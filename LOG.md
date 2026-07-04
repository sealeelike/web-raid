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

## 2026-07-04 — Module 4: backupctl run（实际备份执行）

- 新增 `run_one_target()` + `cmd_run()`：多 target 遍历、`nice -n 19 ionice -c3` 低优先级限速执行、`flock` 防并发（fd 跟随进程生命周期自动释放）、无条件 `restic unlock` 清理 stale lock、成功后自动 `forget --keep-last <N> --prune`
- 端到端验证（针对真实测试 VPS）：正常备份→prune 循环确认 keep-last 生效；**关键场景**——用 80MB 测试文件制造几十秒的备份窗口，`kill -9` 整个 run 进程模拟断电中断，确认 `flock` 自动释放、远端确实留下 stale lock、重跑后 `restic unlock` 自动清理且备份/prune 正常完成，不需要人工介入；并发跳过逻辑（第二次 run 检测到锁占用后正确跳过）也一并验证
- 详见 `doc/04-backupctl-run.md`

## 2026-07-04 — Module 5: 事件触发 backup-watcher

- 新增 `bin/backup-watcher.sh`：单次 `inotifywait -r --timeout` 循环（退出码 0=事件/2=超时，实测确认），去抖状态机（`dirty` + `last_event_epoch`），静默期默认 600 秒，触发失败不放弃、下轮自动重试
- 新增 `systemd/backup-watcher.service`（`__BACKUP_HOME__` 占位符模板）+ `backupctl service install/status/uninstall`：通用批量安装逻辑，`sed` 替换占位符为真实路径写入 `~/.config/systemd/user/`，为模块 6 的 ticker unit 预留好同一套安装逻辑
- 环境准备：本机 缺 `inotify-tools` 且无免密 sudo，用已配置好的图形化 askpass（`sudo -A apt-get install -y inotify-tools`）解决，不需要用户在对话里输入密码
- 端到端验证：新建测试 target + 测试目录，短静默期（15s）模拟连续两次写入，确认去抖真正等满静默期才触发、`backupctl run --force` 被自动调用且成功产生新快照；`service install/status/uninstall` 全流程针对真实 systemd --user 验证通过
- 详见 `doc/05-backup-watcher.md`

## 2026-07-04 — Module 5 修正：全局静默计时器 → 每目录独立触发

- **背景**：模块 5 最初实现是全部监控目录共享一个静默计时器，任何一个目录有变化都会刷新同一个计时器，等大家一起静默才对全部目录跑一次备份。用户实测复盘时指出问题："A 目录可能和 B 目录完全没关系，凭什么 A 要等 B？如果 B 难得空闲，A 也无法备份。" 并明确不同意这个设计
- 我最初提出的"只改触发条件为任一目录静默即触发，但备份动作仍是全量扫描"的折中方案被用户否决——因为这会导致 A 触发时把还在写入中的 B 一起扫进去，等于把"A 被拖累"的问题换成了"B 被抢跑"，没有解决根本问题
- **确认关键前提**：`restic forget --help` 证实默认按 `host,paths` 分组做保留策略清理，也就是说只要每个目录用独立的 `restic backup <目录>` 调用，各自天然形成独立的保留分组，不需要"全量快照才能保证一致性"这个假设
- **修正实现**：`bin/backupctl` 的 `run_one_target()`/`cmd_run()` 新增 `--path <目录>` 精确单目录备份；新增 `EX_LOCK_BUSY=75` 专用退出码区分"锁冲突跳过"和"真正失败"；`bin/backup-watcher.sh` 从单一全局 `inotifywait` 循环重写为每个目录一个独立的 `watch_one_dir()` 后台循环（各自独立的 `dirty`/`last_event_epoch` 状态），主循环每 30 秒对比 `paths.conf` 动态增删对应的监控循环
- 端到端验证（真实测试 VPS + 两个独立测试目录）：只写目录 A 一次后让其静默，同时持续每 3 秒写目录 B 模拟"B 一直很忙"——确认 A 在自己的静默期满后独立触发、快照只含 A 的文件，全程没有等待 B；B 在持续写入期间没有被任何触发扫入；B 自己静默后独立触发、快照只含 B 的文件；`restic snapshots` 确认两个目录的 `host,paths` 保留分组互不干扰、各自正确保留最新一份
- 详见更新后的 `doc/05-backup-watcher.md`

## 下一步

Module 6: 累计开机兜底 `backup-ticker.service`/`.timer`（15 分钟 tick，成功后清零，默认 6 小时强制阈值，复用已有的 `--force` 参数）——鉴于模块 5 的独立性原则，需要跟用户确认兜底状态是否也要按目录独立记录（而不是按 target 记录一个时间戳），避免重新引入跨目录互相牵连的问题
