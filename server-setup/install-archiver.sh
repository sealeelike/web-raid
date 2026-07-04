#!/usr/bin/env bash
#
# install-archiver.sh
# 给已经装好的 restic-rest-server 追加"每日归档 + 按份数淘汰"层。
# 归档目录归 root 所有（mode 700），rest-server 的服务账户（restic-rest-server）
# 对它没有任何读写权限——即使某个客户端的备份凭据被完全攻破，攻击者能碰到的
# 也只有实时仓库，碰不到任何一份历史归档。详见 backup/doc/00-architecture.md。
#
# 用法：在已经跑过 setup-backup-server-hardened.sh 的 VPS 上，以 root 执行本脚本。
# 重新运行可以：修改保留份数等参数（复用现有归档目录，不会丢已有归档）。
#
set -euo pipefail

# ========================= 颜色 / 日志 helper =========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[信息]${NC} $*"; }
ok()    { echo -e "${GREEN}[完成]${NC} $*"; }
warn()  { echo -e "${YELLOW}[注意]${NC} $*"; }
err()   { echo -e "${RED}[错误]${NC} $*" >&2; }
die()   { err "$*"; exit 1; }

trap 'err "第 $LINENO 行执行失败，脚本已中止。可以重新运行本脚本，已完成的步骤会被跳过或安全覆盖。"' ERR

[[ $EUID -eq 0 ]] || die "请以 root 身份运行（sudo bash $0）"

echo "=================================================================="
echo "  备份归档层一键部署（每日归档 + 按份数淘汰）"
echo "=================================================================="

SVC_NAME="restic-rest-server"
DATA_DIR="/opt/${SVC_NAME}/data"
[[ -d "$DATA_DIR" ]] || die "没找到 ${DATA_DIR}，请先跑 setup-backup-server-hardened.sh 装好 rest-server 本体"

ARCHIVER_DIR="/opt/backup-archiver"
CONF_FILE="${ARCHIVER_DIR}/archive-and-prune.conf"
SCRIPT_FILE="${ARCHIVER_DIR}/archive-and-prune.sh"

# ========================= 依赖检查 =========================
info "检查依赖 (rsync/e2fsprogs) ..."
NEED_PKGS=()
command -v rsync  >/dev/null 2>&1 || NEED_PKGS+=(rsync)
command -v chattr >/dev/null 2>&1 || NEED_PKGS+=(e2fsprogs)
if [[ ${#NEED_PKGS[@]} -gt 0 ]]; then
    info "缺少依赖：${NEED_PKGS[*]}，正在通过 apt 安装 ..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NEED_PKGS[@]}"
    ok "依赖安装完成"
else
    ok "依赖已齐全"
fi

# ========================= 已有配置时读出来当默认值 =========================
DEFAULT_ARCHIVE_ROOT="/srv/backup-archive"
DEFAULT_KEEP_COUNT=7
DEFAULT_USE_CHATTR=1
ALREADY_INSTALLED=0
if [[ -f "$CONF_FILE" ]]; then
    ALREADY_INSTALLED=1
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    DEFAULT_ARCHIVE_ROOT="$ARCHIVE_ROOT"
    DEFAULT_KEEP_COUNT="$KEEP_COUNT"
    DEFAULT_USE_CHATTR="$USE_CHATTR"
    warn "检测到归档层已经安装过，当前配置：归档目录=${ARCHIVE_ROOT}，保留份数=${KEEP_COUNT}，chattr immutable=${USE_CHATTR}"
    info "下面的问题直接回车 = 保留原值不变"
fi

# ========================= 交互配置 =========================
read -rp "归档存放目录（直接回车用默认 [${DEFAULT_ARCHIVE_ROOT}]): " ARCHIVE_ROOT
ARCHIVE_ROOT="${ARCHIVE_ROOT:-$DEFAULT_ARCHIVE_ROOT}"

read -rp "每个备份来源保留最新几份归档，按份数淘汰而不是按日期（直接回车用默认 [${DEFAULT_KEEP_COUNT}]): " KEEP_COUNT
KEEP_COUNT="${KEEP_COUNT:-$DEFAULT_KEEP_COUNT}"
[[ "$KEEP_COUNT" =~ ^[0-9]+$ && "$KEEP_COUNT" -ge 1 ]] || die "保留份数必须是 >=1 的整数"

read -rp "归档写完后是否加 chattr +i 只读保护，多一层防篡改（y/n，直接回车用默认 [$([[ $DEFAULT_USE_CHATTR -eq 1 ]] && echo y || echo n)]): " USE_CHATTR_IN
if [[ -z "$USE_CHATTR_IN" ]]; then
    USE_CHATTR="$DEFAULT_USE_CHATTR"
elif [[ "$USE_CHATTR_IN" =~ ^[Yy]$ ]]; then
    USE_CHATTR=1
else
    USE_CHATTR=0
fi

# ========================= 归档目录 =========================
mkdir -p "$ARCHIVE_ROOT"
chown root:root "$ARCHIVE_ROOT"
chmod 700 "$ARCHIVE_ROOT"
ok "归档目录就绪: ${ARCHIVE_ROOT}（root 专属，${SVC_NAME} 服务账户无权限访问）"

# ========================= 写配置 + 脚本本体 =========================
mkdir -p "$ARCHIVER_DIR"
chown root:root "$ARCHIVER_DIR"
chmod 755 "$ARCHIVER_DIR"

cat > "$CONF_FILE" <<EOF
DATA_DIR=${DATA_DIR}
ARCHIVE_ROOT=${ARCHIVE_ROOT}
KEEP_COUNT=${KEEP_COUNT}
USE_CHATTR=${USE_CHATTR}
EOF
chown root:root "$CONF_FILE"
chmod 600 "$CONF_FILE"

cat > "$SCRIPT_FILE" <<'SCRIPT_EOF'
#!/usr/bin/env bash
# archive-and-prune.sh —— 由 install-archiver.sh 生成，配置读自同目录 archive-and-prune.conf
# 每次运行：给 DATA_DIR 下每个客户端仓库目录（--private-repos 按用户名分的那些子目录）
# 用 rsync --link-dest 做一份硬链接归档（没变化的内容零存储成本），然后按"份数"淘汰旧归档——
# 不按日期淘汰，是为了避免"笔记本很久没上线、没产生新归档"时把仅存的历史备份误删掉
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SELF_DIR}/archive-and-prune.conf"

TS="$(date +%Y%m%d-%H%M%S)"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') archive-and-prune: $*"; }

[[ -d "$DATA_DIR" ]] || { log "数据目录不存在: ${DATA_DIR}，跳过本轮"; exit 0; }

shopt -s nullglob
for repo_dir in "${DATA_DIR}"/*/; do
    user="$(basename "$repo_dir")"
    user_archive_dir="${ARCHIVE_ROOT}/${user}"
    mkdir -p "$user_archive_dir"

    last_archive="$(find "$user_archive_dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -n1)"
    link_dest_args=()
    if [[ -n "$last_archive" ]]; then
        link_dest_args=(--link-dest="${user_archive_dir}/${last_archive}/")
    fi

    dest="${user_archive_dir}/${TS}"
    if [[ -e "$dest" ]]; then
        log "[${user}] 目标目录已存在（同一秒内重复运行？）: ${dest}，跳过这次归档"
    else
        mkdir -p "$dest"
        rsync -a "${link_dest_args[@]}" "${repo_dir}" "${dest}/"
        log "[${user}] 归档完成: ${dest}"
        # 注意：chattr +i 只加到"上一份"归档，不加到刚创建的这一份——
        # 免疫属性会阻止对该文件创建新的硬链接（chattr(1)：immutable 的文件"no link can be created"），
        # 如果给刚写完的这份马上加 +i，下一轮 --link-dest 就没法引用它，硬链接去重会悄悄失效退化成整份复制。
        # 让"最新一份"始终保持可链接，上一份在完成它作为 link-dest 源的使命后再加锁，两个目标都不牺牲。
        if [[ "$USE_CHATTR" == "1" ]] && [[ -n "$last_archive" ]] && command -v chattr >/dev/null 2>&1; then
            chattr -R +i "${user_archive_dir}/${last_archive}" 2>/dev/null || log "[${user}] chattr +i 设置失败（文件系统可能不支持），忽略"
        fi
    fi

    # 按份数淘汰，不按日期
    mapfile -t archives < <(find "$user_archive_dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
    count=${#archives[@]}
    if (( count > KEEP_COUNT )); then
        to_remove=$(( count - KEEP_COUNT ))
        for ((i = 0; i < to_remove; i++)); do
            old_dir="${user_archive_dir}/${archives[$i]}"
            if [[ "$USE_CHATTR" == "1" ]] && command -v chattr >/dev/null 2>&1; then
                chattr -R -i "$old_dir" 2>/dev/null || true
            fi
            rm -rf "$old_dir"
            log "[${user}] 淘汰旧归档: ${old_dir}"
        done
    fi
done
log "本轮归档完成"
SCRIPT_EOF
chown root:root "$SCRIPT_FILE"
chmod 750 "$SCRIPT_FILE"
ok "归档脚本已写入: ${SCRIPT_FILE}"

# ========================= systemd 加固服务 + 每日 timer =========================
cat > /etc/systemd/system/backup-archiver.service <<EOF
[Unit]
Description=backup-archiver - 每日归档备份仓库快照（按份数淘汰，与 rest-server 服务账户权限隔离）
After=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_FILE}

# 加固：只读数据源目录，只写归档目录；本身要以 root 运行才能读到
# restic-rest-server 账户 0700 权限下的仓库文件，但下面这些限制仍然收紧了攻击面
ProtectSystem=strict
ReadOnlyPaths=${DATA_DIR}
ReadWritePaths=${ARCHIVE_ROOT}
PrivateTmp=true
NoNewPrivileges=true
EOF

cat > /etc/systemd/system/backup-archiver.timer <<'EOF'
[Unit]
Description=每天固定时间跑一次备份归档 + 按份数淘汰旧归档

[Timer]
OnCalendar=03:30
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now backup-archiver.timer
ok "systemd timer 已启用（每天 03:30 左右触发，允许最多 10 分钟随机延迟错峰）"

# ========================= 立即跑一次，验证链路 =========================
info "立即触发一次归档，验证链路 ..."
if systemctl start backup-archiver.service; then
    ok "首次归档执行成功"
else
    warn "首次归档执行失败，日志如下（不影响下次定时任务自动重试）："
    journalctl -u backup-archiver.service --no-pager -n 30
fi

echo "=================================================================="
ok "归档层部署完成"
echo "  归档目录：${ARCHIVE_ROOT}（root 专属，${SVC_NAME} 服务账户无权限访问）"
echo "  保留份数：${KEEP_COUNT}（按份数淘汰，不按日期，笔记本长期离线也不会误删仅存历史）"
echo "  chattr 只读保护：$([[ $USE_CHATTR -eq 1 ]] && echo 已启用 || echo 未启用)"
echo "  重新运行本脚本可以调整以上参数，不会丢已有归档"
echo "=================================================================="
