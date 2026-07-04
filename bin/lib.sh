#!/usr/bin/env bash
# 公共 helper：颜色输出、路径解析、restic 二进制定位/自动下载
# 被 backupctl / backup-watcher.sh / backup-ticker.sh 共同 source

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[信息]${NC} $*"; }
ok()    { echo -e "${GREEN}[完成]${NC} $*"; }
warn()  { echo -e "${YELLOW}[注意]${NC} $*"; }
err()   { echo -e "${RED}[错误]${NC} $*" >&2; }
die()   { err "$*"; exit 1; }

# BACKUP_HOME: 项目根目录（bin/ 的上一级），不管从哪里调用都能正确解析
BACKUP_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_DIR="${BACKUP_HOME}/config"
TARGETS_DIR="${CONF_DIR}/targets"
PATHS_CONF="${CONF_DIR}/paths.conf"
VAR_DIR="${BACKUP_HOME}/var"
LOG_FILE="${VAR_DIR}/log/backup.log"

mkdir -p "$TARGETS_DIR" "$VAR_DIR/log"

log_line() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# restic 二进制定位：优先系统 PATH，缺失则自动下载单文件版本到 bin/.restic-local
# 这样即使没有 root/apt 权限也能用（登录用户没有 sudo 密码的场景）
# ---------------------------------------------------------------------------
resolve_restic() {
    if command -v restic >/dev/null 2>&1; then
        command -v restic
        return 0
    fi
    local local_bin="${BACKUP_HOME}/bin/.restic-local"
    if [[ -x "$local_bin" ]]; then
        echo "$local_bin"
        return 0
    fi
    info "未检测到系统 restic，正在下载独立二进制到 ${local_bin} ..." >&2
    case "$(uname -m)" in
        x86_64)  local arch="amd64" ;;
        aarch64) local arch="arm64" ;;
        armv7l|armv6l) local arch="arm" ;;
        i686|i386) local arch="386" ;;
        *) die "不支持的架构: $(uname -m)，请手动安装 restic" ;;
    esac
    local api_json ver asset dl_url sums_url tmpd
    api_json="$(curl -fsSL https://api.github.com/repos/restic/restic/releases/latest)" \
        || die "查询 restic 最新版本失败（检查网络/代理）"
    ver="$(echo "$api_json" | grep -m1 '"tag_name"' | sed -E 's/.*"v([0-9.]+)".*/\1/')"
    [[ -n "$ver" ]] || die "无法解析 restic 版本号"
    asset="restic_${ver}_linux_${arch}.bz2"
    dl_url="https://github.com/restic/restic/releases/download/v${ver}/${asset}"
    sums_url="https://github.com/restic/restic/releases/download/v${ver}/SHA256SUMS"

    tmpd="$(mktemp -d)"
    curl -fSL -o "${tmpd}/${asset}" "$dl_url" || die "下载 restic 失败"
    curl -fsSL -o "${tmpd}/SHA256SUMS" "$sums_url" || die "下载校验和文件失败"
    local expect actual
    expect="$(grep -F "$asset" "${tmpd}/SHA256SUMS" | awk '{print $1}')"
    actual="$(sha256sum "${tmpd}/${asset}" | awk '{print $1}')"
    [[ "$expect" == "$actual" ]] || die "restic 二进制校验和不匹配！期望 $expect 实际 $actual"
    bunzip2 -c "${tmpd}/${asset}" > "$local_bin"
    chmod +x "$local_bin"
    rm -rf "$tmpd"
    ok "restic v${ver} 已下载并校验通过: ${local_bin}" >&2
    echo "$local_bin"
}

# 读取某个 target 的配置到当前 shell（source 后可用 TARGET_* 变量）
load_target() {
    local name="$1"
    local envfile="${TARGETS_DIR}/${name}.env"
    [[ -f "$envfile" ]] || die "target 不存在: ${name}"
    # shellcheck disable=SC1090
    source "$envfile"
}

# 拼出某个 target 的 restic 环境变量并 export（调用方需已 load_target）
export_restic_env() {
    export RESTIC_REPOSITORY="rest:https://${TARGET_USER}:${TARGET_PASS}@${TARGET_HOST}:${TARGET_PORT}/${TARGET_USER}/"
    export RESTIC_PASSWORD_FILE="${TARGETS_DIR}/${TARGET_NAME}.pass"
    export RESTIC_CACERT="${TARGETS_DIR}/${TARGET_NAME}.crt"
}

list_targets() {
    find "$TARGETS_DIR" -maxdepth 1 -name '*.env' -printf '%f\n' 2>/dev/null | sed 's/\.env$//' | sort
}

# 目录路径 -> 文件名安全的 slug，backup-ticker.sh 和 backupctl 共用，
# 保证两边写/清零的是同一个 var/uptime-ticks.<slug> 文件
path_slug() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g'
}
