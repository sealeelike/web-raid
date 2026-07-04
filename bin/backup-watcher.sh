#!/usr/bin/env bash
# backup-watcher.sh — 每个备份源目录独立监控 + 独立静默去抖 + 独立触发
# 常驻主进程：为 config/paths.conf 里的每一个目录各起一个独立的后台监控循环，
# 各自维护自己的"最后变化时间"。谁自己静默满窗口，就只触发这一个目录的备份，
# 完全不受其他目录是否繁忙影响——目录 A 和 B 互不相关，A 不该因为 B 还在写就被拖着一起等，
# B 也不该因为 A 想触发就被迫在还没写完的状态下被扫进去
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

# 静默期：一个目录距最后一次文件变化超过这么多秒，才真正触发它自己的备份
DEBOUNCE_SECONDS="${BACKUP_WATCHER_DEBOUNCE_SECONDS:-600}"
# 单个目录 inotifywait 单次调用的超时（同时也是"没有变化时多久检查一次去抖条件"的节奏）
CHECK_INTERVAL=30
# 主循环多久重新读一次 paths.conf，感知新增/删除的目录
RESCAN_INTERVAL=30
BACKUPCTL="${SCRIPT_DIR}/backupctl"

command -v inotifywait >/dev/null 2>&1 || die "未检测到 inotifywait，请先安装: sudo apt install inotify-tools"

declare -A WORKER_PID   # 目录路径 -> 对应后台监控循环的 PID

cleanup() {
    local dir
    for dir in "${!WORKER_PID[@]}"; do
        kill "${WORKER_PID[$dir]}" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT TERM INT

# 单个目录的独立监控循环：只对这一个目录计时、只触发这一个目录的备份，
# 跟其他目录的忙闲状态、触发时机完全无关
watch_one_dir() {
    local dir="$1"
    local dirty=0 last_event_epoch=0

    while true; do
        # 单次调用：要么等到这个目录自己发生事件立刻返回(exit 0)，
        # 要么等满 CHECK_INTERVAL 秒后超时返回(exit 2)
        if inotifywait -r -e modify,create,delete,close_write,moved_to,moved_from,attrib \
            --timeout "$CHECK_INTERVAL" -qq "$dir" 2>>"$LOG_FILE"; then
            dirty=1
            last_event_epoch=$(date +%s)
        else
            local rc=$?
            if [[ $rc -ne 2 ]]; then
                warn "[${dir}] inotifywait 异常退出 (code=${rc})，5 秒后重试"
                log_line "watcher[${dir}]: inotifywait 异常退出 code=${rc}"
                sleep 5
            fi
        fi

        if [[ $dirty -eq 1 ]]; then
            local now
            now=$(date +%s)
            if (( now - last_event_epoch >= DEBOUNCE_SECONDS )); then
                info "[${dir}] 静默期已过 (${DEBOUNCE_SECONDS}s)，触发这个目录的备份"
                log_line "watcher[${dir}]: 静默期已过，触发 backupctl run --force --path ${dir}"
                if "$BACKUPCTL" run --force --path "$dir" >>"$LOG_FILE" 2>&1; then
                    dirty=0
                else
                    # 不清空 dirty：不管是锁被占用(exit 75，比如另一个目录/ticker 正在跑)
                    # 还是真的备份失败，都保留"待触发"状态，下一轮 CHECK_INTERVAL 后自动重试，
                    # 直到成功或者这个目录又有新变化重新计时
                    warn "[${dir}] 本次触发未完成（锁冲突或备份失败），${CHECK_INTERVAL}s 后重试"
                    log_line "watcher[${dir}]: 触发未完成，稍后重试"
                fi
            fi
        fi
    done
}

info "backup-watcher 启动，每个目录独立静默期 ${DEBOUNCE_SECONDS} 秒"
log_line "watcher: 启动 (debounce=${DEBOUNCE_SECONDS}s, 每目录独立触发)"

while true; do
    declare -A current_dirs=()
    if [[ -f "$PATHS_CONF" ]]; then
        while IFS= read -r d; do
            [[ -n "$d" && -d "$d" ]] && current_dirs["$d"]=1
        done < "$PATHS_CONF"
    fi

    # 新增目录：起一个新的独立监控循环
    for d in "${!current_dirs[@]}"; do
        if [[ -z "${WORKER_PID[$d]:-}" ]]; then
            watch_one_dir "$d" &
            WORKER_PID["$d"]=$!
            info "开始独立监控目录: ${d} (pid ${WORKER_PID[$d]})"
            log_line "watcher: 新增监控目录 ${d} (pid ${WORKER_PID[$d]})"
        fi
    done

    # 已从 paths.conf 移除的目录：停掉对应的监控循环
    for d in "${!WORKER_PID[@]}"; do
        if [[ -z "${current_dirs[$d]:-}" ]]; then
            kill "${WORKER_PID[$d]}" 2>/dev/null || true
            unset "WORKER_PID[$d]"
            info "停止监控已移除的目录: ${d}"
            log_line "watcher: 停止监控已移除目录 ${d}"
        fi
    done

    sleep "$RESCAN_INTERVAL"
done
