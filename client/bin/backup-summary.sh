#!/usr/bin/env bash
# backup-summary.sh — 每日一次的成功备份汇总通知（oneshot，由 systemd timer 每天触发一次）
# 失败已经在 backupctl run_one_target() 里即时弹窗了，这里只处理"多次成功不用逐次打扰"：
# 平时每次成功只静默记一行到 var/success-log，这里读出来汇总成一条通知，然后清空这份记录——
# 不需要额外记"上次汇总时间"，因为清空之后文件里剩下的内容天然就是"距上次汇总以来"的新记录
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ ! -s "$SUCCESS_LOG" ]]; then
    info "距上次汇总以来没有新的成功备份记录，本次跳过通知"
    exit 0
fi

count="$(wc -l < "$SUCCESS_LOG" | tr -d ' ')"
first_ts="$(head -n1 "$SUCCESS_LOG" | cut -d' ' -f1,2)"
last_ts="$(tail -n1 "$SUCCESS_LOG" | cut -d' ' -f1,2)"

notify normal "备份汇总" "${first_ts} ~ ${last_ts} 期间成功备份 ${count} 次"
log_line "summary: ${first_ts} ~ ${last_ts} 期间成功备份 ${count} 次"

> "$SUCCESS_LOG"
