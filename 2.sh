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
REDROID_DATA_DIR="${REDROID_DATA_DIR:-${DOCKER_BASE}/redroid-data}"
BACKUP_DIR="${BACKUP_DIR:-${DOCKER_BASE}/backups}"

CONTAINER_NAME="${CONTAINER_NAME:-redroid}"
REDROID_IMAGE="${REDROID_IMAGE:-redroid/redroid:12.0.0_64only-latest}"
REDROID_NET="${REDROID_NET:-redroid-brhostlan}"
REDROID_PARENT="${REDROID_PARENT:-br-hostlan}"
REDROID_SUBNET="${REDROID_SUBNET:-10.10.0.0/24}"
REDROID_GATEWAY="${REDROID_GATEWAY:-10.10.0.1}"
REDROID_IP="${REDROID_IP:-10.10.0.50}"
REDROID_WIDTH="${REDROID_WIDTH:-1080}"
REDROID_HEIGHT="${REDROID_HEIGHT:-1920}"
REDROID_DPI="${REDROID_DPI:-480}"

ok() { echo "[OK] $*"; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

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

quote_sq() {
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

load_config() {
    if [ -r "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
    : "${DOCKER_BASE:=/docker}"
    : "${DOCKER_DATA_ROOT:=${DOCKER_BASE}/data}"
    : "${REDROID_DATA_DIR:=${DOCKER_BASE}/redroid-data}"
    : "${BACKUP_DIR:=${DOCKER_BASE}/backups}"
    : "${CONTAINER_NAME:=redroid}"
    : "${REDROID_IMAGE:=redroid/redroid:12.0.0_64only-latest}"
    : "${REDROID_NET:=redroid-brhostlan}"
    : "${REDROID_PARENT:=br-hostlan}"
    : "${REDROID_SUBNET:=10.10.0.0/24}"
    : "${REDROID_GATEWAY:=10.10.0.1}"
    : "${REDROID_IP:=10.10.0.50}"
    : "${REDROID_WIDTH:=1080}"
    : "${REDROID_HEIGHT:=1920}"
    : "${REDROID_DPI:=480}"
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF_CONF
DOCKER_BASE='$(quote_sq "$DOCKER_BASE")'
DOCKER_DATA_ROOT='$(quote_sq "$DOCKER_DATA_ROOT")'
REDROID_DATA_DIR='$(quote_sq "$REDROID_DATA_DIR")'
BACKUP_DIR='$(quote_sq "$BACKUP_DIR")'
CONTAINER_NAME='$(quote_sq "$CONTAINER_NAME")'
REDROID_IMAGE='$(quote_sq "$REDROID_IMAGE")'
REDROID_NET='$(quote_sq "$REDROID_NET")'
REDROID_PARENT='$(quote_sq "$REDROID_PARENT")'
REDROID_SUBNET='$(quote_sq "$REDROID_SUBNET")'
REDROID_GATEWAY='$(quote_sq "$REDROID_GATEWAY")'
REDROID_IP='$(quote_sq "$REDROID_IP")'
REDROID_WIDTH='$(quote_sq "$REDROID_WIDTH")'
REDROID_HEIGHT='$(quote_sq "$REDROID_HEIGHT")'
REDROID_DPI='$(quote_sq "$REDROID_DPI")'
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

ensure_dirs() {
    mkdir -p "$DOCKER_BASE" "$DOCKER_DATA_ROOT" "$REDROID_DATA_DIR" "$BACKUP_DIR" "$CONFIG_DIR"
}

write_docker_daemon() {
    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    cat > /etc/docker/daemon.json <<EOF_DOCKER
{
  "data-root": "$DOCKER_DATA_ROOT",
  "iptables": true
}
EOF_DOCKER
}

prepare_redroid_host() {
    local modules ok_modules missing_modules mod
    modules=(binder_linux ashmem_linux overlay veth br_netfilter tun 8021q)
    ok_modules=()
    missing_modules=()

    for mod in "${modules[@]}"; do
        if modprobe "$mod" >/dev/null 2>&1; then
            ok_modules+=("$mod")
        else
            missing_modules+=("$mod")
        fi
    done

    mkdir -p /etc/modules-load.d /etc/sysctl.d
    printf '%s\n' "${ok_modules[@]}" > /etc/modules-load.d/easepi-r2-redroid.conf

    cat > /etc/sysctl.d/90-easepi-r2-redroid.conf <<'EOF_SYSCTL'
kernel.unprivileged_userns_clone=1
user.max_user_namespaces=28633
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
-net.bridge.bridge-nf-call-iptables=1
-net.bridge.bridge-nf-call-ip6tables=1
EOF_SYSCTL
    sysctl --system >/dev/null 2>&1 || true

    mkdir -p /dev/binderfs
    if grep -qw binder /proc/filesystems; then
        mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs 2>/dev/null || true
    fi

    if [ "${#missing_modules[@]}" -gt 0 ]; then
        warn "以下 Redroid 模块当前未能加载，若 Redroid 启动异常，需要检查 LiteHost 内核配置："
        printf '  - %s\n' "${missing_modules[@]}"
    fi
}

install_redroid_dependencies() {
    need_root
    local required optional missing_required missing_optional
    required=(
        docker.io containerd runc
        iproute2 iptables ca-certificates curl jq kmod
        util-linux e2fsprogs rsync zstd tar gzip
        android-tools-adb
    )
    optional=(
        android-tools-fastboot v4l-utils libdrm2 libgbm1
        ocl-icd-libopencl1 clinfo docker-compose-plugin
    )

    echo
    echo "========== 检测 Redroid / Docker 依赖 =========="
    mapfile -t missing_required < <(dpkg_missing_packages "${required[@]}")
    mapfile -t missing_optional < <(dpkg_missing_packages "${optional[@]}")

    if [ "${#missing_required[@]}" -eq 0 ] && [ "${#missing_optional[@]}" -eq 0 ]; then
        ok "Redroid 依赖已经安装完整。"
    else
        [ "${#missing_required[@]}" -eq 0 ] || {
            warn "缺少必需依赖："
            printf '  - %s\n' "${missing_required[@]}"
        }
        [ "${#missing_optional[@]}" -eq 0 ] || {
            echo "缺少可选依赖："
            printf '  - %s\n' "${missing_optional[@]}"
        }
        confirm "是否一键安装 Redroid 所有依赖？" y || { warn "已取消安装。"; return 1; }
        apt-get update
        apt_install_required "${required[@]}"
        apt_install_optional "${optional[@]}"
    fi

    ensure_dirs
    write_docker_daemon
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
    echo "Redroid 数据目录   ：$REDROID_DATA_DIR"
    echo "备份目录           ：$BACKUP_DIR"
    echo
    findmnt "$DOCKER_BASE" 2>/dev/null || true
    echo
    docker info --format 'Docker Root Dir: {{.DockerRootDir}}' 2>/dev/null || true
}

set_docker_dirs() {
    need_root
    load_config
    DOCKER_BASE="$(read_default "请输入 Docker 根目录" "$DOCKER_BASE")"
    DOCKER_DATA_ROOT="${DOCKER_BASE}/data"
    REDROID_DATA_DIR="${DOCKER_BASE}/redroid-data"
    BACKUP_DIR="${DOCKER_BASE}/backups"
    ensure_dirs
    write_docker_daemon
    save_config
    warn "Docker data-root 已改为 $DOCKER_DATA_ROOT，重启 Docker 后生效。"
    confirm "是否立即重启 Docker？" y && systemctl restart docker.service || true
}

dir_has_entries() {
    [ -d "$1" ] || return 1
    find "$1" -mindepth 1 -maxdepth 1 | read -r _
}

mount_docker_to_ssd() {
    need_root
    load_config
    echo
    echo "========== 磁盘列表 =========="
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
    echo
    read -r -p "请输入要挂载到 ${DOCKER_BASE} 的磁盘或分区路径: " dev || dev=""
    [ -n "$dev" ] || die "设备不能为空。"
    [ -b "$dev" ] || die "设备不存在：$dev"

    local type part fstype uuid tmp
    type="$(lsblk -dn -o TYPE "$dev" 2>/dev/null | head -n1)"
    if [ "$type" = "disk" ]; then
        warn "$dev 是整块磁盘，如继续会创建 GPT 分区并格式化。"
        read -r -p "如确认清空该磁盘，请输入 FORMAT: " ans || ans=""
        [ "$ans" = "FORMAT" ] || die "未确认 FORMAT，已取消。"
        parted -s "$dev" mklabel gpt
        parted -s "$dev" mkpart primary ext4 0% 100%
        partprobe "$dev" || true
        sleep 2
        part="${dev}1"
        [ -b "$part" ] || part="$(lsblk -ln -o PATH "$dev" | tail -n1)"
        mkfs.ext4 -F -L EasePiR2_Docker "$part"
        dev="$part"
    else
        fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
        if [ -z "$fstype" ]; then
            warn "$dev 没有文件系统。"
            read -r -p "如确认格式化为 ext4，请输入 FORMAT: " ans || ans=""
            [ "$ans" = "FORMAT" ] || die "未确认 FORMAT，已取消。"
            mkfs.ext4 -F -L EasePiR2_Docker "$dev"
        elif [ "$fstype" != "ext4" ]; then
            die "$dev 当前文件系统是 $fstype，建议备份后手工格式化为 ext4。"
        fi
    fi

    uuid="$(blkid -o value -s UUID "$dev" 2>/dev/null || true)"
    [ -n "$uuid" ] || die "无法读取 UUID。"

    systemctl stop docker.service docker.socket containerd.service >/dev/null 2>&1 || true
    tmp="/mnt/easepi-r2-docker-ssd"
    mkdir -p "$tmp" "$DOCKER_BASE"
    mount "$dev" "$tmp"
    if dir_has_entries "$DOCKER_BASE" && confirm "$DOCKER_BASE 已有内容，是否复制到 SSD？" y; then
        rsync -aHAX --numeric-ids "${DOCKER_BASE}/" "${tmp}/"
    fi
    umount "$tmp"

    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
    grep -vE "[[:space:]]${DOCKER_BASE//\//\\/}[[:space:]]" /etc/fstab > /tmp/fstab.easepi-r2-redroid || true
    printf 'UUID=%s %s ext4 defaults,noatime 0 2\n' "$uuid" "$DOCKER_BASE" >> /tmp/fstab.easepi-r2-redroid
    install -m 0644 /tmp/fstab.easepi-r2-redroid /etc/fstab

    mount "$DOCKER_BASE"
    ensure_dirs
    write_docker_daemon
    save_config
    systemctl enable --now docker.service >/dev/null 2>&1 || true
    ok "SSD 已挂载到 $DOCKER_BASE。"
    findmnt "$DOCKER_BASE" || true
}

docker_dirs_menu() {
    local choice
    while true; do
        echo
        echo "========== Docker 目录管理 =========="
        echo "1. 查看当前 Docker 目录"
        echo "2. 修改 Docker 根目录"
        echo "3. 磁盘工具：检测 M.2/SSD 并挂载到 Docker 根目录"
        echo "0. 返回"
        read -r -p "请选择: " choice || return
        case "$choice" in
            1) show_docker_dirs; pause_enter ;;
            2) set_docker_dirs; pause_enter ;;
            3) mount_docker_to_ssd; pause_enter ;;
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
        echo "2. 拉取默认镜像：$REDROID_IMAGE"
        echo "3. 拉取自定义镜像"
        echo "4. 删除本地镜像"
        echo "0. 返回"
        read -r -p "请选择: " choice || return
        case "$choice" in
            1) docker images | awk 'NR==1 || /redroid/' ; pause_enter ;;
            2) docker pull "$REDROID_IMAGE"; pause_enter ;;
            3)
                image="$(read_default "请输入镜像名" "$REDROID_IMAGE")"
                docker pull "$image"
                REDROID_IMAGE="$image"
                save_config
                pause_enter
                ;;
            4)
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
    REDROID_PARENT="$(read_default "桥接父接口" "$REDROID_PARENT")"
    REDROID_SUBNET="$(read_default "Redroid 所在网段" "$REDROID_SUBNET")"
    REDROID_GATEWAY="$(read_default "网关" "$REDROID_GATEWAY")"
    REDROID_IP="$(read_default "Redroid 固定 IP" "$REDROID_IP")"
    REDROID_WIDTH="$(read_default "屏幕宽度" "$REDROID_WIDTH")"
    REDROID_HEIGHT="$(read_default "屏幕高度" "$REDROID_HEIGHT")"
    REDROID_DPI="$(read_default "屏幕 DPI" "$REDROID_DPI")"
    save_config

    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        confirm "容器 $CONTAINER_NAME 已存在，是否删除后重建？" n || return 1
        docker rm -f "$CONTAINER_NAME"
    fi

    ensure_dirs
    prepare_redroid_host
    ensure_redroid_network
    docker image inspect "$REDROID_IMAGE" >/dev/null 2>&1 || docker pull "$REDROID_IMAGE"

    local data_dir
    data_dir="${REDROID_DATA_DIR}/${CONTAINER_NAME}"
    mkdir -p "$data_dir"

    local args
    args=(
        run -d
        --name "$CONTAINER_NAME"
        --privileged
        --restart unless-stopped
        --network "$REDROID_NET"
        --ip "$REDROID_IP"
        -v "${data_dir}:/data"
    )
    [ -d /dev/binderfs ] && args+=(-v /dev/binderfs:/dev/binderfs)
    [ -d /dev/dri ] && args+=(-v /dev/dri:/dev/dri)

    args+=(
        "$REDROID_IMAGE"
        "androidboot.redroid_width=${REDROID_WIDTH}"
        "androidboot.redroid_height=${REDROID_HEIGHT}"
        "androidboot.redroid_dpi=${REDROID_DPI}"
    )

    docker "${args[@]}"
    ok "Redroid 已启动。"
    echo "ADB 连接：adb connect ${REDROID_IP}:5555"
}

backup_redroid() {
    need_root
    load_config
    local name file
    read -r -p "请输入要备份的容器名称 [${CONTAINER_NAME}]: " name || name=""
    name="${name:-$CONTAINER_NAME}"
    if docker ps --format '{{.Names}}' | grep -qx "$name"; then
        confirm "容器 $name 正在运行，是否先停止？" y && docker stop "$name"
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
        docker rm -f "$name"
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
        echo "4. 一键安装 Redroid（桥接到 br-hostlan）"
        echo "5. Redroid 备份 / 还原"
        echo "s. 查看当前状态"
        echo "0. 退出"
        read -r -p "请选择: " choice || exit 0
        case "$choice" in
            1) install_redroid_dependencies; pause_enter ;;
            2) docker_dirs_menu ;;
            3) image_manager_menu ;;
            4) install_redroid; pause_enter ;;
            5) backup_restore_menu ;;
            s|S) show_status; pause_enter ;;
            0) exit 0 ;;
            *) warn "无效选择。" ;;
        esac
    done
}

main_menu "$@"
