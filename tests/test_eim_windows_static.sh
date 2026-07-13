#!/usr/bin/env bash
# Static security gates for eim-windows.ps1. Runs on macOS without PowerShell.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/scripts/eim-windows.ps1"
INSTALL="$ROOT/scripts/install.sh"
WRAPPER="$ROOT/scripts/idf-env.sh"

fail() {
  echo "FAIL=eim-windows-static:$1" >&2
  exit 1
}

require() {
  local pattern="$1" label="$2"
  rg -q -- "$pattern" "$TARGET" || fail "missing-$label"
}

reject() {
  local pattern="$1" label="$2"
  if rg -qi -- "$pattern" "$TARGET"; then
    fail "forbidden-$label"
  fi
}

[ -f "$TARGET" ] || fail missing-helper

# Fixed action surface; no dynamic PowerShell evaluation or detached process.
require "ValidateSet\('CheckPlatform', 'DownloadVerified', 'InstallIdf', 'FixIdf', 'RunIdf'\)" fixed-actions
reject 'Invoke-Expression|(^|[^A-Za-z])iex([^A-Za-z]|$)' invoke-expression
reject 'Start-Process' start-process
reject '(^|[[:space:]])-Command([[:space:]]|$)' command-string-boundary
reject 'CommandString' arbitrary-eim-command-string
reject 'releases/latest/download' blind-latest-download
reject 'ignore-security-hash' hash-bypass

# Windows x64 is the only published EIM CLI fallback; do not silently run its
# asset on ARM64/x86. RunIdf accepts structured argv only, then gives EIM one
# fixed PowerShell launcher using the call operator and environment arguments.
require 'IsWow64Process2' native-os-architecture
require '0x8664' x64-only
require '0xAA64' arm64-machine-constant
require '\[string\[\]\] \$CommandArgs' command-args-array
require '\[string\] \$ArgvFile' argv-file
require '\[string\] \$RunnerPath' runner-path
require '\$fixedLauncher = .& python \$env:ESP_IDF_CY_RUNNER \$env:ESP_IDF_CY_ARGV_FILE.' fixed-launcher
require 'ESP_IDF_CY_ARGV_FILE' argv-env-boundary
require 'WriteByte\(0\)' nul-separated-payload
require 'SetAccessRuleProtection\(\$true, \$false\)' restricted-payload-acl
require 'New-RestrictedArgvPayload -Payload \$incomingPayload.Payload' copied-into-native-acl
require "'CheckPlatform'" platform-action

# Latest/exact-tag discovery must consume the structured GitHub asset digest.
require 'api\.github\.com/repos/\$Repository/releases' github-release-api
require 'ReleaseApiBase/latest' latest-endpoint
require 'ReleaseApiBase/tags/\$RequestedVersion' exact-tag-endpoint
require '\$assets\.Count -ne 1' unique-asset
require '\$asset\.digest' asset-digest
require '\^sha256:\(\[0-9a-fA-F\]\{64\}\)\$' sha256-digest-shape
require 'Get-FileHash -LiteralPath \$temporaryPath -Algorithm SHA256' local-sha256

# Authenticode must be valid and identify Espressif before execution/install.
require 'Get-AuthenticodeSignature -LiteralPath' authenticode
require 'SignatureStatus\]::Valid' valid-status
require "\(CN\|O\).*Espressif" espressif-signer
require 'Get-EspressifSignature -LiteralPath \$temporaryPath' verify-download-signature
require 'Resolve-TrustedEim -Path \$EimPath' verify-existing-eim
python3 - "$TARGET" <<'PY' || fail trust-before-payload
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
run = text.index("function Run-IdfWithEim")
trust = text.index("$trustedEim = Resolve-TrustedEim -Path $EimPath", run)
global_args = text.index("$globalArguments = @(Get-EimGlobalArguments)", run)
payload = text.index("New-RestrictedArgvFile -Arguments $CommandArgs", run)
if trust >= payload or global_args >= payload:
    raise SystemExit("all failing validation must precede sensitive payload creation")
PY

# Download must land in a random sibling temp and only then replace/move.
require '\[Guid\]::NewGuid\(\)' random-temp
require '\[IO\.File\]::Replace\(\$temporaryPath, \$fullOutputPath' atomic-replace
require '\[IO\.File\]::Move\(\$temporaryPath, \$fullOutputPath\)' atomic-first-install
require 'finally' cleanup-finally
require '\[IO\.File\]::Delete\(\$temporaryPath\)' cleanup-temp

# Privacy opt-out and custom registry are global options assembled before every
# EIM subcommand; install/fix/run must all use the same registry identity.
require 'function Get-EimGlobalArguments' global-argument-builder
require "'--do-not-track', 'true'" global-privacy-option
require "'--esp-idf-json-path'" custom-registry-option
perl -0777 -ne '
  die "install opt-out missing\n"
    unless /Install-IdfWithEim[\s\S]*?eimArguments\s*=\s*@\(Get-EimGlobalArguments\)[\s\S]*?eimArguments\s*\+=\s*@\(\s*['"'"']install['"'"']/s;
  die "run opt-out missing\n"
    unless /Run-IdfWithEim[\s\S]*?globalArguments\s*=\s*@\(Get-EimGlobalArguments\)[\s\S]*?eimArguments\s*=\s*@\(\$globalArguments\)[\s\S]*?eimArguments\s*\+=\s*@\(\s*['"'"']run['"'"']/s;
  die "fix opt-out missing\n"
    unless /Fix-IdfWithEim[\s\S]*?eimArguments\s*=\s*@\(Get-EimGlobalArguments\)[\s\S]*?eimArguments\s*\+=\s*@\(\s*['"'"']fix['"'"']/s;
' "$TARGET" || fail do-not-track-order

# Repair is a fixed argv action. If target/mirror overrides are omitted, EIM
# retains the installation's recorded configuration.
require "'fix'" fix-action
rg -Fq "'-p', \$IdfPath" "$TARGET" || fail missing-exact-fix-path
require "InitialBoundParameters.ContainsKey\('Targets'\)" optional-fix-target

# Native execution uses the call operator with an argv array and propagates rc.
require '& \$trustedEim @eimArguments' argv-call-operator
require '\$exitCode = \$LASTEXITCODE' exit-code-capture
require 'exit \(\[int\] \$exitCode\)' exit-code-propagation

# Bash 入口必须真的走这条安全边界；winget 也固定包、源、用户 scope 和非交互参数。
rg -Fq 'ps_file "$helper_win" "${dl_args[@]}"' "$INSTALL" || fail missing-download-integration
rg -Fq 'ps_file "$helper_win" "${args[@]}"' "$INSTALL" || fail missing-install-integration
rg -q -- '--exact --source winget --scope user --silent --disable-interactivity' "$INSTALL" \
  || fail weak-winget-integration
rg -Fq 'ps_file "$EIM_HELPER_WIN" RunIdf' "$WRAPPER" || fail missing-run-integration
rg -Fq -- '-EspIdfJsonPath "$EIM_JSON_DIR_WIN"' "$WRAPPER" || fail missing-run-registry-propagation
rg -Fq 'ps_file "$PLATFORM_HELPER" CheckPlatform' "$INSTALL" || fail missing-pre-mutation-platform-gate
python3 - "$INSTALL" <<'PY' || fail platform-gate-order
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
gate = text.index('ps_file "$PLATFORM_HELPER" CheckPlatform')
winget = text.index('winget install --id Espressif.EIM-CLI')
if gate >= winget:
    raise SystemExit("architecture gate must precede winget mutation")
PY
if rg -q 'releases/download/v[0-9]+\.[0-9]+\.[0-9]+' "$INSTALL"; then
  fail pinned-unverified-download
fi

echo 'PASS=eim-windows-static'
