#!/bin/bash
# x98h（H618 百兆网口版）新机器一键装内核 7.2.12-x98
#
# 一条命令:
#   curl -fsS -u '18072858035:$$Wuyou272097579' -O http://192.168.1.53:5005/sata11-18072858035/X98H/install-x98h-kernel.sh && bash install-x98h-kernel.sh
#
# 开关（原样透传给包里的 install.sh）:
#   -y                  不问直接装
#   --display <mode>    覆盖 video=，如 1920x1080@60 / 2560x1440@60e（接的不是 BenQ QHD 就要改）
#   --no-edid           去掉 drm.edid_firmware，用真显示器 EDID
#   --dtb <name>        覆盖 fdtfile，如 allwinner/sun50i-h618-x98h.dtb
#   --keep-env          完全不动 /boot/armbianEnv.txt
#   --boot-scr          连 /boot/boot.cmd + boot.scr 一起装
#   --tarball <path>    用本地包，不从 NAS 下（离线/拷 U 盘用）
#   --url <base>        换 NAS 地址
set -euo pipefail

KVER=7.2.12-x98
NAME=x98h-kernel-$KVER
WANT_SHA=10fbd727e15c3c484d077071ea379abc8fbbcb5418c6cdb1fed748db29fc195e
BASE="${X98_BASE:-http://192.168.1.53:5005/sata11-18072858035/X98H}"
USERPASS="${X98_AUTH:-18072858035:\$\$Wuyou272097579}"
LOCAL_TAR=""
PASS_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --tarball) LOCAL_TAR="${2:?--tarball 需要路径}"; shift ;;
    --url)     BASE="${2:?--url 需要地址}"; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *)         PASS_ARGS+=("$1") ;;
  esac
  shift
done

[ "$(id -u)" = 0 ] || { echo "必须 root 跑"; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "目标必须是 aarch64（这是 H618 的 aarch64 内核）"; exit 1; }

need=$( [ -n "$LOCAL_TAR" ] && echo 300 || echo 420 )   # MB
avail=$(df -Pm /root | awk 'NR==2{print $4}')
echo "== 检查 ==  free /root ${avail} MB，需要 ≥ ${need} MB，arch $(uname -m)"
[ "$avail" -ge "$need" ] || { echo "空间不够"; exit 1; }

TAR=/root/$NAME.tar.bz2
if [ -n "$LOCAL_TAR" ]; then
  echo "== 1. 用本地包 $LOCAL_TAR =="
  cp -f "$LOCAL_TAR" "$TAR"
else
  echo "== 1. 从 NAS 下载 =="
  echo "  $BASE/$NAME.tar.bz2"
  curl -fL --connect-timeout 10 --retry 3 -u "$USERPASS" -o "$TAR" "$BASE/$NAME.tar.bz2" \
    || { echo "下载失败（NAS 没开 / 账号不对）"; exit 1; }
fi
echo "  $(stat -c %s "$TAR") B"

echo "== 2. 校验 sha256 =="
got=$(sha256sum "$TAR" | cut -d' ' -f1)
echo "  $got"
if [ "$got" != "$WANT_SHA" ]; then
  echo "  !! 与预期 $WANT_SHA 不符，停止（包传坏了或版本不是 $KVER）"
  exit 1
fi

echo "== 3. 解包 =="
rm -rf "/root/$NAME"
tar -xjf "$TAR" -C /root
[ -x "/root/$NAME/install.sh" ] || { echo "包里没有 install.sh"; exit 1; }

echo "== 4. 安装 =="
cd "/root/$NAME"
exec ./install.sh "${PASS_ARGS[@]+"${PASS_ARGS[@]}"}"
