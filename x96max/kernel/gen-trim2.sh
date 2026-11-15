#!/bin/bash
# x96max/kernel/gen-trim2.sh —— 第二轮（真正的硬件裁剪，2026-11-15）
#
# 与 gen-trim.sh（第一轮，只砍 =m 的一部分）的区别：
#   1. 基线必须是【全量源码树】的配置（已归档为
#      configs/config-7.2.12-fulltree-baseline-20261115，257801 B；
#      原 /x96-build/kbuild-clean 构建树 2026-11-15 已删除，只留这份 .config），
#      避免 §5.7 那种"Kconfig 悬空 → 符号静默消失"的假裁剪。
#   2. 规则 A：除了白名单，全部 =m 一律关掉（板子上要的东西全是 =y，模块只需要
#      WiFi/BT/音频/GPU/视频硬解/串口/网络扩展这几类）。
#   3. 规则 B：=y 只动"整块子系统"开关（媒体/DVB、其他 SoC、ATA、MD、MTD、
#      SCSI 低层、virtio、KVM、其它文件系统），不动任何 MESON 驱动。
#
# 用法：
#   ./x96max/kernel/gen-trim2.sh        # 默认基线见下
#   # 输出 /x96-build/trim2-$(date +%Y%m%d).fragment
# 应用：
#   cp $BASE /x96-build/kbuild-trim/.config
#   cat <fragment> >> /x96-build/kbuild-trim/.config
#   make -C /x96-build/src-clean O=/x96-build/kbuild-trim ARCH=arm64 \
#        CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BASE=${BASE:-$REPO/configs/config-7.2.12-fulltree-baseline-20261115}
# 兜底：全量构建树若还在，仍优先用它的 .config（与归档同源）
[[ -f /x96-build/kbuild-clean/.config && -z ${BASE_FORCE:-} ]] && BASE=/x96-build/kbuild-clean/.config
OUT=${OUT:-/x96-build/trim2-$(date +%Y%m%d-%H%M).fragment}
[ -f "$BASE" ] || { echo "缺基线配置: $BASE" >&2; exit 2; }

# ---- 规则 A：=m 白名单（正则，匹配即保留）----
KEEP_M='^(SND_MESON_|SND_SOC_MESON|DRM_PANFROST|DRM_GEM_SHMEM|DRM_SCHED|VIDEO_MESON_|VIDEOBUF2|WLAN|CFG80211|MAC80211|RFKILL|RTW88|BT|BT_HCIUART|BT_RTL|USB_SERIAL$|USB_SERIAL_(FTDI_SIO|PL2303|CH343)$|USB_ACM$|NF_TABLES|NFT_|NF_NAT$|NF_CONNTRACK$|NF_DEFRAG_IPV[46]|NF_SOCKET_IPV[46]|NF_TPROXY_IPV[46]|IP_NF_|IP6_NF_|NETFILTER_XTABLES|XT_|TUN$|TAP$|VETH|MACVLAN|VLAN_8021Q|GARP|MRP|WIREGUARD|PPPOE|ZRAM|ISO9660_FS|NTFS3_FS|IR_MESON|RTC_DRV_MESON|CRYPTO_(AES|SHA[0-9]+|CBC|CTR|CCM|GCM|CMAC|GHASH|LIB_)|TEXTSEARCH_KMP)'

# ---- 规则 B：=y 整块子系统关闭（精确符号，写全 CONFIG_ 名字）----
Y_OFF=(
  # 其他 SoC 平台
  ARCH_SUNXI ARCH_ROCKCHIP
  # 媒体：DVB/模拟电视/收音/SDR/摄像头/USB 采集整块不要；只留平台媒体(meson vdec)
  MEDIA_ANALOG_TV_SUPPORT MEDIA_DIGITAL_TV_SUPPORT MEDIA_CAMERA_SUPPORT \
  MEDIA_RADIO_SUPPORT MEDIA_SDR_SUPPORT MEDIA_TEST_SUPPORT \
  MEDIA_PCI_SUPPORT MEDIA_USB_SUPPORT MEDIA_SUBDRV_SUPPORT \
  DVB_CORE CEC_CORE CEC_MESON_AO CEC_MESON_G12A_AO
  # 大块内核子系统：板子上没有对应硬件
  # 注意：STAGING 不能关 —— meson 的硬解驱动 VIDEO_MESON_VDEC 就在 staging/media 里
  ATA MD MTD SCSI_LOWLEVEL VIRTIO INFINIBAND ISDN HAMRADIO CAN NFC \
  ATM WAN 6LOWPAN IEEE802154 TARGET_CORE FUSION
  # 虚拟化/其他架构
  KVM HYPERVISOR_GUEST PARAVIRT
  # 用不到的文件系统（保留 ext4/vfat/exfat/squashfs/overlay/fuse/tmpfs/ntfs3/iso9660）
  XFS_FS BTRFS_FS F2FS_FS GFS2_FS OCFS2_FS CEPH_FS CIFS NFS_FS NFSD \
  AUTOFS_FS JFS_FS REISERFS_FS UDF_FS HFS_FS HFSPLUS_FS MINIX_FS OMFS_FS \
  NILFS2_FS ZONEFS_FS EROFS_FS CRAMFS ROMFS_FS AFFS_FS BEFS_FS QNX4FS_FS \
  QNX6FS_FS SYSV_FS UFS_FS ADFS_FS VXFS_FS ORANGEFS_FS
)

{
  echo "# ============================================================"
  echo "# X96 Max（S905X2/meson-g12a）第二轮裁剪 —— 由 gen-trim2.sh 生成"
  echo "# 基线: $BASE"
  echo "# 生成: $(date '+%F %T')"
  echo "# ============================================================"
  echo
  echo "# --- 规则 B：=y 整块子系统 ---"
  for s in "${Y_OFF[@]}"; do echo "# CONFIG_$s is not set"; done
  echo
  echo "# --- 规则 A：=m 只留白名单 ---"
  while read -r sym; do
    if grep -qP "$KEEP_M" <<<"$sym"; then
      echo "# KEEP $sym"
    else
      echo "# CONFIG_$sym is not set"
    fi
  done < <(grep -oP '^CONFIG_\K[A-Za-z0-9_]+(?==m$)' "$BASE" | sort)
} > "$OUT"

echo "生成 $OUT"
echo "  关闭 =m: $(grep -c 'is not set' "$OUT")"
echo "  保留 =m: $(grep -c '^# KEEP' "$OUT")"
echo "  关闭 =y: $(printf '%s\n' "${Y_OFF[@]}" | wc -l)"
# 白名单里混进了 MESON 之外的东西？不该砍 MESON 任何一项
if grep 'is not set' "$OUT" | grep -qE 'MESON|AMLOGIC|AXG|G12A|STMMAC|XHCI|DWC3|HDMI|PINCTRL'; then
  echo '✗ 误砍板载驱动:'; grep 'is not set' "$OUT" | grep -E 'MESON|AMLOGIC|AXG|G12A|STMMAC|XHCI|DWC3|HDMI|PINCTRL'
else
  echo '✓ 无板载 MESON/USB/NET 驱动被砍'
fi
