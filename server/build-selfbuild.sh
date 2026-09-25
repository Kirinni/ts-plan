#!/usr/bin/env bash
# 本地交叉编译「单二进制」Tailscale（自带 CLI），用于 R4A 千兆版（MT7621 / mipsel / softfloat）
#
#   VER=1.102.4 OUT=./out bash server/build-selfbuild.sh
#
# 为什么值得自己编（实测数据）：
#   自编译单二进制 : 30.5MB，含 CLI，gzip 后 9.9MB
#   官方静态包     : tailscaled 38.7MB（不含 CLI）+ tailscale 32.1MB，gzip 后 17.7+14.3MB
#   → 内存与下载量都约减半，而且不用为"注册时临时拉 CLI"折腾
#
# 关键编译配方（和 OpenWrt 包一致）：
#   -tags ts_include_cli   ← 把 CLI 合进 tailscaled，单文件即可 `tailscale up`
#   -tags ts_omit_*        ← 裁掉 aws/bird/kube/systray 等用不到的部分
#   GOARCH=mipsle GOMIPS=softfloat CGO_ENABLED=0  ← 匹配无 FPU 的 24KEc，且全静态
#   -trimpath -ldflags "-s -w"                    ← 去掉路径/调试信息，体积明显变小
#
# 环境：脚本会自己把 Go 准备好，不写 /usr/local、不需要 root
#   本机 Go 已满足要求        → 直接用
#   本机 Go 偏低但 >= 1.21    → 交给 GOTOOLCHAIN=auto 自动拉工具链（走 GOPROXY）
#   本机完全没有 Go           → 从 go.dev 下官方 tarball 到临时目录，校验 sha256，用完即弃
# 可调环境变量：
#   GO_BOOTSTRAP=0    关掉自动安装：缺 Go 直接报错退出
#   GO_VERSION=1.27.1 强制指定要装的 Go 版本（默认按源码 go.mod 里的要求）
#   GO_MIRRORS="https://go.dev https://golang.google.cn"   下载源，空格分隔、按序尝试
set -euo pipefail

VER="${VER:-1.102.4}"
OUT="${OUT:-$PWD/out}"
TAGS="${TAGS:-ts_include_cli,ts_omit_aws,ts_omit_bird,ts_omit_clientupdate,ts_omit_completion,ts_omit_kube,ts_omit_systray,ts_omit_taildrop,ts_omit_tap,ts_omit_tpm}"
LDF="${LDF:--s -w -X tailscale.com/version.longStamp=${VER}-selfbuilt -X tailscale.com/version.shortStamp=${VER}}"
GO_BOOTSTRAP="${GO_BOOTSTRAP:-1}"
GO_VERSION="${GO_VERSION:-}"
GO_MIRRORS="${GO_MIRRORS:-https://go.dev https://golang.google.cn}"
[ -n "$GO_MIRRORS" ] || GO_MIRRORS="https://go.dev"
export LANG="${LANG:-C.UTF-8}"

# ------------------------------ 小工具 ------------------------------
ver_ge() { # $1 >= $2 ？
	awk -v a="$1" -v b="$2" 'BEGIN{
		na=split(a,A,"."); nb=split(b,B,".");
		n=(na>nb)?na:nb;
		for(i=1;i<=n;i++){ if(A[i]+0>B[i]+0) exit 0; if(A[i]+0<B[i]+0) exit 1 }
		exit 0
	}'
}
http_get() {
	if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"
	elif command -v wget >/dev/null 2>&1; then wget -qO- "$1"
	else return 127; fi
}
http_dl() { # $1=url $2=输出文件；交互终端显示进度，重定向时安静
	if command -v curl >/dev/null 2>&1; then
		if [ -t 2 ]; then curl -fL --retry 2 --connect-timeout 15 -o "$2" "$1"
		else curl -fsSL --retry 2 --connect-timeout 15 -o "$2" "$1"; fi
	elif command -v wget >/dev/null 2>&1; then
		if [ -t 2 ]; then wget -O "$2" "$1"; else wget -q -O "$2" "$1"; fi
	else return 127; fi
}
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
	else return 127; fi
}
host_os()   { case "$(uname -s)" in Linux) echo linux ;; Darwin) echo darwin ;; *) echo "" ;; esac; }
host_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo "" ;; esac; }

# ------------------------- Go 环境自动准备 -------------------------
install_go() { # $1 = 期望版本（用来判断镜像够不够新）
	local want="$1" m os arch json fname ver sha url got
	os="$(host_os)"; arch="$(host_arch)"
	if [ -z "$os" ] || [ -z "$arch" ]; then
		echo "!! 自动安装 Go 不支持当前平台（$(uname -s) / $(uname -m)）。" >&2
		echo "   Windows 原生请改在 WSL 里跑，或手动装：https://go.dev/dl/" >&2
		exit 1
	fi
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		echo "!! 自动安装 Go 需要 curl 或 wget。" >&2
		exit 1
	fi

	echo ">> 本机 Go 缺失或过低 → 下载官方 tarball（放临时目录，用完即弃，不需要 root）"
	json=""
	for m in $GO_MIRRORS; do
		if json="$(http_get "$m/dl/?mode=json" 2>/dev/null)"; then break; fi
		json=""
	done
	[ -n "$json" ] || { echo "!! 拉取 Go 版本索引失败（网络或代理？可 GO_MIRRORS=... 换源）" >&2; exit 1; }

	# 索引默认只给最新稳定版，取第一个匹配本机 os/arch 的归档
	fname="$(printf '%s' "$json" | grep -o "go[0-9][0-9.]*\.${os}-${arch}\.tar\.gz" | head -n1)"
	[ -n "$fname" ] || { echo "!! 索引里找不到 ${os}/${arch} 的归档包" >&2; exit 1; }
	ver="${fname#go}"; ver="${ver%%.${os}-${arch}.tar.gz}"
	if ! ver_ge "$ver" "$want"; then
		echo "!! 镜像里最新稳定版是 $ver，低于源码 go.mod 要求的 $want" >&2
		echo "   指定版本：GO_VERSION=$want，或换源：GO_MIRRORS=https://go.dev" >&2
		exit 1
	fi

	# 官方索引里带 sha256，必须校验（拒绝来路不明的工具链）
	sha="$(printf '%s' "$json" | tr -d '\n' \
		| grep -o "{[^{}]*\"filename\": \"$fname\"[^{}]*}" \
		| sed -n 's/.*"sha256": "\([0-9a-f]\{64\}\)".*/\1/p')"
	[ -n "$sha" ] || { echo "!! 没解析出 $fname 的 sha256，为安全起见拒绝安装" >&2; exit 1; }

	url="$m/dl/$fname"
	echo "   版本 $ver → $url"
	http_dl "$url" "$W/go.tar.gz" || { echo "!! 下载失败（网络或代理？）" >&2; exit 1; }
	got="$(sha256_of "$W/go.tar.gz")" || { echo "!! 本机没有 sha256sum/shasum，无法校验，拒绝安装" >&2; exit 1; }
	if [ "$got" != "$sha" ]; then
		echo "!! Go tarball 校验失败，已丢弃" >&2
		echo "   期望 $sha" >&2
		echo "   实际 $got" >&2
		exit 1
	fi
	mkdir -p "$W/gotmp"
	tar -xzf "$W/go.tar.gz" -C "$W/gotmp" || { echo "!! 解压失败" >&2; exit 1; }
	mv "$W/gotmp/go" "$W/go"
	rm -f "$W/go.tar.gz"; rmdir "$W/gotmp" 2>/dev/null || true
	echo "   OK 临时 Go：$("$W/go/bin/go" version)"
	echo "   提示：它在临时目录里，本次跑完即删（下次还会重下）。常用的话建议正式装一个。"
}

ensure_go() {
	local req have
	req="$(sed -n 's/^go \([0-9][0-9.]*\)$/\1/p' go.mod | head -n1)"
	[ -n "$req" ] || req="1.21"
	[ -n "$GO_VERSION" ] && req="$GO_VERSION"
	# 注意：不能用 `have="$(go version | sed ...)"` —— pipefail 会让"go 不存在"的 127
	#       顺着管道冒出来，被 set -e 直接杀掉，连提示都打不出来。
	have=""
	if command -v go >/dev/null 2>&1; then
		have="$(go version 2>/dev/null | sed -n 's/.*go\([0-9][0-9.]*\).*/\1/p' | head -n1)"
	fi

	if [ -n "$have" ] && ver_ge "$have" "$req"; then
		echo ">> Go $have 已满足要求（源码 go.mod 要求 $req）"
		return 0
	fi
	if [ -n "$have" ] && ver_ge "$have" "1.21"; then
		# Go >= 1.21 自带 GOTOOLCHAIN：让它自己拉工具链，比我们重下整套更省事
		echo ">> 本机 Go $have 低于要求的 $req → 交给 GOTOOLCHAIN=auto 自动拉工具链"
		echo "   注意：它走 GOPROXY，国内可加 GOPROXY=https://goproxy.cn,direct"
		export GOTOOLCHAIN=auto
		return 0
	fi
	if [ "$GO_BOOTSTRAP" != "1" ]; then
		echo "!! 本机没有 Go（或版本过低：${have:-无}），且 GO_BOOTSTRAP=0 已关闭自动安装。" >&2
		echo "   请手动安装 Go >= $req：https://go.dev/dl/" >&2
		exit 1
	fi
	install_go "$req"
	export PATH="$W/go/bin:$PATH"
}

command -v git >/dev/null 2>&1 || { echo "!! 需要 git 来取源码（Windows 建议在 WSL 里跑本脚本）" >&2; exit 1; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

echo
echo ">> 拉取源码 v$VER（浅克隆）"
git clone --depth 1 --branch "v$VER" https://github.com/tailscale/tailscale "$W/src" >/dev/null
cd "$W/src"

ensure_go
go version

echo
echo ">> [1/3] 先编一个 amd64 版：用它验证 ts_include_cli 真的把 CLI 合进来了"
echo "   （mipsle 二进制无法在本机执行，所以用同 flag 的 amd64 版做行为断言）"
# 【注意】tailscaled 是靠 argv[0] 的 basename 判断当 daemon 还是当 CLI 的，
#         所以验证用的文件必须就叫 tailscale，不能叫 probe 之类。
mkdir -p "$W/probe"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
	go build -trimpath -tags "$TAGS" -ldflags "$LDF" -o "$W/probe/tailscale" ./cmd/tailscaled
out="$("$W/probe/tailscale" version 2>&1 | head -n1 || true)"
case "$out" in
	*"$VER"*) echo "   OK 单文件自带 CLI：$out" ;;
	*) echo "!! 自检失败：单文件没有 CLI 行为（该版本的 tags 可能不同）" >&2
	   echo "   实际输出：$out" >&2
	   exit 1 ;;
esac

echo
echo ">> [2/3] 交叉编译 mipsle（softfloat）"
mkdir -p "$OUT"
BIN="$OUT/tailscaled_${VER}_mipsle"
CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat \
	go build -trimpath -tags "$TAGS" -ldflags "$LDF" -o "$BIN" ./cmd/tailscaled

echo
echo ">> [3/3] 产物自检（防止误发 hardfloat / 动态链接的版本）"
RE=""
for c in readelf llvm-readelf greadelf; do
	if command -v "$c" >/dev/null 2>&1; then RE="$c"; break; fi
done
if [ -n "$RE" ]; then
	if ! "$RE" -A "$BIN" 2>/dev/null | grep -q 'Soft float'; then
		echo "!! 不是 soft float 构建，MT7621 上会非法指令" >&2
		exit 1
	fi
	if "$RE" -d "$BIN" 2>/dev/null | grep -q NEEDED; then
		echo "!! 存在动态依赖（CGO_ENABLED 应为 0）" >&2
		exit 1
	fi
	echo "   OK Soft float + 静态链接（$RE）"
else
	echo "   !! 本机没有 readelf/llvm-readelf/greadelf，ELF 断言被跳过 —— 请自行确认产物" >&2
	echo "      macOS 可 brew install binutils（提供 greadelf），或改在 Linux/WSL 里编" >&2
fi

raw=$(wc -c < "$BIN")
gz=$(gzip -9nc "$BIN" | wc -c)
sha256_of "$BIN" > "$BIN.sha256" || { echo "!! 本机没有 sha256sum/shasum" >&2; exit 1; }

echo
echo "==================== 产物 ===================="
echo "文件   : $BIN"
mb() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }
echo "体积   : raw $(mb "$raw") MB | gzip $(mb "$gz") MB（≈ 每次开机下载量）"
echo "sha256 : $(cat "$BIN.sha256")"
echo
echo "下一步：把二进制传到 VPS 上打包分发"
echo "  scp $BIN root@<你的VPS>:/root/"
echo "  # 在 VPS 上："
echo "  SOURCE=local BINARY=/root/$(basename "$BIN") bash server/make-artifact.sh"
echo
echo "然后把打印出的那一行粘到路由器 /etc/tailscale/ts.conf 的 TS_ARTIFACTS，"
echo "TS_CLI_ARTIFACTS 留空（此版本自带 CLI）。"
