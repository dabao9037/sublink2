# SubLink2

SubLink2 是一个轻量、自托管的“多个节点转一个订阅”工具，也是 SubLink 的**纯原生部署版**。它保留当前 SubLink 的应用功能与 UI，使用 Python venv、systemd 和低权限系统用户运行，不需要容器运行时。

支持将多条 **VLESS / VMess / Trojan / Shadowsocks** 分享链接合并为长期订阅地址并生成二维码：

- Clash Meta / Mihomo / FlClash / Stash：自动输出 Clash YAML
- v2rayN / Shadowrocket 等其他客户端：输出通用 Base64

## 一键安装

支持 Ubuntu 20.04+、Debian 11/12/13，使用 root 或 sudo：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dabao9037/sublink2/main/install.sh) install
```

安装完成后，唯一管理快捷命令是：

```bash
sub
```

直接运行 `sub` 进入菜单：

```text
1. 安装 / 安全更新
2. 更换端口
3. 重设后台账号密码
4. 绑定域名与 HTTPS
5. 查看状态
6. 查看日志
7. 安全卸载
0. 退出
```

默认仅监听 `127.0.0.1`，避免后台端口直接暴露公网。推荐安装后运行 `sub domain example.com y` 绑定域名；临时访问也可以使用 SSH 隧道。

## 命令行操作

```bash
sudo sub install                         # 首次安装或安全更新
sudo sub update                          # install 的别名
sudo sub port 18096                      # 修改应用端口并同步受管代理
sudo sub credentials NewAdmin NewPass88  # 重设后台账号密码
sudo sub domain sub.example.com y        # 绑定域名并启用 HTTPS
sudo sub domain sub.example.com n        # 仅配置 HTTP
sudo sub status                          # 查看服务状态和访问方式
sudo sub logs 200                        # 查看最近 200 行日志
sudo sub uninstall YES n                 # 卸载程序，保留数据库和配置
sudo sub uninstall YES y                 # 卸载并删除全部数据和密钥
```

## 原生部署结构

- 程序版本：`/opt/sublink2/releases/<版本>/`
- 当前版本：`/opt/sublink2/current`（原子切换软链接）
- 每版本 venv：`/opt/sublink2/releases/<版本>/venv/`
- SQLite 数据：`/var/lib/sublink2/subscriptions.db`
- 持久配置：`/etc/sublink2/config.env`
- systemd 单元：`/etc/systemd/system/sublink2.service`
- 管理命令：`/usr/local/bin/sub`
- wheel 缓存：`/var/cache/sublink2/wheels/`
- 运行用户：专用低权限用户 `sublink2`

服务安装后执行 `systemctl enable --now sublink2.service`，服务器重启后会自动恢复。配置文件仅允许 root 和 `sublink2` 组读取，数据目录归低权限用户所有。

## 更新与数据持久化

运行：

```bash
sudo sub update
```

更新会：

1. 从 `dabao9037/sublink2` 的 `main` 下载全新源码；
2. 在新的 release 目录创建 venv、下载/安装固定版本依赖并做导入检查；
3. 保留数据库、后台账号密码、`APP_SECRET`、端口、域名和 HTTPS 设置；
4. 原子切换 `current` 后重启并检查 `/healthz`；
5. 如果新版本启动失败，自动切回上一版本。

应用数据不放在代码目录，因此更新不会覆盖数据库。

## 域名与 HTTPS

运行：

```bash
sudo sub domain sub.example.com y
```

绑定逻辑会先识别 80/443 的当前监听者：

- 已有 Caddy：复用现有 Caddy；支持管理 API 不可用时由 systemd 安全重启加载。
- 已有 Apache：复用 Apache 与 Certbot Apache 插件。
- 已有 Nginx：复用 Nginx 与 Certbot Nginx 插件。
- 80 端口空闲：安装并使用 Nginx。
- 端口由未知程序占用：安全退出，不停止或抢占现有服务。

应用和受管代理服务都会验证 `enabled` 与 `active`。更换端口会同步更新 Caddy、Apache 或 Nginx，而不是只更新其中一种。

首次签发证书前：

- 域名 A 记录必须直指本机公网 IPv4；
- 80/443 必须在安全组和防火墙放行；
- Cloudflare 用户应先关闭代理（灰云），成功后再开启；
- Cloudflare SSL/TLS 建议使用 **Full (strict)**。

## 备份与恢复

最重要的两个备份对象：

```text
/var/lib/sublink2/subscriptions.db
/etc/sublink2/config.env
```

数据库中的节点由 `APP_SECRET` 加密，因此**必须同时备份配置文件**。推荐停服务后打包：

```bash
sudo systemctl stop sublink2
sudo tar -C / -czf sublink2-backup-$(date +%F).tar.gz var/lib/sublink2 etc/sublink2
sudo systemctl start sublink2
```

恢复时把两个目录放回原路径并重新运行一键安装命令；安装器会保留并使用原数据库、账号、密钥、端口和域名配置。

## 与 Sublink Docker版的区别

| 项目 | SubLink2 | Sublink Docker版 |
|---|---|---|
| 运行方式 | Python venv + systemd | 容器编排 |
| 管理命令 | `sub` | 旧版命令 |
| 默认监听 | `127.0.0.1` | 端口映射 |
| 数据目录 | `/var/lib/sublink2` | 旧版项目数据卷 |
| 更新方式 | 新 release 构建、健康检查、原子切换和失败回滚 | 重建容器 |
| 适合场景 | 轻量 VPS、希望原生服务管理 | 已有容器环境 |

两个项目彼此独立。SubLink2 的安装、更新、运行和测试脚本不会调用或安装容器运行时，也不会从旧 `dabao9037/sublink` 仓库运行应用代码。

## 本地开发与测试

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt pytest==8.4.2
PYTHONPATH=. .venv/bin/pytest -q
bash -n install.sh
```

原生 HTTP smoke：

```bash
TMP_DB=$(mktemp)
APP_SECRET='yU0Nu5NptM9YvbIYI1Q2hk4SSABNbDiVjytk1Eg6jwo=' \
ADMIN_USER=admin ADMIN_PASSWORD=test-password DB_PATH="$TMP_DB" \
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 18096
curl http://127.0.0.1:18096/healthz
curl http://127.0.0.1:18096/login
```

## 安全说明

- 后台使用独立登录页面和 HttpOnly 会话 Cookie；
- 节点链接用 Fernet 加密后写入 SQLite；
- 订阅 URL 使用高强度随机 Token；
- systemd 启用低权限用户、`NoNewPrivileges`、`ProtectSystem=strict` 等加固；
- 不抓取远程订阅，不主动连接节点服务器；
- 公网长期使用务必绑定 HTTPS。

## License

MIT
