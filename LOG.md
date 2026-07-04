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

## 2026-07-04 — Module 2: VPS 端一键脚本

- 编写 `backup-server-setup/setup-backup-server-hardened.sh`（独立目录，风格参照 `install-agent-hardened.sh`）
- 在测试 VPS `<vps-name>` 上完整跑通两次（含一次故意重装验证幂等逻辑），最终做了端到端验证：`restic init` → `restic backup` → `restic snapshots` 全部针对真实部署的 rest-server 跑通
- 踩坑与修复详见 `doc/02-vps-setup-script.md`（tar.gz 解压路径、`--private-repos` 模式下根路径鉴权自检逻辑错误）
- 端口 `9199` 确认与现有 nginx/xray/x-ui 均无冲突

## 2026-07-04 — Module 3: backupctl 骨架（target/path 管理）

- 新增 `bin/lib.sh`（颜色 helper、路径解析、`resolve_restic()` 免 root 兜底下载）与 `bin/backupctl`（`target add/list/remove`、`path add/remove/list`）
- 补上 `.gitignore` 里漏掉的 `config/targets/*.pass`（发现时仓库密码文件本会被 git 追踪到，已修复）
- 踩坑与修复：`path remove` 删除最后一条记录时 `set -euo pipefail` + `grep -v` 空输出退出码 1 导致 `mv` 被短路、静默不生效；顺带发现并修复了 `backup-server-setup` 仓库里 VPS 脚本"仅新增凭据"分支端口占用检查顺序错误的 bug（复用场景下端口本来就该被占用，却被当成冲突拒绝）
- 端到端验证：针对真实测试 VPS，`target add` 粘贴凭据 → `restic init` → `restic backup` → `restic snapshots` 全部跑通；`target remove`、`path add/remove/list`（含删除最后一条记录的边界场景）均复测通过
- 详见 `doc/03-backupctl-skeleton.md`

## 下一步

Module 4: `backupctl run`（实际备份执行：多 target 遍历、nice/ionice 限速、flock 防并发、成功后 forget --prune）
