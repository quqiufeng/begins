#!/bin/bash
# x96max/kernel/gen-trim.sh —— X96 Max（S905X2 / meson-g12a）激进版内核裁剪 fragment
#
# 做法参照本机 sandy-dbg3：不逐项微调，把「板子上物理不存在」的整类 =m 关掉
# （本机实测 4382 项 → 1843 项、模块 1786 → 111；裁过的内核在小机箱正常跑）。
#
# 用法：./x96max/kernel/gen-trim.sh            # 输出同目录 x96-trim.fragment
# 应用：cat x96-trim.fragment >> .config && make ARCH=arm64 olddefconfig
#
# 约束：只动 =m。MESON/G12A/AIU/AXG/STMMAC/XHCI/DWC3/HDMI/PINCTRL/MMC/VIDEOBUF2 由 KEEP 保护。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CFG=${CFG:-$HERE/config-7.2.12-x96}
OUT=${OUT:-$HERE/x96-trim.fragment}
[ -f "$CFG" ] || { echo "缺 config: $CFG" >&2; exit 2; }

KEEP='MESON|G12A|AIU|AXG|STMMAC|PINCTRL|XHCI|DWC3|EHCI|OHCI|AMLOGIC|SIMPLEDRM|FBDEV|VIDEOBUF2|HDMI|SPDIF|DW_|USB_HID|HID_GENERIC|HIDRAW|HID_MICROSOFT|HID_APPLE'
emit() {
  local pat="$1" note="$2" sym
  printf '\n# --- %s ---\n' "$note"
  while read -r sym; do
    if grep -qP "$KEEP" <<<"$sym"; then echo "# KEEP $sym"; else echo "# CONFIG_$sym is not set"; fi
  done < <(grep -oP "^CONFIG_\K[A-Z0-9_]+(?==m\$)" "$CFG" | grep -P "^$pat\$" | sort)
}
{
cat <<'HDR'
# ============================================================
# X96 Max（S905X2 / meson-g12a）内核裁剪 fragment —— 激进版
# 由 x96max/kernel/gen-trim.sh 从 config-7.2.12-x96 实际扫描生成；手改请改脚本。
# 目标：2896 个 =m 压到 ~1100 以内，做法同本机 sandy-dbg3。
# ============================================================
CONFIG_DEBUG_INFO_NONE=y
# CONFIG_DEBUG_INFO_BTF is not set
# CONFIG_DEBUG_INFO_BTF_MODULES is not set
HDR
emit 'DVB.*'                        'DVB 数字电视：X96 Max 无 tuner'
emit 'MEDIA_TUNER.*'                'MEDIA 调谐器：无 tuner'
emit 'VIDEO_[A-Z0-9_]+'             'V4L2 平台/子设备：只留 MESON 与 VIDEOBUF2'
emit 'TOUCHSCREEN.*'                '触摸屏：盒子没有触摸面板'
emit 'CAN.*'                        'CAN 总线：无'
emit 'W1.*'                         '1-Wire：无'
emit 'FPGA.*'                       'FPGA 管理：无'
emit 'JOYSTICK.*'                   '游戏摇杆：优先交给 HID'
emit 'DRM_PANEL.*'                  'DRM 面板描述：外接屏用不到'
emit 'IIO_.*|.*_IIO.*'              'IIO 传感器：板上只有 SARADC(已 =y)'
emit 'HID_.*'                       'HID 外设类：只留通用/USB/键鼠'
emit 'USB_GSPCA.*'                  'GSPCA 摄像头：uvcvideo 已够'
emit 'USB_SERIAL_.*'                'USB 串口芯片：按需再开'
emit 'USB_NET.*'                    'USB 网卡：板载 STMMAC 已够'
emit 'USB_(ATM|CDNS|CHIPIDEA|CONFIGFS|GADGET|DUMMY|HSIC|ISP|MUSB|R8A|RENESAS|SNP|TEGRA|UAS|ULPI|IP).*' 'USB 杂项/其他 SoC 控制器/Gadget'
emit 'SND_HDA.*'                    'HDA：x86 专用'
emit 'SND_USB_.*'                   'USB 声卡：先关，需要再开'
emit 'SND_SOC_.*'                   'SND_SOC 离片 codec/平台（MESON 由 KEEP 保护）'
emit 'SPI_.*'                       'SPI 外设：板上无 SPI 外接'
emit 'LEDS_.*'                      'LED 驱动：板上只有电源灯'
emit 'MMC_.*'                       'MMC 其他 SoC 主机控制器'
emit 'FB_.*'                        'legacy fbdev：meson 走 DRM'
emit 'DRM_[A-Z0-9_]+'               'DRM 非 meson GPU/驱动'
emit 'NET_DSA.*'                    'DSA 交换机：盒子无交换芯片'
emit 'NET_SCH_.*'                   '网络 qdisc：板载网只需默认'
emit 'NET_ACT_.*'                   '网络 action：无 tc 场景'
emit 'NET_CLS_.*'                   '网络 classifier：无 tc 场景'
emit 'NET_EMATCH.*'                 '网络 ematch：无 tc 场景'
emit 'NET_TEAM.*'                   '网卡绑定 team：用 bonding 即可'
emit 'NET_IFE.*|NET_NSH.*|NET_PKTGEN.*|NET_VRF.*|NET_9P.*|NET_IPGRE.*' '网络实验/隧道杂项'
emit 'NLS_(?!UTF8|ASCII|CP437|ISO8859_1|DEFAULT).*' 'NLS 字符集：只留 utf8/ascii/cp437/latin1'
emit 'NFT_.*|NF_TABLES.*'           'nftables：盒子不做路由，按需再开'
emit 'CRYPTO_DEV.*'                 '硬件加密：无加密卡'
emit 'RTC_DRV.*'                    'RTC 驱动：其他 SoC'
emit 'GPIO_.*'                      'GPIO 扩展/其他 SoC'
} > "$OUT"
echo "生成 $OUT：砍 $(grep -c 'is not set' "$OUT") 项，KEEP 保留 $(grep -c '^# KEEP' "$OUT") 项"
if grep 'is not set' "$OUT" | grep -qE 'MESON|G12A|AIU|STMMAC|XHCI|DWC3|HDMI|PINCTRL|VIDEOBUF2'; then
  echo '✗ 误砍板载行：'; grep 'is not set' "$OUT" | grep -E 'MESON|G12A|AIU|STMMAC|XHCI|DWC3|HDMI|PINCTRL|VIDEOBUF2'
else echo '✓ 无 MESON/板载驱动被误砍'; fi
