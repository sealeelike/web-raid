#!/usr/bin/env bash
# backup-ticker.sh — 累计开机时长兜底：不看文件有没有变化，只要这个目录"在线"够久
# 没有一次成功备份，就无视静默去抖强制跑一次。由 systemd timer 每 15 分钟触发一次
# （oneshot），只有笔记本开机+登录期间才会被调用到——关机/合盖期间 timer 不运行，
# tick 自然不会累加，这正是"按累计开机时长而非自然日"兜底的关键
#
# 和 backup-watcher.sh 一样按目录独立计数：每个目录自己的 tick 数只在"这个目录"
# 被成功备份时才清零（不管是 watcher 触发的还是这里强制触发的），目录之间互不影响
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

# 累计阈值：一个目录"在线"这么多小时都没有成功备份过，就强制跑一次
THRESHOLD_HOURS="${BACKUP_TICKER_THRESHOLD_HOURS:-6}"
# 必须和 systemd/backup-ticker.timer 里的 OnUnitActiveSec 保持一致，否则算出来的阈值 tick 数不准
TICK_INTERVAL_SECONDS="${BACKUP_TICKER_INTERVAL_SECONDS:-900}"
THRESHOLD_TICKS=$(( THRESHOLD_HOURS * 3600 / TICK_INTERVAL_SECONDS ))
BACKUPCTL="${SCRIPT_DIR}/backupctl"

[[ -s "$PATHS_CONF" ]] || { info "没有配置任何备份源目录，本次 tick 跳过"; exit 0; }

while IFS= read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] || continue

    tick_file="${VAR_DIR}/uptime-ticks.$(path_slug "$dir")"
    ticks=0
    [[ -f "$tick_file" ]] && ticks="$(cat "$tick_file" 2>/dev/null || echo 0)"
    [[ "$ticks" =~ ^[0-9]+$ ]] || ticks=0
    ticks=$((ticks + 1))

    if (( ticks >= THRESHOLD_TICKS )); then
        info "[${dir}] 累计 ${ticks} 个 tick（约 ${THRESHOLD_HOURS} 小时在线）未成功备份，强制触发"
        log_line "ticker[${dir}]: 累计阈值已达 (${ticks} ticks)，触发 backupctl run --force --path ${dir}"
        if "$BACKUPCTL" run --force --path "$dir" >>"$LOG_FILE" 2>&1; then
            echo 0 > "$tick_file"
        else
            # 跟 watcher 一样：不管是锁被占用还是真的失败，都保留 tick 数，下一轮继续尝试触发，
            # 不清零、也不放弃
            echo "$ticks" > "$tick_file"
            warn "[${dir}] 强制触发未完成（锁冲突或备份失败），tick 保留，下次继续尝试"
            log_line "ticker[${dir}]: 强制触发未完成，tick=${ticks} 保留"
        fi
    else
        echo "$ticks" > "$tick_file"
    fi
done < "$PATHS_CONF"
