Set-StrictMode -Version Latest

function Assert-XqPowerShell7 {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'XQ build tools require PowerShell 7 or later.'
    }
}

function Get-XqProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-XqJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required JSON file does not exist: $Path" }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32 -DateKind String) }
    catch { throw "Invalid JSON in '$Path': $($_.Exception.Message)" }
}

function Get-XqTrustedSources {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns the complete trusted-sources policy document, including its rule collection.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $sources = Read-XqJsonFile -Path $Path
    if ((Get-XqProperty $sources 'schemaVersion') -ne '1.0' -or @((Get-XqProperty $sources 'rules')).Count -eq 0) {
        throw "Trusted source file '$Path' is incomplete."
    }
    return $sources
}

function Test-XqCompleteCommit {
    param([AllowNull()][string]$Value)
    return $Value -match '^[a-f0-9]{40}$'
}

function Test-XqForbiddenValue {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return $Value -match '(?i)(?:^|[\\/_?=&.-])(main|latest)(?:$|[\\/_?=&.-])|placeholder|todo|yyyy|<|>|^0{40}$|^0{64}$'
}

function Get-XqUriRule {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)]$TrustedSources,
        [Parameter(Mandatory)][string]$Purpose
    )
    $uriHost = $Uri.DnsSafeHost.ToLowerInvariant()
    $path = [uri]::UnescapeDataString($Uri.AbsolutePath)
    foreach ($rule in @($TrustedSources.rules)) {
        $ruleHost = [string](Get-XqProperty $rule 'host')
        $prefix = [string](Get-XqProperty $rule 'pathPrefix')
        $purposes = @((Get-XqProperty $rule 'purposes'))
        $pathMatches = if ($prefix -eq '/') { $path.StartsWith('/', [StringComparison]::Ordinal) } else { $path -eq $prefix -or $path.StartsWith("$prefix/", [StringComparison]::Ordinal) }
        if ($uriHost -eq $ruleHost.ToLowerInvariant() -and $pathMatches -and
            $purposes -contains $Purpose) { return $rule }
    }
    return $null
}

function Test-XqTrustedUri {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$TrustedSources,
        [Parameter(Mandatory)][string]$Purpose
    )
    $result = [ordered]@{ IsAllowed = $false; Reason = ''; Uri = $null; Rule = $null }
    try { $parsed = [uri]$Uri } catch { $result.Reason = 'URL cannot be parsed.'; return [pscustomobject]$result }
    if (-not $parsed.IsAbsoluteUri) { $result.Reason = 'URL must be absolute.'; return [pscustomobject]$result }
    if ($parsed.Scheme -cne 'https') { $result.Reason = 'Only HTTPS is allowed.'; return [pscustomobject]$result }
    if (-not [string]::IsNullOrEmpty($parsed.UserInfo)) { $result.Reason = 'URL user information is forbidden.'; return [pscustomobject]$result }
    if ($parsed.Port -ne 443) { $result.Reason = 'Only HTTPS port 443 is allowed.'; return [pscustomobject]$result }
    $ignoredIp = [System.Net.IPAddress]::None
    if ([System.Net.IPAddress]::TryParse($parsed.DnsSafeHost, [ref]$ignoredIp)) { $result.Reason = 'IP-literal hosts are forbidden.'; return [pscustomobject]$result }
    if (-not [string]::IsNullOrEmpty($parsed.Fragment)) { $result.Reason = 'URL fragments are forbidden.'; return [pscustomobject]$result }
    $decodedPath = [uri]::UnescapeDataString($parsed.AbsolutePath)
    if ($decodedPath -match '(?i)(?:^|/)(main|latest)(?:/|$)') { $result.Reason = 'Floating main/latest paths are forbidden.'; return [pscustomobject]$result }
    $rule = Get-XqUriRule -Uri $parsed -TrustedSources $TrustedSources -Purpose $Purpose
    if ($null -eq $rule) { $result.Reason = "URL host/path is not trusted for purpose '$Purpose'."; return [pscustomobject]$result }
    $query = $parsed.Query.TrimStart('?')
    $patterns = @((Get-XqProperty $rule 'allowedQueryPatterns'))
    if ([string]::IsNullOrEmpty($query)) {
        if ($patterns.Count -gt 0) {
            $result.Reason = 'URL is missing the query required by the trusted-source rule.'; return [pscustomobject]$result
        }
    } else {
        if ($patterns.Count -eq 0 -or -not (@($patterns | Where-Object { $query -match $_ }).Count -gt 0)) {
            $result.Reason = 'URL query is not allowed by the trusted-source rule.'; return [pscustomobject]$result
        }
    }
    $result.IsAllowed = $true; $result.Uri = $parsed; $result.Rule = $rule
    return [pscustomobject]$result
}

function Assert-XqTrustedUri {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)]$TrustedSources, [Parameter(Mandatory)][string]$Purpose)
    $checked = Test-XqTrustedUri -Uri $Uri -TrustedSources $TrustedSources -Purpose $Purpose
    if (-not $checked.IsAllowed) { throw "Rejected URL '$Uri': $($checked.Reason)" }
    return $checked.Uri
}

function Test-XqManifest {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)]$TrustedSources, [switch]$Formal)
    $errors = [System.Collections.Generic.List[string]]::new()
    $required = 'schemaVersion','buildMode','productVersion','hermesReleaseTag','hermesVersion','upstreamCommit','desktopBuildCommit','runtimeInstallPin','sourcePageUrl','officialAssetUrl','officialAssetName','officialSha256','licenseUrl','licenseSha256','signatureStatus','signature','supportedOs','buildDate','upstreamLicense','xqTelemetry','runtimeInternetRequired'
    foreach ($name in $required) { if ($null -eq (Get-XqProperty $Manifest $name)) { $errors.Add("Missing manifest property '$name'.") } }
    if ($errors.Count -gt 0) { return [pscustomobject]@{ IsValid = $false; Errors = @($errors) } }
    $formalEffective = $Formal -or ((Get-XqProperty $Manifest 'buildMode') -eq 'formal')
    if ((Get-XqProperty $Manifest 'schemaVersion') -ne '1.0') { $errors.Add('schemaVersion must be 1.0.') }
    if ((Get-XqProperty $Manifest 'buildMode') -notin @('draft','formal')) { $errors.Add('buildMode must be draft or formal.') }
    if ([string](Get-XqProperty $Manifest 'productVersion') -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { $errors.Add('productVersion is invalid.') }
    if ((Get-XqProperty $Manifest 'upstreamLicense') -ne 'MIT') { $errors.Add('upstreamLicense must be MIT.') }
    if (@((Get-XqProperty $Manifest 'supportedOs')) -notcontains 'Windows 11 x64') { $errors.Add('supportedOs must include Windows 11 x64.') }
    if ($true -ne (Get-XqProperty $Manifest 'runtimeInternetRequired')) { $errors.Add('runtimeInternetRequired must be true for the thin installer.') }
    if ($false -ne (Get-XqProperty $Manifest 'xqTelemetry')) { $errors.Add('xqTelemetry must be false.') }
    try {
        $buildDate = [string](Get-XqProperty $Manifest 'buildDate'); $parsedDate = [DateTimeOffset]::Parse($buildDate)
        if ($parsedDate.Offset -ne [TimeSpan]::Zero -or $buildDate -notmatch 'Z$') { $errors.Add('buildDate must be ISO-8601 UTC (Z suffix).') }
    } catch { $errors.Add('buildDate must be ISO-8601 UTC.') }
    $sourceCheck = Test-XqTrustedUri -Uri ([string](Get-XqProperty $Manifest 'sourcePageUrl')) -TrustedSources $TrustedSources -Purpose 'source-page'
    if (-not $sourceCheck.IsAllowed) { $errors.Add("sourcePageUrl: $($sourceCheck.Reason)") }
    $assetCheck = Test-XqTrustedUri -Uri ([string](Get-XqProperty $Manifest 'officialAssetUrl')) -TrustedSources $TrustedSources -Purpose 'official-asset'
    if (-not $assetCheck.IsAllowed) { $errors.Add("officialAssetUrl: $($assetCheck.Reason)") }
    $licenseCheck = Test-XqTrustedUri -Uri ([string](Get-XqProperty $Manifest 'licenseUrl')) -TrustedSources $TrustedSources -Purpose 'license'
    if (-not $licenseCheck.IsAllowed) { $errors.Add("licenseUrl: $($licenseCheck.Reason)") }
    $assetName = [string](Get-XqProperty $Manifest 'officialAssetName')
    if ($assetName -ne [IO.Path]::GetFileName($assetName) -or $assetName -notmatch '(?i)\.exe$') { $errors.Add('officialAssetName must be an EXE file name without a path.') }
    if ($assetCheck.IsAllowed -and $assetCheck.Uri.AbsolutePath -notlike "*/$assetName") { $errors.Add('officialAssetName must exactly match the asset URL file name.') }
    $signatureStatus = [string](Get-XqProperty $Manifest 'signatureStatus')
    if ($signatureStatus -notin @('Valid','Unavailable')) { $errors.Add('signatureStatus must be Valid or Unavailable; Invalid is never accepted.') }
    $signature = Get-XqProperty $Manifest 'signature'
    if ((Get-XqProperty $signature 'policy') -ne 'valid-or-explicit-waiver') { $errors.Add('signature.policy must be valid-or-explicit-waiver.') }
    if ([string](Get-XqProperty $signature 'status') -ne $signatureStatus) { $errors.Add('signature.status must match signatureStatus.') }
    if ($signatureStatus -eq 'Valid') {
        if ([string]::IsNullOrWhiteSpace([string](Get-XqProperty $signature 'signerSubject'))) { $errors.Add('Valid signature requires signerSubject.') }
        if ([string](Get-XqProperty $signature 'signerThumbprint') -notmatch '^[A-Fa-f0-9]{40}$') { $errors.Add('Valid signature requires a 40-digit signerThumbprint.') }
    } elseif ([string]::IsNullOrWhiteSpace([string](Get-XqProperty $signature 'waiverId'))) { $errors.Add('Unavailable signature requires an explicit waiverId.') }
    if ($formalEffective) {
        if ((Get-XqProperty $Manifest 'buildMode') -ne 'formal') { $errors.Add('Formal validation requires buildMode=formal.') }
        if ((Get-XqProperty $Manifest 'releaseChannel') -ne 'stable') { $errors.Add('Formal builds must use the stable release channel.') }
        if ([string](Get-XqProperty $Manifest 'hermesReleaseTag') -notmatch '^v\d{4}\.\d{1,2}\.\d{1,2}$') { $errors.Add('hermesReleaseTag must be an exact stable tag.') }
        if ([string](Get-XqProperty $Manifest 'hermesVersion') -notmatch '^\d+\.\d+\.\d+$') { $errors.Add('hermesVersion must be an exact semantic version.') }
        foreach ($commitField in 'upstreamCommit','desktopBuildCommit') {
            $value = [string](Get-XqProperty $Manifest $commitField)
            if (-not (Test-XqCompleteCommit $value) -or (Test-XqForbiddenValue $value)) { $errors.Add("$commitField must be a full, non-floating 40-character commit.") }
        }
        $runtimePin = Get-XqProperty $Manifest 'runtimeInstallPin'
        if ((Get-XqProperty $runtimePin 'type') -ne 'commit' -or -not (Test-XqCompleteCommit ([string](Get-XqProperty $runtimePin 'value'))) -or (Test-XqForbiddenValue ([string](Get-XqProperty $runtimePin 'value')))) { $errors.Add('runtimeInstallPin must contain a full, non-floating commit.') }
        foreach ($field in 'sourcePageUrl','officialAssetUrl','officialAssetName','officialSha256','licenseUrl','licenseSha256') {
            if (Test-XqForbiddenValue ([string](Get-XqProperty $Manifest $field))) { $errors.Add("$field contains a missing, placeholder, or floating value.") }
        }
        if ([string](Get-XqProperty $Manifest 'officialSha256') -notmatch '^[a-f0-9]{64}$') { $errors.Add('officialSha256 must be a lowercase 64-character SHA-256 value.') }
        if ([string](Get-XqProperty $Manifest 'licenseSha256') -notmatch '^[a-f0-9]{64}$') { $errors.Add('licenseSha256 must be a lowercase 64-character SHA-256 value.') }
        if ($licenseCheck.IsAllowed) {
            $expectedLicensePath = "/NousResearch/hermes-agent/$([string](Get-XqProperty $Manifest 'upstreamCommit'))/LICENSE"
            if ($licenseCheck.Uri.DnsSafeHost -cne 'raw.githubusercontent.com' -or $licenseCheck.Uri.AbsolutePath -cne $expectedLicensePath) {
                $errors.Add('licenseUrl must pin the LICENSE file at the exact upstreamCommit on raw.githubusercontent.com.')
            }
        }
        $formalSupportedOs = @((Get-XqProperty $Manifest 'supportedOs'))
        if ($formalSupportedOs.Count -ne 1 -or [string]$formalSupportedOs[0] -ne 'Windows 11 x64') { $errors.Add('Formal builds support exactly Windows 11 x64.') }
        if ($assetCheck.IsAllowed) {
            $buildMatch = [regex]::Match($assetCheck.Uri.Query.TrimStart('?'), '^build=([a-f0-9]{12,40})$')
            if (-not $buildMatch.Success) { $errors.Add('Formal asset URL must include a 12-40 character build query.') }
            elseif (-not ([string](Get-XqProperty $Manifest 'desktopBuildCommit')).StartsWith($buildMatch.Groups[1].Value, [StringComparison]::Ordinal)) { $errors.Add('Asset build query must be a prefix of desktopBuildCommit.') }
        }
        $commits = @(@([string](Get-XqProperty $Manifest 'upstreamCommit'), [string](Get-XqProperty $Manifest 'desktopBuildCommit'), [string](Get-XqProperty $runtimePin 'value')) | Select-Object -Unique)
        if ($commits.Count -gt 1 -and ([string]::IsNullOrWhiteSpace([string](Get-XqProperty $Manifest 'commitRelationshipJustification')) -or [string]::IsNullOrWhiteSpace([string](Get-XqProperty $Manifest 'vmEvidence')))) { $errors.Add('Different upstream, desktop, and runtime commits require commitRelationshipJustification and vmEvidence.') }
    }
    return [pscustomobject]@{ IsValid = ($errors.Count -eq 0); Errors = @($errors) }
}

function Assert-XqManifest {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)]$TrustedSources, [switch]$Formal)
    $result = Test-XqManifest -Manifest $Manifest -TrustedSources $TrustedSources -Formal:$Formal
    if (-not $result.IsValid) { throw "Manifest validation failed: $($result.Errors -join ' ')" }
    return $Manifest
}

function Assert-XqDiscoveredManifestBinding {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][object[]]$DesktopAssets
    )
    $matchingCandidates = @($Candidates | Where-Object {
        [string](Get-XqProperty $_ 'tag') -ceq [string](Get-XqProperty $Manifest 'hermesReleaseTag')
    })
    if ($matchingCandidates.Count -ne 1) {
        throw 'The formal manifest tag does not identify exactly one lockable discovery candidate.'
    }
    $candidate = $matchingCandidates[0]
    if ([string](Get-XqProperty $candidate 'releaseCommit') -cne [string](Get-XqProperty $Manifest 'upstreamCommit')) {
        throw 'The formal manifest upstreamCommit does not match the discovered release tag commit.'
    }
    if ([string](Get-XqProperty $candidate 'hermesVersion') -cne [string](Get-XqProperty $Manifest 'hermesVersion')) {
        throw 'The formal manifest Hermes version does not match the discovered release tag version.'
    }
    $matchingAssets = @($DesktopAssets | Where-Object {
        [string](Get-XqProperty $_ 'url') -ceq [string](Get-XqProperty $Manifest 'officialAssetUrl')
    })
    if ($matchingAssets.Count -ne 1) {
        throw 'The formal manifest officialAssetUrl was not observed exactly once on the official Desktop product page.'
    }
    return $true
}

function Get-XqResponseHeader {
    param([Parameter(Mandatory)]$Response, [Parameter(Mandatory)][string]$Name)
    $headers = Get-XqProperty $Response 'Headers'
    if ($null -eq $headers) { return $null }
    if ($headers -is [System.Collections.IDictionary]) {
        foreach ($key in $headers.Keys) { if ([string]$key -ieq $Name) { return [string]$headers[$key] } }
    }
    $property = $headers.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($null -ne $property) { return [string]$property.Value }
    return $null
}

function Invoke-XqDefaultNetworkRequest {
    param([Parameter(Mandatory)]$Request)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    if ($null -ne (Get-XqProperty $Request 'TimeoutSeconds')) { $client.Timeout = [TimeSpan]::FromSeconds([int]$Request.TimeoutSeconds) }
    try {
        $message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, [uri]$Request.Uri)
        $message.Headers.TryAddWithoutValidation('User-Agent', 'xq-hermes-agent-windows-kit/1.0') | Out-Null
        $response = $client.Send($message, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        try {
            $headers = @{}
            foreach ($header in $response.Headers) { $headers[$header.Key] = ($header.Value -join ', ') }
            foreach ($header in $response.Content.Headers) { $headers[$header.Key] = ($header.Value -join ', ') }
            $maximumBytes = if ($null -eq (Get-XqProperty $Request 'MaximumBytes')) { 16777216L } else { [long]$Request.MaximumBytes }
            if ($response.Content.Headers.ContentLength -gt $maximumBytes) { throw "Response Content-Length exceeds configured limit of $maximumBytes bytes." }
            if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300 -and -not [string]::IsNullOrWhiteSpace([string](Get-XqProperty $Request 'OutFile'))) {
                $outFile = [string](Get-XqProperty $Request 'OutFile')
                $stream = $response.Content.ReadAsStream()
                $output = [IO.File]::Open($outFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $buffer = [byte[]]::new(131072); $total = 0L
                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $total += $read
                        if ($total -gt $maximumBytes) { throw "Response exceeds configured limit of $maximumBytes bytes." }
                        $output.Write($buffer, 0, $read)
                    }
                } finally { $output.Dispose(); $stream.Dispose() }
                [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Headers = $headers; ContentWritten = $true; ContentLength = $total }
            } else {
                $body = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                if ($body.LongLength -gt $maximumBytes) { throw "Response exceeds configured limit of $maximumBytes bytes." }
                [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Headers = $headers; ContentBytes = $body }
            }
        } finally { $response.Dispose() }
    } finally { $client.Dispose(); $handler.Dispose() }
}

function Invoke-XqHttpChain {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$TrustedSources,
        [Parameter(Mandatory)][string]$Purpose,
        [scriptblock]$NetworkInvoker,
        [ValidateRange(0, 8)][int]$MaximumRedirects = 5,
        [string]$OutFile,
        [ValidateRange(1024, 2147483647)][long]$MaximumBytes = 16777216,
        [ValidateRange(5, 3600)][int]$TimeoutSeconds = 120
    )
    if ($null -eq $NetworkInvoker) { $NetworkInvoker = ${function:Invoke-XqDefaultNetworkRequest} }
    $current = Assert-XqTrustedUri -Uri $Uri -TrustedSources $TrustedSources -Purpose $Purpose
    $chain = [System.Collections.Generic.List[string]]::new(); $chain.Add($current.AbsoluteUri)
    for ($hop = 0; $hop -le $MaximumRedirects; $hop++) {
        $response = & $NetworkInvoker ([pscustomobject]@{ Uri = $current.AbsoluteUri; Method = 'GET'; OutFile = $OutFile; MaximumBytes = $MaximumBytes; TimeoutSeconds = $TimeoutSeconds })
        if ($null -eq $response -or $null -eq (Get-XqProperty $response 'StatusCode')) { throw 'Network invoker returned no HTTP status.' }
        $status = [int](Get-XqProperty $response 'StatusCode')
        if ($status -ge 300 -and $status -lt 400) {
            if ($hop -eq $MaximumRedirects) { throw "Redirect limit ($MaximumRedirects) exceeded." }
            $location = Get-XqResponseHeader -Response $response -Name 'Location'
            if ([string]::IsNullOrWhiteSpace($location)) { throw 'Redirect response has no Location header.' }
            try { $next = [uri]::new($current, $location) } catch { throw "Redirect Location is invalid: $location" }
            $current = Assert-XqTrustedUri -Uri $next.AbsoluteUri -TrustedSources $TrustedSources -Purpose $Purpose
            $chain.Add($current.AbsoluteUri); continue
        }
        if ($status -lt 200 -or $status -ge 300) { throw "HTTP request failed with status $status." }
        return [pscustomobject]@{ RequestedUrl = $Uri; FinalUrl = $current.AbsoluteUri; Redirects = @($chain); Response = $response }
    }
    throw 'Unexpected redirect loop termination.'
}

function Test-XqAssetSourceProof {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)]$TrustedSources, [scriptblock]$NetworkInvoker)
    $page = Invoke-XqHttpChain -Uri ([string]$Manifest.sourcePageUrl) -TrustedSources $TrustedSources -Purpose 'source-page' -NetworkInvoker $NetworkInvoker
    $bytes = Get-XqProperty $page.Response 'ContentBytes'
    $content = Get-XqProperty $page.Response 'ContentText'
    if ($null -eq $content -and $null -ne $bytes) { $content = [Text.Encoding]::UTF8.GetString([byte[]]$bytes) }
    if ([string]::IsNullOrWhiteSpace([string]$content)) { throw 'Official source page returned no inspectable content.' }
    $decoded = [System.Net.WebUtility]::HtmlDecode([string]$content)
    if (-not $decoded.Contains([string]$Manifest.officialAssetUrl, [StringComparison]::Ordinal)) { throw 'Official source page does not prove the locked asset URL.' }
    return [pscustomobject]@{ SourcePage = $page.FinalUrl; AssetUrl = [string]$Manifest.officialAssetUrl; VerifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
}

function Test-XqLicenseSourceProof {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)]$TrustedSources, [scriptblock]$NetworkInvoker)
    $license = Invoke-XqHttpChain -Uri ([string]$Manifest.licenseUrl) -TrustedSources $TrustedSources -Purpose 'license' -NetworkInvoker $NetworkInvoker -MaximumBytes 1048576 -TimeoutSeconds 120
    if ([string]$license.FinalUrl -cne [string]$Manifest.licenseUrl) {
        throw 'The LICENSE request did not finish at the exact locked licenseUrl.'
    }
    $bytes = Get-XqProperty $license.Response 'ContentBytes'
    if ($null -eq $bytes) {
        $textValue = Get-XqProperty $license.Response 'ContentText'
        if ($null -eq $textValue) { throw 'The locked LICENSE response contained no inspectable content.' }
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$textValue)
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $actualHash = (($hasher.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $hasher.Dispose() }
    if ($actualHash -cne [string]$Manifest.licenseSha256) {
        throw 'The official LICENSE SHA-256 does not match the formal manifest.'
    }
    $licenseText = [Text.Encoding]::UTF8.GetString([byte[]]$bytes)
    if ($licenseText -notmatch '(?im)^MIT License\s*$' -or $licenseText -notmatch 'Permission is hereby granted') {
        throw 'The locked upstream LICENSE does not contain the expected MIT license markers.'
    }
    return [pscustomobject]@{ LicenseUrl = $license.FinalUrl; Sha256 = $actualHash; VerifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
}

function Test-XqPeFile {
    param([Parameter(Mandatory)][string]$Path, [ValidateRange(64, [int]::MaxValue)][int]$MinimumBytes = 1024)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.Length -lt $MinimumBytes) { throw "Artifact is too small to be an installer ($($item.Length) bytes)." }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadByte() -ne 0x4d -or $reader.ReadByte() -ne 0x5a) { throw 'Artifact does not begin with the MZ executable header.' }
        $stream.Position = 0x3c; $offset = $reader.ReadInt32()
        if ($offset -lt 0x40 -or $offset -gt ($item.Length - 4)) { throw 'Artifact has an invalid PE header offset.' }
        $stream.Position = $offset
        if ($reader.ReadByte() -ne 0x50 -or $reader.ReadByte() -ne 0x45 -or $reader.ReadByte() -ne 0 -or $reader.ReadByte() -ne 0) { throw 'Artifact does not contain a PE signature.' }
    } finally { $stream.Dispose() }
    return $true
}

function Get-XqArtifactHash {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Move-XqToQuarantine {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$CacheDirectory, [Parameter(Mandatory)][string]$AssetName)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $dir = Join-Path $CacheDirectory 'quarantine'; [IO.Directory]::CreateDirectory($dir) | Out-Null
    $target = Join-Path $dir ("{0}.{1}.partial" -f $AssetName, [guid]::NewGuid().ToString('N'))
    [IO.File]::Move($Path, $target)
    return $target
}

function Invoke-XqValidatedDownload {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$TrustedSources,
        [Parameter(Mandatory)][string]$CacheDirectory,
        [scriptblock]$NetworkInvoker,
        [string]$ReceiptPath,
        [ValidateRange(1048576, 2147483647)][long]$MaximumArtifactBytes = 1073741824,
        [ValidateRange(30, 3600)][int]$TimeoutSeconds = 1800
    )
    Assert-XqManifest -Manifest $Manifest -TrustedSources $TrustedSources -Formal | Out-Null
    Test-XqAssetSourceProof -Manifest $Manifest -TrustedSources $TrustedSources -NetworkInvoker $NetworkInvoker | Out-Null
    [IO.Directory]::CreateDirectory($CacheDirectory) | Out-Null
    $assetName = [string]$Manifest.officialAssetName; $target = Join-Path $CacheDirectory $assetName
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $existing = Get-XqArtifactHash -Path $target
        if ($existing -ne [string]$Manifest.officialSha256) {
            $quarantine = Move-XqToQuarantine -Path $target -CacheDirectory $CacheDirectory -AssetName $assetName
            throw "Existing cache artifact hash differs from the lock and was quarantined at '$quarantine'."
        }
        try { Test-XqPeFile -Path $target | Out-Null }
        catch {
            $quarantine = Move-XqToQuarantine -Path $target -CacheDirectory $CacheDirectory -AssetName $assetName
            throw "Existing cache artifact failed PE validation and was quarantined at '$quarantine'."
        }
        $receipt = [ordered]@{ status='REUSED'; receivedAtUtc=[DateTimeOffset]::UtcNow.ToString('o'); requestedUrl=[string]$Manifest.officialAssetUrl; finalUrl=[string]$Manifest.officialAssetUrl; redirects=@(); fileName=$assetName; cachePath=$target; contentLength=(Get-Item -LiteralPath $target).Length; sha256=$existing; etag=$null; lastModified=$null; tool='xq-hermes-agent-windows-kit PowerShell 7' }
    } else {
        $partial = Join-Path $CacheDirectory (".{0}.{1}.partial" -f $assetName, [guid]::NewGuid().ToString('N'))
        try {
            $download = Invoke-XqHttpChain -Uri ([string]$Manifest.officialAssetUrl) -TrustedSources $TrustedSources -Purpose 'official-asset' -NetworkInvoker $NetworkInvoker -OutFile $partial -MaximumBytes $MaximumArtifactBytes -TimeoutSeconds $TimeoutSeconds
            $lockedAssetUri = [uri][string]$Manifest.officialAssetUrl
            $finalAssetUri = [uri][string]$download.FinalUrl
            $finalName = [IO.Path]::GetFileName([uri]::UnescapeDataString($finalAssetUri.AbsolutePath))
            if ($finalName -cne $assetName) {
                throw 'The final download URL changed the locked installer file name.'
            }
            if ($finalAssetUri.Query -cne $lockedAssetUri.Query) {
                throw 'The final download URL changed or removed the locked Desktop build query.'
            }
            if (-not [bool](Get-XqProperty $download.Response 'ContentWritten')) {
                $body = Get-XqProperty $download.Response 'ContentBytes'
                if ($null -eq $body) { throw 'Download response did not contain binary content.' }
                if (([byte[]]$body).LongLength -gt $MaximumArtifactBytes) { throw "Download response exceeds configured limit of $MaximumArtifactBytes bytes." }
                [IO.File]::WriteAllBytes($partial, [byte[]]$body)
            }
            $hash = Get-XqArtifactHash -Path $partial
            if ($hash -ne [string]$Manifest.officialSha256) { $quarantine = Move-XqToQuarantine -Path $partial -CacheDirectory $CacheDirectory -AssetName $assetName; throw "SHA-256 mismatch; artifact quarantined at '$quarantine'." }
            Test-XqPeFile -Path $partial | Out-Null
            [IO.File]::Move($partial, $target)
            $receipt = [ordered]@{ status='DOWNLOADED'; receivedAtUtc=[DateTimeOffset]::UtcNow.ToString('o'); requestedUrl=$download.RequestedUrl; finalUrl=$download.FinalUrl; redirects=@($download.Redirects); fileName=$assetName; cachePath=$target; contentLength=(Get-Item -LiteralPath $target).Length; sha256=$hash; etag=(Get-XqResponseHeader -Response $download.Response -Name 'ETag'); lastModified=(Get-XqResponseHeader -Response $download.Response -Name 'Last-Modified'); tool='xq-hermes-agent-windows-kit PowerShell 7' }
        } catch {
            if (Test-Path -LiteralPath $partial) { Move-XqToQuarantine -Path $partial -CacheDirectory $CacheDirectory -AssetName $assetName | Out-Null }
            throw
        }
    }
    $object = [pscustomobject]$receipt
    if (-not [string]::IsNullOrWhiteSpace($ReceiptPath)) { Write-XqJsonAtomic -InputObject $object -Path $ReceiptPath }
    return $object
}

function Get-XqSignatureReport {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$ArtifactPath, [scriptblock]$SignatureProvider)
    if ($null -eq $SignatureProvider) { $SignatureProvider = { param($path) Get-AuthenticodeSignature -LiteralPath $path } }
    $signature = & $SignatureProvider $ArtifactPath
    if ($null -eq $signature) { throw 'Signature provider returned no result.' }
    $certificate = Get-XqProperty $signature 'SignerCertificate'
    $timestampCertificate = Get-XqProperty $signature 'TimeStamperCertificate'
    [pscustomobject]@{
        checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); artifactPath = $ArtifactPath; status = [string](Get-XqProperty $signature 'Status'); statusMessage = [string](Get-XqProperty $signature 'StatusMessage'); signerSubject = if ($null -eq $certificate) { $null } else { [string](Get-XqProperty $certificate 'Subject') }; signerThumbprint = if ($null -eq $certificate) { $null } else { [string](Get-XqProperty $certificate 'Thumbprint') }; timestampStatus = if ($null -eq $timestampCertificate) { 'Unavailable' } else { 'Valid' }; timestampSubject = if ($null -eq $timestampCertificate) { $null } else { [string](Get-XqProperty $timestampCertificate 'Subject') }; tool = 'Get-AuthenticodeSignature'
    }
}

function Assert-XqSignaturePolicy {
    param([Parameter(Mandatory)]$Report, [Parameter(Mandatory)]$Manifest)
    $bad = @('Invalid','HashMismatch','UnknownPublisher','NotTrusted','UnknownError')
    if ([string]$Report.status -in $bad) { throw "Unacceptable Authenticode status: $($Report.status)" }
    if ([string]$Manifest.signatureStatus -eq 'Valid') {
        if ([string]$Report.status -ne 'Valid') { throw "Expected a Valid Authenticode signature, got '$($Report.status)'." }
        if ([string]$Report.signerSubject -ne [string]$Manifest.signature.signerSubject) { throw 'Authenticode signer subject does not match the lock.' }
        if ([string]$Report.signerThumbprint -ine [string]$Manifest.signature.signerThumbprint) { throw 'Authenticode signer thumbprint does not match the lock.' }
    } elseif ([string]$Manifest.signatureStatus -eq 'Unavailable') {
        if ([string]::IsNullOrWhiteSpace([string]$Manifest.signature.waiverId)) { throw 'Unavailable signature has no explicit waiver.' }
        if ([string]$Report.status -notin @('NotSigned','Unavailable')) { throw "Unavailable signature policy does not accept '$($Report.status)'." }
    } else { throw 'Invalid signature policy in manifest.' }
    return $true
}

function Test-XqArtifactIdentity {
    param([Parameter(Mandatory)][string]$ArtifactPath, [Parameter(Mandatory)]$Manifest)
    if ([IO.Path]::GetFileName($ArtifactPath) -ne [string]$Manifest.officialAssetName) { throw 'Artifact file name does not match the manifest.' }
    Test-XqPeFile -Path $ArtifactPath | Out-Null
    $hash = Get-XqArtifactHash -Path $ArtifactPath
    if ($hash -ne [string]$Manifest.officialSha256) { throw 'Artifact SHA-256 does not match the manifest.' }
    return $hash
}

function Write-XqJsonAtomic {
    param([Parameter(Mandatory)]$InputObject, [Parameter(Mandatory)][string]$Path)
    $parent = Split-Path -Parent $Path; if ([string]::IsNullOrWhiteSpace($parent)) { throw 'Receipt path must include a parent directory.' }
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = Join-Path $parent (".{0}.{1}.partial" -f [IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    try {
        $json = $InputObject | ConvertTo-Json -Depth 16
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

Export-ModuleMember -Function Assert-XqPowerShell7,Read-XqJsonFile,Get-XqTrustedSources,Test-XqTrustedUri,Assert-XqTrustedUri,Test-XqManifest,Assert-XqManifest,Assert-XqDiscoveredManifestBinding,Invoke-XqHttpChain,Test-XqAssetSourceProof,Test-XqLicenseSourceProof,Invoke-XqValidatedDownload,Get-XqSignatureReport,Assert-XqSignaturePolicy,Test-XqArtifactIdentity,Get-XqArtifactHash,Test-XqPeFile,Write-XqJsonAtomic
