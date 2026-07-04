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

### 5. 查看状态

```bash
bin/backupctl status
```

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
