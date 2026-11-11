<#
.SYNOPSIS
    向已存在的 GitHub 仓库推送一次更新（不需要安装 git）。

.DESCRIPTION
    基于仓库当前 head 创建一次提交，只替换/新增 -Paths 指定的文件或目录，
    其余文件保持不变。适合首次发布后继续更新内容。

.EXAMPLE
    .\update-github.ps1 -Owner molly0829 -Repo client-sales-coach -Token ghp_xxx
    # 默认推送 README.md 与 dsh-plugin/ 目录

.EXAMPLE
    .\update-github.ps1 -Owner molly0829 -Repo client-sales-coach -Token ghp_xxx -Paths 'dsh-plugin' -Message 'feat: dsh plugin'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Owner,
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Token,

    # 相对 -SourceDir 的路径；文件或目录，目录会递归收集
    [string[]]$Paths = @('README.md', 'dsh-plugin'),

    [string]$Message = 'feat: add DeepSeek Harness plugin bundle',
    [string]$Branch = 'main',
    [string]$SourceDir,
    [string]$ApiBase = 'https://api.github.com'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..'
}

$headers = @{
    Authorization          = "token $Token"
    'User-Agent'           = 'client-sales-coach-updater'
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

$root = (Resolve-Path -LiteralPath $SourceDir).Path
$fullName = "$Owner/$Repo"

try { $me = Invoke-Gh -Method GET -Path '/user' } catch { Die "Token 无效或权限不足：$($_.Exception.Message)" }
if ($me.login -ne $Owner) { Write-Warning "Token 属于 $($me.login)，与 -Owner $Owner 不一致。" }

# 当前分支 head 与根树
try {
    $ref = Invoke-Gh -Method GET -Path "/repos/$fullName/git/ref/heads/$Branch"
    $headSha = $ref.object.sha
    $commit = Invoke-Gh -Method GET -Path "/repos/$fullName/git/commits/$headSha"
    $baseTree = $commit.tree.sha
} catch { Die "读取仓库 $fullName 失败（分支 $Branch 是否存在？）：$($_.Exception.Message)" }
Write-Host "当前 head：$($headSha.Substring(0, 7))"

# 收集文件
$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
foreach ($p in $Paths) {
    $full = Join-Path $root $p
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $files.Add((Get-Item -LiteralPath $full))
    } elseif (Test-Path -LiteralPath $full -PathType Container) {
        Get-ChildItem -LiteralPath $full -Recurse -File -Force | ForEach-Object { $files.Add($_) }
    } else {
        Die "找不到路径：$full"
    }
}
if ($files.Count -eq 0) { Die "没有可上传的文件。" }
Write-Host "待上传文件数：$($files.Count)"

# 逐文件创建 blob
$tree = @()
$i = 0
foreach ($f in $files) {
    $i++
    $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($f.FullName))
    try { $blob = Invoke-Gh -Method POST -Path "/repos/$fullName/git/blobs" -Body @{ content = $b64; encoding = 'base64' } }
    catch { Die "上传 $rel 失败：$($_.Exception.Message)" }
    $tree += @{ path = $rel; mode = '100644'; type = 'blob'; sha = $blob.sha }
    Write-Host ("  [{0}/{1}] {2}" -f $i, $files.Count, $rel)
}

# 建树（基于现有树，只替换列出的路径）、提交、更新分支
try { $treeObj = Invoke-Gh -Method POST -Path "/repos/$fullName/git/trees" -Body @{ base_tree = $baseTree; tree = $tree } }
catch { Die "创建目录树失败：$($_.Exception.Message)" }

try { $newCommit = Invoke-Gh -Method POST -Path "/repos/$fullName/git/commits" -Body @{ message = $Message; tree = $treeObj.sha; parents = @($headSha) } }
catch { Die "创建提交失败：$($_.Exception.Message)" }

try { $null = Invoke-Gh -Method PATCH -Path "/repos/$fullName/git/refs/heads/$Branch" -Body @{ sha = $newCommit.sha; force = $false } }
catch { Die "更新分支失败：$($_.Exception.Message)" }

Write-Host ""
Write-Host "更新完成：https://github.com/$fullName"
Write-Host "分支：$Branch  文件：$($files.Count)  提交：$($newCommit.sha.Substring(0, 7))"
