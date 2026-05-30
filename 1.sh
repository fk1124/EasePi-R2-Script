#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# EasePi-R2 LXC 一键布置 / 管理脚本
# - LXC 宿主依赖与 OpenWrt 宿主内核能力检测
# - /lxc 目录与 SSD 挂载管理
# - OpenWrt 24/25、Debian 12/13、Ubuntu 24.04 rootfs 管理
# - OpenWrt 路由容器一键安装
# - Debian/Ubuntu 普通容器自动接入 OpenWrt LAN 桥 br-hostlan
# - 容器离线备份 / 还原
# =========================================================

APP_NAME="EasePi-R2 LXC Manager"
CONFIG_DIR="/etc/easepi-r2-lxc-manager"
CONFIG_FILE="${CONFIG_DIR}/config.env"

LXC_BASE="${LXC_BASE:-/lxc}"
CONTAINER_DIR="${CONTAINER_DIR:-${LXC_BASE}/containers}"
ROOTFS_CACHE_DIR="${ROOTFS_CACHE_DIR:-${LXC_BASE}/rootfs-cache}"
BACKUP_DIR="${BACKUP_DIR:-${LXC_BASE}/backups}"
BACKUP_REMOTE_SLUG="${BACKUP_REMOTE_SLUG:-}"
BACKUP_REMOTE_REPO="${BACKUP_REMOTE_REPO:-}"
BACKUP_REMOTE_BRANCH="${BACKUP_REMOTE_BRANCH:-main}"
BACKUP_REMOTE_PATH="${BACKUP_REMOTE_PATH:-backups}"
BACKUP_CLOUD_DIR="${BACKUP_CLOUD_DIR:-${BACKUP_DIR}/.cloud-repo}"
BACKUP_SPLIT_SIZE="${BACKUP_SPLIT_SIZE:-95M}"
BACKUP_REMOTE_AUTH="${BACKUP_REMOTE_AUTH:-https-token}"
BACKUP_REMOTE_USER="${BACKUP_REMOTE_USER:-fk1124}"
BACKUP_REMOTE_TOKEN_FILE="${BACKUP_REMOTE_TOKEN_FILE:-${CONFIG_DIR}/github-token}"
BACKUP_REMOTE_SSH_KEY="${BACKUP_REMOTE_SSH_KEY:-/root/.ssh/easepi_r2_image_backup}"

HOST_BR="${HOST_BR:-br-hostlan}"
HOST_IP="${HOST_IP:-10.10.0.2}"
HOST_IP_CIDR="${HOST_IP_CIDR:-10.10.0.2/24}"
OPENWRT_IP="${OPENWRT_IP:-10.10.0.1}"
LAN_CIDR="${LAN_CIDR:-10.10.0.0/24}"
HOST_OPENWRT_ROUTE_ENABLE="${HOST_OPENWRT_ROUTE_ENABLE:-auto}"
HOST_OPENWRT_ROUTE_METRIC="${HOST_OPENWRT_ROUTE_METRIC:-300}"
HOST_OPENWRT_ROUTE_CHECK_IP="${HOST_OPENWRT_ROUTE_CHECK_IP:-223.5.5.5}"
OPENWRT_NET_TUNE_ENABLE="${OPENWRT_NET_TUNE_ENABLE:-1}"
OPENWRT_NET_TUNE_WAN_IRQ_CPU="${OPENWRT_NET_TUNE_WAN_IRQ_CPU:-6}"
OPENWRT_NET_TUNE_LAN_IRQ_CPUS="${OPENWRT_NET_TUNE_LAN_IRQ_CPUS:-7 5 4}"
OPENWRT_NET_TUNE_RPS_CPUS="${OPENWRT_NET_TUNE_RPS_CPUS:-f0}"
OPENWRT_NET_TUNE_RPS_FLOW_CNT="${OPENWRT_NET_TUNE_RPS_FLOW_CNT:-4096}"
OPENWRT_NET_TUNE_CPU_GOVERNOR="${OPENWRT_NET_TUNE_CPU_GOVERNOR:-performance}"
DHCP_START_IP="${DHCP_START_IP:-10.10.0.100}"
DHCP_END_IP="${DHCP_END_IP:-10.10.0.249}"
CANDIDATE_IFS="${CANDIDATE_IFS:-eth0 eth1 eth2 eth3}"

DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports}"
OPENWRT24_URL="${OPENWRT24_URL:-https://mirror.sjtu.edu.cn/openwrt/releases/24.10.6/targets/armsr/armv8/openwrt-24.10.6-armsr-armv8-rootfs.tar.gz}"
OPENWRT24_SHA256="${OPENWRT24_SHA256:-a0f7bdda2fe581e044b06d2f48788b76cbdb37cfa1e974d72ea981e391e04392}"
OPENWRT25_URL="${OPENWRT25_URL:-https://downloads.openwrt.org/releases/25.12.0/targets/armsr/armv8/openwrt-25.12.0-armsr-armv8-rootfs.tar.gz}"
OPENWRT25_SHA256="${OPENWRT25_SHA256:-d5e42b396d7f64697c65a884912107b49e05d2b2f2c00a251f94c44f8deef507}"
UBUNTU_KEYRING_DEB="${UBUNTU_KEYRING_DEB:-ubuntu-keyring_2023.11.28.1_all.deb}"
UBUNTU_KEYRING_SHA256="${UBUNTU_KEYRING_SHA256:-36de43b15853ccae0028e9a767613770c704833f82586f28eb262f0311adb8a8}"

if [ "$(id -u)" != "0" ]; then
    echo "请用 root 执行：bash 1.sh"
    exit 1
fi

log() { echo "[lxc-manager] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

pause_enter() {
    echo
    read -r -p "按回车返回..." _ || true
}

confirm() {
    local prompt="$1"
    local default="${2:-y}"
    local ans hint
    if [ "$default" = "y" ]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi
    read -r -p "${prompt} ${hint}: " ans || ans=""
    ans="${ans:-$default}"
    case "$ans" in
        y|Y|yes|YES|Yes|是) return 0 ;;
        *) return 1 ;;
    esac
}

read_default() {
    local prompt="$1"
    local default="$2"
    local ans
    read -r -p "${prompt} [${default}]: " ans || ans=""
    printf '%s' "${ans:-$default}"
}

menu_action() {
    ( "$@" ) || warn "操作未完成。"
}

trim() {
    local s="$*"
    s="${s#${s%%[![:space:]]*}}"
    s="${s%${s##*[![:space:]]}}"
    printf '%s' "$s"
}

format_bytes() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB", u, " ");
        i = 1;
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%.0f%s", b, u[i];
        else printf "%.1f%s", b, u[i];
    }'
}

file_size_bytes() {
    local path="$1"
    stat -c '%s' "$path" 2>/dev/null || wc -c < "$path" 2>/dev/null || echo 0
}

dir_size_bytes() {
    local path="$1"
    du -sb "$path" 2>/dev/null | awk '{print $1}'
}

sanitize_backup_id() {
    local name="$1"
    printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_'
}

valid_relative_path() {
    local path="$1"
    case "$path" in
        ""|/*|*../*|../*|*"/.."|*"//"*|*[!A-Za-z0-9_.\/-]*) return 1 ;;
        *) return 0 ;;
    esac
}

normalize_backup_remote_slug() {
    local input="$1"
    input="$(trim "$input")"
    input="${input#https://github.com/}"
    input="${input#http://github.com/}"
    input="${input#git@github.com:}"
    input="${input#ssh://git@github.com/}"
    input="${input%.git}"
    input="${input#/}"
    input="${input%/}"
    printf '%s' "$input"
}

valid_backup_remote_slug() {
    case "$1" in
        */*)
            case "$1" in
                *//*|/*|*/|*../*|../*|*"/.."|*[!A-Za-z0-9_.\/-]*) return 1 ;;
                *) [ "$(printf '%s' "$1" | awk -F/ '{print NF}')" -eq 2 ] ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

backup_remote_url_for_auth() {
    local slug="$1" auth="$2"
    case "$auth" in
        ssh) printf 'git@github.com:%s.git' "$slug" ;;
        *) printf 'https://github.com/%s.git' "$slug" ;;
    esac
}

refresh_backup_remote_repo() {
    BACKUP_REMOTE_SLUG="$(normalize_backup_remote_slug "${BACKUP_REMOTE_SLUG:-${BACKUP_REMOTE_REPO:-fk1124/EasePi-R2-Image-Backup}}")"
    if ! valid_backup_remote_slug "$BACKUP_REMOTE_SLUG"; then
        warn "云端仓库格式不合法，已恢复为 fk1124/EasePi-R2-Image-Backup。"
        BACKUP_REMOTE_SLUG="fk1124/EasePi-R2-Image-Backup"
    fi
    BACKUP_REMOTE_REPO="$(backup_remote_url_for_auth "$BACKUP_REMOTE_SLUG" "$BACKUP_REMOTE_AUTH")"
}

valid_backup_filename() {
    case "$1" in
        ""|*/*|*.partial|*[!A-Za-z0-9_.-]*) return 1 ;;
        *.tar.zst) return 0 ;;
        *) return 1 ;;
    esac
}

backup_container_name_from_file() {
    local file="$1" base
    base="$(basename "$file")"
    printf '%s' "$base" | sed -E 's/-[0-9]{8}-[0-9]{6}\.tar\.zst$//'
}

stable_lxc_mac() {
    local name="$1"
    local ifname="$2"
    local digest

    digest="$(printf 'easepi-r2-lxc:%s:%s' "$name" "$ifname" | sha256sum | awk '{print $1}')"
    printf '02:%s:%s:%s:%s:%s\n' \
        "${digest:0:2}" "${digest:2:2}" "${digest:4:2}" "${digest:6:2}" "${digest:8:2}"
}

load_config() {
    if [ -r "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
    : "${LXC_BASE:=/lxc}"
    : "${CONTAINER_DIR:=${LXC_BASE}/containers}"
    : "${ROOTFS_CACHE_DIR:=${LXC_BASE}/rootfs-cache}"
    : "${BACKUP_DIR:=${LXC_BASE}/backups}"
    : "${BACKUP_REMOTE_SLUG:=${BACKUP_REMOTE_REPO:-fk1124/EasePi-R2-Image-Backup}}"
    : "${BACKUP_REMOTE_REPO:=}"
    : "${BACKUP_REMOTE_BRANCH:=main}"
    : "${BACKUP_REMOTE_PATH:=backups}"
    : "${BACKUP_CLOUD_DIR:=${BACKUP_DIR}/.cloud-repo}"
    : "${BACKUP_SPLIT_SIZE:=95M}"
    : "${BACKUP_REMOTE_AUTH:=https-token}"
    : "${BACKUP_REMOTE_USER:=fk1124}"
    : "${BACKUP_REMOTE_TOKEN_FILE:=${CONFIG_DIR}/github-token}"
    : "${BACKUP_REMOTE_SSH_KEY:=/root/.ssh/easepi_r2_image_backup}"
    refresh_backup_remote_repo
    : "${HOST_BR:=br-hostlan}"
    : "${HOST_IP:=10.10.0.2}"
    : "${HOST_IP_CIDR:=10.10.0.2/24}"
    : "${OPENWRT_IP:=10.10.0.1}"
    : "${LAN_CIDR:=10.10.0.0/24}"
    : "${HOST_OPENWRT_ROUTE_ENABLE:=auto}"
    : "${HOST_OPENWRT_ROUTE_METRIC:=300}"
    : "${HOST_OPENWRT_ROUTE_CHECK_IP:=223.5.5.5}"
    : "${OPENWRT_NET_TUNE_ENABLE:=1}"
    : "${OPENWRT_NET_TUNE_WAN_IRQ_CPU:=6}"
    : "${OPENWRT_NET_TUNE_LAN_IRQ_CPUS:=7 5 4}"
    : "${OPENWRT_NET_TUNE_RPS_CPUS:=f0}"
    : "${OPENWRT_NET_TUNE_RPS_FLOW_CNT:=4096}"
    : "${OPENWRT_NET_TUNE_CPU_GOVERNOR:=performance}"
    : "${DHCP_START_IP:=10.10.0.100}"
    : "${DHCP_END_IP:=10.10.0.249}"
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    {
        printf 'LXC_BASE=%q\n' "$LXC_BASE"
        printf 'CONTAINER_DIR=%q\n' "$CONTAINER_DIR"
        printf 'ROOTFS_CACHE_DIR=%q\n' "$ROOTFS_CACHE_DIR"
        printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR"
        printf 'BACKUP_REMOTE_SLUG=%q\n' "$BACKUP_REMOTE_SLUG"
        printf 'BACKUP_REMOTE_REPO=%q\n' "$BACKUP_REMOTE_REPO"
        printf 'BACKUP_REMOTE_BRANCH=%q\n' "$BACKUP_REMOTE_BRANCH"
        printf 'BACKUP_REMOTE_PATH=%q\n' "$BACKUP_REMOTE_PATH"
        printf 'BACKUP_CLOUD_DIR=%q\n' "$BACKUP_CLOUD_DIR"
        printf 'BACKUP_SPLIT_SIZE=%q\n' "$BACKUP_SPLIT_SIZE"
        printf 'BACKUP_REMOTE_AUTH=%q\n' "$BACKUP_REMOTE_AUTH"
        printf 'BACKUP_REMOTE_USER=%q\n' "$BACKUP_REMOTE_USER"
        printf 'BACKUP_REMOTE_TOKEN_FILE=%q\n' "$BACKUP_REMOTE_TOKEN_FILE"
        printf 'BACKUP_REMOTE_SSH_KEY=%q\n' "$BACKUP_REMOTE_SSH_KEY"
        printf 'HOST_BR=%q\n' "$HOST_BR"
        printf 'HOST_IP=%q\n' "$HOST_IP"
        printf 'HOST_IP_CIDR=%q\n' "$HOST_IP_CIDR"
        printf 'OPENWRT_IP=%q\n' "$OPENWRT_IP"
        printf 'LAN_CIDR=%q\n' "$LAN_CIDR"
        printf 'HOST_OPENWRT_ROUTE_ENABLE=%q\n' "$HOST_OPENWRT_ROUTE_ENABLE"
        printf 'HOST_OPENWRT_ROUTE_METRIC=%q\n' "$HOST_OPENWRT_ROUTE_METRIC"
        printf 'HOST_OPENWRT_ROUTE_CHECK_IP=%q\n' "$HOST_OPENWRT_ROUTE_CHECK_IP"
        printf 'OPENWRT_NET_TUNE_ENABLE=%q\n' "$OPENWRT_NET_TUNE_ENABLE"
        printf 'OPENWRT_NET_TUNE_WAN_IRQ_CPU=%q\n' "$OPENWRT_NET_TUNE_WAN_IRQ_CPU"
        printf 'OPENWRT_NET_TUNE_LAN_IRQ_CPUS=%q\n' "$OPENWRT_NET_TUNE_LAN_IRQ_CPUS"
        printf 'OPENWRT_NET_TUNE_RPS_CPUS=%q\n' "$OPENWRT_NET_TUNE_RPS_CPUS"
        printf 'OPENWRT_NET_TUNE_RPS_FLOW_CNT=%q\n' "$OPENWRT_NET_TUNE_RPS_FLOW_CNT"
        printf 'OPENWRT_NET_TUNE_CPU_GOVERNOR=%q\n' "$OPENWRT_NET_TUNE_CPU_GOVERNOR"
        printf 'DHCP_START_IP=%q\n' "$DHCP_START_IP"
        printf 'DHCP_END_IP=%q\n' "$DHCP_END_IP"
    } > "$CONFIG_FILE"
}

ensure_dirs() {
    mkdir -p "$LXC_BASE" "$CONTAINER_DIR" "$ROOTFS_CACHE_DIR" "$BACKUP_DIR" "$CONFIG_DIR"
    apply_lxc_global_config
}

apply_lxc_global_config() {
    mkdir -p /etc/lxc

    local tmp
    tmp="$(mktemp)"
    if [ -f /etc/lxc/lxc.conf ]; then
        grep -vE '^[[:space:]]*lxc\.lxcpath[[:space:]]*=' /etc/lxc/lxc.conf > "$tmp" || true
    fi
    printf 'lxc.lxcpath = %s\n' "$CONTAINER_DIR" >> "$tmp"
    install -m 0644 "$tmp" /etc/lxc/lxc.conf
    rm -f "$tmp"

    cat > /etc/default/lxc-net <<'EOF'
USE_LXC_BRIDGE="false"
EOF

    cat > /etc/lxc/default.conf <<'EOF'
lxc.include = /usr/share/lxc/config/common.conf
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1
EOF

    systemctl disable --now lxc-net.service >/dev/null 2>&1 || true
}

dpkg_missing_packages() {
    local pkg
    for pkg in "$@"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            printf '%s\n' "$pkg"
        fi
    done
}

install_lxc_dependencies() {
    local packages missing
    packages=(
        lxc lxcfs lxc-templates uidmap libpam-cgfs
        systemd-container dbus-user-session
        debootstrap mmdebstrap debian-archive-keyring
        qemu-user-static binfmt-support
        fuse-overlayfs slirp4netns criu
        iproute2 iputils-ping ethtool bridge-utils
        curl wget ca-certificates rsync zstd xz-utils gzip tar unzip
        git pv
        jq kmod parted util-linux e2fsprogs dosfstools
        openssh-client
    )

    echo
    echo "========== 检测 LXC 宿主依赖 =========="
    mapfile -t missing < <(dpkg_missing_packages "${packages[@]}")
    if [ "${#missing[@]}" -eq 0 ]; then
        ok "LXC 宿主依赖已经安装完整。"
    else
        echo "缺少以下软件包："
        printf '  - %s\n' "${missing[@]}"
        if confirm "是否一键安装这些依赖？" y; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
        else
            warn "已取消安装依赖。"
            return 1
        fi
    fi

    ensure_dirs
    systemctl enable --now lxc.service >/dev/null 2>&1 || true
    systemctl enable --now lxcfs.service >/dev/null 2>&1 || true
    systemctl disable --now lxc-net.service >/dev/null 2>&1 || true
    ok "LXC 依赖与默认目录配置完成。"
}

check_openwrt_kmods() {
    local packages missing_packages modules ok_modules missing_modules flow_modules ok_flow_modules missing_flow_modules mod
    packages=(
        kmod iproute2 iputils-ping ethtool bridge-utils
        iptables nftables ebtables arptables conntrack ipset
    )
    modules=(
        bridge br_netfilter veth tun overlay 8021q
        slhc ppp_generic pppox pppoe
        nf_tables nf_conntrack nf_nat nft_chain_nat nft_masq nft_redir
        nft_tproxy nft_socket nf_tproxy_ipv4 nf_tproxy_ipv6
        nf_socket_ipv4 nf_socket_ipv6 ip_set ip_set_hash_ip ip_set_hash_net
        x_tables ip_tables iptable_nat iptable_mangle
        xt_TPROXY xt_socket xt_mark xt_connmark xt_conntrack xt_REDIRECT xt_MASQUERADE
        wireguard
    )
    flow_modules=(nf_flow_table nft_flow_offload)
    ok_modules=()
    missing_modules=()
    ok_flow_modules=()
    missing_flow_modules=()

    echo
    echo "========== 检测 OpenWrt LXC 所需宿主内核能力 =========="
    mapfile -t missing_packages < <(dpkg_missing_packages "${packages[@]}")
    if [ "${#missing_packages[@]}" -gt 0 ]; then
        echo "缺少以下 OpenWrt 宿主辅助包："
        printf '  - %s\n' "${missing_packages[@]}"
        if confirm "是否一键安装这些辅助包？" y; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
        else
            warn "已取消安装辅助包，仅继续检测当前内核模块。"
        fi
    fi

    if ! dpkg-query -W -f='${Status}' kmod 2>/dev/null | grep -q 'install ok installed'; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y kmod
    fi

    for mod in "${modules[@]}"; do
        if modprobe "$mod" >/dev/null 2>&1; then
            ok_modules+=("$mod")
        else
            missing_modules+=("$mod")
        fi
    done

    for mod in "${flow_modules[@]}"; do
        if grep -qw "$mod" /proc/modules 2>/dev/null || modprobe -n "$mod" >/dev/null 2>&1; then
            ok_flow_modules+=("$mod")
        else
            missing_flow_modules+=("$mod")
        fi
    done

    ensure_host_ppp_device

    mkdir -p /etc/modules-load.d
    printf '%s\n' "${ok_modules[@]}" > /etc/modules-load.d/easepi-r2-lxc.conf

    cat > /etc/sysctl.d/90-easepi-r2-lxc-host.conf <<'EOF'
kernel.unprivileged_userns_clone=1
user.max_user_namespaces=28633
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
-net.bridge.bridge-nf-call-iptables=1
-net.bridge.bridge-nf-call-ip6tables=1
EOF
    sysctl --system >/dev/null 2>&1 || true

    echo
    ok "已成功加载/持久化 ${#ok_modules[@]} 个模块。"
    if [ "${#missing_modules[@]}" -gt 0 ]; then
        warn "以下模块当前内核没有提供或名称不匹配："
        printf '  - %s\n' "${missing_modules[@]}"
        warn "这类模块不能靠脚本凭空安装；如果后续功能缺失，需要在 LiteHost 内核配置里开启。"
    fi
    if [ "${#ok_flow_modules[@]}" -gt 0 ]; then
        ok "Flow offload 模块可用（仅检测，不会默认开启 OpenWrt firewall flow offload）：${ok_flow_modules[*]}"
    fi
    if [ "${#missing_flow_modules[@]}" -gt 0 ]; then
        warn "Flow offload 可选模块未检测到：${missing_flow_modules[*]}"
    fi
}

rootfs_label() {
    case "$1" in
        openwrt24) echo "OpenWrt 24.10.6 armsr/armv8" ;;
        openwrt25) echo "OpenWrt 25.12.0 armsr/armv8" ;;
        debian12) echo "Debian 12 Bookworm arm64" ;;
        debian13) echo "Debian 13 Trixie arm64" ;;
        ubuntu24) echo "Ubuntu 24.04 Noble arm64" ;;
        *) echo "$1" ;;
    esac
}

rootfs_cache_file() {
    case "$1" in
        openwrt24) echo "${ROOTFS_CACHE_DIR}/openwrt-24.10.6-armsr-armv8-rootfs.tar.gz" ;;
        openwrt25) echo "${ROOTFS_CACHE_DIR}/openwrt-25.12.0-armsr-armv8-rootfs.tar.gz" ;;
        debian12) echo "${ROOTFS_CACHE_DIR}/debian-12-bookworm-arm64-rootfs.tar.zst" ;;
        debian13) echo "${ROOTFS_CACHE_DIR}/debian-13-trixie-arm64-rootfs.tar.zst" ;;
        ubuntu24) echo "${ROOTFS_CACHE_DIR}/ubuntu-24.04-noble-arm64-rootfs.tar.zst" ;;
        *) die "未知 rootfs：$1" ;;
    esac
}

rootfs_url() {
    case "$1" in
        openwrt24) echo "$OPENWRT24_URL" ;;
        openwrt25) echo "$OPENWRT25_URL" ;;
        *) echo "" ;;
    esac
}

rootfs_sha256() {
    case "$1" in
        openwrt24) echo "$OPENWRT24_SHA256" ;;
        openwrt25) echo "$OPENWRT25_SHA256" ;;
        *) echo "" ;;
    esac
}

sha256_file_ok() {
    local file="$1"
    local sha="$2"
    [ -f "$file" ] || return 1
    [ -n "$sha" ] || return 0
    echo "${sha}  ${file}" | sha256sum -c - >/dev/null 2>&1
}

download_file() {
    local url="$1"
    local file="$2"
    local sha="$3"
    local tmp="${file}.tmp.$$"

    mkdir -p "$(dirname "$file")"
    if sha256_file_ok "$file" "$sha"; then
        ok "复用已下载并校验通过的文件：$file"
        return 0
    fi

    rm -f "$tmp"
    log "下载：$url"
    if command_exists curl; then
        curl -L --fail --connect-timeout 20 --retry 3 -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    else
        wget -O "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    fi
    if [ -n "$sha" ]; then
        echo "${sha}  ${tmp}" | sha256sum -c - || { rm -f "$tmp"; return 1; }
    fi
    mv -f "$tmp" "$file"
    ok "下载完成：$file"
}

ensure_openwrt_rootfs() {
    local key="$1"
    download_file "$(rootfs_url "$key")" "$(rootfs_cache_file "$key")" "$(rootfs_sha256 "$key")"
}

ubuntu_keyring_url_candidates() {
    local mirror_base
    mirror_base="${UBUNTU_MIRROR%/}"
    cat <<EOF
${mirror_base}/pool/main/u/ubuntu-keyring/${UBUNTU_KEYRING_DEB}
https://ports.ubuntu.com/ubuntu-ports/pool/main/u/ubuntu-keyring/${UBUNTU_KEYRING_DEB}
https://archive.ubuntu.com/ubuntu/pool/main/u/ubuntu-keyring/${UBUNTU_KEYRING_DEB}
EOF
}

ensure_ubuntu_archive_keyring() {
    local keyring="${ROOTFS_CACHE_DIR}/ubuntu-archive-keyring.gpg"
    local deb="${ROOTFS_CACHE_DIR}/${UBUNTU_KEYRING_DEB}"
    local extract_dir url

    if [ -s "$keyring" ]; then
        echo "$keyring"
        return 0
    fi

    mkdir -p "$ROOTFS_CACHE_DIR"
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        if download_file "$url" "$deb" "$UBUNTU_KEYRING_SHA256" >&2; then
            break
        fi
        warn "下载 Ubuntu keyring 失败，尝试下一个源：$url"
    done < <(ubuntu_keyring_url_candidates)

    if ! sha256_file_ok "$deb" "$UBUNTU_KEYRING_SHA256"; then
        die "无法下载并校验 Ubuntu keyring：${UBUNTU_KEYRING_DEB}"
    fi

    extract_dir="$(mktemp -d /tmp/easepi-r2-ubuntu-keyring.XXXXXX)"
    dpkg-deb -x "$deb" "$extract_dir"
    if [ ! -s "${extract_dir}/usr/share/keyrings/ubuntu-archive-keyring.gpg" ]; then
        rm -rf "$extract_dir"
        die "Ubuntu keyring 包内缺少 ubuntu-archive-keyring.gpg"
    fi
    install -m 0644 "${extract_dir}/usr/share/keyrings/ubuntu-archive-keyring.gpg" "$keyring"
    rm -rf "$extract_dir"
    echo "$keyring"
}

prepare_debootstrap_dir_for_suite() {
    local suite="$1"
    local compat_suite="${2:-}"
    local source_dir="/usr/share/debootstrap"
    local target_dir script_path

    if [ -e "${source_dir}/scripts/${suite}" ]; then
        echo "$source_dir"
        return 0
    fi
    [ -n "$compat_suite" ] || die "当前 debootstrap 缺少 ${suite} 脚本。"
    [ -e "${source_dir}/scripts/${compat_suite}" ] || die "当前 debootstrap 同时缺少 ${suite}/${compat_suite} 脚本。"

    target_dir="$(mktemp -d /tmp/easepi-r2-debootstrap.XXXXXX)"
    mkdir -p "${target_dir}/scripts"
    cp -a "${source_dir}/functions" "${target_dir}/functions"
    cp -a "${source_dir}/scripts/." "${target_dir}/scripts/"
    script_path="${target_dir}/scripts/${suite}"
    ln -s "$compat_suite" "$script_path" 2>/dev/null || cp -a "${target_dir}/scripts/${compat_suite}" "$script_path"
    echo "$target_dir"
}

debootstrap_rootfs() {
    local key="$1"
    local suite="$2"
    local mirror="$3"
    local include="$4"
    local cache_file
    local work rootfs keyring_arg debootstrap_dir debootstrap_env
    cache_file="$(rootfs_cache_file "$key")"

    if [ -f "$cache_file" ]; then
        ok "复用已存在 rootfs：$cache_file"
        return 0
    fi

    install_lxc_dependencies
    mkdir -p "$ROOTFS_CACHE_DIR"
    work="$(mktemp -d /tmp/easepi-r2-rootfs.XXXXXX)"
    rootfs="${work}/rootfs"
    mkdir -p "$rootfs"

    keyring_arg=()
    debootstrap_dir="/usr/share/debootstrap"
    if [[ "$key" == ubuntu* ]]; then
        keyring_arg=(--keyring="$(ensure_ubuntu_archive_keyring)")
        debootstrap_dir="$(prepare_debootstrap_dir_for_suite "$suite" jammy)"
    fi

    log "生成 $(rootfs_label "$key")，时间会稍长..."
    debootstrap_env=()
    if [ "$debootstrap_dir" != "/usr/share/debootstrap" ]; then
        debootstrap_env=(env "DEBOOTSTRAP_DIR=${debootstrap_dir}")
    fi
    if ! "${debootstrap_env[@]}" debootstrap --arch=arm64 --variant=minbase "${keyring_arg[@]}" --include="$include" "$suite" "$rootfs" "$mirror"; then
        [ "$debootstrap_dir" = "/usr/share/debootstrap" ] || rm -rf "$debootstrap_dir"
        rm -rf "$work"
        return 1
    fi

    configure_linux_rootfs_base "$rootfs" "$key"

    tar --numeric-owner --xattrs -C "$rootfs" -I 'zstd -19 -T0' -cpf "$cache_file" .
    [ "$debootstrap_dir" = "/usr/share/debootstrap" ] || rm -rf "$debootstrap_dir"
    rm -rf "$work"
    ok "rootfs 已生成：$cache_file"
}

configure_linux_rootfs_base() {
    local rootfs="$1"
    local key="$2"
    local hostname="$key"

    mkdir -p "$rootfs/etc/systemd/network" "$rootfs/etc/systemd/system/multi-user.target.wants"
    echo "$hostname" > "$rootfs/etc/hostname"
    cat > "$rootfs/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${hostname}
EOF

    cat > "$rootfs/etc/systemd/network/10-eth0.network" <<'EOF'
[Match]
Name=eth0

[Network]
DHCP=yes
IPv6AcceptRA=yes
LinkLocalAddressing=ipv6

[DHCPv4]
UseDNS=yes
UseRoutes=yes
EOF

    ln -sf /lib/systemd/system/systemd-networkd.service \
        "$rootfs/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>/dev/null || true
    ln -sf /lib/systemd/system/ssh.service \
        "$rootfs/etc/systemd/system/multi-user.target.wants/ssh.service" 2>/dev/null || true

    cat > "$rootfs/etc/resolv.conf" <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
EOF

    : > "$rootfs/etc/machine-id"
    rm -f "$rootfs/var/lib/dbus/machine-id"
    chroot "$rootfs" apt-get clean >/dev/null 2>&1 || true

    cat > "$rootfs/root/README-EasePi-R2-LXC.txt" <<'EOF'
这个容器由 EasePi-R2 LXC Manager 创建。
默认通过 eth0 DHCP 接入 OpenWrt 的 br-hostlan 网络。
如需 SSH root 登录，请先通过 lxc-attach 进入容器后执行 passwd 设置密码。
EOF
}

ensure_debian_ubuntu_rootfs() {
    case "$1" in
        debian12)
            debootstrap_rootfs debian12 bookworm "$DEBIAN_MIRROR" "systemd-sysv,dbus,iproute2,iputils-ping,ca-certificates,curl,wget,nano,less,openssh-server,locales,sudo"
            ;;
        debian13)
            debootstrap_rootfs debian13 trixie "$DEBIAN_MIRROR" "systemd-sysv,dbus,iproute2,iputils-ping,ca-certificates,curl,wget,nano,less,openssh-server,locales,sudo"
            ;;
        ubuntu24)
            debootstrap_rootfs ubuntu24 noble "$UBUNTU_MIRROR" "systemd-sysv,dbus,iproute2,iputils-ping,ca-certificates,curl,wget,nano,less,openssh-server,locales,sudo"
            ;;
        *) die "未知 Debian/Ubuntu rootfs：$1" ;;
    esac
}

ensure_rootfs() {
    case "$1" in
        openwrt24|openwrt25) ensure_openwrt_rootfs "$1" ;;
        debian12|debian13|ubuntu24) ensure_debian_ubuntu_rootfs "$1" ;;
        *) die "未知 rootfs：$1" ;;
    esac
}

rootfs_manager_menu() {
    local choice key file
    while true; do
        echo
        echo "========== rootfs 管理 =========="
        for key in openwrt24 openwrt25 debian12 debian13 ubuntu24; do
            file="$(rootfs_cache_file "$key")"
            if [ -f "$file" ]; then
                printf '  %-10s %-30s 已缓存：%s\n' "$key" "$(rootfs_label "$key")" "$file"
            else
                printf '  %-10s %-30s 未缓存\n' "$key" "$(rootfs_label "$key")"
            fi
        done
        echo
        echo "1. 预下载 OpenWrt 24"
        echo "2. 预下载 OpenWrt 25"
        echo "3. 预生成 Debian 12 Bookworm"
        echo "4. 预生成 Debian 13 Trixie"
        echo "5. 预生成 Ubuntu 24.04 Noble"
        echo "0. 返回"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1) ensure_rootfs openwrt24; pause_enter ;;
            2) ensure_rootfs openwrt25; pause_enter ;;
            3) ensure_rootfs debian12; pause_enter ;;
            4) ensure_rootfs debian13; pause_enter ;;
            5) ensure_rootfs ubuntu24; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

dir_has_entries() {
    local dir="$1"
    [ -d "$dir" ] || return 1
    find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

show_lxc_dirs() {
    echo
    echo "========== 当前 LXC 目录 =========="
    echo "LXC 根目录       ：$LXC_BASE"
    echo "容器目录         ：$CONTAINER_DIR"
    echo "rootfs 缓存目录  ：$ROOTFS_CACHE_DIR"
    echo "备份目录         ：$BACKUP_DIR"
    echo "配置文件         ：$CONFIG_FILE"
    echo
    findmnt "$LXC_BASE" || true
}

set_lxc_dirs() {
    local new_base
    new_base="$(read_default "请输入 LXC 根目录" "$LXC_BASE")"
    new_base="${new_base%/}"
    [ -n "$new_base" ] || die "LXC 根目录不能为空。"

    LXC_BASE="$new_base"
    CONTAINER_DIR="${LXC_BASE}/containers"
    ROOTFS_CACHE_DIR="${LXC_BASE}/rootfs-cache"
    BACKUP_DIR="${LXC_BASE}/backups"
    save_config
    ensure_dirs
    ok "目录已更新。"
    show_lxc_dirs
}

root_parent_disk() {
    local src pk
    src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [ -n "$src" ] || return 1
    pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
    if [ -n "$pk" ]; then
        echo "/dev/$pk"
    else
        echo "$src"
    fi
}

list_m2_candidates() {
    echo
    echo "========== 磁盘列表 =========="
    lsblk -dpno NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,MODEL,TRAN 2>/dev/null | sed 's/^/  /'
    echo
    echo "提示：M.2 NVMe 通常类似 /dev/nvme0n1；SATA SSD 可能类似 /dev/sda。"
    echo "说明：/lxc 是目录挂载点，推荐把整块 SSD 重建为 1 个 ext4 分区，再挂载到 /lxc。"
}

partition_of_disk() {
    local disk="$1"
    if [[ "$disk" =~ (nvme|mmcblk) ]]; then
        echo "${disk}p1"
    else
        echo "${disk}1"
    fi
}

partition_example_of_disk() {
    partition_of_disk "$1"
}

disk_partitions() {
    local disk="$1"
    lsblk -lnp -o NAME,TYPE "$disk" 2>/dev/null | awk '$2=="part"{print $1}'
}

ensure_disk_tools() {
    local missing=()
    local cmd
    for cmd in lsblk findmnt blkid mount umount wipefs parted partprobe mkfs.ext4 rsync; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    warn "磁盘工具不完整，缺少：${missing[*]}"
    if confirm "是否自动安装 parted / e2fsprogs / util-linux / rsync？" y; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y parted e2fsprogs util-linux rsync
    else
        die "缺少磁盘工具，无法继续。"
    fi
}

unmount_disk_partitions() {
    local disk="$1"
    local part mp
    while read -r part; do
        [ -n "$part" ] || continue
        if swapon --noheadings --show=NAME 2>/dev/null | grep -qx "$part"; then
            warn "关闭 swap：$part"
            swapoff "$part" || die "无法关闭 swap：$part"
        fi

        findmnt -rn -S "$part" -o TARGET 2>/dev/null | sort -r | while read -r mp; do
            [ -n "$mp" ] || continue
            warn "卸载：$part -> $mp"
            umount "$mp" || die "无法卸载 $mp，请先手动停止正在占用它的服务。"
        done
    done < <(disk_partitions "$disk")
}

format_disk_as_lxc_ext4() {
    local disk="$1"
    local ack part

    echo >&2
    warn "你选择的是整块磁盘：$disk"
    warn "下面操作会卸载该磁盘的所有分区，并清空整块磁盘上的所有数据。"
    echo "当前分区情况：" >&2
    lsblk -lnp -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT "$disk" 2>/dev/null | sed 's/^/  /' >&2
    echo >&2
    read -r -p "如确认把整块磁盘重建为 /lxc 专用盘，请输入：FORMAT ${disk} : " ack || ack=""
    [ "$ack" = "FORMAT ${disk}" ] || die "确认文本不匹配，已取消格式化。"

    unmount_disk_partitions "$disk"
    wipefs -a "$disk" >&2
    parted -s "$disk" mklabel gpt >&2
    parted -s "$disk" mkpart primary ext4 1MiB 100% >&2
    partprobe "$disk" >&2 || true
    command_exists udevadm && udevadm settle >&2 || true
    sleep 2
    part="$(partition_of_disk "$disk")"
    [ -b "$part" ] || die "创建分区后未找到 $part。"
    mkfs.ext4 -F -L EasePiR2_LXC "$part" >&2
    echo "$part"
}

prepare_ext4_target() {
    local dev="$1"
    local type fstype children ack part choice example pk
    type="$(lsblk -dn -o TYPE "$dev" 2>/dev/null | head -n1 || true)"
    fstype="$(lsblk -dn -o FSTYPE "$dev" 2>/dev/null | head -n1 || true)"

    case "$type" in
        disk)
            children="$(lsblk -nr "$dev" 2>/dev/null | awk 'NR>1 {print $1}' | head -n1 || true)"
            if [ -n "$children" ]; then
                example="$(partition_example_of_disk "$dev")"
                echo >&2
                warn "$dev 已有分区。你可以选择已有分区挂载到 $LXC_BASE，也可以清空整块磁盘后重建。"
                echo "当前分区：" >&2
                lsblk -lnp -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT "$dev" 2>/dev/null | sed 's/^/  /' >&2
                echo >&2
                echo "1. 选择已有分区，例如 $example" >&2
                echo "2. 卸载该磁盘所有分区，清空并重新格式化为 /lxc 专用 ext4 分区" >&2
                echo "0. 取消" >&2
                read -r -p "请选择: " choice || choice=""
                case "$choice" in
                    1)
                        read -r -p "请输入要挂载到 ${LXC_BASE} 的分区路径，例如 ${example}: " part || part=""
                        [ -b "$part" ] || die "分区不存在：$part"
                        pk="$(lsblk -no PKNAME "$part" 2>/dev/null | head -n1 || true)"
                        [ -n "$pk" ] && [ "/dev/$pk" = "$dev" ] || die "$part 不属于 $dev。"
                        prepare_ext4_target "$part"
                        ;;
                    2)
                        format_disk_as_lxc_ext4 "$dev"
                        ;;
                    0|"")
                        die "已取消。"
                        ;;
                    *)
                        die "无效选择。"
                        ;;
                esac
                return 0
            fi
            format_disk_as_lxc_ext4 "$dev"
            ;;
        part)
            if [ -z "$fstype" ]; then
                warn "$dev 没有文件系统。"
                read -r -p "如确认格式化，请输入：FORMAT ${dev} : " ack || ack=""
                [ "$ack" = "FORMAT ${dev}" ] || die "确认文本不匹配，已取消格式化。"
                mkfs.ext4 -F -L EasePiR2_LXC "$dev" >&2
                echo "$dev"
            else
                case "$fstype" in
                    ext4|xfs|btrfs) echo "$dev" ;;
                    *) die "$dev 的文件系统是 $fstype，不建议作为 LXC 目录。请备份后格式化为 ext4。" ;;
                esac
            fi
            ;;
        *) die "$dev 不是磁盘或分区。" ;;
    esac
}

mount_lxc_to_ssd() {
    local dev rootdisk pk target uuid tmp mp
    ensure_disk_tools
    list_m2_candidates
    read -r -p "请输入要挂载到 ${LXC_BASE} 的磁盘或分区路径: " dev || dev=""
    [ -b "$dev" ] || die "设备不存在：$dev"

    rootdisk="$(root_parent_disk || true)"
    pk="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1 || true)"
    if [ "$dev" = "$rootdisk" ] || { [ -n "$pk" ] && [ "/dev/$pk" = "$rootdisk" ]; }; then
        die "拒绝操作系统盘 $rootdisk，避免误格式化/误挂载。"
    fi

    target="$(prepare_ext4_target "$dev")"
    [ -b "$target" ] || die "目标设备不可用：$target"

    mkdir -p "$LXC_BASE"
    if findmnt -rn -S "$target" >/dev/null 2>&1; then
        while read -r mp; do
            [ -n "$mp" ] || continue
            if [ "$mp" = "$LXC_BASE" ]; then
                ok "$target 已经挂载到 $LXC_BASE。"
                ensure_dirs
                findmnt "$LXC_BASE" || true
                return 0
            fi
            warn "$target 当前已挂载到 $mp。"
            confirm "是否卸载 $mp 并改挂到 $LXC_BASE？" y || die "已取消。"
            umount "$mp" || die "无法卸载 $mp，请先手动停止占用它的服务。"
        done < <(findmnt -rn -S "$target" -o TARGET 2>/dev/null | sort -r)
    fi

    if findmnt -rn "$LXC_BASE" >/dev/null 2>&1; then
        warn "$LXC_BASE 已经是挂载点。"
        findmnt "$LXC_BASE" || true
        return 0
    fi

    tmp="/mnt/easepi-r2-lxc-ssd"
    mkdir -p "$tmp"
    mount "$target" "$tmp"
    if dir_has_entries "$LXC_BASE" && confirm "$LXC_BASE 已有内容，是否复制到 SSD？" y; then
        rsync -aHAX --numeric-ids "${LXC_BASE}/" "${tmp}/"
    fi
    umount "$tmp"

    uuid="$(blkid -s UUID -o value "$target")"
    [ -n "$uuid" ] || die "无法读取 $target 的 UUID。"
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    grep -vE "[[:space:]]${LXC_BASE//\//\\/}[[:space:]]" /etc/fstab > /tmp/fstab.easepi-r2 || true
    printf 'UUID=%s %s ext4 defaults,noatime 0 2\n' "$uuid" "$LXC_BASE" >> /tmp/fstab.easepi-r2
    install -m 0644 /tmp/fstab.easepi-r2 /etc/fstab
    rm -f /tmp/fstab.easepi-r2

    mount "$LXC_BASE"
    ensure_dirs
    ok "SSD 已挂载到 $LXC_BASE。"
    findmnt "$LXC_BASE" || true
}

persist_current_lxc_mount() {
    local src uuid tmp
    src="$(findmnt -rn "$LXC_BASE" -o SOURCE 2>/dev/null | head -n1 || true)"
    [ -n "$src" ] || { warn "未检测到 $LXC_BASE 的挂载源，已跳过 fstab 修复。"; return 0; }
    case "$src" in
        /dev/*) ;;
        *) warn "$LXC_BASE 当前挂载源是 $src，不是块设备，已跳过 fstab 修复。"; return 0 ;;
    esac
    uuid="$(blkid -s UUID -o value "$src" 2>/dev/null || true)"
    [ -n "$uuid" ] || { warn "无法读取 $src 的 UUID，已跳过 fstab 修复。"; return 0; }

    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    tmp="$(mktemp)"
    grep -vE "[[:space:]]${LXC_BASE//\//\\/}[[:space:]]" /etc/fstab > "$tmp" 2>/dev/null || true
    printf 'UUID=%s %s ext4 defaults,noatime 0 2\n' "$uuid" "$LXC_BASE" >> "$tmp"
    install -m 0644 "$tmp" /etc/fstab
    rm -f "$tmp"
    ok "已修复 /etc/fstab：$src -> $LXC_BASE"
}

write_lxc_service_mount_dropin() {
    mkdir -p /etc/systemd/system/lxc.service.d
    cat > /etc/systemd/system/lxc.service.d/10-easepi-r2-lxcpath.conf <<EOF
[Unit]
RequiresMountsFor=${LXC_BASE} ${CONTAINER_DIR}
After=local-fs.target
EOF
}

infer_lxc_net_info() {
    local cfg="$1"
    awk '
        function trim(s) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            return s
        }
        /^[[:space:]]*lxc\.net\.[0-9]+\.(type|link|name)[[:space:]]*=/ {
            key = $1
            val = $0
            sub(/^[^=]*=/, "", val)
            val = trim(val)
            split(key, a, ".")
            idx = a[3]
            attr = a[4]
            data[idx, attr] = val
            seen[idx] = 1
        }
        END {
            for (idx in seen) {
                if (data[idx, "type"] == "phys" && data[idx, "link"] != "")
                    print "phys " data[idx, "link"]
                if (data[idx, "type"] == "veth" && data[idx, "name"] == "host0" && data[idx, "link"] != "")
                    print "hostbr " data[idx, "link"]
            }
        }
    ' "$cfg"
}

repair_hostnet_from_existing_openwrt() {
    local start_now="${1:-0}"
    local name cfg kind value phys_ifs="" host_br=""
    while read -r name; do
        cfg="$(container_dir_for "$name")/config"
        [ -r "$cfg" ] || continue
        while read -r kind value; do
            [ -n "${kind:-}" ] || continue
            case "$kind" in
                phys)
                    if ! printf ' %s ' "$phys_ifs" | grep -q " ${value} "; then
                        phys_ifs="$(trim "$phys_ifs $value")"
                    fi
                    ;;
                hostbr)
                    host_br="$value"
                    ;;
            esac
        done < <(infer_lxc_net_info "$cfg")
    done < <(container_names)

    if [ -z "$phys_ifs" ] && [ -z "$host_br" ]; then
        warn "未从现有容器配置中识别到 OpenWrt 路由容器的物理网口/宿主桥，已跳过 hostnet 修复。"
        return 0
    fi

    PHYS_IFS="$phys_ifs"
    [ -n "$host_br" ] && HOST_BR="$host_br"
    write_hostnet_service
    write_hostroute_service
    if [ "$start_now" = "1" ]; then
        systemctl start easepi-r2-lxc-hostnet.service >/dev/null 2>&1 || warn "easepi-r2-lxc-hostnet.service 启动失败，请检查物理网口是否存在：$PHYS_IFS"
        ok "已修复并启动 OpenWrt LXC 宿主桥：${HOST_BR}；物理网口：${PHYS_IFS:-无}"
    else
        ok "已修复 OpenWrt LXC 宿主桥服务：${HOST_BR}；物理网口：${PHYS_IFS:-无}（未立即切网启动）"
    fi
}

start_lxc_autostart_now() {
    warn "即将启动 hostnet 和 LXC 自启动容器；OpenWrt 路由容器可能接管物理网口，SSH 可能会断开。"
    confirm "确认现在启动 hostnet 和 LXC 自启动容器" n || { warn "已跳过立即启动；重启后仍会按自启动配置启动。"; return 0; }
    systemctl start easepi-r2-lxc-hostnet.service >/dev/null 2>&1 || warn "easepi-r2-lxc-hostnet.service 启动失败。"
    systemctl restart lxc.service >/dev/null 2>&1 || warn "lxc.service 重启失败。"
    systemctl start easepi-r2-lxc-hostroute.timer >/dev/null 2>&1 || true
    systemctl start easepi-r2-lxc-hostroute.service >/dev/null 2>&1 || true
    ok "已触发 hostnet 和 LXC 自启动容器。"
    list_containers || true
}

ensure_host_ppp_device() {
    modprobe slhc 2>/dev/null || true
    modprobe ppp_generic 2>/dev/null || true
    modprobe pppox 2>/dev/null || true
    modprobe pppoe 2>/dev/null || true
    [ -e /dev/ppp ] || mknod /dev/ppp c 108 0 2>/dev/null || true
    chmod 600 /dev/ppp 2>/dev/null || true
}

restore_lte4g_networkd_files() {
    local disabled_dir="/etc/easepi-r2-lxc-manager/disabled-networkd"
    local f base restored=0

    [ -d "$disabled_dir" ] || return 0
    mkdir -p /etc/systemd/network

    for f in "$disabled_dir"/*lte4g* "$disabled_dir"/*lte-4g*; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        case "$base" in
            *.link|*.network|*.netdev)
                if [ ! -e "/etc/systemd/network/$base" ]; then
                    mv "$f" "/etc/systemd/network/$base" 2>/dev/null || true
                    restored=1
                fi
                ;;
        esac
    done

    if [ "$restored" -eq 1 ]; then
        ok "已恢复 lte4g 的 systemd-networkd 命名/网络规则。"
    fi
}

ensure_openwrt_lxc_ppp_access() {
    local config_file="$1"

    [ -f "$config_file" ] || return 0

    grep -q '^lxc.cgroup.devices.allow = c 108:0 rwm$' "$config_file" || \
        echo 'lxc.cgroup.devices.allow = c 108:0 rwm' >> "$config_file"
    grep -q '^lxc.cgroup2.devices.allow = c 108:0 rwm$' "$config_file" || \
        echo 'lxc.cgroup2.devices.allow = c 108:0 rwm' >> "$config_file"
    grep -q '^lxc.mount.entry = /dev/ppp dev/ppp none bind,create=file,optional' "$config_file" || \
        echo 'lxc.mount.entry = /dev/ppp dev/ppp none bind,create=file,optional' >> "$config_file"
}

repair_openwrt_ppp_access() {
    local config_file changed=0

    ensure_host_ppp_device

    while IFS= read -r config_file; do
        [ -f "$config_file" ] || continue
        grep -Eq '^lxc\.net\.[0-9]+\.name = wan$' "$config_file" || continue
        ensure_openwrt_lxc_ppp_access "$config_file"
        changed=1
    done < <(find "$CONTAINER_DIR" -mindepth 2 -maxdepth 2 -type f -name config 2>/dev/null)

    if [ "$changed" -eq 1 ]; then
        ok "已补齐 OpenWrt LXC PPPoE 所需 /dev/ppp 设备权限。"
    fi
}

repair_lxc_remount() {
    load_config

    echo
    echo "========== 重挂载修复已有 LXC 数据 =========="
    if ! findmnt -rn "$LXC_BASE" >/dev/null 2>&1; then
        warn "$LXC_BASE 当前不是挂载点。请先用“磁盘工具”把 M.2/SSD 挂载到 $LXC_BASE。"
        return 1
    fi

    warn "此修复会重写 /etc/fstab、LXC 配置、自启动配置和容器快捷命令。"
    warn "默认不会立即切网启动容器；最后如选择立即启动，SSH 才可能断开。"
    confirm "确认继续执行重挂载修复" n || { warn "已取消。"; return 0; }

    install_lxc_dependencies || return 1
    ensure_dirs
    persist_current_lxc_mount
    write_lxc_service_mount_dropin
    repair_hostnet_from_existing_openwrt 0
    restore_lte4g_networkd_files
    repair_openwrt_ppp_access
    save_config
    repair_all_container_autostart
    write_all_container_shortcuts

    systemctl daemon-reload || true
    systemctl enable lxcfs.service lxc.service >/dev/null 2>&1 || true
    systemctl start lxcfs.service >/dev/null 2>&1 || true
    ok "LXC 重挂载修复完成；已启用下次开机自启动，但本次未默认启动 LXC 容器。"
    list_containers || true
    start_lxc_autostart_now
}

rebuild_openwrt_host_takeover() {
    load_config

    echo
    echo "========== 重建 OpenWrt 宿主接管配置 =========="
    if ! dir_has_entries "$CONTAINER_DIR"; then
        warn "未发现已有容器目录：$CONTAINER_DIR"
        return 1
    fi

    warn "此操作只重建 OpenWrt 网口接管、hostroute、容器自启动和快捷命令。"
    warn "不会修改 /lxc 挂载、/etc/fstab、LXC 全局路径或 LXC 服务挂载顺序。"
    confirm "确认继续重建宿主接管配置" y || { warn "已取消。"; return 0; }

    repair_hostnet_from_existing_openwrt 0
    restore_lte4g_networkd_files
    repair_openwrt_ppp_access
    save_config
    repair_all_container_autostart
    write_all_container_shortcuts

    systemctl daemon-reload || true
    ok "OpenWrt 宿主接管配置已重建。"
    list_containers || true
    start_lxc_autostart_now
}

lxc_dirs_menu() {
    local choice
    while true; do
        echo
        echo "========== LXC 目录管理 =========="
        echo "1. 查看当前目录"
        echo "2. 修改 LXC 根目录"
        echo "3. 磁盘工具：检测 M.2/SSD 并挂载到 LXC 根目录"
        echo "4. 重挂载修复已有 LXC 数据"
        echo "5. 重建 OpenWrt 宿主接管配置"
        echo "0. 返回"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1) show_lxc_dirs; pause_enter ;;
            2) set_lxc_dirs; pause_enter ;;
            3) mount_lxc_to_ssd; pause_enter ;;
            4) repair_lxc_remount; pause_enter ;;
            5) rebuild_openwrt_host_takeover; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

ip_to_int() {
    local ip="$1"
    local a b c d
    IFS=. read -r a b c d <<EOF
$ip
EOF
    case "${a:-}.${b:-}.${c:-}.${d:-}" in *[!0-9.]*|.*|*.) return 1 ;; esac
    [ "$a" -ge 0 ] && [ "$a" -le 255 ] || return 1
    [ "$b" -ge 0 ] && [ "$b" -le 255 ] || return 1
    [ "$c" -ge 0 ] && [ "$c" -le 255 ] || return 1
    [ "$d" -ge 0 ] && [ "$d" -le 255 ] || return 1
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

prefix_to_netmask() {
    local prefix="$1"
    local mask
    [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
    if [ "$prefix" -eq 0 ]; then
        mask=0
    else
        mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    fi
    int_to_ip "$mask"
}

split_cidr() {
    local cidr="$1"
    case "$cidr" in
        */*) echo "${cidr%/*} ${cidr#*/}" ;;
        *) return 1 ;;
    esac
}

normalize_if_list() {
    local raw="$1"
    local out="" item
    raw="$(printf '%s' "$raw" | tr ',，;' '   ')"
    raw="$(trim "$raw")"
    [ "$raw" = "none" ] && { echo ""; return 0; }
    for item in $raw; do
        ip link show "$item" >/dev/null 2>&1 || warn "未检测到网口 $item，仍会写入配置。"
        if ! printf ' %s ' "$out" | grep -q " ${item} "; then
            out="$(trim "$out $item")"
        fi
    done
    echo "$out"
}

default_existing_ifs() {
    local out="" item
    for item in $CANDIDATE_IFS; do
        if ip link show "$item" >/dev/null 2>&1; then
            out="$(trim "$out $item")"
        fi
    done
    echo "$out"
}

collect_openwrt_network_config() {
    local existing default_wan default_lan raw_wan raw_lan raw_cidr cidr_ip prefix net_int open_int host_int dhcp_start_int dhcp_end_int
    existing="$(default_existing_ifs)"
    default_wan="eth0"
    default_lan="eth1 eth2 eth3"
    if [ -n "$existing" ]; then
        printf ' %s ' "$existing" | grep -q ' eth0 ' || default_wan="none"
        default_lan=""
        for i in eth1 eth2 eth3; do
            printf ' %s ' "$existing" | grep -q " $i " && default_lan="$(trim "$default_lan $i")"
        done
        [ -n "$default_lan" ] || default_lan="eth1 eth2 eth3"
    fi

    echo
    echo "========== OpenWrt 路由容器网络规划 =========="
    echo "WAN 物理口会直通给 OpenWrt；LAN 物理口也会直通给 OpenWrt。"
    echo "宿主机通过 ${HOST_BR}/host0 接到 OpenWrt LAN。"
    echo
    raw_wan="$(read_default "OpenWrt WAN 口，填 none 表示暂不设置 WAN" "$default_wan")"
    raw_lan="$(read_default "OpenWrt LAN 口，多个网口用空格隔开" "$default_lan")"
    LAN_CIDR="$(read_default "OpenWrt LAN 网段" "$LAN_CIDR")"

    WAN_IF="$(normalize_if_list "$raw_wan")"
    [ -z "$WAN_IF" ] && WAN_IF="none"
    if [[ "$WAN_IF" == *" "* ]]; then
        die "WAN 口只能有一个。"
    fi
    LAN_IFS="$(normalize_if_list "$raw_lan")"
    [ -n "$LAN_IFS" ] || die "LAN 口不能为空。"

    read -r cidr_ip prefix < <(split_cidr "$LAN_CIDR")
    [ -n "${cidr_ip:-}" ] && [ -n "${prefix:-}" ] || die "LAN_CIDR 格式错误。"
    LAN_NETMASK="$(prefix_to_netmask "$prefix")"
    net_int="$(ip_to_int "$cidr_ip")"

    OPENWRT_IP="$(read_default "OpenWrt LAN IP" "$OPENWRT_IP")"
    HOST_IP="$(read_default "宿主机在 OpenWrt LAN 下的 IP" "$HOST_IP")"
    HOST_IP_CIDR="${HOST_IP}/${prefix}"
    DHCP_START_IP="$(read_default "OpenWrt DHCP 起始 IP" "$DHCP_START_IP")"
    DHCP_END_IP="$(read_default "OpenWrt DHCP 结束 IP" "$DHCP_END_IP")"

    open_int="$(ip_to_int "$OPENWRT_IP")"
    host_int="$(ip_to_int "$HOST_IP")"
    dhcp_start_int="$(ip_to_int "$DHCP_START_IP")"
    dhcp_end_int="$(ip_to_int "$DHCP_END_IP")"
    [ "$dhcp_start_int" -le "$dhcp_end_int" ] || die "DHCP 起始 IP 不能大于结束 IP。"
    [ "$open_int" != "$host_int" ] || die "OpenWrt IP 不能和宿主机 IP 相同。"

    DHCP_START_OFFSET=$(( dhcp_start_int - net_int ))
    DHCP_LIMIT=$(( dhcp_end_int - dhcp_start_int + 1 ))
    [ "$DHCP_START_OFFSET" -gt 0 ] || die "DHCP 起始 IP 不在 LAN 网段内。"
    [ "$DHCP_LIMIT" -gt 0 ] || die "DHCP 地址池错误。"

    PHYS_IFS="$(trim "$WAN_IF $LAN_IFS")"
    [ "$WAN_IF" = "none" ] && PHYS_IFS="$LAN_IFS"

    save_config
}

cleanup_host_openwrt_lan_conflicts() {
    local dev cidr
    if [ "$HOST_BR" != "br-lan" ] && ip link show br-lan >/dev/null 2>&1; then
        log "清理宿主残留 br-lan，避免占用 OpenWrt 网关 ${OPENWRT_IP}..."
        ip addr flush dev br-lan 2>/dev/null || true
        ip link set br-lan down 2>/dev/null || true
        ip link delete br-lan type bridge 2>/dev/null || ip link delete br-lan 2>/dev/null || true
    fi
    ip -o -4 addr show | awk -v target="$OPENWRT_IP" '{ split($4, a, "/"); if (a[1] == target) print $2, $4 }' | while read -r dev cidr; do
        [ -n "$dev" ] || continue
        dev="${dev%%@*}"
        ip addr del "$cidr" dev "$dev" 2>/dev/null || true
    done
}

write_hostnet_service() {
    cat > /usr/local/sbin/easepi-r2-lxc-hostnet.sh <<EOF
#!/bin/sh
set -eu

PHYS_IFS="${PHYS_IFS}"
HOST_BR="${HOST_BR}"
HOST_IP_CIDR="${HOST_IP_CIDR}"
OPENWRT_IP="${OPENWRT_IP}"

log() { echo "[easepi-r2-lxc-hostnet] \$*"; }

restore_lte4g_networkd_files() {
    local disabled_dir="/etc/easepi-r2-lxc-manager/disabled-networkd"
    local f base

    [ -d "\$disabled_dir" ] || return 0
    mkdir -p /etc/systemd/network

    for f in "\$disabled_dir"/*lte4g* "\$disabled_dir"/*lte-4g*; do
        [ -e "\$f" ] || continue
        base="\$(basename "\$f")"
        case "\$base" in
            *.link|*.network|*.netdev)
                if [ ! -e "/etc/systemd/network/\$base" ]; then
                    mv "\$f" "/etc/systemd/network/\$base" 2>/dev/null || true
                    log "restore LTE networkd file: \$base"
                fi
                ;;
        esac
    done
}

log "stop host network services that may own OpenWrt NICs..."
systemctl stop dnsmasq.service nftables.service NetworkManager.service NetworkManager-wait-online.service systemd-networkd.service lxc-net.service 2>/dev/null || true
systemctl disable dnsmasq.service nftables.service NetworkManager.service NetworkManager-wait-online.service systemd-networkd.service lxc-net.service 2>/dev/null || true

if [ -d /etc/systemd/network ]; then
    mkdir -p /etc/easepi-r2-lxc-manager/disabled-networkd
    for f in /etc/systemd/network/*easepi-r2*.network /etc/systemd/network/*easepi-r2*.netdev /etc/systemd/network/*easepi-r2*.link /etc/systemd/network/*r2-br-lan* /etc/systemd/network/*r2-lan-*; do
        [ -e "\$f" ] || continue
        base="\$(basename "\$f")"
        case "\$base" in
            *lte4g*|*lte-4g*)
                continue
                ;;
        esac
        mv "\$f" "/etc/easepi-r2-lxc-manager/disabled-networkd/\$base" 2>/dev/null || true
    done
    restore_lte4g_networkd_files
fi

for mod in bridge br_netfilter veth tun overlay nf_tables nf_conntrack nf_nat nft_chain_nat nft_masq nft_redir x_tables ip_tables iptable_nat iptable_mangle xt_MASQUERADE xt_REDIRECT xt_conntrack; do
    modprobe "\$mod" 2>/dev/null || true
done

mkdir -p /dev/net
[ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true
chmod 666 /dev/net/tun 2>/dev/null || true
modprobe slhc 2>/dev/null || true
modprobe ppp_generic 2>/dev/null || true
modprobe pppox 2>/dev/null || true
modprobe pppoe 2>/dev/null || true
[ -e /dev/ppp ] || mknod /dev/ppp c 108 0 2>/dev/null || true
chmod 600 /dev/ppp 2>/dev/null || true

if [ "\$HOST_BR" != "br-lan" ] && ip link show br-lan >/dev/null 2>&1; then
    log "remove stale host br-lan..."
    ip addr flush dev br-lan 2>/dev/null || true
    ip link set br-lan down 2>/dev/null || true
    ip link delete br-lan type bridge 2>/dev/null || ip link delete br-lan 2>/dev/null || true
fi

ip -o -4 addr show | awk -v target="\$OPENWRT_IP" '{ split(\$4, a, "/"); if (a[1] == target) print \$2, \$4 }' | while read -r DEV CIDR; do
    [ -n "\$DEV" ] || continue
    DEV="\${DEV%%@*}"
    ip addr del "\$CIDR" dev "\$DEV" 2>/dev/null || true
done

log "prepare bridge \$HOST_BR with \$HOST_IP_CIDR..."
ip link show "\$HOST_BR" >/dev/null 2>&1 || ip link add "\$HOST_BR" type bridge
ip link set "\$HOST_BR" up
ip addr replace "\$HOST_IP_CIDR" dev "\$HOST_BR"
ip link set dev "\$HOST_BR" type bridge stp_state 0 2>/dev/null || true

log "release selected NICs to OpenWrt LXC: \$PHYS_IFS"
for IF in \$PHYS_IFS; do
    [ "\$IF" = "none" ] && continue
    if ip link show "\$IF" >/dev/null 2>&1; then
        ip addr flush dev "\$IF" 2>/dev/null || true
        ip link set "\$IF" down 2>/dev/null || true
    else
        log "skip missing iface: \$IF"
    fi
done

log "done."
EOF
    chmod +x /usr/local/sbin/easepi-r2-lxc-hostnet.sh

    cat > /etc/systemd/system/easepi-r2-lxc-hostnet.service <<'EOF'
[Unit]
Description=Prepare EasePi-R2 host bridge and NICs for OpenWrt LXC
DefaultDependencies=yes
After=network.target
Before=lxc.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/easepi-r2-lxc-hostnet.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p /etc/systemd/system/lxc.service.d
    cat > /etc/systemd/system/lxc.service.d/override.conf <<'EOF'
[Unit]
Requires=easepi-r2-lxc-hostnet.service
After=easepi-r2-lxc-hostnet.service
EOF
    systemctl daemon-reload
    systemctl enable easepi-r2-lxc-hostnet.service >/dev/null 2>&1 || true
}

write_hostroute_service() {
    cat > /usr/local/sbin/easepi-r2-lxc-hostroute.sh <<EOF
#!/bin/sh
set -eu

HOST_BR="${HOST_BR}"
OPENWRT_IP="${OPENWRT_IP}"
ROUTE_ENABLE="${HOST_OPENWRT_ROUTE_ENABLE}"
ROUTE_METRIC="${HOST_OPENWRT_ROUTE_METRIC}"
CHECK_IP="${HOST_OPENWRT_ROUTE_CHECK_IP}"

log() { echo "[easepi-r2-lxc-hostroute] \$*"; }

remove_openwrt_default() {
    ip route del default via "\$OPENWRT_IP" dev "\$HOST_BR" 2>/dev/null || true
}

remove_openwrt_dns() {
    if [ -f /etc/systemd/resolved.conf.d/easepi-r2-openwrt.conf ]; then
        rm -f /etc/systemd/resolved.conf.d/easepi-r2-openwrt.conf
        systemctl restart systemd-resolved.service >/dev/null 2>&1 || true
    elif [ ! -L /etc/resolv.conf ] && grep -q "nameserver[[:space:]]\+\$OPENWRT_IP" /etc/resolv.conf 2>/dev/null; then
        cat > /etc/resolv.conf <<DNS
nameserver 223.5.5.5
nameserver 119.29.29.29
DNS
    fi
}

case "\$ROUTE_ENABLE" in
    0|off|OFF|no|NO|false|FALSE|disabled|DISABLED)
        log "OpenWrt preferred host route disabled; remove managed route."
        remove_openwrt_default
        remove_openwrt_dns
        exit 0
        ;;
esac

case "\$ROUTE_METRIC" in
    ""|*[!0-9]*) ROUTE_METRIC=300 ;;
esac

case "\$CHECK_IP" in
    ""|*[!0-9.]*) CHECK_IP="" ;;
esac

if ! ip link show "\$HOST_BR" >/dev/null 2>&1; then
    log "bridge \$HOST_BR is missing; keep existing fallback routes."
    remove_openwrt_default
    remove_openwrt_dns
    exit 0
fi

ip link set "\$HOST_BR" up 2>/dev/null || true

if ! ping -c 1 -W 1 "\$OPENWRT_IP" >/dev/null 2>&1; then
    log "OpenWrt gateway \$OPENWRT_IP is unreachable; fall back to other default route."
    remove_openwrt_default
    remove_openwrt_dns
    exit 0
fi

if [ -n "\$CHECK_IP" ]; then
    ip route replace "\$CHECK_IP/32" via "\$OPENWRT_IP" dev "\$HOST_BR" metric "\$ROUTE_METRIC" 2>/dev/null || true
    if ! ping -c 1 -W 2 "\$CHECK_IP" >/dev/null 2>&1; then
        log "OpenWrt gateway is reachable, but internet check \$CHECK_IP failed; fall back to other default route."
        ip route del "\$CHECK_IP/32" via "\$OPENWRT_IP" dev "\$HOST_BR" 2>/dev/null || true
        remove_openwrt_default
        remove_openwrt_dns
        exit 0
    fi
    ip route del "\$CHECK_IP/32" via "\$OPENWRT_IP" dev "\$HOST_BR" 2>/dev/null || true
fi

ip route replace default via "\$OPENWRT_IP" dev "\$HOST_BR" metric "\$ROUTE_METRIC"

if systemctl list-unit-files systemd-resolved.service --no-legend 2>/dev/null | grep -q '^systemd-resolved\.service'; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/easepi-r2-openwrt.conf <<DNS
[Resolve]
DNS=\$OPENWRT_IP
FallbackDNS=223.5.5.5 119.29.29.29
DNSDefaultRoute=yes
DNS
    systemctl restart systemd-resolved.service >/dev/null 2>&1 || true
elif [ ! -L /etc/resolv.conf ]; then
    cat > /etc/resolv.conf <<DNS
nameserver \$OPENWRT_IP
nameserver 223.5.5.5
nameserver 119.29.29.29
DNS
fi

log "default route prefers OpenWrt: via \$OPENWRT_IP dev \$HOST_BR metric \$ROUTE_METRIC."
EOF
    chmod +x /usr/local/sbin/easepi-r2-lxc-hostroute.sh

    cat > /etc/systemd/system/easepi-r2-lxc-hostroute.service <<'EOF'
[Unit]
Description=Prefer OpenWrt LXC as EasePi-R2 host default route when healthy
After=easepi-r2-lxc-hostnet.service lxc.service
Wants=easepi-r2-lxc-hostnet.service lxc.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/easepi-r2-lxc-hostroute.sh

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/easepi-r2-lxc-hostroute.timer <<'EOF'
[Unit]
Description=Re-check EasePi-R2 OpenWrt preferred host default route

[Timer]
OnBootSec=30sec
OnUnitActiveSec=60sec
AccuracySec=10sec
Unit=easepi-r2-lxc-hostroute.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable easepi-r2-lxc-hostroute.timer >/dev/null 2>&1 || true
}

write_openwrt_net_tune_service() {
    local name="$1"

    case "$OPENWRT_NET_TUNE_ENABLE" in
        0|off|OFF|no|NO|false|FALSE|disabled|DISABLED)
            systemctl disable --now easepi-r2-lxc-openwrt-net-tune.service >/dev/null 2>&1 || true
            warn "OpenWrt 网络性能调优已按配置禁用。"
            return 0
            ;;
    esac

    mkdir -p /etc/default
    {
        printf 'TUNE_ENABLE=%q\n' "$OPENWRT_NET_TUNE_ENABLE"
        printf 'CT_NAME=%q\n' "$name"
        printf 'CONTAINER_DIR=%q\n' "$CONTAINER_DIR"
        printf 'WAN_IRQ_CPU=%q\n' "$OPENWRT_NET_TUNE_WAN_IRQ_CPU"
        printf 'LAN_IRQ_CPUS=%q\n' "$OPENWRT_NET_TUNE_LAN_IRQ_CPUS"
        printf 'RPS_CPUS=%q\n' "$OPENWRT_NET_TUNE_RPS_CPUS"
        printf 'RPS_FLOW_CNT=%q\n' "$OPENWRT_NET_TUNE_RPS_FLOW_CNT"
        printf 'CPU_GOVERNOR=%q\n' "$OPENWRT_NET_TUNE_CPU_GOVERNOR"
    } > /etc/default/easepi-r2-lxc-openwrt-net-tune

    cat > /usr/local/sbin/easepi-r2-lxc-openwrt-net-tune.sh <<'EOF'
#!/bin/sh
set -eu

ENV_FILE="/etc/default/easepi-r2-lxc-openwrt-net-tune"
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

: "${TUNE_ENABLE:=1}"
: "${CT_NAME:?missing CT_NAME}"
: "${CONTAINER_DIR:=/lxc/containers}"
: "${WAN_IRQ_CPU:=6}"
: "${LAN_IRQ_CPUS:=7 5 4}"
: "${RPS_CPUS:=f0}"
: "${RPS_FLOW_CNT:=4096}"
: "${CPU_GOVERNOR:=performance}"

LXC_CONFIG="${CONTAINER_DIR}/${CT_NAME}/config"

log() { echo "[easepi-r2-openwrt-net-tune] $*"; }

is_uint() {
    case "${1:-}" in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

cpu_mask() {
    local cpu="$1"

    case "$cpu" in
        0x*|0X*) printf '%s\n' "$cpu"; return 0 ;;
    esac
    is_uint "$cpu" || return 1
    awk -v cpu="$cpu" 'BEGIN {
        if (cpu < 0 || cpu > 63) exit 1
        v = 1
        for (i = 0; i < cpu; i++) v *= 2
        printf "%x\n", v
    }'
}

set_cpu_governor() {
    local governor_file

    [ -n "$CPU_GOVERNOR" ] || return 0
    for governor_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -e "$governor_file" ] || continue
        if [ -w "$governor_file" ]; then
            printf '%s\n' "$CPU_GOVERNOR" > "$governor_file" 2>/dev/null || true
        fi
    done
    log "CPU governor target: $CPU_GOVERNOR"
}

config_value() {
    local key="$1"

    [ -r "$LXC_CONFIG" ] || return 0
    awk -F= -v want="$key" '
    function trim(s) {
        sub(/^[ \t\r\n]+/, "", s)
        sub(/[ \t\r\n]+$/, "", s)
        return s
    }
    {
        k = trim($1)
        if (k == want) {
            v = $0
            sub(/^[^=]*=/, "", v)
            print trim(v)
        }
    }' "$LXC_CONFIG" | tail -n 1
}

phys_indexes() {
    [ -r "$LXC_CONFIG" ] || return 0
    awk -F= '
    function trim(s) {
        sub(/^[ \t\r\n]+/, "", s)
        sub(/[ \t\r\n]+$/, "", s)
        return s
    }
    {
        k = trim($1)
        v = trim($2)
        if (k ~ /^lxc\.net\.[0-9]+\.type$/ && v == "phys") {
            sub(/^lxc\.net\./, "", k)
            sub(/\.type$/, "", k)
            print k
        }
    }' "$LXC_CONFIG" | sort -n
}

find_irqs_for_labels() {
    local label_a="$1"
    local label_b="${2:-}"

    awk -v a="$label_a" -v b="$label_b" '
    function label_match(line, label, start, rel, pos, before, after) {
        if (label == "") return 0
        start = 1
        while (start <= length(line)) {
            rel = index(substr(line, start), label)
            if (rel == 0) return 0
            pos = start + rel - 1
            before = (pos <= 1) ? " " : substr(line, pos - 1, 1)
            after = substr(line, pos + length(label), 1)
            if (before !~ /[[:alnum:]_]/ && after !~ /[[:alnum:]_]/) return 1
            start = pos + 1
        }
        return 0
    }
    /^[[:space:]]*[0-9]+:/ {
        irq = $1
        sub(/:/, "", irq)
        if (label_match($0, a) || label_match($0, b)) print irq
    }' /proc/interrupts | sort -n -u
}

lan_cpu_for() {
    local lan_no="$1"
    local idx=1
    local cpu
    local last=""

    is_uint "$lan_no" || lan_no=1
    for cpu in $LAN_IRQ_CPUS; do
        last="$cpu"
        if [ "$idx" -eq "$lan_no" ]; then
            printf '%s\n' "$cpu"
            return 0
        fi
        idx=$((idx + 1))
    done
    if [ -n "$last" ]; then
        printf '%s\n' "$last"
    else
        printf '%s\n' "$WAN_IRQ_CPU"
    fi
}

set_irq_cpu() {
    local irq="$1"
    local cpu="$2"
    local mask path

    mask="$(cpu_mask "$cpu")" || {
        log "skip IRQ $irq: invalid CPU target $cpu"
        return 0
    }
    path="/proc/irq/${irq}/smp_affinity"
    if [ ! -w "$path" ]; then
        log "skip IRQ $irq: $path is not writable"
        return 0
    fi
    if printf '%s\n' "$mask" > "$path" 2>/dev/null; then
        log "IRQ $irq -> CPU $cpu (mask $mask)"
    else
        log "failed to write IRQ $irq affinity"
    fi
}

tune_irqs() {
    local idx ct_if host_if cpu lan_no irqs irq

    if [ ! -r "$LXC_CONFIG" ]; then
        log "skip IRQ tuning: missing LXC config $LXC_CONFIG"
        return 0
    fi

    for idx in $(phys_indexes); do
        ct_if="$(config_value "lxc.net.${idx}.name")"
        host_if="$(config_value "lxc.net.${idx}.link")"
        [ -n "$ct_if" ] || continue

        case "$ct_if" in
            wan)
                cpu="$WAN_IRQ_CPU"
                ;;
            lan[0-9]*)
                lan_no="${ct_if#lan}"
                cpu="$(lan_cpu_for "$lan_no")"
                ;;
            *)
                continue
                ;;
        esac

        irqs="$(find_irqs_for_labels "$ct_if" "$host_if")"
        if [ -z "$irqs" ]; then
            log "no IRQ matched for $ct_if (${host_if:-unknown host iface})"
            continue
        fi
        for irq in $irqs; do
            set_irq_cpu "$irq" "$cpu"
        done
    done
}

wait_container_running() {
    local i=0

    while [ "$i" -lt 30 ]; do
        if lxc-info -P "$CONTAINER_DIR" -n "$CT_NAME" -s 2>/dev/null | grep -q RUNNING; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

tune_container_rps() {
    [ -n "$RPS_CPUS" ] || return 0
    if ! command -v lxc-attach >/dev/null 2>&1; then
        log "skip container RPS: lxc-attach is missing"
        return 0
    fi
    if ! wait_container_running; then
        log "skip container RPS: $CT_NAME is not running"
        return 0
    fi

    if ! lxc-attach -P "$CONTAINER_DIR" -n "$CT_NAME" -- sh -s <<EOF_RPS
RPS_CPUS="$RPS_CPUS"
RPS_FLOW_CNT="$RPS_FLOW_CNT"

log() { echo "[easepi-r2-openwrt-net-tune:ct] \$*"; }

case "\$RPS_FLOW_CNT" in
    ""|*[!0-9]*) RPS_FLOW_CNT=0 ;;
esac

if [ "\$RPS_FLOW_CNT" -gt 0 ] && [ -w /proc/sys/net/core/rps_sock_flow_entries ]; then
    printf '%s\n' "\$RPS_FLOW_CNT" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
fi

set_rps_dev() {
    dev="\$1"
    base="/sys/class/net/\$dev/queues"
    changed=0
    [ -d "\$base" ] || return 0

    for rxq in "\$base"/rx-*; do
        [ -d "\$rxq" ] || continue
        if [ -w "\$rxq/rps_cpus" ]; then
            printf '%s\n' "\$RPS_CPUS" > "\$rxq/rps_cpus" 2>/dev/null && changed=1 || true
        else
            log "skip \$dev \$(basename "\$rxq") rps_cpus: read-only"
        fi

        if [ "\$RPS_FLOW_CNT" -gt 0 ] && [ -w "\$rxq/rps_flow_cnt" ]; then
            printf '%s\n' "\$RPS_FLOW_CNT" > "\$rxq/rps_flow_cnt" 2>/dev/null || true
        fi
    done

    [ "\$changed" -eq 1 ] && log "RPS \$dev -> \$RPS_CPUS flow_cnt=\$RPS_FLOW_CNT"
}

for dev in br-lan pppoe-wan wan lan1 lan2 lan3 lan4 host0; do
    set_rps_dev "\$dev"
done
EOF_RPS
    then
        log "container RPS tuning failed"
    fi
}

detect_flow_offload_modules() {
    local mod

    for mod in nf_flow_table nft_flow_offload; do
        if grep -qw "$mod" /proc/modules 2>/dev/null || { command -v modprobe >/dev/null 2>&1 && modprobe -n "$mod" >/dev/null 2>&1; }; then
            log "flow offload module available: $mod (firewall offload is not enabled by this script)"
        else
            log "flow offload module not found: $mod"
        fi
    done
}

case "$TUNE_ENABLE" in
    0|off|OFF|no|NO|false|FALSE|disabled|DISABLED)
        log "disabled by TUNE_ENABLE=$TUNE_ENABLE"
        exit 0
        ;;
esac

detect_flow_offload_modules
set_cpu_governor
tune_irqs
tune_container_rps
log "done."
EOF
    chmod +x /usr/local/sbin/easepi-r2-lxc-openwrt-net-tune.sh

    cat > /etc/systemd/system/easepi-r2-lxc-openwrt-net-tune.service <<'EOF'
[Unit]
Description=Tune EasePi-R2 OpenWrt LXC IRQ and RPS
After=easepi-r2-lxc-hostnet.service lxc.service
Wants=easepi-r2-lxc-hostnet.service lxc.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/easepi-r2-lxc-openwrt-net-tune
ExecStart=/usr/local/sbin/easepi-r2-lxc-openwrt-net-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable easepi-r2-lxc-openwrt-net-tune.service >/dev/null 2>&1 || true
}

write_openwrt_lxc_config() {
    local name="$1"
    local rootfs_dir="$2"
    local config_dir="$3"
    local net_idx=0
    local lan_idx=1
    local iface

    ensure_host_ppp_device

    cat > "${config_dir}/config" <<EOF
lxc.rootfs.path = dir:${rootfs_dir}
lxc.uts.name = ${name}
lxc.include = /usr/share/lxc/config/common.conf
lxc.mount.auto = proc:mixed sys:mixed cgroup:mixed
lxc.apparmor.profile = unconfined
lxc.cap.drop =
lxc.start.auto = 1
lxc.start.order = 10
lxc.start.delay = 5
lxc.tty.max = 4
lxc.pty.max = 1024
lxc.cgroup.devices.allow = c 10:200 rwm
lxc.cgroup2.devices.allow = c 10:200 rwm
lxc.cgroup.devices.allow = c 108:0 rwm
lxc.cgroup2.devices.allow = c 108:0 rwm
lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file,optional
lxc.mount.entry = /dev/ppp dev/ppp none bind,create=file,optional
lxc.mount.entry = /lib/modules lib/modules none ro,bind,optional,create=dir
EOF

    if [ "$WAN_IF" != "none" ]; then
        cat >> "${config_dir}/config" <<EOF

lxc.net.${net_idx}.type = phys
lxc.net.${net_idx}.link = ${WAN_IF}
lxc.net.${net_idx}.name = wan
lxc.net.${net_idx}.flags = up
EOF
        net_idx=$((net_idx + 1))
    fi

    for iface in $LAN_IFS; do
        cat >> "${config_dir}/config" <<EOF

lxc.net.${net_idx}.type = phys
lxc.net.${net_idx}.link = ${iface}
lxc.net.${net_idx}.name = lan${lan_idx}
lxc.net.${net_idx}.flags = up
EOF
        net_idx=$((net_idx + 1))
        lan_idx=$((lan_idx + 1))
    done

    cat >> "${config_dir}/config" <<EOF

lxc.net.${net_idx}.type = veth
lxc.net.${net_idx}.link = ${HOST_BR}
lxc.net.${net_idx}.name = host0
lxc.net.${net_idx}.hwaddr = $(stable_lxc_mac "$name" host0)
lxc.net.${net_idx}.flags = up
EOF
}

configure_openwrt_rootfs() {
    local rootfs_dir="$1"
    local lan_idx=1
    local dev lan_ports
    mkdir -p "${rootfs_dir}/etc/config"

    lan_ports=""
    for dev in $LAN_IFS; do
        lan_ports="${lan_ports} lan${lan_idx}"
        lan_idx=$((lan_idx + 1))
    done

    {
        cat <<EOF
config interface 'loopback'
        option device 'lo'
        option proto 'static'
        option ipaddr '127.0.0.1'
        option netmask '255.0.0.0'

config globals 'globals'
        option ula_prefix 'fd10:10:10::/48'

config device
        option name 'br-lan'
        option type 'bridge'
EOF
        for dev in $lan_ports; do
            echo "        list ports '${dev}'"
        done
        echo "        list ports 'host0'"
        cat <<EOF

config interface 'lan'
        option device 'br-lan'
        option proto 'static'
        option ipaddr '${OPENWRT_IP}'
        option netmask '${LAN_NETMASK}'
        option ip6assign '60'
EOF
        if [ "$WAN_IF" != "none" ]; then
            cat <<'EOF'

config device 'wan_dev'
        option name 'wan'
        option autoneg '1'

config interface 'wan'
        option device 'wan'
        option proto 'dhcp'

config interface 'wan6'
        option device 'wan'
        option proto 'dhcpv6'
EOF
        fi
    } > "${rootfs_dir}/etc/config/network"

    if [ "$WAN_IF" != "none" ]; then
        mkdir -p "${rootfs_dir}/etc/hotplug.d/net"
        cat > "${rootfs_dir}/etc/hotplug.d/net/10-wan-autoneg" <<'EOF'
#!/bin/sh

case "$ACTION" in
    add|move|register|online) ;;
    *) exit 0 ;;
esac

[ "$DEVICENAME" = "wan" ] || exit 0
command -v ethtool >/dev/null 2>&1 || exit 0

(
    sleep 2
    ethtool -s wan autoneg on >/dev/null 2>&1 || exit 0
    logger -t wan-autoneg "enabled auto-negotiation on wan"
) &
EOF
        chmod +x "${rootfs_dir}/etc/hotplug.d/net/10-wan-autoneg"
    fi

    {
        cat <<'EOF'
{
        "model": {
                "id": "easepi-r2,lxc-openwrt",
                "name": "EasePi R2 LXC OpenWrt"
        },
        "network": {
                "lan": {
                        "ports": [
EOF
        lan_idx=0
        for dev in $lan_ports; do
            [ "$lan_idx" -eq 0 ] || printf ',\n'
            printf '                                "%s"' "$dev"
            lan_idx=$((lan_idx + 1))
        done
        printf '\n'
        cat <<'EOF'
                        ],
                        "protocol": "static"
EOF
        if [ "$WAN_IF" != "none" ]; then
            cat <<'EOF'
                },
                "wan": {
                        "device": "wan",
                        "protocol": "dhcp"
                }
EOF
        else
            cat <<'EOF'
                }
EOF
        fi
        cat <<'EOF'
        }
}
EOF
    } > "${rootfs_dir}/etc/board.json"

    cat > "${rootfs_dir}/etc/config/dhcp" <<EOF
config dnsmasq
        option domainneeded '1'
        option boguspriv '1'
        option localise_queries '1'
        option rebind_protection '1'
        option rebind_localhost '1'
        option local '/lan/'
        option domain 'lan'
        option expandhosts '1'
        option authoritative '1'
        option readethers '1'
        option leasefile '/tmp/dhcp.leases'
        option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'

config dhcp 'lan'
        option interface 'lan'
        option start '${DHCP_START_OFFSET}'
        option limit '${DHCP_LIMIT}'
        option leasetime '12h'
        option dhcpv4 'server'
        option dhcpv6 'server'
        option ra 'server'
EOF
    if [ "$WAN_IF" != "none" ]; then
        cat >> "${rootfs_dir}/etc/config/dhcp" <<'EOF'

config dhcp 'wan'
        option interface 'wan'
        option ignore '1'
EOF
    fi
    cat >> "${rootfs_dir}/etc/config/dhcp" <<'EOF'

config odhcpd 'odhcpd'
        option maindhcp '0'
        option leasefile '/tmp/hosts/odhcpd'
        option leasetrigger '/usr/sbin/odhcpd-update'
        option loglevel '4'
EOF

    cat > "${rootfs_dir}/etc/config/firewall" <<'EOF'
config defaults
        option input 'ACCEPT'
        option output 'ACCEPT'
        option forward 'REJECT'
        option synflood_protect '1'

config zone
        option name 'lan'
        list network 'lan'
        option input 'ACCEPT'
        option output 'ACCEPT'
        option forward 'ACCEPT'
EOF
    if [ "$WAN_IF" != "none" ]; then
        cat >> "${rootfs_dir}/etc/config/firewall" <<'EOF'

config zone
        option name 'wan'
        list network 'wan'
        list network 'wan6'
        option input 'REJECT'
        option output 'ACCEPT'
        option forward 'REJECT'
        option masq '1'
        option mtu_fix '1'

config forwarding
        option src 'lan'
        option dest 'wan'

config rule
        option name 'Allow-DHCP-Renew'
        option src 'wan'
        option proto 'udp'
        option dest_port '68'
        option target 'ACCEPT'
        option family 'ipv4'

config rule
        option name 'Allow-Ping'
        option src 'wan'
        option proto 'icmp'
        option icmp_type 'echo-request'
        option family 'ipv4'
        option target 'ACCEPT'

config rule
        option name 'Allow-DHCPv6'
        option src 'wan'
        option proto 'udp'
        option dest_port '546'
        option family 'ipv6'
        option target 'ACCEPT'

config rule
        option name 'Allow-ICMPv6-Input'
        option src 'wan'
        option proto 'icmp'
        list icmp_type 'echo-request'
        list icmp_type 'echo-reply'
        list icmp_type 'destination-unreachable'
        list icmp_type 'packet-too-big'
        list icmp_type 'time-exceeded'
        list icmp_type 'bad-header'
        list icmp_type 'unknown-header-type'
        list icmp_type 'router-solicitation'
        list icmp_type 'neighbour-solicitation'
        list icmp_type 'router-advertisement'
        list icmp_type 'neighbour-advertisement'
        option limit '1000/sec'
        option family 'ipv6'
        option target 'ACCEPT'
EOF
    fi
}

write_openwrt_finalizer() {
    local name="$1"
    cat > /usr/local/sbin/easepi-r2-lxc-openwrt-finalize.sh <<EOF
#!/bin/sh
set -eu

CT_NAME="${name}"
CONTAINER_DIR="${CONTAINER_DIR}"
HOST_BR="${HOST_BR}"
OPENWRT_IP="${OPENWRT_IP}"
LOG="/var/log/easepi-r2-lxc-openwrt-finalize.log"

exec >>"\$LOG" 2>&1
printf '===== OpenWrt LXC finalize start: %s =====\n' "\$(date '+%F %T')"

systemctl restart easepi-r2-lxc-hostnet.service
systemctl start easepi-r2-lxc-hostroute.timer >/dev/null 2>&1 || true

if lxc-info -P "\$CONTAINER_DIR" -n "\$CT_NAME" -s 2>/dev/null | grep -q RUNNING; then
    echo "OpenWrt container already running."
else
    lxc-start -P "\$CONTAINER_DIR" -n "\$CT_NAME" -d -l DEBUG -o /tmp/easepi-r2-openwrt-lxc-debug.log
fi

i=0
while [ "\$i" -lt 45 ]; do
    if ping -c 1 -W 1 "\$OPENWRT_IP" >/dev/null 2>&1; then
        echo "OpenWrt gateway \$OPENWRT_IP is reachable."
        break
    fi
    i=\$((i + 1))
    sleep 1
done

if ! ping -c 1 -W 1 "\$OPENWRT_IP" >/dev/null 2>&1; then
    echo "ERROR: OpenWrt gateway \$OPENWRT_IP is unreachable."
    lxc-info -P "\$CONTAINER_DIR" -n "\$CT_NAME" || true
    ip -br addr show "\$HOST_BR" || true
    exit 1
fi

echo "Try installing/enabling LuCI web service..."
lxc-attach -P "\$CONTAINER_DIR" -n "\$CT_NAME" -- sh -c '
if [ ! -e /www/index.html ]; then
    if command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install luci luci-ssl uhttpd rpcd || true
    elif command -v apk >/dev/null 2>&1; then
        apk update && apk add luci luci-ssl uhttpd rpcd || true
    fi
fi
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd enable || true
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart || true
' || true

echo "Check OpenWrt internet..."
if lxc-attach -P "\$CONTAINER_DIR" -n "\$CT_NAME" -- ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1; then
    echo "OpenWrt IPv4 internet OK."
else
    echo "WARNING: OpenWrt cannot ping 223.5.5.5 yet."
fi

if [ -x /usr/local/sbin/easepi-r2-lxc-openwrt-net-tune.sh ]; then
    echo "Apply OpenWrt network performance tuning..."
    /usr/local/sbin/easepi-r2-lxc-openwrt-net-tune.sh || true
fi

/usr/local/sbin/easepi-r2-lxc-hostroute.sh || true

curl -m 5 -sS -I "http://\$OPENWRT_IP/" 2>&1 | sed -n '1,8p' || true
lxc-info -P "\$CONTAINER_DIR" -n "\$CT_NAME" || true
ip -br addr show "\$HOST_BR" || true
printf '===== OpenWrt LXC finalize done: %s =====\n' "\$(date '+%F %T')"
EOF
    chmod +x /usr/local/sbin/easepi-r2-lxc-openwrt-finalize.sh
}

container_dir_for() {
    echo "${CONTAINER_DIR}/$1"
}

container_running() {
    lxc-info -P "$CONTAINER_DIR" -n "$1" -s 2>/dev/null | grep -q RUNNING
}

container_dir_safe() {
    local name="$1" dir base_real parent_real
    valid_container_name "$name" || return 1
    dir="$(container_dir_for "$name")"
    mkdir -p "$CONTAINER_DIR"
    base_real="$(cd "$CONTAINER_DIR" && pwd -P)"
    parent_real="$(cd "$(dirname "$dir")" && pwd -P 2>/dev/null || true)"
    [ "$parent_real" = "$base_real" ]
}

ensure_single_router_running() {
    local target="$1"
    local name
    while read -r name; do
        [ -n "$name" ] || continue
        [ "$name" = "$target" ] && continue
        if container_is_openwrt_router "$name" && container_running "$name"; then
            die "检测到路由容器 $name 正在运行。OpenWrt 路由容器同一时间只建议运行一个，请先停止它。"
        fi
    done < <(container_names)
}

prepare_container_dir() {
    local name="$1"
    local dir
    dir="$(container_dir_for "$name")"
    if [ -d "$dir" ]; then
        if confirm "容器 ${name} 已存在，是否停止并备份旧目录？" n; then
            lxc-stop -P "$CONTAINER_DIR" -n "$name" 2>/dev/null || true
            mv "$dir" "${dir}.bak.$(date +%Y%m%d-%H%M%S)"
        else
            die "容器已存在，取消安装。"
        fi
    fi
    mkdir -p "${dir}/rootfs"
    echo "$dir"
}

install_openwrt_router() {
    local key="$1"
    local name default_name dir rootfs_file
    default_name="$key"
    name="$(read_default "容器名称" "$default_name")"
    [ -n "$name" ] || die "容器名称不能为空。"

    ensure_single_router_running "$name"
    install_lxc_dependencies
    check_openwrt_kmods
    ensure_dirs
    ensure_rootfs "$key"
    collect_openwrt_network_config

    echo
    echo "========== 安装计划确认 =========="
    echo "容器名称       ：$name"
    echo "容器目录       ：$(container_dir_for "$name")"
    echo "WAN            ：$WAN_IF"
    echo "LAN            ：$LAN_IFS"
    echo "宿主桥         ：$HOST_BR / $HOST_IP_CIDR"
    echo "OpenWrt IP     ：$OPENWRT_IP"
    echo "DHCP           ：$DHCP_START_IP - $DHCP_END_IP"
    confirm "确认安装并准备切网？" y || die "已取消。"

    cleanup_host_openwrt_lan_conflicts
    dir="$(prepare_container_dir "$name")"
    rootfs_file="$(rootfs_cache_file "$key")"
    tar --numeric-owner -xzf "$rootfs_file" -C "${dir}/rootfs"

    write_hostnet_service
    write_hostroute_service
    write_openwrt_net_tune_service "$name"
    write_openwrt_lxc_config "$name" "${dir}/rootfs" "$dir"
    configure_openwrt_rootfs "${dir}/rootfs"
    write_openwrt_finalizer "$name"

    echo
    echo "即将后台执行最终切网和启动容器。SSH 可能会断开。"
    echo "完成后请从 OpenWrt LAN 口访问：http://${OPENWRT_IP}"
    if confirm "是否立即执行最终切网启动？" y; then
        if command_exists systemd-run; then
            systemd-run --unit=easepi-r2-lxc-openwrt-finalize --collect /bin/sh -c 'sleep 6; exec /usr/local/sbin/easepi-r2-lxc-openwrt-finalize.sh'
        else
            nohup /bin/sh -c 'sleep 6; exec /usr/local/sbin/easepi-r2-lxc-openwrt-finalize.sh' >/tmp/easepi-r2-lxc-openwrt-finalize-launch.log 2>&1 &
        fi
        ok "已提交后台任务。日志：/var/log/easepi-r2-lxc-openwrt-finalize.log"
    else
        ok "已完成安装。稍后可手动执行：/usr/local/sbin/easepi-r2-lxc-openwrt-finalize.sh"
    fi
}

configure_linux_instance_rootfs() {
    local rootfs="$1"
    local hostname="$2"
    echo "$hostname" > "$rootfs/etc/hostname"
    cat > "$rootfs/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${hostname}
EOF
    : > "$rootfs/etc/machine-id"
    rm -f "$rootfs/var/lib/dbus/machine-id"
}

write_linux_lxc_config() {
    local name="$1"
    local rootfs_dir="$2"
    local config_dir="$3"
    cat > "${config_dir}/config" <<EOF
lxc.rootfs.path = dir:${rootfs_dir}
lxc.uts.name = ${name}
lxc.include = /usr/share/lxc/config/common.conf
lxc.mount.auto = proc:mixed sys:mixed cgroup:mixed
lxc.apparmor.profile = unconfined
lxc.cap.drop =
lxc.start.auto = 1
lxc.start.order = 50
lxc.tty.max = 4
lxc.pty.max = 1024
lxc.init.cmd = /sbin/init

lxc.net.0.type = veth
lxc.net.0.link = ${HOST_BR}
lxc.net.0.name = eth0
lxc.net.0.hwaddr = $(stable_lxc_mac "$name" eth0)
lxc.net.0.flags = up
EOF
}

install_linux_container() {
    local key="$1"
    local name default_name dir rootfs_file
    default_name="$key"
    name="$(read_default "容器名称" "$default_name")"
    [ -n "$name" ] || die "容器名称不能为空。"

    if ! ip link show "$HOST_BR" >/dev/null 2>&1 || ! ping -c 1 -W 1 "$OPENWRT_IP" >/dev/null 2>&1; then
        die "未检测到可用的 OpenWrt LAN 桥 ${HOST_BR}/${OPENWRT_IP}。请先安装并启动 OpenWrt 路由容器。"
    fi

    install_lxc_dependencies
    ensure_dirs
    ensure_rootfs "$key"
    dir="$(prepare_container_dir "$name")"
    rootfs_file="$(rootfs_cache_file "$key")"
    tar --numeric-owner --xattrs -I zstd -xpf "$rootfs_file" -C "${dir}/rootfs"
    configure_linux_instance_rootfs "${dir}/rootfs" "$name"
    write_linux_lxc_config "$name" "${dir}/rootfs" "$dir"

    lxc-start -P "$CONTAINER_DIR" -n "$name" -d
    sleep 3
    ok "${name} 已启动，并桥接到 ${HOST_BR}。"
    lxc-info -P "$CONTAINER_DIR" -n "$name" || true
}

list_containers() {
    ensure_dirs
    if command_exists lxc-ls; then
        lxc-ls -P "$CONTAINER_DIR" -f 2>/dev/null || true
    else
        find "$CONTAINER_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true
    fi
}

container_names() {
    local dir
    [ -d "$CONTAINER_DIR" ] || return 0
    for dir in "$CONTAINER_DIR"/*; do
        [ -d "$dir" ] || continue
        [ -r "$dir/config" ] || continue
        basename "$dir"
    done | sort
}

valid_container_name() {
    case "$1" in
        ""|"."|".."|*/*|*[!A-Za-z0-9_.-]*) return 1 ;;
        *) return 0 ;;
    esac
}

container_exists() {
    local name="$1"
    [ -d "$(container_dir_for "$name")" ] && [ -r "$(container_dir_for "$name")/config" ]
}

container_config_for() {
    echo "$(container_dir_for "$1")/config"
}

container_is_openwrt_router() {
    local name="$1" cfg
    cfg="$(container_config_for "$name")"
    case "$name" in openwrt|openwrt[0-9]*|openwrt-*) return 0 ;; esac
    grep -Eq '^[[:space:]]*lxc\.net\.[0-9]+\.name[[:space:]]*=[[:space:]]*wan[[:space:]]*$' "$cfg" 2>/dev/null
}

choose_openwrt_router_container() {
    local -a routers
    local name choice idx

    mapfile -t routers < <(
        while read -r name; do
            [ -n "$name" ] || continue
            if container_is_openwrt_router "$name"; then
                echo "$name"
            fi
        done < <(container_names)
    )

    if [ "${#routers[@]}" -eq 0 ]; then
        warn "未发现 OpenWrt 路由容器。"
        return 1
    fi
    if [ "${#routers[@]}" -eq 1 ]; then
        echo "${routers[0]}"
        return 0
    fi

    echo >&2
    warn "检测到多个 OpenWrt 路由容器，请选择要应用网络性能优化的容器。"
    idx=1
    for name in "${routers[@]}"; do
        printf '  %d. %s\n' "$idx" "$name" >&2
        idx=$((idx + 1))
    done
    read -r -p "请选择 [1]: " choice || choice=1
    choice="${choice:-1}"
    case "$choice" in
        *[!0-9]*|"")
            warn "选择无效。"
            return 1
            ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#routers[@]}" ]; then
        warn "选择超出范围。"
        return 1
    fi
    echo "${routers[$((choice - 1))]}"
}

apply_openwrt_net_tune() {
    local name

    load_config
    name="$(choose_openwrt_router_container)" || return 1

    echo
    echo "========== OpenWrt 网络性能优化 =========="
    echo "容器名称       ：$name"
    echo "WAN IRQ CPU    ：$OPENWRT_NET_TUNE_WAN_IRQ_CPU"
    echo "LAN IRQ CPUs   ：$OPENWRT_NET_TUNE_LAN_IRQ_CPUS"
    echo "RPS CPUs       ：$OPENWRT_NET_TUNE_RPS_CPUS"
    echo "RPS flow cnt   ：$OPENWRT_NET_TUNE_RPS_FLOW_CNT"
    echo "CPU governor   ：$OPENWRT_NET_TUNE_CPU_GOVERNOR"

    write_openwrt_net_tune_service "$name"
    save_config

    case "$OPENWRT_NET_TUNE_ENABLE" in
        0|off|OFF|no|NO|false|FALSE|disabled|DISABLED)
            ok "已写入配置，但当前 OPENWRT_NET_TUNE_ENABLE=0，调优服务未启动。"
            return 0
            ;;
    esac

    if systemctl start easepi-r2-lxc-openwrt-net-tune.service >/dev/null 2>&1; then
        ok "已安装并立即应用 OpenWrt 网络性能优化。"
    else
        warn "调优服务启动失败，可查看：journalctl -u easepi-r2-lxc-openwrt-net-tune.service -n 80 --no-pager"
        return 1
    fi
}

set_lxc_config_key() {
    local cfg="$1" key="$2" value="$3" tmp regex
    [ -r "$cfg" ] || die "容器配置不存在：$cfg"
    tmp="$(mktemp)"
    regex="$(printf '%s' "$key" | sed 's/[.[\*^$()+?{}|]/\\&/g')"
    grep -vE "^[[:space:]]*${regex}[[:space:]]*=" "$cfg" > "$tmp" || true
    printf '%s = %s\n' "$key" "$value" >> "$tmp"
    install -m 0644 "$tmp" "$cfg"
    rm -f "$tmp"
}

get_lxc_config_key() {
    local cfg="$1" key="$2" regex
    [ -r "$cfg" ] || return 1
    regex="$(printf '%s' "$key" | sed 's/[.[\*^$()+?{}|]/\\&/g')"
    sed -nE "s/^[[:space:]]*${regex}[[:space:]]*=[[:space:]]*//p" "$cfg" | tail -n1
}

insert_lxc_net_key_after_name() {
    local cfg="$1" idx="$2" key="$3" value="$4" tmp inserted=0
    tmp="$(mktemp)"
    awk -v idx="$idx" -v key="$key" -v value="$value" '
        {
            print
            if (!inserted && $0 ~ "^[[:space:]]*lxc\\.net\\." idx "\\.name[[:space:]]*=") {
                print "lxc.net." idx "." key " = " value
                inserted = 1
            }
        }
        END {
            if (!inserted) {
                print "lxc.net." idx "." key " = " value
            }
        }
    ' "$cfg" > "$tmp"
    install -m 0644 "$tmp" "$cfg"
    rm -f "$tmp"
}

repair_container_stable_macs() {
    local name="$1" cfg idx ifname mac changed=0

    container_exists "$name" || die "容器不存在：$name"
    cfg="$(container_config_for "$name")"

    while read -r idx; do
        [ -n "$idx" ] || continue
        ifname="$(get_lxc_config_key "$cfg" "lxc.net.${idx}.name")"
        [ -n "$ifname" ] || ifname="eth${idx}"
        if [ -n "$(get_lxc_config_key "$cfg" "lxc.net.${idx}.hwaddr")" ]; then
            continue
        fi
        mac="$(stable_lxc_mac "$name" "$ifname")"
        insert_lxc_net_key_after_name "$cfg" "$idx" "hwaddr" "$mac"
        ok "已为 ${name}/${ifname} 写入固定 MAC：${mac}"
        changed=1
    done < <(sed -nE 's/^[[:space:]]*lxc\.net\.([0-9]+)\.type[[:space:]]*=[[:space:]]*veth[[:space:]]*$/\1/p' "$cfg" | sort -n -u)

    if [ "$changed" -eq 0 ]; then
        ok "${name} 已存在固定 MAC，未修改。"
    elif container_running "$name"; then
        warn "${name} 正在运行；固定 MAC 需要重启该容器后生效。"
    fi
}

repair_all_container_stable_macs() {
    local name found=0
    while read -r name; do
        [ -n "$name" ] || continue
        found=1
        repair_container_stable_macs "$name"
    done < <(container_names)
    [ "$found" -eq 1 ] || warn "没有发现容器。"
}

set_container_autostart() {
    local name="$1" enabled="$2" cfg order
    container_exists "$name" || die "容器不存在：$name"
    cfg="$(container_config_for "$name")"
    if [ "$enabled" = "1" ]; then
        if container_is_openwrt_router "$name"; then
            order=10
        else
            order=50
        fi
        set_lxc_config_key "$cfg" "lxc.start.auto" "1"
        set_lxc_config_key "$cfg" "lxc.start.order" "$order"
        ok "已启用 $name 开机自启动。"
    else
        set_lxc_config_key "$cfg" "lxc.start.auto" "0"
        ok "已取消 $name 开机自启动。"
    fi
}

repair_all_container_autostart() {
    local -a names routers
    local name selected default choice idx
    mapfile -t names < <(container_names)
    [ "${#names[@]}" -gt 0 ] || { warn "没有发现容器。"; return 0; }

    routers=()
    for name in "${names[@]}"; do
        if container_is_openwrt_router "$name"; then
            routers+=("$name")
        fi
    done

    selected=""
    if [ "${#routers[@]}" -eq 1 ]; then
        selected="${routers[0]}"
    elif [ "${#routers[@]}" -gt 1 ]; then
        echo
        warn "检测到多个 OpenWrt 路由容器，同一时间只建议一个开机自启动。"
        idx=1
        for name in "${routers[@]}"; do
            printf '  %d. %s\n' "$idx" "$name"
            idx=$((idx + 1))
        done
        default=1
        read -r -p "请选择默认开机自启动的 OpenWrt 容器，输入 0 表示都不自启 [$default]: " choice || choice="$default"
        choice="${choice:-$default}"
        if [ "$choice" != "0" ]; then
            case "$choice" in
                *[!0-9]*|"") warn "选择无效，已跳过 OpenWrt 自启修复。" ;;
                *)
                    if [ "$choice" -ge 1 ] && [ "$choice" -le "${#routers[@]}" ]; then
                        selected="${routers[$((choice - 1))]}"
                    else
                        warn "选择超出范围，已跳过 OpenWrt 自启修复。"
                    fi
                    ;;
            esac
        fi
    fi

    for name in "${names[@]}"; do
        if container_is_openwrt_router "$name"; then
            if [ -n "$selected" ] && [ "$name" = "$selected" ]; then
                set_container_autostart "$name" 1
            else
                set_container_autostart "$name" 0
            fi
        else
            set_container_autostart "$name" 1
        fi
    done
}

ensure_lxc_hostnet_started_if_present() {
    if systemctl list-unit-files easepi-r2-lxc-hostnet.service --no-legend 2>/dev/null | grep -q '^easepi-r2-lxc-hostnet\.service'; then
        systemctl start easepi-r2-lxc-hostnet.service >/dev/null 2>&1 || warn "easepi-r2-lxc-hostnet.service 启动失败。"
    fi
}

start_lxc_hostroute_if_present() {
    if systemctl list-unit-files easepi-r2-lxc-hostroute.service --no-legend 2>/dev/null | grep -q '^easepi-r2-lxc-hostroute\.service'; then
        systemctl start easepi-r2-lxc-hostroute.timer >/dev/null 2>&1 || true
        systemctl start easepi-r2-lxc-hostroute.service >/dev/null 2>&1 || true
    fi
}

start_openwrt_net_tune_if_present() {
    if systemctl list-unit-files easepi-r2-lxc-openwrt-net-tune.service --no-legend 2>/dev/null | grep -q '^easepi-r2-lxc-openwrt-net-tune\.service'; then
        systemctl start easepi-r2-lxc-openwrt-net-tune.service >/dev/null 2>&1 || true
    fi
}

start_container_by_name() {
    local name="$1" i
    container_exists "$name" || die "容器不存在：$name"
    if container_running "$name"; then
        ok "$name 已在运行。"
        if container_is_openwrt_router "$name"; then
            start_openwrt_net_tune_if_present
            start_lxc_hostroute_if_present
        fi
        return 0
    fi
    if container_is_openwrt_router "$name"; then
        ensure_single_router_running "$name"
    fi
    ensure_lxc_hostnet_started_if_present
    lxc-start -P "$CONTAINER_DIR" -n "$name" -d
    for i in $(seq 1 10); do
        if container_running "$name"; then
            ok "$name 已启动。"
            if container_is_openwrt_router "$name"; then
                start_openwrt_net_tune_if_present
                start_lxc_hostroute_if_present
            fi
            return 0
        fi
        sleep 1
    done
    lxc-info -P "$CONTAINER_DIR" -n "$name" || true
    die "$name 启动后未进入 RUNNING 状态。"
}

stop_container_by_name() {
    local name="$1"
    container_exists "$name" || die "容器不存在：$name"
    if ! container_running "$name"; then
        ok "$name 已停止。"
        return 0
    fi
    lxc-stop -P "$CONTAINER_DIR" -n "$name"
    if container_is_openwrt_router "$name"; then
        start_lxc_hostroute_if_present
    fi
    ok "$name 已停止。"
}

restart_container_by_name() {
    local name="$1"
    container_exists "$name" || die "容器不存在：$name"
    container_running "$name" && lxc-stop -P "$CONTAINER_DIR" -n "$name" || true
    start_container_by_name "$name"
}

attach_container_by_name() {
    local name="$1" shell
    container_exists "$name" || die "容器不存在：$name"
    start_container_by_name "$name"
    for shell in /bin/bash /bin/ash /bin/sh; do
        if lxc-attach -P "$CONTAINER_DIR" -n "$name" -- test -x "$shell" >/dev/null 2>&1; then
            lxc-attach -P "$CONTAINER_DIR" -n "$name" -- "$shell"
            return 0
        fi
    done
    lxc-attach -P "$CONTAINER_DIR" -n "$name"
}

prompt_container_name() {
    local prompt="$1" name
    echo >&2
    list_containers >&2 || true
    read -r -p "$prompt: " name || name=""
    valid_container_name "$name" || { warn "容器名称不合法：$name"; return 1; }
    container_exists "$name" || { warn "容器不存在：$name"; return 1; }
    echo "$name"
}

write_container_shortcut() {
    local name="$1" target="/usr/local/bin/$1" is_router=0 router_names="" other
    valid_container_name "$name" || { warn "跳过非法容器名：$name"; return 0; }
    if [ -e "$target" ] && ! grep -qs 'EasePi-R2 LXC container shortcut' "$target"; then
        warn "$target 已存在且不是本脚本生成，已跳过。"
        return 0
    fi
    if container_is_openwrt_router "$name"; then
        is_router=1
        while read -r other; do
            [ -n "$other" ] || continue
            if container_is_openwrt_router "$other"; then
                router_names="$(trim "$router_names $other")"
            fi
        done < <(container_names)
    fi
    cat > "$target" <<EOF
#!/bin/sh
# EasePi-R2 LXC container shortcut: ${name}
set -eu

CONFIG_FILE="/etc/easepi-r2-lxc-manager/config.env"
[ -r "\$CONFIG_FILE" ] && . "\$CONFIG_FILE"
CONTAINER_DIR="\${CONTAINER_DIR:-${CONTAINER_DIR}}"
CT_NAME="${name}"
CT_ROUTER="${is_router}"
ROUTER_NAMES="${router_names}"

running() {
    lxc-info -P "\$CONTAINER_DIR" -n "\$CT_NAME" -s 2>/dev/null | grep -q RUNNING
}

router_guard() {
    [ "\$CT_ROUTER" = "1" ] || return 0
    for other in \$ROUTER_NAMES; do
        [ "\$other" = "\$CT_NAME" ] && continue
        if lxc-info -P "\$CONTAINER_DIR" -n "\$other" -s 2>/dev/null | grep -q RUNNING; then
            echo "OpenWrt router container \$other is already running. Stop it before starting \$CT_NAME." >&2
            exit 1
        fi
    done
}

start_ct() {
    if running; then
        if [ "\$CT_ROUTER" = "1" ] && systemctl list-unit-files easepi-r2-lxc-openwrt-net-tune.service --no-legend 2>/dev/null | grep -q '^easepi-r2-lxc-openwrt-net-tune\.service'; then
            systemctl start easepi-r2-lxc-openwrt-net-tune.service >/dev/null 2>&1 || true
        fi
        if [ "\$CT_ROUTER" = "1" ] && systemctl list-unit-files easepi-r2-lxc-hostroute.service --no-legend 2>/dev/null | grep -q '^easepi-r2-lxc-hostroute\.service'; then
            systemctl start easepi-r2-lxc-hostroute.timer >/dev/null 2>&1 || true
            systemctl start easepi-r2-lxc-hostroute.service >/dev/null 2>&1 || true
        fi
        return 0
    fi
    router_guard
    if systemctl list-unit-files easepi-r2-lxc-hostnet.service --no-legend 2>/dev/null | grep -q '^easepi-r2-lxc-hostnet\.service'; then
        systemctl start easepi-r2-lxc-hostnet.service >/dev/null 2>&1 || true
    fi
    lxc-start -P "\$CONTAINER_DIR" -n "\$CT_NAME" -d
    i=0
    while [ "\$i" -lt 10 ]; do
        if running; then
            if [ "\$CT_ROUTER" = "1" ] && systemctl list-unit-files easepi-r2-lxc-openwrt-net-tune.service --no-legend 2>/dev/null | grep -q '^easepi-r2-lxc-openwrt-net-tune\.service'; then
                systemctl start easepi-r2-lxc-openwrt-net-tune.service >/dev/null 2>&1 || true
            fi
            if [ "\$CT_ROUTER" = "1" ] && systemctl list-unit-files easepi-r2-lxc-hostroute.service --no-legend 2>/dev/null | grep -q '^easepi-r2-lxc-hostroute\.service'; then
                systemctl start easepi-r2-lxc-hostroute.timer >/dev/null 2>&1 || true
                systemctl start easepi-r2-lxc-hostroute.service >/dev/null 2>&1 || true
            fi
            return 0
        fi
        i=\$((i + 1))
        sleep 1
    done
    lxc-info -P "\$CONTAINER_DIR" -n "\$CT_NAME" || true
    exit 1
}

attach_ct() {
    start_ct
    for sh in /bin/bash /bin/ash /bin/sh; do
        if lxc-attach -P "\$CONTAINER_DIR" -n "\$CT_NAME" -- test -x "\$sh" >/dev/null 2>&1; then
            exec lxc-attach -P "\$CONTAINER_DIR" -n "\$CT_NAME" -- "\$sh"
        fi
    done
    exec lxc-attach -P "\$CONTAINER_DIR" -n "\$CT_NAME"
}

case "\${1:-attach}" in
    attach|shell|console|"") attach_ct ;;
    start) start_ct ;;
    stop)
        lxc-stop -P "\$CONTAINER_DIR" -n "\$CT_NAME"
        if [ "\$CT_ROUTER" = "1" ] && systemctl list-unit-files easepi-r2-lxc-hostroute.service --no-legend 2>/dev/null | grep -q '^easepi-r2-lxc-hostroute\.service'; then
            systemctl start easepi-r2-lxc-hostroute.service >/dev/null 2>&1 || true
        fi
        ;;
    restart) lxc-stop -P "\$CONTAINER_DIR" -n "\$CT_NAME" 2>/dev/null || true; start_ct ;;
    status) lxc-info -P "\$CONTAINER_DIR" -n "\$CT_NAME" ;;
    *) start_ct; exec lxc-attach -P "\$CONTAINER_DIR" -n "\$CT_NAME" -- "\$@" ;;
esac
EOF
    chmod 755 "$target"
    ok "已生成快捷命令：$target"
}

write_all_container_shortcuts() {
    local name
    while read -r name; do
        [ -n "$name" ] || continue
        write_container_shortcut "$name"
    done < <(container_names)
}

delete_container() {
    local name confirm_name dir shortcut
    echo
    echo "========== 删除容器 =========="
    name="$(prompt_container_name "请输入要删除的容器名称")" || return 1
    dir="$(container_dir_for "$name")"
    container_dir_safe "$name" || {
        warn "容器目录安全校验失败：$dir"
        return 1
    }
    if container_running "$name"; then
        warn "容器 $name 正在运行。请先停止容器后再删除。"
        return 1
    fi

    warn "此操作会永久删除容器目录：$dir"
    read -r -p "请输入完整容器名称确认删除: " confirm_name || confirm_name=""
    if [ "$confirm_name" != "$name" ]; then
        warn "确认内容不匹配，已取消删除。"
        return 1
    fi
    confirm "最后确认删除容器 ${name}？" n || { warn "已取消删除。"; return 1; }

    if command_exists lxc-destroy; then
        lxc-destroy -P "$CONTAINER_DIR" -n "$name"
    else
        warn "未找到 lxc-destroy，请先安装 LXC 依赖。"
        return 1
    fi

    shortcut="/usr/local/bin/$name"
    if [ -f "$shortcut" ] && grep -qs 'EasePi-R2 LXC container shortcut' "$shortcut"; then
        rm -f "$shortcut"
        ok "已删除快捷命令：$shortcut"
    fi
    ok "容器已删除：$name"
}

default_openwrt_container_name() {
    local name first
    for name in openwrt24 openwrt25 openwrt; do
        if [ -d "$(container_dir_for "$name")" ]; then
            echo "$name"
            return 0
        fi
    done
    first="$(find "$CONTAINER_DIR" -mindepth 1 -maxdepth 1 -type d -name 'openwrt*' -printf '%f\n' 2>/dev/null | sort | head -n1 || true)"
    echo "${first:-openwrt24}"
}

select_openwrt_container() {
    local default name
    echo
    echo "========== OpenWrt 容器 =========="
    list_containers || true
    default="$(default_openwrt_container_name)"
    name="$(read_default "OpenWrt 容器名称" "$default")"
    [ -n "$name" ] || die "容器名称不能为空。"
    [ -d "$(container_dir_for "$name")" ] || die "容器不存在：$name"

    if ! container_running "$name"; then
        if confirm "容器 $name 未运行，是否启动？" y; then
            lxc-start -P "$CONTAINER_DIR" -n "$name" -d
            sleep 3
        else
            die "容器未运行，无法继续。"
        fi
    fi
    SELECTED_OPENWRT_CT="$name"
}

run_in_openwrt_container() {
    local name="$1"
    shift || true
    lxc-attach -P "$CONTAINER_DIR" -n "$name" -- /bin/sh "$@"
}

install_openwrt_lxc_passwall() {
    local name
    select_openwrt_container
    name="$SELECTED_OPENWRT_CT"

    check_openwrt_kmods

    echo
    echo "========== 一键安装 Passwall =========="
    run_in_openwrt_container "$name" -s <<'EOS'
set -u

ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
installed() { opkg status "$1" 2>/dev/null | grep -q 'Status: install ok installed'; }
fetch_file() {
    local url="$1"
    local dst="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dst" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$dst" "$url"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -O "$dst" "$url"
    else
        return 1
    fi
}

[ -r /etc/openwrt_release ] || { warn "当前容器不像 OpenWrt。"; exit 1; }
command -v opkg >/dev/null 2>&1 || { warn "未找到 opkg。"; exit 1; }

echo "OpenWrt: $(. /etc/openwrt_release; echo "$DISTRIB_DESCRIPTION")"
echo "运行内核: $(uname -r)"
if opkg status kernel >/tmp/easepi-kernel-status 2>/dev/null; then
    echo "opkg kernel: $(awk '/^Version:/{print $2; exit}' /tmp/easepi-kernel-status)"
fi
rm -f /tmp/easepi-kernel-status

mkdir -p /etc/opkg
touch /etc/opkg/customfeeds.conf
. /etc/openwrt_release
release="${DISTRIB_RELEASE%.*}"
arch="$DISTRIB_ARCH"

echo
echo "配置 Passwall-build 软件源：packages-${release}/${arch}"
if fetch_file "https://master.dl.sourceforge.net/project/openwrt-passwall-build/ipk.pub" /tmp/easepi-passwall-ipk.pub; then
    opkg-key add /tmp/easepi-passwall-ipk.pub >/dev/null 2>&1 || warn "Passwall-build key 导入失败，若软件源签名校验失败请手动检查。"
    rm -f /tmp/easepi-passwall-ipk.pub
else
    warn "Passwall-build key 下载失败，继续尝试使用已有 key。"
fi

for feed in passwall_luci passwall_packages passwall2; do
    sed -i -E "/^[[:space:]]*src\\/gz[[:space:]]+${feed}[[:space:]]+/d" /etc/opkg/customfeeds.conf
    echo "src/gz ${feed} https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${release}/${arch}/${feed}" >> /etc/opkg/customfeeds.conf
done

for conf in /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf; do
    [ -f "$conf" ] || continue
    if grep -qE '^[[:space:]]*src/gz[[:space:]]+[^[:space:]]*kmods?[[:space:]]+' "$conf"; then
        [ -f "${conf}.easepi-lxc.bak" ] || cp -a "$conf" "${conf}.easepi-lxc.bak"
        sed -i -E 's|^[[:space:]]*(src/gz[[:space:]]+[^[:space:]]*kmods?[[:space:]]+.*)$|# disabled-by-easepi-lxc: \1|' "$conf"
        rm -f /var/opkg-lists/*kmod* /var/opkg-lists/*Kmod* 2>/dev/null || true
        ok "已禁用 $conf 里的 OpenWrt kmod 源，避免安装与宿主内核不匹配的 .ko。"
    fi
done

opkg update || warn "opkg update 失败，请检查网络或软件源。"

if installed dnsmasq-full; then
    ok "dnsmasq-full 已安装。"
else
    if installed dnsmasq; then
        /etc/init.d/dnsmasq stop >/dev/null 2>&1 || true
        opkg remove dnsmasq --force-depends || warn "移除 dnsmasq 失败，稍后安装 dnsmasq-full 可能冲突。"
    fi
    opkg install dnsmasq-full || opkg install --force-overwrite dnsmasq-full
    installed dnsmasq-full && ok "dnsmasq-full 已安装。" || warn "dnsmasq-full 安装失败。"
    /etc/init.d/dnsmasq enable >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi

failed=""
for p in coreutils coreutils-base64 coreutils-nohup curl ip-full libuci-lua lua luci-compat luci-lib-jsonc luci-lua-runtime resolveip ca-bundle ca-certificates unzip chinadns-ng dns2socks microsocks tcping lyaml; do
    if installed "$p"; then
        continue
    fi
    if ! opkg install "$p"; then
        failed="$failed $p"
    fi
done

if [ -n "$failed" ]; then
    warn "以下用户态依赖未安装成功，通常是对应软件源未添加或网络失败：$failed"
else
    ok "Passwall 常用用户态依赖已准备。"
fi

echo
echo "安装 Passwall 与中文翻译包..."
if opkg install --force-depends luci-app-passwall luci-i18n-passwall-zh-cn; then
    ok "luci-app-passwall 与 luci-i18n-passwall-zh-cn 已安装。"
else
    warn "Passwall 安装命令返回失败。请查看上方 opkg 输出，通常是软件源网络或用户态依赖下载失败。"
fi

echo
echo "宿主内核能力可见性："
for m in nf_tables nft_tproxy nft_socket nf_tproxy_ipv4 nf_tproxy_ipv6 xt_TPROXY xt_socket nft_chain_nat nf_nat tun wireguard; do
    if grep -qw "$m" /proc/modules; then
        echo "  [OK] $m"
    else
        echo "  [WARN] $m 未加载"
    fi
done
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
echo "[OK] Passwall 一键安装流程已执行。"
EOS
}

install_openwrt_lxc_easytier() {
    local name
    select_openwrt_container
    name="$SELECTED_OPENWRT_CT"

    check_openwrt_kmods

    echo
    echo "========== 一键安装 EasyTier =========="
    run_in_openwrt_container "$name" -s <<'EOS'
set -u

ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
installed() { opkg status "$1" 2>/dev/null | grep -q 'Status: install ok installed'; }
fetch_file() {
    local url="$1"
    local dst="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dst" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$dst" "$url"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -O "$dst" "$url"
    else
        return 1
    fi
}

[ -r /etc/openwrt_release ] || { warn "当前容器不像 OpenWrt。"; exit 1; }
command -v opkg >/dev/null 2>&1 || { warn "当前 EasyTier 一键安装仅支持 opkg 版 OpenWrt。"; exit 1; }

. /etc/openwrt_release
arch="$DISTRIB_ARCH"
work="/tmp/easepi-easytier-install"

echo "OpenWrt: $DISTRIB_DESCRIPTION"
echo "运行内核: $(uname -r)"
echo "架构: $arch"

if [ ! -c /dev/net/tun ]; then
    warn "/dev/net/tun 不存在，EasyTier 无法创建 TUN 设备。请确认 OpenWrt LXC 配置已挂载 /dev/net/tun 后重启容器。"
    exit 1
fi
if grep -q '^tun[[:space:]]' /proc/modules; then
    ok "宿主 tun 模块在容器内可见。"
else
    warn "未在 /proc/modules 看到 tun。若后续无法启动 EasyTier，请回宿主执行 OpenWrt Kmod 检测。"
fi

mkdir -p /usr/lib/opkg/info
if ! installed kmod-tun; then
    cp -a /usr/lib/opkg/status /usr/lib/opkg/status.easepi-before-virtual-kmod-tun 2>/dev/null || true
    cat >> /usr/lib/opkg/status <<EOF

Package: kmod-tun
Version: 9999-easepi-lxc
Status: install user installed
Architecture: ${arch}
Description: EasePi LXC virtual package; tun is provided by the host kernel.
EOF
    ok "已注册 LXC 虚拟 kmod-tun，避免安装与宿主内核不匹配的 OpenWrt kmod。"
fi
: > /usr/lib/opkg/info/kmod-tun.list
[ -f /usr/lib/opkg/info/kmod-tun.control ] || cat > /usr/lib/opkg/info/kmod-tun.control <<EOF
Package: kmod-tun
Version: 9999-easepi-lxc
Architecture: ${arch}
Description: EasePi LXC virtual package; tun is provided by the host kernel.
EOF

opkg update || warn "opkg update 失败，请检查 OpenWrt 网络或软件源。"
opkg install luci-compat unzip ca-bundle ca-certificates || warn "安装 EasyTier 基础依赖时有失败项，请查看上方 opkg 输出。"

rm -rf "$work"
mkdir -p "$work"
cd "$work"

if command -v jsonfilter >/dev/null 2>&1; then
    tag="$(fetch_file https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest - | jsonfilter -e '@.tag_name' 2>/dev/null || true)"
else
    tag="$(fetch_file https://api.github.com/repos/EasyTier/luci-app-easytier/releases/latest - | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
fi
[ -n "${tag:-}" ] || tag="v2.6.4"
url="https://github.com/EasyTier/luci-app-easytier/releases/download/${tag}/EasyTier-${tag}-${arch}-22.03.7.zip"

echo "下载 EasyTier ${tag}: $url"
if ! fetch_file "$url" easytier.zip; then
    warn "下载 EasyTier 安装包失败。当前架构 ${arch} 可能没有对应 release asset，或无法访问 GitHub。"
    exit 1
fi
unzip -o easytier.zip >/tmp/easepi-easytier-unzip.log

core="$(ls easytier_[0-9]*_${arch}.ipk 2>/dev/null | head -n1 || true)"
luci="$(ls luci-app-easytier_*.ipk 2>/dev/null | head -n1 || true)"
i18n="$(ls luci-i18n-easytier-zh-cn_*.ipk 2>/dev/null | head -n1 || true)"
[ -n "$core" ] && [ -n "$luci" ] && [ -n "$i18n" ] || { warn "安装包内容不完整。"; ls -l; exit 1; }

opkg install "$core" "$luci" "$i18n"

/etc/init.d/easytier enable >/dev/null 2>&1 || true
/etc/init.d/easytier restart >/dev/null 2>&1 || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
rm -rf "$work"

echo
echo "安装结果："
opkg list-installed | grep -E '^kmod-tun |^easytier |^luci-app-easytier|^luci-i18n-easytier|^luci-compat' || true
if command -v easytier-core >/dev/null 2>&1; then
    easytier-core --version
    ok "EasyTier 核心与 LuCI 已安装。"
else
    warn "未找到 easytier-core，安装未完成。"
    exit 1
fi
EOS
}

backup_local_files() {
    [ -d "$BACKUP_DIR" ] || return 0
    find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.zst' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-
}

print_local_backups() {
    local -a files
    local idx file base size mtime
    mapfile -t files < <(backup_local_files)
    if [ "${#files[@]}" -eq 0 ]; then
        echo "  无本地备份。"
        return 0
    fi
    idx=1
    for file in "${files[@]}"; do
        base="$(basename "$file")"
        size="$(format_bytes "$(file_size_bytes "$file")")"
        mtime="$(date -r "$file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
        printf '  %2d. %-42s %9s  %s\n' "$idx" "$base" "$size" "$mtime"
        idx=$((idx + 1))
    done
}

select_local_backup() {
    local prompt="${1:-请输入备份序号或文件名}"
    local -a files
    local input idx file
    mkdir -p "$BACKUP_DIR"
    mapfile -t files < <(backup_local_files)
    if [ "${#files[@]}" -eq 0 ]; then
        warn "没有可用的本地备份。"
        return 1
    fi
    print_local_backups >&2
    read -r -p "$prompt: " input || input=""
    input="$(trim "$input")"
    [ -n "$input" ] || { warn "未输入备份。"; return 1; }
    case "$input" in
        *[!0-9]*)
            case "$input" in
                /*) file="$input" ;;
                *) file="${BACKUP_DIR}/${input}" ;;
            esac
            ;;
        *)
            idx=$((10#$input))
            if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#files[@]}" ]; then
                warn "备份序号超出范围：$input"
                return 1
            fi
            file="${files[$((idx - 1))]}"
            ;;
    esac
    [ -f "$file" ] || { warn "备份文件不存在：$file"; return 1; }
    valid_backup_filename "$(basename "$file")" || { warn "备份文件名不合法：$(basename "$file")"; return 1; }
    case "$file" in
        "$BACKUP_DIR"/*.tar.zst) ;;
        *) warn "只支持还原 ${BACKUP_DIR} 下的本地 .tar.zst 备份。"; return 1 ;;
    esac
    printf '%s\n' "$file"
}

write_backup_sha256() {
    local file="$1" dir base
    dir="$(dirname "$file")"
    base="$(basename "$file")"
    (cd "$dir" && sha256sum "$base" > "${base}.sha256")
}

verify_backup_sha256() {
    local file="$1" dir base sha_file
    dir="$(dirname "$file")"
    base="$(basename "$file")"
    sha_file="${file}.sha256"
    [ -f "$sha_file" ] || return 0
    if (cd "$dir" && sha256sum -c "$(basename "$sha_file")"); then
        ok "备份校验通过：$(basename "$sha_file")"
        return 0
    fi
    warn "备份校验失败：$sha_file"
    return 1
}

backup_container() {
    local name dir file tmp size
    echo
    echo "========== 备份容器（必须关机） =========="
    list_containers
    read -r -p "请输入要备份的容器名称: " name || name=""
    name="$(trim "$name")"
    valid_container_name "$name" || { warn "容器名称不合法：$name"; return 1; }
    container_exists "$name" || { warn "容器不存在：$name"; return 1; }
    if container_running "$name"; then
        warn "容器 $name 正在运行。请先停止容器后再备份。"
        return 1
    fi

    dir="$(container_dir_for "$name")"
    size="$(dir_size_bytes "$dir")"
    [ -n "$size" ] || size=0
    mkdir -p "$BACKUP_DIR"
    file="${BACKUP_DIR}/${name}-$(date +%Y%m%d-%H%M%S).tar.zst"
    tmp="${file}.partial"
    rm -f "$tmp"

    echo "容器目录：$dir"
    echo "预计大小：$(format_bytes "$size")"
    echo "输出文件：$file"
    echo "开始备份..."

    if command_exists pv; then
        if ! tar --numeric-owner --xattrs -C "$CONTAINER_DIR" -cpf - "$name" | pv -s "$size" -p -t -e -r -b | zstd -19 -T0 -q > "$tmp"; then
            rm -f "$tmp"
            warn "备份失败。"
            return 1
        fi
    else
        warn "未安装 pv，备份期间不会显示进度。"
        if ! tar --numeric-owner --xattrs -C "$CONTAINER_DIR" -cpf - "$name" | zstd -19 -T0 -q > "$tmp"; then
            rm -f "$tmp"
            warn "备份失败。"
            return 1
        fi
    fi

    mv -f "$tmp" "$file"
    write_backup_sha256 "$file"
    ok "备份完成：$file"
}

restore_container() {
    local file name first size dir
    mkdir -p "$BACKUP_DIR" "$CONTAINER_DIR"
    echo
    echo "========== 还原容器（仅本地备份） =========="
    file="$(select_local_backup "请输入要还原的备份序号或文件名")" || return 1
    verify_backup_sha256 "$file" || return 1

    set +o pipefail
    first="$(tar -I zstd -tf "$file" 2>/dev/null | head -n1 || true)"
    set -o pipefail
    name="$(printf '%s' "$first" | cut -d/ -f1)"
    valid_container_name "$name" || { warn "无法识别备份内的容器名称。"; return 1; }
    if [ -e "$(container_dir_for "$name")" ]; then
        warn "容器 $name 已存在，请先改名或删除。"
        return 1
    fi
    dir="$(container_dir_for "$name")"

    echo "备份文件：$file"
    echo "还原容器：$name"
    confirm "确认开始还原？" y || { warn "已取消还原。"; return 1; }

    size="$(file_size_bytes "$file")"
    echo "开始还原..."
    if command_exists pv; then
        if ! pv -s "$size" "$file" | zstd -dc | tar --numeric-owner --xattrs -xpf - -C "$CONTAINER_DIR"; then
            [ -d "$dir" ] && rm -rf "$dir"
            warn "还原失败。"
            return 1
        fi
    else
        warn "未安装 pv，还原期间不会显示进度。"
        if ! tar --numeric-owner --xattrs -I zstd -xpf "$file" -C "$CONTAINER_DIR"; then
            [ -d "$dir" ] && rm -rf "$dir"
            warn "还原失败。"
            return 1
        fi
    fi

    repair_container_stable_macs "$name" || true
    write_container_shortcut "$name" || true
    ok "还原完成：$name"
    if container_is_openwrt_router "$name"; then
        if confirm "检测到 OpenWrt 路由容器，是否现在重建宿主接管配置？" y; then
            rebuild_openwrt_host_takeover || true
        else
            warn "已跳过；如需恢复网口接管/hostroute/自启动，可稍后在“LXC 目录管理”执行。"
        fi
    fi
}

backup_git_askpass_script() {
    local askpass
    askpass="$(mktemp /tmp/easepi-r2-git-askpass.XXXXXX)"
    cat > "$askpass" <<'EOF'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' "${GIT_BACKUP_USER:-x-access-token}" ;;
    *Password*) cat "${GIT_BACKUP_TOKEN_FILE:?}" ;;
    *) printf '\n' ;;
esac
EOF
    chmod 700 "$askpass"
    echo "$askpass"
}

backup_cloud_auth_ready() {
    refresh_backup_remote_repo
    case "$BACKUP_REMOTE_AUTH" in
        https-token)
            if [ ! -r "$BACKUP_REMOTE_TOKEN_FILE" ]; then
                warn "尚未配置 GitHub Token。请先进入“云端仓库备份设置 / 鉴权设置”。"
                return 1
            fi
            ;;
        ssh)
            if [ ! -r "$BACKUP_REMOTE_SSH_KEY" ]; then
                warn "尚未配置 SSH 私钥：$BACKUP_REMOTE_SSH_KEY"
                warn "请先进入“云端仓库备份设置 / 鉴权设置”生成或配置 SSH Key。"
                return 1
            fi
            ;;
        none)
            ;;
        *)
            warn "未知云端鉴权方式：$BACKUP_REMOTE_AUTH"
            warn "请先进入“云端仓库备份设置 / 鉴权设置”重新选择鉴权方式。"
            return 1
            ;;
    esac
}

run_backup_git() {
    local askpass rc
    refresh_backup_remote_repo
    case "$BACKUP_REMOTE_AUTH" in
        https-token)
            [ -r "$BACKUP_REMOTE_TOKEN_FILE" ] || {
                warn "未配置 GitHub Token：$BACKUP_REMOTE_TOKEN_FILE"
                return 1
            }
            askpass="$(backup_git_askpass_script)" || return 1
            if GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" GIT_BACKUP_USER="${BACKUP_REMOTE_USER:-x-access-token}" GIT_BACKUP_TOKEN_FILE="$BACKUP_REMOTE_TOKEN_FILE" git "$@"; then
                rc=0
            else
                rc=$?
            fi
            rm -f "$askpass"
            return "$rc"
            ;;
        ssh)
            [ -r "$BACKUP_REMOTE_SSH_KEY" ] || {
                warn "未找到 SSH 私钥：$BACKUP_REMOTE_SSH_KEY"
                return 1
            }
            if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -i $BACKUP_REMOTE_SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" git "$@"; then
                return 0
            else
                rc=$?
                return "$rc"
            fi
            ;;
        none)
            if GIT_TERMINAL_PROMPT=0 git "$@"; then
                return 0
            else
                rc=$?
                return "$rc"
            fi
            ;;
        *)
            warn "未知云端鉴权方式：$BACKUP_REMOTE_AUTH"
            return 1
            ;;
    esac
}

ensure_backup_cloud_repo() {
    backup_cloud_auth_ready || return 1
    mkdir -p "$(dirname "$BACKUP_CLOUD_DIR")"
    if [ ! -d "$BACKUP_CLOUD_DIR/.git" ]; then
        if [ -e "$BACKUP_CLOUD_DIR" ] && dir_has_entries "$BACKUP_CLOUD_DIR"; then
            warn "$BACKUP_CLOUD_DIR 已存在但不是 git 仓库，请清理或修改云端本地缓存目录。"
            return 1
        fi
        echo "正在初始化云端仓库缓存：$BACKUP_CLOUD_DIR"
        run_backup_git clone -q "$BACKUP_REMOTE_REPO" "$BACKUP_CLOUD_DIR" || {
            warn "克隆云端仓库失败。"
            return 1
        }
    fi

    if git -C "$BACKUP_CLOUD_DIR" remote get-url origin >/dev/null 2>&1; then
        git -C "$BACKUP_CLOUD_DIR" remote set-url origin "$BACKUP_REMOTE_REPO"
    else
        git -C "$BACKUP_CLOUD_DIR" remote add origin "$BACKUP_REMOTE_REPO"
    fi
    git -C "$BACKUP_CLOUD_DIR" config user.name "EasePi-R2 Backup"
    git -C "$BACKUP_CLOUD_DIR" config user.email "fk1124@users.noreply.github.com"
    git -C "$BACKUP_CLOUD_DIR" config core.autocrlf false

    if run_backup_git -C "$BACKUP_CLOUD_DIR" ls-remote --exit-code --heads origin "$BACKUP_REMOTE_BRANCH" >/dev/null 2>&1; then
        run_backup_git -C "$BACKUP_CLOUD_DIR" fetch -q origin "$BACKUP_REMOTE_BRANCH" || return 1
        git -C "$BACKUP_CLOUD_DIR" checkout -q -B "$BACKUP_REMOTE_BRANCH" "origin/$BACKUP_REMOTE_BRANCH"
    else
        git -C "$BACKUP_CLOUD_DIR" checkout -q -B "$BACKUP_REMOTE_BRANCH"
    fi
    mkdir -p "${BACKUP_CLOUD_DIR}/${BACKUP_REMOTE_PATH}"
}

backup_cloud_pull() {
    ensure_backup_cloud_repo || return 1
    if run_backup_git -C "$BACKUP_CLOUD_DIR" ls-remote --exit-code --heads origin "$BACKUP_REMOTE_BRANCH" >/dev/null 2>&1; then
        run_backup_git -C "$BACKUP_CLOUD_DIR" fetch -q origin "$BACKUP_REMOTE_BRANCH" || return 1
        git -C "$BACKUP_CLOUD_DIR" merge --ff-only "origin/${BACKUP_REMOTE_BRANCH}" >/dev/null 2>&1 || {
            warn "云端仓库存在本地未合并变更，请先手动处理：$BACKUP_CLOUD_DIR"
            return 1
        }
    fi
}

backup_manifest_value() {
    local file="$1" key="$2"
    sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n1
}

cloud_manifest_files() {
    local base="${BACKUP_CLOUD_DIR}/${BACKUP_REMOTE_PATH}"
    [ -d "$base" ] || return 0
    find "$base" -mindepth 2 -maxdepth 2 -type f -name manifest.env -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-
}

print_cloud_backups() {
    local -a manifests
    local idx manifest id name size created parts
    mapfile -t manifests < <(cloud_manifest_files)
    if [ "${#manifests[@]}" -eq 0 ]; then
        echo "  无云端备份。"
        return 0
    fi
    idx=1
    for manifest in "${manifests[@]}"; do
        id="$(backup_manifest_value "$manifest" BACKUP_ID)"
        name="$(backup_manifest_value "$manifest" CONTAINER_NAME)"
        size="$(backup_manifest_value "$manifest" SIZE_BYTES)"
        created="$(backup_manifest_value "$manifest" CREATED_AT)"
        parts="$(backup_manifest_value "$manifest" PARTS)"
        printf '  %2d. %-36s %-12s %9s  parts:%s  %s\n' \
            "$idx" "${id:-unknown}" "${name:-unknown}" "$(format_bytes "${size:-0}")" "${parts:-?}" "${created:-unknown}"
        idx=$((idx + 1))
    done
}

select_cloud_backup() {
    local prompt="${1:-请输入云端备份序号或备份 ID}"
    local -a manifests
    local input idx manifest
    mapfile -t manifests < <(cloud_manifest_files)
    if [ "${#manifests[@]}" -eq 0 ]; then
        warn "没有可用的云端备份。"
        return 1
    fi
    print_cloud_backups >&2
    read -r -p "$prompt: " input || input=""
    input="$(trim "$input")"
    [ -n "$input" ] || { warn "未输入云端备份。"; return 1; }
    case "$input" in
        *[!0-9]*)
            case "$input" in
                ""|*/*|*[!A-Za-z0-9_.-]*) warn "备份 ID 不合法：$input"; return 1 ;;
            esac
            manifest="${BACKUP_CLOUD_DIR}/${BACKUP_REMOTE_PATH}/${input}/manifest.env"
            ;;
        *)
            idx=$((10#$input))
            if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#manifests[@]}" ]; then
                warn "云端备份序号超出范围：$input"
                return 1
            fi
            manifest="${manifests[$((idx - 1))]}"
            ;;
    esac
    [ -f "$manifest" ] || { warn "云端备份不存在：$input"; return 1; }
    printf '%s\n' "$manifest"
}

backup_cloud_commit_push() {
    local message="$1"
    git -C "$BACKUP_CLOUD_DIR" add -A -- .
    if git -C "$BACKUP_CLOUD_DIR" diff --cached --quiet; then
        if git -C "$BACKUP_CLOUD_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
            if [ -n "$(git -C "$BACKUP_CLOUD_DIR" log --oneline '@{u}..HEAD' 2>/dev/null || true)" ]; then
                run_backup_git -C "$BACKUP_CLOUD_DIR" push -q origin "$BACKUP_REMOTE_BRANCH" || {
                    warn "推送云端仓库失败。"
                    return 1
                }
                ok "已推送之前未同步的云端提交。"
                return 0
            fi
        fi
        if git -C "$BACKUP_CLOUD_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
            ok "没有需要提交的云端变更。"
            return 0
        fi
    fi
    git -C "$BACKUP_CLOUD_DIR" commit -q -m "$message" || return 1
    run_backup_git -C "$BACKUP_CLOUD_DIR" push -q -u origin "$BACKUP_REMOTE_BRANCH" || {
        warn "推送云端仓库失败。"
        return 1
    }
}

backup_cloud_settings() {
    local repo_slug branch remote_path cache_dir split_size auth_choice token key_pub
    refresh_backup_remote_repo
    echo
    echo "========== 云端仓库备份设置 =========="
    echo "当前仓库      ：$BACKUP_REMOTE_SLUG"
    echo "Git 地址      ：$BACKUP_REMOTE_REPO"
    echo "当前分支      ：$BACKUP_REMOTE_BRANCH"
    echo "云端目录      ：$BACKUP_REMOTE_PATH"
    echo "本地缓存      ：$BACKUP_CLOUD_DIR"
    echo "分片大小      ：$BACKUP_SPLIT_SIZE"
    echo "鉴权方式      ：$BACKUP_REMOTE_AUTH"
    echo

    repo_slug="$(read_default "云端 GitHub 仓库（owner/repo）" "$BACKUP_REMOTE_SLUG")"
    branch="$(read_default "云端分支" "$BACKUP_REMOTE_BRANCH")"
    remote_path="$(read_default "云端备份目录" "$BACKUP_REMOTE_PATH")"
    cache_dir="$(read_default "本地云端缓存目录" "$BACKUP_CLOUD_DIR")"
    split_size="$(read_default "上传分片大小（建议 95M）" "$BACKUP_SPLIT_SIZE")"
    echo "鉴权方式：1. HTTPS Token  2. SSH Key  3. 无鉴权"
    read -r -p "请选择鉴权方式，直接回车保持当前设置: " auth_choice || auth_choice=""
    case "$auth_choice" in
        1) BACKUP_REMOTE_AUTH="https-token" ;;
        2) BACKUP_REMOTE_AUTH="ssh" ;;
        3) BACKUP_REMOTE_AUTH="none" ;;
        "") ;;
        *) warn "鉴权方式无效，保持原设置：$BACKUP_REMOTE_AUTH" ;;
    esac

    BACKUP_REMOTE_SLUG="$(normalize_backup_remote_slug "$repo_slug")"
    if ! valid_backup_remote_slug "$BACKUP_REMOTE_SLUG"; then
        warn "云端仓库格式不合法，请使用 owner/repo，例如 fk1124/EasePi-R2-Image-Backup。"
        BACKUP_REMOTE_SLUG="fk1124/EasePi-R2-Image-Backup"
    fi
    refresh_backup_remote_repo
    BACKUP_REMOTE_BRANCH="$branch"
    BACKUP_REMOTE_PATH="${remote_path#/}"
    BACKUP_REMOTE_PATH="${BACKUP_REMOTE_PATH%/}"
    valid_relative_path "$BACKUP_REMOTE_PATH" || {
        warn "云端备份目录不合法，已恢复为 backups。"
        BACKUP_REMOTE_PATH="backups"
    }
    BACKUP_CLOUD_DIR="${cache_dir%/}"
    BACKUP_SPLIT_SIZE="$split_size"

    if [ "$BACKUP_REMOTE_AUTH" = "https-token" ]; then
        mkdir -p "$(dirname "$BACKUP_REMOTE_TOKEN_FILE")"
        chmod 700 "$(dirname "$BACKUP_REMOTE_TOKEN_FILE")" 2>/dev/null || true
        echo
        echo "Token 文件：$BACKUP_REMOTE_TOKEN_FILE"
        read -r -s -p "请输入新的 GitHub Token（留空则不修改）: " token || token=""
        echo
        if [ -n "$token" ]; then
            umask 077
            printf '%s\n' "$token" > "$BACKUP_REMOTE_TOKEN_FILE"
            chmod 600 "$BACKUP_REMOTE_TOKEN_FILE"
            ok "Token 已保存。"
        elif [ ! -r "$BACKUP_REMOTE_TOKEN_FILE" ]; then
            warn "尚未配置 Token，云端私有仓库无法同步。"
        fi
    elif [ "$BACKUP_REMOTE_AUTH" = "ssh" ]; then
        if [ ! -f "$BACKUP_REMOTE_SSH_KEY" ]; then
            if command_exists ssh-keygen && confirm "未找到 SSH Key，是否现在生成？" y; then
                mkdir -p "$(dirname "$BACKUP_REMOTE_SSH_KEY")"
                ssh-keygen -t ed25519 -N "" -C "easepi-r2-image-backup" -f "$BACKUP_REMOTE_SSH_KEY"
            else
                warn "请先准备 SSH Key：$BACKUP_REMOTE_SSH_KEY"
            fi
        fi
        key_pub="${BACKUP_REMOTE_SSH_KEY}.pub"
        if [ -f "$key_pub" ]; then
            echo
            echo "请把下面的公钥添加到 GitHub 仓库 Deploy keys 或账号 SSH keys："
            cat "$key_pub"
        fi
    fi

    save_config
    ok "云端备份设置已保存。"
}

backup_cloud_upload() {
    local file base backup_id dest size sha created parts container_name
    file="$(select_local_backup "请输入要上传的本地备份序号或文件名")" || return 1
    backup_cloud_pull || return 1

    base="$(basename "$file")"
    backup_id="$(sanitize_backup_id "${base%.tar.zst}")"
    container_name="$(backup_container_name_from_file "$base")"
    dest="${BACKUP_CLOUD_DIR}/${BACKUP_REMOTE_PATH}/${backup_id}"
    if [ -e "$dest" ]; then
        confirm "云端已存在 ${backup_id}，是否覆盖？" n || { warn "已取消上传。"; return 1; }
        rm -rf "$dest"
    fi
    mkdir -p "$dest"

    size="$(file_size_bytes "$file")"
    sha="$(sha256sum "$file" | awk '{print $1}')"
    created="$(date -r "$file" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "正在分片：$base -> $backup_id（每片 $BACKUP_SPLIT_SIZE）"
    if ! split -b "$BACKUP_SPLIT_SIZE" -d -a 3 "$file" "${dest}/${backup_id}.tar.zst.part-"; then
        rm -rf "$dest"
        warn "备份分片失败。"
        return 1
    fi
    parts="$(find "$dest" -maxdepth 1 -type f -name '*.part-*' | wc -l | tr -d ' ')"
    {
        printf 'BACKUP_ID=%s\n' "$backup_id"
        printf 'BACKUP_FILE=%s\n' "$base"
        printf 'CONTAINER_NAME=%s\n' "$container_name"
        printf 'CREATED_AT=%s\n' "$created"
        printf 'SIZE_BYTES=%s\n' "$size"
        printf 'SHA256=%s\n' "$sha"
        printf 'PARTS=%s\n' "$parts"
        printf 'SPLIT_SIZE=%s\n' "$BACKUP_SPLIT_SIZE"
    } > "${dest}/manifest.env"

    backup_cloud_commit_push "Upload LXC backup ${backup_id}" || return 1
    ok "已上传云端备份：$backup_id"
}

backup_cloud_download() {
    local manifest dir backup_id backup_file dest tmp sha size total
    local -a parts
    backup_cloud_pull || return 1
    manifest="$(select_cloud_backup "请输入要下载的云端备份序号或备份 ID")" || return 1
    dir="$(dirname "$manifest")"
    backup_id="$(backup_manifest_value "$manifest" BACKUP_ID)"
    backup_file="$(backup_manifest_value "$manifest" BACKUP_FILE)"
    sha="$(backup_manifest_value "$manifest" SHA256)"
    [ -n "$backup_file" ] || backup_file="${backup_id}.tar.zst"
    mkdir -p "$BACKUP_DIR"
    dest="${BACKUP_DIR}/${backup_file}"
    tmp="${dest}.partial"
    if [ -e "$dest" ]; then
        confirm "本地已存在 ${backup_file}，是否覆盖？" n || { warn "已取消下载。"; return 1; }
    fi
    mapfile -t parts < <(find "$dir" -maxdepth 1 -type f -name '*.part-*' | sort)
    if [ "${#parts[@]}" -eq 0 ]; then
        warn "云端备份缺少分片文件：$backup_id"
        return 1
    fi
    total="$(find "$dir" -maxdepth 1 -type f -name '*.part-*' -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
    rm -f "$tmp"
    echo "正在下载到本地：$dest"
    if command_exists pv; then
        if ! cat "${parts[@]}" | pv -s "$total" > "$tmp"; then
            rm -f "$tmp"
            warn "合并云端分片失败。"
            return 1
        fi
    else
        if ! cat "${parts[@]}" > "$tmp"; then
            rm -f "$tmp"
            warn "合并云端分片失败。"
            return 1
        fi
    fi
    if [ -n "$sha" ]; then
        size="$(file_size_bytes "$tmp")"
        echo "已合并大小：$(format_bytes "$size")，正在校验 SHA256..."
        if ! echo "${sha}  ${tmp}" | sha256sum -c -; then
            rm -f "$tmp"
            warn "下载文件校验失败。"
            return 1
        fi
    fi
    mv -f "$tmp" "$dest"
    write_backup_sha256 "$dest"
    ok "云端备份已下载到本地：$dest"
}

backup_local_delete() {
    local file
    file="$(select_local_backup "请输入要删除的本地备份序号或文件名")" || return 1
    warn "即将删除本地备份：$file"
    confirm "确认删除？" n || { warn "已取消删除。"; return 1; }
    rm -f "$file" "${file}.sha256"
    ok "已删除本地备份：$(basename "$file")"
}

backup_cloud_delete() {
    local manifest backup_id confirm_id rel
    backup_cloud_pull || return 1
    manifest="$(select_cloud_backup "请输入要删除的云端备份序号或备份 ID")" || return 1
    backup_id="$(backup_manifest_value "$manifest" BACKUP_ID)"
    [ -n "$backup_id" ] || { warn "无法识别云端备份 ID。"; return 1; }
    warn "即将删除云端备份：$backup_id"
    read -r -p "请输入完整备份 ID 确认删除: " confirm_id || confirm_id=""
    if [ "$confirm_id" != "$backup_id" ]; then
        warn "确认内容不匹配，已取消删除。"
        return 1
    fi
    rel="${BACKUP_REMOTE_PATH}/${backup_id}"
    git -C "$BACKUP_CLOUD_DIR" rm -r -q -- "$rel" || {
        warn "删除云端备份文件失败。"
        return 1
    }
    backup_cloud_commit_push "Delete LXC backup ${backup_id}" || return 1
    ok "已删除云端备份：$backup_id"
}

backup_cloud_show_overview() {
    echo
    echo "========== 当前本地备份 =========="
    print_local_backups
    echo
    echo "========== 当前云端备份 =========="
    if ! backup_cloud_auth_ready; then
        warn "云端鉴权尚未就绪，暂不读取云端列表。"
    elif backup_cloud_pull; then
        print_cloud_backups
    else
        warn "暂时无法读取云端备份。请检查仓库名、鉴权方式和网络。"
    fi
}

backup_cloud_sync_menu() {
    local choice
    while true; do
        echo
        echo "========== 云端 git 同步管理 =========="
        backup_cloud_show_overview
        echo
        echo "1. 云端仓库备份设置 / 鉴权设置"
        echo "2. 本地备份上传云端"
        echo "3. 云端备份下载本地"
        echo "4. 删除本地备份"
        echo "5. 删除云端备份"
        echo "0. 返回"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1) menu_action backup_cloud_settings; load_config; pause_enter ;;
            2) menu_action backup_cloud_upload; pause_enter ;;
            3) menu_action backup_cloud_download; pause_enter ;;
            4) menu_action backup_local_delete; pause_enter ;;
            5) menu_action backup_cloud_delete; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

backup_restore_menu() {
    local choice
    while true; do
        echo
        echo "========== LXC 备份 / 还原 =========="
        echo "1. 备份容器（必须关机）"
        echo "2. 云端 git 同步管理"
        echo "3. 还原容器（仅本地备份）"
        echo "0. 返回"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1) menu_action backup_container; pause_enter ;;
            2) backup_cloud_sync_menu ;;
            3) menu_action restore_container; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

container_manage_menu() {
    local choice name
    while true; do
        echo
        echo "========== LXC 容器管理 =========="
        echo "1. 查看容器"
        echo "2. 启动容器"
        echo "3. 停止容器"
        echo "4. 重启容器"
        echo "5. 进入容器后台"
        echo "6. 启用容器开机自启动"
        echo "7. 取消容器开机自启动"
        echo "8. 修复所有容器开机自启动"
        echo "9. 生成容器快捷命令"
        echo "10. 补齐容器固定 MAC"
        echo "11. 删除容器"
        echo "0. 返回"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1)
                list_containers
                pause_enter
                ;;
            2)
                name="$(prompt_container_name "请输入要启动的容器名称")" || { pause_enter; continue; }
                menu_action start_container_by_name "$name"
                pause_enter
                ;;
            3)
                name="$(prompt_container_name "请输入要停止的容器名称")" || { pause_enter; continue; }
                menu_action stop_container_by_name "$name"
                pause_enter
                ;;
            4)
                name="$(prompt_container_name "请输入要重启的容器名称")" || { pause_enter; continue; }
                menu_action restart_container_by_name "$name"
                pause_enter
                ;;
            5)
                name="$(prompt_container_name "请输入要进入的容器名称")" || { pause_enter; continue; }
                menu_action attach_container_by_name "$name"
                ;;
            6)
                name="$(prompt_container_name "请输入要启用自启动的容器名称")" || { pause_enter; continue; }
                if container_is_openwrt_router "$name"; then
                    warn "OpenWrt 路由容器同一时间只建议一个开机自启动。"
                    while read -r other; do
                        [ "$other" = "$name" ] && continue
                        if container_is_openwrt_router "$other"; then
                            set_container_autostart "$other" 0
                        fi
                    done < <(container_names)
                fi
                menu_action set_container_autostart "$name" 1
                pause_enter
                ;;
            7)
                name="$(prompt_container_name "请输入要取消自启动的容器名称")" || { pause_enter; continue; }
                menu_action set_container_autostart "$name" 0
                pause_enter
                ;;
            8)
                menu_action repair_all_container_autostart
                pause_enter
                ;;
            9)
                menu_action write_all_container_shortcuts
                pause_enter
                ;;
            10)
                menu_action repair_all_container_stable_macs
                pause_enter
                ;;
            11)
                menu_action delete_container
                pause_enter
                ;;
            0)
                return 0
                ;;
            *)
                warn "无效选择。"
                ;;
        esac
    done
}

show_status() {
    echo
    echo "========== 当前状态 =========="
    show_lxc_dirs
    echo
    echo "容器列表："
    list_containers || true
    echo
    echo "网络："
    ip -br addr show "$HOST_BR" 2>/dev/null || true
    echo
    echo "默认路由："
    ip route show default 2>/dev/null || true
    echo
    echo "出口判断："
    ip route get "${HOST_OPENWRT_ROUTE_CHECK_IP:-223.5.5.5}" 2>/dev/null || true
    if ping -c 1 -W 1 "$OPENWRT_IP" >/dev/null 2>&1; then
        ok "OpenWrt 网关 ${OPENWRT_IP} 可达。"
    else
        warn "OpenWrt 网关 ${OPENWRT_IP} 不可达，宿主会保留其他默认路由兜底。"
    fi
}

main_menu() {
    local choice
    load_config
    while true; do
        echo
        echo "========== ${APP_NAME} =========="
        echo "1. 一键检测并安装 LXC 所有依赖"
        echo "2. 一键检测并安装 OpenWrt 所需 Kmod"
        echo "3. LXC 目录管理"
        echo "4. rootfs 管理"
        echo "5. 一键安装 OpenWrt 24"
        echo "6. 一键安装 OpenWrt 25"
        echo "7. 一键安装 Debian 12 Bookworm"
        echo "8. 一键安装 Debian 13 Trixie"
        echo "9. 一键安装 Ubuntu 24.04 Noble"
        echo "10. LXC 备份 / 还原"
        echo "11. 一键安装 Passwall（LXC 兼容，含中文翻译）"
        echo "12. 一键安装 EasyTier（LXC 兼容，含核心和中文翻译）"
        echo "13. LXC 容器管理"
        echo "14. 应用 OpenWrt 网络性能优化"
        echo "s. 查看当前状态"
        echo "0. 退出"
        read -r -p "请选择: " choice || exit 0
        case "$choice" in
            1) install_lxc_dependencies; pause_enter ;;
            2) check_openwrt_kmods; pause_enter ;;
            3) lxc_dirs_menu ;;
            4) rootfs_manager_menu ;;
            5) install_openwrt_router openwrt24; pause_enter ;;
            6) install_openwrt_router openwrt25; pause_enter ;;
            7) install_linux_container debian12; pause_enter ;;
            8) install_linux_container debian13; pause_enter ;;
            9) install_linux_container ubuntu24; pause_enter ;;
            10) backup_restore_menu ;;
            11) install_openwrt_lxc_passwall; pause_enter ;;
            12) install_openwrt_lxc_easytier; pause_enter ;;
            13) container_manage_menu ;;
            14) apply_openwrt_net_tune; pause_enter ;;
            s|S) show_status; pause_enter ;;
            0) exit 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

main_menu "$@"
