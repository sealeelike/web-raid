# 模块 7：通知策略（失败即时弹窗 + 成功每日汇总）

代码：`bin/lib.sh` 新增 `notify()` + `SUCCESS_LOG`；`bin/backupctl` 的 `run_one_target()` 成功/失败分支各接入一处；新增 `bin/backup-summary.sh` + `systemd/backup-summary.service`/`.timer`。

## 做什么

- **失败立即弹窗**：任何一次备份失败（不管是手动 `run`、watcher 事件触发、还是 ticker 累计开机兜底触发），立刻 `notify-send -u critical` 提示，不等汇总
- **成功不逐次打扰，攒起来每天汇总一次**：每次成功只静默记一行（时间戳 + target 名）到 `var/success-log`；`backup-summary.sh` 由 systemd timer 每天固定时间跑一次，读出这段时间内的成功记录数量和起止时间，汇总成一条 `notify-send` 通知，然后清空 `success-log`

## 为什么接入点放在 `run_one_target()` 而不是 watcher/ticker 各自实现一遍

失败/成功的通知逻辑只写了一份，放在 `bin/backupctl` 的 `run_one_target()` 里——这是模块 5/6 就已经确立的"共同收敛点"：不管触发源是手动 `run`、`backup-watcher.sh`（事件去抖后调用 `backupctl run --force --path`）、还是 `backup-ticker.sh`（累计开机阈值触发后调用同一条命令），最终都会走到这个函数。把通知逻辑放这里，三条触发路径自动全部覆盖，不需要 watcher/ticker 各自维护一份重复逻辑（也不会出现"改了一处忘了改另一处"的不一致风险）。

## 为什么不需要额外记"上次汇总时间"

`success-log` 本身只保存"自上次汇总以来"的成功记录——`backup-summary.sh` 每次读完就清空这个文件（`> "$SUCCESS_LOG"`），下一次备份成功会重新从空文件开始追加。所以"这段时间"天然就是"文件当前的全部内容"，不需要额外记录一个时间戳再去反向过滤日志。汇总通知的起止时间直接取文件第一行和最后一行的时间戳字段即可。

如果 `success-log` 是空的（没有新的成功记录），`backup-summary.sh` 直接静默跳过，不发"0 次备份"这种没有意义的通知。

## 关键实现点

1. `notify()`（`lib.sh`）：`notify-send` 未安装或调用失败（比如纯 SSH 无图形会话）都静默忽略，不能让通知失败影响调用方的正常流程
2. 失败分支：`err`/`log_line` 之后追加 `notify critical "备份失败: ${name}" "..."`，消息体区分"全部目录"还是 `--path` 指定的单个目录，方便用户一眼看出是哪部分数据没成功
3. 成功分支：在模块 6 已有的"清零对应目录 tick 计数"逻辑之后，追加一行 `echo "$(date ...) ${name}" >> "$SUCCESS_LOG"`
4. `backup-summary.sh`：oneshot，`wc -l` 数行数、`head -n1`/`tail -n1` 取首尾时间戳，`notify normal` 弹一条汇总，`log_line` 记一行到 `backup.log`，最后清空 `success-log`
5. `systemd/backup-summary.timer`：`OnCalendar=09:00` 固定每天一个时间点、`Persistent=true`（当天没开机就在下次登录时补跑一次）——`service install/status/stop/start/uninstall`（模块 5/6 已实现的批量逻辑）不需要任何改动就能识别这组新的 timer+service

## 实测记录（2026-07-04）

1. `bash -n` 通过 `bin/lib.sh`、`bin/backupctl`、`bin/backup-summary.sh` 全部语法检查
2. **失败通知**：配置一个必然连不上的假 target（本地端口 + 空证书文件）触发真实的 `restic backup` 失败，确认 `run_one_target()` 的失败分支被执行（`backup.log` 记录 `run: faketest 备份失败`）；单独手动跑一次 `notify-send -u critical` 确认当前登录会话（`DISPLAY=:0`、`DBUS_SESSION_BUS_ADDRESS` 均可用）下弹窗功能本身工作正常
3. **成功记录 + 汇总**：临时在测试 VPS 上起一个独立的 rest-server 实例（端口 9197，验证完毕已完全清理），针对真实仓库连续跑两次成功的 `backupctl run --force`，确认 `var/success-log` 正确追加两行；运行 `bin/backup-summary.sh` 确认：弹出汇总通知、`backup.log` 记录了汇总行（`summary: <first> ~ <last> 期间成功备份 2 次`）、`success-log` 被清空（size=0）；再次运行 `backup-summary.sh` 确认静默跳过（不发送任何通知，只打印一行提示）
4. 测试完毕后清理：本地删除临时 target/path 配置，VPS 上完全移除临时 `restic-rest-server` 实例（停止/禁用服务、删除 unit 文件、删除安装目录、删除专用系统用户、确认端口已释放）

## 已知待办 / 注意事项

- 汇总时间点固定写死 `OnCalendar=09:00`，如果用户希望换个时间，目前只能重新安装 unit 前手动改 `systemd/backup-summary.timer` 源文件（尚未接入 `backupctl` 的任何配置命令）——当前场景优先级不高，先用固定默认值
- 失败通知目前不去重：如果同一个 target 短时间内反复失败（比如 watcher 因为目录持续变化不断重试），会重复弹窗。目前认为这是合理的（用户本来就应该被持续提醒直到修好），暂不做频率限制
