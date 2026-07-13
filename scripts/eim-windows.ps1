# esp-idf-cy · Windows EIM security boundary.
#
# This helper is intentionally action-based. Git Bash passes data as arguments;
# PowerShell owns release discovery, trust verification, and native EIM execution.
# Keep native execution on the call operator with an explicit argument array.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('CheckPlatform', 'DownloadVerified', 'InstallIdf', 'FixIdf', 'RunIdf')]
    [string] $Action,

    [string] $EimPath,
    [string] $Destination,
    [string] $Version,

    [string] $IdfVersion,
    [string] $Targets = 'all',
    [string] $Mirror,
    [string] $IdfMirror,
    [string] $PypiMirror,
    [string] $EspIdfJsonPath,

    [string] $IdfPath,
    [string] $RunnerPath,
    [string] $ArgvFile,
    [AllowEmptyCollection()]
    [AllowEmptyString()]
    [string[]] $CommandArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InitialBoundParameters = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $InitialBoundParameters[$entry.Key] = $entry.Value
}

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

function Assert-WindowsX64 {
    # An x64 process emulated on Windows ARM64 can report virtual AMD64 through
    # PROCESSOR_ARCHITECTURE. IsWow64Process2 returns the native machine type,
    # so the decision cannot be bypassed by that compatibility view.
    if ($null -eq ('EspIdfCy.NativeMachine' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace EspIdfCy {
  public static class NativeMachine {
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWow64Process2(
      IntPtr process, out ushort processMachine, out ushort nativeMachine);
  }
}
'@
        }
        catch {
            Fail "Unable to load native architecture probe: $($_.Exception.Message)" 8
        }
    }

    [UInt16] $processMachine = 0
    [UInt16] $nativeMachine = 0
    $handle = [Diagnostics.Process]::GetCurrentProcess().Handle
    if (-not [EspIdfCy.NativeMachine]::IsWow64Process2(
        $handle, [ref] $processMachine, [ref] $nativeMachine)) {
        $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Fail "Unable to determine native Windows architecture (Win32=$nativeError)" 8
    }

    # IMAGE_FILE_MACHINE_AMD64 = 0x8664; ARM64 = 0xAA64; I386 = 0x014c.
    if ($nativeMachine -ne 0x8664) {
        $environmentHint = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
            [string] $env:PROCESSOR_ARCHITEW6432
        }
        else {
            [string] $env:PROCESSOR_ARCHITECTURE
        }
        Fail ("EIM CLI fallback supports native Windows x64 only; " +
            "nativeMachine=0x{0:X4} environment={1}" -f $nativeMachine, $environmentHint) 8
    }
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

function Get-EimGlobalArguments {
    $arguments = @('--do-not-track', 'true')
    if (-not [string]::IsNullOrWhiteSpace($EspIdfJsonPath)) {
        Assert-NoLineBreak -Name 'EspIdfJsonPath' -Value $EspIdfJsonPath
        $arguments += @('--esp-idf-json-path', $EspIdfJsonPath)
    }
    return $arguments
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

    Assert-WindowsX64
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
    Assert-WindowsX64
    if ([string]::IsNullOrWhiteSpace($EimPath) -or
        [string]::IsNullOrWhiteSpace($IdfVersion)) {
        Fail 'InstallIdf requires -EimPath and -IdfVersion' 64
    }
    Assert-NoLineBreak -Name 'IdfVersion' -Value $IdfVersion
    Assert-NoLineBreak -Name 'Targets' -Value $Targets

    $trustedEim = Resolve-TrustedEim -Path $EimPath
    $eimArguments = @(Get-EimGlobalArguments)
    $eimArguments += @(
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

function Add-RepairMirrorArguments {
    param([object[]] $Arguments)

    $result = @($Arguments)
    if (-not [string]::IsNullOrWhiteSpace($Mirror)) {
        Assert-HttpsUri -Name 'Mirror' -Value $Mirror
        $result += @('--mirror', $Mirror)
    }
    if (-not [string]::IsNullOrWhiteSpace($IdfMirror)) {
        Assert-HttpsUri -Name 'IdfMirror' -Value $IdfMirror
        $result += @('--idf-mirror', $IdfMirror)
    }
    if (-not [string]::IsNullOrWhiteSpace($PypiMirror)) {
        Assert-HttpsUri -Name 'PypiMirror' -Value $PypiMirror
        $result += @('--pypi-mirror', $PypiMirror)
    }
    return $result
}

function Fix-IdfWithEim {
    Assert-WindowsX64
    if ([string]::IsNullOrWhiteSpace($EimPath) -or
        [string]::IsNullOrWhiteSpace($IdfPath)) {
        Fail 'FixIdf requires -EimPath and -IdfPath' 64
    }
    Assert-NoLineBreak -Name 'IdfPath' -Value $IdfPath

    $trustedEim = Resolve-TrustedEim -Path $EimPath
    $eimArguments = @(Get-EimGlobalArguments)
    $eimArguments += @(
        'fix',
        '-p', $IdfPath
    )
    # Omitting target/mirror options preserves the installation's recorded
    # configuration.  Only an explicit caller override is forwarded.
    if ($InitialBoundParameters.ContainsKey('Targets') -and
        -not [string]::IsNullOrWhiteSpace($Targets)) {
        Assert-NoLineBreak -Name 'Targets' -Value $Targets
        $eimArguments += @('-t', $Targets)
    }
    $eimArguments = Add-RepairMirrorArguments -Arguments $eimArguments

    & $trustedEim @eimArguments
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
    exit ([int] $exitCode)
}

function New-RestrictedArgvPayload {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]] $Payload
    )

    $directory = Join-Path ([IO.Path]::GetTempPath()) ('esp-idf-cy-argv-' + [Guid]::NewGuid().ToString('N'))
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetOwner($identity)
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $identity,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void] $security.AddAccessRule($rule)

    try {
        # Windows PowerShell/.NET Framework can apply the ACL atomically.
        [void] [IO.Directory]::CreateDirectory($directory, $security)
    }
    catch [Management.Automation.MethodException] {
        # PowerShell 7 uses FileSystemAclExtensions instead of that overload.
        $directoryInfo = [IO.Directory]::CreateDirectory($directory)
        [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $security)
    }

    $payloadPath = Join-Path $directory 'argv.bin'
    try {
        [IO.File]::WriteAllBytes($payloadPath, $Payload)
    }
    catch {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    return [PSCustomObject]@{ Path = $payloadPath; Directory = $directory }
}

function New-RestrictedArgvFile {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Arguments
    )

    if ($null -eq $Arguments -or $Arguments.Count -eq 0 -or
        [string]::IsNullOrEmpty($Arguments[0])) {
        Fail 'CommandArgs must contain a non-empty command name' 64
    }

    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $stream = [IO.MemoryStream]::new()
    try {
        foreach ($argument in $Arguments) {
            if ($null -eq $argument) { $argument = '' }
            $bytes = $utf8.GetBytes([string] $argument)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.WriteByte(0)
        }
        $payload = $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }

    $createdPayload = New-RestrictedArgvPayload -Payload $payload
    return $createdPayload
}

function Resolve-ArgvFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "argv payload does not exist: $Path" 64
    }
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    $payload = [IO.File]::ReadAllBytes($resolved)
    if ($payload.Length -eq 0 -or $payload.Length -gt (4 * 1024 * 1024) -or
        $payload[$payload.Length - 1] -ne 0 -or $payload[0] -eq 0) {
        Fail 'argv payload is empty, oversized, malformed, or has no command' 64
    }
    try {
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        [void] $strictUtf8.GetString($payload)
    }
    catch [Text.DecoderFallbackException] {
        Fail 'argv payload is not valid UTF-8' 64
    }
    return [PSCustomObject]@{ Path = $resolved; Payload = $payload }
}

function Run-IdfWithEim {
    Assert-WindowsX64
    if ([string]::IsNullOrWhiteSpace($EimPath) -or
        [string]::IsNullOrWhiteSpace($IdfPath) -or
        [string]::IsNullOrWhiteSpace($RunnerPath)) {
        Fail 'RunIdf requires -EimPath, -IdfPath, -RunnerPath, and argv data' 64
    }
    if ($InitialBoundParameters.ContainsKey('ArgvFile') -and
        $InitialBoundParameters.ContainsKey('CommandArgs')) {
        Fail 'RunIdf accepts either -ArgvFile or -CommandArgs, not both' 64
    }

    Assert-NoLineBreak -Name 'IdfPath' -Value $IdfPath
    if (-not (Test-Path -LiteralPath $RunnerPath -PathType Leaf)) {
        Fail "argv runner does not exist: $RunnerPath" 64
    }
    # Verify trust before creating/copying any payload. Fail() exits the script,
    # so doing this later would bypass cleanup for PowerShell-native CommandArgs.
    $trustedEim = Resolve-TrustedEim -Path $EimPath
    $globalArguments = @(Get-EimGlobalArguments)
    $resolvedRunner = (Resolve-Path -LiteralPath $RunnerPath).ProviderPath
    $ownedDirectory = $null
    $inputArgv = $null
    if ($InitialBoundParameters.ContainsKey('CommandArgs')) {
        $createdPayload = New-RestrictedArgvFile -Arguments $CommandArgs
        $resolvedArgv = $createdPayload.Path
        $ownedDirectory = $createdPayload.Directory
    }
    elseif ($InitialBoundParameters.ContainsKey('ArgvFile') -and
        -not [string]::IsNullOrWhiteSpace($ArgvFile)) {
        # Git Bash chmod/umask cannot prove a native Windows ACL. Validate the
        # incoming bytes, then copy them into the same current-user-only ACL
        # container used by the PowerShell-native CommandArgs route.
        $incomingPayload = Resolve-ArgvFile -Path $ArgvFile
        $inputArgv = $incomingPayload.Path
        $createdPayload = New-RestrictedArgvPayload -Payload $incomingPayload.Payload
        $resolvedArgv = $createdPayload.Path
        $ownedDirectory = $createdPayload.Directory
        Remove-Item -LiteralPath $inputArgv -Force -ErrorAction SilentlyContinue
    }
    else {
        Fail 'RunIdf requires -ArgvFile or -CommandArgs' 64
    }

    # The inner command is a fixed PowerShell program.  Environment values are
    # passed as individual arguments by PowerShell and are never parsed as code.
    $fixedLauncher = '& python $env:ESP_IDF_CY_RUNNER $env:ESP_IDF_CY_ARGV_FILE'
    $eimArguments = @($globalArguments)
    $eimArguments += @(
        'run',
        $fixedLauncher,
        $IdfPath
    )

    $oldRunner = [Environment]::GetEnvironmentVariable('ESP_IDF_CY_RUNNER', 'Process')
    $oldArgv = [Environment]::GetEnvironmentVariable('ESP_IDF_CY_ARGV_FILE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('ESP_IDF_CY_RUNNER', $resolvedRunner, 'Process')
        [Environment]::SetEnvironmentVariable('ESP_IDF_CY_ARGV_FILE', $resolvedArgv, 'Process')
        & $trustedEim @eimArguments
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
    }
    finally {
        [Environment]::SetEnvironmentVariable('ESP_IDF_CY_RUNNER', $oldRunner, 'Process')
        [Environment]::SetEnvironmentVariable('ESP_IDF_CY_ARGV_FILE', $oldArgv, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($inputArgv)) {
            Remove-Item -LiteralPath $inputArgv -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $resolvedArgv -Force -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($ownedDirectory)) {
            Remove-Item -LiteralPath $ownedDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    exit ([int] $exitCode)
}

switch ($Action) {
    'CheckPlatform' {
        Assert-WindowsX64
        Write-Output 'WINDOWS_ARCHITECTURE=x64'
        break
    }
    'DownloadVerified' {
        Download-VerifiedEim -OutputPath $Destination -RequestedVersion $Version
        break
    }
    'InstallIdf' {
        Install-IdfWithEim
        break
    }
    'FixIdf' {
        Fix-IdfWithEim
        break
    }
    'RunIdf' {
        Run-IdfWithEim
        break
    }
}
