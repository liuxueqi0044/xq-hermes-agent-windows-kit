[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository PowerShell sources intentionally use UTF-8 without BOM for deterministic cross-tool output.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'The only exception is private renderer helper Flush-Paragraph, which is not an exported command.')]
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ContentRoot = '',
    [string]$ManifestPath = '',
    [string]$OutputRoot = '',
    [string]$ProductVersion = '',
    [string]$HermesVersion = '',
    [string]$InstallerName = '',
    [string]$OfficialSha256 = '',
    [string]$SignatureStatus = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "输出目录尚未通过安全校验：$parent" }
    Assert-NoReparseInPath $parent
    if (Test-Path -LiteralPath $Path) { Assert-NoReparseInPath $Path }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Assert-NoReparseInPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "拒绝经过 reparse point 的路径：$cursor"
            }
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-SafeContainedPath([string]$Root, [string]$Relative, [string]$Kind) {
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw "$Kind 路径不能为空。" }
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.(?:[\\/]|$)' -or $Relative -match '(^|[\\/])[^\\/]*:') {
        throw "$Kind 路径越界：$Relative"
    }
    try { $full = [IO.Path]::GetFullPath((Join-Path -Path $Root -ChildPath $Relative)) }
    catch { throw "$Kind 路径无效：$Relative" }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rootPrefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Kind 路径解析后越界：$Relative"
    }
    Assert-NoReparseInPath $full
    return $full
}

function Get-SafeContentFile([string]$Root, [string]$Relative, [string]$Kind) {
    $full = Get-SafeContainedPath $Root $Relative $Kind
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "找不到 $Kind：$full" }
    Assert-NoReparseInPath $full
    return $full
}

function Get-SafeOutputFile([string]$Root, [string]$Relative) {
    if (-not (Test-Path -LiteralPath $Root)) {
        $rootParent = Split-Path -Parent $Root
        Assert-NoReparseInPath $rootParent
        if (-not (Test-Path -LiteralPath $rootParent -PathType Container)) { New-Item -ItemType Directory -Path $rootParent -Force | Out-Null }
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "OutputRoot 不是目录：$Root" }
    Assert-NoReparseInPath $Root
    $full = Get-SafeContainedPath $Root $Relative '输出'
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Assert-NoReparseInPath $parent
    if (Test-Path -LiteralPath $full) {
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "输出目标不是文件：$full" }
        Assert-NoReparseInPath $full
    }
    return $full
}

function Get-ValueOrEmpty($Object, [string]$Name) {
    if ($null -eq $Object) { return '' }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Resolve-Setting([string]$Explicit, [string]$ManifestValue, [string]$Name) {
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($ManifestValue)) { return $ManifestValue.Trim() }
    throw "缺少内容变量 $Name。请通过 manifest 或显式参数提供。"
}

function Html([string]$Text) { return [System.Net.WebUtility]::HtmlEncode($Text) }

function Convert-Inline([string]$Text) {
    $encoded = Html $Text
    $encoded = [regex]::Replace($encoded, '\[([^\]]+)\]\(([^)\s]+)\)', {
        param($match)
        $label = $match.Groups[1].Value
        $href = $match.Groups[2].Value
        if ($href -notmatch '^https://(github\.com/NousResearch/hermes-agent(?:/|$)|raw\.githubusercontent\.com/NousResearch/hermes-agent(?:/|$)|hermes-agent\.nousresearch\.com(?:/|$)|hermes-assets\.nousresearch\.com(?:/|$))') {
            throw "发现不允许的外部链接：$href"
        }
        if ($href -match '["''<>`\s]') { throw "外部链接包含不安全字符：$href" }
        if ($label -notmatch '需要联网') { $label = "$label（需要联网）" }
        return '<a href="' + $href + '" data-network="true" rel="noreferrer">' + $label + '</a>'
    })
    $encoded = [regex]::Replace($encoded, '`([^`]+)`', '<code>$1</code>')
    $encoded = [regex]::Replace($encoded, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    return $encoded
}

function Convert-Markdown([string]$Markdown) {
    $lines = $Markdown -replace "`r`n", "`n" -replace "`r", "`n" -split "`n"
    $html = New-Object System.Collections.Generic.List[string]
    $paragraph = New-Object System.Collections.Generic.List[string]
    $inCode = $false
    $code = New-Object System.Collections.Generic.List[string]
    $listType = ''
    function Flush-Paragraph {
        if ($paragraph.Count -gt 0) {
            $joined = ($paragraph -join ' ').Trim()
            if ($joined.Length -gt 0) { $html.Add('<p>' + (Convert-Inline $joined) + '</p>') }
            $paragraph.Clear()
        }
    }
    function Close-List {
        if ($listType -ne '') { $html.Add('</' + $listType + '>'); Set-Variable -Name listType -Value '' -Scope 1 }
    }
    foreach ($line in $lines) {
        if ($inCode) {
            if ($line -match '^\s*```') {
                $html.Add('<pre><code>' + (Html ($code -join "`n")) + '</code></pre>')
                $code.Clear(); $inCode = $false
            } else { $code.Add($line) }
            continue
        }
        if ($line -match '^\s*```') { Flush-Paragraph; Close-List; $inCode = $true; continue }
        if ([string]::IsNullOrWhiteSpace($line)) { Flush-Paragraph; Close-List; continue }
        if ($line -match '^(#{1,6})\s+(.+?)\s*$') {
            Flush-Paragraph; Close-List
            $level = $matches[1].Length
            $html.Add('<h' + $level + '>' + (Convert-Inline $matches[2]) + '</h' + $level + '>'); continue
        }
        if ($line -match '^\s*[-*]\s+(.+)$') {
            Flush-Paragraph
            if ($listType -eq 'ol') { Close-List }
            if ($listType -eq '') { $html.Add('<ul>'); $listType = 'ul' }
            $html.Add('<li>' + (Convert-Inline $matches[1]) + '</li>'); continue
        }
        if ($line -match '^\s*\d+\.\s+(.+)$') {
            Flush-Paragraph
            if ($listType -eq 'ul') { Close-List }
            if ($listType -eq '') { $html.Add('<ol>'); $listType = 'ol' }
            $html.Add('<li>' + (Convert-Inline $matches[1]) + '</li>'); continue
        }
        if ($line -match '^\s*&gt;\s*(.*)$' -or $line -match '^\s*>\s*(.*)$') {
            Flush-Paragraph; Close-List
            $html.Add('<blockquote>' + (Convert-Inline $matches[1]) + '</blockquote>'); continue
        }
        $paragraph.Add($line)
    }
    if ($inCode) { throw 'Markdown 代码块未闭合。' }
    Flush-Paragraph; Close-List
    return ($html -join "`n")
}

function Get-RelativeHref([string]$FromOutput, [string]$ToOutput) {
    $fromParts = ($FromOutput -split '[\\/]')
    $fromDirCount = [Math]::Max(0, $fromParts.Count - 1)
    $toParts = ($ToOutput -split '[\\/]')
    $common = 0
    while ($common -lt $fromDirCount -and $common -lt $toParts.Count -and $fromParts[$common] -eq $toParts[$common]) { $common++ }
    $parts = New-Object System.Collections.Generic.List[string]
    for ($i = $common; $i -lt $fromDirCount; $i++) { $parts.Add('..') }
    for ($i = $common; $i -lt $toParts.Count; $i++) { $parts.Add($toParts[$i]) }
    return ($parts -join '/')
}

try {
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    if ([string]::IsNullOrWhiteSpace($ContentRoot)) { $ContentRoot = Join-Path $ProjectRoot 'content' }
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $ProjectRoot 'manifest/product-manifest.json' }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $ProjectRoot 'work/rendered-content' }
    $ContentRoot = [IO.Path]::GetFullPath($ContentRoot)
    $OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
    if (-not (Test-Path -LiteralPath $ContentRoot -PathType Container)) { throw "ContentRoot 不是目录：$ContentRoot" }
    Assert-NoReparseInPath $ContentRoot
    $mapPath = Get-SafeContentFile $ContentRoot 'content-map.json' '内容映射'
    $map = Get-Content -Raw -Encoding UTF8 -LiteralPath $mapPath | ConvertFrom-Json
    if ($null -eq $map.pages -or $map.pages.Count -lt 1) { throw 'content-map.json 未定义页面。' }

    $cssPath = Get-SafeContentFile $ContentRoot 'assets/xq-offline.css' 'CSS'
    $css = Get-Content -Raw -Encoding UTF8 -LiteralPath $cssPath
    if ($css -match '(?i)@import|url\s*\(\s*["'']?(?:https?:|//)|https?://|//[^/\r\n]') {
        throw 'CSS 禁止 @import、远程 url() 和网络资源。'
    }

    $manifest = $null
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) { $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $ManifestPath | ConvertFrom-Json }
    $product = Resolve-Setting $ProductVersion (Get-ValueOrEmpty $manifest 'productVersion') 'productVersion'
    $hermes = Resolve-Setting $HermesVersion (Get-ValueOrEmpty $manifest 'hermesVersion') 'hermesVersion'
    $installer = Resolve-Setting $InstallerName (Get-ValueOrEmpty $manifest 'officialAssetName') 'officialAssetName'
    $sha = Resolve-Setting $OfficialSha256 (Get-ValueOrEmpty $manifest 'officialSha256') 'officialSha256'
    $sig = Resolve-Setting $SignatureStatus (Get-ValueOrEmpty $manifest 'signatureStatus') 'signatureStatus'
    if ($sha -notmatch '^[0-9a-fA-F]{64}$') { throw 'officialSha256 必须是 64 位十六进制值。' }
    if ($sha -match '^0+$') { throw 'officialSha256 不能是未锁定的全零值。' }
    if ($sig -eq 'Invalid') { throw '签名状态为 Invalid，禁止渲染交付内容。' }
    foreach ($pair in @(@('productVersion',$product),@('hermesVersion',$hermes),@('officialAssetName',$installer),@('officialSha256',$sha))) {
        if ($pair[1] -match '(?i)(\{\{|\}\}|<[^>]+>|\bTODO\b|\bTBD\b|\bCHANGE_ME\b|\bCHANGEME\b|\blatest\b|\bmain\b)') { throw "$($pair[0]) 含占位符或浮动值。" }
    }
    $vars = @{ productVersion=$product; hermesVersion=$hermes; installerName=$installer; officialSha256=$sha; signatureStatus=$sig }
    $expectedOutputs = @($map.pages | ForEach-Object { [string]$_.output }) + @([string]$map.readme.output)
    foreach ($out in $expectedOutputs) {
        if ([IO.Path]::IsPathRooted($out) -or $out -match '(^|[\\/])\.\.(?:[\\/]|$)') { throw "输出路径越界：$out" }
        [void](Get-SafeContainedPath $OutputRoot $out '输出')
    }
    $pageIndex = 0
    foreach ($page in $map.pages) {
        $source = Get-SafeContentFile $ContentRoot ([string]$page.source) '内容源'
        $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $source
        foreach ($key in $vars.Keys) { $text = $text.Replace('{{' + $key + '}}', $vars[$key]) }
        if ($text -match '\{\{[^}]+\}\}') { throw "内容存在未替换变量：$source" }
        $body = Convert-Markdown $text
        if ($body -match '(?is)<script|<iframe|<link[^>]+href\s*=\s*["'']https?://|<img[^>]+src\s*=\s*["'']https?://|https?://[^"''\s>]+\.(?:js|css|woff2?|ttf)(?:[?#][^"''\s>]*)?') { throw "页面包含远程资源或脚本：$source" }
        $title = Html ([string]$page.title)
        $nav = New-Object System.Collections.Generic.List[string]
        $nav.Add('<nav aria-label="页面导航"><a href="' + (Get-RelativeHref ([string]$page.output) ([string]$map.pages[0].output)) + '">返回开始</a>')
        $index = $pageIndex
        if ($index -gt 0) { $nav.Add(' · <a href="' + (Get-RelativeHref ([string]$page.output) ([string]$map.pages[$index-1].output)) + '">上一页</a>') }
        if ($index -lt $map.pages.Count - 1) { $nav.Add(' · <a href="' + (Get-RelativeHref ([string]$page.output) ([string]$map.pages[$index+1].output)) + '">下一页</a>') }
        $nav.Add('</nav>')
        $meta = '<div class="meta">Hermes Agent ' + (Html $hermes) + ' · 配置包 ' + (Html $product) + ' · 仅本地渲染</div>'
        $footer = '<footer>来源与版本以本包清单为准。外部链接仅在用户主动点击时访问官方站点，并标注需要联网。</footer>'
        $document = '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' + $title + '</title><style>' + $css + '</style></head><body><main>' + ($nav -join '') + $meta + $body + $footer + '</main></body></html>'
        $target = Get-SafeOutputFile $OutputRoot ([string]$page.output)
        Write-Utf8NoBom $target $document
        $pageIndex++
    }
    $readme = @"
XQ Hermes Agent Windows 配置包

这是面向 Windows 11 x64 的中文安装与配置说明集合。Hermes Agent 由 Nous Research 发布，XQ 仅提供整理、验证、离线说明、本地只读诊断和约定范围内的支持。

本包可离线阅读；官方 Desktop 是薄安装器，首次启动准备运行环境、登录和模型请求需要联网。模型账号、订阅、Key、费用和服务质量由用户自行承担，凭据只能由用户本人在本机输入。

五步：检查系统与网络；核对来源、SHA-256 和签名；运行官方原始安装器；选择 OAuth 或自备模型服务；完成普通文本对话并运行检查。

产品版本：$product
Hermes 版本：$hermes
官方安装器：$installer
官方 SHA-256：$sha
签名状态：$sig

页面不加载远程脚本、字体、图片、统计或其他网络资源。官方链接只有用户主动点击才会访问，链接页面需要联网。

请勿发送 API Key、Token、Cookie、密码、授权码、会话正文、生产日志或 .env 内容。更新前备份用户数据；本套件不提供自动清理数据的脚本。

官方页面（需要联网，用户主动点击）：
https://hermes-agent.nousresearch.com/docs/user-guide/windows-native
https://hermes-agent.nousresearch.com/docs/user-guide/desktop
https://hermes-agent.nousresearch.com/docs/user-guide/security/
"@
    Write-Utf8NoBom (Get-SafeOutputFile $OutputRoot ([string]$map.readme.output)) ($readme.Trim() + "`r`n")
    Write-Output "Offline content rendered: $OutputRoot"
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
