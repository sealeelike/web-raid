# 开发日志

## 2026-07-04 — Module 1: 项目骨架

- 创建目录结构：`bin/ config/targets/ var/log/ systemd/ doc/`
- `git init`（本地仓库，非全局 git 身份）
- `.gitignore`：排除运行时状态文件（日志、锁、tick 计数）和敏感配置（`config/targets/*.env`、证书、`paths.conf`），这些都是本机私有数据，不应该进版本库
- 编写 `README.md`：快速部署步骤 + 项目亮点说明
- 建立本文件 `LOG.md` 与 `doc/` 目录，后续每完成一个模块在此追加一节

设计全文见完整设计讨论（VPS 端 rest-server、事件驱动+累计开机兜底触发、多 target 结构、按份数淘汰的归档策略等），落地文档会在对应模块完成时写入 `doc/`。

### 测试 VPS 信息

- `<vps-name>` / `<vps-host>:22`，Debian 12，已用专用 SSH key 打通（`~/.ssh/id_ed25519_backup_test`）
- 已占用端口：nginx(80,8447)、xray(443, 本地62789/11111)、x-ui(57680) —— rest-server 计划用 `9199`，Module 2 里会先探测确认未占用
- 缺 `git`、`apache2-utils`(htpasswd)，Module 2 脚本里会自动安装

---

## 下一步

Module 2: VPS 端一键脚本 `setup-backup-server-hardened.sh`
