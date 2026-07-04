# backup-server-setup

单机加密备份系统的 VPS 端一键部署脚本。配套的笔记本端项目见 `backup/`（独立仓库）。

## 用法

在目标 VPS 上以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/<your-gh>/<repo>/main/setup-backup-server-hardened.sh | bash
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

- 不使用 `--append-only`：与"保留最近 N 份快照"天然冲突，防篡改改由笔记本端项目的每日归档层（与实时仓库权限隔离）负责，详见 `backup/doc/00-architecture.md`
- `--private-repos`：一个 rest-server 实例按用户名隔离多个独立仓库，天然支持未来多客户端/多来源
- 服务伪装成通用系统监控 agent 的名字，降低被扫描器识别为备份服务的概率
