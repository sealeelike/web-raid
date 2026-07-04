#!/usr/bin/env bash
# backup-watcher.sh — 事件驱动 + 静默去抖触发器
# 常驻进程：监控 config/paths.conf 里的所有目录，检测到文件变化后，
# 等到"连续这么久都没有新变化"（默认 10 分钟）才真正触发一次 backupctl run --force，
# 避免在文件还在写入的过程中就抢跑
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

# 静默期：距最后一次文件变化超过这么多秒，才真正触发备份
DEBOUNCE_SECONDS="${BACKUP_WATCHER_DEBOUNCE_SECONDS:-600}"
# 没有文件变化时，多久重新检查一次去抖条件/重新读取 paths.conf
CHECK_INTERVAL=30
BACKUPCTL="${SCRIPT_DIR}/backupctl"

command -v inotifywait >/dev/null 2>&1 || die "未检测到 inotifywait，请先安装: sudo apt install inotify-tools"

info "backup-watcher 启动，静默期 ${DEBOUNCE_SECONDS} 秒"
log_line "watcher: 启动 (debounce=${DEBOUNCE_SECONDS}s)"

dirty=0
last_event_epoch=0

while true; do
    watch_dirs=()
    if [[ -f "$PATHS_CONF" ]]; then
        while IFS= read -r d; do
            [[ -n "$d" && -d "$d" ]] && watch_dirs+=("$d")
        done < "$PATHS_CONF"
    fi

    if [[ ${#watch_dirs[@]} -eq 0 ]]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # 单次调用：要么等到一个事件立刻返回(exit 0)，要么等满 CHECK_INTERVAL 秒后超时返回(exit 2)。
    # -r 在每次重新启动时都会基于当前目录树重建递归监控，所以新增的子目录/新增的 path 都能在
    # 下一轮自动生效，不需要重启这个常驻进程
    if inotifywait -r -e modify,create,delete,close_write,moved_to,moved_from,attrib \
        --timeout "$CHECK_INTERVAL" -qq "${watch_dirs[@]}" 2>>"$LOG_FILE"; then
        dirty=1
        last_event_epoch=$(date +%s)
    else
        rc=$?
        if [[ $rc -ne 2 ]]; then
            warn "inotifywait 异常退出 (code=${rc})，5 秒后重试"
            log_line "watcher: inotifywait 异常退出 code=${rc}"
            sleep 5
        fi
    fi

    if [[ $dirty -eq 1 ]]; then
        now=$(date +%s)
        if (( now - last_event_epoch >= DEBOUNCE_SECONDS )); then
            info "静默期已过 (${DEBOUNCE_SECONDS}s 无新变化)，触发备份"
            log_line "watcher: 静默期已过，触发 backupctl run --force"
            if "$BACKUPCTL" run --force >>"$LOG_FILE" 2>&1; then
                dirty=0
            else
                # 不清空 dirty：保留"待触发"状态，下一轮 CHECK_INTERVAL 后自动重试，
                # 直到成功或者又有新的文件变化重新计时——应对网络抖动等临时性失败
                warn "本次自动触发的备份失败，${CHECK_INTERVAL}s 后自动重试，详情见 ${LOG_FILE}"
                log_line "watcher: 自动触发的 backupctl run 失败，稍后重试"
            fi
        fi
    fi
done
