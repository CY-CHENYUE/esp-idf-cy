# esp-idf-cy · Windows EIM security boundary.
#
# This helper is intentionally action-based. Git Bash passes data as arguments;
# PowerShell owns release discovery, trust verification, and native EIM execution.
# Keep native execution on the call operator with an explicit argument array.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('DownloadVerified', 'InstallIdf', 'RunIdf')]
    [string] $Action,

    [string] $EimPath,
    [string] $Destination,
    [string] $Version,

    [string] $IdfVersion,
    [string] $Targets = 'all',
    [string] $Mirror,
    [string] $IdfMirror,
    [string] $PypiMirror,

    [string] $CommandString,
    [string] $IdfPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Repository = 'espressif/idf-im-ui'
$AssetName = 'eim-cli-windows-x64.exe'
$ReleaseApiBase = "https://api.github.com/repos/$Repository/releases"
$ExpectedDownloadBase = "https://github.com/$Repository/releases/download/"
$GitHubHeaders = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'esp-idf-cy'
    'X-GitHub-Api-Version' = '2022-11-28'
}

function Fail {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,
        [int] $Code = 1
    )

    [Console]::Error.WriteLine("ERROR=$Message")
    exit $Code
}

function Assert-NoLineBreak {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ($Value.IndexOf("`r", [StringComparison]::Ordinal) -ge 0 -or
        $Value.IndexOf("`n", [StringComparison]::Ordinal) -ge 0) {
        Fail "$Name contains a line break" 64
    }
}

function Assert-HttpsUri {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    [Uri] $parsed = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $parsed) -or
        $parsed.Scheme -cne 'https') {
        Fail "$Name must be an absolute HTTPS URL" 64
    }
}

function Get-EspressifSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string] $LiteralPath
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $LiteralPath
    if ($null -eq $signature -or $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        $status = if ($null -eq $signature) { 'Missing' } else { [string] $signature.Status }
        Fail "EIM Authenticode signature is not valid: $status" 9
    }
    if ($null -eq $signature.SignerCertificate) {
        Fail 'EIM Authenticode signer certificate is missing' 9
    }

    $subject = [string] $signature.SignerCertificate.Subject
    # Certificate formatting can vary (CN/O order and quoting), so bind to a
    # certificate identity field containing Espressif instead of a rotating
    # thumbprint. The GitHub release digest independently binds exact content.
    if ($subject -notmatch '(?i)(^|,\s*)(CN|O)\s*=\s*[^,]*Espressif') {
        Fail "EIM Authenticode signer is not Espressif: $subject" 9
    }

    return $signature
}

function Resolve-TrustedEim {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "EIM binary does not exist: $Path" 2
    }
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    [void] (Get-EspressifSignature -LiteralPath $resolved)
    return $resolved
}

function Get-ReleaseMetadata {
    param([string] $RequestedVersion)

    if ([string]::IsNullOrWhiteSpace($RequestedVersion)) {
        $uri = "$ReleaseApiBase/latest"
    }
    else {
        if ($RequestedVersion -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
            Fail "EIM version must be an exact v<major>.<minor>.<patch> tag: $RequestedVersion" 64
        }
        $uri = "$ReleaseApiBase/tags/$RequestedVersion"
    }

    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers $GitHubHeaders
    }
    catch {
        Fail "GitHub release metadata request failed: $($_.Exception.Message)" 6
    }
}

function Download-VerifiedEim {
    param(
        [Parameter(Mandatory = $true)]
        [string] $OutputPath,
        [string] $RequestedVersion
    )

    $release = Get-ReleaseMetadata -RequestedVersion $RequestedVersion
    if ($release.draft -eq $true -or $release.prerelease -eq $true) {
        Fail 'Refusing draft or prerelease EIM release' 6
    }

    $tag = [string] $release.tag_name
    if ($tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
        Fail "GitHub returned an invalid EIM release tag: $tag" 6
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion) -and $tag -cne $RequestedVersion) {
        Fail "GitHub release tag mismatch: requested=$RequestedVersion returned=$tag" 6
    }

    $assets = @($release.assets | Where-Object { ([string] $_.name) -ceq $AssetName })
    if ($assets.Count -ne 1) {
        Fail "Expected exactly one $AssetName asset; found $($assets.Count)" 6
    }
    $asset = $assets[0]

    $digest = [string] $asset.digest
    if ($digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
        Fail "GitHub release asset has no usable SHA256 digest: $digest" 6
    }
    $expectedHash = $Matches[1].ToUpperInvariant()

    $downloadUrl = [string] $asset.browser_download_url
    $expectedPrefix = "$ExpectedDownloadBase$tag/"
    if (-not $downloadUrl.StartsWith($expectedPrefix, [StringComparison]::Ordinal) -or
        -not $downloadUrl.EndsWith("/$AssetName", [StringComparison]::Ordinal)) {
        Fail "Unexpected EIM release asset URL: $downloadUrl" 6
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Fail 'DownloadVerified requires -Destination' 64
    }
    $fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = [IO.Path]::GetDirectoryName($fullOutputPath)
    if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
        Fail "Cannot determine destination directory: $OutputPath" 64
    }
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

    # Keep the temporary file on the destination volume so File.Replace/Move
    # never degrades into an untrusted cross-volume copy.
    $temporaryPath = Join-Path $outputDirectory ('.eim-download-' + [Guid]::NewGuid().ToString('N') + '.tmp.exe')
    $installed = $false
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $temporaryPath

        $actualHash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -cne $expectedHash) {
            Fail "EIM SHA256 mismatch: expected=$expectedHash actual=$actualHash" 9
        }

        $signature = Get-EspressifSignature -LiteralPath $temporaryPath
        $signerSubject = [string] $signature.SignerCertificate.Subject
        $signerThumbprint = [string] $signature.SignerCertificate.Thumbprint

        # Execute only after both independent trust checks have passed.
        $versionOutput = @(& $temporaryPath --version 2>&1)
        $versionExitCode = $LASTEXITCODE
        if ($versionExitCode -ne 0) {
            Fail "Verified EIM binary failed --version with rc=$versionExitCode" 9
        }

        if ([IO.File]::Exists($fullOutputPath)) {
            [IO.File]::Replace($temporaryPath, $fullOutputPath, $null, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $fullOutputPath)
        }
        $installed = $true

        Write-Output "EIM_BIN=$fullOutputPath"
        Write-Output "EIM_RELEASE=$tag"
        Write-Output "EIM_SHA256=$actualHash"
        Write-Output "EIM_SIGNER=$signerSubject"
        Write-Output "EIM_SIGNER_THUMBPRINT=$signerThumbprint"
        if ($versionOutput.Count -gt 0) {
            Write-Output "EIM_VERSION_OUTPUT=$($versionOutput[0])"
        }
    }
    finally {
        if (-not $installed -and [IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

function Install-IdfWithEim {
    if ([string]::IsNullOrWhiteSpace($EimPath) -or
        [string]::IsNullOrWhiteSpace($IdfVersion)) {
        Fail 'InstallIdf requires -EimPath and -IdfVersion' 64
    }
    Assert-NoLineBreak -Name 'IdfVersion' -Value $IdfVersion
    Assert-NoLineBreak -Name 'Targets' -Value $Targets

    $trustedEim = Resolve-TrustedEim -Path $EimPath
    $eimArguments = @(
        '--do-not-track', 'true',
        'install',
        '-i', $IdfVersion,
        '-t', $Targets,
        '-a', 'true',
        '--cleanup', 'true'
    )

    if (-not [string]::IsNullOrWhiteSpace($Mirror)) {
        Assert-HttpsUri -Name 'Mirror' -Value $Mirror
        $eimArguments += @('--mirror', $Mirror)
    }
    if (-not [string]::IsNullOrWhiteSpace($IdfMirror)) {
        Assert-HttpsUri -Name 'IdfMirror' -Value $IdfMirror
        $eimArguments += @('--idf-mirror', $IdfMirror)
    }
    if (-not [string]::IsNullOrWhiteSpace($PypiMirror)) {
        Assert-HttpsUri -Name 'PypiMirror' -Value $PypiMirror
        $eimArguments += @('--pypi-mirror', $PypiMirror)
    }

    & $trustedEim @eimArguments
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
    exit ([int] $exitCode)
}

function Run-IdfWithEim {
    if ([string]::IsNullOrWhiteSpace($EimPath) -or
        [string]::IsNullOrWhiteSpace($CommandString) -or
        [string]::IsNullOrWhiteSpace($IdfPath)) {
        Fail 'RunIdf requires -EimPath, -CommandString, and -IdfPath' 64
    }
    Assert-NoLineBreak -Name 'CommandString' -Value $CommandString
    Assert-NoLineBreak -Name 'IdfPath' -Value $IdfPath

    $trustedEim = Resolve-TrustedEim -Path $EimPath
    $eimArguments = @(
        '--do-not-track', 'true',
        'run',
        $CommandString,
        $IdfPath
    )

    & $trustedEim @eimArguments
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
    exit ([int] $exitCode)
}

switch ($Action) {
    'DownloadVerified' {
        Download-VerifiedEim -OutputPath $Destination -RequestedVersion $Version
        break
    }
    'InstallIdf' {
        Install-IdfWithEim
        break
    }
    'RunIdf' {
        Run-IdfWithEim
        break
    }
}
