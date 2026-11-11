<#
.SYNOPSIS
    把技能包发布到 GitHub（不需要安装 git）。

.DESCRIPTION
    使用 GitHub REST API：创建仓库 → 上传全部文件为一次提交 → 输出仓库地址。
    需要 Personal Access Token（classic 勾选 repo，或 fine-grained 授予
    Administration: Read and write + Contents: Read and write）。

.EXAMPLE
    .\publish-github.ps1 -Owner yourname -Repo client-sales-coach -Token ghp_xxx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Owner,
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Description = "B2B 客户聊天教练技能包：判断采购阶段、读懂客户信号、止损决策、客户档案与看板。AI skill for B2B sales coaching.",
    [switch]$Private,
    [string]$SourceDir,
    [string]$ApiBase = 'https://api.github.com',
    [string]$CommitMessage = 'Initial commit: 客户聊天教练 Client Sales Coach (B2B)'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..'
}

$headers = @{
    Authorization          = "token $Token"
    'User-Agent'           = 'client-sales-coach-publisher'
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

function Invoke-Gh {
    param([string]$Method, [string]$Path, $Body)
    $url = $ApiBase.TrimEnd('/') + $Path
    $p = @{ Method = $Method; Uri = $url; Headers = $headers; TimeoutSec = 60 }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $p.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $p.ContentType = 'application/json; charset=utf-8'
    }
    Invoke-RestMethod @p
}

function Die([string]$msg) { Write-Error $msg; exit 1 }

# 0. 校验 token 与账号
try { $me = Invoke-Gh -Method GET -Path '/user' } catch { Die "Token 无效或权限不足：$($_.Exception.Message)" }
Write-Host "登录账号：$($me.login)"
if ($me.login -ne $Owner) {
    Write-Warning "Token 属于 $($me.login)，与 -Owner $Owner 不一致；将按 $Owner 操作（需要有权限）。"
}

# 1. 检查仓库是否已存在
# 1. 检查仓库：空仓库可直接复用，非空则拒绝
$repoObj = $null
try { $repoObj = Invoke-Gh -Method GET -Path "/repos/$Owner/$Repo" } catch { }

if ($repoObj) {
    if ($repoObj.size -eq 0) {
        Write-Host "仓库已存在且为空，直接初始化：$($repoObj.full_name)"
    } else {
        Die "仓库 $Owner/$Repo 已存在且非空。请换一个 -Repo 名称，或先手动删除。"
    }
} else {
    # 2. 创建仓库
    $repoBody = @{
        name        = $Repo
        description = $Description
        private     = [bool]$Private
        has_issues  = $true
        has_wiki    = $false
        auto_init   = $false
    }
    try { $repoObj = Invoke-Gh -Method POST -Path '/user/repos' -Body $repoBody }
    catch { Die "创建仓库失败：$($_.Exception.Message)" }
    Write-Host "已创建仓库：$($repoObj.full_name)"
}
$fullName = $repoObj.full_name

# 3. 收集文件（排除 .git / profiles / 本地数据）
$root = (Resolve-Path -LiteralPath $SourceDir).Path
$excludeDirs = @('.git', 'profiles', 'node_modules', '.idea', '.vscode')
$excludeFiles = @('.env')

$files = Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object {
    $rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    $parts = $rel.Split('/')
    $badDir = $false
    foreach ($part in $parts[0..([Math]::Max(0, $parts.Count - 2))]) {
        if ($excludeDirs -contains $part) { $badDir = $true }
    }
    (-not $badDir) -and ($excludeFiles -notcontains $_.Name)
}

Write-Host "待上传文件数：$($files.Count)"

# 4. 确保分支有初始提交（空仓库无法创建 blob，GitHub 返回 409）
$branch = if ($repoObj.default_branch) { $repoObj.default_branch } else { 'main' }
$headSha = $null
try { $headSha = (Invoke-Gh -Method GET -Path "/repos/$fullName/git/ref/heads/$branch").object.sha } catch { }

if (-not $headSha) {
    $readmePath = Join-Path $root 'README.md'
    if (Test-Path -LiteralPath $readmePath) {
        $initB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($readmePath))
        $initMsg = 'chore: 初始化仓库'
    } else {
        $initB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("# init`n"))
        $initMsg = 'chore: init'
    }
    try {
        $null = Invoke-Gh -Method PUT -Path "/repos/$fullName/contents/README.md" -Body @{ message = $initMsg; content = $initB64; branch = $branch }
        $headSha = (Invoke-Gh -Method GET -Path "/repos/$fullName/git/ref/heads/$branch").object.sha
        Write-Host "已建立初始提交：$($headSha.Substring(0, 7))"
    } catch { Die "初始化分支失败：$($_.Exception.Message)" }
}

# 5. 逐个创建 blob
$tree = @()
$i = 0
foreach ($f in $files) {
    $i++
    $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $b64 = [Convert]::ToBase64String($bytes)
    try {
        $blob = Invoke-Gh -Method POST -Path "/repos/$fullName/git/blobs" -Body @{ content = $b64; encoding = 'base64' }
    } catch { Die "上传 $rel 失败：$($_.Exception.Message)" }
    $tree += @{ path = $rel; mode = '100644'; type = 'blob'; sha = $blob.sha }
    Write-Host ("  [{0}/{1}] {2}" -f $i, $files.Count, $rel)
}

# 6. 建树、提交、更新分支
try { $treeObj = Invoke-Gh -Method POST -Path "/repos/$fullName/git/trees" -Body @{ tree = $tree } }
catch { Die "创建目录树失败：$($_.Exception.Message)" }

try { $commit = Invoke-Gh -Method POST -Path "/repos/$fullName/git/commits" -Body @{ message = $CommitMessage; tree = $treeObj.sha; parents = @($headSha) } }
catch { Die "创建提交失败：$($_.Exception.Message)" }

try { $null = Invoke-Gh -Method PATCH -Path "/repos/$fullName/git/refs/heads/$branch" -Body @{ sha = $commit.sha; force = $false } }
catch { Die "更新分支 $branch 失败：$($_.Exception.Message)" }

Write-Host ""
Write-Host "发布完成：$($repoObj.html_url)"
Write-Host "分支：$branch  文件：$($files.Count)  提交：$($commit.sha.Substring(0, 7))"
