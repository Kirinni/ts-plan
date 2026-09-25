#!/bin/sh
# 在路由器上执行。两种用法：
#
#   A) 一条命令装完（推荐，无交互）：
#     sh install.sh \
#       --artifact "8de0c50a… https://dl.example.com/ts/<token>/tailscaled_1.102.4_mipsle.tar.gz" \
#       --login-server https://hs.example.com \
#       --routes 192.168.31.0/24 \
#       --authkey -
#
#   B) 只装文件，配置稍后自己填：
#     sh install.sh
#
# 参数（全部可选）：
#   --artifact "<sha256> <url>"   工件条目，可重复（按顺序回退）
#   --url <url> --sha <sha256>    等价于一条 --artifact
#   --cli-artifact "<sha> <url>"  只有官方静态包需要（它不含 CLI），可重复
#   --login-server <url>          写入 LOGIN_SERVER
#   --routes <cidr>               写入 ADVERTISE_ROUTES
#   --hostname <name>             写入 HOSTNAME_OVERRIDE
#   --authkey <key>               写入 authkey 文件；传 "-" 从 stdin 读（更安全，不进 history）
#   --force                       覆盖已存在的 ts.conf 模板（默认保留）
#   --no-start                    只安装，不启动服务
#   -h | --help
#
# 设计要点：真实配置全部写进 <ts.conf>.local，脚本永不修改 ts.conf 模板本身。
#           所以重跑本脚本（升级）不会丢你手填的值。
#
# TS_ROOT=<dir>  仅自测用：文件操作重定向到该目录，并跳过 opkg/mknod/mount/init.d。
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${TS_ROOT:-}"
CONF="${TS_CONF:-$ROOT/etc/tailscale/ts.conf}"

TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT INT TERM
: > "$TMPD/daemon"
: > "$TMPD/cli"

fail() { echo "!! $*" >&2; exit 1; }

usage() {
	if [ -f "$0" ]; then
		sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
	else
		echo "用法见仓库 README 的「一条命令安装」一节，或 router/install.sh 头部注释"
	fi
}

# ---- 参数解析 -------------------------------------------------------------
have_cfg=0
force=0
do_start=1
p_url=""
p_sha=""
LOGIN_SERVER_ARG=""
ROUTES_ARG=""
HOSTNAME_ARG=""
AUTHKEY_ARG=""

is_sha() {
	case "$1" in "" | *[!0-9a-f]*) return 1 ;; esac
	[ "${#1}" -eq 64 ]
}

add_artifact() { # $1="<sha> <url>"  $2=累积文件
	case "$1" in
		*" "*) ;;
		*) fail "--artifact 需要 \"<sha256> <url>\" 两段，请用引号包住整个值" ;;
	esac
	sha="${1%% *}"
	url="${1#* }"
	case "$url" in
		*" "*) fail "--artifact 的 URL 部分不应有空格：$url" ;;
		http://* | https://* | file://*) ;;
		*) fail "URL 必须以 http:// / https:// / file:// 开头：$url" ;;
	esac
	is_sha "$sha" || fail "sha256 格式不对（应 64 位小写十六进制）：$sha"
	printf '%s %s\n' "$sha" "$url" >> "$2"
}

flush_pair() { # --url/--sha 攒够一对就落盘
	[ -n "$p_url" ] || return 0
	[ -n "$p_sha" ] || fail "--url 需要配一个 --sha"
	add_artifact "$p_sha $p_url" "$TMPD/daemon"
	p_url=""
	p_sha=""
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--artifact)
			[ "$#" -ge 2 ] || fail "--artifact 缺参数"
			flush_pair
			add_artifact "$2" "$TMPD/daemon"
			have_cfg=1
			shift 2
			;;
		--url)
			[ "$#" -ge 2 ] || fail "--url 缺参数"
			flush_pair
			p_url="$2"
			shift 2
			;;
		--sha)
			[ "$#" -ge 2 ] || fail "--sha 缺参数"
			p_sha="$2"
			have_cfg=1
			shift 2
			;;
		--cli-artifact)
			[ "$#" -ge 2 ] || fail "--cli-artifact 缺参数"
			add_artifact "$2" "$TMPD/cli"
			have_cfg=1
			shift 2
			;;
		--login-server)
			[ "$#" -ge 2 ] || fail "--login-server 缺参数"
			LOGIN_SERVER_ARG="$2"
			have_cfg=1
			shift 2
			;;
		--routes)
			[ "$#" -ge 2 ] || fail "--routes 缺参数"
			ROUTES_ARG="$2"
			have_cfg=1
			shift 2
			;;
		--hostname)
			[ "$#" -ge 2 ] || fail "--hostname 缺参数"
			HOSTNAME_ARG="$2"
			have_cfg=1
			shift 2
			;;
		--authkey)
			[ "$#" -ge 2 ] || fail "--authkey 缺参数"
			if [ "$2" = "-" ]; then
				AUTHKEY_ARG="$(cat)"
			else
				AUTHKEY_ARG="$2"
			fi
			[ -n "$AUTHKEY_ARG" ] || fail "authkey 为空"
			have_cfg=1
			shift 2
			;;
		--force)
			force=1
			shift
			;;
		--no-start)
			do_start=0
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			fail "不认识的参数：$1（-h 看用法）"
			;;
		*)
			fail "不认识的参数：$1（安装脚本本身不接受位置参数）"
			;;
	esac
done
flush_pair

# ---- 装文件 ---------------------------------------------------------------
echo "==> 安装文件"
put() { # $1=源  $2=目标  $3=mode
	mkdir -p "$(dirname "$2")" || fail "无法创建 $(dirname "$2")"
	cp -f "$1" "$2" || fail "复制 $1 失败"
	chmod "$3" "$2"
	echo "    $2"
}

if [ -f "$CONF" ] && [ "$force" != 1 ]; then
	echo "    保留已有 $CONF（要覆盖请加 --force）"
else
	put "$DIR/ts.conf" "$CONF" 0644
fi
put "$DIR/ts-fetch" "$ROOT/usr/sbin/ts-fetch" 0755
put "$DIR/ts-login" "$ROOT/usr/sbin/ts-login" 0755
put "$DIR/ts-doctor" "$ROOT/usr/sbin/ts-doctor" 0755
put "$DIR/ts-status" "$ROOT/usr/sbin/ts-status" 0755
put "$DIR/tailscale-ram" "$ROOT/etc/init.d/tailscale-ram" 0755

# 立刻读出 TS_DIR / STATE_DIR / AUTHKEY_FILE / TMPFS_SIZE
TS_CONF="$CONF"
export TS_CONF
# shellcheck source=/dev/null
. "$CONF"

# ---- 写本地覆盖 -----------------------------------------------------------
LOCAL="${CONF}.local"
if [ "$have_cfg" = 1 ]; then
	mkdir -p "$(dirname "$LOCAL")" || fail "无法创建 $(dirname "$LOCAL")"
	if [ -f "$LOCAL" ]; then
		cp -f "$LOCAL" "$LOCAL.bak"
		echo "    已把旧配置备份到 $LOCAL.bak"
	fi
	{
		echo "# 由 install.sh 生成（$(date '+%F %T')）—— 重跑 install.sh 会覆盖本文件"
		echo "# 真实值都放这里；ts.conf 模板可以放心被升级覆盖。"
		if [ -s "$TMPD/daemon" ]; then
			echo 'TS_ARTIFACTS="'
			cat "$TMPD/daemon"
			echo '"'
		fi
		if [ -s "$TMPD/cli" ]; then
			echo 'TS_CLI_ARTIFACTS="'
			cat "$TMPD/cli"
			echo '"'
		fi
		if [ -n "$LOGIN_SERVER_ARG" ]; then
			echo "LOGIN_SERVER=$LOGIN_SERVER_ARG"
		fi
		if [ -n "$ROUTES_ARG" ]; then
			echo "ADVERTISE_ROUTES=$ROUTES_ARG"
		fi
		if [ -n "$HOSTNAME_ARG" ]; then
			echo "HOSTNAME_OVERRIDE=$HOSTNAME_ARG"
		fi
	} > "$LOCAL.tmp"
	mv -f "$LOCAL.tmp" "$LOCAL" || fail "写入 $LOCAL 失败"
	chmod 0600 "$LOCAL"
	# shellcheck source=/dev/null
	. "$LOCAL"
	echo "    写入 $LOCAL"
fi

# ---- 目录 / authkey -------------------------------------------------------
mkdir -p "$ROOT$STATE_DIR" "$ROOT$TS_DIR" || fail "无法创建目录"
chmod 0700 "$ROOT$STATE_DIR"
echo "    $STATE_DIR（持久）+ $TS_DIR（内存）"

AK="$ROOT${AUTHKEY_FILE:-/etc/tailscale/authkey}"
if [ -n "$AUTHKEY_ARG" ]; then
	printf '%s' "$AUTHKEY_ARG" > "$AK" || fail "写入 $AK 失败"
	chmod 0600 "$AK"
	unset AUTHKEY_ARG
	echo "    authkey 已写入 $AK（注册成功后 ts-login 会删掉它）"
fi

# ---- 系统准备 -------------------------------------------------------------
if [ -z "$ROOT" ]; then
	echo "==> 安装依赖"
	opkg update >/dev/null 2>&1 || true
	opkg install kmod-tun ca-bundle curl >/dev/null 2>&1 \
		|| opkg install kmod-tun ca-bundle libustream-mbedtls >/dev/null 2>&1
	command -v curl >/dev/null 2>&1 || echo "    (未装 curl，将退回 uclient-fetch / busybox wget)"

	echo "==> 检查 TUN 设备"
	if [ ! -c /dev/net/tun ]; then
		mknod /dev/net/tun c 10 200 && echo "    已创建 /dev/net/tun"
	else
		echo "    /dev/net/tun 存在"
	fi

	# tmpfs 上限只由 ts.conf 的 TMPFS_SIZE 决定（这里不再写死，避免两处不一致）
	echo "==> 抬高 /tmp 上限到 ${TMPFS_SIZE:-96m}（只改上限，不预分配）"
	mount -o remount,size="${TMPFS_SIZE:-96m}" /tmp 2>/dev/null \
		|| echo "    (remount 失败；开机时 ts-fetch 会再试一次)"
else
	echo "==> TS_ROOT 模式：跳过 opkg / mknod / remount / init.d"
fi

# ---- 配置体检 -------------------------------------------------------------
case "${TS_ARTIFACTS:-}" in
	"")
		echo
		echo "!! TS_ARTIFACTS 为空，开机拉取一定失败。"
		echo "   补上：sh install.sh --artifact \"<sha256> <url>\""
		;;
	*PUT_SHA256_HERE*)
		echo
		echo "!! TS_ARTIFACTS 还是占位符，请填入 make-artifact.sh 输出的 <sha256> <url>。"
		;;
esac
case "${LOGIN_SERVER:-}" in
	*example.com*)
		echo
		echo "!! LOGIN_SERVER 还是示例值（$LOGIN_SERVER），改成你的 headscale 地址。"
		;;
esac
if [ ! -s "$AK" ] && [ ! -f "$ROOT$STATE_DIR/tailscaled.state" ]; then
	echo
	echo "!! 还没有 authkey，也没注册过："
	echo "   在服务器执行 headscale preauthkeys create --user home --reusable --expiration 24h"
	echo "   然后回来：ts-login --authkey <key>   （或先 echo -n <key> > $AK）"
fi

# ---- 启动 -----------------------------------------------------------------
if [ "$do_start" = 1 ] && [ -z "$ROOT" ]; then
	echo "==> 启用并启动服务"
	/etc/init.d/tailscale-ram enable
	/etc/init.d/tailscale-ram start
fi

echo
echo "下一步："
echo "  1) 自检（等 30 秒让首次拉取跑完）：ts-doctor"
echo "  2) 首次注册（若还没注册）：ts-login"
echo "  3) 看状态：ts-status"
echo
echo "查看进度："
echo "  tail -f /tmp/ts-fetch.log"
echo "  tail -f /tmp/ts-up.log"
