# 模块 10：端到端总校验

不是新代码，是对照原始设计文档里的"校验计划"完整走一遍，用一套全新的临时实例（VPS 端口 9193）把前面 9 个模块的能力串起来跑一次真实场景，逐条验证。测试完毕后所有临时基础设施（VPS 侧 + 本机侧）均已完全清理，不留任何残留。

## 校验计划逐条结果

### 1. VPS 一键脚本人工检查
`setup-backup-server-hardened.sh` 装出 `restic-rest-server`（端口 9193，自签证书，`--private-repos`），`install-archiver.sh` 装出 `backup-archiver.service`/`.timer`（`KEEP_COUNT=4`），两者 `systemctl status` 均正常。

### 2. `target add` → `restic init`
本机 `backupctl target add` 粘贴凭据 blob，自动解析 + `restic init` 成功，目标 `e2e-vps`，仓库 ID `a143cb2d7b`。

### 3. `path add` + watcher 事件触发
`path add /tmp/e2e-backup-dir` 后写文件，`backup-watcher.service`（临时把 `BACKUP_WATCHER_DEBOUNCE_SECONDS` 调到 15s 加速测试）在静默期后自动触发，`restic backup` 产生新快照，`success-log`/`last-success.<target>`/tick 文件（清零）均正确更新。

**顺带确认一个真实时序细节**：`backup-watcher.sh` 的静默期判断只在 `inotifywait --timeout $CHECK_INTERVAL`（固定 30s）返回时才重新评估一次，所以即使把 `DEBOUNCE_SECONDS` 调到比 30 还小，实际触发延迟的下限仍然是 `CHECK_INTERVAL`（30s），不会比这更快——这是设计上的合理取舍（避免忙等），记录在这里备查。

### 4. 累计开机 tick 兜底
临时用 `BACKUP_TICKER_THRESHOLD_HOURS=1` + `BACKUP_TICKER_INTERVAL_SECONDS=1800`（`THRESHOLD_TICKS=2`）手动连续跑两次 `bin/backup-ticker.sh`，在**完全不改动**目标目录任何文件的情况下：第一次只累加到 1（不触发），第二次达到阈值 2，无视"没有文件变化"强制触发了一次真实备份，成功后 tick 清零。符合设计意图。

### 5. kill -9 中断恢复模拟
写入一个 80MiB 大文件制造足够长的上传窗口，`backupctl run --force` 跑到一半时 `kill -9` 掉 `restic backup` 子进程：
- `run_one_target()` 正确捕获失败，`err`/`log_line`/`notify critical` 全部触发，没有产生任何快照
- 巧的是这次写入本身也触发了 watcher（15s debounce 仍生效），watcher 独立发起的第二次 `backupctl run` 在几乎同一时间抢到了本地 `flock`——手动想再跑一次时被正确拒绝（`EX_LOCK_BUSY=75`，"已有 backupctl run 正在执行，本次跳过"），验证了 `flock` 并发保护在真实并发场景下工作正常
- watcher 那次运行完整跑完，`restic unlock` 无条件清理（脚本第 203 行）没有让任何残留的远端 stale lock 挡住这次重试，最终成功产生完整快照并 `forget --prune`
- 之后手动再跑一次确认仓库完全干净、无锁残留

### 6. nice/ionice 限速验证
另起一次真实备份（60MiB 新文件），用 `ps -o ni` 和 `ionice -p` 直接查看运行中的 `restic backup` 子进程：`nice=19`（最低 CPU 优先级），`ionice class=idle`（最低 I/O 优先级），均生效，备份仍正常完成。

### 7. 归档正确性验证（重点，KEEP_COUNT=4，跨 5 轮）
手动连续触发 5 轮 `backup-archiver.service`（模拟 5 天），每轮记录归档目录 + `lsattr`：

| 轮次 | 目录列表（新→旧） | 每个目录的锁状态 |
|---|---|---|
| 1 | 215745 | 215745 未锁（唯一，最新） |
| 2 | 215747, 215745 | 215747 未锁，215745 已锁 |
| 3 | 215748, 215747, 215745 | 215748 未锁，其余已锁 |
| 4 | 215750, 215748, 215747, 215745 | 215750 未锁，其余已锁（共 4 份，未超限） |
| 5 | 215751, 215750, 215748, 215747 | 215751 未锁，其余已锁；**215745 被淘汰** |

确认：
- 每一轮永远只有"最新一份"不加锁，其余全部 `chattr +i`，锁跟随"当前最新"滚动前移
- 第 5 轮超过 `KEEP_COUNT=4` 后正确淘汰最老的一份，且淘汰前脚本自己 `chattr -i` 解锁再删除（没有报错），证明淘汰逻辑和加锁逻辑顺序正确
- **额外做了一次直接攻击性验证**：对仍在保留期内、已加锁的归档目录直接 `rm -rf`，被内核以 `Operation not permitted` 全部拒绝——证明 `chattr +i` 确实提供了真实的文件系统级防误删/防篡改保护，不只是逻辑上"应该"生效
- `du -sh` 确认硬链接去重生效（多份归档共享未变化的 data blob，不是 4 份独立全量拷贝）

### 8. 通知策略回归
- 失败即时弹窗：第 5 步 kill -9 触发的失败已经过 `notify critical` 真实弹出（前序模块 7 已验证过 `notify-send` 在图形会话下工作正常，本次只需确认失败分支代码路径本身被正确调用到，日志确认无误）
- 成功每日汇总：手动 `systemctl --user start backup-summary.service` 触发，正确读出本轮测试积累的 12 条 `success-log` 记录，汇总成一条通知并清空文件，`backup.log` 记录了汇总内容和起止时间戳

## 清理

VPS 侧：停用/删除 `restic-rest-server.service`、`backup-archiver.service`/`.timer` 三个 unit，解锁并删除 `/srv/backup-archive-e2e`、`/opt/backup-archiver`、`/opt/restic-rest-server`，删除 `restic-rest-server` 系统账户，`daemon-reload`，确认 9193 端口已释放。

本机侧：`backupctl service uninstall` 卸载三个 `--user` unit，删除 watcher 静默期测试用的 drop-in override，`backupctl target remove e2e-vps`、`path remove /tmp/e2e-backup-dir`，删除临时测试目录和残留的 `var/last-success.e2e-vps`/`var/uptime-ticks.*` 状态文件。

## 一个意外发现（非本模块范围，记录备查）

清理时用 `ss -tlnp` 核对端口占用，发现测试 VPS 上 `:9199` 端口实际监听的进程是 `rest-server`（本项目自己的 restic REST 后端二进制），**不是**此前一直以为的 `sysmetrics-agent`——`/opt/sysmetrics-agent` 目录确实存在，但它和监听 9199 的进程并不是同一个东西。9199 这个端口在项目早期模块（3/4 的 `mytest-vps`/`seatest` 等临时测试）里出现过，推测是当时某次测试的 `rest-server` 实例只删了 systemd unit、没有正确杀掉进程本身，变成孤儿进程一直存活至今。

本次没有触碰 9199（延续既定的"不碰这个端口"约定），只是如实记录这个发现——它很可能是本项目自己遗留的测试孤儿进程而非无关服务，是否清理由用户决定。
