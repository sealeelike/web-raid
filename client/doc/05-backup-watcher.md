# 模块 5：事件触发 backup-watcher（每目录独立触发）

代码：`bin/backup-watcher.sh`（常驻监控脚本）+ `bin/backupctl` 新增 `run --path <目录>` / `service install/status/uninstall` + `systemd/backup-watcher.service`（unit 模板）。

## 设计修正说明

本模块最初实现是"全局共享一个静默计时器"：任意一个被监控目录发生变化都会刷新同一个计时器，等所有目录都不再变化、共同静默满一段时间后，才对 `paths.conf` 里的全部目录跑一次 `backupctl run --force`。

用户在实测验证阶段指出这个设计有问题："A 目录可能和 B 目录完全没关系，凭什么 A 要等 B？如果 B 难得空闲，A 也无法备份。" 具体来说共享计时器有两个反直觉的后果：

1. 目录 A 早就写完静默了，但因为目录 B 还在持续活动，A 的备份会被无限期推迟——A 和 B 逻辑上毫不相关，不该互相拖累
2. 反过来，如果为了不拖累 A 而把触发条件从"全部静默"改成"任一个静默"，又会导致"全量扫全部目录"的那次备份把仍在写入中的 B 也一起扫进去，破坏 B 自己的静默保护意义——这不是真正的独立，只是把问题从"A 被拖累"换成了"B 被抢跑"

**修正方案**：不是"改触发条件"，而是从根本上让每个目录拥有完全独立的监控循环、独立的静默计时器、独立的触发动作——只对这一个目录调用 `restic backup <目录>`，不牵涉其他目录。这要求确认一件事：`restic forget` 默认按 `host,paths` 分组做保留策略清理（`restic forget --help` 确认），也就是说只要每次都用同一个 `<目录>` 单独调用 `backup`，这个目录会自动形成自己独立的快照分组，`--keep-last 1 --prune` 天然只在这个分组内生效，不需要"大家凑成一次全量快照才算数"这种假设。这样重新设计后，A 和 B 互不相关、互不阻塞、互不牵连，各自的保留策略也天然独立正确。

## 做什么

`config/paths.conf` 里配置的每一个目录，各自拥有一个独立的后台监控循环：独立检测文件变化、独立维护"最后一次变化时间"、独立判断静默期是否已过、独立触发只针对这一个目录的 `backupctl run --force --path <目录>`。任何一个目录的忙碌状态完全不影响其他目录的监控和触发节奏。

## 关键实现点

1. **每目录一个独立的 `watch_one_dir()` 后台循环**：脚本主循环每隔 `RESCAN_INTERVAL`（30s）读一次 `paths.conf`，用 `WORKER_PID` 关联数组维护"目录 → 对应后台循环 PID"，新增的目录自动起一个新的 `watch_one_dir <dir> &`，从 `paths.conf` 移除的目录自动 `kill` 掉对应循环——不需要重启整个 watcher 进程就能感知目录增删。
2. **单次 `inotifywait -r --timeout` 循环**：每个 `watch_one_dir` 内部仍然是"每轮重新调用一次 `inotifywait -r -e ... --timeout <CHECK_INTERVAL> -qq <dir>`"这个模式（沿用最初验证过的 0=事件/2=超时退出码语义），只是范围收窄到这一个目录，不再把多个目录传给同一次 `inotifywait` 调用。
3. **去抖状态机就地独立化**：`dirty` 标志和 `last_event_epoch` 时间戳变成每个 `watch_one_dir` 循环的局部变量，不再是脚本级别的全局共享状态——这是本次修正的核心。
4. **`backupctl run --path <目录>` 精确单目录备份**：`run_one_target()` 新增 `only_path` 参数，非空时只备份这一个目录，不读整个 `paths.conf`；`cmd_run()` 新增 `--path` 解析与合法性校验（必须是已在 `paths.conf` 里的目录）。
5. **`EX_LOCK_BUSY=75` 专用退出码**：因为现在同一时刻可能有多个目录各自的循环都想触发 `backupctl run`，而 `run` 内部仍然用同一把 `flock` 防止真正并发写同一个 restic 仓库，所以"这次触发因为锁被占用而跳过"必须能和"真正的备份失败"以及"什么都不用做的成功"区分开——用 0/1/75 三种退出码：0=成功，1=备份或清理失败，75=锁忙本次跳过。`watch_one_dir` 收到非 0（不管是 75 还是 1）都不清空 `dirty`，留给下一轮 `CHECK_INTERVAL` 自动重试。
6. **失败/锁冲突都重试而非放弃**：与之前一致，不清空 `dirty` 即可白嫖循环本身的重试节奏，不需要额外写退避逻辑。
7. **零手动改配置的 systemd 安装**：`backupctl service install/status/uninstall` 逻辑不变（`__BACKUP_HOME__` 占位符替换 + 批量安装 `systemd/` 目录下所有 unit），本次修正没有触及这部分。

## 实测记录（2026-07-04，修正后重新验证）

1. `bash -n bin/backup-watcher.sh` 与 `bash -n bin/backupctl` 语法检查均通过
2. 新建测试 target `multitest2`（凭据通过程序化管道传递，避免手动转录长 base64 出错），注册两个空目录 `/tmp/watcher-multi-a`、`/tmp/watcher-multi-b`
3. `BACKUP_WATCHER_DEBOUNCE_SECONDS=12 bin/backup-watcher.sh &` 启动，确认为 A、B 各自起了一个独立的 `inotifywait` 子进程（`ps` 可见两个独立 pid）
4. **核心场景验证**：只往 A 里写一次文件后让它静默，同时每隔 3 秒持续写 B（模拟"B 一直很忙、迟迟不空闲"）：
   - A 在自己的静默期过后独立触发了 `backupctl run --force --path /tmp/watcher-multi-a`，快照 `232c01fe` 只包含 A 的这一个文件（19B），**完全没有等待 B**
   - B 在整个"持续写入"的窗口内没有被任何一次触发扫入（因为触发时其他目录的循环压根不知道 B 的存在，只会备份自己负责的那一个目录）
   - B 后续自己停止写入、静默期满后，独立触发了自己的备份，快照 `021f8226` 只包含 B 的 8 个文件（160B）
5. **保留策略独立性验证**：两次 `forget --keep-last 1 --prune` 分别在各自的 `host,paths` 分组内生效——`restic snapshots` 显示 A 的分组只保留 `232c01fe`（path=/tmp/watcher-multi-a），B 的分组只保留 `021f8226`（path=/tmp/watcher-multi-b），互不影响、互不清除对方的快照
6. 测试完毕后：显式按 PID kill 掉 watcher 主进程和所有 `inotifywait` 子进程（避免 `pkill -f` 误伤同名字符串导致的自杀问题，实测中一度踩到这个坑），`backupctl path remove`/`target remove` 清理配置，删除临时测试目录，`path list`/`target list` 确认恢复到空状态，不留手工痕迹

## 环境准备

`inotifywait` 来自 `inotify-tools` 包，本机默认没有装、也没有免密 sudo。通过已配置好的图形化 askpass 助手解决（`sudo -A apt-get install -y inotify-tools`，弹出 GNOME 图形密码框，不需要在终端/对话里输入密码）。

## 已知待办 / 注意事项

- `CHECK_INTERVAL`（当前 30s）同时承担"`inotifywait --timeout` 的等待上限"和"静默条件的检查节奏"两个角色：如果把 `DEBOUNCE_SECONDS` 设得比 `CHECK_INTERVAL` 还小（仅测试场景才会这么做），实际触发时间点会向后取整到下一次 `CHECK_INTERVAL` 超时，而不是精确在静默期刚满时立刻触发——生产默认值 `DEBOUNCE_SECONDS=600` 远大于 `CHECK_INTERVAL=30`，不受这个取整影响，属于预期行为，不是 bug
- `service install` 目前只会把 `systemd/` 目录下现有的 unit 全部装一遍；模块 6 的 ticker unit 落地后会自然被这套逻辑一并处理，不需要额外改动
- systemd `--user` 服务默认只在图形桌面会话存在期间运行——只有在真正 `logout`/服务器无图形会话的场景才需要 `loginctl enable-linger $USER`，`service install` 只打印提示不会自动执行这条命令
- **给模块 6 的提醒**：既然每个目录的触发已经是独立的，累计开机兜底的"距上次成功备份"状态也应该按目录独立记录（而不是按 target 整体记录一个时间戳），否则会重新引入"一个目录的兜底强制备份把其他目录一起扫入"的老问题——这个点在模块 6 开始前需要和用户确认设计
