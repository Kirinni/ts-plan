#!/usr/bin/env bash
# 在 headscale 所在机器上执行：建 user、发 preauthkey、打印随后要用的命令与配置片段。
#
#   bash headscale-bootstrap.sh --user home --routes 192.168.31.0/24
#
# headscale 跑在容器里时（例如 docker compose）：
#   HEADSCALE_CMD="docker exec headscale headscale" bash headscale-bootstrap.sh
#
# 参数：
#   --user <name>        tailnet 用户名（默认 home）
#   --routes <cidrs>     要宣告的路由，逗号分隔（默认 192.168.31.0/24）；传 "" 则跳过 autoApprovers
#   --ttl <duration>     preauthkey 有效期（默认 24h）
#   --server-url <url>   你的 headscale 公网地址，用于打印完整的安装命令
#   --ephemeral          签 ephemeral key（节点登出即消失，一般不用）
#   -h | --help
#
# 只做三件事：建用户、发 key、打印片段。**不会改动 headscale 配置文件** ——
# 那需要重启服务，交给你自己决定。
set -euo pipefail

HSCMD="${HEADSCALE_CMD:-headscale}"
USER_NAME="${TS_USER:-home}"
ROUTES="${TS_ROUTES:-192.168.31.0/24}"
TTL="${TS_KEY_TTL:-24h}"
SERVER_URL="${TS_SERVER_URL:-}"
EPHEMERAL=0

fail() { echo "!! $*" >&2; exit 1; }

usage() {
	sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--user)     [ "$#" -ge 2 ] || fail "--user 缺参数"; USER_NAME="$2"; shift 2 ;;
		--routes)   [ "$#" -ge 2 ] || fail "--routes 缺参数"; ROUTES="$2"; shift 2 ;;
		--ttl)      [ "$#" -ge 2 ] || fail "--ttl 缺参数"; TTL="$2"; shift 2 ;;
		--server-url) [ "$#" -ge 2 ] || fail "--server-url 缺参数"; SERVER_URL="$2"; shift 2 ;;
		--ephemeral) EPHEMERAL=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) fail "不认识的参数：$1（-h 看用法）" ;;
	esac
done

# --------------------------------------------------------------------------
echo "==> 检查 headscale 可用"
# 注意：不要把管道写进赋值里（`v="$(cmd | head -n1)"` 的退出码是 head 的，永远是 0），
#       那样失败会被吞掉。
if ! ver_out="$($HSCMD version 2>&1)"; then
	echo "!! 执行 '$HSCMD version' 失败。" >&2
	echo "   headscale 不在 PATH 里、或跑在容器里？试试：" >&2
	echo "     HEADSCALE_CMD=\"docker exec <容器名> headscale\" bash $0" >&2
	exit 1
fi
echo "    $(printf '%s\n' "$ver_out" | head -n1)"

echo
echo "==> 建用户：$USER_NAME"
if out="$($HSCMD users create "$USER_NAME" 2>&1)"; then
	echo "    $out"
else
	case "$out" in
		*"already exists"* | *exists*)
			echo "    已存在，跳过"
			;;
		*)
			echo "$out" >&2
			fail "建用户失败"
			;;
	esac
fi

echo
echo "==> 签发 preauthkey（reusable，有效期 $TTL）"
set -- --user "$USER_NAME" --reusable --expiration "$TTL"
if [ "$EPHEMERAL" = 1 ]; then
	set -- "$@" --ephemeral
fi
if ! out="$($HSCMD preauthkeys create "$@" 2>&1)"; then
	echo "$out" >&2
	echo "   提示：如果报 user 找不到，用数字 ID 试试（headscale users list）" >&2
	exit 1
fi
key="$(printf '%s' "$out" | grep -oE 'tskey-[A-Za-z0-9_-]+' | head -n1 || true)"
if [ -z "$key" ]; then
	echo "$out"
	fail "没能从输出里认出 tskey-…，请手工复制上面的 key"
fi
echo "    $key"

# 把 "a,b,c" 拼成 JSON 里的路由段：  "a": ["home"], "b": ["home"]
routes_json=""
if [ -n "$ROUTES" ]; then
	old_ifs="$IFS"
	IFS=,
	for r in $ROUTES; do
		r="$(printf '%s' "$r" | tr -d ' ')"
		[ -n "$r" ] || continue
		[ -n "$routes_json" ] && routes_json="$routes_json, "
		routes_json="${routes_json}\"$r\": [\"$USER_NAME\"]"
	done
	IFS="$old_ifs"
fi

# --------------------------------------------------------------------------
cat <<EOF

==================== 接下来 ====================

1) 在路由器上安装并注册（把 <sha> <url> 换成 make-artifact.sh 打印的值）：

   ts-login 装好后不用手输 key，直接：

     sh router/install.sh \\
       --artifact "<sha> <url>" \\
       --login-server ${SERVER_URL:-https://hs.example.com} \\
       --routes ${ROUTES:-192.168.31.0/24} \\
       --authkey -

   然后按提示把上面的 key 粘进去回车（用 - 从 stdin 读，不会留在 shell history）。

   已经装好了、只想注册：

     echo -n '$key' > /etc/tailscale/authkey && chmod 600 /etc/tailscale/authkey
     ts-login

2) 批准路由。手工方式：

     headscale routes list
     headscale routes enable -r <route-id>

   或者一次性免人工批准 —— 在 headscale 的 config.yaml 里加（字段名按你的版本核对）：

   "autoApprovers": {
     "routes":   { ${routes_json:-(不宣告路由)} },
     "exitNode": ["$USER_NAME"]
   }

   改完重启 headscale 生效（systemctl restart headscale / docker compose restart）。

3) 确认节点已上线：

     headscale nodes list

EOF

if [ -n "$ROUTES" ]; then
	echo "4) 客户端要用到内网，记得开 --accept-routes（手机端是 \"Use Tailscale subnets\"），"
	echo "   并且 ACL 里放行 $ROUTES —— 路由批准了但 ACL 不给权限，照样访问不了。"
	echo
fi

echo "提示：key 有效期 $TTL。路由器用掉它以后，ts-login 会自动把 authkey 文件删掉。"
