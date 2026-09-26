#!/bin/sh
# bootstrap.sh —— 在路由器上免 scp 安装：从仓库拉一份快照，然后执行 router/install.sh
#
# 用法（路由器上一条命令装完）：
#
#   # 先下 bootstrap，再把安装参数透传给它
#   wget -O- https://raw.githubusercontent.com/Kirinni/ts-plan/main/router/bootstrap.sh | sh -s -- \
#     --artifact "<sha256> <url>" \
#     --login-server https://hs.example.com \
#     --routes 192.168.31.0/24 \
#     --authkey -
#
#   生产上建议 pin 到具体 commit（内容不可变，不怕上游被改）：
#   wget -O- https://raw.githubusercontent.com/Kirinni/ts-plan/<commit>/router/bootstrap.sh | sh -s -- \
#     --ref <commit> --artifact "…" …
#
# 自己的参数（下面这些会被吃掉，其余原样传给 install.sh）：
#   --ref <git-ref>       要拉取的 commit / 分支 / tag（默认 main，建议写 40 位 commit）
#   --sha256 <hex>        校验下载到的快照；强烈建议用在自建分发点上
#   --base-url <url>      仓库地址前缀，默认 https://github.com/$TS_PLAN_REPO
#                         支持 file:// 前缀，便于离线测试
#   --from <dir>          直接用本地已解压的仓库目录，完全不联网
#   --keep                保留解压出来的临时目录（排错用）
#   -h | --help
#
# 注意：本脚本只在**安装/升级时**跑一次，不在开机路径上。
#       开机只由 ts-fetch 拉 TS_ARTIFACTS 里列的地址（通常是你的 VPS），不碰 GitHub。
#
# 环境变量：TS_PLAN_REPO=owner/repo  TS_PLAN_REF=<ref>  TS_PLAN_SHA256=<hex>
set -u

REPO="${TS_PLAN_REPO:-Kirinni/ts-plan}"
REF="${TS_PLAN_REF:-main}"
SHA256="${TS_PLAN_SHA256:-}"
BASE="${TS_PLAN_BASE:-https://github.com/$REPO}"
FROM=""
KEEP=0

TMPD="$(mktemp -d)" || exit 1
: > "$TMPD/args"

# --keep 时保留现场（排错用），否则退出时清掉
cleanup() { [ "${KEEP:-0}" = 1 ] || rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM

fail() { echo "!! $*" >&2; exit 1; }

need_val() { # $1=选项名  $2=剩余参数个数
	[ "$2" -ge 2 ] || fail "$1 缺参数"
}

usage() {
	# 被 `wget -O- … | sh -s --` 这样调用时 $0 不是本文件，退化提示
	if [ -f "$0" ]; then
		sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
	else
		echo "用法见仓库 README 的「一条命令安装」一节，或直接看 router/bootstrap.sh 头部注释"
	fi
}

# 解析自己的参数，其余原样收集（含空格的 --artifact 也能安全透传）
while [ "$#" -gt 0 ]; do
	case "$1" in
		--ref)
			need_val --ref "$#"
			REF="$2"
			shift 2
			;;
		--sha256)
			need_val --sha256 "$#"
			SHA256="$2"
			shift 2
			;;
		--base-url)
			need_val --base-url "$#"
			BASE="$2"
			shift 2
			;;
		--from)
			need_val --from "$#"
			FROM="$2"
			shift 2
			;;
		--keep)
			KEEP=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf '%s\n' "$1" >> "$TMPD/args"
			shift
			;;
	esac
done

# 把收集到的参数还原成位置参数（每行一个，所以值里的空格不会丢）
set --
while IFS= read -r line; do
	set -- "$@" "$line"
done < "$TMPD/args"

# --------------------------------------------------------------------------
fetch() { # $1=url $2=输出文件
	if command -v curl >/dev/null 2>&1; then
		curl -fL --retry 2 --connect-timeout 20 -o "$2" "$1"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1"
	else
		return 127
	fi
}

SRC=""
if [ -n "$FROM" ]; then
	echo ">> 使用本地仓库目录：$FROM"
	[ -d "$FROM/router" ] || fail "$FROM 里找不到 router/ 目录"
	SRC="$FROM"
else
	case "$BASE" in
		file://*)
			pkg="$(printf '%s' "$BASE" | sed 's|^file://||')/archive/$REF.tar.gz"
			echo ">> 使用本地归档：$pkg"
			[ -f "$pkg" ] || fail "找不到 $pkg"
			cp -f "$pkg" "$TMPD/repo.tgz" || fail "复制归档失败"
			;;
		*)
			url="$BASE/archive/$REF.tar.gz"
			echo ">> 拉取 $REPO @ $REF"
			echo "   $url"
			fetch "$url" "$TMPD/repo.tgz" || fail "下载失败（网络/代理？也可以先 scp 一份再用 --from）"
			;;
	esac

	# 自建分发点时建议带上 --sha256：万一分发点被动了手脚，也装不进去
	if [ -n "$SHA256" ]; then
		command -v sha256sum >/dev/null 2>&1 || fail "本机没有 sha256sum，无法校验 --sha256"
		got="$(sha256sum "$TMPD/repo.tgz" | cut -d' ' -f1)"
		if [ "$got" != "$SHA256" ]; then
			echo "!! 仓库快照校验失败，已丢弃" >&2
			echo "   期望 $SHA256" >&2
			echo "   实际 $got" >&2
			exit 1
		fi
		echo ">> 快照 sha256 校验通过"
	fi
	tar -xzf "$TMPD/repo.tgz" -C "$TMPD" || fail "解压失败（不是有效的 tar.gz？）"
	SRC="$(find "$TMPD" -maxdepth 1 -type d -name '*ts-plan*' | head -n1)"
	[ -n "$SRC" ] || fail "解压后没找到仓库目录"
	[ -f "$SRC/router/install.sh" ] || fail "$SRC/router/install.sh 不存在"
	echo ">> 解压到 $SRC"
fi
echo
sh "$SRC/router/install.sh" "$@"
exit $?
