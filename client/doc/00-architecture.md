# 架构总览

## 组件

| 组件 | 位置 | 作用 |
|---|---|---|
| `rest-server` | VPS | restic 官方 REST 后端，笔记本通过 HTTPS 直接读写加密仓库 |
| `backupctl` | 笔记本 `bin/` | 主 CLI：管理 target/path、执行备份 |
| `backup-watcher` | 笔记本 systemd user service | inotify 监控 + 静默去抖，触发事件驱动备份 |
| `backup-ticker` | 笔记本 systemd user timer | 累计开机时长兜底，触发保底备份 |
| `archive-and-prune.sh` | VPS systemd timer | 每日归档 + 实时仓库瘦身，与笔记本是否在线无关 |

## 数据流

```
笔记本 paths.conf 里的目录
        │  inotify 事件 / 累计开机兜底
        ▼
   backupctl run
        │  nice/ionice 限速执行
        ▼
   restic backup  ──HTTPS(TLS)──▶  VPS rest-server（实时仓库，每 target 独立）
                                          │  每日 systemd timer
                                          ▼
                                   rsync --link-dest 归档
                                   （独立专用用户持有，笔记本凭据不可达）
                                          │
                                          ▼
                                   实时仓库 forget --keep-last 1 --prune
```

## 关键设计取舍

详见根目录 README 的"项目亮点"一节和各模块 `doc/0N-*.md`。核心思路：

1. **不用 SSH 隧道**：rest-server 直接监听端口 + TLS，避免维护 sshd/chroot
2. **不用服务级 append-only**：与"保留最近 N 份快照"天然冲突；改用"归档层完全隔离"来防笔记本被黑后删光远端历史
3. **触发不基于自然日**：笔记本不常驻在线，改用"事件+去抖 / 累计开机兜底"
4. **归档淘汰按份数，不按日期**：避免笔记本长期离线时被误判"该删旧备份了"
