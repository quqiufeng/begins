#!/usr/bin/env bash
# lib/mode.sh — 两套打包的唯一参数源（full 完整源码树 / trim 裁剪版）
#
# 只被 source，不单独执行。所有 x96max/*.sh 与 x96max/{full,trim}/*.sh 都从这里
# 取「配置 / 源码树 / 编译产物树 / 内核名 / initrd / 包仓 / 成品镜像名」，
# 保证两套参数永远成对、不会串味（以前两套共用一个 KNAME，包会互相覆盖）。
#
# 用法：
#   source "$SELF_DIR/lib/mode.sh";  x96_mode full    # 或 trim
# 之后可用变量：
#   MODE KNAME KV CFG KSRC OUT PKGS KERNDIR INITRD UINITRD IMG IMG_GZ
#
# 两套参数对照（路径前缀 ROOT=/x96-build）：
#   full  KNAME=7.2.12-x96        CFG=config-7.2.12-x96-full   KSRC=src-full    OUT=kbuild-7.2.12
#   trim  KNAME=7.2.12-x96-trim   CFG=config-7.2.12-x96-trim   KSRC=src-trim    OUT=kbuild-trim
#
# 源码树策略：
#   full —— **不长期占地方**。src-full 由 x96_ensure_src 从源码包
#           /opt/linux/src/linux-<KV>.tar.xz 现解压（约 9s / 1.8G），编完可删
#           （--clean-src 或 X96_CLEAN_SRC=1 自动删）。默认不用旧目录 src-linux：
#           那棵树被削过（无 Documentation、只剩 arm64 等），要它请显式 X96_KSRC。
#   trim —— src-trim 是「解压 + trim-tools 裁剪」的产物（782M / 50552 文件，原版
#           1.4G），解压本身还原不出来，必须保留；删了用 kernel/gen-trim.sh 重新生成，
#           或对解压树跑 trim-tools/prune_src.py --apply。
#           目录名不强求：依次找 src-trim / src-clean / $KV-trim，取第一个存在的
#           （实测现役树叫 7.2.12-trim，旧文档写的 src-clean 从没在这个机器上落盘过，
#            于是 trim 模式一律「缺源码树」——默认值必须认实际存在的那个）。
# 包仓：full→pkgs/full  trim→pkgs/trim；两者都按需同步进 ophub 的 kernel/stable/7.2.12
# （同一时刻只放一套，见 x96_stage_pkgs），成品：recovery/x96-<MODE>-autoinstall.img.gz
#
# 可覆盖：X96_BUILD_ROOT / X96_KV / X96_KNAME / X96_CFG / X96_KSRC / X96_KOUT / X96_IMG
# 注意：KNAME 必须与 config 里的 CONFIG_LOCALVERSION 对得上
# （full=-x96 → 7.2.12-x96；trim=-x96-trim → 7.2.12-x96-trim），否则模块目录名会错。

X96_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # x96max/
X96_REPO=$(dirname "$X96_DIR")                             # 仓库根

# trim 源码树的实际落点（名字随历史变过，别写死一个）。
x96_pick_trim_src() {
  local root=$1 d
  for d in src-trim src-clean "$KV-trim" "$KV-src"; do
    [[ -f $root/$d/Makefile ]] && { echo "$root/$d"; return 0; }
  done
  echo "$root/src-trim"        # 都没有 → 报这个名字，别再造 src-clean 这种不存在路径
}

x96_mode() {
  local m=${1:-full}
  case $m in
    full|trim) ;;
    *) echo "MODE 只能是 full|trim（当前 '$m'）" >&2; return 2 ;;
  esac
  MODE=$m
  ROOT=${X96_BUILD_ROOT:-/x96-build}
  KV=${X96_KV:-7.2.12}
  if [[ $MODE == trim ]]; then
    KNAME=${X96_KNAME:-$KV-x96-trim}
    CFG=${X96_CFG:-$X96_DIR/kernel/config-$KV-x96-trim}
    KSRC=${X96_KSRC:-$(x96_pick_trim_src "$ROOT")}
    OUT=${X96_KOUT:-$ROOT/kbuild-trim}
  else
    KNAME=${X96_KNAME:-$KV-x96}
    CFG=${X96_CFG:-$X96_DIR/kernel/config-$KV-x96-full}
    KSRC=${X96_KSRC:-$ROOT/src-full}   # 缺席由 x96_ensure_src 现解压
    OUT=${X96_KOUT:-$ROOT/kbuild-$KV}
  fi
  PKGS=${X96_PKGS:-$ROOT/pkgs/$MODE}                       # 本套自己的包仓（互不覆盖）
  KERNDIR=$ROOT/amlogic-s9xxx-armbian/build-armbian/kernel/stable/$KV  # ophub 只认这个目录
  INITRD=$ROOT/initrd.img-$KNAME
  UINITRD=$ROOT/uInitrd-$KNAME
  IMG=${X96_IMG:-$ROOT/recovery/x96-$MODE-autoinstall.img}
  IMG_GZ=$IMG.gz
  CFG_ARCHIVE=$(ls -1 "$X96_REPO"/configs/config-$KV-x96-$MODE-[0-9]* 2>/dev/null | tail -1 || true)
  SRC_XZ=${X96_SRC_XZ:-/opt/linux/src/linux-$KV.tar.xz}   # 完整源码包
  export MODE ROOT KV KNAME CFG KSRC OUT PKGS KERNDIR INITRD UINITRD IMG IMG_GZ \
         CFG_ARCHIVE SRC_XZ X96_DIR X96_REPO
}

# 按需准备源码树（full 可以从源码包现解压，不用常驻一份全量树）。
# 用法：x96_ensure_src          → 0 已就绪/解压成功；2 缺包或 trim 树缺失
x96_ensure_src() {
  if [[ -f $KSRC/Makefile && -d $KSRC/drivers ]]; then
    echo "  源码树就绪：$KSRC"
    return 0
  fi
  if [[ $MODE == trim ]]; then
    echo "缺裁剪源码树: $KSRC" >&2
    echo "  裁剪树是「解压+裁剪」的产物，解压源码包还原不出来。两条路：" >&2
    echo "    a) 复用现成的：X96_KSRC=/x96-build/<已有裁剪树> ./x96max/preflight.sh --trim" >&2
    echo "    b) 重新生成：x96max/kernel/gen-trim.sh，或解压后跑 trim-tools/prune_src.py --apply" >&2
    echo "  已找过的位置：$ROOT/{src-trim,src-clean,$KV-trim,$KV-src}" >&2
    return 2
  fi
  [[ -f $SRC_XZ ]] || { echo "缺源码包: $SRC_XZ（解压不出 $KSRC）" >&2; return 2; }
  echo "解压源码包（首次/已删过，约 1-2 分钟）：$SRC_XZ → $KSRC"
  local t0; t0=$(date +%s)
  mkdir -p "$KSRC"
  if ! tar -xJf "$SRC_XZ" -C "$KSRC" --strip-components=1; then
    echo "解压失败，清掉半成品: $KSRC" >&2; rm -rf "$KSRC"; return 2
  fi
  : > "$KSRC/.x96-extracted"      # 标记「这是解压出来的，可以随手删」
  echo "  解压完成 $(($(date +%s) - t0))s，$(du -sh "$KSRC" | cut -f1)"
}

# 编完释放全量树（只对 full 且确实是解压出来的树生效）。
x96_drop_src() {
  [[ ${1:-} == 1 || ${X96_CLEAN_SRC:-0} == 1 ]] || return 0
  [[ $MODE == full ]] || { echo "  保留 $KSRC（trim 树不可再解压得到）"; return 0; }
  [[ -f $KSRC/.x96-extracted ]] || { echo "  保留 $KSRC（不是解压出来的，不动）"; return 0; }
  echo "  释放全量源码树 $KSRC（$(du -sh "$KSRC" | cut -f1)）——需要时自动重新解压"
  rm -rf "$KSRC"
}

# 把本套的四个包同步进 ophub 的 kernel/stable/<KV>，先清掉另一套的残留。
# ophub rebuild 的 -k 只认版本号（7.2.12），所以两套共用这个目录、只能轮流放。
x96_stage_pkgs() {
  [[ -d $PKGS ]] || { echo "包仓不存在: $PKGS" >&2; return 1; }
  mkdir -p "$KERNDIR"
  rm -f "$KERNDIR"/*.tar.gz "$KERNDIR"/sha256sums
  rm -rf "$KERNDIR"/boot "$KERNDIR"/dtb "$KERNDIR"/modules "$KERNDIR"/header
  cp "$PKGS"/*.tar.gz "$KERNDIR"/
  [[ -f $PKGS/sha256sums ]] && cp "$PKGS/sha256sums" "$KERNDIR"/
  echo "staged: $PKGS → $KERNDIR（KNAME=$KNAME）"
}

# 配置语义比对：忽略注释/空行/olddefconfig 噪声，只看「符号=值」。
# 用法：x96_cfg_same <a.config> <b.config>  → 0 相同，1 不同（会打印差异符号数）
x96_cfg_same() {
  python3 - "$1" "$2" <<'PYEOF'
import sys
def load(p):
    d = {}
    for line in open(p, errors='replace'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        k, _, v = line.partition('=')
        d[k] = v
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
diff = [k for k in set(a) | set(b) if a.get(k) != b.get(k)]
if diff:
    print(f"  语义差异 {len(diff)} 个符号，例如: " + ", ".join(sorted(diff)[:5]))
    sys.exit(1)
PYEOF
}

# 一行三元组，给各脚本 echo 用
x96_mode_show() {
  printf 'MODE=%s  KNAME=%s  CFG=%s  KSRC=%s  OUT=%s  PKGS=%s\n' \
    "$MODE" "$KNAME" "$CFG" "$KSRC" "$OUT" "$PKGS"
}
