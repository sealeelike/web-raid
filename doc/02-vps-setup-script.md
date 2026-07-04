# 模块 2：VPS 端一键部署脚本

脚本本体：`backup-server-setup/setup-backup-server-hardened.sh`（独立目录/独立仓库，风格参照 `install-agent-hardened.sh`）。

## 做什么

在一台全新（或已装过一次）的 VPS 上，以 root 一条命令部署好 restic 的 REST 后端，并打印一行凭据供笔记本端粘贴对接。

## 关键实现点

1. **依赖自愈**：先探测 `curl/tar/openssl/apache2-utils/git` 是否存在，缺什么 apt 装什么，不需要用户提前装好环境
2. **二进制来源**：GitHub Release 动态查询最新版本号（不写死版本），下载对应架构 tar.gz + `SHA256SUMS`，校验和比对通过才解压安装——避免下载被篡改的二进制
3. **专用受限用户**：`useradd -r -s /usr/sbin/nologin`，只对 `data/` 子目录有权限；二进制本身归 root，服务账户不能替换/删除它
4. **TLS 证书三选一菜单**（仿 3x-ui，回车默认自签）：
   - Let's Encrypt（acme.sh webroot 模式，适配已被 nginx 占用 80 端口的场景）
   - **自签证书（默认）**：探测公网 IP 作为 SAN，配合 `--cacert` 直接 pin
   - 自定义证书路径（复用已有证书）
5. **凭据**：`htpasswd -B`（bcrypt）生成账户，密码随机生成（`openssl rand -base64 24` 去除易混淆符号）
6. **rest-server 参数**：`--private-repos`（按用户名隔离仓库目录）+ `--tls`，**不加 `--append-only`**（原因见根目录 doc/00-architecture.md 和最初设计讨论）
7. **systemd 加固**：`NoNewPrivileges`/`ProtectSystem=strict`/`ProtectHome`/`PrivateTmp`/`PrivateDevices`/`CapabilityBoundingSet=` 等，只保留 `ReadWritePaths=<data dir>`
8. **自检易错点（已踩坑修复）**：`--private-repos` 模式下鉴权是按 URL 路径的用户名分段匹配的——请求根路径 `/` 永远 401，跟凭据对不对无关；必须请求 `/<user>/` 才能验证鉴权链路。自检逻辑改为：不带凭据访问 `/<user>/` 应该 401，带凭据访问应该不是 401（可能是 200/404/405，取决于仓库是否已 `restic init`）
9. **幂等**：重新运行脚本时如果检测到已安装，提供"仅新增一个新的备份来源凭据"（复用同一个 rest-server，给新客户端一个新用户）或"完全重新安装"两个选项——为将来同一台 VPS 服务多个来源留了口子
10. **凭据 blob**：`{host, port, user, pass, cert_pem_b64}` 打包成 JSON 再 base64 成一行，笔记本端 `backupctl target add` 直接粘贴解析（cert 用 base64 是因为 PEM 本身带真实换行，塞进单行 JSON 字符串不方便转义）

## 实测记录（2026-07-04，测试 VPS <vps-name>）

- 端口 9199 确认未被占用（与已有 nginx/xray/x-ui 均无冲突）
- 全新环境跑通：依赖自动安装 → 下载 v0.14.0 rest-server(amd64) → 自签证书 → 生成凭据 → 服务启动 `active`
- **踩坑 1**：rest-server release 的 tar.gz 解压后二进制在子目录 `rest-server_<ver>_linux_<arch>/rest-server` 里，不在顶层，用 `find` 定位后 `install` 修复
- **踩坑 2**：自检脚本最初请求根路径 `/` 判断 200，实际 `--private-repos` 模式下根路径鉴权永远 401（跟凭据无关），改成请求 `/<user>/` 并比较"无凭据 vs 有凭据"两次请求的状态码差异来判断鉴权是否真的生效
- **端到端验证**：本地临时拉取 restic 0.18.1 客户端二进制（无 root 环境下用免安装的单文件二进制验证），针对刚部署的 rest-server 执行 `restic init` → `restic backup` → `restic snapshots`，全部成功，证明整条链路（TLS 自签证书信任、htpasswd 鉴权、private-repos 路径隔离）真实可用，不只是"服务进程 active"这种表面验证

## 已知待办（记录不阻塞当前模块）

- `backupctl`（模块 3）需要考虑：系统没有 root/无法 `apt install restic` 时，自动下载单文件二进制到 `bin/.restic-local` 作为兜底（本模块验证时用的就是这个方式，已加入 `.gitignore`，不入库）
