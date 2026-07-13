#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL=identify-versions:$1" >&2; exit 1; }
pass() { echo "PASS=$1"; }

cp "$ROOT/scripts/identify-device.sh" "$TMP/identify-device.sh"
cat >"$TMP/idf-env.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'esptool version'*) printf '%s\n' 'Python 3.13.9' 'dependency 99.1' "esptool.py v${ESPTOOL_FIXTURE_VERSION}" ;;
  *'chip_id'*) printf '%s\n' 'Chip is ESP32-S3 (revision v0.2)' 'MAC: aa:bb:cc:dd:ee:ff' ;;
  *'chip-id'*)
    if [ "${ESPTOOL_FIXTURE_KIND}" = v5 ]; then
      printf '%s\n' 'Chip type:          ESP32-C6 (QFN40) (revision v0.1)' 'MAC:                 11:22:33:44:55:66'
    else
      printf '%s\n' 'Connected to an unsupported mystery device' 'MAC: 11:22:33:44:55:66'
    fi ;;
  *) exit 90 ;;
esac
SH
chmod +x "$TMP/idf-env.sh"

OUT="$(ESPTOOL_FIXTURE_VERSION=4.12.0 ESPTOOL_FIXTURE_KIND=v4 \
  bash "$TMP/identify-device.sh" -p /dev/tty.fixture)" || fail v4-rc
printf '%s\n' "$OUT" | grep -Fqx 'CHIP=ESP32-S3' || fail v4-chip
printf '%s\n' "$OUT" | grep -Fqx 'MAC=AA:BB:CC:DD:EE:FF' || fail v4-mac
pass esptool-v4-identity

OUT="$(ESPTOOL_FIXTURE_VERSION=5.1.0 ESPTOOL_FIXTURE_KIND=v5 \
  bash "$TMP/identify-device.sh" -p COM7)" || fail v5-rc
printf '%s\n' "$OUT" | grep -Fqx 'CHIP=ESP32-C6' || fail v5-chip
printf '%s\n' "$OUT" | grep -Fqx 'MAC=11:22:33:44:55:66' || fail v5-mac
pass esptool-v5-identity

set +e
OUT="$(ESPTOOL_FIXTURE_VERSION=5.1.0 ESPTOOL_FIXTURE_KIND=unknown \
  bash "$TMP/identify-device.sh" -p COM8 2>&1)"
RC=$?
set -e
[ "$RC" -eq 5 ] || fail "unknown-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -Fqx 'CHIP=unknown' || fail unknown-chip
printf '%s\n' "$OUT" | grep -q '拒绝把不完整身份当作成功' || fail unknown-message
pass esptool-unknown-fail-closed

cat >"$TMP/idf-env.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'esptool version'*) printf '%s\n' 'Python 3.13.9' 'version unavailable' ;;
  *) exit 90 ;;
esac
SH
chmod +x "$TMP/idf-env.sh"
set +e
OUT="$(bash "$TMP/identify-device.sh" -p COM9 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "unparseable-version-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '拒绝猜测命令格式' || fail unparseable-version-message
pass esptool-version-parser-ignores-unrelated-numbers

echo PASS=all-identify-versions
