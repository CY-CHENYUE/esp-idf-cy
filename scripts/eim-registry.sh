#!/usr/bin/env bash
# esp-idf-cy · EIM 登记的精确版本解析边界。
#
# 本文件供 install.sh / install-eim-macos.sh source。调用方必须先 source lib.sh。
# 它只相信 eim_idf.json 中的登记项及该项自己的版本元数据,不使用 selected、
# ambient IDF_PATH 或默认安装目录替代精确匹配。

exact_idf_tag() {
  printf '%s\n' "${1:-}" | sed -nE 's/.*(^|[^0-9A-Za-z])v?([0-9]+\.[0-9]+\.[0-9]+)([^0-9].*|$)/v\2/p' | head -1
}

# EIM 的 name 可被 rename。只有仍是默认版本显示名时才把它当版本线索；
# 任意自定义名称里的日期/数字不能覆盖仓库自己的版本元数据。
canonical_eim_name_tag() {
  printf '%s\n' "${1:-}" \
    | sed -nE 's/^(ESP-IDF[[:space:]]+)?v?([0-9]+\.[0-9]+\.[0-9]+)$/v\2/p' \
    | head -1
}

same_existing_path() {
  local left="$1" right="$2"
  if [ -d "$left" ] && [ -d "$right" ]; then
    [ "$(canonical_existing_dir "$left" 2>/dev/null || printf '%s' "$left")" = \
      "$(canonical_existing_dir "$right" 2>/dev/null || printf '%s' "$right")" ]
  else
    [ "$left" = "$right" ]
  fi
}

# 输出唯一匹配的 IDF 根目录。返回码:
#   0  唯一匹配
#   10 登记中不存在该精确版本
#   11 同版本存在多个不同路径,拒绝猜选
#   12 登记/目录元数据冲突或登记路径损坏到无法安全定位
#   13 EIM 登记文件无法结构化解析
eim_exact_idf_path() {
  local expected="$1" required_path="${2:-}" registry line raw_path name path existing duplicate i
  local name_tag actual_tag actual_raw candidate="" count=0 version_match_seen=no records="" parse_rc=0
  local required_match=no registry_unknown=no
  local seen_paths=() seen_count=0

  [ "$(exact_idf_tag "$expected")" = "$expected" ] || {
    echo "ERROR=EIM 路径解析只接受精确 tag v<major>.<minor>.<patch>: $expected" >&2
    return 64
  }
  registry="$(eim_json_path)"
  if [ ! -f "$registry" ]; then
    echo "EIM_INSTALL_STATE=absent" >&2
    return 10
  fi

  records="$(parse_eim_json "$registry")"; parse_rc=$?
  if [ "$parse_rc" -ne 0 ]; then
    echo "EIM_INSTALL_STATE=registry_unreadable" >&2
    echo "ERROR=EIM 登记文件无法结构化解析(rc=$parse_rc): $registry" >&2
    return 13
  fi

  while IFS=$'\t' read -r raw_path name; do
    [ -n "$raw_path" ] || continue
    path="$raw_path"
    [ "$OS" = windows ] && path="$(cygpath -u "$path" 2>/dev/null || printf '%s' "$path")"
    if path_has_whitespace "$path"; then
      echo "EIM_INSTALL_STATE=conflict" >&2
      echo "ERROR=EIM 登记路径含 ESP-IDF 不支持的空白字符: $path" >&2
      return 12
    fi
    name_tag="$(canonical_eim_name_tag "$name")"

    # EIM 有的登记指向 IDF 根,有的登记指向上层版本目录。只在文件系统
    # 给出唯一证据时补 /esp-idf,不从固定目录结构反推。
    if is_idf_dir "$path"; then
      :
    elif is_idf_dir "$path/esp-idf"; then
      path="$path/esp-idf"
    elif [ "$name_tag" = "$expected" ] && [ -d "$path/esp-idf" ] && [ ! -f "$path/tools/idf.py" ]; then
      path="$path/esp-idf"
    elif [ -d "$path" ]; then
      # 保留现存但工具/元数据受损的登记根，供 exact fix 处理。
      :
    else
      if [ "$name_tag" = "$expected" ] \
        || { [ -n "$required_path" ] && same_existing_path "$path" "$required_path"; }; then
        echo "EIM_INSTALL_STATE=registered_path_missing" >&2
        echo "ERROR=EIM 登记路径已不存在，fix 也要求有效 IDF 目录: $path" >&2
        return 12
      fi
      registry_unknown=yes
      continue
    fi

    required_match=no
    [ -z "$required_path" ] || { same_existing_path "$path" "$required_path" && required_match=yes; }

    actual_raw="$(idf_dir_version "$path" 2>/dev/null || true)"
    actual_tag="$(exact_idf_tag "$actual_raw")"
    if [ -n "$actual_tag" ] && [ "$actual_raw" != "$actual_tag" ]; then
      if [ "$required_match" = yes ] || [ "$name_tag" = "$expected" ]; then
        echo "EIM_INSTALL_STATE=conflict" >&2
        echo "ERROR=EIM 目录不是精确 tag checkout($actual_raw): $path" >&2
        return 12
      fi
      registry_unknown=yes
      continue
    fi

    if [ -n "$actual_tag" ]; then
      if [ "$actual_tag" != "$expected" ]; then
        if [ "$required_match" = yes ] || [ "$name_tag" = "$expected" ]; then
          echo "EIM_INSTALL_STATE=conflict" >&2
          echo "ERROR=请求 $expected,但登记路径实际是 $actual_tag: $path" >&2
          return 12
        fi
        continue
      fi
    elif [ "$name_tag" != "$expected" ] && [ "$required_match" != yes ]; then
      # rename 后又损坏到无法从仓库取版本时，自动模式不能把它当 absent
      # 再装一份；只有项目/用户给出的 exact path 能安全消歧。
      registry_unknown=yes
      continue
    fi
    version_match_seen=yes

    if [ -n "$required_path" ] && [ "$required_match" != yes ]; then
      continue
    fi
    duplicate=no
    i=0
    while [ "$i" -lt "$seen_count" ]; do
      existing="${seen_paths[$i]}"
      [ "$existing" != "$path" ] || { duplicate=yes; break; }
      i=$((i + 1))
    done
    [ "$duplicate" = no ] || continue
    seen_paths[$seen_count]="$path"
    seen_count=$((seen_count + 1))
    candidate="$path"
    count=$((count + 1))
  done <<EOF
$records
EOF

  if [ "$count" -eq 0 ]; then
    if [ -n "$required_path" ] && [ "$version_match_seen" = yes ]; then
      echo "EIM_INSTALL_STATE=path_mismatch" >&2
      echo "ERROR=请求修复的路径不等于 EIM 对 $expected 的登记路径: $required_path" >&2
      return 12
    fi
    if [ "$registry_unknown" = yes ]; then
      echo "EIM_INSTALL_STATE=unidentified_registration" >&2
      echo "ERROR=EIM 存在无法确定版本的登记；由 Agent 先按路径消歧，不能当作未安装" >&2
      return 12
    fi
    echo "EIM_INSTALL_STATE=absent" >&2
    return 10
  fi
  if [ "$count" -ne 1 ]; then
    echo "EIM_INSTALL_STATE=ambiguous" >&2
    echo "ERROR=EIM 登记中有 $count 个 $expected 路径;必须由 Agent 明确消歧,本脚本拒绝猜选" >&2
    return 11
  fi
  printf '%s\n' "$candidate"
}
