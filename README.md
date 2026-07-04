# backup — 本机 单机增量加密备份系统

主力机 `本机`（不常驻在线的笔记本）到自建 VPS 的增量、加密、原子性备份系统。设计上可平滑扩展到多个 VPS 目标（"copy 模式"：同一份数据独立备份到每一个目标）。

## 项目亮点 / 特性

- **事件驱动 + 累计开机兜底触发**：不依赖"自然日定时"（笔记本本来就不 24 小时在线，纯 cron 没有意义）。文件变化后经过静默去抖才触发备份；同时用"累计开机时长"（而非日历天数）兜底，保证长期不触发文件变化时也有备份下限，关机期间不会被误算进"该备份了"的判断
- **低优先级限速执行，不打扰前台**：备份进程用 `nice`/`ionice` 跑并限制上传速率，不需要严格等待系统空闲——这是 Backblaze / Time Machine 的真实做法，比"检测输入空闲"更贴近实际使用体验
- **零手动改配置**：所有配置变更（新增备份目录、新增 VPS 目标）都通过 `backupctl` 交互命令完成，不需要手动编辑任何配置文件
- **归档层按份数淘汰，而非按日期淘汰**：VPS 侧每日归档，保留策略锚定在"实际产生的归档份数"而不是"距今多少天"——这样即使笔记本长期离线/损坏，现有的历史备份也**绝不会**被"日期到了"逻辑误删，只有真正产生新归档时才会淘汰最老的一份
- **归档层与实时仓库权限隔离**：即使笔记本凭据被完全攻破，攻击者能触达的只有实时仓库；每日归档由 VPS 本地另一个专用用户持有，笔记本这端的凭据对归档目录没有任何权限
- **原子性**：基于 restic 的快照机制，备份中途被打断（合盖/断电/断网）不会产生损坏状态，重跑会自动去重、不重复上传
- **去中心化多 target 可扩展**：现在只启用一个 VPS，但配置结构（`config/targets/<name>.env`）从一开始就支持水平扩展到多个独立备份目标，新增目标不需要改动核心逻辑

## 快速部署

### 1. VPS 端（一键脚本）

在 VPS 上以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/<your-gh>/<repo>/main/backup-server-setup/setup-backup-server-hardened.sh | bash
```

脚本跑完会打印一行凭据 blob，复制它。

### 2. 笔记本端

```bash
cd <client 目录>
bin/backupctl target add
# 粘贴上面的凭据 blob，回车确认默认值即可
```

### 3. 添加备份目录

```bash
bin/backupctl path add ~/Documents
```

### 4. 手动触发一次（可选，日常靠自动触发）

```bash
bin/backupctl run --force
```

### 5. 安装后台自动监控（可选，装好之后就不用管了）

```bash
bin/backupctl service install
```

装完之后，目录有变化会在静默期后自动触发备份，不需要再手动跑 `run`。

## 日常操作命令一览

现阶段（开发中）所有操作都是命令行；后续计划做 TUI（终端菜单式界面），更成熟后再考虑 GUI——见文末"路线图"。

### 备份目标（VPS）管理

```bash
bin/backupctl target add              # 粘贴 VPS 一键脚本打印的凭据 blob，交互式添加一个目标
bin/backupctl target list             # 列出已配置的所有目标
bin/backupctl target remove <name>    # 删除本机的目标配置（不影响远端 VPS 上已有的数据）
```

### 备份目录管理

```bash
bin/backupctl path add [目录]         # 添加一个备份源目录（不填参数默认当前目录）
bin/backupctl path remove <目录>      # 从备份源中移除一个目录
bin/backupctl path list               # 列出所有已配置的备份源目录
```

### 手动执行备份

```bash
bin/backupctl run                     # 对所有已启用的目标、所有目录跑一次备份
bin/backupctl run --target <name>     # 只对指定目标跑
bin/backupctl run --path <目录>       # 只备份 paths.conf 里的这一个目录
```
日常不需要手动执行——装了 `service install` 之后会自动触发。这条命令主要用于立即测试或临时补跑一次。

### 后台自动监控（service）

```bash
bin/backupctl service install         # 安装并启用后台监控，开机/登录后自动运行
bin/backupctl service status          # 查看当前运行状态
bin/backupctl service stop            # 暂停后台监控（不删配置、不取消开机自启，随时可以 start 恢复）
bin/backupctl service start           # 恢复被 service stop 暂停的后台监控
bin/backupctl service uninstall       # 彻底停止并卸载（取消开机自启，删除 systemd 配置文件）
```
只是想临时"别再自动备份了"（比如流量紧张的场合），用 `service stop`；确定以后都不需要了才用 `service uninstall`。

## 路线图

- 当前阶段：CLI 命令行操作，功能优先，交互在命令内部已尽量做到"回车用默认值、无需手动改配置文件"
- 后续计划：命令行菜单式 TUI，把上面这些命令收进一个交互式界面，减少记命令的负担
- 更远期：桌面 GUI（视需求而定）

## 目录结构

```
bin/            可执行脚本（backupctl、watcher、ticker）
config/         配置（paths.conf、targets/*.env）—— 均由 backupctl 生成，不手动编辑
var/            运行时状态（日志、锁、上次成功时间等）
systemd/        安装到 ~/.config/systemd/user/ 的 unit 文件
doc/            各模块详细设计文档
```

## 开发状态

见 [LOG.md](LOG.md)（开发进度）与 [doc/](doc/)（模块设计详解）。
