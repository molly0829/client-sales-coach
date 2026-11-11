<#
.SYNOPSIS
    客户教练 CLI —— 用 DeepSeek（或任意 OpenAI 兼容接口）分析客户聊天记录。

.DESCRIPTION
    读取技能主文件作为系统提示，把客户聊天记录/邮件/纪要发给模型，输出五段式分析。
    兼容 Windows PowerShell 5.1 与 PowerShell 7，无第三方依赖。

.EXAMPLE
    $env:DEEPSEEK_API_KEY = "sk-xxxx"
    .\chat.ps1 -InputFile .\samples\demo-chat.txt

.EXAMPLE
    .\chat.ps1 -Text "客户：方案我看了，挺好的，有需要联系你" -Profile .\profiles\恒远制造.md
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory = $false)]
    [string]$ApiKey = $env:DEEPSEEK_API_KEY,

    [string]$BaseUrl = "https://api.deepseek.com",

    [string]$Model = "deepseek-chat",

    [Parameter(ParameterSetName = 'File', Mandatory = $true)]
    [string]$InputFile,

    [Parameter(ParameterSetName = 'Text', Mandatory = $true)]
    [string]$Text,

    # 可选：该客户的档案文件，作为上下文一起发给模型
    [string]$Profile,

    # 技能目录（默认取本脚本上一级，脚本体内计算）
    [string]$SkillDir,

    # 单轮最大输出 tokens
    [int]$MaxTokens = 2048,

    # 温度（0–2）
    [double]$Temperature = 0.6
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ([string]::IsNullOrWhiteSpace($SkillDir)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $SkillDir = Join-Path $scriptDir '..\.claude\skills\client-sales-coach'
}

function Die([string]$msg) {
    Write-Error $msg
    exit 1
}

# ---------- 读取输入 ----------
if ($PSCmdlet.ParameterSetName -eq 'File') {
    if (-not (Test-Path -LiteralPath $InputFile)) { Die "找不到聊天记录文件：$InputFile" }
    $chatText = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $InputFile), [System.Text.Encoding]::UTF8)
} else {
    $chatText = $Text
}
if ([string]::IsNullOrWhiteSpace($chatText)) { Die "聊天记录为空。" }

# ---------- 读取技能 ----------
$skillPath = Join-Path $SkillDir 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillPath)) { Die "找不到技能文件：$skillPath（请确认 -SkillDir 或目录结构）" }
$skill = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $skillPath), [System.Text.Encoding]::UTF8)

# ---------- 技能里引用的方法论，按需附带核心几份 ----------
$refFiles = @('chat-analysis.md', 'signal-patterns.md', 'lifecycle.md', 'damage-control.md')
$refText = ''
foreach ($f in $refFiles) {
    $p = Join-Path (Join-Path $SkillDir 'references') $f
    if (Test-Path -LiteralPath $p) {
        $refText += "`n`n===== references/$f =====`n" + [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $p), [System.Text.Encoding]::UTF8)
    }
}

$profileText = ''
if ($Profile -and (Test-Path -LiteralPath $Profile)) {
    $profileText = "`n`n===== 该客户已有档案 =====`n" + [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Profile), [System.Text.Encoding]::UTF8)
}

# ---------- 组装请求 ----------
$system = "你是「客户教练」，严格按下面技能文件执行。输出中文，结构固定：📍定位 / 🔍信号解读 / ⚠️你的问题 / 💬建议回复 / 🎯下一步。" +
          "涉及具体客户时必须开头加阶段标签。信息不足时先问 1–2 个关键问题。`n`n" +
          $skill + $refText

$user = "请分析以下客户沟通内容，判断阶段与真实意向，指出我的问题并给可直接发送的回复。`n`n--- 客户沟通内容 ---`n" +
        $chatText + $profileText

if (-not $ApiKey) {
    Die "缺少 API Key。请设置环境变量 DEEPSEEK_API_KEY，或用 -ApiKey 传入。"
}

$body = @{
    model       = $Model
    messages    = @(
        @{ role = 'system'; content = $system },
        @{ role = 'user'; content = $user }
    )
    temperature = $Temperature
    max_tokens  = $MaxTokens
    stream      = $false
} | ConvertTo-Json -Depth 8 -Compress

# ---------- 调用 ----------
$endpoint = ($BaseUrl.TrimEnd('/')) + '/chat/completions'
$req = [System.Net.WebRequest]::Create($endpoint)
$req.Method = 'POST'
$req.Timeout = 300000
$req.ReadWriteTimeout = 300000
$req.ContentType = 'application/json'
$req.Headers.Add('Authorization', "Bearer $ApiKey")

$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
$req.ContentLength = $bytes.Length
$rs = $req.GetRequestStream()
$rs.Write($bytes, 0, $bytes.Length)
$rs.Close()

try {
    $resp = $req.GetResponse()
} catch [System.Net.WebException] {
    $ex = $_.Exception
    $detail = ''
    if ($ex.Response) {
        $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $detail = $sr.ReadToEnd(); $sr.Close()
    }
    Die "请求失败：$($ex.Message)`n$detail"
}

$sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
$raw = $sr.ReadToEnd()
$sr.Close(); $resp.Close()

try {
    $obj = $raw | ConvertFrom-Json
    $content = $obj.choices[0].message.content
} catch {
    Die "响应解析失败：$raw"
}

if ([string]::IsNullOrWhiteSpace($content)) { Die "模型返回为空：$raw" }

# ---------- 输出 ----------
Write-Output $content
