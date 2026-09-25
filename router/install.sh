#!/bin/sh
# 在路由器上执行：sh install.sh
#
# 前提：本目录（ts.conf / ts-fetch / tailscale-ram / install.sh）已 scp 到路由器，
#       例如 /root/ts-kit/
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> 安装依赖"
opkg update >/dev/null 2>&1 || true
opkg install kmod-tun ca-bundle curl >/dev/null 2>&1 \
	|| opkg install kmod-tun ca-bundle libustream-mbedtls >/dev/null 2>&1
command -v curl >/dev/null 2>&1 || echo "    (未装 curl，将退回 busybox wget)"

echo "==> 准备目录"
mkdir -p /etc/tailscale /tmp/tailscale
chmod 0700 /etc/tailscale

echo "==> 安装文件"
cp -f "$DIR/ts.conf"        /etc/tailscale/ts.conf
cp -f "$DIR/ts-fetch"       /usr/sbin/ts-fetch
cp -f "$DIR/ts-login"       /usr/sbin/ts-login
cp -f "$DIR/tailscale-ram"  /etc/init.d/tailscale-ram
chmod 0755 /usr/sbin/ts-fetch /usr/sbin/ts-login /etc/init.d/tailscale-ram

echo "==> 检查 TUN 设备"
if [ ! -c /dev/net/tun ]; then
	mknod /dev/net/tun c 10 200 && echo "    已创建 /dev/net/tun"
else
	echo "    /dev/net/tun 存在"
fi

echo "==> 抬高 /tmp 上限（只改上限，不预分配）"
mount -o remount,size=64m /tmp 2>/dev/null || true

if [ ! -s /etc/tailscale/authkey ]; then
	echo
	echo "!! 还差 authkey，请在服务器上执行："
	echo "     headscale preauthkeys create --user home --reusable --expiration 24h"
	echo "   然后回到路由器："
	echo "     echo -n '<key>' > /etc/tailscale/authkey && chmod 600 /etc/tailscale/authkey"
fi

if grep -q 'PUT_SHA256_HERE' /etc/tailscale/ts.conf; then
	echo
	echo "!! /etc/tailscale/ts.conf 里的 TS_ARTIFACTS 还是占位符，"
	echo "   请填入 make-artifact.sh 输出的 <sha256> <url>，否则拉取一定失败。"
fi

echo "==> 启用并启动服务"
/etc/init.d/tailscale-ram enable
/etc/init.d/tailscale-ram start

echo
echo "下一步："
echo "  1) 填好 /etc/tailscale/ts.conf 里的 sha256/url 与 LOGIN_SERVER"
echo "  2) 写入 authkey：echo -n '<key>' > /etc/tailscale/authkey && chmod 600 /etc/tailscale/authkey"
echo "  3) 首次注册：ts-login       （会临时拉 CLI，注册成功后自动释放内存）"
echo
echo "查看进度："
echo "  tail -f /tmp/ts-fetch.log"
echo "  tail -f /tmp/ts-up.log"
