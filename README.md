# backup-server-setup

单机加密备份系统的 VPS 端一键部署脚本。配套的笔记本端项目见 `backup/`（独立仓库）。

## 用法

在目标 VPS 上以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/sealeelike/web-raid/main/setup-backup-server-hardened.sh | bash
```

或者下载后本地执行：

```bash
bash setup-backup-server-hardened.sh
```

脚本会：
1. 自动安装缺失依赖（curl/tar/openssl/apache2-utils/git）
2. 从 GitHub Release 下载对应架构的 `rest-server` 二进制并校验 SHA256
3. 创建专用受限系统用户，二进制归 root、数据目录归受限用户
4. 交互式证书选择：Let's Encrypt / 自签（默认）/ 自定义路径
5. 生成随机账户凭据（htpasswd bcrypt）
6. 写入加固的 systemd 服务并启动
7. 打印一行 base64 凭据 blob，供笔记本端 `backupctl target add` 粘贴使用

重新运行脚本可以：仅新增一个新的备份来源凭据（复用现有服务），或完全重新安装。

## 设计要点

- 不使用 `--append-only`：与"保留最近 N 份快照"天然冲突，防篡改改由笔记本端项目的每日归档层（与实时仓库权限隔离）负责，详见下面的 `install-archiver.sh`
- `--private-repos`：一个 rest-server 实例按用户名隔离多个独立仓库，天然支持未来多客户端/多来源

## 归档层：install-archiver.sh

`setup-backup-server-hardened.sh` 部署完成后，在同一台 VPS 上以 root 再跑一次：

```bash
bash install-archiver.sh
```

给这台 VPS 追加一个"每日归档 + 按份数淘汰"层：每天把 `rest-server` 的实时仓库数据（`--private-repos` 下每个用户各自的仓库目录）用 `rsync --link-dest` 硬链接归档一份到独立目录（默认 `/srv/backup-archive`），归档目录归 root 所有、权限 700，`rest-server` 的服务账户对它没有任何读写权限——即使笔记本这端的备份凭据被完全攻破，攻击者能删的只有实时仓库，删不到任何一份历史归档。淘汰旧归档按"份数"（默认保留 7 份），不按日期，笔记本长期离线不产生新归档也不会误删仅存的历史。

重新运行本脚本可以调整保留份数等参数，不会丢已有归档。详细设计和真实测试记录见 `backup/doc/09-archive-and-prune.md`（笔记本端仓库）。
