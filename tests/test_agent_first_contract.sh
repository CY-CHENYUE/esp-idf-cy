#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL=agent-first-contract:$1" >&2; exit 1; }
require() { rg -Fq "$2" "$1" || fail "$3"; }

require "$ROOT/SKILL.md" '不要把示例路径当事实' dynamic-path-policy
require "$ROOT/SKILL.md" 'build/project_description.json' project-metadata-discovery
require "$ROOT/SKILL.md" '有界搜索' bounded-search
require "$ROOT/SKILL.md" 'GUI 不是默认依赖' gui-optional
require "$ROOT/SKILL.md" '密码、Touch ID、UAC' secure-ui-user-gate
require "$ROOT/SKILL.md" '不支持 IDF 路径或' whitespace-policy
require "$ROOT/SKILL.md" 'Windows 没有 Git Bash' powershell-bootstrap
require "$ROOT/SKILL.md" '已有可用 EIM 时直接复用' adaptive-mac-existing-eim
require "$ROOT/SKILL.md" '已有 Homebrew 且' adaptive-mac-homebrew
require "$ROOT/SKILL.md" '三层职责不要混淆' three-layer-agent-first
require "$ROOT/SKILL.md" 'FixIdf' exact-repair-route
require "$ROOT/SKILL.md" 'idf.py --list-targets' dynamic-target-discovery
require "$ROOT/SKILL.md" '不会把项目路径、正则或用户数据直接拼成 shell 命令' eim-data-code-boundary
require "$ROOT/README.md" 'Skill 会根据实机动态分流' readme-dynamic-route
require "$ROOT/README.md" 'Agent 会操作 EIM GUI 吗？' readme-gui-boundary
require "$ROOT/README.md" '健康可复用 / 已安装但损坏 / 确实未安装' readme-three-state
require "$ROOT/references/idf-commands.md" 'NUL 分隔' eim-fixed-argv-relay
require "$ROOT/scripts/post-flash-check.sh" 'CURRENT_PORT_IDENTITY=unverified' honest-post-reset-identity

if rg -n '/Users/cychenyue|C:\\Users\\cychenyue' "$ROOT" \
  --glob '!**/tests/**' --glob '!**/evals/**' --glob '!**/LICENSE' >/dev/null; then
  fail hardcoded-local-user-path
fi

python3 - "$ROOT/evals/evals.json" <<'PY' || exit $?
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
by_id = {item["id"]: item for item in data["evals"]}
required = {
    14: "Computer Use",
    15: "project_description.json",
    16: "PowerShell",
    17: "NUL",
    18: "FixIdf",
    19: "OSArchitecture",
    20: "CURRENT_PORT_IDENTITY=unverified",
    21: "idf.py --list-targets",
}
for eval_id, text in required.items():
    item = by_id.get(eval_id)
    if not item or text not in (item["prompt"] + item["expected_output"]):
        print(f"FAIL=agent-first-contract:eval-{eval_id}", file=sys.stderr)
        raise SystemExit(1)
print("PASS=agent-first-evals")
PY

echo PASS=agent-first-contract
