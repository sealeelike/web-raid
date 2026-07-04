# 模块 4：backupctl run（实际备份执行）

代码：`bin/backupctl` 新增 `run_one_target()` + `cmd_run()`。

## 做什么

真正调用 `restic backup` 的地方。之前的模块只管理配置，这个模块第一次让 `backupctl` 产生实际的远端数据变化。

## 关键实现点

1. **多 target 遍历**：`backupctl run` 默认对 `config/targets/` 下所有 `ENABLED=true` 的 target 各跑一次独立备份（copy 模式：同一份 `paths.conf` 里的目录，分别全量备份到每个 target，互不影响）；`--target <name>` 只跑指定的一个。单个 target 失败不会中断其他 target——都跑完之后再统一返回失败状态。
2. **低优先级限速执行**：`nice -n 19 ionice -c3 restic backup ...`，如果 target 的 `.env` 里设了 `LIMIT_UPLOAD_KBPS`，追加 `--limit-upload`。不需要等"用户空闲"，跑在后台不抢占前台资源即可。
3. **`flock` 防并发**：`var/backup.lock` 通过 `exec 200>lockfile; flock -n 200` 的经典模式加锁——这个文件描述符跟随 `backupctl` 进程本身的生命周期，进程结束（无论正常退出还是被 `kill -9`）时锁自动释放，不需要手动清理。如果检测到锁已被占用（另一次 `run` 正在跑），直接跳过退出（exit 0，不算错误——这是预期中的"上次触发还没跑完，这次先不跑"）。
4. **stale lock 自动清理**：因为已经有本地 `flock` 保证不会有第二个 `backupctl run` 并发执行同一仓库，所以每次备份前无条件先跑一次 `restic unlock`——不会误伤真正在跑的进程（那种情况已经被 `flock` 挡在外面了），只会清理"上次 `restic backup` 被强制中断（断电/kill -9）后遗留在远端仓库里的锁文件"。
5. **成功后自动 `forget --keep-last <KEEP_LAST> --prune`**：`.env` 里已有的 `KEEP_LAST`（默认 1）—— 只有备份本身成功才会执行清理；`forget --prune` 本身失败只 warn 不影响本次备份的成功状态（下次 run 会重试清理）。
6. **`--force` 参数**：目前只是占位，接受但不做任何事——`run` 本身不做"要不要跑"的判断（没有去抖/兜底逻辑），这些逻辑属于模块 5/6 的触发器脚本，触发器决定什么时候调用 `run`，`run` 只管"调用了就执行"。
7. **状态记录**：成功后写 `var/last-success.<name>`（时间戳，供以后 `status` 子命令使用），所有关键事件写入 `var/log/backup.log`。

## 实测记录（2026-07-04，针对真实测试 VPS）

- 首次 `backupctl run`：1 个 target、1 个测试目录，`restic backup` → `forget --keep-last 1 --prune` 全部成功
- 二次运行（改动文件后 `--target seatest`）：确认 `keep-last 1` 真的把上一份快照删掉了（`remove 1 snapshots` + `prune` 日志可见），仓库里始终只保留最新一份
- **关键场景：模拟断电/强制中断**——制造一个 80MB 测试文件让备份持续几十秒，`backupctl run` 跑到一半时 `kill -9` 整个进程树（含 `restic backup` 子进程）。之后确认：
  - `var/backup.lock` 因为持有它的进程已死，`flock` 自动释放（不需要任何手动清理）
  - 直接查询远端仓库 `restic list locks`，确认真的留下了一个 stale lock
  - 重新执行 `backupctl run --target seatest`：备份和 `forget --prune` 都顺利完成，证明"无条件 `restic unlock`"确实清理掉了这个残留锁，不需要人工介入
  - 顺带验证了"并发跳过"逻辑：在第一次 run 还没跑完时手动再跑一次 `backupctl run --target seatest`，正确输出"已有 backupctl run 正在执行，本次跳过"并以 exit 0 返回
- 边界情况：`run --target 不存在的名字` 正确报错退出；未知参数 `--bogus` 正确报错退出

## 已知待办

- `--force` 目前是纯占位符，等模块 5（`backup-watcher`）/模块 6（`backup-ticker`）实现后才会有实际调用方传这个参数
- `var/last-success.<name>` 目前只写不读，`backupctl status` 子命令留到后续模块实现（读取这个文件 + `restic snapshots`/`stats`）
