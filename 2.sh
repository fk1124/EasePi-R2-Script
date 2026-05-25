#!/usr/bin/env bash
set -euo pipefail

# EasePi-R2 Redroid 一键部署与容器管理
# - Docker / Redroid 宿主依赖检测安装
# - Docker 数据目录管理，可引导挂载到 SSD
# - Redroid 镜像管理
# - Redroid 容器安装、备份、还原、状态查看

APP_NAME="EasePi-R2 Redroid Manager"
CONFIG_DIR="/etc/easepi-r2-redroid-manager"
CONFIG_FILE="${CONFIG_DIR}/config"

DOCKER_BASE="${DOCKER_BASE:-/docker}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-${DOCKER_BASE}/data}"
DOCKER_REGISTRY_MIRRORS="${DOCKER_REGISTRY_MIRRORS:-}"
REDROID_DATA_DIR="${REDROID_DATA_DIR:-${DOCKER_BASE}/redroid-data}"
BACKUP_DIR="${BACKUP_DIR:-${DOCKER_BASE}/backups}"

CONTAINER_NAME="${CONTAINER_NAME:-redroid}"
REDROID_RK3588_IMAGE="${REDROID_RK3588_IMAGE:-cnflysky/redroid-rk3588:lineage-20}"
REDROID_OFFICIAL_IMAGE="${REDROID_OFFICIAL_IMAGE:-redroid/redroid:12.0.0_64only-latest}"
REDROID_IMAGE="${REDROID_IMAGE:-$REDROID_RK3588_IMAGE}"
REDROID_IMAGE_MIGRATED_RK3588="${REDROID_IMAGE_MIGRATED_RK3588:-0}"
REDROID_NETWORK_MODE="${REDROID_NETWORK_MODE:-port}"
REDROID_ADB_HOST="${REDROID_ADB_HOST:-127.0.0.1}"
REDROID_ADB_PORT="${REDROID_ADB_PORT:-5555}"
REDROID_NET="${REDROID_NET:-redroid-brhostlan}"
REDROID_PARENT="${REDROID_PARENT:-br-hostlan}"
REDROID_SUBNET="${REDROID_SUBNET:-10.10.0.0/24}"
REDROID_GATEWAY="${REDROID_GATEWAY:-10.10.0.1}"
REDROID_IP="${REDROID_IP:-10.10.0.50}"
REDROID_WIDTH="${REDROID_WIDTH:-1080}"
REDROID_HEIGHT="${REDROID_HEIGHT:-1920}"
REDROID_DPI="${REDROID_DPI:-480}"
REDROID_FPS="${REDROID_FPS:-60}"
REDROID_FAKE_WIFI="${REDROID_FAKE_WIFI:-1}"
REDROID_ADBD_BIND_ETH0="${REDROID_ADBD_BIND_ETH0:-1}"
REDROID_ENABLE_INPUT_SUBSYS="${REDROID_ENABLE_INPUT_SUBSYS:-0}"
REDROID_CREATE_SECURE_DISPLAY="${REDROID_CREATE_SECURE_DISPLAY:-0}"
REDROID_BUILD_CHARACTERISTICS="${REDROID_BUILD_CHARACTERISTICS:-default}"
REDROID_RESTART_POLICY="${REDROID_RESTART_POLICY:-no}"

LIBMALI_DEB_URL="${LIBMALI_DEB_URL:-https://github.com/tsukumijima/libmali-rockchip/releases/download/v1.9-1-20260312-bd33ee2/libmali-valhall-g610-g24p0-gbm_1.9-1_arm64.deb}"
LIBMALI_DEB_SHA256="${LIBMALI_DEB_SHA256:-32ffe853e8d56295284637252f1da15dd868a8f7c6b8da6b9f77616ba285eb1a}"
GPU_CACHE_DIR="${GPU_CACHE_DIR:-/var/cache/easepi-r2-redroid}"

ok() { echo "[OK] $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

need_root() {
    [ "$(id -u)" = "0" ] || die "请用 root 执行。"
}

pause_enter() {
    echo
    read -r -p "按回车继续..." _ || true
}

confirm() {
    local prompt="$1" default="${2:-y}" ans suffix
    case "$default" in
        y|Y) suffix="[Y/n]" ;;
        *) suffix="[y/N]" ;;
    esac
    read -r -p "${prompt} ${suffix}: " ans || ans=""
    ans="${ans:-$default}"
    case "$ans" in
        y|Y|yes|YES|是|好) return 0 ;;
        *) return 1 ;;
    esac
}

read_default() {
    local prompt="$1" default="$2" ans
    read -r -p "${prompt} [${default}]: " ans || ans=""
    printf '%s\n' "${ans:-$default}"
}

read_choice() {
    local prompt="$1" default="$2" value allowed
    shift 2
    allowed=" $* "
    while true; do
        value="$(read_default "$prompt" "$default")"
        if [[ "$allowed" == *" $value "* ]]; then
            printf '%s\n' "$value"
            return 0
        fi
        warn "请输入：$*"
    done
}

set_docker_base_paths() {
    local base="$1"
    base="${base%/}"
    [ -n "$base" ] || die "Docker 根目录不能为空。"
    [ "$base" != "/" ] || die "Docker 根目录不能是 /。"

    DOCKER_BASE="$base"
    DOCKER_DATA_ROOT="${DOCKER_BASE}/data"
    REDROID_DATA_DIR="${DOCKER_BASE}/redroid-data"
    BACKUP_DIR="${DOCKER_BASE}/backups"
}

quote_sq() {
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

docker_registry_mirrors_json() {
    local IFS=',' item first=1
    printf '['
    for item in $DOCKER_REGISTRY_MIRRORS; do
        item="$(printf '%s' "$item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$item" ] || continue
        [ "$first" = "1" ] || printf ', '
        printf '"%s"' "$(json_escape "$item")"
        first=0
    done
    printf ']'
}

load_existing_docker_registry_mirrors() {
    [ -r /etc/docker/daemon.json ] || return 0
    command_exists jq || return 0
    jq -r '."registry-mirrors" // [] | join(",")' /etc/docker/daemon.json 2>/dev/null || true
}

load_config() {
    local had_config=0 had_rk3588_migration=0 had_registry_mirrors_config=0
    if [ -r "$CONFIG_FILE" ]; then
        had_config=1
        grep -q '^REDROID_IMAGE_MIGRATED_RK3588=' "$CONFIG_FILE" && had_rk3588_migration=1
        grep -q '^DOCKER_REGISTRY_MIRRORS=' "$CONFIG_FILE" && had_registry_mirrors_config=1
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
    : "${DOCKER_BASE:=/docker}"
    : "${DOCKER_DATA_ROOT:=${DOCKER_BASE}/data}"
    : "${DOCKER_REGISTRY_MIRRORS:=}"
    if [ "$had_registry_mirrors_config" != "1" ] && [ -z "$DOCKER_REGISTRY_MIRRORS" ]; then
        DOCKER_REGISTRY_MIRRORS="$(load_existing_docker_registry_mirrors)"
    fi
    : "${REDROID_DATA_DIR:=${DOCKER_BASE}/redroid-data}"
    : "${BACKUP_DIR:=${DOCKER_BASE}/backups}"
    : "${CONTAINER_NAME:=redroid}"
    : "${REDROID_RK3588_IMAGE:=cnflysky/redroid-rk3588:lineage-20}"
    : "${REDROID_OFFICIAL_IMAGE:=redroid/redroid:12.0.0_64only-latest}"
    : "${REDROID_IMAGE:=$REDROID_RK3588_IMAGE}"
    : "${REDROID_IMAGE_MIGRATED_RK3588:=0}"
    if [ "$had_config" = "1" ] && [ "$had_rk3588_migration" != "1" ] && [ "$REDROID_IMAGE" = "$REDROID_OFFICIAL_IMAGE" ]; then
        REDROID_IMAGE="$REDROID_RK3588_IMAGE"
        REDROID_IMAGE_MIGRATED_RK3588=1
    elif [ "$had_config" = "0" ]; then
        REDROID_IMAGE_MIGRATED_RK3588=1
    fi
    : "${REDROID_NETWORK_MODE:=port}"
    : "${REDROID_ADB_HOST:=127.0.0.1}"
    : "${REDROID_ADB_PORT:=5555}"
    : "${REDROID_NET:=redroid-brhostlan}"
    : "${REDROID_PARENT:=br-hostlan}"
    : "${REDROID_SUBNET:=10.10.0.0/24}"
    : "${REDROID_GATEWAY:=10.10.0.1}"
    : "${REDROID_IP:=10.10.0.50}"
    : "${REDROID_WIDTH:=1080}"
    : "${REDROID_HEIGHT:=1920}"
    : "${REDROID_DPI:=480}"
    : "${REDROID_FPS:=60}"
    : "${REDROID_FAKE_WIFI:=1}"
    : "${REDROID_ADBD_BIND_ETH0:=1}"
    : "${REDROID_ENABLE_INPUT_SUBSYS:=0}"
    : "${REDROID_CREATE_SECURE_DISPLAY:=0}"
    : "${REDROID_BUILD_CHARACTERISTICS:=default}"
    : "${REDROID_RESTART_POLICY:=no}"
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF_CONF
DOCKER_BASE='$(quote_sq "$DOCKER_BASE")'
DOCKER_DATA_ROOT='$(quote_sq "$DOCKER_DATA_ROOT")'
DOCKER_REGISTRY_MIRRORS='$(quote_sq "$DOCKER_REGISTRY_MIRRORS")'
REDROID_DATA_DIR='$(quote_sq "$REDROID_DATA_DIR")'
BACKUP_DIR='$(quote_sq "$BACKUP_DIR")'
CONTAINER_NAME='$(quote_sq "$CONTAINER_NAME")'
REDROID_RK3588_IMAGE='$(quote_sq "$REDROID_RK3588_IMAGE")'
REDROID_OFFICIAL_IMAGE='$(quote_sq "$REDROID_OFFICIAL_IMAGE")'
REDROID_IMAGE='$(quote_sq "$REDROID_IMAGE")'
REDROID_IMAGE_MIGRATED_RK3588='$(quote_sq "$REDROID_IMAGE_MIGRATED_RK3588")'
REDROID_NETWORK_MODE='$(quote_sq "$REDROID_NETWORK_MODE")'
REDROID_ADB_HOST='$(quote_sq "$REDROID_ADB_HOST")'
REDROID_ADB_PORT='$(quote_sq "$REDROID_ADB_PORT")'
REDROID_NET='$(quote_sq "$REDROID_NET")'
REDROID_PARENT='$(quote_sq "$REDROID_PARENT")'
REDROID_SUBNET='$(quote_sq "$REDROID_SUBNET")'
REDROID_GATEWAY='$(quote_sq "$REDROID_GATEWAY")'
REDROID_IP='$(quote_sq "$REDROID_IP")'
REDROID_WIDTH='$(quote_sq "$REDROID_WIDTH")'
REDROID_HEIGHT='$(quote_sq "$REDROID_HEIGHT")'
REDROID_DPI='$(quote_sq "$REDROID_DPI")'
REDROID_FPS='$(quote_sq "$REDROID_FPS")'
REDROID_FAKE_WIFI='$(quote_sq "$REDROID_FAKE_WIFI")'
REDROID_ADBD_BIND_ETH0='$(quote_sq "$REDROID_ADBD_BIND_ETH0")'
REDROID_ENABLE_INPUT_SUBSYS='$(quote_sq "$REDROID_ENABLE_INPUT_SUBSYS")'
REDROID_CREATE_SECURE_DISPLAY='$(quote_sq "$REDROID_CREATE_SECURE_DISPLAY")'
REDROID_BUILD_CHARACTERISTICS='$(quote_sq "$REDROID_BUILD_CHARACTERISTICS")'
REDROID_RESTART_POLICY='$(quote_sq "$REDROID_RESTART_POLICY")'
EOF_CONF
}

dpkg_missing_packages() {
    local pkg
    for pkg in "$@"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            printf '%s\n' "$pkg"
        fi
    done
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

dependency_present_any() {
    local cmd="$1"
    shift
    local pkg
    command_exists "$cmd" && return 0
    for pkg in "$@"; do
        package_installed "$pkg" && return 0
    done
    return 1
}

apt_candidate_exists() {
    local pkg="$1"
    apt-cache policy "$pkg" 2>/dev/null | awk '
        /^[[:space:]]*Candidate:/ {
            found = 1
            if ($2 != "(none)") ok = 1
        }
        END { exit !(found && ok) }
    '
}

apt_install_first_available() {
    local required="$1" label="$2"
    shift 2
    local pkg

    for pkg in "$@"; do
        package_installed "$pkg" && return 0
    done
    for pkg in "$@"; do
        if apt_candidate_exists "$pkg"; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" && return 0
            break
        fi
    done

    if [ "$required" = "required" ]; then
        die "无法安装 ${label}：当前 apt 源没有可用包（候选：$*）。"
    fi
    warn "可选依赖 ${label} 在当前 apt 源没有可用包，已跳过（候选：$*）。"
}

docker_compose_available() {
    docker compose version >/dev/null 2>&1 && return 0
    command_exists docker-compose && return 0
    package_installed docker-compose-plugin && return 0
    package_installed docker-compose && return 0
    return 1
}

apt_install_required() {
    local missing
    mapfile -t missing < <(dpkg_missing_packages "$@")
    [ "${#missing[@]}" -eq 0 ] && return 0
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

apt_install_optional() {
    local pkg
    for pkg in "$@"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" || \
                warn "可选包安装失败，已跳过：$pkg"
        fi
    done
}

detect_gpu_stack() {
    local kernel
    kernel="$(uname -r 2>/dev/null || true)"
    case "$kernel" in
        *vendor*|*rk35xx*|6.1.*)
            printf '%s\n' vendor
            ;;
        *)
            printf '%s\n' mainline
            ;;
    esac
}

has_libmali() {
    dpkg-query -W -f='${Status}' libmali-valhall-g610-g24p0-gbm 2>/dev/null | grep -q 'install ok installed' && return 0
    ldconfig -p 2>/dev/null | grep -qi 'libmali' && return 0
    return 1
}

install_vendor_libmali() {
    local deb_name deb_path tmp_path

    if has_libmali; then
        ok "vendor 6.1 libmali 已安装。"
        return 0
    fi

    deb_name="$(basename "$LIBMALI_DEB_URL")"
    deb_path="${GPU_CACHE_DIR}/${deb_name}"
    tmp_path="${deb_path}.tmp"
    mkdir -p "$GPU_CACHE_DIR"

    if [ ! -f "$deb_path" ]; then
        info "正在下载 vendor 6.1 libmali：$LIBMALI_DEB_URL"
        curl -fL --retry 3 --connect-timeout 15 -o "$tmp_path" "$LIBMALI_DEB_URL"
        mv -f "$tmp_path" "$deb_path"
    fi

    printf '%s  %s\n' "$LIBMALI_DEB_SHA256" "$deb_path" | sha256sum -c -
    if ! DEBIAN_FRONTEND=noninteractive dpkg -i "$deb_path"; then
        DEBIAN_FRONTEND=noninteractive apt-get -f install -y
    fi

    ok "vendor 6.1 libmali 已安装。"
}

install_gpu_userspace() {
    local stack
    local -a core optional missing_core missing_optional

    stack="$(detect_gpu_stack)"
    echo
    echo "========== 检测 GPU 用户态包 =========="
    echo "检测到 GPU 栈：$stack"

    if [ "$stack" = vendor ]; then
        core=(libdrm2 libgbm1 ocl-icd-libopencl1 clinfo v4l-utils ca-certificates curl)
        optional=()
    else
        core=(libdrm2 libegl-mesa0 libgles2 libgl1-mesa-dri mesa-vulkan-drivers v4l-utils)
        optional=(mesa-utils vulkan-tools kmscube glmark2-es2-drm ocl-icd-libopencl1 clinfo)
    fi

    mapfile -t missing_core < <(dpkg_missing_packages "${core[@]}")
    mapfile -t missing_optional < <(dpkg_missing_packages "${optional[@]}")
    if [ "${#missing_core[@]}" -gt 0 ] || [ "${#missing_optional[@]}" -gt 0 ]; then
        apt-get update
    fi
    [ "${#missing_core[@]}" -eq 0 ] || apt_install_required "${core[@]}"
    [ "${#missing_optional[@]}" -eq 0 ] || apt_install_optional "${optional[@]}"

    if [ "$stack" = vendor ]; then
        install_vendor_libmali || warn "libmali 安装失败，Redroid 可继续尝试，但 GPU 加速可能不可用。"
    fi

    ok "GPU 用户态包检测完成。"
}

ensure_dirs() {
    mkdir -p "$DOCKER_BASE" "$DOCKER_DATA_ROOT" "$REDROID_DATA_DIR" "$BACKUP_DIR" "$CONFIG_DIR"
}

write_docker_daemon() {
    local data_root_json mirrors_json
    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    data_root_json="$(json_escape "$DOCKER_DATA_ROOT")"
    mirrors_json="$(docker_registry_mirrors_json)"
    if [ "$mirrors_json" = "[]" ]; then
        cat > /etc/docker/daemon.json <<EOF_DOCKER
{
  "data-root": "$data_root_json",
  "iptables": true
}
EOF_DOCKER
        return 0
    fi
    cat > /etc/docker/daemon.json <<EOF_DOCKER
{
  "data-root": "$data_root_json",
  "iptables": true,
  "registry-mirrors": $mirrors_json
}
EOF_DOCKER
}

prepare_redroid_host() {
    local modules ok_modules missing_modules mod binder_ready ashmem_ready
    modules=(overlay veth br_netfilter tun 8021q uhid)
    ok_modules=()
    missing_modules=()

    for mod in "${modules[@]}"; do
        if modprobe "$mod" >/dev/null 2>&1; then
            ok_modules+=("$mod")
        else
            missing_modules+=("$mod")
        fi
    done

    binder_ready=0
    if ! grep -qw binder /proc/filesystems; then
        if modprobe binder_linux >/dev/null 2>&1; then
            ok_modules+=("binder_linux")
        fi
    fi

    mkdir -p /dev/binderfs
    if grep -qw binder /proc/filesystems; then
        mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs 2>/dev/null || true
        if mountpoint -q /dev/binderfs || [ -e /dev/binderfs/binder-control ] || [ -e /dev/binderfs/binder ]; then
            binder_ready=1
        fi
    fi

    ashmem_ready=0
    if modprobe ashmem_linux >/dev/null 2>&1; then
        ok_modules+=("ashmem_linux")
        ashmem_ready=1
    elif [ -e /dev/ashmem ] || grep -qw ashmem /proc/misc 2>/dev/null; then
        ashmem_ready=1
    fi

    mkdir -p /etc/modules-load.d /etc/sysctl.d
    : > /etc/modules-load.d/easepi-r2-redroid.conf
    if [ "${#ok_modules[@]}" -gt 0 ]; then
        printf '%s\n' "${ok_modules[@]}" | awk 'NF && !seen[$0]++' > /etc/modules-load.d/easepi-r2-redroid.conf
    fi

    cat > /etc/sysctl.d/90-easepi-r2-redroid.conf <<'EOF_SYSCTL'
kernel.unprivileged_userns_clone=1
user.max_user_namespaces=28633
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
-net.bridge.bridge-nf-call-iptables=1
-net.bridge.bridge-nf-call-ip6tables=1
EOF_SYSCTL
    sysctl --system >/dev/null 2>&1 || true

    if [ "$binder_ready" = "1" ]; then
        ok "binderfs 已就绪：/dev/binderfs"
    else
        warn "未检测到可用 binderfs。Redroid 依赖 binder；若容器无法启动或 ADB 不通，请检查 LiteHost 内核是否启用 CONFIG_ANDROID_BINDERFS。"
    fi

    if [ "$ashmem_ready" = "1" ]; then
        ok "ashmem 兼容项可用。"
    else
        warn "未检测到 ashmem_linux；Android 12/Lineage 20 通常可使用 memfd，这不是阻断项。"
    fi

    if [ "${#missing_modules[@]}" -gt 0 ]; then
        warn "以下通用内核模块当前未能 modprobe；若网络、输入或 Docker 异常再检查 LiteHost 内核："
        printf '  - %s\n' "${missing_modules[@]}"
    fi
}

install_redroid_dependencies() {
    need_root
    local required missing_required missing_optional
    required=(
        docker.io containerd runc
        iproute2 iptables ca-certificates curl jq kmod
        util-linux e2fsprogs rsync zstd tar gzip
    )

    echo
    echo "========== 检测 Redroid / Docker 依赖 =========="
    mapfile -t missing_required < <(dpkg_missing_packages "${required[@]}")
    dependency_present_any adb adb android-tools-adb || missing_required+=("adb 或 android-tools-adb")

    missing_optional=()
    dependency_present_any fastboot fastboot android-tools-fastboot || missing_optional+=("fastboot 或 android-tools-fastboot")
    docker_compose_available || missing_optional+=("docker compose 插件或 docker-compose")

    if [ "${#missing_required[@]}" -eq 0 ]; then
        ok "Redroid 依赖已经安装完整。"
        if [ "${#missing_optional[@]}" -gt 0 ]; then
            warn "以下可选依赖未安装，不影响 Redroid 基本功能："
            printf '  - %s\n' "${missing_optional[@]}"
            if confirm "是否尝试安装这些可选依赖？" n; then
                apt-get update
                dependency_present_any fastboot fastboot android-tools-fastboot || apt_install_first_available optional "Fastboot" fastboot android-tools-fastboot
                docker_compose_available || apt_install_first_available optional "Docker Compose" docker-compose-plugin docker-compose
            fi
        fi
    else
        warn "缺少必需依赖："
        printf '  - %s\n' "${missing_required[@]}"
        [ "${#missing_optional[@]}" -eq 0 ] || {
            echo "缺少可选依赖："
            printf '  - %s\n' "${missing_optional[@]}"
        }
        confirm "是否一键安装 Redroid 所有依赖？" y || { warn "已取消安装。"; return 1; }
        apt-get update
        apt_install_required "${required[@]}"
        dependency_present_any adb adb android-tools-adb || apt_install_first_available required "ADB" adb android-tools-adb
        dependency_present_any fastboot fastboot android-tools-fastboot || apt_install_first_available optional "Fastboot" fastboot android-tools-fastboot
        docker_compose_available || apt_install_first_available optional "Docker Compose" docker-compose-plugin docker-compose
    fi

    install_gpu_userspace
    ensure_dirs
    write_docker_daemon
    write_docker_service_mount_dropin
    systemctl daemon-reload || true
    systemctl enable --now docker.service >/dev/null 2>&1 || systemctl restart docker.service || true
    prepare_redroid_host
    save_config
    ok "Redroid 依赖、Docker 数据目录和宿主模块已准备完成。"
}

show_docker_dirs() {
    load_config
    echo
    echo "========== 当前 Docker 目录 =========="
    echo "Docker 根目录       ：$DOCKER_BASE"
    echo "Docker data-root   ：$DOCKER_DATA_ROOT"
    echo "Docker 镜像加速    ：${DOCKER_REGISTRY_MIRRORS:-未配置}"
    echo "Redroid 数据目录   ：$REDROID_DATA_DIR"
    echo "备份目录           ：$BACKUP_DIR"
    echo
    findmnt "$DOCKER_BASE" 2>/dev/null || true
    echo
    docker info --format 'Docker Root Dir: {{.DockerRootDir}}' 2>/dev/null || true
    docker info --format 'Registry Mirrors: {{json .RegistryConfig.Mirrors}}' 2>/dev/null || true
}

configure_docker_registry_mirrors() {
    need_root
    load_config
    local value

    echo
    echo "========== Docker Hub 镜像加速 =========="
    echo "当前配置：${DOCKER_REGISTRY_MIRRORS:-未配置}"
    echo "多个地址请用英文逗号分隔；输入 clear 可清空。"
    read -r -p "请输入 registry mirror 地址: " value || value=""
    value="${value:-$DOCKER_REGISTRY_MIRRORS}"
    case "$value" in
        clear|CLEAR|none|NONE|无)
            value=""
            ;;
    esac

    DOCKER_REGISTRY_MIRRORS="$value"
    write_docker_daemon
    save_config
    systemctl daemon-reload || true
    confirm "是否立即重启 Docker 让镜像加速配置生效？" y && restart_docker_services
    ok "Docker Hub 镜像加速配置已更新。"
    docker info --format 'Registry Mirrors: {{json .RegistryConfig.Mirrors}}' 2>/dev/null || true
}

set_docker_dirs() {
    need_root
    load_config
    set_docker_base_paths "$(read_default "请输入 Docker 根目录" "$DOCKER_BASE")"
    ensure_dirs
    write_docker_daemon
    write_docker_service_mount_dropin
    save_config
    systemctl daemon-reload || true
    warn "Docker data-root 已改为 $DOCKER_DATA_ROOT，重启 Docker 后生效。"
    confirm "是否立即重启 Docker？" y && systemctl restart docker.service || true
}

dir_has_entries() {
    [ -d "$1" ] || return 1
    find "$1" -mindepth 1 -maxdepth 1 | read -r _
}

path_is_mountpoint() {
    local path="$1"
    mountpoint -q "$path" 2>/dev/null || findmnt -rn --mountpoint "$path" >/dev/null 2>&1
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
    echo "说明：推荐把 Docker/Redroid 放到已挂载的 SSD 目录，例如 /lxc/docker 或 /docker。"
}

partition_of_disk() {
    local disk="$1"
    if [[ "$disk" =~ (nvme|mmcblk) ]]; then
        echo "${disk}p1"
    else
        echo "${disk}1"
    fi
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

format_disk_as_docker_ext4() {
    local disk="$1"
    local ack part

    echo >&2
    warn "你选择的是整块磁盘：$disk"
    warn "下面操作会卸载该磁盘的所有分区，并清空整块磁盘上的所有数据。"
    echo "当前分区情况：" >&2
    lsblk -lnp -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT "$disk" 2>/dev/null | sed 's/^/  /' >&2
    echo >&2
    read -r -p "如确认把整块磁盘重建为 Docker/Redroid 专用盘，请输入：FORMAT ${disk} : " ack || ack=""
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
    mkfs.ext4 -F -L EasePiR2_Docker "$part" >&2
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
                example="$(partition_of_disk "$dev")"
                echo >&2
                warn "$dev 已有分区。你可以选择已有分区挂载到 $DOCKER_BASE，也可以清空整块磁盘后重建。"
                echo "当前分区：" >&2
                lsblk -lnp -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT "$dev" 2>/dev/null | sed 's/^/  /' >&2
                echo >&2
                echo "1. 选择已有分区，例如 $example" >&2
                echo "2. 卸载该磁盘所有分区，清空并重新格式化为 Docker/Redroid 专用 ext4 分区" >&2
                echo "0. 取消" >&2
                read -r -p "请选择: " choice || choice=""
                case "$choice" in
                    1)
                        read -r -p "请输入要挂载到 ${DOCKER_BASE} 的分区路径，例如 ${example}: " part || part=""
                        [ -b "$part" ] || die "分区不存在：$part"
                        pk="$(lsblk -no PKNAME "$part" 2>/dev/null | head -n1 || true)"
                        [ -n "$pk" ] && [ "/dev/$pk" = "$dev" ] || die "$part 不属于 $dev。"
                        prepare_ext4_target "$part"
                        ;;
                    2)
                        format_disk_as_docker_ext4 "$dev"
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
            format_disk_as_docker_ext4 "$dev"
            ;;
        part)
            if [ -z "$fstype" ]; then
                warn "$dev 没有文件系统。"
                read -r -p "如确认格式化，请输入：FORMAT ${dev} : " ack || ack=""
                [ "$ack" = "FORMAT ${dev}" ] || die "确认文本不匹配，已取消格式化。"
                mkfs.ext4 -F -L EasePiR2_Docker "$dev" >&2
                echo "$dev"
            else
                [ "$fstype" = "ext4" ] || die "$dev 的文件系统是 $fstype，不建议作为 Docker/Redroid 目录。请备份后格式化为 ext4。"
                echo "$dev"
            fi
            ;;
        *) die "$dev 不是磁盘或分区。" ;;
    esac
}

persist_mount_for_path() {
    local mount_path="$1"
    local src uuid tmp
    if ! path_is_mountpoint "$mount_path"; then
        warn "$mount_path 当前不是独立挂载点，已跳过 fstab 修复。"
        return 0
    fi
    src="$(findmnt -rn --mountpoint "$mount_path" -o SOURCE 2>/dev/null | head -n1 || true)"
    [ -n "$src" ] || { warn "未检测到 $mount_path 的挂载源，已跳过 fstab 修复。"; return 0; }
    case "$src" in
        /dev/*) ;;
        *) warn "$mount_path 当前挂载源是 $src，不是块设备，已跳过 fstab 修复。"; return 0 ;;
    esac
    uuid="$(blkid -s UUID -o value "$src" 2>/dev/null || true)"
    [ -n "$uuid" ] || { warn "无法读取 $src 的 UUID，已跳过 fstab 修复。"; return 0; }

    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    tmp="$(mktemp)"
    grep -vE "[[:space:]]${mount_path//\//\\/}[[:space:]]" /etc/fstab > "$tmp" 2>/dev/null || true
    printf 'UUID=%s %s ext4 defaults,noatime 0 2\n' "$uuid" "$mount_path" >> "$tmp"
    install -m 0644 "$tmp" /etc/fstab
    rm -f "$tmp"
    ok "已修复 /etc/fstab：$src -> $mount_path"
}

write_docker_service_mount_dropin() {
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/10-easepi-r2-docker-data.conf <<EOF
[Unit]
RequiresMountsFor=${DOCKER_BASE} ${DOCKER_DATA_ROOT} ${REDROID_DATA_DIR}
After=local-fs.target
EOF
}

restart_docker_services() {
    systemctl daemon-reload || true
    systemctl enable containerd.service docker.service >/dev/null 2>&1 || true
    systemctl restart containerd.service >/dev/null 2>&1 || true
    systemctl restart docker.service >/dev/null 2>&1 || systemctl start docker.service >/dev/null 2>&1 || true
}

migrate_docker_base_if_needed() {
    local old_base="$1" new_base="$2"
    [ "$old_base" != "$new_base" ] || return 0
    [ -d "$old_base" ] || return 0
    dir_has_entries "$old_base" || return 0
    case "${new_base}/" in
        "${old_base}/"*)
            warn "新 Docker 目录位于旧目录内部，已跳过自动复制以避免递归：$old_base -> $new_base"
            return 0
            ;;
    esac

    warn "检测到旧 Docker/Redroid 目录已有内容：$old_base"
    confirm "是否停止 Docker 并复制旧数据到 $new_base？" y || {
        warn "已跳过数据复制。旧镜像/容器不会自动出现在新 data-root。"
        return 0
    }
    systemctl stop docker.service docker.socket containerd.service >/dev/null 2>&1 || true
    mkdir -p "$new_base"
    rsync -aHAX --numeric-ids "${old_base}/" "${new_base}/"
    ok "旧数据已复制到 $new_base。"
}

use_lxc_disk_for_docker() {
    need_root
    load_config
    local lxc_base="${LXC_BASE:-/lxc}"
    local old_base="$DOCKER_BASE"
    lxc_base="${lxc_base%/}"

    if ! path_is_mountpoint "$lxc_base"; then
        die "$lxc_base 当前不是挂载点。请先用 1.sh 把 SSD 挂载到 $lxc_base。"
    fi

    set_docker_base_paths "${lxc_base}/docker"
    ensure_dirs
    migrate_docker_base_if_needed "$old_base" "$DOCKER_BASE"
    write_docker_daemon
    write_docker_service_mount_dropin
    save_config
    systemctl daemon-reload || true
    warn "Docker/Redroid 目录已切到 ${DOCKER_BASE}。"
    [ "$old_base" = "$DOCKER_BASE" ] || warn "旧目录：$old_base；新目录：$DOCKER_BASE。"
    confirm "是否立即重启 Docker 让 data-root 生效？" y && restart_docker_services
    ok "已使用 ${lxc_base} 磁盘作为 Docker/Redroid 目录。"
    show_docker_dirs
}

mount_docker_to_ssd() {
    need_root
    load_config
    local dev rootdisk pk target uuid tmp mp

    ensure_disk_tools
    list_m2_candidates
    read -r -p "请输入要挂载到 ${DOCKER_BASE} 的磁盘或分区路径: " dev || dev=""
    [ -b "$dev" ] || die "设备不存在：$dev"

    rootdisk="$(root_parent_disk || true)"
    pk="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1 || true)"
    if [ "$dev" = "$rootdisk" ] || { [ -n "$pk" ] && [ "/dev/$pk" = "$rootdisk" ]; }; then
        die "拒绝操作系统盘 $rootdisk，避免误格式化/误挂载。"
    fi

    target="$(prepare_ext4_target "$dev")"
    [ -b "$target" ] || die "目标设备不可用：$target"

    mkdir -p "$DOCKER_BASE"
    if findmnt -rn -S "$target" >/dev/null 2>&1; then
        while read -r mp; do
            [ -n "$mp" ] || continue
            if [ "$mp" = "$DOCKER_BASE" ]; then
                ok "$target 已经挂载到 $DOCKER_BASE。"
                ensure_dirs
                write_docker_daemon
                write_docker_service_mount_dropin
                save_config
                persist_mount_for_path "$DOCKER_BASE"
                restart_docker_services
                findmnt "$DOCKER_BASE" || true
                return 0
            fi
            warn "$target 当前已挂载到 $mp。"
            confirm "是否卸载 $mp 并改挂到 $DOCKER_BASE？" y || die "已取消。"
            systemctl stop docker.service docker.socket containerd.service >/dev/null 2>&1 || true
            umount "$mp" || die "无法卸载 $mp，请先手动停止占用它的服务。"
        done < <(findmnt -rn -S "$target" -o TARGET 2>/dev/null | sort -r)
    fi

    if path_is_mountpoint "$DOCKER_BASE"; then
        warn "$DOCKER_BASE 已经是挂载点。"
        findmnt "$DOCKER_BASE" || true
        persist_mount_for_path "$DOCKER_BASE"
        restart_docker_services
        return 0
    fi

    systemctl stop docker.service docker.socket containerd.service >/dev/null 2>&1 || true
    tmp="/mnt/easepi-r2-docker-ssd"
    mkdir -p "$tmp"
    mount "$target" "$tmp"
    if dir_has_entries "$DOCKER_BASE" && confirm "$DOCKER_BASE 已有内容，是否复制到 SSD？" y; then
        rsync -aHAX --numeric-ids "${DOCKER_BASE}/" "${tmp}/"
    fi
    umount "$tmp"

    uuid="$(blkid -s UUID -o value "$target")"
    [ -n "$uuid" ] || die "无法读取 $target 的 UUID。"
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    grep -vE "[[:space:]]${DOCKER_BASE//\//\\/}[[:space:]]" /etc/fstab > /tmp/fstab.easepi-r2-redroid || true
    printf 'UUID=%s %s ext4 defaults,noatime 0 2\n' "$uuid" "$DOCKER_BASE" >> /tmp/fstab.easepi-r2-redroid
    install -m 0644 /tmp/fstab.easepi-r2-redroid /etc/fstab
    rm -f /tmp/fstab.easepi-r2-redroid

    mount "$DOCKER_BASE"
    ensure_dirs
    write_docker_daemon
    write_docker_service_mount_dropin
    save_config
    restart_docker_services
    ok "SSD 已挂载到 $DOCKER_BASE。"
    findmnt "$DOCKER_BASE" || true
}

repair_docker_remount() {
    need_root
    load_config

    echo
    echo "========== 重挂载修复已有 Docker/Redroid 数据 =========="
    if ! path_is_mountpoint "$DOCKER_BASE"; then
        warn "$DOCKER_BASE 当前不是挂载点。"
        if path_is_mountpoint /lxc && [ "${DOCKER_BASE#/lxc/}" != "$DOCKER_BASE" ]; then
            warn "检测到 /lxc 已挂载，当前 Docker 目录位于 /lxc 下，可继续修复 Docker 配置。"
        else
            warn "如需独立挂载，请先用“磁盘工具”把 M.2/SSD 挂载到 $DOCKER_BASE。"
        fi
    fi

    warn "此修复会重写 Docker daemon.json、systemd 挂载依赖、自启动策略和快捷命令。"
    confirm "确认继续执行重挂载修复" n || { warn "已取消。"; return 0; }

    ensure_dirs
    write_docker_daemon
    write_docker_service_mount_dropin
    if path_is_mountpoint "$DOCKER_BASE"; then
        persist_mount_for_path "$DOCKER_BASE"
    elif path_is_mountpoint /lxc && [ "${DOCKER_BASE#/lxc/}" != "$DOCKER_BASE" ]; then
        persist_mount_for_path /lxc
    fi
    save_config
    restart_docker_services
    repair_all_docker_autostart
    write_all_docker_shortcuts
    ok "Docker/Redroid 重挂载修复完成。"
    list_docker_containers || true
}

docker_dirs_menu() {
    local choice
    while true; do
        echo
        echo "========== Docker 目录管理 =========="
        echo "1. 查看当前 Docker 目录"
        echo "2. 修改 Docker 根目录"
        echo "3. 使用 1.sh 的 /lxc 磁盘作为 Docker/Redroid 目录"
        echo "4. 磁盘工具：检测 M.2/SSD 并挂载到 Docker 根目录"
        echo "5. 重挂载修复已有 Docker/Redroid 数据"
        echo "6. 配置 Docker Hub 镜像加速"
        echo "0. 返回"
        read -r -p "请选择: " choice || return
        case "$choice" in
            1) show_docker_dirs; pause_enter ;;
            2) set_docker_dirs; pause_enter ;;
            3) use_lxc_disk_for_docker; pause_enter ;;
            4) mount_docker_to_ssd; pause_enter ;;
            5) repair_docker_remount; pause_enter ;;
            6) configure_docker_registry_mirrors; pause_enter ;;
            0) return ;;
            *) warn "无效选择。" ;;
        esac
    done
}

docker_container_names() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | sort
}

docker_container_exists() {
    local name="$1"
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"
}

docker_container_running() {
    local name="$1"
    docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true
}

pull_docker_image() {
    local image="$1"
    info "正在拉取镜像：$image"
    if docker pull "$image"; then
        ok "镜像拉取完成：$image"
        return 0
    fi
    warn "镜像拉取失败：$image"
    warn "这通常是 Docker Hub 连接超时、DNS 异常，或未配置可用镜像加速/代理。"
    warn "可在“Docker 目录管理 -> 配置 Docker Hub 镜像加速”中填写 mirror 后重试。"
    return 1
}

valid_docker_container_name() {
    case "$1" in
        ""|*/*|*[!A-Za-z0-9_.-]*) return 1 ;;
        *) return 0 ;;
    esac
}

list_docker_containers() {
    if ! command_exists docker; then
        warn "未安装 docker。"
        return 1
    fi
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
}

prompt_docker_container_name() {
    local prompt="$1" name
    echo >&2
    list_docker_containers >&2 || true
    read -r -p "$prompt: " name || name=""
    valid_docker_container_name "$name" || die "容器名称不合法：$name"
    docker_container_exists "$name" || die "容器不存在：$name"
    echo "$name"
}

start_docker_container_by_name() {
    local name="$1"
    docker_container_exists "$name" || die "容器不存在：$name"
    if docker_container_running "$name"; then
        ok "$name 已在运行。"
        return 0
    fi
    systemctl start docker.service >/dev/null 2>&1 || true
    docker start "$name" >/dev/null
    ok "$name 已启动。"
}

stop_docker_container_by_name() {
    local name="$1"
    docker_container_exists "$name" || die "容器不存在：$name"
    if ! docker_container_running "$name"; then
        ok "$name 已停止。"
        return 0
    fi
    docker stop "$name" >/dev/null
    ok "$name 已停止。"
}

restart_docker_container_by_name() {
    local name="$1"
    docker_container_exists "$name" || die "容器不存在：$name"
    docker restart "$name" >/dev/null
    ok "$name 已重启。"
}

attach_docker_container_by_name() {
    local name="$1" shell
    docker_container_exists "$name" || die "容器不存在：$name"
    start_docker_container_by_name "$name"
    for shell in /bin/bash /system/bin/sh /bin/sh /vendor/bin/sh; do
        if docker exec "$name" "$shell" -c 'exit 0' >/dev/null 2>&1; then
            docker exec -it "$name" "$shell"
            return 0
        fi
    done
    docker exec -it "$name" sh
}

set_docker_container_autostart() {
    local name="$1" policy="$2"
    docker_container_exists "$name" || die "容器不存在：$name"
    docker update --restart "$policy" "$name" >/dev/null
    case "$policy" in
        no) ok "已取消 $name 开机自启动。" ;;
        *) ok "已启用 $name 开机自启动：$policy" ;;
    esac
}

repair_all_docker_autostart() {
    local name
    if ! command_exists docker; then
        warn "未安装 docker，已跳过容器自启动修复。"
        return 0
    fi
    while read -r name; do
        [ -n "$name" ] || continue
        set_docker_container_autostart "$name" unless-stopped
    done < <(docker_container_names)
}

write_docker_container_shortcut() {
    local name="$1" target="/usr/local/bin/$1"
    valid_docker_container_name "$name" || { warn "跳过非法容器名：$name"; return 0; }
    if [ -e "$target" ] && ! grep -qs 'EasePi-R2 Docker container shortcut' "$target"; then
        warn "$target 已存在且不是本脚本生成，已跳过。"
        return 0
    fi
    cat > "$target" <<EOF
#!/bin/sh
# EasePi-R2 Docker container shortcut: ${name}
set -eu

CT_NAME="${name}"
CONFIG_FILE="${CONFIG_FILE}"

running() {
    docker inspect -f '{{.State.Running}}' "\$CT_NAME" 2>/dev/null | grep -qx true
}

start_ct() {
    if running; then
        return 0
    fi
    systemctl start docker.service >/dev/null 2>&1 || true
    docker start "\$CT_NAME" >/dev/null
}

shell_ct() {
    start_ct
    for sh in /bin/bash /system/bin/sh /bin/sh /vendor/bin/sh; do
        if docker exec "\$CT_NAME" "\$sh" -c 'exit 0' >/dev/null 2>&1; then
            exec docker exec -it "\$CT_NAME" "\$sh"
        fi
    done
    exec docker exec -it "\$CT_NAME" sh
}

adb_connect() {
    [ -r "\$CONFIG_FILE" ] && . "\$CONFIG_FILE"
    case "\${REDROID_NETWORK_MODE:-port}" in
        macvlan)
            exec adb connect "\${REDROID_IP:-${REDROID_IP}}:5555"
            ;;
        *)
            exec adb connect "\${REDROID_ADB_HOST:-127.0.0.1}:\${REDROID_ADB_PORT:-5555}"
            ;;
    esac
}

case "\${1:-shell}" in
    shell|attach|console|"") shell_ct ;;
    start) start_ct ;;
    stop) docker stop "\$CT_NAME" >/dev/null ;;
    restart) docker restart "\$CT_NAME" >/dev/null ;;
    status) docker ps -a --filter "name=^\${CT_NAME}$" ;;
    logs) shift || true; exec docker logs -f "\$@" "\$CT_NAME" ;;
    adb) shift || true; adb_connect ;;
    *) start_ct; exec docker exec -it "\$CT_NAME" "\$@" ;;
esac
EOF
    chmod 755 "$target"
    ok "已生成快捷命令：$target"
}

write_all_docker_shortcuts() {
    local name
    if ! command_exists docker; then
        warn "未安装 docker，已跳过快捷命令生成。"
        return 0
    fi
    while read -r name; do
        [ -n "$name" ] || continue
        write_docker_container_shortcut "$name"
    done < <(docker_container_names)
}

docker_container_manager_menu() {
    local choice name
    while true; do
        echo
        echo "========== Docker 容器管理 =========="
        echo "1. 查看容器"
        echo "2. 启动容器"
        echo "3. 停止容器"
        echo "4. 重启容器"
        echo "5. 进入容器后台"
        echo "6. 查看容器日志"
        echo "7. 启用容器开机自启动"
        echo "8. 取消容器开机自启动"
        echo "9. 修复所有容器开机自启动"
        echo "10. 生成容器快捷命令"
        echo "0. 返回"
        read -r -p "请选择: " choice || return
        case "$choice" in
            1) list_docker_containers; pause_enter ;;
            2)
                name="$(prompt_docker_container_name "请输入要启动的容器名称")"
                start_docker_container_by_name "$name"
                pause_enter
                ;;
            3)
                name="$(prompt_docker_container_name "请输入要停止的容器名称")"
                stop_docker_container_by_name "$name"
                pause_enter
                ;;
            4)
                name="$(prompt_docker_container_name "请输入要重启的容器名称")"
                restart_docker_container_by_name "$name"
                pause_enter
                ;;
            5)
                name="$(prompt_docker_container_name "请输入要进入的容器名称")"
                attach_docker_container_by_name "$name"
                pause_enter
                ;;
            6)
                name="$(prompt_docker_container_name "请输入要查看日志的容器名称")"
                docker logs --tail 200 -f "$name"
                pause_enter
                ;;
            7)
                name="$(prompt_docker_container_name "请输入要启用自启动的容器名称")"
                set_docker_container_autostart "$name" unless-stopped
                pause_enter
                ;;
            8)
                name="$(prompt_docker_container_name "请输入要取消自启动的容器名称")"
                set_docker_container_autostart "$name" no
                pause_enter
                ;;
            9) repair_all_docker_autostart; pause_enter ;;
            10) write_all_docker_shortcuts; pause_enter ;;
            0) return ;;
            *) warn "无效选择。" ;;
        esac
    done
}

image_manager_menu() {
    local choice image
    while true; do
        echo
        echo "========== Redroid 镜像管理 =========="
        echo "1. 查看本地 Redroid 镜像"
        echo "2. 拉取 RK3588 推荐镜像：$REDROID_RK3588_IMAGE"
        echo "3. 拉取当前默认镜像：$REDROID_IMAGE"
        echo "4. 拉取自定义镜像"
        echo "5. 删除本地镜像"
        echo "0. 返回"
        read -r -p "请选择: " choice || return
        case "$choice" in
            1) docker images | awk 'NR==1 || /redroid/' ; pause_enter ;;
            2)
                if pull_docker_image "$REDROID_RK3588_IMAGE"; then
                    REDROID_IMAGE="$REDROID_RK3588_IMAGE"
                    save_config
                fi
                pause_enter
                ;;
            3) pull_docker_image "$REDROID_IMAGE" || true; pause_enter ;;
            4)
                image="$(read_default "请输入镜像名" "$REDROID_IMAGE")"
                if pull_docker_image "$image"; then
                    REDROID_IMAGE="$image"
                    save_config
                fi
                pause_enter
                ;;
            5)
                read -r -p "请输入要删除的镜像名或 ID: " image || image=""
                [ -n "$image" ] && docker rmi "$image" || true
                pause_enter
                ;;
            0) return ;;
            *) warn "无效选择。" ;;
        esac
    done
}

ensure_redroid_network() {
    if docker network inspect "$REDROID_NET" >/dev/null 2>&1; then
        return 0
    fi
    ip link show "$REDROID_PARENT" >/dev/null 2>&1 || die "未找到 $REDROID_PARENT。请先用 1.sh 安装 OpenWrt，或手工创建 br-hostlan。"
    docker network create -d macvlan \
        --subnet "$REDROID_SUBNET" \
        --gateway "$REDROID_GATEWAY" \
        -o parent="$REDROID_PARENT" \
        "$REDROID_NET"
}

install_redroid() {
    need_root
    load_config
    install_redroid_dependencies

    CONTAINER_NAME="$(read_default "容器名称" "$CONTAINER_NAME")"
    REDROID_IMAGE="$(read_default "Redroid 镜像" "$REDROID_IMAGE")"
    REDROID_NETWORK_MODE="$(read_choice "网络模式（port=端口映射，macvlan=br-hostlan 固定 IP）" "$REDROID_NETWORK_MODE" port macvlan)"
    if [ "$REDROID_NETWORK_MODE" = "macvlan" ]; then
        REDROID_PARENT="$(read_default "桥接父接口" "$REDROID_PARENT")"
        REDROID_SUBNET="$(read_default "Redroid 所在网段" "$REDROID_SUBNET")"
        REDROID_GATEWAY="$(read_default "网关" "$REDROID_GATEWAY")"
        REDROID_IP="$(read_default "Redroid 固定 IP" "$REDROID_IP")"
    else
        REDROID_ADB_PORT="$(read_default "ADB 映射端口" "$REDROID_ADB_PORT")"
        REDROID_ADB_HOST="$(read_default "快捷命令 adb 连接地址" "$REDROID_ADB_HOST")"
    fi
    REDROID_WIDTH="$(read_default "屏幕宽度" "$REDROID_WIDTH")"
    REDROID_HEIGHT="$(read_default "屏幕高度" "$REDROID_HEIGHT")"
    REDROID_DPI="$(read_default "屏幕 DPI" "$REDROID_DPI")"
    REDROID_FPS="$(read_default "屏幕 FPS" "$REDROID_FPS")"
    REDROID_FAKE_WIFI="$(read_choice "模拟 Wi-Fi（1=开启，0=关闭）" "$REDROID_FAKE_WIFI" 1 0)"
    REDROID_ADBD_BIND_ETH0="$(read_choice "ADB TCP 5555 监听容器内 eth0（非宿主网口，建议 1）" "$REDROID_ADBD_BIND_ETH0" 1 0)"
    REDROID_ENABLE_INPUT_SUBSYS="$(read_choice "启用 input 子系统（1=开启，0=关闭）" "$REDROID_ENABLE_INPUT_SUBSYS" 1 0)"
    REDROID_CREATE_SECURE_DISPLAY="$(read_choice "创建 secure display（1=开启，0=关闭）" "$REDROID_CREATE_SECURE_DISPLAY" 1 0)"
    REDROID_BUILD_CHARACTERISTICS="$(read_default "Android 设备形态 ro.build.characteristics（通常 default）" "$REDROID_BUILD_CHARACTERISTICS")"
    REDROID_RESTART_POLICY="$(read_choice "容器重启策略（no/unless-stopped/always）" "$REDROID_RESTART_POLICY" no unless-stopped always)"
    save_config

    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        confirm "容器 $CONTAINER_NAME 已存在，是否删除后重建？" n || return 1
        docker rm -f "$CONTAINER_NAME" >/dev/null
    fi

    ensure_dirs
    prepare_redroid_host
    [ "$REDROID_NETWORK_MODE" = "macvlan" ] && ensure_redroid_network
    if ! docker image inspect "$REDROID_IMAGE" >/dev/null 2>&1; then
        pull_docker_image "$REDROID_IMAGE" || die "镜像拉取失败，无法继续安装 Redroid。请检查网络，或先配置 Docker Hub 镜像加速/代理。"
    fi

    local data_dir dev adb_hint
    data_dir="${REDROID_DATA_DIR}/${CONTAINER_NAME}"
    mkdir -p "$data_dir"

    local args
    args=(
        run -d
        --name "$CONTAINER_NAME"
        --privileged
        --restart "$REDROID_RESTART_POLICY"
    )
    if [ "$REDROID_NETWORK_MODE" = "macvlan" ]; then
        args+=(
            --network "$REDROID_NET"
            --ip "$REDROID_IP"
        )
        adb_hint="${REDROID_IP}:5555"
    else
        args+=(-p "${REDROID_ADB_PORT}:5555")
        adb_hint="${REDROID_ADB_HOST}:${REDROID_ADB_PORT}"
    fi
    args+=(
        -v "${data_dir}:/data"
    )
    for dev in /dev/binderfs /dev/mali0 /dev/dri /dev/dma_heap /dev/uhid /dev/input; do
        [ -e "$dev" ] && args+=(-v "${dev}:${dev}")
    done

    args+=(
        "$REDROID_IMAGE"
        "androidboot.redroid_width=${REDROID_WIDTH}"
        "androidboot.redroid_height=${REDROID_HEIGHT}"
        "androidboot.redroid_dpi=${REDROID_DPI}"
        "androidboot.redroid_fps=${REDROID_FPS}"
        "androidboot.redroid_fake_wifi=${REDROID_FAKE_WIFI}"
        "androidboot.redroid_adbd_bind_eth0=${REDROID_ADBD_BIND_ETH0}"
        "androidboot.redroid_enable_input_subsys=${REDROID_ENABLE_INPUT_SUBSYS}"
        "androidboot.redroid_create_secure_display=${REDROID_CREATE_SECURE_DISPLAY}"
        "ro.build.characteristics=${REDROID_BUILD_CHARACTERISTICS}"
    )

    docker "${args[@]}" >/dev/null
    set_docker_container_autostart "$CONTAINER_NAME" "$REDROID_RESTART_POLICY"
    write_docker_container_shortcut "$CONTAINER_NAME"
    ok "Redroid 已启动。"
    echo "ADB 连接：adb connect ${adb_hint}"
}

backup_redroid() {
    need_root
    load_config
    local name file
    read -r -p "请输入要备份的容器名称 [${CONTAINER_NAME}]: " name || name=""
    name="${name:-$CONTAINER_NAME}"
    if docker ps --format '{{.Names}}' | grep -qx "$name"; then
        confirm "容器 $name 正在运行，是否先停止？" y && docker stop "$name" >/dev/null
    fi
    [ -d "${REDROID_DATA_DIR}/${name}" ] || die "未找到数据目录：${REDROID_DATA_DIR}/${name}"
    mkdir -p "$BACKUP_DIR"
    file="${BACKUP_DIR}/redroid_${name}_$(date +%Y%m%d-%H%M%S).tar.zst"
    docker inspect "$name" > "${file%.tar.zst}.inspect.json" 2>/dev/null || true
    tar --xattrs --numeric-owner -I zstd -cpf "$file" -C "$REDROID_DATA_DIR" "$name"
    ok "备份完成：$file"
}

restore_redroid() {
    need_root
    load_config
    local file name tmp src
    echo
    echo "========== 可用备份 =========="
    ls -1 "$BACKUP_DIR"/redroid_*.tar.zst 2>/dev/null || true
    echo
    read -r -p "请输入要还原的备份文件名或完整路径: " file || file=""
    [ -n "$file" ] || die "备份文件不能为空。"
    case "$file" in
        /*) ;;
        *) file="${BACKUP_DIR}/${file}" ;;
    esac
    [ -f "$file" ] || die "备份文件不存在：$file"
    name="$(basename "$file" | sed -E 's/^redroid_//; s/_[0-9]{8}-[0-9]{6}\.tar\.zst$//')"
    name="$(read_default "还原为容器名称" "$name")"
    if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
        confirm "容器 $name 已存在，是否删除容器并覆盖数据？" n || return 1
        docker rm -f "$name" >/dev/null
    fi
    tmp="$(mktemp -d)"
    mkdir -p "$REDROID_DATA_DIR"
    tar -I zstd -xpf "$file" -C "$tmp"
    src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    [ -n "$src" ] || die "备份文件里没有 Redroid 数据目录。"
    rm -rf "${REDROID_DATA_DIR:?}/${name}"
    mv "$src" "${REDROID_DATA_DIR}/${name}"
    rm -rf "$tmp"
    ok "数据已还原：${REDROID_DATA_DIR}/${name}"
    warn "如需启动容器，请返回主菜单执行一键安装 Redroid，并使用相同容器名。"
}

backup_restore_menu() {
    local choice
    while true; do
        echo
        echo "========== Redroid 备份 / 还原 =========="
        echo "1. 备份 Redroid 数据"
        echo "2. 还原 Redroid 数据"
        echo "0. 返回"
        read -r -p "请选择: " choice || return
        case "$choice" in
            1) backup_redroid; pause_enter ;;
            2) restore_redroid; pause_enter ;;
            0) return ;;
            *) warn "无效选择。" ;;
        esac
    done
}

show_status() {
    load_config
    echo
    echo "========== 当前状态 =========="
    show_docker_dirs
    echo
    echo "Docker 服务："
    systemctl --no-pager --full status docker.service 2>/dev/null | sed -n '1,8p' || true
    echo
    echo "Redroid 容器："
    docker ps -a --filter "name=${CONTAINER_NAME}" 2>/dev/null || true
    echo
    echo "Docker 网络："
    docker network inspect "$REDROID_NET" --format '{{json .IPAM.Config}}' 2>/dev/null || true
    echo
    echo "宿主桥："
    ip -br addr show "$REDROID_PARENT" 2>/dev/null || true
    echo
    echo "Redroid 模块："
    lsmod | grep -E 'binder|ashmem|overlay|br_netfilter|veth' || true
    echo
    echo "GPU 用户态："
    echo "  GPU 栈：$(detect_gpu_stack)"
    dpkg-query -W -f='  ${binary:Package} ${Version}\n' \
        libmali-valhall-g610-g24p0-gbm libdrm2 libgbm1 libegl-mesa0 libgles2 \
        libgl1-mesa-dri mesa-vulkan-drivers 2>/dev/null || true
    command -v clinfo >/dev/null 2>&1 && clinfo -l 2>/dev/null | sed 's/^/  /' || true
}

main_menu() {
    local choice
    load_config
    while true; do
        echo
        echo "========== ${APP_NAME} =========="
        echo "1. 一键检测并安装 Redroid 所有依赖（含 Docker）"
        echo "2. Docker 目录管理"
        echo "3. Redroid 镜像管理"
        echo "4. 一键安装 Redroid"
        echo "5. Redroid 备份 / 还原"
        echo "6. Docker 容器管理"
        echo "s. 查看当前状态"
        echo "0. 退出"
        read -r -p "请选择: " choice || exit 0
        case "$choice" in
            1) install_redroid_dependencies; pause_enter ;;
            2) docker_dirs_menu ;;
            3) image_manager_menu ;;
            4) install_redroid; pause_enter ;;
            5) backup_restore_menu ;;
            6) docker_container_manager_menu ;;
            s|S) show_status; pause_enter ;;
            0) exit 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

main_menu "$@"
