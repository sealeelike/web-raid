# 模块 5：事件触发 backup-watcher

代码：`bin/backup-watcher.sh`（常驻监控脚本）+ `bin/backupctl` 新增 `service install/status/uninstall` + `systemd/backup-watcher.service`（unit 模板）。

## 做什么

监控 `config/paths.conf` 里的所有目录，检测到文件变化后不立刻备份，而是等到"连续静默一段时间都没有新变化"（默认 600 秒）才真正触发一次 `backupctl run --force`——避免在文件还在写入的过程中就抢跑，抢跑会导致同一份还没写完的文件被拆成好几次增量备份，也可能在极端情况下备份到一份逻辑不一致的中间状态。

## 关键实现点

1. **单次 `inotifywait -r` 循环，而非 `-m` 常驻监控管道**：每轮循环都重新调用一次 `inotifywait -r -e ... --timeout <CHECK_INTERVAL> -qq <dirs>`。实测确认退出码语义：`0` = 等到一个事件立刻返回，`2` = 等满 `CHECK_INTERVAL` 秒（默认 30s）无事件发生而超时，其他退出码视为异常。选择这个模式而非"`-m` 监控 + 管道 + `read -t` 超时"的原因：`read -t` 超时和管道 EOF 的退出码在 bash 里容易混淆，不如 `inotifywait --timeout` 的 0/2 退出码来得明确可靠；额外的好处是每轮重新调用 `inotifywait -r` 会基于当前目录树重新建立递归监控，`paths.conf` 里新增的目录、目录树里新建的子目录都能在下一轮循环自动生效，不需要重启这个常驻进程。
2. **去抖状态机**：`dirty` 标志 + `last_event_epoch` 时间戳。检测到事件就置位 `dirty=1` 并刷新时间戳；每轮循环检查"当前时间 - 最后事件时间 是否 ≥ 静默期"，是就触发 `backupctl run --force` 并清空 `dirty`。
3. **失败重试而非放弃**：如果这次自动触发的 `backupctl run --force` 失败（比如网络问题），**不清空** `dirty` 标志——下一轮 `CHECK_INTERVAL`（30 秒）后会自动重新判断并重试，直到成功，或者又有新的文件变化重新计时。不需要额外写重试逻辑，白嫖了循环本身的节奏。
4. **`BACKUP_WATCHER_DEBOUNCE_SECONDS` 环境变量覆盖**：默认 600 秒（10 分钟），可通过环境变量临时调小方便测试，正式使用不需要设置。
5. **零手动改配置的 systemd 安装**：`systemd/backup-watcher.service` 里 `ExecStart` 用 `__BACKUP_HOME__` 占位符代替绝对路径（因为这个项目可能被部署在不同用户/不同路径下，不能写死）。新增的 `backupctl service install` 子命令：
   - `sed` 替换占位符为真实的 `$BACKUP_HOME` 绝对路径，写入 `~/.config/systemd/user/`
   - `systemctl --user daemon-reload` + `enable --now`
   - 设计成通用的"批量安装 `systemd/` 目录下所有 unit"逻辑（`.service` 独立启动，`.timer` 启用自己、同名 `.service` 交给 timer 触发不单独启动）——这样模块 6 的 `backup-ticker.service`/`.timer` 落地后，不需要再改 `cmd_service_install`，直接把两个文件放进 `systemd/` 目录即可被这套逻辑自动识别安装
   - 配套 `service status`（遍历所有 unit 跑 `systemctl --user status`）、`service uninstall`（disable + 删除文件 + daemon-reload）
6. **依赖检测**：脚本开头检查 `inotifywait` 是否存在，缺失时给出明确的安装提示而不是让 `set -e` 直接崩在某个未定义命令上。

## 环境准备

`inotifywait` 来自 `inotify-tools` 包，本机 默认没有装、也没有免密 sudo。通过已配置好的图形化 askpass 助手解决（`sudo -A apt-get install -y inotify-tools`，弹出 GNOME 图形密码框，不需要在终端/对话里输入密码）——细节见 memory 里的 `sudo_askpass` 记录和 `~/READMEs/sudo-askpass.md`。

## 实测记录（2026-07-04）

1. `bash -n bin/backup-watcher.sh` 语法检查通过
2. 用 VPS 一键脚本"仅新增凭据"分支生成了一个新测试用户 `watchertest`，`backupctl target add` 添加为 `watcher-test` target，`backupctl path add /tmp/watcher-test-src` 注册测试目录
3. `BACKUP_WATCHER_DEBOUNCE_SECONDS=15 bin/backup-watcher.sh &` 启动watcher，在测试目录里写入两次文件（间隔 3 秒模拟"还在写入中"），确认：
   - 两次写入都被检测到（`dirty` 保持置位，`last_event_epoch` 被刷新到最后一次写入的时间）
   - 静默期真正等满 15 秒无新变化后才触发，而不是第一次写入后立刻触发
   - 触发后日志出现 `静默期已过...触发备份`，随后 `backupctl run --force` 真实执行了一次 `restic backup` + `forget --keep-last 1 --prune`，`var/log/backup.log` 能看到完整的成功记录，远端仓库确实多了一份新快照
4. `backupctl service install`：unit 文件正确写入 `~/.config/systemd/user/backup-watcher.service`，路径占位符被正确替换成真实的 `<client 目录>`，`systemctl --user status` 确认服务 `active (running)`，日志里能看到进程启动信息
5. `backupctl service uninstall`：确认 unit 被正确 disable + 删除，`systemctl --user list-unit-files` 里不再有残留
6. 测试完毕后清理了测试 target/path/systemd unit，不留手工痕迹

## 已知待办

- `service install` 目前只会把 `systemd/` 目录下现有的 unit 全部装一遍；模块 6 的 ticker unit 落地后会自然被这套逻辑一并处理，不需要额外改动
- systemd `--user` 服务默认只在图形桌面会话存在期间运行——如果笔记本合盖但用户没有真正登出，GNOME 会话通常还在（不算注销），服务不受影响；只有在真正 `logout`/服务器无图形会话的场景才需要 `loginctl enable-linger $USER`，`service install` 只打印提示不会自动执行这条命令（涉及改变用户级系统配置，交给用户自己决定）
