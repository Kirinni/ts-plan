#!/usr/bin/env bash
# 在 VPS 上把 GitHub Release 里的工件拉下来、校验、铺到分发点，并打印路由器要用的那条命令。
#
# 为什么是"拉"而不是让 Actions 推：让 CI 推就得在 GitHub 里存一把能登 VPS 的私钥，
# 泄漏面（GitHub 侧被脱库/被投毒 → 你的服务器跟着沦陷）比这条命令大得多。
# 公开仓库上"拉"连凭据都不需要（匿名下载 Release 资产）；仓库转私有的话，
# 只需在这台 VPS 上放一把**只读** token（IN_TOKEN），不用把服务器钥匙交给 GitHub。
#
#   # 在 VPS 上（本仓库的一份 clone 里，或者只把本脚本拿过来）
#   BASE_URL=https://dl.example.com/ts/<token> \
#   LOGIN_SERVER=https://hs.example.com ADVERTISE_ROUTES=192.168.31.0/24 \
#     bash server/pull-release.sh
#
# 参数 / 环境变量：
#   --tag <vX|latest>   拉哪个 Release（默认 latest，即最近发布的那个）
#   --from <dir>        不联网：把本地目录当资产目录（离线部署 / 自测用）
#   --keep              保留临时目录（排错）
#   REPO=owner/repo     默认 Kirinni/ts-plan
#   OUT=/srv/ts         分发目录（要和 nginx 的 root 一致）
#   IN_TOKEN=...        仓库转私有后需要的只读 token（公开仓库不用填）
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${REPO:-Kirinni/ts-plan}"
TAG="${TAG:-latest}"
OUT="${OUT:-/srv/ts}"
BASE_URL="${BASE_URL:-https://dl.example.com/ts/CHANGE_ME_TOKEN}"
LOGIN_SERVER="${LOGIN_SERVER:-}"
ADVERTISE_ROUTES="${ADVERTISE_ROUTES:-}"
IN_TOKEN="${IN_TOKEN:-}"
FROM=""
KEEP=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		--tag) TAG="${2:?--tag 缺参数}"; shift 2 ;;
		--from) FROM="${2:?--from 缺参数}"; shift 2 ;;
		--keep) KEEP=1; shift ;;
		-h | --help)
			sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "!! 认不出的参数：$1（-h 看用法）" >&2
			exit 1
			;;
	esac
done

W="$(mktemp -d)"
trap '[ "${KEEP:-0}" = 1 ] || rm -rf "$W"' EXIT INT TERM
fail() { echo "!! $*" >&2; exit 1; }

# --------------------------------------------------------------------------
# 取资产：$1=资产名  $2=输出文件
# --------------------------------------------------------------------------
fetch() {
	if [ -n "$FROM" ]; then
		[ -f "$FROM/$1" ] || return 1
		cp -f "$FROM/$1" "$2"
		return 0
	fi
	if [ -n "$IN_TOKEN" ]; then
		# 私有仓库：走 API 拿资产（匿名下载这条路走不通）
		api="https://api.github.com/repos/$REPO/releases"
		case "$TAG" in
			latest | "") rel="$(curl -fsSL -H "Authorization: Bearer $IN_TOKEN" "$api/latest")" ;;
			*) rel="$(curl -fsSL -H "Authorization: Bearer $IN_TOKEN" "$api/tags/$TAG")" ;;
		esac
		id="$(printf '%s' "$rel" | tr ',' '\n' | sed -n 's/.*"id": \([0-9]\{1,\}\).*/\1/p' | head -n1)"
		[ -n "$id" ] || return 1
		curl -fsSL -H "Authorization: Bearer $IN_TOKEN" \
			-H 'Accept: application/octet-stream' \
			"$api/assets/$id" -o "$2" || return 1
		return 0
	fi
	case "$TAG" in
		latest | "") url="https://github.com/$REPO/releases/latest/download/$1" ;;
		*) url="https://github.com/$REPO/releases/download/$TAG/$1" ;;
	esac
	if command -v curl >/dev/null 2>&1; then
		curl -fL --retry 2 --connect-timeout 15 -o "$2" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$url"
	else
		echo "!! 需要 curl 或 wget" >&2
		return 127
	fi
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
	else return 127; fi
}

info() { # 从 BUILD_INFO.txt 里取 $1 键
	sed -n "s/^$1=//p" "$W/BUILD_INFO.txt" | head -n1
}

if [ -n "$FROM" ]; then
	echo ">> 来源：本地目录 $FROM"
else
	echo ">> 来源：https://github.com/$REPO（release: $TAG）"
fi

# --------------------------- 版本 / commit / 期望的 sha ---------------------------
echo ">> 取 BUILD_INFO.txt"
fetch BUILD_INFO.txt "$W/BUILD_INFO.txt" || fail "拿不到 BUILD_INFO.txt（$TAG 这个 Release 里没有？旧版 workflow 打的包没有这个文件）"
VER="$(info version)"
REF="$(info ref)"
WANT_TAR="$(info tar_sha256)"
WANT_SNAP="$(info snapshot_sha256)"
TAR_NAME="$(info tar)"
SNAP_NAME="$(info snapshot)"
[ -n "$TAR_NAME" ] || TAR_NAME="tailscaled_mipsle.tar.gz"
[ -n "$SNAP_NAME" ] || SNAP_NAME="repo-snapshot.tar.gz"
[ -n "$VER" ] || fail "BUILD_INFO.txt 里没有 version"
[ -n "$WANT_TAR" ] || fail "BUILD_INFO.txt 里没有 tar_sha256"
echo "   Tailscale v$VER / commit $REF"

# --------------------------- 二进制工件 ---------------------------
echo ">> 下载二进制工件 $TAR_NAME"
fetch "$TAR_NAME" "$W/tar.gz" || fail "下载 $TAR_NAME 失败"
got="$(sha256_of "$W/tar.gz")" || fail "本机没有 sha256sum/shasum，无法校验"
[ "$got" = "$WANT_TAR" ] || fail "sha256 不匹配：期望 $WANT_TAR / 实得 $got（别装，先查是不是被改过）"

mkdir -p "$OUT"
DEST="$OUT/tailscaled_${VER}_mipsle.tar.gz"
mv -f "$W/tar.gz" "$DEST"
printf '%s\n' "$got" > "$DEST.sha256"
echo "   OK $got"
echo "   → $DEST"

# --------------------------- 仓库快照（让路由器装的时候也不用碰 GitHub）---------------------------
SNAP_SHA=""
if [ -z "$WANT_SNAP" ]; then
	echo ">> 这次 Release 没带仓库快照，跳过（路由器安装时得另想办法，见 README 第 6 步）"
else
	echo ">> 下载仓库快照 $SNAP_NAME"
	if fetch "$SNAP_NAME" "$W/snap.gz"; then
		sgot="$(sha256_of "$W/snap.gz")"
		if [ "$sgot" != "$WANT_SNAP" ]; then
			echo "!! 快照 sha256 不匹配（期望 $WANT_SNAP / 实得 $sgot），已跳过" >&2
		else
			mkdir -p "$OUT/archive"
			# bootstrap.sh 会去 <BASE_URL>/archive/<ref>.tar.gz 取，所以这里按 ref 命名
			[ -n "$REF" ] || fail "快照需要 ref 才能命名，但 BUILD_INFO.txt 里没有 ref"
			mv -f "$W/snap.gz" "$OUT/archive/$REF.tar.gz"
			printf '%s\n' "$sgot" > "$OUT/archive/$REF.tar.gz.sha256"
			SNAP_SHA="$sgot"
			echo "   OK $sgot"
			echo "   → $OUT/archive/$REF.tar.gz"
		fi
	else
		echo "   拿不到快照，跳过"
	fi
fi

# --------------------------- bootstrap.sh ---------------------------
echo ">> 下载 bootstrap.sh"
if fetch bootstrap.sh "$W/bootstrap"; then
	cp -f "$W/bootstrap" "$OUT/bootstrap.sh"
	chmod 0644 "$OUT/bootstrap.sh"
	echo "   → $OUT/bootstrap.sh"
else
	echo "   拿不到 bootstrap.sh（不影响开机运行，但路由器装的时候要另找一份）"
fi

# --------------------------- 生成 ts.conf.local（与 make-artifact.sh 同一份逻辑）--------------------------
printf '%s %s\n' "$got" "$BASE_URL/tailscaled_${VER}_mipsle.tar.gz" > "$W/daemon.lines"
GENERATOR=pull-release.sh \
OUT="$OUT" BASE_URL="$BASE_URL" \
LOGIN_SERVER="${LOGIN_SERVER:-https://hs.example.com}" \
ADVERTISE_ROUTES="${ADVERTISE_ROUTES:-192.168.31.0/24}" \
	bash "$DIR/make-ts-conf.sh" "$W/daemon.lines"

# --------------------------- 顺带确认分发点真的能下到 ---------------------------
case "$BASE_URL" in
	"" | *CHANGE_ME_TOKEN*)
		echo ">> 分发点前缀还是占位值，跳过在线校验"
		;;
	*)
		if command -v curl >/dev/null 2>&1; then
			if curl -fsSL --connect-timeout 15 -o "$W/check.gz" "$BASE_URL/tailscaled_${VER}_mipsle.tar.gz"; then
				cgot="$(sha256_of "$W/check.gz")"
				[ "$cgot" = "$got" ] || fail "分发点上下的文件和拿到的不是同一个（期望 $got / 实得 $cgot）—— nginx 缓存旧文件？"
				echo ">> OK 分发点上能下到，且 sha256 一致"
			else
				echo ">> 提示：$BASE_URL/tailscaled_${VER}_mipsle.tar.gz 现在下不动 ——" >&2
				echo "   nginx/token 还没配好？（见 README 第 4 步）文件已经放进 $OUT 了。" >&2
			fi
		fi
		;;
esac

# --------------------------- 路由器命令 ---------------------------
echo
echo "==================== 路由器上执行（不访问 GitHub）===================="
echo
echo "wget -O- $BASE_URL/bootstrap.sh | sh -s -- \\"
echo "  --base-url $BASE_URL \\"
if [ -n "$SNAP_SHA" ]; then
	echo "  --ref $REF \\"
	echo "  --sha256 $SNAP_SHA \\"
fi
echo "  --artifact \"$got $BASE_URL/tailscaled_${VER}_mipsle.tar.gz\" \\"
if [ -n "$LOGIN_SERVER" ]; then
	echo "  --login-server $LOGIN_SERVER \\"
else
	echo "  --login-server https://hs.example.com \\   # ← 改成你的"
fi
if [ -n "$ADVERTISE_ROUTES" ]; then
	echo "  --routes $ADVERTISE_ROUTES \\"
else
	echo "  --routes 192.168.31.0/24 \\              # ← 改成你的"
fi
echo "  --authkey -"
echo
echo "（这份配置也写在 $OUT/ts.conf.local 里，想用拷文件的方式就照第 3 步的 A 方案）"
