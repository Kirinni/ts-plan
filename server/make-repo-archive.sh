#!/usr/bin/env bash
# 生成"路由器离线安装包"：把仓库快照和 bootstrap 一起放到你自己的服务器上，
# 路由器完全不需要访问 GitHub（安装时不需要，开机时更不需要）。
#
#   # 在 VPS 上（需要本仓库的一份 git clone）
#   REF=<commit> OUT=/srv/ts BASE_URL=https://dl.example.com/ts/<token> \
#     bash make-repo-archive.sh
#
# 产出（与 nginx-ts.conf.example 的 /srv/ts 布局一致，同一个 location 就能同时
# 分发二进制工件和这份快照）：
#   $OUT/archive/<ref>.tar.gz   仓库快照；bootstrap 会去 <BASE_URL>/archive/<ref>.tar.gz 取
#   $OUT/bootstrap.sh           bootstrap 本身，方便路由器只从你的服务器取
#
# 然后路由器上（全程不碰 GitHub）：
#   wget -O- <BASE_URL>/bootstrap.sh | sh -s -- \
#     --base-url <BASE_URL> --ref <ref> --sha256 <快照 sha> --artifact "…" …
#
# 说明：快照用 git archive 从指定 commit 导出，所以内容等价于那个 commit，
#       工作区里没提交的改动不会进去（脚本会提醒你）。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${REPO:-$(cd "$DIR/.." && pwd)}"
REF="${REF:-}"
OUT="${OUT:-/srv/ts}"
BASE_URL="${BASE_URL:-https://dl.example.com/ts/CHANGE_ME_TOKEN}"

[ -d "$REPO/router" ] || {
	echo "!! $REPO 里找不到 router/ 目录，用 REPO=/path/to/clone 指定" >&2
	exit 1
}
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
	echo "!! $REPO 不是 git 仓库（git archive 需要它）。" >&2
	echo "   在 VPS 上先：git clone https://github.com/Kirinni/ts-plan.git" >&2
	exit 1
}

if [ -z "$REF" ]; then
	REF="$(git -C "$REPO" rev-parse HEAD)"
fi
short="$(git -C "$REPO" rev-parse --short "$REF" 2>/dev/null)" || {
	echo "!! 认不出这个 ref：$REF" >&2
	exit 1
}

# 提醒：快照只含已提交内容
if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
	echo "!! 注意：$REPO 的工作区有未提交改动，它们【不会】进入快照。" >&2
	echo "   要带上就先 commit（快照导出的是 commit 内容，这样才好 pin）。" >&2
fi

mkdir -p "$OUT/archive"
ARCHIVE="$OUT/archive/$REF.tar.gz"

echo ">> 导出快照 $short → $ARCHIVE"
# --prefix 让解压出来是 ts-plan-<short>/，bootstrap.sh 靠这个名字找目录
git -C "$REPO" archive --format=tar.gz --prefix="ts-plan-$short/" -o "$ARCHIVE" "$REF"

cp -f "$REPO/router/bootstrap.sh" "$OUT/bootstrap.sh"
chmod 0644 "$OUT/bootstrap.sh"

sha="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
size="$(awk -v b="$(wc -c < "$ARCHIVE")" 'BEGIN{printf "%.1f", b/1024}')"
echo "   ${size}KB  sha256=$sha"

cat <<EOF

==================== 路由器上执行（不访问 GitHub）====================

wget -O- $BASE_URL/bootstrap.sh | sh -s -- \\
  --base-url $BASE_URL \\
  --ref $REF \\
  --sha256 $sha \\
  --artifact "<sha256> <url>" \\
  --login-server https://hs.example.com \\
  --routes 192.168.31.0/24 \\
  --authkey -

要点：
- --sha256 会把下载到的快照和你这里算出来的值比对，分发点被动手脚也装不进去
- <sha256> <url> 用 make-artifact.sh 打印的值（那是运行时拉的二进制工件，与本快照无关）
- 开机路径与这份快照无关：每次重启只由 ts-fetch 拉 TS_ARTIFACTS 里的地址
EOF
