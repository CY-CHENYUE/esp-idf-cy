#!/usr/bin/env bash
# check_network 单元测试：全部网络请求由 fake curl 接管，不访问真实网络。
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_CURL="$TMP/fake-curl"
cat >"$FAKE_CURL" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
url="${!#}"
case "${FAKE_CURL_MODE:-offline}:$url" in
  global:https://github.com/espressif/esp-idf.git) exit 0 ;;
  cn-jihulab:https://jihulab.com/esp-mirror/espressif/esp-idf.git) exit 0 ;;
  cn-dl:https://dl.espressif.cn/) exit 0 ;;
  *) exit 22 ;;
esac
SH
chmod +x "$FAKE_CURL"

# shellcheck source=../scripts/lib.sh
source "$SKILL_DIR/scripts/lib.sh"

fail() {
  echo "FAIL=$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

run_probe() {
  local mode="$1"
  : >"$TMP/curl.log"
  FAKE_CURL_MODE="$mode" FAKE_CURL_LOG="$TMP/curl.log" \
    ESP_IDF_CY_CURL_BIN="$FAKE_CURL" check_network
}

assert_log() {
  local expected="$1" actual
  actual="$(cat "$TMP/curl.log")"
  assert_eq "$expected" "$actual" "$2"
}

result="$(run_probe global)"
assert_eq global "$result" "GitHub 官方仓库可达时的分流"
assert_log '-m 5 -fsI https://github.com/espressif/esp-idf.git' \
  "global 只探测 GitHub 官方仓库"

result="$(run_probe cn-jihulab)"
assert_eq cn "$result" "JihuLab 镜像可达时的分流"
assert_log $'-m 5 -fsI https://github.com/espressif/esp-idf.git\n-m 5 -fsI https://jihulab.com/esp-mirror/espressif/esp-idf.git' \
  "cn 优先探测实际 clone 镜像"

result="$(run_probe cn-dl)"
assert_eq cn "$result" "乐鑫下载镜像可达时的分流"
assert_log $'-m 5 -fsI https://github.com/espressif/esp-idf.git\n-m 5 -fsI https://jihulab.com/esp-mirror/espressif/esp-idf.git\n-m 5 -fsI https://dl.espressif.cn/' \
  "JihuLab 不可达时才探测乐鑫下载镜像"

result="$(run_probe offline)"
assert_eq offline "$result" "安装相关端点都不可达时的分流"
assert_log $'-m 5 -fsI https://github.com/espressif/esp-idf.git\n-m 5 -fsI https://jihulab.com/esp-mirror/espressif/esp-idf.git\n-m 5 -fsI https://dl.espressif.cn/' \
  "offline 穷尽三个安装相关端点"

for override in global cn offline; do
  : >"$TMP/curl.log"
  result="$(FAKE_CURL_LOG="$TMP/curl.log" ESP_IDF_CY_CURL_BIN="$FAKE_CURL" \
    ESP_IDF_CY_NET="$override" check_network)"
  assert_eq "$override" "$result" "ESP_IDF_CY_NET=$override 覆盖"
  [ ! -s "$TMP/curl.log" ] || fail "ESP_IDF_CY_NET=$override 不应调用 curl"
done

: >"$TMP/curl.log"
set +e
error="$(FAKE_CURL_LOG="$TMP/curl.log" ESP_IDF_CY_CURL_BIN="$FAKE_CURL" \
  ESP_IDF_CY_NET=invalid check_network 2>&1)"
rc=$?
set -e
assert_eq 64 "$rc" "非法 ESP_IDF_CY_NET 返回码"
assert_eq 'ERROR=ESP_IDF_CY_NET 只能是 global/cn/offline' "$error" \
  "非法 ESP_IDF_CY_NET 错误信息"
[ ! -s "$TMP/curl.log" ] || fail "非法 ESP_IDF_CY_NET 不应调用 curl"

if rg -n 'baidu|google|bing' "$SKILL_DIR/scripts/lib.sh" >/dev/null; then
  fail "lib.sh 网络探针不应包含无关第三方站点"
fi

echo "PASS=test_network_probe"
