# 模块 3：backupctl 骨架（target/path 管理）

代码：`bin/lib.sh`（公共 helper）+ `bin/backupctl`（主 CLI）。

## 做什么

笔记本端的主入口。这个模块只做"配置管理"——把 VPS 一键脚本吐出的凭据变成一个可用的 restic 仓库，以及维护要备份哪些目录；不涉及"什么时候跑"（模块 4/5/6）。

## 关键实现点

1. **`bin/lib.sh` 公共 helper**：颜色输出（`info/ok/warn/err/die`）、`BACKUP_HOME` 基于 `BASH_SOURCE` 解析（不管从哪个目录调用 `backupctl` 都能正确定位项目根目录）、`load_target`/`export_restic_env`（把某个 target 的 `.env` 转成 `RESTIC_REPOSITORY`/`RESTIC_PASSWORD_FILE`/`RESTIC_CACERT` 环境变量）、`list_targets`。
2. **`resolve_restic()` 免 root 兜底**：优先用系统 PATH 里的 `restic`；找不到时从 GitHub Release 下载独立二进制（校验和验证，同模块 2 的模式）到 `bin/.restic-local`（已加入 `.gitignore`）。这是因为测试环境发现没有免密 sudo，`apt install restic` 会卡在密码交互——这个兜底让 `backupctl` 在任何权限受限的环境下都能工作，不依赖包管理器。
3. **`target add`**：交互粘贴 VPS 脚本打印的 base64 凭据 → `python3 -c 'import json...'` 解析出 host/port/user/pass/cert → 起名字（默认 `vps-<host最后一段>`）→ cert 写入 `.crt` → 仓库加密密码（回车=`openssl rand -base64 32` 自动生成）→ 写 `.env`（含 `KEEP_LAST=1`、`LIMIT_UPLOAD_KBPS=` 两个模块 4 会用到的字段）→ `resolve_restic()` → `restic init`。**`restic init` 失败会回滚**（删掉刚写的 `.env`/`.crt`/`.pass`），不留半成品配置。
4. **`target list`**：表格展示已配置 target 的名称/地址/用户/启用状态。
5. **`target remove`**：`y/N` 二次确认，且明确提示"只删本机配置，不删远端 VPS 上已有的备份数据"——避免用户误以为这是删除远端仓库的操作。
6. **`path add/remove/list`**：`path add` 默认当前目录，`realpath -e` 解析绝对路径并确认目录存在，`grep -qxF` 去重（重复添加不报错,只提示"已在列表中"）。`path remove` 用 `realpath -m`（不要求目录还存在，允许移除一个已经被删掉的目录条目）。
7. **敏感文件权限**：`.pass`/`.env` 在 `umask 077` 下创建，`chmod 600`；`.crt` 是公开的 CA 证书内容，不需要限权。
8. **`.gitignore` 补漏**：审查时发现 `config/targets/*.pass` 之前漏在 `.gitignore` 之外——如果不补上，`target add` 生成的仓库密码文件会被 `git add` 追踪到，是一个真实的安全漏洞（虽然本地仓库不推送到任何远端，但原则上密码类文件不该有被提交的可能）。已修复。

## 踩坑与修复

**`path remove` 删除最后一条记录时静默失败**：`cmd_path_remove()` 原实现是 `grep -vxF "$dir" "$PATHS_CONF" > "${PATHS_CONF}.tmp" && mv "${PATHS_CONF}.tmp" "$PATHS_CONF"`。当 `paths.conf` 里只有这一条要删的记录时，`grep -v` 过滤后没有任何一行输出，此时 `grep` 退出码是 1（无匹配输出）；`set -euo pipefail` 环境下，`A && B` 里 A 失败会让整条语句的退出码非零，短路掉 `mv`——`.tmp` 文件已经正确写成了空文件，但从未替换回 `$PATHS_CONF`，导致"移除"提示成功但实际记录原封不动地留在文件里。**修复**：`grep -vxF ... || true` 后单独执行 `mv`，不再依赖 `&&` 链式短路。用"只有一条记录时删除"这个场景复测确认修复有效。

**VPS 脚本"仅新增凭据"分支的端口占用检查顺序错误**（连带在这个模块的联调测试中发现，已在 `backup-server-setup` 仓库单独修复）：原脚本先问端口号并检查是否被占用，再判断是否是"复用已有服务、只加一个新凭据"的场景——但复用场景下这个端口本来就该是被（自己）占用的状态，检查逻辑把这个正常情况当成了错误直接 `die`，导致这条本该最常用的"幂等新增凭据"路径实际上完全跑不通。**修复**：把"是否已安装"的判断挪到端口询问之前；已安装且选择"仅新增凭据"时，直接从现有 systemd unit 文件的 `--listen :PORT` 参数里读出端口，跳过占用检查；只有"全新安装"或"完全重新安装"才需要重新问端口并检查占用。

## 实测记录（2026-07-04，针对真实测试 VPS <vps-host>）

- 先在 VPS 上用修复后的脚本走"仅新增凭据"分支，成功生成新用户 `client-2990d6`，自检通过（HTTP 405，鉴权链路正常）
- `backupctl target add` 粘贴该凭据 → 解析成功 → 自动生成仓库密码 → `restic init` 成功，远端可见 `created restic repository ... at rest:https://client-2990d6:***@<vps-host>:9199/client-2990d6/`
- `restic backup /tmp/mytest-vps-src`（临时测试目录）成功，`restic snapshots` 显示正确快照
- `target list` 正确显示新 target；`target remove mytest-vps` 确认删除后 `target list` 恢复"还没有配置任何备份目标"
- `path add/remove/list` 全流程验证，包括修复后的"删除最后一条记录"场景

## 已知待办

- `target add`/`path add` 目前都是一次性交互命令，尚未接入实际的备份执行逻辑（`backupctl run`，模块 4）
- `KEEP_LAST`/`LIMIT_UPLOAD_KBPS` 字段已经写入 `.env` 模板，但目前没有任何代码读取它们——留给模块 4 使用
