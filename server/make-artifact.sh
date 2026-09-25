#!/usr/bin/env bash
# 生成给路由器拉取的 Tailscale 工件。
#
#   # 默认：官方静态构建（推荐。mipsle 实测为 Soft float + 完全静态，硬件兼容性最好）
#   SOURCE=official VER=1.102.4 OUT=/srv/ts bash make-artifact.sh
#
#   # 可选：从 OpenWrt 的 24.10 分支 ipk 拆包（只有 1.80.3，headscale 可能嫌旧）
#   SOURCE=openwrt OUT=/srv/ts bash make-artifact.sh
#
# 产出两个工件（各自 tar.gz + .sha256）：
#   tailscaled_<ver>_mipsle.tar.gz      只含 daemon —— 开机日常拉这个（约 14MB）
#   tailscale-cli_<ver>_mipsle.tar.gz   只含 CLI  —— 仅首次注册时拉一次（约 12MB）
#
# 为什么拆成两个：官方静态构建的 tailscaled 不含 CLI，两个加起来解压后 70.8MB，
# 128MB 内存的 R4A 扛不住；而 CLI 只在注册时需要一次，之后 state 持久化在
# overlay，daemon 自己就能恢复连接，日常只需 38.7MB 的 tailscaled。
set -euo pipefail

SOURCE="${SOURCE:-official}"        # official | openwrt
VER="${VER:-1.102.4}"                # 官方静态包版本（SOURCE=official 时生效）
ARCH_GO="${ARCH_GO:-mipsle}"         # Go 架构名：MT7621 是 mipsel(小端/softfloat)
ARCH_OWRT="${ARCH_OWRT:-mipsel_24kc}"
OUT="${OUT:-/srv/ts}"
BASE_URL="${BASE_URL:-https://dl.example.com/ts/CHANGE_ME_TOKEN}"

mkdir -p "$OUT"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 把单个文件压成 tar.gz（-n 不写时间戳，便于重建时结果稳定）
pack_one() { # $1=源文件  $2=包内文件名  $3=输出路径
	local stage="$work/stage"
	rm -rf "$stage" && mkdir -p "$stage"
	cp -f "$1" "$stage/$2"
	tar -cf - -C "$stage" "$2" | gzip -9n > "$3"
	sha256sum "$3" | cut -d' ' -f1 > "$3.sha256"
	ls -l "$3" | awk -v n="$3" '{printf "   %s  %.1f MB\n", n, $5/1048576}'
}

emit() { # $1=工件路径  $2=用途说明
	local f="$1" sha
	sha="$(cat "$f.sha256")"
	echo "   $sha $BASE_URL/$(basename "$f")    # $2"
}

# ---------------------------------------------------------------------------
if [ "$SOURCE" = "official" ]; then
	url="https://pkgs.tailscale.com/stable/tailscale_${VER}_${ARCH_GO}.tgz"
	echo ">> 来源：官方静态构建"
	echo ">> 下载 $url"
	curl -fL --retry 3 --connect-timeout 15 -o "$work/pkg.tgz" "$url"

	echo ">> 校验官方 sha256 sidecar"
	expect="$(curl -fsSL "$url.sha256" | tr -d '[:space:]')"
	got="$(sha256sum "$work/pkg.tgz" | cut -d' ' -f1)"
	if [ "$expect" != "$got" ]; then
		echo "!! sha256 校验失败：期望 $expect / 实得 $got" >&2
		exit 1
	fi
	echo "   OK $got"

	tar xzf "$work/pkg.tgz" -C "$work"
	d="$work/tailscale_${VER}_${ARCH_GO}"
	for f in tailscaled tailscale; do
		[ -x "$d/$f" ] || { echo "!! 包里缺少 $f" >&2; exit 1; }
	done

	echo ">> 打包"
	pack_one "$d/tailscaled" tailscaled "$OUT/tailscaled_${VER}_${ARCH_GO}.tar.gz"
	pack_one "$d/tailscale"  tailscale  "$OUT/tailscale-cli_${VER}_${ARCH_GO}.tar.gz"

	echo
	echo "把下面两行分别粘到 router/ts.conf："
	emit "$OUT/tailscaled_${VER}_${ARCH_GO}.tar.gz"     "TS_ARTIFACTS（开机日常，常驻内存）"
	emit "$OUT/tailscale-cli_${VER}_${ARCH_GO}.tar.gz"  "TS_CLI_ARTIFACTS（仅 ts-login 首次注册时用）"

# ---------------------------------------------------------------------------
elif [ "$SOURCE" = "openwrt" ]; then
	FEED="releases/24.10.0/packages/${ARCH_OWRT}/packages"
	echo ">> 来源：OpenWrt $FEED（注意：只有 1.80.3）"
	for m in "https://mirrors.tuna.tsinghua.edu.cn/openwrt" "https://downloads.openwrt.org"; do
		listing="$(curl -fsSL --max-time 60 "$m/$FEED/" 2>/dev/null \
			| grep -oE "tailscale_[0-9][^\"]+_${ARCH_OWRT}\.ipk" | sort -Vu | tail -n1 || true)"
		[ -n "$listing" ] && { url="$m/$FEED/$listing"; break; }
	done
	if [ -z "${url:-}" ]; then
		echo "!! 没找到 tailscale ipk。" >&2
		echo "   注意：snapshots/main 已经改用 apk 格式（ADB 容器），本脚本不拆 apk；" >&2
		echo "   要新版本请用 SOURCE=official。" >&2
		exit 1
	fi

	echo ">> 下载 $url"
	curl -fL --retry 3 --connect-timeout 15 -o "$work/ts.ipk" "$url"

	mkdir -p "$work/x" && cd "$work/x"
	tar xzf ../ts.ipk data.tar.gz
	tar xzf data.tar.gz ./usr/sbin/tailscaled
	ver="$(cd "$work/x" && tar xzf ../ts.ipk control.tar.gz && sed -n 's/^Version: *//p' ./control | head -n1)"
	[ -n "$ver" ] || ver="unknown"

	echo ">> OpenWrt 的包是单二进制（编译期 ts_include_cli），CLI 由软链提供"
	pack_one "$work/x/usr/sbin/tailscaled" tailscaled "$OUT/tailscaled_${ver}_${ARCH_OWRT}.tar.gz"

	echo
	echo "把下面这行粘到 router/ts.conf 的 TS_ARTIFACTS："
	emit "$OUT/tailscaled_${ver}_${ARCH_OWRT}.tar.gz" "单二进制，自带 CLI，不需要 TS_CLI_ARTIFACTS"

# ---------------------------------------------------------------------------
elif [ "$SOURCE" = "local" ]; then
	# 本地自编译的单二进制（见 server/build-selfbuild.sh）：体积最小、自带 CLI
	BIN="${BINARY:?SOURCE=local 需要指定 BINARY=/path/to/tailscaled_<ver>_mipsle}"
	[ -f "$BIN" ] || { echo "!! 找不到 $BIN" >&2; exit 1; }
	echo ">> 来源：本地自编译二进制 $BIN"

	# 发出去之前先把属性检查一遍：hardfloat 或动态链接在 MT7621 上都跑不起来
	if command -v readelf >/dev/null 2>&1; then
		if ! readelf -A "$BIN" 2>/dev/null | grep -q 'Soft float'; then
			echo "!! 不是 soft float 构建，MT7621（无 FPU）上会非法指令" >&2
			exit 1
		fi
		if readelf -d "$BIN" 2>/dev/null | grep -q NEEDED; then
			echo "!! 有动态依赖；请用 CGO_ENABLED=0 静态构建" >&2
			exit 1
		fi
		echo "   OK Soft float + 静态链接"
	else
		echo "   (本机没有 readelf，跳过 ELF 断言)"
	fi

	ver="$(basename "$BIN" | sed -n 's/.*_\([0-9][0-9.]*\)_mipsle$/\1/p')"
	[ -n "$ver" ] || ver="selfbuilt"
	pack_one "$BIN" tailscaled "$OUT/tailscaled_${ver}_${ARCH_GO}.tar.gz"

	echo
	echo "把下面这行粘到 router/ts.conf 的 TS_ARTIFACTS（TS_CLI_ARTIFACTS 留空）："
	emit "$OUT/tailscaled_${ver}_${ARCH_GO}.tar.gz" "单二进制自带 CLI，无需 CLI 工件"
else
	echo "!! SOURCE 只能是 official、openwrt 或 local" >&2
	exit 1
fi

echo
echo "提示：改版本或重新打包后，务必同步更新 ts.conf 里的 sha256。"
