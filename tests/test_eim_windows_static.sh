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
require "ValidateSet\('DownloadVerified', 'InstallIdf', 'RunIdf'\)" fixed-actions
reject 'Invoke-Expression|(^|[^A-Za-z])iex([^A-Za-z]|$)' invoke-expression
reject 'Start-Process' start-process
reject '(^|[[:space:]])-Command([[:space:]]|$)' command-string-boundary
reject 'releases/latest/download' blind-latest-download
reject 'ignore-security-hash' hash-bypass

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

# Download must land in a random sibling temp and only then replace/move.
require '\[Guid\]::NewGuid\(\)' random-temp
require '\[IO\.File\]::Replace\(\$temporaryPath, \$fullOutputPath' atomic-replace
require '\[IO\.File\]::Move\(\$temporaryPath, \$fullOutputPath\)' atomic-first-install
require 'finally' cleanup-finally
require '\[IO\.File\]::Delete\(\$temporaryPath\)' cleanup-temp

# Privacy opt-out is a global option and must precede both EIM subcommands.
perl -0777 -ne '
  die "install opt-out missing\n"
    unless /eimArguments\s*=\s*@\(\s*['"'"']--do-not-track['"'"']\s*,\s*['"'"']true['"'"']\s*,\s*['"'"']install['"'"']/s;
  die "run opt-out missing\n"
    unless /eimArguments\s*=\s*@\(\s*['"'"']--do-not-track['"'"']\s*,\s*['"'"']true['"'"']\s*,\s*['"'"']run['"'"']/s;
' "$TARGET" || fail do-not-track-order

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
if rg -q 'releases/download/v[0-9]+\.[0-9]+\.[0-9]+' "$INSTALL"; then
  fail pinned-unverified-download
fi

echo 'PASS=eim-windows-static'
