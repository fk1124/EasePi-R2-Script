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

HOST_BR="${HOST_BR:-br-hostlan}"
HOST_IP="${HOST_IP:-10.10.0.2}"
HOST_IP_CIDR="${HOST_IP_CIDR:-10.10.0.2/24}"
OPENWRT_IP="${OPENWRT_IP:-10.10.0.1}"
LAN_CIDR="${LAN_CIDR:-10.10.0.0/24}"
DHCP_START_IP="${DHCP_START_IP:-10.10.0.100}"
DHCP_END_IP="${DHCP_END_IP:-10.10.0.249}"
CANDIDATE_IFS="${CANDIDATE_IFS:-eth0 eth1 eth2 eth3}"

DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports}"
OPENWRT24_URL="${OPENWRT24_URL:-https://mirror.sjtu.edu.cn/openwrt/releases/24.10.6/targets/armsr/armv8/openwrt-24.10.6-armsr-armv8-rootfs.tar.gz}"
OPENWRT24_SHA256="${OPENWRT24_SHA256:-a0f7bdda2fe581e044b06d2f48788b76cbdb37cfa1e974d72ea981e391e04392}"
OPENWRT25_URL="${OPENWRT25_URL:-https://downloads.openwrt.org/releases/25.12.0/targets/armsr/armv8/openwrt-25.12.0-armsr-armv8-rootfs.tar.gz}"
OPENWRT25_SHA256="${OPENWRT25_SHA256:-d5e42b396d7f64697c65a884912107b49e05d2b2f2c00a251f94c44f8deef507}"

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

trim() {
    local s="$*"
    s="${s#${s%%[![:space:]]*}}"
    s="${s%${s##*[![:space:]]}}"
    printf '%s' "$s"
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
    : "${HOST_BR:=br-hostlan}"
    : "${HOST_IP:=10.10.0.2}"
    : "${HOST_IP_CIDR:=10.10.0.2/24}"
    : "${OPENWRT_IP:=10.10.0.1}"
    : "${LAN_CIDR:=10.10.0.0/24}"
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
        printf 'HOST_BR=%q\n' "$HOST_BR"
        printf 'HOST_IP=%q\n' "$HOST_IP"
        printf 'HOST_IP_CIDR=%q\n' "$HOST_IP_CIDR"
        printf 'OPENWRT_IP=%q\n' "$OPENWRT_IP"
        printf 'LAN_CIDR=%q\n' "$LAN_CIDR"
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
    local packages missing_packages modules ok_modules missing_modules mod
    packages=(
        kmod iproute2 iputils-ping ethtool bridge-utils
        iptables nftables ebtables arptables conntrack ipset
    )
    modules=(
        bridge br_netfilter veth tun overlay 8021q
        nf_tables nf_conntrack nf_nat nft_chain_nat nft_masq nft_redir
        nft_tproxy nft_socket nf_tproxy_ipv4 nf_tproxy_ipv6
        nf_socket_ipv4 nf_socket_ipv6 ip_set ip_set_hash_ip ip_set_hash_net
        x_tables ip_tables iptable_nat iptable_mangle
        xt_TPROXY xt_socket xt_mark xt_connmark xt_conntrack xt_REDIRECT xt_MASQUERADE
        wireguard
    )
    ok_modules=()
    missing_modules=()

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
        curl -L --fail --connect-timeout 20 --retry 3 -o "$tmp" "$url"
    else
        wget -O "$tmp" "$url"
    fi
    if [ -n "$sha" ]; then
        echo "${sha}  ${tmp}" | sha256sum -c -
    fi
    mv -f "$tmp" "$file"
    ok "下载完成：$file"
}

ensure_openwrt_rootfs() {
    local key="$1"
    download_file "$(rootfs_url "$key")" "$(rootfs_cache_file "$key")" "$(rootfs_sha256 "$key")"
}

debootstrap_rootfs() {
    local key="$1"
    local suite="$2"
    local mirror="$3"
    local include="$4"
    local cache_file
    local work rootfs keyring_arg
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
    if [[ "$key" == ubuntu* ]]; then
        if [ ! -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-keyring >/dev/null 2>&1 || true
        fi
        if [ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]; then
            keyring_arg=(--keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg)
        fi
    fi

    log "生成 $(rootfs_label "$key")，时间会稍长..."
    debootstrap --arch=arm64 --variant=minbase "${keyring_arg[@]}" --include="$include" "$suite" "$rootfs" "$mirror"

    configure_linux_rootfs_base "$rootfs" "$key"

    tar --numeric-owner --xattrs -C "$rootfs" -I 'zstd -19 -T0' -cpf "$cache_file" .
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

lxc_dirs_menu() {
    local choice
    while true; do
        echo
        echo "========== LXC 目录管理 =========="
        echo "1. 查看当前目录"
        echo "2. 修改 LXC 根目录"
        echo "3. 磁盘工具：检测 M.2/SSD 并挂载到 LXC 根目录"
        echo "0. 返回"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1) show_lxc_dirs; pause_enter ;;
            2) set_lxc_dirs; pause_enter ;;
            3) mount_lxc_to_ssd; pause_enter ;;
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

log "stop host network services that may own OpenWrt NICs..."
systemctl stop dnsmasq.service nftables.service NetworkManager.service NetworkManager-wait-online.service systemd-networkd.service lxc-net.service 2>/dev/null || true
systemctl disable dnsmasq.service nftables.service NetworkManager.service NetworkManager-wait-online.service systemd-networkd.service lxc-net.service 2>/dev/null || true

if [ -d /etc/systemd/network ]; then
    mkdir -p /etc/easepi-r2-lxc-manager/disabled-networkd
    for f in /etc/systemd/network/*easepi-r2*.network /etc/systemd/network/*easepi-r2*.netdev /etc/systemd/network/*easepi-r2*.link /etc/systemd/network/*r2-br-lan* /etc/systemd/network/*r2-lan-*; do
        [ -e "\$f" ] || continue
        mv "\$f" "/etc/easepi-r2-lxc-manager/disabled-networkd/\$(basename "\$f")" 2>/dev/null || true
    done
fi

for mod in bridge br_netfilter veth tun overlay nf_tables nf_conntrack nf_nat nft_chain_nat nft_masq nft_redir x_tables ip_tables iptable_nat iptable_mangle xt_MASQUERADE xt_REDIRECT xt_conntrack; do
    modprobe "\$mod" 2>/dev/null || true
done

mkdir -p /dev/net
[ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true
chmod 666 /dev/net/tun 2>/dev/null || true

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

write_openwrt_lxc_config() {
    local name="$1"
    local rootfs_dir="$2"
    local config_dir="$3"
    local net_idx=0
    local lan_idx=1
    local iface

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
lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file,optional
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

config interface 'wan'
        option device 'wan'
        option proto 'dhcp'

config interface 'wan6'
        option device 'wan'
        option proto 'dhcpv6'
EOF
        fi
    } > "${rootfs_dir}/etc/config/network"

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

ip route replace default via "\$OPENWRT_IP" dev "\$HOST_BR" metric 300 2>/dev/null || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<DNS
nameserver \$OPENWRT_IP
nameserver 223.5.5.5
nameserver 119.29.29.29
DNS

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

ensure_single_router_running() {
    local target="$1"
    local name
    for name in openwrt openwrt24 openwrt25; do
        [ "$name" = "$target" ] && continue
        if container_running "$name"; then
            die "检测到路由容器 $name 正在运行。OpenWrt 路由容器同一时间只建议运行一个，请先停止它。"
        fi
    done
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

backup_container() {
    local name dir file
    list_containers
    read -r -p "请输入要备份的容器名称: " name || name=""
    [ -n "$name" ] || die "容器名称不能为空。"
    dir="$(container_dir_for "$name")"
    [ -d "$dir" ] || die "容器不存在：$name"
    if container_running "$name"; then
        die "容器 $name 正在运行。请先 lxc-stop 后再备份。"
    fi
    mkdir -p "$BACKUP_DIR"
    file="${BACKUP_DIR}/${name}-$(date +%Y%m%d-%H%M%S).tar.zst"
    tar --numeric-owner --xattrs -C "$CONTAINER_DIR" -I 'zstd -19 -T0' -cpf "$file" "$name"
    ok "备份完成：$file"
}

restore_container() {
    local file name first
    mkdir -p "$BACKUP_DIR"
    echo
    echo "========== 可用备份 =========="
    find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.zst' -printf '  %f\n' 2>/dev/null || true
    read -r -p "请输入要还原的备份文件名或完整路径: " file || file=""
    [ -n "$file" ] || die "备份文件不能为空。"
    case "$file" in
        /*) ;;
        *) file="${BACKUP_DIR}/${file}" ;;
    esac
    [ -f "$file" ] || die "备份文件不存在：$file"

    set +o pipefail
    first="$(tar -I zstd -tf "$file" 2>/dev/null | head -n1)"
    set -o pipefail
    name="$(printf '%s' "$first" | cut -d/ -f1)"
    [ -n "$name" ] || die "无法识别备份内的容器名称。"
    [ ! -e "$(container_dir_for "$name")" ] || die "容器 $name 已存在，请先改名或删除。"
    tar --numeric-owner --xattrs -I zstd -xpf "$file" -C "$CONTAINER_DIR"
    ok "还原完成：$name"
}

backup_restore_menu() {
    local choice
    while true; do
        echo
        echo "========== LXC 备份 / 还原 =========="
        echo "1. 备份容器（必须关机）"
        echo "2. 还原容器"
        echo "0. 返回"
        read -r -p "请选择: " choice || return 0
        case "$choice" in
            1) backup_container; pause_enter ;;
            2) restore_container; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选择。" ;;
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
            s|S) show_status; pause_enter ;;
            0) exit 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

main_menu "$@"
