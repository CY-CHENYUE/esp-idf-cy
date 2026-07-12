#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "PASS=$1"; }
fail() { echo "FAIL=$1" >&2; exit 1; }

expect_rc() {
  expected="$1"; shift
  set +e
  OUT="$("$@" 2>&1)"
  RC=$?
  set -e
  [ "$RC" -eq "$expected" ] || fail "rc expected=$expected actual=$RC command=$* output=$OUT"
}

for script in wait-port.sh identify-device.sh monitor.sh; do
  bash -n "$ROOT/scripts/$script" || fail "bash-n:$script"
done
PYTHONPYCACHEPREFIX="$TMP/pycache" python3 -m py_compile "$ROOT/scripts/serial_monitor.py" || fail python-syntax
pass syntax

# wait-port:缺值/非法数值必须稳定 rc=64,零超时必须立即有界退出。
PORTS_FILE="$TMP/no-ports"
: >"$PORTS_FILE"
for args in '-t' '-i' '-p' '-p -t' '-t -1' '-t abc' '-t 1.5' '-t 9999999999' '-i 0' '-i -1' '-i abc' '-i 9999999999'; do
  # shellcheck disable=SC2086
  expect_rc 64 env ESP_IDF_CY_PORTS_FILE="$PORTS_FILE" bash "$ROOT/scripts/wait-port.sh" $args
done
expect_rc 1 env ESP_IDF_CY_PORTS_FILE="$PORTS_FILE" bash "$ROOT/scripts/wait-port.sh" -t 0 -i 1
printf '%s\n' "$OUT" | grep -q '^TIMEOUT=yes' || fail wait-zero-timeout-output
pass wait-port-boundaries

# identify:缺端口是 usage;即使读到 MAC,解析不到芯片也不能成功。
expect_rc 64 bash "$ROOT/scripts/identify-device.sh" -p
mkdir -p "$TMP/idf/tools" "$TMP/bin"
: >"$TMP/idf/tools/idf.py"
printf '%s\n' '#!/usr/bin/env bash' 'export PATH="$ESP_IDF_CY_TEST_BIN:$PATH"' >"$TMP/idf/export.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  *"esptool version"*) echo "esptool.py v4.12" ;;' \
  '  *"chip_id"*) echo "MAC: 7c:df:a1:12:34:56" ;;' \
  '  *) exit 9 ;;' \
  'esac' >"$TMP/bin/python"
chmod +x "$TMP/bin/python"
expect_rc 5 env ESP_IDF_CY_IDF_PATH="$TMP/idf" ESP_IDF_CY_TEST_BIN="$TMP/bin" \
  bash "$ROOT/scripts/identify-device.sh" -p /dev/ttyFIXTURE
printf '%s\n' "$OUT" | grep -q '^CHIP=unknown$' || fail identify-unknown-marker
pass identify-boundaries

# 自包含 fake pyserial:覆盖打开失败、读取失败、expect 超时、零数据成功和统计输出。
mkdir -p "$TMP/fake-serial"
printf '%s\n' \
  'class SerialException(Exception): pass' \
  'class SerialBase: pass' \
  'class Port(SerialBase):' \
  '    def __init__(self, url): self.url=url; self.rts=False; self.dtr=False; self.sent=False' \
  '    @property' \
  '    def in_waiting(self): return 8 if self.url == "data://" and not self.sent else 0' \
  '    def open(self):' \
  '        if self.url == "fail://": raise SerialException("fixture open failure")' \
  '    def setRTS(self, value): pass' \
  '    def setDTR(self, value): pass' \
  '    def read(self, size):' \
  '        if self.url == "readfail://": raise SerialException("fixture read failure")' \
  '        if self.url == "data://" and not self.sent: self.sent=True; return b"READY=1\n"' \
  '        return b""' \
  '    def close(self): pass' \
  'def serial_for_url(url, **kwargs): return Port(url)' >"$TMP/fake-serial/serial.py"

SERIAL_MONITOR="$ROOT/scripts/serial_monitor.py"
for args in '--timeout 0' '--timeout -1' '--timeout nan' '--timeout inf' '--baud 0' '--baud -1'; do
  # shellcheck disable=SC2086
  expect_rc 64 env PYTHONPATH="$TMP/fake-serial" python3 "$SERIAL_MONITOR" --port empty:// $args
done
pass serial-usage

expect_rc 4 env -u PYTHONPATH python3 -S "$SERIAL_MONITOR" --port empty:// --timeout 0.01
printf '%s\n' "$OUT" | grep -q '^DEPENDENCY_MISSING=pyserial$' || fail serial-dependency-marker
pass serial-dependency

expect_rc 2 env PYTHONPATH="$TMP/fake-serial" python3 "$SERIAL_MONITOR" --port fail:// --timeout 0.01
printf '%s\n' "$OUT" | grep -q '^DATA_SEEN=no$' || fail serial-open-data
printf '%s\n' "$OUT" | grep -q '^CAPTURE_BYTES=0$' || fail serial-open-bytes
pass serial-open

expect_rc 3 env PYTHONPATH="$TMP/fake-serial" python3 "$SERIAL_MONITOR" --port readfail:// --timeout 0.01
printf '%s\n' "$OUT" | grep -q '^DATA_SEEN=no$' || fail serial-read-data
printf '%s\n' "$OUT" | grep -q '^CAPTURE_BYTES=0$' || fail serial-read-bytes
pass serial-read

expect_rc 1 env PYTHONPATH="$TMP/fake-serial" python3 "$SERIAL_MONITOR" --port empty:// --timeout 0.01 --expect NEVER
printf '%s\n' "$OUT" | grep -q '^EXPECT_MATCH=no$' || fail serial-expect-marker
printf '%s\n' "$OUT" | grep -q '^DATA_SEEN=no$' || fail serial-expect-data
pass serial-expect-timeout

expect_rc 0 env PYTHONPATH="$TMP/fake-serial" python3 "$SERIAL_MONITOR" --port empty:// --timeout 0.01
printf '%s\n' "$OUT" | grep -q '^DATA_SEEN=no$' || fail serial-empty-data
printf '%s\n' "$OUT" | grep -q '^CAPTURE_BYTES=0$' || fail serial-empty-bytes
pass serial-empty-complete

expect_rc 0 env PYTHONPATH="$TMP/fake-serial" python3 "$SERIAL_MONITOR" --port data:// --timeout 0.1 --expect READY=1
printf '%s\n' "$OUT" | grep -q '^DATA_SEEN=yes$' || fail serial-data-seen
printf '%s\n' "$OUT" | grep -q '^CAPTURE_BYTES=8$' || fail serial-data-bytes
printf '%s\n' "$OUT" | grep -q '^EXPECT_MATCH=yes$' || fail serial-data-expect
pass serial-data

# shell wrapper 应在进入 IDF 环境前拒绝缺值/非法 timeout/baud。
for args in '-p' '-t' '-b' '-e -R' '-p COM1 -t 0' '-p COM1 -t inf' '-p COM1 -b 0' '-p COM1 -b -1'; do
  # shellcheck disable=SC2086
  expect_rc 64 bash "$ROOT/scripts/monitor.sh" $args
done
pass monitor-shell-boundaries

# wrapper 也要保留 Python 层的错误分类,不能把打开/依赖失败误报为 expect 超时。
mkdir -p "$TMP/monitor-idf/tools" "$TMP/monitor-bin"
: >"$TMP/monitor-idf/tools/idf.py"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'export PATH="$ESP_IDF_CY_TEST_MONITOR_BIN:$PATH"' \
  'export PYTHONPATH="$ESP_IDF_CY_TEST_SERIAL_MODULE"' >"$TMP/monitor-idf/export.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exec python3 "$@"' >"$TMP/monitor-bin/python"
chmod +x "$TMP/monitor-bin/python"

expect_rc 2 env ESP_IDF_CY_IDF_PATH="$TMP/monitor-idf" \
  ESP_IDF_CY_TEST_MONITOR_BIN="$TMP/monitor-bin" ESP_IDF_CY_TEST_SERIAL_MODULE="$TMP/fake-serial" \
  bash "$ROOT/scripts/monitor.sh" -p fail:// -t 0.01 -e NEVER
printf '%s\n' "$OUT" | grep -q '^MONITOR_RC=2$' || fail monitor-open-rc-marker
printf '%s\n' "$OUT" | grep -q '串口无法打开' || fail monitor-open-hint
printf '%s\n' "$OUT" | grep -q "没等到 'NEVER'" && fail monitor-open-not-expect

expect_rc 1 env ESP_IDF_CY_IDF_PATH="$TMP/monitor-idf" \
  ESP_IDF_CY_TEST_MONITOR_BIN="$TMP/monitor-bin" ESP_IDF_CY_TEST_SERIAL_MODULE="$TMP/fake-serial" \
  bash "$ROOT/scripts/monitor.sh" -p empty:// -t 0.01 -e NEVER
printf '%s\n' "$OUT" | grep -q '^MONITOR_RC=1$' || fail monitor-expect-rc-marker
printf '%s\n' "$OUT" | grep -q "没等到 'NEVER'" || fail monitor-expect-hint
pass monitor-error-classification

pass all-runtime-boundaries
