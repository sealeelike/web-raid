# 模块 6：累计开机兜底 backup-ticker（每目录独立计数）

代码：`bin/backup-ticker.sh`（systemd timer 触发的 oneshot 脚本）+ `bin/lib.sh` 新增 `path_slug()` + `bin/backupctl` 的 `run_one_target()` 新增"成功后清零对应目录 tick"逻辑 + `systemd/backup-ticker.service`/`.timer`。

## 做什么

`backup-watcher.sh` 只在文件真的发生变化时才会触发备份——如果一个目录长期没有任何变化，watcher 永远不会主动碰它。`backup-ticker.sh` 是这条路径的兜底：每个目录只要"累计在线"够久（默认 6 小时）都没有成功过一次备份，就无视有没有文件变化强制跑一次，保证"用久了总会备份"这条底线。

## 为什么按"累计在线时长"而不是"自然日"

沿用最初设计讨论的结论：笔记本本来就不会 24 小时开机，如果按自然日算（比如"超过一天没备份就强制跑"），关机一整天也会被计入"已经一天没备份"，逼着开机后立刻触发一次可能毫无必要的备份。改成 systemd `--user` timer 每 15 分钟 tick 一次、每次 tick 计数加一——**timer 本身只有在用户登录桌面会话期间才会运行**，关机/合盖期间 timer 不触发，tick 自然不会累加。这样"6 小时阈值"实际衡量的是"这台机器实际被使用了 6 小时"，不是挂钟上过了 6 小时。

## 沿用模块 5 的独立性原则

模块 5 的修正记录（`doc/05-backup-watcher.md` 末尾）已经提前留了提醒：既然每个目录的触发都已经独立，兜底状态也必须按目录独立记录，不能按 target 记一个全局时间戳——否则会重新引入"一个目录的强制备份把其他目录一起扫进去"的老问题。本模块从一开始就按这个结论实现：

1. **每个目录一个独立的 tick 计数文件** `var/uptime-ticks.<slug>`（`slug` 由 `path_slug()` 把目录路径里的非字母数字字符换成 `_` 得到，个人单机场景不需要处理哈希碰撞）
2. **每个目录的 tick 只在这个目录自己被成功备份后才清零**——不管这次成功是 watcher 触发的、ticker 自己强制触发的、还是用户手动 `run` 的，只要覆盖到这个目录就清零；这个清零动作放在 `bin/backupctl` 的 `run_one_target()` 成功分支里（对 `paths` 数组里的每个目录都清一次），而不是放在 ticker 脚本里，这样不管谁触发了成功的备份，兜底计时都会正确重置，不需要 ticker 反过来监听其他触发源
3. **强制触发失败（锁冲突或备份真的失败）不清零、不放弃**，保留 tick 数，下一次 tick（15 分钟后）继续尝试触发——和 watcher 的"失败不清空 `dirty`"是同一个思路

## 关键实现点

1. `THRESHOLD_TICKS = THRESHOLD_HOURS * 3600 / TICK_INTERVAL_SECONDS`，两个环境变量都可覆盖（`BACKUP_TICKER_THRESHOLD_HOURS` 默认 6，`BACKUP_TICKER_INTERVAL_SECONDS` 默认 900），但 `TICK_INTERVAL_SECONDS` 必须和 `systemd/backup-ticker.timer` 里的 `OnUnitActiveSec` 保持一致，否则算出来的阈值 tick 数会跟实际 tick 节奏对不上——这个约束只能靠文档和脚本内注释提醒，两处硬编码 900/15min 保持同步
2. `backup-ticker.sh` 是 oneshot（一次性跑完就退出），不是像 `backup-watcher.sh` 那样的常驻循环——每次被 timer 唤醒时，读一遍 `paths.conf`，对每个目录各自的 tick 文件加一、判断是否达标、达标则调用 `backupctl run --force --path <目录>`
3. `path_slug()` 挪进 `lib.sh` 共享：`backup-ticker.sh` 写 tick 文件名和 `backupctl` 清零 tick 文件名必须用完全一致的 slug 算法，放两处容易写岔，所以只写一份共用
4. `systemd/backup-ticker.timer`：`OnBootSec=5min`（登录/启动后 5 分钟先跑一次）+ `OnUnitActiveSec=15min`（之后每 15 分钟一次）+ `Persistent=true`（如果开机时错过了本该触发的一次，下次启动会补跑一次——这只影响"这次 tick 什么时候被执行"，不影响 tick 计数本身的"只在在线时累加"语义）
5. `service install/status/stop/start/uninstall`（模块 5 已实现的批量安装/控制逻辑）不需要任何改动就能处理新增的 `.timer`+`.service` 组合——`cmd_service_install()` 里已经有的"识别 unit 是不是配对的 timer/service、配对的 service 不单独 enable --now"逻辑，正是模块 5 完成时特意为模块 6 预留的

## 实测记录（2026-07-04）

在测试 VPS（`<vps-host>`，为避免影响已有的常驻测试实例，临时用 `9198` 端口重新跑了一次一键脚本得到独立测试凭据，验证完毕后已在 VPS 上完全清理这次临时安装）：

1. `bash -n` 通过 `bin/backup-ticker.sh`、`bin/lib.sh`、`bin/backupctl` 全部语法检查
2. **达标触发场景**：`BACKUP_TICKER_THRESHOLD_HOURS=1 BACKUP_TICKER_INTERVAL_SECONDS=1800`（阈值=2 ticks）手动跑两次 `backup-ticker.sh`：第一次 tick 文件写入 `1`、不触发；第二次 tick 文件先算出 `2` 达标，触发 `backupctl run --force --path`，`restic snapshots` 确认真的产生了新快照，成功后 tick 文件被清零为 `0`
3. **失败/锁冲突保留场景**：手动持有 `var/backup.lock`（模拟另一个 `run` 正在执行）后再跑两次 ticker，第二次达标触发时 `run --force` 因为拿不到锁返回 `EX_LOCK_BUSY=75`，确认 tick 文件保留在 `2`（不清零、不放弃），下一轮会继续尝试
4. 测试完毕后清理：删除测试 target/目录/tick 文件，VPS 上停止并彻底移除临时起的 `restic-rest-server` 实例（`systemctl stop/disable` + 删除 `/opt/restic-rest-server` + 删除对应系统用户 + 删除 unit 文件），恢复到测试前状态

## 已知待办 / 注意事项

- `TICK_INTERVAL_SECONDS`（脚本默认 900）和 timer 的 `OnUnitActiveSec`（15min）必须手动保持一致，这是当前实现里唯一一处"改一边要记得改另一边"的耦合点，后续如果要支持"用户改了 timer 间隔但忘了改脚本"的容错，可以考虑让脚本从 `systemctl show` 读实际间隔，但目前场景下没必要——用户不太可能只改 timer 不改脚本
- 与模块 7（通知）的接口：ticker 强制触发成功/失败目前只写日志（`log_line`），还没有接通知；模块 7 落地后，`backupctl run` 的失败通知逻辑理应同时覆盖 watcher 和 ticker 触发的场景，不需要 ticker 单独再接一次
