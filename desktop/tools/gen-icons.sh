#!/bin/sh
# desktop/tools/gen-icons.sh — 把本机图标主题里的对应图标抠出来，落到 assets/icons/
#
# 只做一次的事：主题里是 SVG，运行时装 SDL2_image 解不了 SVG，
# 所以在这里用 ImageMagick 转成 256x256 PNG，桌面上按需缩放。
#
#   ./tools/gen-icons.sh                       # 自动读当前 GTK 图标主题
#   THEME=Papirus-Dark ./tools/gen-icons.sh    # 指定主题
#   OUT=/tmp/x ./tools/gen-icons.sh            # 指定输出目录
#
# 找图顺序：主题里最大的 SVG/PNG → Adwaita → hicolor（总有兜底）。
set -eu

OUT=${OUT:-$(cd "$(dirname "$0")/.." && pwd)/assets/icons}
SIZE=${SIZE:-256}
THEME=${THEME:-$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'")}
THEME=${THEME:-Papirus}
ICON_ROOT=${ICON_ROOT:-/usr/share/icons}
FALLBACKS="Adwaita hicolor"

# 类别 → 主题里的图标名（mimetypes/places，不带目录）
icon_name() {
	case "$1" in
	dir)   echo places/folder ;;
	video) echo mimetypes/video-x-generic ;;
	audio) echo mimetypes/audio-x-generic ;;
	image) echo mimetypes/image-x-generic ;;
	ebook) echo mimetypes/application-epub+zip ;;
	other) echo mimetypes/text-x-generic ;;
	esac
}

# 在主题目录里找同名图标：尺寸目录大的优先（256x256 > 48x48 > scalable）
find_icon() {
	rel=$1
	for theme in $THEME $FALLBACKS; do
		dir=$ICON_ROOT/$theme
		[ -d "$dir" ] || continue
		hit=$(find -L "$dir" -type f \( -name "$(basename "$rel").svg" \
			-o -name "$(basename "$rel").png" \) -path "*/$(dirname "$rel")/*" 2>/dev/null |
			awk -F/ '{s=$0; gsub(/[^0-9]/," ",s); n=split(s,a," ");
				best=0; for(i=1;i<=n;i++) if(a[i]+0>best) best=a[i]+0;
				if($0 ~ /scalable/) best=9999;
				printf "%05d %s\n", best, $0}' |
			sort -rn | head -1 | cut -d' ' -f2-)
		if [ -n "$hit" ]; then echo "$hit"; return 0; fi
	done
	return 1
}

mkdir -p "$OUT"
for kind in dir ebook video audio image other; do
	rel=$(icon_name "$kind")
	src=$(find_icon "$rel" || true)
	if [ -z "$src" ]; then
		echo "跳过 $kind：主题 $THEME 里没有 $rel" >&2
		continue
	fi
	convert -background none "$src" -resize "${SIZE}x${SIZE}" -strip "PNG32:$OUT/$kind.png"
	echo "$kind <- ${src#/usr/share/icons/}"
done
