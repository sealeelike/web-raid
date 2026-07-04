# 开发日志

## 2026-07-04 — Module 1: 项目骨架

- 创建目录结构：`bin/ config/targets/ var/log/ systemd/ doc/`
- `git init`（本地仓库，非全局 git 身份）
- `.gitignore`：排除运行时状态文件（日志、锁、tick 计数）和敏感配置（`config/targets/*.env`、证书、`paths.conf`），这些都是本机私有数据，不应该进版本库
- 编写 `README.md`：快速部署步骤 + 项目亮点说明
- 建立本文件 `LOG.md` 与 `doc/` 目录，后续每完成一个模块在此追加一节

设计全文见完整设计讨论（VPS 端 rest-server、事件驱动+累计开机兜底触发、多 target 结构、按份数淘汰的归档策略等），落地文档会在对应模块完成时写入 `doc/`。

### 测试 VPS 信息

- Debian 12，已用专用 SSH key 打通
- 已占用端口：nginx(80,8447)、xray(443, 本地62789/11111)、x-ui(57680) —— rest-server 计划用 `9199`，Module 2 里会先探测确认未占用
- 缺 `git`、`apache2-utils`(htpasswd)，Module 2 脚本里会自动安装

---

## 2026-07-04 — Module 2: VPS 端一键脚本

- 编写 `backup-server-setup/setup-backup-server-hardened.sh`（独立目录，风格参照 `install-agent-hardened.sh`）
- 在测试 VPS 上完整跑通两次（含一次故意重装验证幂等逻辑），最终做了端到端验证：`restic init` → `restic backup` → `restic snapshots` 全部针对真实部署的 rest-server 跑通
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
- 环境准备：本机缺 `inotify-tools` 且无免密 sudo，用已配置好的图形化 askpass（`sudo -A apt-get install -y inotify-tools`）解决，不需要用户在对话里输入密码
- 端到端验证：新建测试 target + 测试目录，短静默期（15s）模拟连续两次写入，确认去抖真正等满静默期才触发、`backupctl run --force` 被自动调用且成功产生新快照；`service install/status/uninstall` 全流程针对真实 systemd --user 验证通过
- 详见 `doc/05-backup-watcher.md`

## 2026-07-04 — Module 5 修正：全局静默计时器 → 每目录独立触发

- **背景**：模块 5 最初实现是全部监控目录共享一个静默计时器，任何一个目录有变化都会刷新同一个计时器，等大家一起静默才对全部目录跑一次备份。用户实测复盘时指出问题："A 目录可能和 B 目录完全没关系，凭什么 A 要等 B？如果 B 难得空闲，A 也无法备份。" 并明确不同意这个设计
- 我最初提出的"只改触发条件为任一目录静默即触发，但备份动作仍是全量扫描"的折中方案被用户否决——因为这会导致 A 触发时把还在写入中的 B 一起扫进去，等于把"A 被拖累"的问题换成了"B 被抢跑"，没有解决根本问题
- **确认关键前提**：`restic forget --help` 证实默认按 `host,paths` 分组做保留策略清理，也就是说只要每个目录用独立的 `restic backup <目录>` 调用，各自天然形成独立的保留分组，不需要"全量快照才能保证一致性"这个假设
- **修正实现**：`bin/backupctl` 的 `run_one_target()`/`cmd_run()` 新增 `--path <目录>` 精确单目录备份；新增 `EX_LOCK_BUSY=75` 专用退出码区分"锁冲突跳过"和"真正失败"；`bin/backup-watcher.sh` 从单一全局 `inotifywait` 循环重写为每个目录一个独立的 `watch_one_dir()` 后台循环（各自独立的 `dirty`/`last_event_epoch` 状态），主循环每 30 秒对比 `paths.conf` 动态增删对应的监控循环
- 端到端验证（真实测试 VPS + 两个独立测试目录）：只写目录 A 一次后让其静默，同时持续每 3 秒写目录 B 模拟"B 一直很忙"——确认 A 在自己的静默期满后独立触发、快照只含 A 的文件，全程没有等待 B；B 在持续写入期间没有被任何触发扫入；B 自己静默后独立触发、快照只含 B 的文件；`restic snapshots` 确认两个目录的 `host,paths` 保留分组互不干扰、各自正确保留最新一份
- 详见更新后的 `doc/05-backup-watcher.md`

## 2026-07-04 — Module 5 后续：service stop/start + 修复 watcher 退出码

- 用户提问 4-5 模块常驻监控的系统开销，实测 `ps aux`：1 个监控目录时总计约 8MB RSS（主循环 + 单目录 worker + `inotifywait` 三个进程）、空闲时 0% CPU，确认设计的低开销声明不只是理论上成立
- 新增 `backupctl service stop/start`：只暂停/恢复已安装的 unit，不删配置、不取消开机自启，方便用户不需要记 `systemctl` 语法就能临时暂停监控
- 实测 `service stop` 时发现 bug：`backup-watcher.sh` 的 `trap cleanup EXIT TERM INT` 收到 `SIGTERM` 后没有显式 `exit 0`，导致进程以信号退出码 143 结束；`systemd` 在 unit 没声明 `SuccessExitStatus` 的情况下把这次正常停止误判成"失败"，`systemctl --user is-active` 停止后显示 `failed` 而不是 `inactive`（虽然没有触发意外的 `Restart=on-failure` 循环，因为 systemd 对用户主动发起的 stop 本来就会抑制自动重启，但状态显示具有误导性）。修复：拆分 trap，`TERM`/`INT` 单独处理为 `cleanup; exit 0`，重新验证 install→stop→start→uninstall 全流程，`is-active` 正确显示 `inactive`
- 重写 `README.md` 操作说明：去掉不存在的 `backupctl status` 引用，补全 `target`/`path`/`run`/`service` 全部真实子命令，加了一段"路线图"说明当前是 CLI 阶段、后续会做 TUI/GUI

## 2026-07-04 — Module 6: 累计开机兜底 backup-ticker

- 新增 `bin/backup-ticker.sh`（systemd timer 驱动的 oneshot 脚本，每 15 分钟被唤醒一次）+ `systemd/backup-ticker.service`/`.timer`
- 沿用模块 5 的独立性原则：每个目录一个独立的 `var/uptime-ticks.<slug>` 计数文件，只在这个目录自己被成功备份后清零（不管触发源是 watcher/ticker/手动 run），避免重新引入跨目录互相牵连的问题——这正是模块 5 完成时特意留下的提醒事项
- `path_slug()` 挪进 `bin/lib.sh` 共享，保证 ticker 写 tick 文件名和 `backupctl` 清零 tick 文件名用的是同一套算法
- `backupctl` 的 `run_one_target()` 成功分支新增清零逻辑；失败/锁冲突不清零、不放弃，保留 tick 数下一轮继续尝试
- 端到端验证（真实测试 VPS，临时用 9198 端口起一个独立测试实例，验证完毕已在 VPS 上完全清理）：低阈值场景确认"未达标不触发/达标触发且产生真实快照/成功后清零"；持锁模拟场景确认"锁冲突时 tick 保留、不清零、不放弃"
- 详见 `doc/06-backup-ticker.md`

## 2026-07-04 — Module 7: 通知策略（失败即时 + 成功每日汇总）

- `bin/lib.sh` 新增 `notify()`（`notify-send` 不存在/失败静默忽略）+ `SUCCESS_LOG` 变量
- `bin/backupctl` 的 `run_one_target()` 接入两处：成功分支静默追加一行到 `success-log`，失败分支立即 `notify critical` 弹窗——放在这个共同收敛点，手动 `run`/watcher/ticker 三条触发路径自动全部覆盖，不需要各自重复实现
- 新增 `bin/backup-summary.sh`（oneshot）+ `systemd/backup-summary.service`/`.timer`（`OnCalendar=09:00`，`Persistent=true`）：读 `success-log` 首尾时间戳和行数汇总成一条通知，随后清空该文件；不需要额外记"上次汇总时间"，因为清空后文件天然只包含"距上次汇总以来"的新记录；日志为空时静默跳过，不发送"0 次"通知
- 端到端验证：假 target 制造真实备份失败，确认失败分支触发（`notify-send` 手动验证在当前图形会话下工作正常）；临时在测试 VPS 起独立 rest-server 实例（端口 9197）跑两次真实成功备份，确认 `success-log` 正确记录，`backup-summary.sh` 正确弹出汇总通知、写日志、清空文件，二次运行正确静默跳过；测试完毕本地配置和 VPS 临时实例均已完全清理
- 详见 `doc/07-notifications.md`

## 2026-07-04 — Module 8: 同一 VPS 多设备/多客户端隔离验证与文档

- 不是新代码，是给已经存在的能力（VPS 一键脚本"仅新增凭据"默认分支 + `backupctl` 多 target 遍历）补一次真实端到端验证：确认"一台 VPS 服务多台设备"这条 M×N 扇形结构路径是可靠的
- 用户提问引出：VPS 侧现状是二进制直接部署（受控安装脚本引导，Docker 化是可选的后续方向）、客户端多 target copy 模式已支持多 VPS、VPS 端 `--private-repos` 已支持多用户——组合起来就是设想中的"M2M 矩阵"，本次只做验证+文档，不新增代码
- 真实测试（临时 rest-server 实例，端口 9196）：`deviceA` 全新安装并端到端跑通 → 用默认"仅新增凭据"分支给同实例加第二个用户 `deviceB`（确认复用端口、复用证书、只追加 `.htpasswd` + `systemctl restart`）→ 验证这次 restart 没有破坏 `deviceA` 已有仓库（重新 `run --force` 正常成功）→ `deviceB` 独立初始化仓库并成功备份（确认懒创建目录：加凭据时不建目录，第一次真正操作才出现）
- **关键验证**：跨认证隔离测试（`curl` 直接打 rest-server HTTP 接口）——`deviceA`/`deviceB` 各自凭据访问自己的路径均 200，访问对方路径均 401，不带凭据也是 401，五组结果全部符合预期
- 明确记录隔离的性质：这是 rest-server **应用层**鉴权+路由保证（认证用户名与 URL 路径用户名段必须匹配），不是操作系统层面的文件权限隔离——VPS 上所有客户端的仓库数据在系统层面仍归属同一个 `restic-rest-server` 账户；也记录了已知代价：不同设备的仓库之间没有跨仓库去重
- 测试完毕本地配置和 VPS 临时实例均已完全清理
- **追加对抗性验证**（用户追问"A 用户有可能渗透进入 B 的空间吗？"）：查证 `rest-server` 历史上有两次真实的 `--private-repos` 目录穿越漏洞（分别修复于 0.10.0 和 0.11.0），先确认一键脚本永远拉 GitHub `releases/latest`（当前 v0.14.0，远晚于两个修复版本），再实际起一个真实数据的测试实例，用 `deviceA` 凭据尝试了未编码穿越、`%2F`/`%252F` 编码穿越、`curl --path-as-is` 触发的重定向后跟随、跨用户 `DELETE`、构造包含 `/` 的畸形用户名等全部历史已知手法访问/破坏 `deviceC` 的真实数据——全部被正确拒绝（401），`deviceC` 数据全程完好。同时明确这只回答了"应用层鉴权能否被绕过"，不能替代"VPS root 被攻破后数据还安不安全"这个更大的问题
- 详见 `doc/08-multi-device-same-vps.md`

## 2026-07-04 — Module 9: VPS 侧每日归档与保留策略清理

- 新增 `backup-server-setup/install-archiver.sh`（独立一键脚本，VPS 上 root 执行，与 `setup-backup-server-hardened.sh` 风格一致）：给已有 `rest-server` 追加"每日归档 + 按份数淘汰"层——`rsync --link-dest` 硬链接归档到独立目录（默认 `/srv/backup-archive`，root 专属 700 权限，`restic-rest-server` 服务账户零权限），按份数（默认 7）淘汰最老归档而非按日期，用户确认先做固定滚动窗口这一种模式（原计划提到的祖父-父亲-儿子式阶梯保留留作以后可选扩展）
- **真实 bug 及修复**：实测中发现"归档一创建就立刻 `chattr +i`"会导致下一轮 `rsync --link-dest` 完全无法硬链接（`chattr(1)`：immutable 文件不能被 `link()`），归档悄悄退化成每天全量复制，破坏了"未变化内容零存储成本"这条核心设计。修复为"只锁上一份，永远留最新一份可写"，重新测试确认硬链接（inode 相同、链接数为 2）和 chattr 保护（`lsattr` 确认较旧归档已锁、最新一份未锁）同时生效
- 端到端验证（真实测试 VPS，临时实例，端口 9194）：真实数据连续 4 轮归档确认硬链接去重生效、按份数正确淘汰（`KEEP_COUNT=2`）；`su` 到 `restic-rest-server` 账户确认对归档目录零权限；把归档整体拉回本机用 `restic snapshots`/`restore` 实际验证可恢复、恢复内容与原始文件逐字节一致；淘汰逻辑代码走查确认没有任何日期/`mtime` 判断，"长期不产生新归档不会误删历史"是结构性保证
- 测试完毕本地配置和 VPS 临时实例（rest-server + archiver 两部分）均已完全清理
- 详见 `doc/09-archive-and-prune.md`

## 2026-07-04 — Module 10: 端到端总校验

- 不是新代码，用一套全新临时实例（VPS 端口 9193）对照原始设计文档"校验计划"的 7 条逐一走一遍：VPS 一键脚本人工检查、`target add`/`restic init`、`path add`+watcher 事件触发、累计开机 tick 兜底（临时调低阈值，验证"零文件改动也能强制触发"）、kill -9 中断恢复模拟、nice/ionice 限速验证（实测 `ni=19`/`ionice class=idle`）、归档正确性（`KEEP_COUNT=4` 连续 5 轮，确认锁跟随最新归档滚动、超限正确淘汰、硬链接去重、且新增了一次直接 `rm -rf` 已锁归档的攻击性验证，被内核 `Operation not permitted` 拒绝）
- 顺带发现并验证了一个真实并发场景：kill -9 打断的备份和 watcher 独立触发的重试几乎同时发生，本地 `flock` 正确让第二个调用拿到 `EX_LOCK_BUSY` 退让，而不是互相破坏；重试那次因为脚本无条件 `restic unlock`，没有被任何残留的远端 stale lock 挡住
- 顺带发现一个时序细节：`backup-watcher.sh` 的静默期判断只在固定 `CHECK_INTERVAL=30s` 的 `inotifywait` 超时点重新评估，所以 `DEBOUNCE_SECONDS` 调得再小，实际触发延迟下限也是 30s
- **意外发现（未处理，留待用户决定）**：测试 VPS 上 `:9199` 端口监听的其实是本项目自己的 `rest-server` 二进制（很可能是模块 3/4 早期测试遗留的孤儿进程），不是此前一直以为的 `sysmetrics-agent`——继续遵守"不碰 9199"的约定，只如实记录
- 测试完毕，VPS 侧（`restic-rest-server`+`backup-archiver` 两个服务、专用账户、数据目录）和本机侧（target/path/三个 systemd --user 服务/临时 drop-in override）全部完全清理
- 详见 `doc/10-e2e-validation.md`

## 项目状态

原始设计的 10 个模块（骨架 → VPS 脚本 → backupctl → run → watcher → ticker → 通知 → 端到端校验，中间穿插模块 8/9 的隔离验证与归档层）已全部完成并逐一通过真实测试 VPS 的端到端验证。下一步是用户计划中"模拟真实用户体验"的独立验收：把仓库推到 `github.com/sealeelike/web-raid` 后，用 README 里的一键 curl 脚本从零跑一遍真实部署流程。
