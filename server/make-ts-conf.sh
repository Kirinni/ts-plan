#!/usr/bin/env bash
# 把"工件清单"写成路由器要用的 ts.conf.local，并打印两种用法（拷文件 / 当参数传）。
#
# 由 make-artifact.sh（本机/VPS 打新包）和 pull-release.sh（从 GitHub Release 拉）
# 共用 —— 两边生成的配置必须一致，所以逻辑只留这一份。
#
#   OUT=/srv/ts BASE_URL=https://dl.example.com/ts/<token> \
#     bash server/make-ts-conf.sh <daemon-lines> [<cli-lines>]
#
# 两个输入文件都是 `<sha256> <url>` 一行一个（和 ts.conf 里 TS_ARTIFACTS 的格式一致）：
#   daemon-lines  开机日常要拉的工件 → TS_ARTIFACTS
#   cli-lines     仅首次注册用的 CLI 工件 → TS_CLI_ARTIFACTS（没有就不传）
#
# 可选环境变量：GENERATOR（写进文件头的"由谁生成"，默认 make-ts-conf.sh）
set -euo pipefail

OUT="${OUT:-/srv/ts}"
BASE_URL="${BASE_URL:-https://dl.example.com/ts/CHANGE_ME_TOKEN}"
LOGIN_SERVER="${LOGIN_SERVER:-https://hs.example.com}"
ADVERTISE_ROUTES="${ADVERTISE_ROUTES:-192.168.31.0/24}"
GENERATOR="${GENERATOR:-make-ts-conf.sh}"

DAEMON="${1:?用法: make-ts-conf.sh <daemon-lines> [<cli-lines>]}"
CLI="${2:-}"
[ -s "$DAEMON" ] || {
	echo "!! $DAEMON 里没有工件行（格式应为 '<sha256> <url>'）" >&2
	exit 1
}

mkdir -p "$OUT"
CFG="$OUT/ts.conf.local"
{
	echo "# 由 $GENERATOR 生成（$(date '+%F %T')）"
	echo "# 目标位置：/etc/tailscale/ts.conf.local（ts.conf 会自动 source 它）"
	echo "# 放在这里而不是改 ts.conf：重跑 install.sh 不会覆盖它。"
	echo
	echo 'TS_ARTIFACTS="'
	cat "$DAEMON"
	echo '"'
	if [ -n "$CLI" ] && [ -s "$CLI" ]; then
		echo 'TS_CLI_ARTIFACTS="'
		cat "$CLI"
		echo '"'
	fi
	echo
	if [ "$LOGIN_SERVER" = "https://hs.example.com" ] || [ "$ADVERTISE_ROUTES" = "192.168.31.0/24" ]; then
		echo "# 注意：下面仍是示例值（留着会被 install.sh / ts-doctor 报警），改成你自己的"
	else
		echo "# 下面两项来自构建/发布时的 LOGIN_SERVER / ADVERTISE_ROUTES，可直接用"
	fi
	echo "LOGIN_SERVER=$LOGIN_SERVER"
	echo "ADVERTISE_ROUTES=$ADVERTISE_ROUTES"
} > "$CFG"

echo
echo "==================== 给路由器的配置 ===================="
echo "文件：$CFG"
echo "两种用法二选一："
echo "  A) 拷文件：scp $CFG root@192.168.31.1:/etc/tailscale/ts.conf.local"
echo "  B) 当参数传（不拷文件，装的时候直接写进去）："
while read -r sha url; do
	echo "       --artifact \"$sha $url\""
done < "$DAEMON"
if [ -n "$CLI" ] && [ -s "$CLI" ]; then
	while read -r sha url; do
		echo "       --cli-artifact \"$sha $url\""
	done < "$CLI"
fi
echo
echo "提示：换版本/重新打包后 sha256 会变 —— 重跑本脚本重新生成即可。"
