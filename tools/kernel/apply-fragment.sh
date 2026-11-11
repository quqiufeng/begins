#!/bin/bash
# apply-fragment.sh —— 把 CONFIG_X=y|m|n 片段逐条喂给 scripts/config，再 olddefconfig
# 用法：tools/kernel/apply-fragment.sh <tree> <fragment> [<fragment>...]
set -euo pipefail
tree=$1; shift
cd "$tree"
for frag in "$@"; do
    [ -f "$frag" ] || { echo "没有这个片段: $frag" >&2; exit 1; }
    while IFS= read -r line; do
        case $line in
            CONFIG_LOCALVERSION=*) scripts/config --file .config --set-str LOCALVERSION "$(v=${line#CONFIG_LOCALVERSION=}; echo "${v%\"}"; echo "${v#\"}")" | sed 's/^/  /' ;;
            CONFIG_*=y) scripts/config --file .config -e "${line%%=*}" ;;
            CONFIG_*=m) scripts/config --file .config -m "${line%%=*}" ;;
            CONFIG_*=n) scripts/config --file .config -d "${line%%=*}" ;;
            # savedefconfig 输出里的「关闭」行：原来被静默跳过，导致反向导出的
            # fragment 喂回去时丢一半信息（多出来的 =y 收不回来）。
            "# CONFIG_"*" is not set") scripts/config --file .config -d "$(echo "$line" | sed 's/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1/')" ;;
            # 兜底：数值/字符串配置（LOG_BUF_SHIFT=18、NLS_DEFAULT="utf8"），
            # 以前这些行直接被丢掉，fragment 回灌后配置会悄悄漂移。
            CONFIG_*=*)
                k=${line%%=*}; v=${line#*=}
                case $v in
                    \"*\") scripts/config --file .config --set-str "$k" "$(v=${v#\"}; echo "${v%\"}")" ;;
                    *)    scripts/config --file .config --set-val "$k" "$v" ;;
                esac ;;
        esac
    done < "$frag"
    echo "· 已合并 $(basename "$frag")"
done
make olddefconfig
