# 运维指南

> 前提：已经按 README「三、从零部署」跑通过一次。本文按**日常真会做的事**组织：
> 接新机器 → 升级 → 巡检/备份 → 卸载清理 → 故障速查。
> 尖括号 `<...>` 是要替换成自己值的地方；**本站实际值请放本地留档，不要进公开仓库**（公开仓库的 run 日志/Summary 谁都能看）。

## 0. 全貌与文件地图

| 机器 | 角色 | 关键位置 |
|---|---|---|
| 你的电脑 | 发版（推 tag）、需要时做中转下载 | 本仓库 clone |
| VPS | headscale + HTTPS 分发点 | `/srv/ts`（工件）、`/etc/nginx/conf.d/ts-download.conf`、`/etc/headscale/`、`/var/lib/headscale/`、`~/…/server/*.sh` |
| 路由器 | 运行 tailscaled（二进制在 tmpfs） | `/usr/sbin/ts-*`、`/etc/init.d/tailscale-ram`、`/etc/tailscale/`（配置+state+authkey）、`/tmp/tailscale/`（重启即失） |

分发点 `/srv/ts` 里应该是这几样：

```
tailscaled_<ver>_mipsle.tar.gz(+.sha256)   开机要拉的二进制（约 9.9MB）
archive/<commit>.tar.gz(+.sha256)          仓库快照，安装/升级时用
bootstrap.sh                               路由器安装入口
ts.conf.local                              给路由器的一组现成参数
```

路由器侧文件（`install.sh` 装的）：

```
/usr/sbin/ts-fetch  ts-login  ts-doctor  ts-status
/etc/init.d/tailscale-ram
/etc/tailscale/ts.conf(+.local[+.bak])  tailscaled.state  authkey
/tmp/tailscale/                        二进制 + socket（tmpfs）
```

## 1. 接入一台新路由器

### ① 发 preauthkey（VPS 上）

```sh
sudo headscale preauthkeys create -u <用户ID> --reusable --expiration 24h
sudo headscale preauthkeys list -u <用户ID>      # 想看还有哪些 key 有效
```

- 同一时段装多台：一把 `--reusable` 的 key 够用
- 跨时段分批装：**每台现发一把**（24h 是故意短的）
- v0.28 起 `--user` 只认**数字 ID**：`sudo headscale users list -o json` 查

### ② 路由器上安装（一条命令）

```sh
wget -O- <BASE_URL>/bootstrap.sh | sh -s -- \
  --base-url <BASE_URL> \
  --ref <快照对应的 commit> --sha256 <快照 sha256> \
  --artifact "<工件 sha256> <工件 url>" \
  --login-server <headscale 地址> \
  --hostname <这台唯一的名字> \
  --routes <这台自己的内网网段> \
  --authkey -
```

每台只有三处不同：

| 参数 | 说明 |
|---|---|
| `--hostname` | **必改**。默认是 `r4a-home`（`ts.conf` 里的 `HOSTNAME_OVERRIDE`），不改多台会重名 |
| `--routes` | 每台自己的 LAN 网段 |
| `--authkey -` | 粘该台对应的 key（有终端时读 `/dev/tty`，不进 history） |

### ③ 批准路由（VPS 上）

```sh
sudo headscale nodes list
sudo headscale routes list
sudo headscale routes enable -r <ID>
```

### 验证

```sh
ts-doctor      # 路由器上：期望没有 FAIL
ts-status      # 路由器上：节点在线、tailscale0 有地址
```

### 多台注意

- **网段别撞**：两台路由器宣告同一子网会路由混乱，各自规划（或只宣告一台）
- 给每台留档：hostname / 网段 / 部署日期 / 用的那条完整命令
- 硬件不同没关系：同一个 mipsel 单二进制适配所有 MT7621 机器

## 2. 升级维护

### 2.1 发新版本（CI 路线，推荐）

```sh
# 电脑上二选一：
git tag v1.110.0 && git push origin v1.110.0     # 版本号取 tag 名，编完自动发 Release
# 或 Actions 页面 Run workflow —— release_tag 必须填，留空只编不发
```

等约 3 分钟。**不需要任何 Secrets**；可选 Variables（`TS_BASE_URL` / `TS_LOGIN_SERVER` / `TS_ADVERTISE_ROUTES` / `TS_VER`）只是为了 CI 打印的命令更省事。

### 2.2 VPS 铺分发点

**在线**（VPS 能顺畅访问 GitHub 时）：

```sh
cd <仓库 clone> && REPO=<owner/repo> TAG=v1.110.0 OUT=/srv/ts \
  BASE_URL=<BASE_URL> LOGIN_SERVER=<headscale 地址> ADVERTISE_ROUTES=<网段> \
  bash server/pull-release.sh
```

**检查点**：结尾出现 `OK 分发点上能下到，且 sha256 一致`，以及一段 `wget -O- …/bootstrap.sh | sh -s -- …`。

**VPS 到 GitHub 不稳时（本项目实测 1/3 请求挂）→ 走中转**：

```sh
# 电脑：下 4 个固定名资产
curl -fL -O https://github.com/<owner/repo>/releases/download/<tag>/BUILD_INFO.txt
curl -fL -O https://github.com/<owner/repo>/releases/download/<tag>/tailscaled_mipsle.tar.gz
curl -fL -O https://github.com/<owner/repo>/releases/download/<tag>/repo-snapshot.tar.gz
curl -fL -O https://github.com/<owner/repo>/releases/download/<tag>/bootstrap.sh

# 传到 VPS（Windows 用 pscp：-load <会话> + 显式 user@host）
pscp -batch -load <会话> ./BUILD_INFO.txt ./tailscaled_mipsle.tar.gz ./repo-snapshot.tar.gz ./bootstrap.sh <user>@<host>:/home/<user>/ts-from/

# VPS：把目录当资产源（--from 完全不联网）
cd ~/<仓库 clone> && REPO=<owner/repo> OUT=/srv/ts BASE_URL=<BASE_URL> \
  LOGIN_SERVER=<headscale 地址> ADVERTISE_ROUTES=<网段> \
  bash server/pull-release.sh --from ~/ts-from
```

### 2.3 路由器升级

把上一步打印的命令在**每台**路由器上重跑（hostname/routes 保持它自己的）：

- 升级**不需要** `--authkey`（state 还在，不会重新注册）
- `install.sh` 就地更新 `ts.conf.local`，旧值自动备份成 `.local.bak`
- 装完 `ts-doctor`；有条件再 `reboot` 验证开机自愈

### 2.4 不用 CI 的手工路线

```sh
# 电脑
bash server/build-selfbuild.sh        # 产出 out/tailscaled_<ver>_mipsle
# 传到 VPS 后
SOURCE=local BINARY=~/tailscaled_<ver>_mipsle OUT=/srv/ts BASE_URL=<BASE_URL> \
  LOGIN_SERVER=<hs> ADVERTISE_ROUTES=<网段> bash server/make-artifact.sh
REF=$(git rev-parse HEAD) OUT=/srv/ts BASE_URL=<BASE_URL> bash server/make-repo-archive.sh
```

### 2.5 日常巡检（建议每月一次）

```sh
# 路由器
ts-doctor && ts-status

# VPS
curl -sI <BASE_URL>/bootstrap.sh | head -1                          # 分发点活着（200）
sudo headscale nodes list                                           # 节点是否都在
sudo headscale routes list                                          # 路由 enabled
openssl x509 -enddate -noout -in /etc/nginx/ssl/<域>/fullchain.pem   # 证书到期
df -h /                                                             # 磁盘（工件会累积）
```

证书是 acme.sh **每日 cron 自动续**的：`/root/.acme.sh/acme.sh.log` 有当日痕迹就正常；到期前一周还没换再干预。旧版本工件可按需清理：`ls -lt /srv/ts /srv/ts/archive` 后手工删老文件（**别删当前 `ts.conf.local` 里引用的那份**）。

### 2.6 备份与恢复

```sh
# VPS：headscale（先停服务，避免 sqlite WAL 不一致）
sudo systemctl stop headscale
sudo tar -czf /root/headscale-$(date +%F).tgz /etc/headscale /var/lib/headscale
sudo systemctl start headscale

# VPS：nginx 侧（vhost + 证书）
sudo tar -czf /root/nginx-ts-$(date +%F).tgz /etc/nginx/conf.d /etc/nginx/ssl
```

- 关键文件：`/var/lib/headscale/db.sqlite`（含 `-wal`/`-shm`）、`noise_private.key`、`derp_server_private.key`、`/etc/headscale/config.yaml`
- 路由器侧可选备份 `/etc/tailscale/tailscaled.state`（保住节点身份，省一次重新注册）
- ⚠️ 丢了 `db.sqlite`：所有节点都得重新注册（路由器上删 state 后重新 `up`，要新 key）

### 2.7 回滚

- Release 里保留**版本化资产**（`tailscaled_<ver>_mipsle.tar.gz`），旧版本可以再铺一次
- 留住每台的安装命令就能快速回退（只换 `--ref/--sha256/--artifact` 三个值）
- 换工件后路由器 sha 必须同步，对不上 `ts-doctor` 会直接报

### 2.8 升级 headscale 本身（VPS 控制面）

> 与 ts-plan 的发版完全独立；只影响控制面，重启期间节点掉几秒后自动连回，**不需要重新注册**。

**升级前必须做的两件事**

1. **备份**（0.29 起**禁止降级**，回滚只能靠恢复 DB）：
   ```sh
   sudo systemctl stop headscale
   sudo tar -czf /root/headscale-pre-<新版本>-$(date +%F).tgz /etc/headscale /var/lib/headscale
   sudo cp /usr/bin/headscale /root/headscale-<旧版本>.bin
   sudo systemctl start headscale
   ```
2. **看 release notes 的 BREAKING 段**：重点看「配置键重命名/删除」和「最低客户端版本」。

**装包（务必加 `--force-confold`）**

```sh
sudo dpkg -i --force-confold ~/headscale_<新版本>_linux_amd64.deb
sudo systemctl restart headscale
sudo journalctl -u headscale -n 25 --no-pager
```

- `--force-confold` = 永远保留你现有的 `config.yaml`。**不加它，dpkg 可能用新版默认配置覆盖你的 config**，症状是只监听 `127.0.0.1:8080`、内嵌 DERP / STUN 全消失、所有节点掉线
- 真被覆盖了也别慌：dpkg 会留下 `/etc/headscale/config.yaml.dpkg-old`（替换前那份），自己备份的通常是 `config.yaml.bak`

**验收**

```sh
headscale version                     # 新版本
sudo headscale nodes list             # 节点都在、online
sudo headscale routes list            # 路由仍 enabled
# 日志里应有：listening and serving HTTP on: 0.0.0.0:<你的端口> / stun server started / derp region: ...
```

**已知升级陷阱（本项目实际踩过）**

| 版本 | 陷阱 |
|---|---|
| 0.29 | 删除 `randomize_client_port` 配置键：**存在即拒绝启动**（默认行为就是 false，直接删该行） |
| 0.29 | `ephemeral_node_inactivity_timeout` 移到 `node.ephemeral.inactivity_timeout`（旧键被忽略并告警） |
| 0.29 | 强制单向升级：不允许跨 minor 跳（0.27→0.29 要分两步）、**不允许降级** |
| 0.29 | 最低客户端版本 v1.80，过老的客户端会被拒 |
| 0.28 | `preauthkeys create --user` 只收数字 ID（见 §5） |

## 3. 卸载与清理

### 3.1 单台路由器临时下线

```sh
/etc/init.d/tailscale-ram stop
/etc/init.d/tailscale-ram disable          # 取消开机自启
# VPS 上把节点也从 headscale 里移除：
sudo headscale nodes list                  # 找 ID
sudo headscale nodes delete -i <ID>        # 语法以 nodes delete -h 为准
```

### 3.2 彻底移除路由器组件

```sh
/etc/init.d/tailscale-ram stop; /etc/init.d/tailscale-ram disable
rm -f /etc/init.d/tailscale-ram
rm -f /usr/sbin/ts-fetch /usr/sbin/ts-login /usr/sbin/ts-doctor /usr/sbin/ts-status
rm -rf /etc/tailscale /tmp/tailscale
```

删完就回到"没装过"的状态；这些文件总共几十 KB，不用担心 flash 寿命。

### 3.3 分发点下线（VPS）

```sh
sudo rm -f /etc/nginx/conf.d/ts-download.conf
sudo nginx -t && sudo systemctl reload nginx
rm -rf /srv/ts ~/ts-from ~/ts-download.conf      # 工件 + 中转文件
```

域名、证书、headscale、博客都不受影响。

### 3.4 headscale 下线

```sh
sudo systemctl stop headscale && sudo systemctl disable headscale
sudo tar -czf /root/headscale-final-$(date +%F).tgz /etc/headscale /var/lib/headscale   # 留个底
# 确认真的不要了再删：
# sudo rm -rf /var/lib/headscale /etc/headscale
```

### 3.5 GitHub 侧清理

- 删 Release：网页删 + `git push --delete origin <tag>`
- 不再用：仓库转私有或 Archive；Actions Artifacts 90 天自动过期
- 注意：删了 Release 就没有在线拉取源了（**已铺到分发点的文件不受影响**，路由器照旧）

## 4. 故障速查

| 现象 | 先做什么 |
|---|---|
| 路由器节点掉线 | `tail -f /tmp/ts-fetch.log`；`curl -sI <BASE_URL>/bootstrap.sh` 测分发点；重来：`rm -rf /tmp/tailscale && /etc/init.d/tailscale-ram restart` |
| 分发点 404 | 核对两处是否一致：nginx 的 `server_name` + `location` 路径 ↔ `BASE_URL` 的域名和 token（本项目踩过：改了 server_name 没改 BASE_URL） |
| sha256 不匹配 | 分发点上的工件被换过/被动手脚：重跑 `pull-release.sh` 核对；路由器改用新 sha 的命令 |
| 节点在 headscale 但路由 pending | `sudo headscale routes enable -r <ID>`，或配 `autoApprovers` |
| 路由 enabled 但访问不了内网 | 客户端开 `--accept-routes`；policy 放行；路由器 forward/防火墙（README「七、排错」里有 nft 规则） |
| headscale 起不来 | `sudo journalctl -u headscale -n 50 --no-pager` |
| VPS 拉不动 GitHub | 走 2.2 的中转（`--from`），别在 VPS 上硬重试 |
| 证书快到期 | 看 acme.sh 日志/root crontab；手动续期：`sudo /root/.acme.sh/acme.sh --renew -d <域> --ecc --force`（参数以该版本 `--help` 为准） |
| 换了 `ts.conf` 不生效 | 真实值要放 `ts.conf.local`（它最后 source）；`ts-doctor` 会报告 |

## 5. 本项目踩过的坑（别再踩）

- **VPS ↔ GitHub 不稳**：VPS 侧拉取优先用中转 `--from`；中转也就多两条 curl + 一次 pscp
- **headscale v0.28 的 `preauthkeys create --user` 只收数字 ID**：`server/headscale-bootstrap.sh` 里按用户名传的写法在该版本会失败（待修）
- **nginx 的 `server_name` 必须和 `BASE_URL` 的域名一致**：只改一边 → 404
- **token 不是密钥**：它是"挡爬虫"的随机路径，公开仓库的 run 日志里会带上，当作公开地址看待
- **Windows + plink/pscp**：PowerShell 5.1 会吞掉参数里内嵌的双引号（远端 `grep "a|b"` 会变成真管道）——远端命令尽量别用双引号
- **R4A 只有 16MB flash**：二进制永远只放 `/tmp`；`/etc/tailscale` 只放几十 KB 的 state
- **dpkg 升级 headscale 会覆盖 `config.yaml`**（conffile 交互里选了/等效于"安装维护者版本"）：一律用 `sudo dpkg -i --force-confold <deb>`。症状是只监听 `127.0.0.1:8080`、DERP/STUN 消失、节点全掉线；恢复用 `config.yaml.dpkg-old`（或自己的 `config.yaml.bak`）覆盖回去再重启
- **headscale 0.29 起禁止降级**：升级前必须 tar 备份 `/etc/headscale` + `/var/lib/headscale`；回滚 = 恢复 DB + 换回旧二进制（直接降级会被拒绝启动）
