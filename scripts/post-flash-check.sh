#!/usr/bin/env bash
# esp-idf-cy · 烧录后两阶段恢复门禁。
#
# prepare: 在最终 RESET/上电前，对当前烧录口做最后一次 MAC 重验并签发短期 session。
# verify:  校验 prepare session，重扫端口，通过串口控制线做一次受控 reset 并采集；
#          此阶段代码中没有 identify/esptool 路径。
#
# 用法:
#   post-flash-check.sh prepare -p <烧录口> -m <确认MAC>
#       [--download-entry automatic|manual|unknown] [-t 秒]
#   post-flash-check.sh verify --session <prepare输出的token> -C <项目>
#       -e <应用健康正则> [-p <明确端口>] [-t 秒]

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PHASE="${1:-}"
case "$PHASE" in
  prepare|verify) shift ;;
  -h|--help) PHASE="" ;;
  *) echo "ERROR=第一个参数必须是 prepare 或 verify" >&2; exit 64 ;;
esac
usage() {
  cat >&2 <<'EOF'
用法:
  post-flash-check.sh prepare -p <烧录口> -m <预期MAC> [--download-entry automatic|manual|unknown] [-t 秒]
  post-flash-check.sh verify --session <token> -C <项目> -e <应用健康正则> [-p 端口] [-t 秒]
EOF
}
[ -n "$PHASE" ] || { usage; exit 0; }

EXPECTED_MAC=""; PROJECT=""; EXPECT=""; PORT=""; PORT_GIVEN=no; SESSION_TOKEN=""
TOTAL_TIMEOUT=60; ENTRY_MODE=unknown; ENTRY_GIVEN=no
PRE_RESET_IDENTITY=unverified
CURRENT_PORT_IDENTITY=unverified
PORT_SELECTION=unselected

need_value() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR=$1 需要一个非空值" >&2; exit 64; }
  case "$2" in -*) echo "ERROR=$1 不能把选项 $2 当作值" >&2; exit 64 ;; esac
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -m|--expected-mac) need_value "$@"; EXPECTED_MAC="$2"; shift 2 ;;
    -C|--project) need_value "$@"; PROJECT="$2"; shift 2 ;;
    -e|--expect) need_value "$@"; EXPECT="$2"; shift 2 ;;
    -p|--port) need_value "$@"; PORT="$2"; PORT_GIVEN=yes; shift 2 ;;
    -t|--timeout) need_value "$@"; TOTAL_TIMEOUT="$2"; shift 2 ;;
    --download-entry) need_value "$@"; ENTRY_MODE="$2"; ENTRY_GIVEN=yes; shift 2 ;;
    --manual-download) ENTRY_MODE=manual; ENTRY_GIVEN=yes; shift ;;
    --session) need_value "$@"; SESSION_TOKEN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR=未知参数: $1" >&2; usage; exit 64 ;;
  esac
done
case "$ENTRY_MODE" in
  auto) ENTRY_MODE=automatic ;;
  automatic|manual|unknown) ;;
  *) echo "ERROR=--download-entry 只能是 automatic、manual 或 unknown" >&2; exit 64 ;;
esac
case "$TOTAL_TIMEOUT" in ''|*[!0-9]*) echo "ERROR=-t 必须是正整数" >&2; exit 64 ;; esac
[ "${#TOTAL_TIMEOUT}" -le 9 ] || { echo "ERROR=-t 数值过大" >&2; exit 64; }
TOTAL_TIMEOUT=$((10#$TOTAL_TIMEOUT))
[ "$TOTAL_TIMEOUT" -gt 0 ] || { echo "ERROR=-t 必须大于 0" >&2; exit 64; }
case "$PORT$PROJECT$EXPECT$EXPECTED_MAC" in *$'\n'*|*$'\r'*) echo "ERROR=参数不能包含换行" >&2; exit 64 ;; esac

normalize_mac() {
  local mac
  mac="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]:' )"
  printf '%s\n' "$mac" | grep -Eq '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' || return 1
  printf '%s\n' "$mac"
}
emit_common() {
  local identity_status="$3"
  # verify 阶段只能证明 RESET 前的 MAC。恢复后的串口即使路径未变，也没有再次
  # 运行 esptool，因此兼容字段 IDENTITY_STATUS 必须反映当前端口仍未验证。
  [ "$PHASE" != verify ] || identity_status="$CURRENT_PORT_IDENTITY"
  echo "POST_FLASH_PHASE=$PHASE"
  echo "POST_FLASH_STATE=$1"
  echo "POST_FLASH_READY=$2"
  echo "ENTRY_MODE=$ENTRY_MODE"
  echo "IDENTITY_STATUS=$identity_status"
  echo "PRE_RESET_IDENTITY=$PRE_RESET_IDENTITY"
  echo "CURRENT_PORT_IDENTITY=$CURRENT_PORT_IDENTITY"
  echo "PORT_SELECTION=$PORT_SELECTION"
  echo "APPLICATION_EVIDENCE=$4"
  echo "DOWNLOAD_MODE_SUSPECTED=$5"
  echo "ACTION_REQUIRED=$6"
}

SESSION_DIR="${ESP_IDF_CY_POST_FLASH_SESSION_DIR:-${TMPDIR:-/tmp}/esp-idf-cy-post-flash}"
SESSION_TTL="${ESP_IDF_CY_POST_FLASH_SESSION_TTL:-3600}"
case "$SESSION_TTL" in ''|*[!0-9]*) echo "ERROR=SESSION_TTL 必须是整数" >&2; exit 64 ;; esac

if [ "$PHASE" = prepare ]; then
  [ -z "$PROJECT$EXPECT$SESSION_TOKEN" ] || { echo "ERROR=prepare 不接受 -C/-e/--session" >&2; exit 64; }
  [ -n "$PORT" ] || { echo "ERROR=prepare 必须给出当前烧录口 -p" >&2; exit 64; }
  [ -n "$EXPECTED_MAC" ] || { echo "ERROR=prepare 必须给出 -m/--expected-mac" >&2; exit 64; }
  EXPECTED_MAC_NORMALIZED="$(normalize_mac "$EXPECTED_MAC")" || { echo "ERROR=无效 MAC" >&2; exit 64; }
  IDENTIFY_HELPER="${ESP_IDF_CY_POST_FLASH_IDENTIFY_BIN:-$SCRIPT_DIR/identify-device.sh}"
  [ -f "$IDENTIFY_HELPER" ] || {
    emit_common identity_failed no unverified not_observed unknown check_port
    echo "FAILURE_KIND=dependency_missing"; exit 4
  }
  IDENTIFY_OUT="$(run_with_timeout "$TOTAL_TIMEOUT" bash "$IDENTIFY_HELPER" -p "$PORT" 2>&1)"
  IDENTIFY_RC=$?
  [ -z "$IDENTIFY_OUT" ] || printf '%s\n' "$IDENTIFY_OUT" >&2
  if [ "$IDENTIFY_RC" -ne 0 ]; then
    emit_common identity_failed no unverified not_observed unknown check_port
    echo "FAILURE_KIND=identity_failed"; echo "HELPER_RC=$IDENTIFY_RC"; exit 4
  fi
  OBSERVED_MAC_RAW="$(printf '%s\n' "$IDENTIFY_OUT" | sed -n 's/^MAC=//p' | head -1)"
  OBSERVED_MAC="$(normalize_mac "$OBSERVED_MAC_RAW")" || {
    emit_common identity_failed no unverified not_observed unknown check_port
    echo "FAILURE_KIND=identity_failed"; exit 4
  }
  if [ "$OBSERVED_MAC" != "$EXPECTED_MAC_NORMALIZED" ]; then
    echo "EXPECTED_MAC=$EXPECTED_MAC_NORMALIZED"; echo "OBSERVED_MAC=$OBSERVED_MAC"
    emit_common identity_mismatch no mismatch not_observed unknown select_or_isolate_port
    echo "IDENTITY_REVERIFIED=no"; echo "FAILURE_KIND=identity_mismatch"; exit 5
  fi

  PRE_RESET_IDENTITY=matched
  CURRENT_PORT_IDENTITY=matched
  PORT_SELECTION=original

  umask 077
  mkdir -p "$SESSION_DIR" || { echo "ERROR=无法创建 post-flash session 目录" >&2; exit 4; }
  chmod 700 "$SESSION_DIR" 2>/dev/null || true
  SESSION_FILE="$(mktemp "$SESSION_DIR/session.XXXXXX")" || { echo "ERROR=无法创建 session" >&2; exit 4; }
  SESSION_TOKEN="${SESSION_FILE##*/}"
  {
    echo "VERSION=1"
    echo "EXPECTED_MAC=$EXPECTED_MAC_NORMALIZED"
    echo "OBSERVED_MAC=$OBSERVED_MAC"
    echo "ENTRY_MODE=$ENTRY_MODE"
    echo "PREPARED_PORT=$PORT"
    echo "PREPARED_AT=$(date +%s)"
  } >"$SESSION_FILE"
  chmod 600 "$SESSION_FILE" 2>/dev/null || true

  echo "EXPECTED_MAC=$EXPECTED_MAC_NORMALIZED"; echo "OBSERVED_MAC=$OBSERVED_MAC"
  echo "IDENTITY_REVERIFIED=yes"; echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "PREPARED_PORT=$PORT"
  if [ "$ENTRY_MODE" = manual ] || [ "$ENTRY_MODE" = unknown ]; then
    emit_common action_required no matched not_observed unknown release_boot_then_reset_or_power_cycle
    echo "RESET_REQUIRED=yes"; echo "NEXT=verify --session $SESSION_TOKEN"; exit 20
  fi
  emit_common prepared no matched not_observed unknown none
  echo "RESET_REQUIRED=no"; echo "NEXT=verify --session $SESSION_TOKEN"; exit 0
fi

# verify 必须消费 prepare 产生的受限 session；不能由调用方自报身份已重验。
[ -z "$EXPECTED_MAC" ] || { echo "ERROR=verify 不接受 -m；身份只能来自 prepare session" >&2; exit 64; }
[ "$ENTRY_GIVEN" = no ] || { echo "ERROR=verify 不接受 --download-entry；进入方式来自 session" >&2; exit 64; }
[ -n "$SESSION_TOKEN" ] || { echo "ERROR=verify 必须给出 prepare 输出的 --session" >&2; exit 64; }
case "$SESSION_TOKEN" in */*|*..*|session.) echo "ERROR=无效 session token" >&2; exit 64 ;; session.*) ;; *) echo "ERROR=无效 session token" >&2; exit 64 ;; esac
SESSION_FILE="$SESSION_DIR/$SESSION_TOKEN"
[ -f "$SESSION_FILE" ] || { echo "ERROR=session 不存在或已消费" >&2; exit 64; }
SESSION_VERSION="$(sed -n 's/^VERSION=//p' "$SESSION_FILE" | head -1)"
SESSION_EXPECTED_MAC="$(sed -n 's/^EXPECTED_MAC=//p' "$SESSION_FILE" | head -1)"
SESSION_OBSERVED_MAC="$(sed -n 's/^OBSERVED_MAC=//p' "$SESSION_FILE" | head -1)"
ENTRY_MODE="$(sed -n 's/^ENTRY_MODE=//p' "$SESSION_FILE" | head -1)"
PREPARED_PORT="$(sed -n 's/^PREPARED_PORT=//p' "$SESSION_FILE" | head -1)"
PREPARED_AT="$(sed -n 's/^PREPARED_AT=//p' "$SESSION_FILE" | head -1)"
[ "$SESSION_VERSION" = 1 ] || { echo "ERROR=session 版本无效" >&2; exit 64; }
NORMAL_SESSION_MAC="$(normalize_mac "$SESSION_EXPECTED_MAC")" || { echo "ERROR=session MAC 无效" >&2; exit 64; }
[ "$NORMAL_SESSION_MAC" = "$(normalize_mac "$SESSION_OBSERVED_MAC" 2>/dev/null)" ] || { echo "ERROR=session 身份不一致" >&2; exit 64; }
case "$ENTRY_MODE" in automatic|manual|unknown) ;; *) echo "ERROR=session entry 无效" >&2; exit 64 ;; esac
case "$PREPARED_PORT" in ''|*$'\n'*|*$'\r'*) echo "ERROR=session prepared port 无效" >&2; exit 64 ;; esac
case "$PREPARED_AT" in ''|*[!0-9]*) echo "ERROR=session 时间无效" >&2; exit 64 ;; esac
NOW="$(date +%s)"; AGE=$((NOW - PREPARED_AT))
[ "$AGE" -ge 0 ] && [ "$AGE" -le "$SESSION_TTL" ] || { echo "ERROR=session 已过期" >&2; exit 64; }
[ -n "$PROJECT" ] || { echo "ERROR=verify 必须给出 -C/--project" >&2; exit 64; }
[ -n "$EXPECT" ] || { echo "ERROR=verify 必须给出 -e/--expect；无应用证据不能判 READY" >&2; exit 64; }

# session 只证明最终 RESET 前、PREPARED_PORT 上的 MAC 匹配。verify 阶段不得再
# 运行 identify/esptool，因此恢复后的 CURRENT_PORT_IDENTITY 永远是 unverified。
PRE_RESET_IDENTITY=matched
CURRENT_PORT_IDENTITY=unverified
if [ "$PORT_GIVEN" = yes ]; then
  PORT_SELECTION=agent_explicit
else
  PORT_SELECTION=candidate_required
fi

WAIT_HELPER="${ESP_IDF_CY_POST_FLASH_WAIT_PORT_BIN:-$SCRIPT_DIR/wait-port.sh}"
MONITOR_HELPER="${ESP_IDF_CY_POST_FLASH_MONITOR_BIN:-$SCRIPT_DIR/monitor.sh}"
for helper in "$WAIT_HELPER" "$MONITOR_HELPER"; do [ -f "$helper" ] || {
  emit_common monitor_error no matched not_observed unknown inspect_environment
  echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "FAILURE_KIND=dependency_missing"; exit 4
}; done
STARTED_AT="$(date +%s)"; DEADLINE=$((STARTED_AT + TOTAL_TIMEOUT))
remaining_seconds() { local n r; n="$(date +%s)"; r=$((DEADLINE - n)); [ "$r" -gt 0 ] || return 1; echo "$r"; }
REMAINING="$(remaining_seconds)" || {
  emit_common port_unavailable no matched not_observed unknown check_port
  echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "FAILURE_KIND=port_timeout"; exit 2
}
WAIT_ARGS=(-t "$REMAINING" -i 1); [ "$PORT_GIVEN" = no ] || WAIT_ARGS+=(-p "$PORT")
WAIT_OUT="$(run_with_timeout "$REMAINING" bash "$WAIT_HELPER" "${WAIT_ARGS[@]}" 2>&1)"; WAIT_RC=$?
[ -z "$WAIT_OUT" ] || printf '%s\n' "$WAIT_OUT" >&2
if [ "$WAIT_RC" -eq 3 ] || printf '%s\n' "$WAIT_OUT" | grep -q '^AMBIGUOUS=yes$'; then
  emit_common port_ambiguous no matched not_observed unknown select_or_isolate_port
  echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "PREPARED_PORT=$PREPARED_PORT"
  printf '%s\n' "$WAIT_OUT" | sed -n 's/^CANDIDATE_PORT=/CANDIDATE_PORT=/p'
  echo "FAILURE_KIND=port_ambiguous"; exit 3
fi
if [ "$WAIT_RC" -ne 0 ]; then
  emit_common port_unavailable no matched not_observed unknown check_port
  echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "FAILURE_KIND=port_timeout"; echo "HELPER_RC=$WAIT_RC"; exit 2
fi
CANDIDATE_COUNT="$(printf '%s\n' "$WAIT_OUT" | grep -c '^CANDIDATE_PORT=')"
[ "$CANDIDATE_COUNT" -eq 1 ] || {
  emit_common port_unavailable no matched not_observed unknown check_port
  echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "FAILURE_KIND=port_unavailable"; exit 2
}
CANDIDATE_PORT="$(printf '%s\n' "$WAIT_OUT" | sed -n 's/^CANDIDATE_PORT=//p' | head -1)"
[ -n "$CANDIDATE_PORT" ] || { echo "ERROR=候选端口为空" >&2; exit 2; }

if [ "$PORT_GIVEN" = yes ]; then
  # Agent 已在对话/外部证据层明确选择恢复口；helper 不得悄悄替换它。
  [ "$CANDIDATE_PORT" = "$PORT" ] || {
    emit_common port_unavailable no matched not_observed unknown check_port
    echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "PREPARED_PORT=$PREPARED_PORT"
    echo "REQUESTED_PORT=$PORT"; echo "CANDIDATE_PORT=$CANDIDATE_PORT"
    echo "FAILURE_KIND=port_contract"; exit 2
  }
  PORT_SELECTION=agent_explicit
elif [ "$CANDIDATE_PORT" = "$PREPARED_PORT" ]; then
  PORT_SELECTION=original
else
  # 一个新端口也只是候选。端口路径不是设备身份，必须把选择权交还 Agent，
  # 由其结合 USB topology/序列号/用户确认后用显式 -p 再次 verify。
  PORT_SELECTION=candidate_required
  emit_common port_selection_required no matched not_observed unknown select_recovery_port
  echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "PREPARED_PORT=$PREPARED_PORT"
  echo "CANDIDATE_PORT=$CANDIDATE_PORT"; echo "FAILURE_KIND=port_selection_required"
  exit 3
fi
REMAINING="$(remaining_seconds)" || {
  emit_common app_unverified no matched not_observed unknown inspect_log_or_reset
  echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "FAILURE_KIND=expect_timeout"; exit 1
}

umask 077
CAPTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/esp-idf-cy-capture.XXXXXX")" || {
  emit_common monitor_error no matched not_observed unknown inspect_environment
  echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "FAILURE_KIND=capture_setup"; exit 4
}
CAPTURE_LOG="$CAPTURE_DIR/serial.log"; MONITOR_STATUS_FILE="$CAPTURE_DIR/monitor.status"
run_with_timeout "$REMAINING" bash "$MONITOR_HELPER" -p "$CANDIDATE_PORT" -C "$PROJECT" \
  -t "$REMAINING" -e "$EXPECT" -R >"$CAPTURE_LOG" 2>"$MONITOR_STATUS_FILE"
MONITOR_RC=$?
MONITOR_STATUS="$(cat "$MONITOR_STATUS_FILE" 2>/dev/null)"
[ -z "$MONITOR_STATUS" ] || printf '%s\n' "$MONITOR_STATUS" >&2

if [ "$MONITOR_RC" -eq 10 ] && printf '%s\n' "$MONITOR_STATUS" | grep -q '^ROM_DOWNLOAD_MODE=yes$'; then
  ROM_SIGNATURE="$(printf '%s\n' "$MONITOR_STATUS" | sed -n 's/^ROM_SIGNATURE=//p' | head -1)"
  emit_common download_mode_suspected no matched not_matched yes release_boot_then_reset_or_power_cycle
  echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "POST_FLASH_PORT=$CANDIDATE_PORT"; echo "CAPTURE_LOG=$CAPTURE_LOG"
  echo "ROM_SIGNATURE=${ROM_SIGNATURE:-unknown}"; echo "FAILURE_KIND=rom_download"; exit 20
fi
if [ "$MONITOR_RC" -eq 0 ] && printf '%s\n' "$MONITOR_STATUS" | grep -q '^EXPECT_MATCH=yes$'; then
  emit_common ready yes matched matched no none
  echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "POST_FLASH_PORT=$CANDIDATE_PORT"; echo "CAPTURE_LOG=$CAPTURE_LOG"
  echo "ROM_SIGNATURE=none"; echo "FAILURE_KIND=none"
  rm -f "$SESSION_FILE"
  exit 0
fi
case "$MONITOR_RC" in
  0)
    emit_common monitor_error no matched not_observed unknown inspect_environment
    FAILURE_KIND=monitor_contract; FINAL_RC=4 ;;
  1|124)
    emit_common app_unverified no matched not_matched unknown inspect_log_or_reset
    FAILURE_KIND=expect_timeout; FINAL_RC=1 ;;
  2|3)
    emit_common port_unavailable no matched not_observed unknown check_port
    FAILURE_KIND=monitor_port_error; FINAL_RC=2 ;;
  4)
    emit_common monitor_error no matched not_observed unknown inspect_environment
    FAILURE_KIND=dependency_missing; FINAL_RC=4 ;;
  64)
    emit_common monitor_error no matched not_observed unknown fix_expect_or_arguments
    FAILURE_KIND=usage_error; FINAL_RC=64 ;;
  *)
    emit_common monitor_error no matched not_observed unknown inspect_environment
    FAILURE_KIND=monitor_error; FINAL_RC=4 ;;
esac
echo "POST_FLASH_SESSION=$SESSION_TOKEN"; echo "POST_FLASH_PORT=$CANDIDATE_PORT"; echo "CAPTURE_LOG=$CAPTURE_LOG"
echo "ROM_SIGNATURE=none"; echo "FAILURE_KIND=$FAILURE_KIND"; echo "HELPER_RC=$MONITOR_RC"
exit "$FINAL_RC"
