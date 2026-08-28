Set-StrictMode -Version Latest

Describe 'M3 离线中文内容渲染' {
    BeforeAll {
        $project = Split-Path -Parent $PSScriptRoot
        $renderer = Join-Path $project 'build/Render-OfflineContent.ps1'
        $fixtureManifest = Join-Path $project 'tests/fixtures/content/product-manifest.json'
        $rendered = Join-Path $TestDrive 'rendered-content'
        $shell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
        if ([string]::IsNullOrWhiteSpace($shell)) { $shell = (Get-Command powershell -ErrorAction Stop).Source }
        $script:Shell = $shell
        & $script:Shell -NoProfile -File $renderer -ProjectRoot $project -ManifestPath $fixtureManifest -OutputRoot $rendered
        if ($LASTEXITCODE -ne 0) { throw '渲染脚本未成功完成。' }
        $files = @(Get-ChildItem -LiteralPath $rendered -Recurse -File)
        $htmlFiles = @($files | Where-Object Extension -eq '.html')
        $htmlText = ($htmlFiles | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
    }

    It '生成交付契约中的全部十个 HTML 页面和 README' {
        $expected = @(
            '00-开始这里.html',
            '02-配置指南/01-首次启动与模型配置.html',
            '02-配置指南/02-跑通第一次对话.html',
            '02-配置指南/03-数据目录与备份.html',
            '02-配置指南/04-更新重装与卸载.html',
            '02-配置指南/05-常见问题.html',
            '03-诊断工具/诊断工具使用说明.html',
            '05-售后说明/自助版服务范围.html',
            '05-售后说明/远程版服务范围.html',
            '05-售后说明/提交问题前请准备.html',
            'README.txt'
        )
        foreach ($relative in $expected) { Test-Path -LiteralPath (Join-Path $rendered $relative) | Should -BeTrue }
    }

    It '页面只使用内联本地资源，外链仅为可主动点击的官方 HTTPS 链接' {
        $htmlText | Should -Not -Match '(?is)<script|<iframe|<link[^>]+https?://|<img[^>]+https?://|src\s*=\s*["'']https?://'
        $hrefs = [regex]::Matches($htmlText, 'href="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        foreach ($href in $hrefs) {
            $uri = [Uri]$href
            if (-not $uri.IsAbsoluteUri) { continue }
            if ($uri.Scheme -ne 'https') { throw "外链不是 HTTPS：$href" }
            $official = ($uri.Host -eq 'hermes-agent.nousresearch.com' -or $uri.Host -eq 'hermes-assets.nousresearch.com' -or
                (($uri.Host -eq 'github.com' -or $uri.Host -eq 'raw.githubusercontent.com') -and $uri.AbsolutePath.StartsWith('/NousResearch/hermes-agent', [StringComparison]::Ordinal)))
            $official | Should -BeTrue
        }
        $htmlText | Should -Match 'data-network="true"'
        $htmlText | Should -Not -Match '(?i)cdn|serviceworker|tracking|telemetry|pixel'
    }

    It '没有未替换变量或禁用宣传承诺' {
        $htmlText | Should -Not -Match '\{\{[^}]+\}\}|\$\{[^}]+\}'
        $htmlText | Should -Not -Match 'XQ\s*官方\s*Hermes|永久|百分百|无限售后|全离线安装'
    }

    It '起始页只有五步，并明确两条模型路线和联网边界' {
        $start = Get-Content -Raw -LiteralPath (Join-Path $rendered '00-开始这里.html')
        ([regex]::Matches($start, '<ol>')).Count | Should -Be 1
        ([regex]::Matches($start, '<li>')).Count | Should -Be 5
        $start | Should -Match 'Nous Portal OAuth'
        $start | Should -Match '自备模型服务'
        $start | Should -Match '薄安装器|需要联网'
    }

    It '覆盖数据、备份、更新、重装、卸载与售后边界' {
        $htmlText | Should -Match 'LOCALAPPDATA'
        $htmlText | Should -Match '备份'
        $htmlText | Should -Match '更新'
        $htmlText | Should -Match '重装'
        $htmlText | Should -Match '卸载'
        $htmlText | Should -Match '自助版服务范围'
        $htmlText | Should -Match '用户本人.*Key|Key.*用户本人'
    }

    It '缺少锁定 hash 时失败并返回非零' {
        $badManifest = Join-Path $TestDrive 'bad-manifest.json'
        '{"productVersion":"1.0.0","hermesVersion":"0.1.0","officialAssetName":"x.exe","officialSha256":"bad","signatureStatus":"Unavailable"}' | Set-Content -LiteralPath $badManifest -Encoding UTF8
        $badOutput = Join-Path $TestDrive 'bad-output'
        & $script:Shell -NoProfile -File $renderer -ProjectRoot $project -ManifestPath $badManifest -OutputRoot $badOutput *> $null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It '拒绝恶意 source 和 output 路径' {
        $caseContent = Join-Path $TestDrive 'path-case-content'
        Copy-Item -LiteralPath (Join-Path $project 'content') -Destination $caseContent -Recurse
        $caseMapPath = Join-Path $caseContent 'content-map.json'
        $caseMap = Get-Content -Raw -Encoding UTF8 -LiteralPath $caseMapPath | ConvertFrom-Json
        $caseMap.pages[0].source = '../outside.md'
        $caseMap | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $caseMapPath -Encoding UTF8
        $badOutput = Join-Path $TestDrive 'path-case-output'
        & $script:Shell -NoProfile -File $renderer -ProjectRoot $project -ContentRoot $caseContent -ManifestPath $fixtureManifest -OutputRoot $badOutput *> $null
        $LASTEXITCODE | Should -Not -Be 0

        $caseContent2 = Join-Path $TestDrive 'output-case-content'
        Copy-Item -LiteralPath (Join-Path $project 'content') -Destination $caseContent2 -Recurse
        $caseMapPath2 = Join-Path $caseContent2 'content-map.json'
        $caseMap2 = Get-Content -Raw -Encoding UTF8 -LiteralPath $caseMapPath2 | ConvertFrom-Json
        $caseMap2.pages[0].output = '../escape.html'
        $caseMap2 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $caseMapPath2 -Encoding UTF8
        $badOutput2 = Join-Path $TestDrive 'output-case-output'
        & $script:Shell -NoProfile -File $renderer -ProjectRoot $project -ContentRoot $caseContent2 -ManifestPath $fixtureManifest -OutputRoot $badOutput2 *> $null
        $LASTEXITCODE | Should -Not -Be 0

        $caseContent3 = Join-Path $TestDrive 'absolute-source-content'
        Copy-Item -LiteralPath (Join-Path $project 'content') -Destination $caseContent3 -Recurse
        $caseMapPath3 = Join-Path $caseContent3 'content-map.json'
        $caseMap3 = Get-Content -Raw -Encoding UTF8 -LiteralPath $caseMapPath3 | ConvertFrom-Json
        $caseMap3.pages[0].source = (Join-Path $TestDrive 'outside.md')
        $caseMap3 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $caseMapPath3 -Encoding UTF8
        $badOutput3 = Join-Path $TestDrive 'absolute-source-output'
        & $script:Shell -NoProfile -File $renderer -ProjectRoot $project -ContentRoot $caseContent3 -ManifestPath $fixtureManifest -OutputRoot $badOutput3 *> $null
        $LASTEXITCODE | Should -Not -Be 0

        $caseContent4 = Join-Path $TestDrive 'absolute-output-content'
        Copy-Item -LiteralPath (Join-Path $project 'content') -Destination $caseContent4 -Recurse
        $caseMapPath4 = Join-Path $caseContent4 'content-map.json'
        $caseMap4 = Get-Content -Raw -Encoding UTF8 -LiteralPath $caseMapPath4 | ConvertFrom-Json
        $caseMap4.pages[0].output = (Join-Path $TestDrive 'escape.html')
        $caseMap4 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $caseMapPath4 -Encoding UTF8
        $badOutput4 = Join-Path $TestDrive 'absolute-output-output'
        & $script:Shell -NoProfile -File $renderer -ProjectRoot $project -ContentRoot $caseContent4 -ManifestPath $fixtureManifest -OutputRoot $badOutput4 *> $null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It '拒绝 CSS 中的 @import 和远程 url' {
        $caseContent = Join-Path $TestDrive 'css-case-content'
        Copy-Item -LiteralPath (Join-Path $project 'content') -Destination $caseContent -Recurse
        Add-Content -LiteralPath (Join-Path $caseContent 'assets/xq-offline.css') -Value "`n@import url('https://evil.example/style.css');" -Encoding UTF8
        $badOutput = Join-Path $TestDrive 'css-case-output'
        & $script:Shell -NoProfile -File $renderer -ProjectRoot $project -ContentRoot $caseContent -ManifestPath $fixtureManifest -OutputRoot $badOutput *> $null
        $LASTEXITCODE | Should -Not -Be 0
    }
}
