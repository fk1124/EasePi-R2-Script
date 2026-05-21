#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# R2 / iStoreNext 宿主初始化 OpenWrt 24.10.6 LXC
# 适配：直接通过 eth 口 SSH 执行，最后一步才断网切换
#
# 修正版：CUTOVER 后再设置宿主默认路由和 DNS，避免前置下载阶段断网
#
# 新增能力：
# - 开始阶段交互式选择要直通给 OpenWrt LXC 的网卡 eth0-eth3
# - 支持自定义 WAN 口、LAN 口列表
# - 支持自定义 LAN 网段、OpenWrt LAN IP、iStoreNext 宿主 IP、DHCP 地址池
#
# 默认规划：
# - WAN：eth0
# - LAN：eth1 eth2 eth3
# - OpenWrt LAN：10.10.0.1/24
# - iStoreNext 宿主：10.10.0.2/24，接入 OpenWrt LAN
# - OpenWrt DHCP：10.10.0.100 - 10.10.0.249
# - apt 默认国内源：清华 TUNA Debian 镜像
# - OpenWrt rootfs 默认国内源：上海交通大学 SJTUG OpenWrt 镜像
#
# 重要说明：
# - 本脚本请在 iStoreNext/Debian 宿主执行，不要在 OpenWrt 容器里执行
# - 脚本前半段不会释放所选 eth 网卡，尽量保证当前 SSH 不断
# - 最后一阶段才会通过 systemd 后台执行“切网 + 启动容器”，届时 SSH 可能断开
# - 断开后，请把电脑网线接到你选择的 OpenWrt LAN 口，并设置自动获取 IP
# =========================================================

CT_NAME="${CT_NAME:-openwrt}"
CT_DIR="/var/lib/lxc/${CT_NAME}"
ROOTFS_DIR="${CT_DIR}/rootfs"

CANDIDATE_IFS="${CANDIDATE_IFS:-eth0 eth1 eth2 eth3}"
HOST_BR="${HOST_BR:-br-hostlan}"

# 国内镜像默认值：
# - APT：默认使用清华 TUNA Debian / debian-security 镜像
# - OpenWrt rootfs：默认使用上海交通大学 SJTUG OpenWrt 镜像
# 如需改回官方源，可在执行脚本前通过环境变量覆盖 ROOTFS_URL / APT_MIRROR / APT_SECURITY_MIRROR。
APT_MIRROR="${APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
APT_SECURITY_MIRROR="${APT_SECURITY_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian-security}"
APT_COMPONENTS_DEFAULT="main contrib non-free non-free-firmware"
ENABLE_APT_CHINA_MIRROR="${ENABLE_APT_CHINA_MIRROR:-1}"

ROOTFS_URL="${ROOTFS_URL:-https://mirror.sjtu.edu.cn/openwrt/releases/24.10.6/targets/armsr/armv8/openwrt-24.10.6-armsr-armv8-rootfs.tar.gz}"
ROOTFS_FILE="${ROOTFS_FILE:-/tmp/openwrt-24.10.6-rootfs.tar.gz}"
ROOTFS_SHA256="${ROOTFS_SHA256:-a0f7bdda2fe581e044b06d2f48788b76cbdb37cfa1e974d72ea981e391e04392}"

# 可用环境变量跳过交互：
#   SKIP_WIZARD=1 WAN_IF=eth0 LAN_IFS="eth1 eth2 eth3" LAN_CIDR=10.10.0.0/24 \
#   OPENWRT_IP=10.10.0.1 HOST_IP=10.10.0.2 DHCP_START_IP=10.10.0.100 DHCP_END_IP=10.10.0.249 bash xxx.sh
SKIP_WIZARD="${SKIP_WIZARD:-0}"
SKIP_CONFIRM="${SKIP_CONFIRM:-0}"
DISABLE_HOST_ROUTER_STACK="${DISABLE_HOST_ROUTER_STACK:-1}"

# 下面这些变量会由交互配置阶段生成
WAN_IF="${WAN_IF:-}"
LAN_IFS="${LAN_IFS:-}"
PHYS_IFS=""
LAN_CIDR="${LAN_CIDR:-10.10.0.0/24}"
LAN_NET=""
CIDR_PREFIX=""
LAN_NETMASK=""
OPENWRT_IP="${OPENWRT_IP:-}"
HOST_IP="${HOST_IP:-}"
HOST_IP_CIDR=""
DHCP_START_IP="${DHCP_START_IP:-}"
DHCP_END_IP="${DHCP_END_IP:-}"
DHCP_START_OFFSET=""
DHCP_LIMIT=""
DHCP_RANGE=""
LAN_DEV_NAMES=""
HAS_WAN="0"
SSH_CLIENT_IP=""
SSH_CLIENT_DEV=""

if [ "$(id -u)" != "0" ]; then
    echo "请用 root 执行。"
    exit 1
fi

log() {
    echo "[lxc-openwrt] $*"
}

die() {
    echo "错误：$*" >&2
    exit 1
}

trim() {
    local s="$*"
    s="${s#${s%%[![:space:]]*}}"
    s="${s%${s##*[![:space:]]}}"
    printf '%s' "$s"
}

word_in_list() {
    local word="$1"
    shift || true
    local item
    for item in "$@"; do
        [ "$item" = "$word" ] && return 0
    done
    return 1
}

is_candidate_if() {
    local target="$1"
    local item
    for item in $CANDIDATE_IFS; do
        [ "$item" = "$target" ] && return 0
    done
    return 1
}

iface_exists() {
    ip link show "$1" >/dev/null 2>&1
}

normalize_if_list() {
    local raw="$1"
    local out=""
    local item=""
    raw="$(printf '%s' "$raw" | tr ',，;' '   ')"
    raw="$(trim "$raw")"

    if [ -z "$raw" ] || [ "$raw" = "none" ] || [ "$raw" = "NONE" ] || [ "$raw" = "无" ]; then
        printf '%s' ""
        return 0
    fi

    for item in $raw; do
        if ! is_candidate_if "$item"; then
            die "${item} 不在允许范围内，只支持：${CANDIDATE_IFS}"
        fi
        if ! printf ' %s ' "$out" | grep -q " ${item} "; then
            out="$(trim "$out $item")"
        fi
    done
    printf '%s' "$out"
}

ip_to_int() {
    local ip="$1"
    local a b c d
    IFS=. read -r a b c d <<EOF
$ip
EOF
    [ -n "${a:-}" ] && [ -n "${b:-}" ] && [ -n "${c:-}" ] && [ -n "${d:-}" ] || return 1
    case "$a$b$c$d" in
        *[!0-9]*) return 1 ;;
    esac
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

cidr_to_mask_int() {
    local prefix="$1"
    if [ "$prefix" -eq 0 ]; then
        echo 0
    else
        echo $(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    fi
}

cidr_to_netmask() {
    local prefix="$1"
    local mask
    mask="$(cidr_to_mask_int "$prefix")"
    int_to_ip "$mask"
}

strip_ip_prefix() {
    local ip="$1"
    ip="$(trim "$ip")"
    ip="${ip%%/*}"
    printf '%s' "$ip"
}

set_lan_cidr_values() {
    local cidr="$1"
    local ip_part prefix ip_int mask_int network_int broadcast_int host_count canonical_net

    cidr="$(trim "$cidr")"
    case "$cidr" in
        */*) ;;
        *) die "LAN 网段必须写成 CIDR 格式，例如 10.10.0.0/24" ;;
    esac

    ip_part="${cidr%%/*}"
    prefix="${cidr##*/}"

    case "$prefix" in
        *[!0-9]*|'') die "CIDR 前缀不正确：${prefix}" ;;
    esac

    # 家用/小型办公场景建议 /24；这里放宽到 /16 - /24，避免 DHCP 默认池计算复杂且不易误配。
    if [ "$prefix" -lt 16 ] || [ "$prefix" -gt 24 ]; then
        die "当前脚本建议使用 /16 到 /24 的 LAN 网段，例如 10.10.0.0/24、192.168.50.0/24、172.16.10.0/24"
    fi

    ip_int="$(ip_to_int "$ip_part")" || die "LAN 网段 IP 不合法：${ip_part}"
    mask_int="$(cidr_to_mask_int "$prefix")"
    network_int=$(( ip_int & mask_int ))
    broadcast_int=$(( network_int | (0xffffffff ^ mask_int) ))
    host_count=$(( broadcast_int - network_int - 1 ))
    [ "$host_count" -ge 250 ] || die "该网段可用地址太少，不适合默认 DHCP 池。请使用 /24 或更大的地址池。"

    canonical_net="$(int_to_ip "$network_int")/${prefix}"
    LAN_CIDR="$canonical_net"
    LAN_NET="$(int_to_ip "$network_int")/${prefix}"
    CIDR_PREFIX="$prefix"
    LAN_NETMASK="$(cidr_to_netmask "$prefix")"

    NETWORK_INT="$network_int"
    BROADCAST_INT="$broadcast_int"
}

ip_in_lan_host_range() {
    local ip="$1"
    local ip_int
    ip_int="$(ip_to_int "$ip")" || return 1
    [ "$ip_int" -gt "$NETWORK_INT" ] && [ "$ip_int" -lt "$BROADCAST_INT" ]
}

prompt_with_default() {
    local label="$1"
    local default="$2"
    local input=""

    if [ "$SKIP_WIZARD" = "1" ] || [ ! -t 0 ]; then
        printf '%s' "$default"
        return 0
    fi

    read -r -p "${label} [默认：${default}]：" input
    input="$(trim "$input")"
    if [ -z "$input" ]; then
        printf '%s' "$default"
    else
        printf '%s' "$input"
    fi
}

default_existing_if() {
    local fallback="$1"
    local item
    for item in $CANDIDATE_IFS; do
        if [ "$item" = "$fallback" ] && iface_exists "$item"; then
            echo "$item"
            return 0
        fi
    done
    for item in $CANDIDATE_IFS; do
        if iface_exists "$item"; then
            echo "$item"
            return 0
        fi
    done
    echo "$fallback"
}

default_lan_ifs_except() {
    local except="$1"
    local out=""
    local item
    for item in $CANDIDATE_IFS; do
        [ "$item" = "$except" ] && continue
        # 若系统能识别 eth 口，只默认选择真实存在的；若识别失败，仍保留 eth1-eth3 传统默认值。
        if iface_exists "$item" || [ "$item" = "eth1" ] || [ "$item" = "eth2" ] || [ "$item" = "eth3" ]; then
            out="$(trim "$out $item")"
        fi
    done
    echo "$out"
}

warn_missing_ifaces() {
    local item
    for item in $PHYS_IFS; do
        if ! iface_exists "$item"; then
            echo "警告：当前系统暂时没有检测到 ${item}，请确认网口命名是否正确。"
        fi
    done
}

detect_ssh_client_dev() {
    SSH_CLIENT_IP="$(printf '%s' "${SSH_CLIENT:-}" | awk '{print $1}')"
    if [ -n "$SSH_CLIENT_IP" ]; then
        SSH_CLIENT_DEV="$(ip route get "$SSH_CLIENT_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}' || true)"
    fi
}

show_current_network_status() {
    local item carrier operstate

    echo "========================================================="
    echo " 当前宿主网络状态"
    echo "========================================================="

    echo
    echo "[1] 所有网卡链路状态："
    ip -br link show || true

    echo
    echo "[2] 所有网卡 IP 地址："
    ip -br addr show || true

    echo
    echo "[3] 当前默认网关 / 默认路由："
    if ip route show default | grep -q .; then
        ip route show default || true
    else
        echo "未检测到默认路由。"
    fi

    echo
    echo "[4] 当前主路由表："
    ip route show || true

    echo
    echo "[5] 候选 eth 网口状态：${CANDIDATE_IFS}"
    for item in $CANDIDATE_IFS; do
        if iface_exists "$item"; then
            operstate="unknown"
            carrier="unknown"

            if [ -r "/sys/class/net/${item}/operstate" ]; then
                operstate="$(cat "/sys/class/net/${item}/operstate" 2>/dev/null || echo unknown)"
            fi

            if [ -r "/sys/class/net/${item}/carrier" ]; then
                carrier="$(cat "/sys/class/net/${item}/carrier" 2>/dev/null || echo unknown)"
            fi

            echo
            echo "  - ${item}: 存在，operstate=${operstate}，carrier=${carrier}"
            ip -br link show dev "$item" || true
            ip -br addr show dev "$item" || true
        else
            echo
            echo "  - ${item}: 不存在 / 当前系统未识别"
        fi
    done

    detect_ssh_client_dev

    echo
    echo "[6] 当前 SSH 连接："
    if [ -n "${SSH_CLIENT_IP:-}" ]; then
        echo "SSH 来源 IP ：${SSH_CLIENT_IP}"
        echo "SSH 路由出口：${SSH_CLIENT_DEV:-未知}"
    else
        echo "未检测到 SSH_CLIENT，可能不是通过 SSH 执行，或当前 shell 未保留该变量。"
    fi

    echo
    echo "========================================================="
}

detect_debian_codename() {
    local codename=""

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        codename="${VERSION_CODENAME:-}"
    fi

    if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
        codename="$(lsb_release -sc 2>/dev/null || true)"
    fi

    if [ -z "$codename" ] && [ -r /etc/debian_version ]; then
        case "$(cat /etc/debian_version 2>/dev/null)" in
            13*|trixie*) codename="trixie" ;;
            12*|bookworm*) codename="bookworm" ;;
            11*|bullseye*) codename="bullseye" ;;
            10*|buster*) codename="buster" ;;
        esac
    fi

    printf '%s' "$codename"
}

apt_components_for_codename() {
    local codename="$1"
    case "$codename" in
        buster|bullseye)
            printf '%s' "main contrib non-free"
            ;;
        *)
            printf '%s' "${APT_COMPONENTS:-$APT_COMPONENTS_DEFAULT}"
            ;;
    esac
}

configure_apt_china_mirror() {
    [ "${ENABLE_APT_CHINA_MIRROR}" = "1" ] || {
        log "跳过 apt 国内源替换：ENABLE_APT_CHINA_MIRROR=${ENABLE_APT_CHINA_MIRROR}"
        return 0
    }

    command -v apt-get >/dev/null 2>&1 || {
        log "未检测到 apt-get，跳过 apt 源替换。"
        return 0
    }

    local codename components ts backup_dir sources_list deb822_file
    codename="$(detect_debian_codename)"
    case "$codename" in
        trixie|bookworm|bullseye|buster) ;;
        *)
            log "未能识别 Debian 版本代号：${codename:-未知}，为避免误改 apt 源，已跳过自动替换。"
            log "如需强制指定，可先手工设置 /etc/apt/sources.list，或把 VERSION_CODENAME 写入 /etc/os-release。"
            return 0
            ;;
    esac

    components="$(apt_components_for_codename "$codename")"
    ts="$(date +%Y%m%d-%H%M%S)"
    backup_dir="/etc/apt/backup-before-openwrt-lxc-${ts}"
    sources_list="/etc/apt/sources.list"
    deb822_file="/etc/apt/sources.list.d/debian.sources"

    log "准备把 Debian apt 源切换为国内镜像。"
    log "Debian 版本：${codename}"
    log "Debian 主源：${APT_MIRROR}"
    log "Debian 安全源：${APT_SECURITY_MIRROR}"

    mkdir -p "$backup_dir"

    if [ -f "$sources_list" ]; then
        cp -a "$sources_list" "$backup_dir/sources.list"
    fi
    if [ -f "$deb822_file" ]; then
        cp -a "$deb822_file" "$backup_dir/debian.sources"
    fi

    if [ -f "$deb822_file" ]; then
        cat > "$deb822_file" <<APTDEB822
Types: deb
URIs: ${APT_MIRROR}
Suites: ${codename} ${codename}-updates ${codename}-backports
Components: ${components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${APT_SECURITY_MIRROR}
Suites: ${codename}-security
Components: ${components}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
APTDEB822

        if [ -f "$sources_list" ]; then
            cat > "$sources_list" <<APTLIST
# 已由 lxc.openwrt 脚本切换为 DEB822 格式国内源。
# 原文件已备份到：${backup_dir}/sources.list
# 当前主要源文件：${deb822_file}
APTLIST
        fi
    else
        cat > "$sources_list" <<APTLIST
# Debian ${codename} 国内镜像源，由 lxc.openwrt 脚本自动写入
# 原文件备份目录：${backup_dir}

deb ${APT_MIRROR} ${codename} ${components}
deb ${APT_MIRROR} ${codename}-updates ${components}
deb ${APT_MIRROR} ${codename}-backports ${components}
deb ${APT_SECURITY_MIRROR} ${codename}-security ${components}
APTLIST
    fi

    log "apt 源替换完成，原配置已备份到：${backup_dir}"
}

sha256_file_ok() {
    local file="$1"
    local sha256="$2"

    [ -f "$file" ] || return 1
    echo "${sha256}  ${file}" | sha256sum -c - >/dev/null 2>&1
}

fetch_openwrt_rootfs() {
    local tmp_file="${ROOTFS_FILE}.tmp"

    if sha256_file_ok "$ROOTFS_FILE" "$ROOTFS_SHA256"; then
        log "复用已下载并校验通过的 rootfs：${ROOTFS_FILE}"
        return 0
    fi

    rm -f "$tmp_file"
    log "下载 OpenWrt rootfs：${ROOTFS_URL}"
    wget -O "$tmp_file" "$ROOTFS_URL"

    log "校验 rootfs sha256..."
    echo "${ROOTFS_SHA256}  ${tmp_file}" | sha256sum -c -
    mv -f "$tmp_file" "$ROOTFS_FILE"
}

configure_interactive() {
    local default_wan default_lan raw_wan raw_lan raw_cidr raw_openwrt raw_host raw_dhcp_start raw_dhcp_end
    local openwrt_default host_default dhcp_start_default dhcp_end_default
    local openwrt_int host_int dhcp_start_int dhcp_end_int item idx

    cat <<MSG

=========================================================
 OpenWrt LXC 初始化脚本：交互式配置
=========================================================
 你可以在开始阶段自由选择：
   1. 哪个 eth 口作为 OpenWrt WAN
   2. 哪些 eth 口作为 OpenWrt LAN
   3. OpenWrt LAN 网段、OpenWrt IP、宿主 iStoreNext IP、DHCP 池

 支持网口范围：${CANDIDATE_IFS}
 建议网段格式：10.10.0.0/24、192.168.50.0/24、172.16.10.0/24
=========================================================
MSG

    show_current_network_status
    echo

    default_wan="$(default_existing_if eth0)"
    raw_wan="$(prompt_with_default "请选择 OpenWrt WAN 口，填 none 表示暂不设置 WAN" "${WAN_IF:-$default_wan}")"
    raw_wan="$(trim "$raw_wan")"
    if [ "$raw_wan" = "none" ] || [ "$raw_wan" = "NONE" ] || [ "$raw_wan" = "无" ]; then
        WAN_IF="none"
        HAS_WAN="0"
    else
        WAN_IF="$(normalize_if_list "$raw_wan")"
        case "$WAN_IF" in
            *' '*) die "WAN 口只能选择一个网卡，不能填写多个：${WAN_IF}" ;;
        esac
        [ -n "$WAN_IF" ] || die "WAN 口不能为空；如不需要 WAN，请填 none"
        HAS_WAN="1"
    fi

    if [ "$WAN_IF" = "none" ]; then
        default_lan="$(default_lan_ifs_except '')"
    else
        default_lan="$(default_lan_ifs_except "$WAN_IF")"
    fi
    [ -n "$default_lan" ] || default_lan="eth1 eth2 eth3"

    raw_lan="$(prompt_with_default "请选择 OpenWrt LAN 口，多个网口用空格隔开" "${LAN_IFS:-$default_lan}")"
    LAN_IFS="$(normalize_if_list "$raw_lan")"
    [ -n "$LAN_IFS" ] || die "LAN 口至少选择一个物理网卡；如果你确实只想用 host0，请手动把脚本里的校验放开。"

    if [ "$WAN_IF" != "none" ]; then
        for item in $LAN_IFS; do
            [ "$item" = "$WAN_IF" ] && die "${item} 不能同时作为 WAN 和 LAN"
        done
    fi

    if [ "$WAN_IF" = "none" ]; then
        PHYS_IFS="$LAN_IFS"
    else
        PHYS_IFS="$(normalize_if_list "$WAN_IF $LAN_IFS")"
    fi

    raw_cidr="$(prompt_with_default "请输入 OpenWrt LAN 网段 CIDR" "$LAN_CIDR")"
    set_lan_cidr_values "$raw_cidr"

    openwrt_default="$(int_to_ip $(( NETWORK_INT + 1 )))"
    host_default="$(int_to_ip $(( NETWORK_INT + 2 )))"
    dhcp_start_default="$(int_to_ip $(( NETWORK_INT + 100 )))"
    dhcp_end_default="$(int_to_ip $(( NETWORK_INT + 249 )))"

    raw_openwrt="$(prompt_with_default "请输入 OpenWrt LAN IP" "${OPENWRT_IP:-$openwrt_default}")"
    OPENWRT_IP="$(strip_ip_prefix "$raw_openwrt")"
    ip_in_lan_host_range "$OPENWRT_IP" || die "OpenWrt IP ${OPENWRT_IP} 不在 ${LAN_NET} 可用主机范围内"

    raw_host="$(prompt_with_default "请输入 iStoreNext 宿主 IP" "${HOST_IP:-$host_default}")"
    HOST_IP="$(strip_ip_prefix "$raw_host")"
    ip_in_lan_host_range "$HOST_IP" || die "宿主 IP ${HOST_IP} 不在 ${LAN_NET} 可用主机范围内"

    [ "$HOST_IP" != "$OPENWRT_IP" ] || die "OpenWrt IP 和宿主 IP 不能相同"

    raw_dhcp_start="$(prompt_with_default "请输入 DHCP 起始 IP" "${DHCP_START_IP:-$dhcp_start_default}")"
    DHCP_START_IP="$(strip_ip_prefix "$raw_dhcp_start")"
    ip_in_lan_host_range "$DHCP_START_IP" || die "DHCP 起始 IP ${DHCP_START_IP} 不在 ${LAN_NET} 可用主机范围内"

    raw_dhcp_end="$(prompt_with_default "请输入 DHCP 结束 IP" "${DHCP_END_IP:-$dhcp_end_default}")"
    DHCP_END_IP="$(strip_ip_prefix "$raw_dhcp_end")"
    ip_in_lan_host_range "$DHCP_END_IP" || die "DHCP 结束 IP ${DHCP_END_IP} 不在 ${LAN_NET} 可用主机范围内"

    openwrt_int="$(ip_to_int "$OPENWRT_IP")"
    host_int="$(ip_to_int "$HOST_IP")"
    dhcp_start_int="$(ip_to_int "$DHCP_START_IP")"
    dhcp_end_int="$(ip_to_int "$DHCP_END_IP")"

    [ "$dhcp_start_int" -le "$dhcp_end_int" ] || die "DHCP 起始 IP 不能大于结束 IP"
    [ "$openwrt_int" -lt "$dhcp_start_int" ] || [ "$openwrt_int" -gt "$dhcp_end_int" ] || die "OpenWrt IP 不能落在 DHCP 地址池内"
    [ "$host_int" -lt "$dhcp_start_int" ] || [ "$host_int" -gt "$dhcp_end_int" ] || die "宿主 IP 不能落在 DHCP 地址池内"

    HOST_IP_CIDR="${HOST_IP}/${CIDR_PREFIX}"
    DHCP_START_OFFSET=$(( dhcp_start_int - NETWORK_INT ))
    DHCP_LIMIT=$(( dhcp_end_int - dhcp_start_int + 1 ))
    DHCP_RANGE="${DHCP_START_IP} - ${DHCP_END_IP}"

    LAN_DEV_NAMES=""
    idx=1
    for item in $LAN_IFS; do
        LAN_DEV_NAMES="$(trim "$LAN_DEV_NAMES lan${idx}")"
        idx=$((idx + 1))
    done

    detect_ssh_client_dev
    warn_missing_ifaces

    cat <<MSG

=========================================================
 配置确认
=========================================================
 OpenWrt WAN 口        ：${WAN_IF}
 OpenWrt LAN 物理口    ：${LAN_IFS}
 将被交给 LXC 的物理口 ：${PHYS_IFS}
 宿主反桥接网桥        ：${HOST_BR} / host0
 LAN 网段              ：${LAN_NET}
 LAN 掩码              ：${LAN_NETMASK}
 OpenWrt LAN IP        ：${OPENWRT_IP}
 iStoreNext 宿主 IP    ：${HOST_IP_CIDR}
 DHCP 地址池           ：${DHCP_RANGE}
 DHCP UCI start/limit  ：${DHCP_START_OFFSET} / ${DHCP_LIMIT}
 apt 国内源             ：${APT_MIRROR}
 OpenWrt rootfs 源      ：${ROOTFS_URL}
MSG

    if [ -n "$SSH_CLIENT_IP" ]; then
        echo " 当前 SSH 来源 IP      ：${SSH_CLIENT_IP}"
        echo " 当前 SSH 路由出口      ：${SSH_CLIENT_DEV:-未知}"
        if printf ' %s ' "$PHYS_IFS" | grep -q " ${SSH_CLIENT_DEV} "; then
            echo " 注意：当前 SSH 可能正经过 ${SSH_CLIENT_DEV}，最后 CUTOVER 时断开是正常现象。"
        fi
    fi

    cat <<MSG
=========================================================
MSG
}

configure_interactive

if [ "$SKIP_CONFIRM" != "1" ]; then
    if [ ! -t 0 ]; then
        die "当前不是交互式终端，无法输入确认。请使用 bash -c 方式执行脚本，或确认风险后设置 SKIP_CONFIRM=1。"
    fi
    read -r -p "确认开始准备请输入 YES ：" CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "已取消。"
        exit 0
    fi
fi

echo
echo "========== 阶段 1：切换 apt 国内源并安装宿主依赖 =========="
configure_apt_china_mirror
apt update

apt install -y \
  lxc \
  lxcfs \
  uidmap \
  debootstrap \
  qemu-user-static \
  binfmt-support \
  fuse-overlayfs \
  slirp4netns \
  kmod \
  iproute2 \
  bridge-utils \
  nftables \
  iptables \
  ipset \
  conntrack \
  ethtool \
  tcpdump \
  curl \
  wget \
  ca-certificates \
  tar \
  gzip \
  xz-utils \
  zstd \
  procps \
  psmisc \
  wireguard-tools

echo
echo "========== 阶段 1：加载宿主内核模块 =========="

load_mod() {
    modprobe "$1" 2>/dev/null || true
}

# 基础容器 / 网络模块
load_mod bridge
load_mod br_netfilter
load_mod veth

# TUN
load_mod tun
load_mod wireguard

# nftables / conntrack / NAT
load_mod nf_tables
load_mod nf_conntrack
load_mod nf_conntrack_ipv4
load_mod nf_conntrack_ipv6
load_mod nf_defrag_ipv4
load_mod nf_defrag_ipv6
load_mod nf_nat

# nftables NAT / redirect / tproxy / socket
load_mod nft_chain_nat
load_mod nft_masq
load_mod nft_redir
load_mod nft_tproxy
load_mod nft_socket

# nf tproxy / socket
load_mod nf_tproxy_ipv4
load_mod nf_tproxy_ipv6
load_mod nf_socket_ipv4
load_mod nf_socket_ipv6

# ipset
load_mod ip_set
load_mod ip_set_hash_ip
load_mod ip_set_hash_net
load_mod ip_set_bitmap_ip

# iptables / xtables 兼容
load_mod x_tables
load_mod ip_tables
load_mod iptable_mangle
load_mod iptable_nat
load_mod xt_TPROXY
load_mod xt_socket
load_mod xt_mark
load_mod xt_connmark
load_mod xt_conntrack
load_mod xt_REDIRECT
load_mod xt_MASQUERADE

echo
echo "========== 阶段 1：准备 /dev/net/tun =========="
mkdir -p /dev/net
if [ ! -e /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200 || true
fi
chmod 666 /dev/net/tun || true
ls -l /dev/net/tun || true

echo
echo "========== 阶段 2：写入宿主网络准备脚本 =========="

cat > /usr/local/sbin/owrt-lxc-hostnet.sh <<HOSTNET
#!/bin/sh
set -eu

PHYS_IFS="${PHYS_IFS}"
HOST_BR="${HOST_BR}"
HOST_IP="${HOST_IP_CIDR}"
OPENWRT_IP="${OPENWRT_IP}"
DISABLE_HOST_ROUTER_STACK="${DISABLE_HOST_ROUTER_STACK}"

log() {
    echo "[owrt-lxc-hostnet] \$*"
}

disable_conflicting_host_network_stack() {
    [ "\$DISABLE_HOST_ROUTER_STACK" = "1" ] || {
        log "skip host router stack disable: DISABLE_HOST_ROUTER_STACK=\$DISABLE_HOST_ROUTER_STACK"
        return 0
    }

    log "stopping host router/network services that may own physical NICs..."
    systemctl stop dnsmasq.service nftables.service NetworkManager.service NetworkManager-wait-online.service systemd-networkd.service 2>/dev/null || true
    systemctl disable dnsmasq.service nftables.service NetworkManager.service NetworkManager-wait-online.service systemd-networkd.service 2>/dev/null || true

    if [ -d /etc/systemd/network ]; then
        mkdir -p /etc/easepi-r2-openwrt-lxc/disabled-networkd
        for f in /etc/systemd/network/*easepi-r2*.network /etc/systemd/network/*easepi-r2*.netdev /etc/systemd/network/*easepi-r2*.link; do
            [ -e "\$f" ] || continue
            mv "\$f" "/etc/easepi-r2-openwrt-lxc/disabled-networkd/\$(basename "\$f")" 2>/dev/null || true
        done
    fi
}

disable_conflicting_host_network_stack

log "loading kernel modules..."

modprobe bridge 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
modprobe veth 2>/dev/null || true

modprobe tun 2>/dev/null || true
modprobe wireguard 2>/dev/null || true

modprobe nf_tables 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
modprobe nf_conntrack_ipv4 2>/dev/null || true
modprobe nf_conntrack_ipv6 2>/dev/null || true
modprobe nf_defrag_ipv4 2>/dev/null || true
modprobe nf_defrag_ipv6 2>/dev/null || true
modprobe nf_nat 2>/dev/null || true

modprobe nft_chain_nat 2>/dev/null || true
modprobe nft_masq 2>/dev/null || true
modprobe nft_redir 2>/dev/null || true
modprobe nft_tproxy 2>/dev/null || true
modprobe nft_socket 2>/dev/null || true

modprobe nf_tproxy_ipv4 2>/dev/null || true
modprobe nf_tproxy_ipv6 2>/dev/null || true
modprobe nf_socket_ipv4 2>/dev/null || true
modprobe nf_socket_ipv6 2>/dev/null || true

modprobe ip_set 2>/dev/null || true
modprobe ip_set_hash_ip 2>/dev/null || true
modprobe ip_set_hash_net 2>/dev/null || true
modprobe ip_set_bitmap_ip 2>/dev/null || true

modprobe x_tables 2>/dev/null || true
modprobe ip_tables 2>/dev/null || true
modprobe iptable_mangle 2>/dev/null || true
modprobe iptable_nat 2>/dev/null || true
modprobe xt_TPROXY 2>/dev/null || true
modprobe xt_socket 2>/dev/null || true
modprobe xt_mark 2>/dev/null || true
modprobe xt_connmark 2>/dev/null || true
modprobe xt_conntrack 2>/dev/null || true
modprobe xt_REDIRECT 2>/dev/null || true
modprobe xt_MASQUERADE 2>/dev/null || true

log "preparing /dev/net/tun..."
mkdir -p /dev/net
if [ ! -e /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200 || true
fi
chmod 666 /dev/net/tun || true

log "preparing bridge \${HOST_BR} with \${HOST_IP}..."
if ! ip link show "\$HOST_BR" >/dev/null 2>&1; then
    ip link add "\$HOST_BR" type bridge
fi

ip link set "\$HOST_BR" up
ip addr replace "\$HOST_IP" dev "\$HOST_BR"
ip link set dev "\$HOST_BR" type bridge stp_state 0 2>/dev/null || true

log "releasing selected physical NICs to LXC: \${PHYS_IFS}"
for IF in \$PHYS_IFS; do
    if ip link show "\$IF" >/dev/null 2>&1; then
        ip addr flush dev "\$IF" || true
        ip link set "\$IF" down || true
    else
        log "skip missing iface: \$IF"
    fi
done

# 可选：宿主最终通过 OpenWrt 出网。
# 如果确认 OpenWrt WAN 可正常出网，可取消下一行注释。
# ip route replace default via \$OPENWRT_IP dev "\$HOST_BR" metric 300 2>/dev/null || true

log "done."
exit 0
HOSTNET

chmod +x /usr/local/sbin/owrt-lxc-hostnet.sh

echo
echo "========== 阶段 2：写入 systemd 服务 =========="

cat > /etc/systemd/system/owrt-lxc-hostnet.service <<'SERVICE'
[Unit]
Description=Prepare host bridge, selected NICs and kernel modules for OpenWrt LXC
DefaultDependencies=yes
After=network.target
Before=lxc.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/owrt-lxc-hostnet.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

mkdir -p /etc/systemd/system/lxc.service.d

cat > /etc/systemd/system/lxc.service.d/override.conf <<'OVERRIDE'
[Unit]
Requires=owrt-lxc-hostnet.service
After=owrt-lxc-hostnet.service
OVERRIDE

systemctl daemon-reload
systemctl enable owrt-lxc-hostnet.service
systemctl enable lxc.service 2>/dev/null || true
systemctl enable lxcfs.service 2>/dev/null || true

echo
echo "========== 阶段 2：预创建宿主 ${HOST_BR}，不释放 eth 网卡 =========="
if ! ip link show "$HOST_BR" >/dev/null 2>&1; then
    ip link add "$HOST_BR" type bridge
fi
ip link set "$HOST_BR" up
ip addr replace "$HOST_IP_CIDR" dev "$HOST_BR"
ip link set dev "$HOST_BR" type bridge stp_state 0 2>/dev/null || true

echo
echo "========== 阶段 3：创建 OpenWrt 24.10.6 rootfs =========="

lxc-stop -n "$CT_NAME" 2>/dev/null || true

if [ -d "$CT_DIR" ]; then
    BACKUP="${CT_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
    echo "检测到旧容器目录，备份到：$BACKUP"
    mv "$CT_DIR" "$BACKUP"
fi

mkdir -p "$ROOTFS_DIR"

fetch_openwrt_rootfs

echo "解压 rootfs..."
tar -xzf "$ROOTFS_FILE" -C "$ROOTFS_DIR"

echo
echo "========== 阶段 4：写入 LXC 配置 =========="

cat > "${CT_DIR}/config" <<'LXCCONFIG'
lxc.rootfs.path = dir:/var/lib/lxc/openwrt/rootfs
lxc.uts.name = openwrt

lxc.include = /usr/share/lxc/config/common.conf
lxc.mount.auto = proc:mixed sys:mixed cgroup:mixed

lxc.apparmor.profile = unconfined
lxc.cap.drop =

lxc.start.auto = 1
lxc.start.order = 10
lxc.start.delay = 5

lxc.tty.max = 4
lxc.pty.max = 1024

# TUN 设备给 PassWall / sing-box / WireGuard / OpenVPN / Mihomo TUN 用
lxc.cgroup.devices.allow = c 10:200 rwm
lxc.cgroup2.devices.allow = c 10:200 rwm
lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file

# 让容器能看到宿主模块目录；真正加载模块仍然在宿主做
lxc.mount.entry = /lib/modules lib/modules none ro,bind,optional,create=dir
LXCCONFIG

NET_IDX=0
if [ "$WAN_IF" != "none" ]; then
    cat >> "${CT_DIR}/config" <<LXCCONFIG

# ${WAN_IF} 直通为 OpenWrt WAN
lxc.net.${NET_IDX}.type = phys
lxc.net.${NET_IDX}.link = ${WAN_IF}
lxc.net.${NET_IDX}.name = wan
lxc.net.${NET_IDX}.flags = up
LXCCONFIG
    NET_IDX=$((NET_IDX + 1))
fi

LAN_IDX=1
for IF in $LAN_IFS; do
    cat >> "${CT_DIR}/config" <<LXCCONFIG

# ${IF} 直通为 OpenWrt LAN${LAN_IDX}
lxc.net.${NET_IDX}.type = phys
lxc.net.${NET_IDX}.link = ${IF}
lxc.net.${NET_IDX}.name = lan${LAN_IDX}
lxc.net.${NET_IDX}.flags = up
LXCCONFIG
    NET_IDX=$((NET_IDX + 1))
    LAN_IDX=$((LAN_IDX + 1))
done

cat >> "${CT_DIR}/config" <<LXCCONFIG

# 宿主 iStoreNext 反桥接进 OpenWrt LAN
lxc.net.${NET_IDX}.type = veth
lxc.net.${NET_IDX}.link = ${HOST_BR}
lxc.net.${NET_IDX}.name = host0
lxc.net.${NET_IDX}.flags = up
LXCCONFIG

echo
echo "========== 阶段 5：预写 OpenWrt 网络配置 =========="

mkdir -p "${ROOTFS_DIR}/etc/config"

{
cat <<NETWORK
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
NETWORK

for DEV in $LAN_DEV_NAMES; do
    echo "        list ports '${DEV}'"
done
echo "        list ports 'host0'"

cat <<NETWORK

config interface 'lan'
        option device 'br-lan'
        option proto 'static'
        option ipaddr '${OPENWRT_IP}'
        option netmask '${LAN_NETMASK}'
        option ip6assign '60'
NETWORK

if [ "$WAN_IF" != "none" ]; then
cat <<NETWORK

config interface 'wan'
        option device 'wan'
        option proto 'dhcp'

config interface 'wan6'
        option device 'wan'
        option proto 'dhcpv6'
NETWORK
fi
} > "${ROOTFS_DIR}/etc/config/network"

cat > "${ROOTFS_DIR}/etc/config/dhcp" <<DHCP
config dnsmasq
        option domainneeded '1'
        option boguspriv '1'
        option filterwin2k '0'
        option localise_queries '1'
        option rebind_protection '1'
        option rebind_localhost '1'
        option local '/lan/'
        option domain 'lan'
        option expandhosts '1'
        option cachesize '1000'
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
DHCP

if [ "$WAN_IF" != "none" ]; then
cat >> "${ROOTFS_DIR}/etc/config/dhcp" <<'DHCP'

config dhcp 'wan'
        option interface 'wan'
        option ignore '1'
DHCP
fi

cat >> "${ROOTFS_DIR}/etc/config/dhcp" <<'DHCP'

config odhcpd 'odhcpd'
        option maindhcp '0'
        option leasefile '/tmp/hosts/odhcpd'
        option leasetrigger '/usr/sbin/odhcpd-update'
        option loglevel '4'
DHCP

cat > "${ROOTFS_DIR}/etc/config/firewall" <<'FIREWALL'
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
FIREWALL

if [ "$WAN_IF" != "none" ]; then
cat >> "${ROOTFS_DIR}/etc/config/firewall" <<'FIREWALL'

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
        option name 'Allow-IGMP'
        option src 'wan'
        option proto 'igmp'
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
        option name 'Allow-MLD'
        option src 'wan'
        option proto 'icmp'
        option src_ip 'fe80::/10'
        list icmp_type '130/0'
        list icmp_type '131/0'
        list icmp_type '132/0'
        list icmp_type '143/0'
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

config rule
        option name 'Allow-ICMPv6-Forward'
        option src 'wan'
        option dest '*'
        option proto 'icmp'
        list icmp_type 'echo-request'
        list icmp_type 'echo-reply'
        list icmp_type 'destination-unreachable'
        list icmp_type 'packet-too-big'
        list icmp_type 'time-exceeded'
        list icmp_type 'bad-header'
        list icmp_type 'unknown-header-type'
        option limit '1000/sec'
        option family 'ipv6'
        option target 'ACCEPT'
FIREWALL
else
cat >> "${ROOTFS_DIR}/etc/config/firewall" <<'FIREWALL'

# 当前脚本未配置 WAN 物理口，因此不预置 wan zone / lan->wan forwarding。
# 后续如果你在 OpenWrt 里另行添加 WAN，请同步补充 firewall zone 和 forwarding。
FIREWALL
fi

echo
echo "========== 阶段 6：写入最终切网启动脚本 =========="

cat > /usr/local/sbin/owrt-lxc-finalize.sh <<FINALIZE
#!/bin/sh
set -eu

CT_NAME="${CT_NAME}"
HOST_BR="${HOST_BR}"
OPENWRT_IP="${OPENWRT_IP}"
LOG="/var/log/owrt-lxc-finalize.log"

exec >>"\$LOG" 2>&1

echo
printf '===== owrt-lxc-finalize start: %s =====\n' "\$(date '+%F %T')"

echo "[1/6] Restart host network preparation service..."
systemctl restart owrt-lxc-hostnet.service

echo "[2/6] Start OpenWrt LXC..."
if lxc-info -n "\$CT_NAME" -s 2>/dev/null | grep -q RUNNING; then
    echo "OpenWrt LXC is already running."
else
    lxc-start -n "\$CT_NAME" -d -l DEBUG -o /tmp/openwrt-lxc-debug.log
fi

echo "[3/6] Wait for OpenWrt LAN gateway \$OPENWRT_IP..."
sleep 5
i=0
while [ "\$i" -lt 30 ]; do
    if ping -c 1 -W 1 "\$OPENWRT_IP" >/dev/null 2>&1; then
        echo "OpenWrt gateway \$OPENWRT_IP is reachable."
        break
    fi
    i=\$((i + 1))
    sleep 1
done

if ! ping -c 1 -W 1 "\$OPENWRT_IP" >/dev/null 2>&1; then
    echo "ERROR: OpenWrt gateway \$OPENWRT_IP is still unreachable. Skip default route and DNS change."
    echo "Please check LXC state and OpenWrt br-lan/host0 config."
    lxc-info -n "\$CT_NAME" || true
    ip -br addr show "\$HOST_BR" || true
    ip route || true
    exit 1
fi

echo "[4/6] Optional check: OpenWrt WAN internet connectivity..."
if lxc-attach -n "\$CT_NAME" -- ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1; then
    echo "OpenWrt can reach 223.5.5.5."
else
    echo "WARNING: OpenWrt cannot reach 223.5.5.5 yet."
    echo "The host default route will still be switched to OpenWrt; if the host cannot access the internet, please check OpenWrt WAN/DHCP/upstream router."
fi

echo "[5/6] Set iStoreNext host default route and DNS via OpenWrt..."
ip route replace default via "\$OPENWRT_IP" dev "\$HOST_BR" metric 300 2>/dev/null || true

rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<DNS
nameserver \$OPENWRT_IP
nameserver 223.5.5.5
nameserver 119.29.29.29
DNS

echo "[6/6] Show final status..."
lxc-info -n "\$CT_NAME" || true
ip -br addr show "\$HOST_BR" || true
ip route || true
cat /etc/resolv.conf || true

printf '===== owrt-lxc-finalize done: %s =====\n' "\$(date '+%F %T')"
exit 0
FINALIZE

chmod +x /usr/local/sbin/owrt-lxc-finalize.sh

echo
echo "========== 基础检查 =========="
echo
echo "[1] 宿主 ${HOST_BR}："
ip -br addr show "$HOST_BR" 2>/dev/null || ip addr show "$HOST_BR" || true

echo
echo "[2] LXC 配置："
grep -nE 'lxc.net|lxc.rootfs|lxc.uts.name|tun|modules' "${CT_DIR}/config" || true

echo
echo "[3] OpenWrt LAN / DHCP 配置："
grep -nE "ipaddr|netmask|start|limit|ports|device 'wan'|network 'wan'" "${ROOTFS_DIR}/etc/config/network" "${ROOTFS_DIR}/etc/config/dhcp" "${ROOTFS_DIR}/etc/config/firewall" || true

echo
echo "[4] 宿主模块概览："
lsmod | egrep 'tun|nf_tables|nf_conntrack|nf_nat|nft_tproxy|nft_socket|nf_tproxy|nf_socket|ip_set|xt_TPROXY|xt_socket|iptable_mangle' || true

LAN_HINT="$LAN_IFS"
if [ -z "$LAN_HINT" ]; then
    LAN_HINT="无物理 LAN 口，仅 host0"
fi

cat <<MSG

=========================================================
 准备工作已经完成，即将进入最后切网阶段。
=========================================================
 接下来会发生什么：

 1. 脚本会在后台执行最终切换，不依赖当前 SSH 会话。
 2. 以下物理网口会被交给 OpenWrt LXC：${PHYS_IFS}
 3. OpenWrt WAN 口：${WAN_IF}
 4. OpenWrt LAN 物理口：${LAN_HINT}
 5. OpenWrt LAN 地址：${OPENWRT_IP}
 6. iStoreNext 宿主地址：${HOST_IP_CIDR}
 7. DHCP 地址池：${DHCP_RANGE}

 如果当前 SSH 是通过上述被直通的物理口连接，断开是正常现象。

 断开后请这样操作：

 1. 把电脑网线拔下，重新插到你刚才选择的 LAN 口：${LAN_HINT}
    注意：WAN 口 ${WAN_IF} 不建议接电脑作为管理口。
 2. 电脑网卡设置为“自动获取 IP / DHCP”。
 3. 正常情况下电脑会获取 ${DHCP_RANGE} 中的地址。
 4. 浏览器访问 OpenWrt：

      http://${OPENWRT_IP}

 5. 重新 SSH 进入 iStoreNext 宿主：

      ssh root@${HOST_IP}

 6. 回到宿主后可以查看最终切换日志：

      cat /var/log/owrt-lxc-finalize.log
      lxc-info -n ${CT_NAME}
      ip route
      cat /etc/resolv.conf
      ping -c 4 ${OPENWRT_IP}
      ping -c 4 baidu.com

=========================================================
MSG

if [ "$SKIP_CONFIRM" != "1" ]; then
    if [ ! -t 0 ]; then
        die "当前不是交互式终端，无法输入最终 CUTOVER 确认。请使用 bash -c 方式执行脚本，或稍后手动执行 /usr/local/sbin/owrt-lxc-finalize.sh。"
    fi
    read -r -p "确认马上切网并启动 OpenWrt，请输入 CUTOVER ：" FINAL_CONFIRM
    if [ "$FINAL_CONFIRM" != "CUTOVER" ]; then
        echo "已完成前置准备，但未切网。"
        echo "以后需要手动切网并启动时，可执行："
        echo "  systemd-run --unit=owrt-lxc-finalize --collect /bin/sh -c 'sleep 5; exec /usr/local/sbin/owrt-lxc-finalize.sh'"
        exit 0
    fi
fi

echo
echo "将在后台启动最终切换。SSH 可能很快断开。"
echo "断开后请把电脑网线接到你选择的 LAN 口：${LAN_HINT}，并等待自动获取 ${LAN_NET} 地址。"
echo

if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --unit=owrt-lxc-finalize --collect /bin/sh -c 'sleep 6; exec /usr/local/sbin/owrt-lxc-finalize.sh'
else
    nohup /bin/sh -c 'sleep 6; exec /usr/local/sbin/owrt-lxc-finalize.sh' >/tmp/owrt-lxc-finalize-launch.log 2>&1 &
fi

echo "最终切换任务已提交。当前 SSH 如断开属正常。"
exit 0
