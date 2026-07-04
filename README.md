# web-raid

`本机`（不常驻在线的笔记本）到自建 VPS 的增量、加密、原子性备份系统。私有分布式存储矩阵构想的第一步，设计上可平滑扩展到多个 VPS 目标。

单一仓库，两个部分，因为实现上并不复杂——真正的复杂逻辑全部封装在 shell 脚本里，脚本在各自的机器上运行时才生成实际的目录结构和状态：

- [`server-setup/`](server-setup/) — VPS 端一键部署脚本（root 执行一次）
- [`client/`](client/) — 笔记本端 `backupctl` 及其后台服务

## 快速开始

**VPS 端**（root 执行）：

```bash
curl -fsSL https://raw.githubusercontent.com/sealeelike/web-raid/main/server-setup/setup-backup-server-hardened.sh | bash
```

脚本跑完打印一行凭据 blob，复制它。

**笔记本端**：

```bash
git clone https://github.com/sealeelike/web-raid.git
cd web-raid/client
bin/backupctl target add     # 粘贴上面的凭据 blob
bin/backupctl path add ~/Documents
bin/backupctl service install
```

详细用法、子命令说明见 [`client/README.md`](client/README.md)；VPS 端脚本细节、归档层设计见 [`server-setup/README.md`](server-setup/README.md)。

## 项目亮点

- **事件驱动 + 累计开机兜底触发**：不依赖自然日定时（笔记本本来就不 24 小时在线）。文件变化静默去抖后触发；同时用"累计开机时长"兜底，关机期间不会被误算进"该备份了"
- **低优先级限速执行**：`nice`/`ionice` 跑，不需要严格等待系统空闲，贴近 Backblaze / Time Machine 的真实做法
- **归档层按份数淘汰，不按日期**：VPS 侧每日归档，即使笔记本长期离线/损坏，现有历史备份也不会被"日期到了"逻辑误删
- **归档层与实时仓库权限隔离**：笔记本凭据被攻破，攻击者能触达的只有实时仓库，触达不到任何一份历史归档
- **原子性**：基于 restic 快照，中途被打断不会产生损坏状态，重跑自动去重
- **去中心化多 target 可扩展**：新增第二台 VPS 不需要改动核心逻辑

## 开发状态

见 [`client/LOG.md`](client/LOG.md)（开发进度）与 [`client/doc/`](client/doc/)（各模块设计详解，含真实测试 VPS 上的端到端验证记录）。
