#!/usr/bin/env bash
#
# setup-backup-server-hardened.sh
# 一键在 VPS 上部署 restic rest-server（加固版），供 backupctl 项目对接。
# 用法：curl -fsSL <raw-url> | bash   或者下载后 bash setup-backup-server-hardened.sh
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
echo "  restic rest-server 一键部署（加固版）"
echo "=================================================================="

# ========================= 基础环境检查/安装 =========================
info "检查基础依赖 (curl/tar/openssl/apache2-utils/git) ..."
NEED_PKGS=()
command -v curl    >/dev/null 2>&1 || NEED_PKGS+=(curl)
command -v tar     >/dev/null 2>&1 || NEED_PKGS+=(tar)
command -v openssl >/dev/null 2>&1 || NEED_PKGS+=(openssl)
command -v htpasswd >/dev/null 2>&1 || NEED_PKGS+=(apache2-utils)
command -v git     >/dev/null 2>&1 || NEED_PKGS+=(git)

if [[ ${#NEED_PKGS[@]} -gt 0 ]]; then
    info "缺少依赖：${NEED_PKGS[*]}，正在通过 apt 安装 ..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NEED_PKGS[@]}"
    ok "依赖安装完成"
else
    ok "依赖已齐全"
fi

# ========================= 架构探测 =========================
case "$(uname -m)" in
    x86_64)  RS_ARCH="amd64" ;;
    aarch64) RS_ARCH="arm64" ;;
    armv7l)  RS_ARCH="armv7" ;;
    armv6l)  RS_ARCH="armv6" ;;
    *) die "不支持的架构: $(uname -m)" ;;
esac
info "检测到架构: $(uname -m) -> ${RS_ARCH}"

# ========================= 安装路径 / 服务名 =========================
SVC_NAME="restic-rest-server"
INSTALL_DIR="/opt/${SVC_NAME}"
SVC_USER="${SVC_NAME}"

# 已存在安装时的处理（先判断是否已安装，再决定要不要问端口——
# "仅新增凭据"分支复用现有服务正在监听的端口，不应该再对这个端口做占用检查）
FIRST_INSTALL=1
if [[ -x "${INSTALL_DIR}/rest-server" ]] && systemctl list-unit-files | grep -q "^${SVC_NAME}.service"; then
    FIRST_INSTALL=0
    warn "检测到 ${SVC_NAME} 已经安装过。"
    echo "  [1] 仅新增一个备份凭据（给新的备份来源机器用，复用现有服务） (默认)"
    echo "  [2] 完全重新安装（会停止现有服务，覆盖证书与配置）"
    read -rp "请选择 [1]: " REINSTALL_CHOICE < /dev/tty
    REINSTALL_CHOICE="${REINSTALL_CHOICE:-1}"
    if [[ "$REINSTALL_CHOICE" == "2" ]]; then
        info "停止并清理现有安装 ..."
        systemctl stop "${SVC_NAME}.service" 2>/dev/null || true
        systemctl disable "${SVC_NAME}.service" 2>/dev/null || true
        rm -rf "${INSTALL_DIR}"
        rm -f "/etc/systemd/system/${SVC_NAME}.service"
        systemctl daemon-reload
        FIRST_INSTALL=1
    else
        LISTEN_PORT="$(grep -oP '(?<=--listen :)\d+' "/etc/systemd/system/${SVC_NAME}.service" | head -n1)"
        [[ -n "$LISTEN_PORT" ]] || die "无法从现有服务读取监听端口，建议选择完全重新安装"
        ok "复用现有服务，监听端口: ${LISTEN_PORT}"
    fi
fi

if [[ $FIRST_INSTALL -eq 1 ]]; then
    DEFAULT_PORT=9199
    read -rp "监听端口（直接回车用默认 [${DEFAULT_PORT}]): " LISTEN_PORT < /dev/tty
    LISTEN_PORT="${LISTEN_PORT:-$DEFAULT_PORT}"
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${LISTEN_PORT}\$"; then
        die "端口 ${LISTEN_PORT} 已被占用，请重新运行并选择其他端口"
    fi
    ok "将使用端口 ${LISTEN_PORT}"
fi

# ========================= 下载 rest-server 二进制 =========================
if [[ $FIRST_INSTALL -eq 1 ]]; then
    info "查询 restic/rest-server 最新版本 ..."
    API_JSON="$(curl -fsSL https://api.github.com/repos/restic/rest-server/releases/latest)"
    RS_VERSION="$(echo "$API_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"v([0-9.]+)".*/\1/')"
    [[ -n "$RS_VERSION" ]] || die "无法解析最新版本号"
    ASSET="rest-server_${RS_VERSION}_linux_${RS_ARCH}.tar.gz"
    DL_URL="https://github.com/restic/rest-server/releases/download/v${RS_VERSION}/${ASSET}"
    SUMS_URL="https://github.com/restic/rest-server/releases/download/v${RS_VERSION}/SHA256SUMS"
    info "下载 rest-server v${RS_VERSION} (${RS_ARCH}) ..."

    TMPD="$(mktemp -d)"
    trap 'rm -rf "$TMPD"' EXIT
    curl -fSL --progress-bar -o "${TMPD}/${ASSET}" "$DL_URL"
    curl -fsSL -o "${TMPD}/SHA256SUMS" "$SUMS_URL"

    info "校验 SHA256 ..."
    EXPECT_SUM="$(grep -F "$ASSET" "${TMPD}/SHA256SUMS" | awk '{print $1}')"
    ACTUAL_SUM="$(sha256sum "${TMPD}/${ASSET}" | awk '{print $1}')"
    [[ "$EXPECT_SUM" == "$ACTUAL_SUM" ]] || die "校验和不匹配！期望 $EXPECT_SUM 实际 $ACTUAL_SUM"
    ok "校验通过"

    tar -xzf "${TMPD}/${ASSET}" -C "$TMPD"
    mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/data" "$INSTALL_DIR/tls"
    RS_BIN="$(find "$TMPD" -type f -name rest-server | head -n1)"
    [[ -n "$RS_BIN" ]] || die "解压后未找到 rest-server 二进制"
    install -o root -g root -m 0755 "$RS_BIN" "$INSTALL_DIR/rest-server"
    ok "rest-server 已安装到 ${INSTALL_DIR}/rest-server"

    # ========================= 专用受限用户 =========================
    if ! id "$SVC_USER" >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -d "$INSTALL_DIR/data" "$SVC_USER"
        ok "已创建专用受限用户: ${SVC_USER}（无登录 shell）"
    fi
    chown -R root:root "$INSTALL_DIR"
    chown -R "${SVC_USER}:${SVC_USER}" "$INSTALL_DIR/data"
    chmod 750 "$INSTALL_DIR/data"
    # 二进制/安装目录本身不给服务账户写权限，防止凭据泄露后替换二进制
    chmod 755 "$INSTALL_DIR"
fi

# ========================= TLS 证书（仿 3x-ui 证书菜单） =========================
TLS_CERT="${INSTALL_DIR}/tls/cert.pem"
TLS_KEY="${INSTALL_DIR}/tls/key.pem"

if [[ $FIRST_INSTALL -eq 1 ]]; then
    PUBLIC_IP="$(curl -fsSL -4 https://ifconfig.me 2>/dev/null || curl -fsSL -4 https://icanhazip.com 2>/dev/null || echo "")"
    echo
    echo "证书类型选择："
    echo "  [1] Let's Encrypt 域名证书（需要一个已解析到本机的域名，走 acme.sh webroot 模式）"
    echo "  [2] 自签证书（默认，无需域名，客户端用 --cacert 直接信任这一张证书） (默认)"
    echo "  [3] 自定义证书路径（复用已有证书文件）"
    read -rp "请选择 [2]: " CERT_CHOICE < /dev/tty
    CERT_CHOICE="${CERT_CHOICE:-2}"

    case "$CERT_CHOICE" in
    1)
        read -rp "域名: " CERT_DOMAIN < /dev/tty
        [[ -n "$CERT_DOMAIN" ]] || die "域名不能为空"
        read -rp "nginx webroot 路径（用于 acme.sh 验证，直接回车用默认 [/var/www/html]): " WEBROOT < /dev/tty
        WEBROOT="${WEBROOT:-/var/www/html}"
        [[ -d "$WEBROOT" ]] || die "webroot 路径不存在: $WEBROOT"

        if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
            info "未检测到 acme.sh，正在安装 ..."
            curl -fsSL https://get.acme.sh | sh -s email=admin@"${CERT_DOMAIN}"
        fi
        info "通过 acme.sh 签发证书（webroot 模式）..."
        "$HOME/.acme.sh/acme.sh" --issue -d "$CERT_DOMAIN" -w "$WEBROOT" --keylength ec-256
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$CERT_DOMAIN" --ecc \
            --fullchain-file "$TLS_CERT" \
            --key-file "$TLS_KEY" \
            --reloadcmd "systemctl restart ${SVC_NAME}.service || true"
        ok "Let's Encrypt 证书签发完成: ${CERT_DOMAIN}"
        REST_HOST="$CERT_DOMAIN"
        ;;
    3)
        read -rp "证书文件路径 (fullchain/cert pem): " CUSTOM_CERT < /dev/tty
        read -rp "私钥文件路径 (key pem): " CUSTOM_KEY < /dev/tty
        [[ -f "$CUSTOM_CERT" ]] || die "证书文件不存在: $CUSTOM_CERT"
        [[ -f "$CUSTOM_KEY" ]]  || die "私钥文件不存在: $CUSTOM_KEY"
        cp "$CUSTOM_CERT" "$TLS_CERT"
        cp "$CUSTOM_KEY" "$TLS_KEY"
        ok "已复制自定义证书"
        read -rp "对外连接用的主机名/IP（直接回车用默认 [${PUBLIC_IP}]): " REST_HOST < /dev/tty
        REST_HOST="${REST_HOST:-$PUBLIC_IP}"
        ;;
    *)
        read -rp "证书 SAN 用的公网 IP/域名（直接回车用探测到的 [${PUBLIC_IP}]): " REST_HOST < /dev/tty
        REST_HOST="${REST_HOST:-$PUBLIC_IP}"
        [[ -n "$REST_HOST" ]] || die "无法确定主机地址，请手动输入"
        info "生成自签证书 (SAN=${REST_HOST}, 有效期 3650 天) ..."
        openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
            -keyout "$TLS_KEY" -out "$TLS_CERT" \
            -subj "/CN=${REST_HOST}" \
            -addext "subjectAltName=IP:${REST_HOST}" >/dev/null 2>&1
        ok "自签证书已生成"
        ;;
    esac

    chown "${SVC_USER}:${SVC_USER}" "$TLS_CERT" "$TLS_KEY"
    chmod 640 "$TLS_CERT" "$TLS_KEY"
else
    # 复用现有安装时，仍需要知道主机地址用于打印凭据
    PUBLIC_IP="$(curl -fsSL -4 https://ifconfig.me 2>/dev/null || curl -fsSL -4 https://icanhazip.com 2>/dev/null || echo "")"
    read -rp "对外连接用的主机名/IP（直接回车用探测到的 [${PUBLIC_IP}]): " REST_HOST < /dev/tty
    REST_HOST="${REST_HOST:-$PUBLIC_IP}"
fi

# ========================= htpasswd 凭据 =========================
HTPASSWD_FILE="${INSTALL_DIR}/data/.htpasswd"
DEFAULT_USER="client-$(openssl rand -hex 3)"
read -rp "新增备份来源用户名（直接回车用随机生成 [${DEFAULT_USER}]): " REPO_USER < /dev/tty
REPO_USER="${REPO_USER:-$DEFAULT_USER}"
REPO_PASS="$(openssl rand -base64 24 | tr -d '=+/' | head -c 24)"

if [[ -f "$HTPASSWD_FILE" ]]; then
    htpasswd -bB "$HTPASSWD_FILE" "$REPO_USER" "$REPO_PASS" >/dev/null 2>&1
else
    htpasswd -bBc "$HTPASSWD_FILE" "$REPO_USER" "$REPO_PASS" >/dev/null 2>&1
fi
chown "${SVC_USER}:${SVC_USER}" "$HTPASSWD_FILE"
chmod 640 "$HTPASSWD_FILE"
ok "已为用户 ${REPO_USER} 生成访问凭据"

# ========================= systemd 加固服务 =========================
if [[ $FIRST_INSTALL -eq 1 ]]; then
    info "写入 systemd 服务 ..."
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=restic rest-server (backupctl backup target)
After=network.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
ExecStart=${INSTALL_DIR}/rest-server --listen :${LISTEN_PORT} --path ${INSTALL_DIR}/data \\
    --tls --tls-cert ${TLS_CERT} --tls-key ${TLS_KEY} \\
    --private-repos --htpasswd-file ${HTPASSWD_FILE}
Restart=on-failure
RestartSec=5

# --- 加固 ---
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
ReadWritePaths=${INSTALL_DIR}/data
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${SVC_NAME}.service"
    ok "服务已启动并设置为开机自启"
else
    systemctl restart "${SVC_NAME}.service"
    ok "服务已重启以应用新增凭据"
fi

sleep 1
if systemctl is-active --quiet "${SVC_NAME}.service"; then
    ok "服务运行正常: $(systemctl is-active ${SVC_NAME}.service)"
else
    err "服务未能正常启动，日志如下："
    journalctl -u "${SVC_NAME}.service" --no-pager -n 30
    die "请检查上面的日志"
fi

info "连通性自检 ..."
# --private-repos 模式下，鉴权按 URL 路径的用户名分段匹配，所以要打到 /<user>/ 而不是根路径 "/"
# 仓库还没 restic init，正常应该拿到 401(无凭据被拒)/200/405 均代表鉴权链路正常，只有"有凭据仍 401"才是真故障
SELFCHECK_HOST="${REST_HOST:-127.0.0.1}"
SELFCHECK_URL="https://${SELFCHECK_HOST}:${LISTEN_PORT}/${REPO_USER}/"
NOAUTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --resolve "${SELFCHECK_HOST}:${LISTEN_PORT}:127.0.0.1" --cacert "$TLS_CERT" "$SELFCHECK_URL")"
AUTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --resolve "${SELFCHECK_HOST}:${LISTEN_PORT}:127.0.0.1" --cacert "$TLS_CERT" -u "${REPO_USER}:${REPO_PASS}" "$SELFCHECK_URL")"
if [[ "$NOAUTH_CODE" == "401" && "$AUTH_CODE" != "401" ]]; then
    ok "本地自检成功：无凭据被拒(401)，正确凭据可通过鉴权(HTTP ${AUTH_CODE})"
else
    warn "自检异常：无凭据=${NOAUTH_CODE}，带凭据=${AUTH_CODE}，请手动检查服务日志（journalctl -u ${SVC_NAME}.service）"
fi

# ========================= 生成凭据 blob =========================
CERT_B64="$(base64 -w0 "$TLS_CERT")"
BLOB_JSON=$(printf '{"host":"%s","port":%s,"user":"%s","pass":"%s","cert_pem_b64":"%s"}' \
    "$REST_HOST" "$LISTEN_PORT" "$REPO_USER" "$REPO_PASS" "$CERT_B64")
BLOB="$(printf '%s' "$BLOB_JSON" | base64 -w0)"

echo
echo "=================================================================="
ok "部署完成！请复制下面这一整行凭据，回到笔记本上执行："
echo "    cd <client 目录> && bin/backupctl target add"
echo "然后粘贴这一行："
echo "------------------------------------------------------------------"
echo "$BLOB"
echo "------------------------------------------------------------------"
warn "这行凭据包含访问密码，请只粘贴到你自己的 backupctl，不要发给其他人/其他地方"
echo "=================================================================="
