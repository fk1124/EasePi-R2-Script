#!/usr/bin/env bash
set -uo pipefail

VERSION="2026-05-19-routeros-chr-installer"

INSTALL_CMD="/usr/local/sbin/routerosinstall"
CONSOLE_CMD="/usr/local/sbin/routeros"
CONFIG_DIR="/etc/routerosinstall"
CONFIG_FILE="$CONFIG_DIR/config.env"
PRESET_RSC="$CONFIG_DIR/routeros-preset.rsc"
LIB_DIR="/usr/local/lib/routerosinstall"
HOSTNET_SCRIPT="$LIB_DIR/hostnet.sh"
START_SCRIPT="$LIB_DIR/start-vm.sh"
SERVICE_FILE="/etc/systemd/system/routeros-chr.service"
NM_UNMANAGED_CONF="/etc/NetworkManager/conf.d/99-routerosinstall-unmanaged.conf"
NETWORKD_PREFIX="/etc/systemd/network/80-routerosinstall"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

ok(){ printf '%s\n' "${GREEN}[完成]${RESET} $*"; }
info(){ printf '%s\n' "${BLUE}[信息]${RESET} $*"; }
warn(){ printf '%s\n' "${YELLOW}[提醒]${RESET} $*"; }
err(){ printf '%s\n' "${RED}[错误]${RESET} $*"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

pause(){
  printf '%s' "按回车继续..."
  IFS= read -r _ || true
}

need_root(){
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 执行：sudo bash 9.sh 或 sudo routerosinstall"
    exit 1
  fi
}

read_default(){
  local prompt="$1" def="${2:-}" val
  if [ -n "$def" ]; then
    printf '%s' "$prompt [$def]: "
  else
    printf '%s' "$prompt: "
  fi
  IFS= read -r val || true
  printf '%s' "${val:-$def}"
}

confirm(){
  local prompt="$1" def="${2:-y}" val hint
  if [ "$def" = "y" ]; then
    hint="Y/n"
  else
    hint="y/N"
  fi
  printf '%s' "$prompt [$hint]: "
  IFS= read -r val || true
  val="${val:-$def}"
  case "${val,,}" in
    y|yes|1|true|ok|是|好|确认) return 0 ;;
    *) return 1 ;;
  esac
}

space_to_continue(){
  local key
  printf '%s' "按空格继续执行，按其他任意键取消: "
  IFS= read -rsn1 key || true
  printf '\n'
  [ "$key" = " " ]
}

print_title(){
  clear 2>/dev/null || true
  printf '%s\n' "${BOLD}RouterOS CHR KVM 安装与管理脚本${RESET}"
  printf '%s\n' "版本: $VERSION"
  printf '%s\n\n' "配置目录: $CONFIG_DIR"
}

quote_env(){
  printf '%q' "$1"
}

save_config(){
  mkdir -p "$CONFIG_DIR"
  {
    printf 'IMAGE_PATH=%q\n' "$IMAGE_PATH"
    printf 'DISK_FORMAT=%q\n' "$DISK_FORMAT"
    printf 'QEMU_BIN=%q\n' "$QEMU_BIN"
    printf 'VM_CPUS=%q\n' "$VM_CPUS"
    printf 'VM_MEMORY_MB=%q\n' "$VM_MEMORY_MB"
    printf 'NET_QUEUES=%q\n' "$NET_QUEUES"
    printf 'VM_IFACES=%q\n' "$VM_IFACES"
    printf 'VM_BRIDGES=%q\n' "$VM_BRIDGES"
    printf 'VM_TAPS=%q\n' "$VM_TAPS"
    printf 'VM_MACS=%q\n' "$VM_MACS"
    printf 'PERSIST_HOST_NET=%q\n' "$PERSIST_HOST_NET"
    printf 'SERIAL_SOCK=%q\n' "$SERIAL_SOCK"
    printf 'MONITOR_SOCK=%q\n' "$MONITOR_SOCK"
    printf 'PID_FILE=%q\n' "$PID_FILE"
    printf 'ROS_IDENTITY=%q\n' "$ROS_IDENTITY"
    printf 'ROS_WAN_IFACE=%q\n' "$ROS_WAN_IFACE"
    printf 'ROS_LAN_BRIDGE=%q\n' "$ROS_LAN_BRIDGE"
    printf 'ROS_LAN_PORTS=%q\n' "$ROS_LAN_PORTS"
    printf 'ROS_LAN_IP=%q\n' "$ROS_LAN_IP"
    printf 'ROS_LAN_PREFIX=%q\n' "$ROS_LAN_PREFIX"
    printf 'ROS_DHCP_START=%q\n' "$ROS_DHCP_START"
    printf 'ROS_DHCP_END=%q\n' "$ROS_DHCP_END"
    printf 'ROS_DNS_SERVERS=%q\n' "$ROS_DNS_SERVERS"
  } > "$CONFIG_FILE"
}

load_config(){
  IMAGE_PATH="/root/routeros.img"
  DISK_FORMAT="raw"
  QEMU_BIN="qemu-system-aarch64"
  VM_CPUS="$(nproc 2>/dev/null || echo 4)"
  VM_MEMORY_MB="1024"
  NET_QUEUES="4"
  VM_IFACES="eth1 eth2 eth3"
  VM_BRIDGES="br-ros1 br-ros2 br-ros3"
  VM_TAPS="tap-ros1 tap-ros2 tap-ros3"
  VM_MACS="52:54:00:21:00:01 52:54:00:21:00:02 52:54:00:21:00:03"
  PERSIST_HOST_NET="1"
  SERIAL_SOCK="/run/routeros/serial.sock"
  MONITOR_SOCK="/run/routeros/monitor.sock"
  PID_FILE="/run/routeros/routeros-chr.pid"
  ROS_IDENTITY="CHR-R2"
  ROS_WAN_IFACE="ether1"
  ROS_LAN_BRIDGE="br-lan"
  ROS_LAN_PORTS="ether2 ether3"
  ROS_LAN_IP="10.10.10.1"
  ROS_LAN_PREFIX="24"
  ROS_DHCP_START="10.10.10.100"
  ROS_DHCP_END="10.10.10.200"
  ROS_DNS_SERVERS="223.5.5.5,119.29.29.29"

  if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
}

bootstrap_install(){
  need_root
  local src
  src="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s' "$0")"
  if [ ! -f "$src" ]; then
    err "无法定位当前脚本文件，请把 9.sh 保存到本地后再执行。"
    exit 1
  fi
  mkdir -p "$(dirname "$INSTALL_CMD")"
  install -m 0755 "$src" "$INSTALL_CMD"
  ok "已生成命令: $INSTALL_CMD"
  info "现在输入 routerosinstall 即可进入菜单。"
  info "后续启动虚拟机后，输入 routeros 可进入 RouterOS 控制台。"
}

pkg_installed(){
  dpkg -s "$1" >/dev/null 2>&1
}

dependency_report(){
  local arch kernel virt kvm_state vhost_state qemu_state
  arch="$(uname -m)"
  kernel="$(uname -r)"
  virt="未知"
  if grep -q -E 'Features.*(virt|hyp)' /proc/cpuinfo 2>/dev/null; then
    virt="CPU 信息包含虚拟化特征"
  elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
    virt="ARM64 平台，实际以 /dev/kvm 为准"
  fi

  if [ -e /dev/kvm ]; then
    kvm_state="可用"
  else
    kvm_state="未发现 /dev/kvm"
  fi
  if [ -e /dev/vhost-net ]; then
    vhost_state="可用"
  else
    vhost_state="未发现 /dev/vhost-net，virtio-net 会退回普通 tap"
  fi
  if has_cmd "$QEMU_BIN"; then
    qemu_state="$("$QEMU_BIN" --version 2>/dev/null | head -n1)"
  elif has_cmd qemu-system-aarch64; then
    qemu_state="$(qemu-system-aarch64 --version 2>/dev/null | head -n1)"
  else
    qemu_state="未安装 qemu-system-aarch64"
  fi

  printf '%s\n' "系统架构: $arch"
  printf '%s\n' "内核版本: $kernel"
  printf '%s\n' "虚拟化: $virt"
  printf '%s\n' "KVM: $kvm_state"
  printf '%s\n' "vhost-net: $vhost_state"
  printf '%s\n' "QEMU: $qemu_state"
  printf '%s\n' "systemd: $(has_cmd systemctl && systemctl --version | head -n1 || echo 未发现)"
  printf '\n'

  local item cmd pkg status
  printf '%s\n' "依赖检查:"
  while IFS='|' read -r cmd pkg; do
    [ -n "$cmd" ] || continue
    if has_cmd "$cmd"; then
      status="${GREEN}OK${RESET}"
    else
      status="${YELLOW}缺失，包名通常为 $pkg${RESET}"
    fi
    printf '  %-22s %b\n' "$cmd" "$status"
  done <<'EOF_DEPS'
qemu-system-aarch64|qemu-system-arm
qemu-img|qemu-utils
ip|iproute2
socat|socat
ssh|openssh-client
unzip|unzip
curl|curl
ethtool|ethtool
lsmod|kmod
modprobe|kmod
systemctl|systemd
EOF_DEPS
}

install_dependencies(){
  local packages missing pkg
  packages=(
    qemu-system-arm
    qemu-utils
    iproute2
    socat
    openssh-client
    unzip
    curl
    ethtool
    kmod
    procps
  )
  missing=()
  for pkg in "${packages[@]}"; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    ok "APT 依赖包已安装。"
  else
    warn "将安装缺失包: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" || return 1
    ok "依赖安装完成。"
  fi

  modprobe kvm 2>/dev/null || true
  modprobe vhost_net 2>/dev/null || true
}

menu_dependencies(){
  print_title
  dependency_report
  printf '\n'
  if space_to_continue; then
    install_dependencies
  else
    warn "已取消依赖安装。"
  fi
  pause
}

physical_ifaces(){
  local p ifname type
  for p in /sys/class/net/*; do
    [ -e "$p" ] || continue
    ifname="${p##*/}"
    [ "$ifname" = "lo" ] && continue
    case "$ifname" in
      br-*|docker*|veth*|tap*|tun*|wg*|virbr*|ifb*|bond*|dummy*) continue ;;
    esac
    type="$(cat "$p/type" 2>/dev/null || echo 0)"
    [ "$type" = "1" ] || continue
    printf '%s\n' "$ifname"
  done
}

detect_network_managers(){
  local found=0
  printf '%s\n' "网络管理器检测:"
  if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    printf '  %-24s %s\n' "systemd-networkd" "运行中"
    found=1
  else
    printf '  %-24s %s\n' "systemd-networkd" "未运行"
  fi
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    printf '  %-24s %s\n' "NetworkManager" "运行中"
    found=1
  else
    printf '  %-24s %s\n' "NetworkManager" "未运行"
  fi
  if systemctl is-active --quiet networking 2>/dev/null; then
    printf '  %-24s %s\n' "ifupdown/networking" "运行中"
    found=1
  fi
  if systemctl is-active --quiet connman 2>/dev/null; then
    printf '  %-24s %s\n' "connman" "运行中"
    found=1
  fi
  if [ -d /etc/netplan ]; then
    printf '  %-24s %s\n' "netplan" "存在 /etc/netplan"
  fi
  [ "$found" -eq 0 ] && warn "没有发现常见网络管理服务处于运行状态。"
}

show_iface_usage(){
  local iface="$1" master addrs routes config
  master="$(basename "$(readlink -f "/sys/class/net/$iface/master" 2>/dev/null)" 2>/dev/null || true)"
  addrs="$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | xargs 2>/dev/null || true)"
  routes="$(ip route show dev "$iface" 2>/dev/null | sed 's/^/    /')"
  config="$(grep -Rsl "Name=$iface\\|interface-name=$iface\\|$iface" /etc/systemd/network /etc/netplan /etc/network/interfaces /etc/NetworkManager/system-connections 2>/dev/null | head -n5 | xargs 2>/dev/null || true)"
  printf '  %-10s state=%-8s master=%-10s addr=%s\n' "$iface" "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" "${master:-无}" "${addrs:-无}"
  if [ -n "$routes" ]; then
    printf '%s\n' "$routes"
  fi
  if [ -n "$config" ]; then
    printf '    可能相关配置: %s\n' "$config"
  fi
}

menu_network_check(){
  print_title
  detect_network_managers
  printf '\n%s\n' "链路概览:"
  ip -br link show 2>/dev/null || true
  printf '\n%s\n' "地址概览:"
  ip -br addr show 2>/dev/null || true
  printf '\n%s\n' "默认路由:"
  ip route show default 2>/dev/null || true
  printf '\n%s\n' "物理网口占用情况:"
  local iface
  while IFS= read -r iface; do
    show_iface_usage "$iface"
  done < <(physical_ifaces)
  printf '\n'
  warn "后续选择给 RouterOS 的宿主机网口会被 bridge/tap 接管，脚本启动虚拟机时会清空这些网口上的 IP 并加入对应 br-rosX。"
  warn "不要把当前 SSH 管理入口选进去，除非你有串口、HDMI 或其他备用管理通道。"
  warn "如果 NetworkManager、netplan 或 systemd-networkd 已经管理这些网口，需要按菜单 3 的持久化选项处理，避免重启后被系统重新抢占。"
  pause
}

guess_disk_format(){
  case "${1,,}" in
    *.qcow2) printf '%s' "qcow2" ;;
    *.vdi) printf '%s' "vdi" ;;
    *.vmdk) printf '%s' "vmdk" ;;
    *) printf '%s' "raw" ;;
  esac
}

choose_image_from_root(){
  local default="/root/routeros.img"
  local -a files
  local i sel chosen entry out
  files=()

  if [ -f "$default" ]; then
    ok "检测到 $default"
    IMAGE_PATH="$default"
    DISK_FORMAT="$(guess_disk_format "$IMAGE_PATH")"
    return 0
  fi

  while IFS= read -r f; do
    files+=("$f")
  done < <(find /root -maxdepth 1 -type f \( -iname '*.img' -o -iname '*.raw' -o -iname '*.qcow2' -o -iname '*.vdi' -o -iname '*.vmdk' -o -iname '*.img.zip' -o -iname '*.vdi.zip' -o -iname '*.zip' \) 2>/dev/null | sort)

  if [ "${#files[@]}" -eq 0 ]; then
    warn "/root 下没有找到 routeros.img 或其他 img/zip 镜像。"
    IMAGE_PATH="$(read_default "请输入 RouterOS 镜像完整路径" "$IMAGE_PATH")"
    DISK_FORMAT="$(guess_disk_format "$IMAGE_PATH")"
    return 0
  fi

  printf '%s\n' "没有找到 /root/routeros.img，但发现以下镜像候选:"
  for i in "${!files[@]}"; do
    printf '  %s. %s\n' "$((i+1))" "${files[$i]}"
  done
  printf '%s' "选择要使用的镜像编号，直接回车手动输入路径: "
  IFS= read -r sel || true
  if [ -z "$sel" ]; then
    IMAGE_PATH="$(read_default "请输入 RouterOS 镜像完整路径" "$IMAGE_PATH")"
    DISK_FORMAT="$(guess_disk_format "$IMAGE_PATH")"
    return 0
  fi
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#files[@]}" ]; then
    warn "选择无效，保持当前路径: $IMAGE_PATH"
    return 1
  fi

  chosen="${files[$((sel-1))]}"
  case "${chosen,,}" in
    *.zip)
      if ! has_cmd unzip; then
        err "缺少 unzip，先执行菜单 1 安装依赖。"
        return 1
      fi
      entry="$(unzip -Z1 "$chosen" 2>/dev/null | grep -Ei '\.(img|raw|qcow2|vdi|vmdk)$' | head -n1 || true)"
      if [ -z "$entry" ]; then
        err "压缩包内没有找到 img/raw/qcow2/vdi/vmdk 文件。"
        return 1
      fi
      out="/root/routeros.img"
      if [ -f "$out" ] && ! confirm "$out 已存在，是否覆盖" "n"; then
        warn "已取消解压。"
        return 1
      fi
      info "正在从 $chosen 解压 $entry 到 $out"
      unzip -p "$chosen" "$entry" > "$out" || return 1
      chmod 0600 "$out" 2>/dev/null || true
      IMAGE_PATH="$out"
      DISK_FORMAT="$(guess_disk_format "$entry")"
      ;;
    *)
      IMAGE_PATH="$chosen"
      DISK_FORMAT="$(guess_disk_format "$IMAGE_PATH")"
      ;;
  esac
}

choose_host_ifaces(){
  local -a phys chosen
  local count def iface i macs bridges taps input
  phys=()
  chosen=()
  while IFS= read -r iface; do
    phys+=("$iface")
  done < <(physical_ifaces)

  printf '\n%s\n' "可选物理网口:"
  if [ "${#phys[@]}" -eq 0 ]; then
    warn "没有自动发现物理网口，你仍可手动输入。"
  else
    for iface in "${phys[@]}"; do
      show_iface_usage "$iface"
    done
  fi

  count="$(read_default "给 RouterOS 配置几个 virtio-net 网口" "3")"
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
    count="3"
  fi

  for ((i=1; i<=count; i++)); do
    case "$i" in
      1) def="eth1" ;;
      2) def="eth2" ;;
      3) def="eth3" ;;
      *) def="" ;;
    esac
    input="$(read_default "第 $i 个 virtio-net 绑定的宿主机物理网口，输入 none 表示只建内部桥" "$def")"
    chosen+=("$input")
  done

  VM_IFACES="${chosen[*]}"
  bridges=()
  taps=()
  macs=()
  for ((i=1; i<=count; i++)); do
    bridges+=("br-ros$i")
    taps+=("tap-ros$i")
    macs+=("52:54:00:21:00:$(printf '%02x' "$i")")
  done
  VM_BRIDGES="${bridges[*]}"
  VM_TAPS="${taps[*]}"
  VM_MACS="${macs[*]}"

  ROS_WAN_IFACE="ether1"
  if [ "$count" -ge 2 ]; then
    ROS_LAN_PORTS=""
    for ((i=2; i<=count; i++)); do
      ROS_LAN_PORTS="${ROS_LAN_PORTS:+$ROS_LAN_PORTS }ether$i"
    done
  else
    ROS_LAN_PORTS=""
  fi
}

resize_disk_image(){
  local size
  if ! has_cmd qemu-img; then
    warn "缺少 qemu-img，跳过硬盘调整。"
    return 0
  fi
  printf '\n'
  qemu-img info "$IMAGE_PATH" 2>/dev/null || true
  size="$(read_default "如需扩容请输入目标大小，例如 2G、4G；直接回车跳过" "")"
  [ -z "$size" ] && return 0
  warn "只建议扩容，不建议缩小镜像。RouterOS 内部文件系统扩展由 RouterOS 自己处理。"
  if confirm "确认执行 qemu-img resize $IMAGE_PATH $size" "n"; then
    qemu-img resize "$IMAGE_PATH" "$size" && ok "镜像大小已调整。"
  fi
}

write_runtime_files(){
  mkdir -p "$CONFIG_DIR" "$LIB_DIR" /run/routeros

  cat > "$HOSTNET_SCRIPT" <<'EOF_HOSTNET'
#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="/etc/routerosinstall/config.env"
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

ACTION="${1:-up}"
mkdir -p /run/routeros

read -r -a ifaces <<< "${VM_IFACES:-}"
read -r -a bridges <<< "${VM_BRIDGES:-}"
read -r -a taps <<< "${VM_TAPS:-}"
queues="${NET_QUEUES:-1}"

create_tap(){
  local tap="$1"
  if ip link show "$tap" >/dev/null 2>&1; then
    return 0
  fi
  if [ "${queues:-1}" -gt 1 ] 2>/dev/null; then
    ip tuntap add dev "$tap" mode tap multi_queue 2>/dev/null || ip tuntap add dev "$tap" mode tap
  else
    ip tuntap add dev "$tap" mode tap
  fi
}

case "$ACTION" in
  up)
    modprobe tun 2>/dev/null || true
    modprobe vhost_net 2>/dev/null || true
    for i in "${!bridges[@]}"; do
      br="${bridges[$i]}"
      tap="${taps[$i]:-}"
      iface="${ifaces[$i]:-none}"
      ip link show "$br" >/dev/null 2>&1 || ip link add name "$br" type bridge
      ip link set "$br" up
      if [ -n "$tap" ]; then
        create_tap "$tap"
        ip link set "$tap" master "$br"
        ip link set "$tap" up
      fi
      if [ -n "$iface" ] && [ "$iface" != "none" ]; then
        if ip link show "$iface" >/dev/null 2>&1; then
          ip addr flush dev "$iface" 2>/dev/null || true
          ip link set "$iface" up 2>/dev/null || true
          ip link set "$iface" master "$br" 2>/dev/null || true
        else
          echo "routerosinstall: host iface $iface not found" >&2
        fi
      fi
    done
    ;;
  down)
    for i in "${!bridges[@]}"; do
      br="${bridges[$i]}"
      tap="${taps[$i]:-}"
      iface="${ifaces[$i]:-none}"
      if [ -n "$iface" ] && [ "$iface" != "none" ] && ip link show "$iface" >/dev/null 2>&1; then
        ip link set "$iface" nomaster 2>/dev/null || true
      fi
      if [ -n "$tap" ] && ip link show "$tap" >/dev/null 2>&1; then
        ip link set "$tap" down 2>/dev/null || true
        ip link delete "$tap" 2>/dev/null || true
      fi
      if ip link show "$br" >/dev/null 2>&1; then
        ip link set "$br" down 2>/dev/null || true
        ip link delete "$br" type bridge 2>/dev/null || true
      fi
    done
    ;;
  *)
    echo "usage: $0 up|down" >&2
    exit 2
    ;;
esac
EOF_HOSTNET
  chmod 0755 "$HOSTNET_SCRIPT"

  cat > "$START_SCRIPT" <<'EOF_START'
#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="/etc/routerosinstall/config.env"
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
IMAGE_PATH="${IMAGE_PATH:-/root/routeros.img}"
DISK_FORMAT="${DISK_FORMAT:-raw}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY_MB="${VM_MEMORY_MB:-1024}"
NET_QUEUES="${NET_QUEUES:-1}"
SERIAL_SOCK="${SERIAL_SOCK:-/run/routeros/serial.sock}"
MONITOR_SOCK="${MONITOR_SOCK:-/run/routeros/monitor.sock}"
PID_FILE="${PID_FILE:-/run/routeros/routeros-chr.pid}"

read -r -a taps <<< "${VM_TAPS:-tap-ros1 tap-ros2 tap-ros3}"
read -r -a macs <<< "${VM_MACS:-52:54:00:21:00:01 52:54:00:21:00:02 52:54:00:21:00:03}"

mkdir -p "$(dirname "$SERIAL_SOCK")"
rm -f "$SERIAL_SOCK" "$MONITOR_SOCK" "$PID_FILE"

if [ ! -f "$IMAGE_PATH" ]; then
  echo "routerosinstall: image not found: $IMAGE_PATH" >&2
  exit 1
fi

arch="$(uname -m)"
args=(-name routeros-chr)
if { [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; } && [ -e /dev/kvm ]; then
  args+=(-machine virt,accel=kvm,gic-version=3 -cpu host)
else
  args+=(-machine virt -cpu cortex-a72)
fi
args+=(-smp "$VM_CPUS" -m "${VM_MEMORY_MB}M")
args+=(-drive "file=$IMAGE_PATH,if=virtio,format=$DISK_FORMAT,cache=none,aio=threads,discard=unmap")

vhost="off"
[ -e /dev/vhost-net ] && vhost="on"
if ! [[ "$NET_QUEUES" =~ ^[0-9]+$ ]] || [ "$NET_QUEUES" -lt 1 ]; then
  NET_QUEUES=1
fi
vectors=$((NET_QUEUES * 2 + 2))
for i in "${!taps[@]}"; do
  tap="${taps[$i]}"
  mac="${macs[$i]:-52:54:00:21:00:ff}"
  netid="net$((i+1))"
  args+=(-netdev "tap,id=$netid,ifname=$tap,script=no,downscript=no,vhost=$vhost,queues=$NET_QUEUES")
  args+=(-device "virtio-net-pci,netdev=$netid,mac=$mac,mq=on,vectors=$vectors")
done

args+=(-serial "unix:$SERIAL_SOCK,server,nowait")
args+=(-monitor "unix:$MONITOR_SOCK,server,nowait")
args+=(-pidfile "$PID_FILE" -display none -nographic)

exec "$QEMU_BIN" "${args[@]}"
EOF_START
  chmod 0755 "$START_SCRIPT"

  cat > "$CONSOLE_CMD" <<'EOF_CONSOLE'
#!/usr/bin/env bash
CONFIG_FILE="/etc/routerosinstall/config.env"
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
SERIAL_SOCK="${SERIAL_SOCK:-/run/routeros/serial.sock}"
if [ ! -S "$SERIAL_SOCK" ]; then
  echo "RouterOS 串口未就绪: $SERIAL_SOCK" >&2
  echo "请先执行: systemctl start routeros-chr" >&2
  exit 1
fi
echo "进入 RouterOS 控制台。退出方式: 按 Ctrl+]。"
exec socat -,raw,echo=0,escape=0x1d "UNIX-CONNECT:$SERIAL_SOCK"
EOF_CONSOLE
  chmod 0755 "$CONSOLE_CMD"

  cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=RouterOS CHR virtual machine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=$HOSTNET_SCRIPT up
ExecStart=$START_SCRIPT
ExecStopPost=$HOSTNET_SCRIPT down
Restart=on-failure
RestartSec=3
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  if [ "${PERSIST_HOST_NET:-1}" = "1" ]; then
    write_persistent_network_files
  else
    remove_persistent_network_files
  fi

  systemctl daemon-reload 2>/dev/null || true
}

remove_persistent_network_files(){
  rm -f "$NETWORKD_PREFIX"-*.netdev "$NETWORKD_PREFIX"-*.network 2>/dev/null || true
  rm -f "$NM_UNMANAGED_CONF" 2>/dev/null || true
}

write_persistent_network_files(){
  local -a ifaces bridges
  local i iface br unmanaged
  read -r -a ifaces <<< "$VM_IFACES"
  read -r -a bridges <<< "$VM_BRIDGES"
  mkdir -p /etc/systemd/network

  rm -f "$NETWORKD_PREFIX"-*.netdev "$NETWORKD_PREFIX"-*.network 2>/dev/null || true

  unmanaged=""
  for i in "${!bridges[@]}"; do
    br="${bridges[$i]}"
    iface="${ifaces[$i]:-none}"
    cat > "$NETWORKD_PREFIX-$br.netdev" <<EOF_NETDEV
[NetDev]
Name=$br
Kind=bridge
EOF_NETDEV
    cat > "$NETWORKD_PREFIX-$br.network" <<EOF_BRNET
[Match]
Name=$br

[Network]
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF_BRNET
    if [ -n "$iface" ] && [ "$iface" != "none" ]; then
      cat > "$NETWORKD_PREFIX-$iface.network" <<EOF_PORTNET
[Match]
Name=$iface

[Network]
Bridge=$br
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF_PORTNET
      unmanaged="${unmanaged:+$unmanaged; }interface-name:$iface"
    fi
  done

  if [ -n "$unmanaged" ]; then
    mkdir -p /etc/NetworkManager/conf.d
    cat > "$NM_UNMANAGED_CONF" <<EOF_NM
[keyfile]
unmanaged-devices=$unmanaged
EOF_NM
  fi
}

menu_vm_config(){
  print_title
  load_config

  choose_image_from_root
  if [ ! -f "$IMAGE_PATH" ]; then
    warn "镜像路径当前不存在: $IMAGE_PATH"
  fi

  local detected_cpu default_cpu mem queues persist
  detected_cpu="$(nproc 2>/dev/null || echo 4)"
  default_cpu="$VM_CPUS"
  if [ -z "$default_cpu" ] || [ "$default_cpu" = "0" ]; then
    default_cpu="$detected_cpu"
  fi
  VM_CPUS="$(read_default "分配给 RouterOS 的 vCPU 数量，空闲时按需调度，不会固定占满" "$default_cpu")"
  VM_MEMORY_MB="$(read_default "分配内存 MB" "$VM_MEMORY_MB")"
  NET_QUEUES="$(read_default "virtio-net 队列数，建议 1-4" "$NET_QUEUES")"
  QEMU_BIN="$(read_default "QEMU 可执行文件" "$QEMU_BIN")"

  choose_host_ifaces

  persist="$(read_default "是否写入宿主机网口持久化接管配置 1=写入 0=只由服务运行时接管" "$PERSIST_HOST_NET")"
  case "$persist" in
    1|y|Y|yes|是) PERSIST_HOST_NET="1" ;;
    *) PERSIST_HOST_NET="0" ;;
  esac

  resize_disk_image
  save_config
  write_runtime_files

  printf '\n'
  ok "虚拟机参数已保存。"
  printf '%s\n' "镜像: $IMAGE_PATH ($DISK_FORMAT)"
  printf '%s\n' "CPU/内存: ${VM_CPUS} vCPU / ${VM_MEMORY_MB} MB"
  printf '%s\n' "宿主机网口: $VM_IFACES"
  printf '%s\n' "桥/tap: $VM_BRIDGES / $VM_TAPS"
  warn "如果选中的网口原来属于宿主机网络，启动 RouterOS 时会被接管，宿主机不再直接在这些网口上拿 IP。"
  pause
}

ip_to_int(){
  local IFS=. a b c d
  read -r a b c d <<< "$1"
  printf '%u' $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip(){
  local n="$1"
  printf '%u.%u.%u.%u' "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" "$(( (n >> 8) & 255 ))" "$(( n & 255 ))"
}

cidr_network(){
  local ip="$1" prefix="$2" ipn mask net
  ipn="$(ip_to_int "$ip")"
  if [ "$prefix" -eq 0 ]; then
    mask=0
  else
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  fi
  net=$(( ipn & mask ))
  int_to_ip "$net"
}

ros_quote(){
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

build_preset_rsc(){
  mkdir -p "$CONFIG_DIR"
  local network lan_cidr identity_q wan_q bridge_q lan_port_cmds port port_q
  network="$(cidr_network "$ROS_LAN_IP" "$ROS_LAN_PREFIX")"
  lan_cidr="$network/$ROS_LAN_PREFIX"
  identity_q="$(ros_quote "$ROS_IDENTITY")"
  wan_q="$(ros_quote "$ROS_WAN_IFACE")"
  bridge_q="$(ros_quote "$ROS_LAN_BRIDGE")"
  lan_port_cmds=""
  for port in $ROS_LAN_PORTS; do
    port_q="$(ros_quote "$port")"
    lan_port_cmds+=$(printf ':do { /interface bridge port add bridge=%s interface=%s comment="routerosinstall: LAN port" } on-error={}\n' "$bridge_q" "$port_q")
  done

  cat > "$PRESET_RSC" <<EOF_RSC
# Generated by routerosinstall at $(date -Is 2>/dev/null || date)

/system identity set name=$identity_q

:do { /interface ethernet set [find default-name=$ROS_WAN_IFACE] name=$wan_q comment="routerosinstall: WAN" } on-error={}
:do { /interface bridge add name=$bridge_q comment="routerosinstall: LAN bridge" protocol-mode=rstp } on-error={}
:do { /interface bridge set [find name=$bridge_q] comment="routerosinstall: LAN bridge" protocol-mode=rstp } on-error={}

$lan_port_cmds

/ip dhcp-client remove [find comment="routerosinstall: WAN DHCP"]
/ip dhcp-client add interface=$wan_q add-default-route=yes use-peer-dns=no disabled=no comment="routerosinstall: WAN DHCP"

/ip address remove [find comment="routerosinstall: LAN gateway"]
/ip address add address=$ROS_LAN_IP/$ROS_LAN_PREFIX interface=$bridge_q comment="routerosinstall: LAN gateway"

/ip pool remove [find name="pool-lan"]
/ip pool add name=pool-lan ranges=$ROS_DHCP_START-$ROS_DHCP_END

/ip dhcp-server remove [find name="dhcp-lan"]
/ip dhcp-server add name=dhcp-lan interface=$bridge_q address-pool=pool-lan lease-time=12h disabled=no
/ip dhcp-server network remove [find comment="routerosinstall: LAN DHCP network"]
/ip dhcp-server network add address=$lan_cidr gateway=$ROS_LAN_IP dns-server=$ROS_LAN_IP comment="routerosinstall: LAN DHCP network"

/ip dns set allow-remote-requests=yes servers=$ROS_DNS_SERVERS

/ip firewall nat remove [find comment~"routerosinstall:"]
/ip firewall nat add chain=srcnat out-interface=$wan_q action=masquerade comment="routerosinstall: NAT LAN to WAN"

/ip firewall filter remove [find comment~"routerosinstall:"]
/ip firewall filter add chain=input action=accept connection-state=established,related comment="routerosinstall: allow established input"
/ip firewall filter add chain=input action=drop connection-state=invalid comment="routerosinstall: drop invalid input"
/ip firewall filter add chain=input action=accept in-interface=$bridge_q comment="routerosinstall: allow LAN to router"
/ip firewall filter add chain=input action=accept protocol=icmp comment="routerosinstall: allow ping"
/ip firewall filter add chain=forward action=fasttrack-connection connection-state=established,related comment="routerosinstall: fasttrack established related"
/ip firewall filter add chain=forward action=accept connection-state=established,related comment="routerosinstall: accept established related"
/ip firewall filter add chain=forward action=drop connection-state=invalid comment="routerosinstall: drop invalid forward"
/ip firewall filter add chain=forward action=accept in-interface=$bridge_q out-interface=$wan_q comment="routerosinstall: allow LAN to WAN"

/ip service enable ssh
/ip service enable www
/ip service enable winbox
EOF_RSC
}

show_routeros_preset_values(){
  printf '%s\n' "当前 RouterOS 预设置:"
  printf '  %-18s %s\n' "identity" "$ROS_IDENTITY"
  printf '  %-18s %s\n' "WAN" "$ROS_WAN_IFACE DHCP"
  printf '  %-18s %s\n' "LAN bridge" "$ROS_LAN_BRIDGE"
  printf '  %-18s %s\n' "LAN ports" "${ROS_LAN_PORTS:-无}"
  printf '  %-18s %s/%s\n' "LAN IP" "$ROS_LAN_IP" "$ROS_LAN_PREFIX"
  printf '  %-18s %s-%s\n' "DHCP pool" "$ROS_DHCP_START" "$ROS_DHCP_END"
  printf '  %-18s %s\n' "DNS" "$ROS_DNS_SERVERS"
}

edit_routeros_preset(){
  show_routeros_preset_values
  printf '\n'
  ROS_IDENTITY="$(read_default "RouterOS identity" "$ROS_IDENTITY")"
  ROS_WAN_IFACE="$(read_default "WAN 口名称" "$ROS_WAN_IFACE")"
  ROS_LAN_BRIDGE="$(read_default "LAN bridge 名称" "$ROS_LAN_BRIDGE")"
  ROS_LAN_PORTS="$(read_default "LAN 口列表，用空格分隔" "$ROS_LAN_PORTS")"
  ROS_LAN_IP="$(read_default "LAN IP" "$ROS_LAN_IP")"
  ROS_LAN_PREFIX="$(read_default "LAN 掩码前缀" "$ROS_LAN_PREFIX")"
  ROS_DHCP_START="$(read_default "DHCP 起始地址" "$ROS_DHCP_START")"
  ROS_DHCP_END="$(read_default "DHCP 结束地址" "$ROS_DHCP_END")"
  ROS_DNS_SERVERS="$(read_default "RouterOS 上游 DNS，逗号分隔" "$ROS_DNS_SERVERS")"
  save_config
  build_preset_rsc
  ok "预设置已保存到 $PRESET_RSC"
}

apply_preset_ssh(){
  local target
  build_preset_rsc
  target="$(read_default "RouterOS SSH 地址" "$ROS_LAN_IP")"
  if ! has_cmd ssh; then
    err "缺少 ssh 客户端，请先执行菜单 1。"
    return 1
  fi
  warn "将通过 SSH 把预设置导入 RouterOS。如果 RouterOS 已有密码，请按提示输入。"
  ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=none,password,keyboard-interactive \
    -o ConnectTimeout=8 \
    "admin@$target" < "$PRESET_RSC"
}

apply_preset_serial(){
  build_preset_rsc
  if ! has_cmd socat; then
    err "缺少 socat，请先执行菜单 1。"
    return 1
  fi
  if [ ! -S "$SERIAL_SOCK" ]; then
    err "RouterOS 串口 socket 不存在: $SERIAL_SOCK"
    warn "请先在菜单 5 启动 RouterOS。"
    return 1
  fi
  warn "将尝试通过串口自动发送配置。若 RouterOS 首次登录要求设置密码，可能需要手动进入 routeros 控制台处理后再执行。"
  {
    sleep 1
    printf '\r'
    sleep 1
    printf 'admin\r'
    sleep 1
    printf '\r'
    sleep 2
    while IFS= read -r line; do
      printf '%s\r' "$line"
      sleep 0.05
    done < "$PRESET_RSC"
    sleep 1
    printf '\r/quit\r'
  } | socat -T 60 - "UNIX-CONNECT:$SERIAL_SOCK"
}

menu_routeros_preset(){
  load_config
  while true; do
    print_title
    show_routeros_preset_values
    printf '\n'
    printf '%s\n' "1. 修改预设置参数"
    printf '%s\n' "2. 生成/刷新 RouterOS .rsc 预设置脚本"
    printf '%s\n' "3. 通过 SSH 应用预设置"
    printf '%s\n' "4. 通过串口 socket 尝试应用预设置"
    printf '%s\n' "5. 查看预设置脚本"
    printf '%s\n' "0. 返回主菜单"
    printf '%s' "请选择: "
    local choice
    IFS= read -r choice || true
    case "$choice" in
      1) edit_routeros_preset; pause ;;
      2) build_preset_rsc; ok "已生成 $PRESET_RSC"; pause ;;
      3) apply_preset_ssh; pause ;;
      4) apply_preset_serial; pause ;;
      5) build_preset_rsc; sed -n '1,220p' "$PRESET_RSC"; pause ;;
      0) return ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

service_status(){
  if [ -f "$SERVICE_FILE" ]; then
    systemctl --no-pager --full status routeros-chr.service 2>/dev/null | sed -n '1,18p' || true
  else
    warn "routeros-chr.service 尚未生成，请先执行菜单 3。"
  fi
}

uninstall_vm_service(){
  warn "这会停止并删除 RouterOS systemd 服务、hostnet/start 脚本和 routeros 控制台命令。"
  if confirm "是否保留镜像和 $CONFIG_DIR 配置文件" "y"; then
    systemctl stop routeros-chr.service 2>/dev/null || true
    systemctl disable routeros-chr.service 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$CONSOLE_CMD"
    rm -rf "$LIB_DIR"
    systemctl daemon-reload 2>/dev/null || true
    ok "虚拟机服务已卸载，镜像和配置已保留。"
  else
    systemctl stop routeros-chr.service 2>/dev/null || true
    systemctl disable routeros-chr.service 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$CONSOLE_CMD" "$NM_UNMANAGED_CONF"
    rm -f "$NETWORKD_PREFIX"-*.netdev "$NETWORKD_PREFIX"-*.network 2>/dev/null || true
    rm -rf "$LIB_DIR" "$CONFIG_DIR"
    systemctl daemon-reload 2>/dev/null || true
    ok "虚拟机服务与配置已卸载。镜像文件不会自动删除，请手动确认后处理。"
  fi
}

menu_service_manage(){
  load_config
  while true; do
    print_title
    service_status
    printf '\n'
    printf '%s\n' "1. 启动 RouterOS"
    printf '%s\n' "2. 关闭 RouterOS"
    printf '%s\n' "3. 重启 RouterOS"
    printf '%s\n' "4. 设置开机自启动"
    printf '%s\n' "5. 取消开机自启动"
    printf '%s\n' "6. 进入 RouterOS 控制台"
    printf '%s\n' "7. 卸载 RouterOS 虚拟机服务"
    printf '%s\n' "0. 返回主菜单"
    printf '%s' "请选择: "
    local choice
    IFS= read -r choice || true
    case "$choice" in
      1)
        write_runtime_files
        systemctl start routeros-chr.service
        ok "RouterOS 已启动。"
        info "在命令行输入 routeros 可进入 RouterOS 控制台。"
        info "在 RouterOS 控制台中按 Ctrl+] 可退出控制台。"
        pause
        ;;
      2) systemctl stop routeros-chr.service; ok "RouterOS 已关闭。"; pause ;;
      3) write_runtime_files; systemctl restart routeros-chr.service; ok "RouterOS 已重启。"; pause ;;
      4) write_runtime_files; systemctl enable routeros-chr.service; ok "已设置开机自启动。"; pause ;;
      5) systemctl disable routeros-chr.service; ok "已取消开机自启动。"; pause ;;
      6)
        [ -x "$CONSOLE_CMD" ] || write_runtime_files
        "$CONSOLE_CMD"
        pause
        ;;
      7) uninstall_vm_service; pause ;;
      0) return ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

uninstall_installer(){
  warn "这只会卸载 routerosinstall 菜单命令本身。RouterOS 虚拟机服务请在菜单 5 中卸载。"
  if confirm "确认删除 $INSTALL_CMD" "n"; then
    rm -f "$INSTALL_CMD"
    ok "routerosinstall 命令已删除。"
    exit 0
  fi
}

menu_exit_or_uninstall(){
  while true; do
    print_title
    printf '%s\n' "1. 退出脚本"
    printf '%s\n' "2. 卸载 routerosinstall 命令"
    printf '%s\n' "0. 返回主菜单"
    printf '%s' "请选择: "
    local choice
    IFS= read -r choice || true
    case "$choice" in
      1) exit 0 ;;
      2) uninstall_installer ;;
      0) return ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

main_menu(){
  need_root
  load_config
  while true; do
    print_title
    printf '%s\n' "1. 依赖安装"
    printf '%s\n' "2. 网络检查"
    printf '%s\n' "3. 虚拟机参数配置"
    printf '%s\n' "4. RouterOS 预设置"
    printf '%s\n' "5. RouterOS 启动/关闭/卸载/开机自启动设置"
    printf '%s\n' "6. 退出脚本/卸载脚本"
    printf '\n%s' "请选择: "
    local choice
    IFS= read -r choice || true
    case "$choice" in
      1) menu_dependencies ;;
      2) menu_network_check ;;
      3) menu_vm_config ;;
      4) menu_routeros_preset ;;
      5) menu_service_manage ;;
      6) menu_exit_or_uninstall ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  printf '%s\n' "用法:"
  printf '  %s\n' "sudo bash 9.sh            安装 routerosinstall 命令"
  printf '  %s\n' "sudo routerosinstall       打开 RouterOS CHR 安装管理菜单"
  printf '  %s\n' "routeros                   进入 RouterOS 串口控制台"
  exit 0
fi

if [ "${1:-}" = "--run" ]; then
  main_menu
  exit 0
fi

if [ "$(basename "$0")" != "routerosinstall" ]; then
  bootstrap_install
  exit 0
fi

main_menu
