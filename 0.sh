#!/usr/bin/env bash
set -uo pipefail

VERSION="2026-05-20-中文网络管理器-r2"
BASE_DIR="/etc/easepi-r2-script"
CONFIG_FILE="$BASE_DIR/网络配置.env"
BACKUP_DIR="$BASE_DIR/备份"
NETWORK_DIR="/etc/systemd/network"
DNSMASQ_CONF="/etc/dnsmasq.d/easepi-r2-router.conf"
NFT_MAIN_CONF="/etc/nftables.conf"
NFT_DIR="/etc/nftables.d"
NFT_CONF="$NFT_DIR/easepi-r2-nat.nft"
NFT_TABLE="easepi_r2_nat"
SYSCTL_CONF="/etc/sysctl.d/99-easepi-r2-router.conf"
RESOLVED_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_CONF="$RESOLVED_DIR/easepi-r2-dns.conf"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
HOSTAPD_DEFAULT="/etc/default/hostapd"
WPA_DIR="/etc/wpa_supplicant"
LTE_POLICY_SCRIPT="/usr/local/sbin/easepi-r2-lte4g-policy-route.sh"
LTE_POLICY_SERVICE="/etc/systemd/system/easepi-r2-lte4g-policy-route.service"
LTE_POLICY_TIMER="/etc/systemd/system/easepi-r2-lte4g-policy-route.timer"
LTE_MANAGER_SCRIPT="/usr/local/sbin/easepi-r2-lte4g-manager.sh"
LTE_MANAGER_SERVICE="/etc/systemd/system/easepi-r2-lte4g-manager.service"
LTE_MANAGER_TIMER="/etc/systemd/system/easepi-r2-lte4g-manager.timer"
IPV6_DDNS_CONF="$BASE_DIR/ipv6-ddns.env"
IPV6_DDNS_SCRIPT="/usr/local/sbin/easepi-r2-ipv6-ddns.sh"
IPV6_DDNS_SERVICE="/etc/systemd/system/easepi-r2-ipv6-ddns.service"
IPV6_DDNS_TIMER="/etc/systemd/system/easepi-r2-ipv6-ddns.timer"
LTE_POLICY_TABLE="${LTE_POLICY_TABLE:-1004}"
LTE_POLICY_PRIO="${LTE_POLICY_PRIO:-1004}"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
RESET=$'\033[0m'

ok(){ printf '%s\n' "${GREEN}[完成]${RESET} $*"; }
info(){ printf '%s\n' "${BLUE}[信息]${RESET} $*"; }
warn(){ printf '%s\n' "${YELLOW}[提示]${RESET} $*"; }
err(){ printf '%s\n' "${RED}[错误]${RESET} $*"; }
pause(){ read -r -p "按回车继续..." _; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { err "请用 root 执行：sudo bash 0.sh"; exit 1; }; }

read_default(){
  local prompt="$1" def="${2:-}" val
  read -r -p "$prompt [$def]: " val
  printf '%s' "${val:-$def}"
}

confirm(){
  local prompt="$1" def="${2:-y}" val hint
  [ "$def" = y ] && hint="Y/n，回车或空格=Y" || hint="y/N，回车或空格=N"
  read -r -p "$prompt [$hint]: " val
  val="$(trim "$val")"
  val="${val:-$def}"
  case "${val,,}" in
    y|yes|是|好|确认|ok) return 0 ;;
    *) return 1 ;;
  esac
}

trim(){
  local v="$*"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

quote_sq(){
  local s="${1//\'/\'\\\'\'}"
  printf '%s' "$s"
}

cidr_ip(){ echo "${1%/*}"; }
cidr_prefix(){ [ "$1" = "${1#*/}" ] && echo 24 || echo "${1#*/}"; }
prefix3(){ echo "$1" | awk -F. '{print $1"."$2"."$3}'; }

wan_has_iface(){
  local target="$1"
  echo "$WAN_CONFIG" | awk -F'|' -v i="$target" '$1==i && $2!="disabled"{found=1} END{exit !found}'
}

remove_wan_iface(){
  local target="$1"
  WAN_CONFIG="$(echo "$WAN_CONFIG" | awk -F'|' -v i="$target" 'BEGIN{OFS="|"} $1!="" && $1!=i {print}')"
}

remove_lan_iface(){
  local target="$1" word result=""
  for word in $LAN_IFACES; do
    [ "$word" = "$target" ] && continue
    result="${result:+$result }$word"
  done
  LAN_IFACES="$result"
}

prefix_to_mask(){
  local prefix="${1:-24}" out="" full rem i val
  full=$((prefix/8))
  rem=$((prefix%8))
  for i in 0 1 2 3; do
    if [ "$i" -lt "$full" ]; then
      val=255
    elif [ "$i" -eq "$full" ] && [ "$rem" -ne 0 ]; then
      val=$((256 - 2 ** (8 - rem)))
    else
      val=0
    fi
    out="${out:+$out.}$val"
  done
  echo "$out"
}

physical_ifaces(){
  local p ifname type
  for p in /sys/class/net/*; do
    [ -e "$p" ] || continue
    ifname="${p##*/}"
    [ "$ifname" = lo ] && continue
    case "$ifname" in br-*|docker*|veth*|virbr*|tun*|tap*|wg*|ifb*) continue;; esac
    type="$(cat "$p/type" 2>/dev/null || echo 0)"
    [ "$type" = 1 ] || continue
    echo "$ifname"
  done
}

wifi_ifaces(){
  if has_cmd iw; then
    iw dev 2>/dev/null | awk '/Interface/ {print $2}'
  else
    local p
    for p in /sys/class/net/*/wireless; do
      [ -e "$p" ] || continue
      basename "$(dirname "$p")"
    done
  fi
}

init_defaults(){
  WAN_CONFIG="${WAN_CONFIG:-eth0|dhcp|100|||223.5.5.5 119.29.29.29}"
  LAN_IFACES="${LAN_IFACES:-eth1 eth2 eth3}"
  LAN_CIDR="${LAN_CIDR:-10.10.0.1/24}"
  LAN_IP="${LAN_IP:-$(cidr_ip "$LAN_CIDR")}"
  DHCP_START="${DHCP_START:-10.10.0.100}"
  DHCP_END="${DHCP_END:-10.10.0.200}"
  DHCP_MASK="${DHCP_MASK:-$(prefix_to_mask "$(cidr_prefix "$LAN_CIDR")")}"
  DEVICE_DNS="${DEVICE_DNS:-223.5.5.5 119.29.29.29}"
  UPSTREAM_DNS="${UPSTREAM_DNS:-$DEVICE_DNS}"
  LAN_DNS="${LAN_DNS:-$LAN_IP}"
  NAT_OUT="${NAT_OUT:-eth0}"
  LTE4G_METRIC="${LTE4G_METRIC:-30000}"
  WLAN_IFACE="${WLAN_IFACE:-wlan0}"
  WLAN_METRIC="${WLAN_METRIC:-800}"
  WLAN_MODE="${WLAN_MODE:-未配置}"
}

load_config(){
  mkdir -p "$BASE_DIR" "$BACKUP_DIR"
  if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  init_defaults
}

save_config(){
  mkdir -p "$BASE_DIR"
  cat > "$CONFIG_FILE" <<EOF_CONF
WAN_CONFIG='$(quote_sq "$WAN_CONFIG")'
LAN_IFACES='$(quote_sq "$LAN_IFACES")'
LAN_CIDR='$(quote_sq "$LAN_CIDR")'
LAN_IP='$(quote_sq "$LAN_IP")'
DHCP_START='$(quote_sq "$DHCP_START")'
DHCP_END='$(quote_sq "$DHCP_END")'
DHCP_MASK='$(quote_sq "$DHCP_MASK")'
DEVICE_DNS='$(quote_sq "$DEVICE_DNS")'
UPSTREAM_DNS='$(quote_sq "$UPSTREAM_DNS")'
LAN_DNS='$(quote_sq "$LAN_DNS")'
NAT_OUT='$(quote_sq "$NAT_OUT")'
LTE4G_METRIC='$(quote_sq "$LTE4G_METRIC")'
WLAN_IFACE='$(quote_sq "$WLAN_IFACE")'
WLAN_METRIC='$(quote_sq "$WLAN_METRIC")'
WLAN_MODE='$(quote_sq "$WLAN_MODE")'
EOF_CONF
}

install_packages(){
  local -a packages missing
  local p
  packages=("$@")
  missing=()
  for p in "${packages[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  info "准备安装依赖：${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "${missing[@]}"
}

detect_system(){
  OS_ID=""
  OS_ID_LIKE=""
  OS_FAMILY=""
  OS_NAME=""
  OS_CODENAME=""
  OS_VERSION=""
  APT_ARCH=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_ID="${OS_ID,,}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    OS_VERSION="${VERSION_ID:-}"
  fi
  if [ -z "$OS_CODENAME" ] && [ -r /etc/armbian-release ]; then
    OS_CODENAME="$(awk -F= '/^(DISTRIBUTION_CODENAME|DEBIAN_CODENAME|VERSION_CODENAME)=/ {gsub(/"/,"",$2); print $2; exit}' /etc/armbian-release 2>/dev/null || true)"
  fi
  if [ -z "$OS_CODENAME" ] && has_cmd lsb_release; then
    OS_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
  fi
  case "$OS_ID" in
    ubuntu)
      OS_FAMILY="ubuntu"
      ;;
    debian|raspbian|armbian)
      OS_FAMILY="debian"
      ;;
    *)
      case " $OS_ID_LIKE " in
        *" ubuntu "*) OS_FAMILY="ubuntu" ;;
        *" debian "*) OS_FAMILY="debian" ;;
      esac
      ;;
  esac
  if [ -z "$OS_FAMILY" ] && [ -r /etc/debian_version ]; then
    OS_FAMILY="debian"
  fi
  if [ -z "$OS_CODENAME" ] && [ -n "$OS_FAMILY" ]; then
    OS_CODENAME="$(codename_from_version "$OS_FAMILY" "$OS_VERSION")"
  fi
  if [ -z "$OS_CODENAME" ] && [ "$OS_FAMILY" = "debian" ] && [ -r /etc/debian_version ]; then
    OS_CODENAME="$(codename_from_version debian "$(cat /etc/debian_version 2>/dev/null)")"
  fi
  APT_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m 2>/dev/null || echo unknown)"
}

codename_from_version(){
  local family="$1" version="${2%%/*}" major
  version="${version%%-*}"
  major="${version%%.*}"
  case "$family:$version" in
    ubuntu:24.10) echo "oracular"; return ;;
    ubuntu:24.04*) echo "noble"; return ;;
    ubuntu:22.04*) echo "jammy"; return ;;
    ubuntu:20.04*) echo "focal"; return ;;
    ubuntu:18.04*) echo "bionic"; return ;;
    ubuntu:16.04*) echo "xenial"; return ;;
  esac
  case "$family:$major" in
    debian:13) echo "trixie" ;;
    debian:12) echo "bookworm" ;;
    debian:11) echo "bullseye" ;;
    debian:10) echo "buster" ;;
    debian:9) echo "stretch" ;;
  esac
}

ubuntu_mirror_path(){
  case "${APT_ARCH:-}" in
    amd64|i386) echo "ubuntu" ;;
    *) echo "ubuntu-ports" ;;
  esac
}

debian_components(){
  case "${OS_CODENAME:-}" in
    bookworm|trixie|forky|sid|unstable|testing)
      echo "main contrib non-free non-free-firmware"
      ;;
    *)
      echo "main contrib non-free"
      ;;
  esac
}

debian_security_suite(){
  case "${OS_CODENAME:-}" in
    sid|unstable|testing)
      echo ""
      ;;
    buster|stretch)
      echo "$OS_CODENAME/updates"
      ;;
    *)
      echo "$OS_CODENAME-security"
      ;;
  esac
}

mirror_list(){
  local ubuntu_path
  case "$OS_FAMILY" in
    ubuntu)
      ubuntu_path="$(ubuntu_mirror_path)"
      cat <<EOF_MIRROR
阿里云|https://mirrors.aliyun.com/$ubuntu_path/
清华大学|https://mirrors.tuna.tsinghua.edu.cn/$ubuntu_path/
中国科学技术大学|https://mirrors.ustc.edu.cn/$ubuntu_path/
北京外国语大学|https://mirrors.bfsu.edu.cn/$ubuntu_path/
南京大学|https://mirror.nju.edu.cn/$ubuntu_path/
上海交通大学|https://mirror.sjtu.edu.cn/$ubuntu_path/
腾讯云|https://mirrors.cloud.tencent.com/$ubuntu_path/
华为云|https://repo.huaweicloud.com/$ubuntu_path/
EOF_MIRROR
      ;;
    debian)
      cat <<'EOF_MIRROR'
阿里云|https://mirrors.aliyun.com
清华大学|https://mirrors.tuna.tsinghua.edu.cn
中国科学技术大学|https://mirrors.ustc.edu.cn
北京外国语大学|https://mirrors.bfsu.edu.cn
南京大学|https://mirror.nju.edu.cn
上海交通大学|https://mirror.sjtu.edu.cn
腾讯云|https://mirrors.cloud.tencent.com
华为云|https://repo.huaweicloud.com
EOF_MIRROR
      ;;
  esac
}

probe_mirror(){
  local url="$1" test_url start end
  [ -n "$OS_CODENAME" ] || { echo 999999; return; }
  if [ "$OS_FAMILY" = ubuntu ]; then
    test_url="${url%/}/dists/$OS_CODENAME/Release"
  else
    test_url="${url%/}/debian/dists/$OS_CODENAME/Release"
  fi
  start="$(date +%s%3N 2>/dev/null || date +%s000)"
  if has_cmd curl && curl -fsIL --connect-timeout 3 --max-time 6 "$test_url" >/dev/null 2>&1; then
    end="$(date +%s%3N 2>/dev/null || date +%s000)"
    echo $((end-start))
  elif has_cmd wget && wget -q --spider --timeout=6 --tries=1 "$test_url" >/dev/null 2>&1; then
    end="$(date +%s%3N 2>/dev/null || date +%s000)"
    echo $((end-start))
  else
    echo 999999
  fi
}

mirror_root(){
  local url="${1%/}"
  case "$url" in
    */ubuntu) echo "${url%/ubuntu}" ;;
    */ubuntu-ports) echo "${url%/ubuntu-ports}" ;;
    *) echo "$url" ;;
  esac
}

armbian_mirror_url(){
  local base candidate
  base="$(mirror_root "$1")"
  for candidate in "$base/armbian" "$base/armbian/apt"; do
    if has_cmd curl && [ -n "$OS_CODENAME" ] && curl -fsIL --connect-timeout 3 --max-time 6 "$candidate/dists/$OS_CODENAME/Release" >/dev/null 2>&1; then
      echo "$candidate"
      return
    fi
  done
  echo "$base/armbian"
}

rewrite_armbian_source_file(){
  local file="$1" armbian_url="$2" tmp
  grep -qiE 'apt\.armbian\.com|/armbian(/|$)|armbian\.com/apt' "$file" 2>/dev/null || return 1
  tmp="$(mktemp)"
  case "$file" in
    *.sources)
      awk -v u="$armbian_url" '
        BEGIN{IGNORECASE=1}
        { lines[NR]=$0; if ($0 ~ /apt\.armbian\.com|\/armbian(\/|$)|armbian\.com\/apt/) hit=1 }
        END{
          for (i=1; i<=NR; i++) {
            if (hit && lines[i] ~ /^URIs:/) sub(/https?:\/\/[^[:space:]]+/, u, lines[i])
            print lines[i]
          }
        }
      ' "$file" > "$tmp"
      ;;
    *)
      awk -v u="$armbian_url" '
        BEGIN{IGNORECASE=1}
        /^deb[[:space:]]/ && $0 ~ /apt\.armbian\.com|\/armbian(\/|$)|armbian\.com\/apt/ {
          sub(/https?:\/\/[^[:space:]]+/, u)
        }
        {print}
      ' "$file" > "$tmp"
      ;;
  esac
  cat "$tmp" > "$file"
  rm -f "$tmp"
  return 0
}

is_armbian_source_file(){
  grep -qiE 'apt\.armbian\.com|/armbian(/|$)|armbian\.com/apt' "$1" 2>/dev/null
}

is_stock_apt_source_file(){
  grep -qiE 'deb\.debian\.org|security\.debian\.org|ftp\.[^[:space:]/]*debian\.org|archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|old-releases\.ubuntu\.com|cn\.archive\.ubuntu\.com' "$1" 2>/dev/null
}

disable_stock_apt_source_files(){
  local ts="$1" file disabled
  [ -d /etc/apt/sources.list.d ] || return 0
  while IFS= read -r -d '' file; do
    is_armbian_source_file "$file" && continue
    if is_stock_apt_source_file "$file"; then
      disabled="$file.disabled-by-easepi-$ts"
      mv -f "$file" "$disabled"
      warn "已停用系统默认源文件：$file -> ${disabled##*/}"
    fi
  done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null)
}

write_apt_sources(){
  local name="$1" url="$2" ts armbian_url file found_armbian key_opt components security_suite
  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BASE_DIR/apt备份"
  cp -a /etc/apt/sources.list "$BASE_DIR/apt备份/sources.list.$ts" 2>/dev/null || true
  if [ -d /etc/apt/sources.list.d ]; then
    cp -a /etc/apt/sources.list.d "$BASE_DIR/apt备份/sources.list.d.$ts" 2>/dev/null || true
  fi
  disable_stock_apt_source_files "$ts"
  armbian_url="$(armbian_mirror_url "$url")"
  if [ "$OS_FAMILY" = ubuntu ]; then
    cat > /etc/apt/sources.list <<EOF_APT
deb ${url%/}/ $OS_CODENAME main restricted universe multiverse
deb ${url%/}/ $OS_CODENAME-updates main restricted universe multiverse
deb ${url%/}/ $OS_CODENAME-backports main restricted universe multiverse
deb ${url%/}/ $OS_CODENAME-security main restricted universe multiverse
EOF_APT
  else
    components="$(debian_components)"
    security_suite="$(debian_security_suite)"
    cat > /etc/apt/sources.list <<EOF_APT
deb ${url%/}/debian/ $OS_CODENAME $components
EOF_APT
    if [ -n "$security_suite" ]; then
      cat >> /etc/apt/sources.list <<EOF_APT
deb ${url%/}/debian/ $OS_CODENAME-updates $components
deb ${url%/}/debian-security/ $security_suite $components
EOF_APT
    fi
  fi
  found_armbian=0
  if [ -d /etc/apt/sources.list.d ]; then
    while IFS= read -r -d '' file; do
      if rewrite_armbian_source_file "$file" "$armbian_url"; then
        found_armbian=1
      fi
    done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null)
  fi
  if [ "$found_armbian" -eq 0 ] && [ -r /etc/armbian-release ]; then
    mkdir -p /etc/apt/sources.list.d
    key_opt=""
    [ -r /usr/share/keyrings/armbian.gpg ] && key_opt=" [signed-by=/usr/share/keyrings/armbian.gpg]"
    cat > /etc/apt/sources.list.d/armbian.list <<EOF_ARMBIAN
deb${key_opt} ${armbian_url%/}/ $OS_CODENAME main ${OS_CODENAME}-utils
EOF_ARMBIAN
    found_armbian=1
    warn "没有找到现有 Armbian 源，已按常见格式创建 /etc/apt/sources.list.d/armbian.list。"
  fi
  ok "APT 源已切换为：$name"
  [ "$found_armbian" -eq 1 ] && ok "Armbian 源已切换为：$armbian_url"
  info "原配置已备份到：$BASE_DIR/apt备份"
}

apt_process_running(){
  pgrep -x apt >/dev/null 2>&1 ||
    pgrep -x apt-get >/dev/null 2>&1 ||
    pgrep -x aptitude >/dev/null 2>&1 ||
    pgrep -x dpkg >/dev/null 2>&1
}

cleanup_apt_after_failure(){
  warn "APT 更新失败，正在清理索引缓存、partial 目录和过期锁文件。"
  apt-get clean >/dev/null 2>&1 || true
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/partial/* 2>/dev/null || true
  mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial
  if apt_process_running; then
    warn "检测到 apt/dpkg 进程仍在运行，已跳过锁文件清理。"
  else
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend 2>/dev/null || true
  fi
}

run_apt_update_checked(){
  info "正在执行 apt update..."
  DEBIAN_FRONTEND=noninteractive apt-get update \
    -o Acquire::Retries=2 \
    -o Acquire::http::Timeout=15 \
    -o Acquire::https::Timeout=15
}

configure_apt_mirror(){
  need_root
  detect_system
  echo
  info "当前系统：${OS_NAME:-未知}"
  info "APT 类型：${OS_FAMILY:-未知}"
  info "发行代号：${OS_CODENAME:-未知}"
  info "软件架构：${APT_ARCH:-未知}"
  if [ -z "$OS_FAMILY" ]; then
    err "暂不支持当前系统的自动 APT 换源。"
    pause
    return
  fi
  if [ -z "$OS_CODENAME" ]; then
    err "无法识别发行代号，暂不自动改源。"
    pause
    return
  fi

  local name url latency choice best_idx=1 best_latency=999999 idx i
  local -a names urls latencies
  while true; do
    names=()
    urls=()
    latencies=()
    best_idx=1
    best_latency=999999
    idx=0
    echo
    info "正在评估国内镜像，不能联网时会按默认优先级选择。"
    while IFS='|' read -r name url; do
      [ -n "$name" ] || continue
      idx=$((idx+1))
      latency="$(probe_mirror "$url")"
      names+=("$name")
      urls+=("$url")
      latencies+=("$latency")
      if [ "$latency" -lt "$best_latency" ]; then
        best_latency="$latency"
        best_idx="$idx"
      fi
    done < <(mirror_list)
    if [ "${#names[@]}" -eq 0 ]; then
      err "没有匹配当前系统类型的镜像列表。"
      pause
      return 1
    fi
    [ "$best_latency" -eq 999999 ] && best_idx=1

    echo
    echo "可选国内加速源："
    for i in "${!names[@]}"; do
      idx=$((i+1))
      if [ "${latencies[$i]}" -eq 999999 ]; then
        printf '  %d. %s  %s\n' "$idx" "${names[$i]}" "${urls[$i]}"
      else
        printf '  %d. %s  %sms  %s\n' "$idx" "${names[$i]}" "${latencies[$i]}" "${urls[$i]}"
      fi
    done
    echo "  0. 返回/停止重试"
    echo
    read -r -p "请选择数字，直接回车或输入空格使用最优源 [$best_idx]: " choice
    choice="$(trim "$choice")"
    [ -z "$choice" ] && choice="$best_idx"
    if [ "$choice" = "0" ]; then
      warn "已停止 APT 换源流程；当前配置保持不变或保留最后一次写入的源。"
      pause
      return
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#names[@]}" ]; then
      warn "选择无效，使用最优源 $best_idx。"
      choice="$best_idx"
    fi
    write_apt_sources "${names[$((choice-1))]}" "${urls[$((choice-1))]}"
    if ! confirm "是否立即执行 apt update？" y; then
      pause
      return
    fi
    if run_apt_update_checked; then
      ok "apt update 成功。"
      pause
      return
    fi
    err "apt update 失败。"
    cleanup_apt_after_failure
    if confirm "是否重新选择一个国内源并重试？" y; then
      continue
    fi
    warn "已保留当前 APT 配置；你可以稍后重新进入本菜单换源。"
    pause
    return 1
  done
}

configure_ssh_root(){
  need_root
  install_packages openssh-server
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-easepi-r2-root-login.conf <<'EOF_SSH'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF_SSH
  if passwd -S root 2>/dev/null | awk '{exit !($2=="L" || $2=="LK" || $2=="NP") }'; then
    warn "root 账号可能未设置可用密码。"
    if confirm "是否现在设置 root 密码？" y; then
      passwd root
    fi
  else
    if confirm "是否修改 root 密码？" n; then
      passwd root
    fi
  fi
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "SSH root 密码登录已开启。"
  pause
}

backup_now(){
  local reason="${1:-手动}" ts target
  mkdir -p "$BACKUP_DIR"
  ts="$(date +%Y%m%d-%H%M%S)"
  target="$BACKUP_DIR/$ts-$reason"
  mkdir -p "$target"
  mkdir -p "$target/easepi-r2-script"
  cp -a "$CONFIG_FILE" "$target/easepi-r2-script/网络配置.env" 2>/dev/null || true
  cp -a "$NETWORK_DIR" "$target/systemd-network" 2>/dev/null || true
  cp -a /etc/dnsmasq.d "$target/dnsmasq.d" 2>/dev/null || true
  cp -a "$NFT_MAIN_CONF" "$target/nftables.conf" 2>/dev/null || true
  mkdir -p "$target/nftables.d"
  cp -a "$NFT_CONF" "$target/nftables.d/easepi-r2-nat.nft" 2>/dev/null || true
  cp -a "$SYSCTL_CONF" "$target/ip-forward.conf" 2>/dev/null || true
  cp -a /etc/ssh/sshd_config "$target/sshd_config" 2>/dev/null || true
  cp -a /etc/ssh/sshd_config.d "$target/sshd_config.d" 2>/dev/null || true
  cp -a "$RESOLVED_DIR" "$target/resolved.conf.d" 2>/dev/null || true
  cp -a /etc/resolv.conf "$target/resolv.conf" 2>/dev/null || true
  cp -a /etc/hostapd "$target/hostapd" 2>/dev/null || true
  cp -a "$HOSTAPD_DEFAULT" "$target/hostapd.default" 2>/dev/null || true
  cp -a "$WPA_DIR" "$target/wpa_supplicant" 2>/dev/null || true
  cp -a "$LTE_POLICY_SCRIPT" "$target/lte4g-policy-route.sh" 2>/dev/null || true
  cp -a "$LTE_POLICY_SERVICE" "$target/lte4g-policy-route.service" 2>/dev/null || true
  cp -a "$LTE_POLICY_TIMER" "$target/lte4g-policy-route.timer" 2>/dev/null || true
  cp -a "$LTE_MANAGER_SCRIPT" "$target/lte4g-manager.sh" 2>/dev/null || true
  cp -a "$LTE_MANAGER_SERVICE" "$target/lte4g-manager.service" 2>/dev/null || true
  cp -a "$LTE_MANAGER_TIMER" "$target/lte4g-manager.timer" 2>/dev/null || true
  cp -a "$IPV6_DDNS_CONF" "$target/ipv6-ddns.env" 2>/dev/null || true
  cp -a "$IPV6_DDNS_SCRIPT" "$target/ipv6-ddns.sh" 2>/dev/null || true
  cp -a "$IPV6_DDNS_SERVICE" "$target/ipv6-ddns.service" 2>/dev/null || true
  cp -a "$IPV6_DDNS_TIMER" "$target/ipv6-ddns.timer" 2>/dev/null || true
  ls -1dt "$BACKUP_DIR"/* 2>/dev/null | tail -n +6 | xargs -r rm -rf
  echo "$target"
}

restore_backup(){
  need_root
  local num target
  echo "可用备份："
  ls -1dt "$BACKUP_DIR"/* 2>/dev/null | head -5 | nl -w2 -s'. ' || true
  read -r -p "输入要恢复的序号：" num
  target="$(ls -1dt "$BACKUP_DIR"/* 2>/dev/null | sed -n "${num}p")"
  [ -n "$target" ] || { err "无效序号"; pause; return; }
  confirm "确认恢复 $target？" n || return
  mkdir -p "$NETWORK_DIR"
  clean_networkd_files
  find "$target/systemd-network" -maxdepth 1 -type f \( -name '20-r2-*' -o -name '2[0-9]-r2-*' -o -name '3[0-9]-r2-*' -o -name '4[0-9]-r2-*' \) -exec cp -a -t "$NETWORK_DIR" {} + 2>/dev/null || true
  mkdir -p /etc/dnsmasq.d
  cp -a "$target/dnsmasq.d/easepi-r2-router.conf" "$DNSMASQ_CONF" 2>/dev/null || true
  mkdir -p "$NFT_DIR"
  cp -a "$target/nftables.d/easepi-r2-nat.nft" "$NFT_CONF" 2>/dev/null || true
  cp -a "$target/ip-forward.conf" "$SYSCTL_CONF" 2>/dev/null || true
  mkdir -p /etc/ssh/sshd_config.d
  cp -a "$target/sshd_config.d/99-easepi-r2-root-login.conf" /etc/ssh/sshd_config.d/99-easepi-r2-root-login.conf 2>/dev/null || true
  mkdir -p "$RESOLVED_DIR"
  cp -a "$target/resolved.conf.d/easepi-r2-dns.conf" "$RESOLVED_CONF" 2>/dev/null || true
  mkdir -p /etc/hostapd /etc/default
  cp -a "$target/hostapd/hostapd.conf" "$HOSTAPD_CONF" 2>/dev/null || true
  cp -a "$target/hostapd.default" "$HOSTAPD_DEFAULT" 2>/dev/null || true
  mkdir -p "$WPA_DIR"
  find "$target/wpa_supplicant" -maxdepth 1 -type f -name 'wpa_supplicant-*.conf' -exec cp -a -t "$WPA_DIR" {} + 2>/dev/null || true
  cp -a "$target/lte4g-policy-route.sh" "$LTE_POLICY_SCRIPT" 2>/dev/null || true
  cp -a "$target/lte4g-policy-route.service" "$LTE_POLICY_SERVICE" 2>/dev/null || true
  cp -a "$target/lte4g-policy-route.timer" "$LTE_POLICY_TIMER" 2>/dev/null || true
  cp -a "$target/lte4g-manager.sh" "$LTE_MANAGER_SCRIPT" 2>/dev/null || true
  cp -a "$target/lte4g-manager.service" "$LTE_MANAGER_SERVICE" 2>/dev/null || true
  cp -a "$target/lte4g-manager.timer" "$LTE_MANAGER_TIMER" 2>/dev/null || true
  cp -a "$target/ipv6-ddns.env" "$IPV6_DDNS_CONF" 2>/dev/null || true
  cp -a "$target/ipv6-ddns.sh" "$IPV6_DDNS_SCRIPT" 2>/dev/null || true
  cp -a "$target/ipv6-ddns.service" "$IPV6_DDNS_SERVICE" 2>/dev/null || true
  cp -a "$target/ipv6-ddns.timer" "$IPV6_DDNS_TIMER" 2>/dev/null || true
  if [ -r "$target/easepi-r2-script/网络配置.env" ]; then
    mkdir -p "$BASE_DIR"
    cp -a "$target/easepi-r2-script/网络配置.env" "$CONFIG_FILE"
  fi
  ok "已恢复备份。"
  reload_services
  pause
}

clean_networkd_files(){
  mkdir -p "$NETWORK_DIR"
  rm -f "$NETWORK_DIR"/20-r2-*.netdev "$NETWORK_DIR"/2[0-9]-r2-*.network
  rm -f "$NETWORK_DIR"/3[0-9]-r2-*.network "$NETWORK_DIR"/4[0-9]-r2-*.network
}

networkd_file_matches_iface(){
  local file="$1" iface="$2" line value pattern in_match=0
  [ -r "$file" ] || return 1
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(trim "$line")"
    case "$line" in
      "[Match]") in_match=1; continue ;;
      "["*) in_match=0; continue ;;
    esac
    [ "$in_match" -eq 1 ] || continue
    case "$line" in
      Name=*)
        value="${line#Name=}"
        for pattern in $value; do
          [[ "$iface" == $pattern ]] && return 0
        done
        ;;
    esac
  done < "$file"
  return 1
}

networkd_iface_conflicts(){
  local iface="$1" file base
  for file in "$NETWORK_DIR"/*.network; do
    [ -e "$file" ] || continue
    base="$(basename "$file")"
    case "$base" in
      [2-4][0-9]-r2-*.network|*.easepi-r2-script-disabled*) continue ;;
    esac
    networkd_file_matches_iface "$file" "$iface" && printf '%s\n' "$file"
  done | sort
}

guide_networkd_iface_conflicts(){
  local iface="$1" file disabled stamp
  local -a conflicts=()
  mapfile -t conflicts < <(networkd_iface_conflicts "$iface")
  [ "${#conflicts[@]}" -eq 0 ] && return 0

  warn "检测到已有 systemd-networkd 配置会匹配 $iface。"
  warn "networkd 会优先使用排序靠前的 .network 文件，旧规则可能导致本脚本生成的配置不生效。"
  for file in "${conflicts[@]}"; do
    echo "  - $file"
  done
  warn "建议禁用这些旧 .network 文件；脚本只会改名备份，不会直接删除。"
  if confirm "是否现在禁用这些冲突规则？" y; then
    stamp="$(date +%Y%m%d%H%M%S)"
    for file in "${conflicts[@]}"; do
      [ -e "$file" ] || continue
      disabled="${file}.easepi-r2-script-disabled-${stamp}"
      mv -n "$file" "$disabled" && ok "已禁用：$file -> $disabled"
    done
  else
    warn "已保留旧规则；如果 $iface 没有按预期获取地址，请回到本功能并同意禁用冲突规则。"
  fi
}

write_dns_config(){
  mkdir -p "$RESOLVED_DIR"
  {
    echo "[Resolve]"
    for d in $DEVICE_DNS; do echo "DNS=$d"; done
    echo "FallbackDNS=223.5.5.5 119.29.29.29 180.76.76.76"
    echo "DNSStubListener=yes"
  } > "$RESOLVED_CONF"
  if [ -L /etc/resolv.conf ] || [ -f /etc/resolv.conf ]; then
    {
      echo "# 由 EasePi-R2-Script 生成"
      for d in $DEVICE_DNS; do echo "nameserver $d"; done
    } > /etc/resolv.conf 2>/dev/null || true
  fi
}

write_networkd(){
  clean_networkd_files
  cat > "$NETWORK_DIR/20-r2-br-lan.netdev" <<'EOF_BR'
[NetDev]
Name=br-lan
Kind=bridge
EOF_BR
  cat > "$NETWORK_DIR/21-r2-br-lan.network" <<EOF_BRNET
[Match]
Name=br-lan

[Link]
RequiredForOnline=no
ActivationPolicy=up

[Network]
Address=$LAN_CIDR
ConfigureWithoutCarrier=yes
IPv4Forwarding=yes
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF_BRNET
  local idx=30 ifname
  for ifname in $LAN_IFACES; do
    [ -n "$ifname" ] || continue
    cat > "$NETWORK_DIR/$(printf '%02d' "$idx")-r2-lan-$ifname.network" <<EOF_LAN
[Match]
Name=$ifname

[Link]
RequiredForOnline=no
ActivationPolicy=up

[Network]
Bridge=br-lan
ConfigureWithoutCarrier=yes
IgnoreCarrierLoss=yes
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF_LAN
    idx=$((idx+1))
  done

  idx=40
  while IFS='|' read -r ifname mode metric addr gateway dns_list; do
    [ -n "$ifname" ] || continue
    [ "${mode:-dhcp}" = disabled ] && continue
    metric="${metric:-100}"
    dns_list="${dns_list:-$DEVICE_DNS}"
    local network_file
    if [ "$mode" = static ]; then
      network_file="$NETWORK_DIR/$(printf '%02d' "$idx")-r2-wan-$ifname.network"
      cat > "$network_file" <<EOF_WAN_STATIC
[Match]
Name=$ifname

[Link]
RequiredForOnline=no

[Network]
Address=$addr
IPv6AcceptRA=no
LinkLocalAddressing=no
$(for d in $dns_list; do echo "DNS=$d"; done)

[Route]
Gateway=$gateway
Metric=$metric
EOF_WAN_STATIC
    else
      network_file="$NETWORK_DIR/$(printf '%02d' "$idx")-r2-wan-$ifname.network"
      cat > "$network_file" <<EOF_WAN_DHCP
[Match]
Name=$ifname

[Link]
RequiredForOnline=no

[Network]
DHCP=$(if [ "$ifname" = lte4g ]; then echo yes; else echo ipv4; fi)
IPv6AcceptRA=$(if [ "$ifname" = lte4g ]; then echo yes; else echo no; fi)
LinkLocalAddressing=$(if [ "$ifname" = lte4g ]; then echo ipv6; else echo no; fi)
$(for d in $dns_list; do echo "DNS=$d"; done)

[DHCPv4]
UseDNS=no
$(if [ "$ifname" = lte4g ]; then echo "UseRoutes=no"; echo "RouteMetric=$metric"; else echo "RouteMetric=$metric"; fi)
EOF_WAN_DHCP
      if [ "$ifname" = lte4g ]; then
        cat >> "$network_file" <<EOF_LTE_RA

[IPv6AcceptRA]
UseDNS=no
RouteMetric=$metric

[DHCPv6]
UseDNS=no
WithoutRA=solicit
EOF_LTE_RA
      fi
    fi
    idx=$((idx+1))
  done <<< "$WAN_CONFIG"
}

write_dnsmasq(){
  mkdir -p /etc/dnsmasq.d
  cat > "$DNSMASQ_CONF" <<EOF_DNSMASQ
# 由 EasePi-R2-Script 生成
interface=br-lan
bind-dynamic
listen-address=127.0.0.1,$LAN_IP
port=53
domain-needed
bogus-priv
no-resolv
expand-hosts
domain=lan
dhcp-authoritative
dhcp-range=interface:br-lan,$DHCP_START,$DHCP_END,$DHCP_MASK,12h
dhcp-option=interface:br-lan,3,$LAN_IP
dhcp-option=interface:br-lan,6,$LAN_DNS
$(for d in $UPSTREAM_DNS; do echo "server=$d"; done)
EOF_DNSMASQ
}

nat_rule(){
  local -a outs
  local ifname joined i
  outs=()
  for ifname in $NAT_OUT; do
    [ -n "$ifname" ] && outs+=("\"$ifname\"")
  done
  if [ "${#outs[@]}" -eq 0 ]; then
    echo "    # 未配置 NAT 出口"
  elif [ "${#outs[@]}" -eq 1 ]; then
    echo "    oifname ${outs[0]} masquerade"
  else
    joined="${outs[0]}"
    for ((i=1; i<${#outs[@]}; i++)); do
      joined="$joined, ${outs[$i]}"
    done
    echo "    oifname { $joined } masquerade"
  fi
}

write_nft(){
  mkdir -p "$NFT_DIR"
  cat > "$NFT_CONF" <<EOF_NFT
#!/usr/sbin/nft -f
# 由 EasePi-R2-Script 生成

table ip $NFT_TABLE {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
$(nat_rule)
  }
}
EOF_NFT
}

ensure_nft_main_include(){
  mkdir -p "$NFT_DIR"
  if [ ! -e "$NFT_MAIN_CONF" ]; then
    cat > "$NFT_MAIN_CONF" <<'EOF_NFT_MAIN'
#!/usr/sbin/nft -f
include "/etc/nftables.d/*.nft"
EOF_NFT_MAIN
    return
  fi
  if grep -qs '由 EasePi-R2-Script 生成' "$NFT_MAIN_CONF" && grep -qs 'flush ruleset' "$NFT_MAIN_CONF"; then
    cp -a "$NFT_MAIN_CONF" "$BASE_DIR/nftables.conf.$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null || true
    cat > "$NFT_MAIN_CONF" <<'EOF_NFT_MAIN'
#!/usr/sbin/nft -f
# EasePi-R2-Script：主文件只加载片段，不清空其他规则
include "/etc/nftables.d/*.nft"
EOF_NFT_MAIN
    return
  fi
  grep -qsE '^[[:space:]]*include[[:space:]]+"/etc/nftables\.d/\*\.nft"' "$NFT_MAIN_CONF" && return
  cp -a "$NFT_MAIN_CONF" "$BASE_DIR/nftables.conf.$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null || true
  {
    echo
    echo '# EasePi-R2-Script：加载脚本自己的 nftables 片段，不清空其他规则'
    echo 'include "/etc/nftables.d/*.nft"'
  } >> "$NFT_MAIN_CONF"
}

load_nft_rules(){
  ensure_nft_main_include
  if ! has_cmd nft; then
    warn "nft 命令不存在，请先安装 nftables。"
    return 1
  fi
  if ! nft -c -f "$NFT_CONF" >/dev/null 2>&1; then
    warn "nftables 规则校验失败，请检查 $NFT_CONF"
    return 1
  fi
  nft delete table ip "$NFT_TABLE" 2>/dev/null || true
  nft -f "$NFT_CONF" 2>/dev/null || { warn "nftables 规则加载失败，请检查 $NFT_CONF"; return 1; }
  return 0
}

write_sysctl(){
  mkdir -p /etc/sysctl.d
  cat > "$SYSCTL_CONF" <<'EOF_SYSCTL'
net.ipv4.ip_forward=1
EOF_SYSCTL
}

apply_lte4g_ipv6_ra_sysctl(){
  [ -d /sys/class/net/lte4g ] || return 0
  sysctl -w net.ipv6.conf.lte4g.accept_ra=2 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.lte4g.autoconf=1 >/dev/null 2>&1 || true
}

write_lte4g_manager_files(){
  mkdir -p "$(dirname "$LTE_MANAGER_SCRIPT")" "$(dirname "$LTE_MANAGER_SERVICE")"
  cat > "$LTE_MANAGER_SCRIPT" <<'EOF_LTE_MANAGER'
#!/usr/bin/env bash
set -u

IFACE="${1:-lte4g}"
VID="${EASEPI_R2_ML307R_VID:-2ecc}"
PID="${EASEPI_R2_ML307R_PID:-3012}"
NEW_ID="/sys/bus/usb-serial/drivers/option1/new_id"
APN="${EASEPI_R2_LTE4G_APN:-}"
AT_PORT=""
LOG_TAG="easepi-r2-lte4g-manager"

log(){
  logger -t "$LOG_TAG" "$*" 2>/dev/null || true
  printf '%s\n' "$*"
}

ml307r_present(){
  local vendor_path device_dir
  for vendor_path in /sys/bus/usb/devices/*/idVendor; do
    [ -r "$vendor_path" ] || continue
    device_dir="${vendor_path%/idVendor}"
    [ "$(cat "$vendor_path" 2>/dev/null)" = "$VID" ] || continue
    [ -r "$device_dir/idProduct" ] || continue
    [ "$(cat "$device_dir/idProduct" 2>/dev/null)" = "$PID" ] || continue
    return 0
  done
  return 1
}

bind_ml307r_at(){
  modprobe usbserial 2>/dev/null || true
  modprobe usb_wwan 2>/dev/null || true
  modprobe option 2>/dev/null || true
  if ml307r_present && [ -w "$NEW_ID" ]; then
    { printf '%s %s\n' "$VID" "$PID" > "$NEW_ID"; } 2>/dev/null || true
  fi
}

at_send_raw(){
  local port="$1" cmd="$2" out
  [ -c "$port" ] || return 1
  stty -F "$port" 115200 raw -echo -echoe -echok -crtscts -ixon -ixoff min 0 time 10 2>/dev/null || true
  exec 3<>"$port" || return 1
  dd if="$port" of=/dev/null bs=512 count=1 iflag=nonblock 2>/dev/null || true
  printf '%s\r' "$cmd" >&3
  out="$(timeout 8 cat <&3 2>/dev/null | tr '\r' '\n' | sed '/^$/d')"
  exec 3>&- 3<&-
  printf '%s\n' "$out"
}

at_try(){
  local cmd="$1" out one_line
  out="$(at_send_raw "$AT_PORT" "$cmd" 2>/dev/null || true)"
  one_line="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
  log "AT $cmd => ${one_line:-no response}"
  printf '%s\n' "$out" | grep -q 'OK'
}

find_at_port(){
  local i port out
  for i in $(seq 1 30); do
    for port in /dev/ttyUSB2 /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB3 /dev/ttyUSB4; do
      [ -c "$port" ] || continue
      out="$(at_send_raw "$port" AT 2>/dev/null || true)"
      if printf '%s\n' "$out" | grep -q 'OK'; then
        printf '%s\n' "$port"
        return 0
      fi
    done
    sleep 1
  done
  return 1
}

wait_for_iface(){
  local i
  for i in $(seq 1 30); do
    [ -d "/sys/class/net/$IFACE" ] && return 0
    sleep 1
  done
  return 1
}

configure_ml307r(){
  at_try ATE0 || true
  at_try AT+CGATT=1 || true
  if [ -n "$APN" ]; then
    at_try "AT+CGDCONT=1,\"IPV4V6\",\"$APN\"" || true
  fi
  at_try 'AT*NETIF=1' || true
  at_try 'AT*NETACT=1,1,1' || true
  at_try 'AT+MDIALUPCFG="auto",1' || true
  at_try 'AT*DIALMODE=1' || true
  at_try 'AT+MDIALUP=1,1' || true
}

refresh_lte_network(){
  local i
  sysctl -w "net.ipv6.conf.$IFACE.accept_ra=2" >/dev/null 2>&1 || true
  sysctl -w "net.ipv6.conf.$IFACE.autoconf=1" >/dev/null 2>&1 || true
  if command -v networkctl >/dev/null 2>&1; then
    networkctl reconfigure "$IFACE" >/dev/null 2>&1 || true
  fi
  for i in $(seq 1 30); do
    ip -4 -o addr show dev "$IFACE" scope global >/dev/null 2>&1 && \
      ip -6 -o addr show dev "$IFACE" scope global >/dev/null 2>&1 && break
    sleep 1
  done
  if [ -x /usr/local/sbin/easepi-r2-lte4g-policy-route.sh ]; then
    /usr/local/sbin/easepi-r2-lte4g-policy-route.sh "$IFACE" 1004 1004 >/dev/null 2>&1 || true
  fi
}

main(){
  local stopped_mm=0
  bind_ml307r_at
  wait_for_iface || log "$IFACE not found; skip LTE manager"

  AT_PORT="$(find_at_port 2>/dev/null || true)"
  if [ -z "$AT_PORT" ] && systemctl is-active --quiet ModemManager.service 2>/dev/null; then
    stopped_mm=1
    systemctl stop ModemManager.service >/dev/null 2>&1 || true
    sleep 2
    AT_PORT="$(find_at_port 2>/dev/null || true)"
  fi

  if [ -n "$AT_PORT" ]; then
    log "using AT port $AT_PORT"
    configure_ml307r
  else
    log "no ML307R AT port found; only refresh network routes"
  fi

  refresh_lte_network

  if [ "$stopped_mm" -eq 1 ] && [ "${EASEPI_R2_LTE4G_RESTART_MODEMMANAGER:-no}" = yes ]; then
    systemctl start ModemManager.service >/dev/null 2>&1 || true
  fi
}

main "$@"
EOF_LTE_MANAGER
  chmod 755 "$LTE_MANAGER_SCRIPT"

  cat > "$LTE_MANAGER_SERVICE" <<EOF_LTE_MANAGER_SERVICE
[Unit]
Description=EasePi-R2 lte4g ML307R dial and management
After=systemd-modules-load.service systemd-udevd.service
Before=systemd-networkd.service ModemManager.service
Wants=systemd-networkd.service

[Service]
Type=oneshot
ExecStart=$LTE_MANAGER_SCRIPT lte4g
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF_LTE_MANAGER_SERVICE

  cat > "$LTE_MANAGER_TIMER" <<'EOF_LTE_MANAGER_TIMER'
[Unit]
Description=Refresh EasePi-R2 lte4g ML307R dial state

[Timer]
OnBootSec=20s
OnUnitActiveSec=5min
AccuracySec=15s
Unit=easepi-r2-lte4g-manager.service

[Install]
WantedBy=timers.target
EOF_LTE_MANAGER_TIMER
}

write_lte4g_policy_files(){
  mkdir -p "$(dirname "$LTE_POLICY_SCRIPT")" "$(dirname "$LTE_POLICY_SERVICE")"
  cat > "$LTE_POLICY_SCRIPT" <<'EOF_LTE_POLICY'
#!/usr/bin/env bash
set -u

IFACE="${1:-lte4g}"
TABLE="${2:-1004}"
PRIO="${3:-1004}"

[ -d "/sys/class/net/$IFACE" ] || exit 0
sysctl -w "net.ipv6.conf.$IFACE.accept_ra=2" >/dev/null 2>&1 || true
sysctl -w "net.ipv6.conf.$IFACE.autoconf=1" >/dev/null 2>&1 || true

ADDR4="$(ip -o -4 addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')"
ADDR4_IP="${ADDR4%/*}"

ADDR6="$(ip -o -6 addr show dev "$IFACE" scope global 2>/dev/null | awk '!/ temporary / {print $4; exit}')"
[ -n "$ADDR6" ] || ADDR6="$(ip -o -6 addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')"
ADDR6_IP="${ADDR6%/*}"

IFINDEX="$(cat "/sys/class/net/$IFACE/ifindex" 2>/dev/null || true)"
LEASE="/run/systemd/netif/leases/$IFINDEX"
ROUTER=""
if [ -r "$LEASE" ]; then
  ROUTER="$(awk -F= '$1=="ROUTER"{print $2; exit}' "$LEASE")"
  ROUTER="${ROUTER%% *}"
fi
[ -n "$ROUTER" ] || ROUTER="$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')"

ROUTER6="$(ip -6 route show default dev "$IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"

while ip -4 rule del priority "$PRIO" 2>/dev/null; do :; done
while ip -6 rule del priority "$PRIO" 2>/dev/null; do :; done
ip -4 route flush table "$TABLE" 2>/dev/null || true
ip -6 route flush table "$TABLE" 2>/dev/null || true

if [ -n "$ADDR4_IP" ] && [ -n "$ROUTER" ]; then
  ip -4 route show dev "$IFACE" scope link 2>/dev/null | while read -r route; do
    [ -n "$route" ] || continue
    prefix="${route%% *}"
    rest="${route#"$prefix"}"
    ip -4 route replace "$prefix" dev "$IFACE" table "$TABLE" $rest 2>/dev/null || true
  done
  ip -4 route replace default via "$ROUTER" dev "$IFACE" table "$TABLE"
  ip -4 rule add priority "$PRIO" from "$ADDR4_IP/32" table "$TABLE"
fi

if [ -n "$ADDR6_IP" ]; then
  ip -6 route show dev "$IFACE" scope link 2>/dev/null | while read -r route; do
    [ -n "$route" ] || continue
    prefix="${route%% *}"
    rest="${route#"$prefix"}"
    ip -6 route replace "$prefix" dev "$IFACE" table "$TABLE" $rest 2>/dev/null || true
  done
  if [ -n "$ROUTER6" ]; then
    ip -6 route replace default via "$ROUTER6" dev "$IFACE" table "$TABLE"
  else
    ip -6 route replace default dev "$IFACE" table "$TABLE" 2>/dev/null || true
  fi
  ip -6 rule add priority "$PRIO" from "$ADDR6_IP/128" table "$TABLE"
fi
exit 0
EOF_LTE_POLICY
  chmod 755 "$LTE_POLICY_SCRIPT"

  cat > "$LTE_POLICY_SERVICE" <<EOF_LTE_SERVICE
[Unit]
Description=EasePi-R2 lte4g 管理入口策略路由
After=systemd-networkd.service
Wants=systemd-networkd.service

[Service]
Type=oneshot
ExecStart=$LTE_POLICY_SCRIPT lte4g $LTE_POLICY_TABLE $LTE_POLICY_PRIO
EOF_LTE_SERVICE

  cat > "$LTE_POLICY_TIMER" <<'EOF_LTE_TIMER'
[Unit]
Description=定时刷新 EasePi-R2 lte4g 管理入口策略路由

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=easepi-r2-lte4g-policy-route.service

[Install]
WantedBy=timers.target
EOF_LTE_TIMER
}

sync_lte4g_policy_service(){
  write_lte4g_policy_files
  if wan_has_iface lte4g; then
    systemctl daemon-reload || true
    systemctl enable --now easepi-r2-lte4g-policy-route.timer >/dev/null 2>&1 || true
    systemctl start easepi-r2-lte4g-policy-route.service >/dev/null 2>&1 || true
  else
    systemctl disable --now easepi-r2-lte4g-policy-route.timer >/dev/null 2>&1 || true
    systemctl stop easepi-r2-lte4g-policy-route.service >/dev/null 2>&1 || true
    while ip -4 rule del priority "$LTE_POLICY_PRIO" 2>/dev/null; do :; done
    while ip -6 rule del priority "$LTE_POLICY_PRIO" 2>/dev/null; do :; done
    ip -4 route flush table "$LTE_POLICY_TABLE" 2>/dev/null || true
    ip -6 route flush table "$LTE_POLICY_TABLE" 2>/dev/null || true
  fi
}

sync_lte4g_manager_service(){
  write_lte4g_manager_files
  if wan_has_iface lte4g; then
    systemctl daemon-reload || true
    systemctl enable easepi-r2-lte4g-manager.service >/dev/null 2>&1 || true
    systemctl enable --now easepi-r2-lte4g-manager.timer >/dev/null 2>&1 || true
    systemctl start easepi-r2-lte4g-manager.service >/dev/null 2>&1 || true
  else
    systemctl disable --now easepi-r2-lte4g-manager.timer >/dev/null 2>&1 || true
    systemctl disable easepi-r2-lte4g-manager.service >/dev/null 2>&1 || true
    systemctl stop easepi-r2-lte4g-manager.service >/dev/null 2>&1 || true
  fi
}

write_all_configs(){
  save_config
  write_dns_config
  write_networkd
  write_dnsmasq
  write_nft
  write_sysctl
  write_lte4g_manager_files
  write_lte4g_policy_files
}

reload_services(){
  need_root
  local step=0 total=12
  reload_step(){
    step=$((step+1))
    info "[$step/$total] $*"
  }

  echo
  info "开始重新加载网络服务，耗时较长的步骤会提前提示，请耐心等待。"

  reload_step "读取当前配置..."
  load_config

  reload_step "写入 networkd / dnsmasq / nftables / 4G 管理配置..."
  write_all_configs

  reload_step "应用 sysctl 内核网络参数..."
  sysctl --system >/dev/null 2>&1 || true

  reload_step "检查并应用 lte4g IPv6 RA 参数..."
  wan_has_iface lte4g && apply_lte4g_ipv6_ra_sysctl

  reload_step "重新加载 systemd 服务配置..."
  systemctl daemon-reload || true

  reload_step "启用 networkd / dnsmasq / nftables..."
  systemctl enable systemd-networkd dnsmasq nftables >/dev/null 2>&1 || true

  reload_step "禁用 systemd-networkd-wait-online，避免无网口等待超时..."
  systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
  systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true

  reload_step "启动/刷新 lte4g 管理服务；这一步可能需要 20-40 秒..."
  sync_lte4g_manager_service

  reload_step "重启 systemd-networkd..."
  systemctl restart systemd-networkd 2>/dev/null || warn "systemd-networkd 重启失败，请查看 journalctl -u systemd-networkd"

  reload_step "加载 nftables 转发/NAT 规则..."
  load_nft_rules || true

  reload_step "重启 dnsmasq / systemd-resolved..."
  systemctl restart dnsmasq 2>/dev/null || warn "dnsmasq 重启失败，请查看 journalctl -u dnsmasq"
  systemctl restart systemd-resolved 2>/dev/null || true

  reload_step "启动/刷新 lte4g 策略路由服务..."
  sync_lte4g_policy_service

  ok "networkd / dnsmasq / nftables 已重新加载。"
}

test_lte4g_connectivity(){
  local iface="${1:-lte4g}" ipv4_target="${LTE4G_TEST_IPV4:-223.5.5.5}" ipv6_target="${LTE4G_TEST_IPV6:-2400:3200::1}"
  local tmp4 tmp6 v4_ok=1 v6_ok=1

  echo
  info "正在通过 $iface 测试外网 IPv4/IPv6 连通性..."
  if [ ! -d "/sys/class/net/$iface" ]; then
    err "$iface 不存在，lte4g 开启失败。"
    return 1
  fi

  systemctl start easepi-r2-lte4g-manager.service >/dev/null 2>&1 || true
  systemctl start easepi-r2-lte4g-policy-route.service >/dev/null 2>&1 || true
  if [ -x "$LTE_POLICY_SCRIPT" ]; then
    "$LTE_POLICY_SCRIPT" "$iface" "$LTE_POLICY_TABLE" "$LTE_POLICY_PRIO" >/dev/null 2>&1 || true
  fi
  sleep 2

  ip -br addr show "$iface" 2>/dev/null | sed 's/^/  /' || true

  tmp4="$(mktemp)"
  tmp6="$(mktemp)"
  echo
  info "IPv4 测试：ping -4 -I $iface -c 3 -W 3 $ipv4_target"
  if ping -4 -I "$iface" -c 3 -W 3 "$ipv4_target" >"$tmp4" 2>&1; then
    v4_ok=0
  fi
  sed 's/^/  /' "$tmp4"

  echo
  info "IPv6 测试：ping -6 -I $iface -c 3 -W 3 $ipv6_target"
  if ping -6 -I "$iface" -c 3 -W 3 "$ipv6_target" >"$tmp6" 2>&1; then
    v6_ok=0
  fi
  sed 's/^/  /' "$tmp6"
  rm -f "$tmp4" "$tmp6"

  if [ "$v4_ok" -eq 0 ] && [ "$v6_ok" -eq 0 ]; then
    ok "lte4g 开启成功：IPv4 和 IPv6 外网均已 ping 通。"
    return 0
  fi

  err "lte4g 开启失败：IPv4 或 IPv6 外网 ping 不通。"
  warn "可查看：journalctl -u easepi-r2-lte4g-manager.service -u easepi-r2-lte4g-policy-route.service --no-pager -n 80"
  return 1
}

guess_dns_zone(){
  local fqdn="${1%.}"
  awk -F. 'NF>=2 {print $(NF-1)"."$NF; exit} {print $0}' <<< "$fqdn"
}

ensure_ipv6_ddns_deps(){
  local -a deps missing
  local pkg
  deps=(iproute2 curl ca-certificates jq openssl)
  missing=()
  echo "正在检测 IPv6 DDNS 依赖..."
  for pkg in "${deps[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "IPv6 DDNS 必要依赖已安装。"
    return 0
  fi
  warn "缺少以下依赖："
  printf '  %s\n' "${missing[@]}"
  confirm "是否立即安装缺少的 IPv6 DDNS 依赖？" y || return 1
  install_packages "${missing[@]}"
}

write_ipv6_ddns_files(){
  mkdir -p "$(dirname "$IPV6_DDNS_SCRIPT")" "$(dirname "$IPV6_DDNS_SERVICE")"
  cat > "$IPV6_DDNS_SCRIPT" <<'EOF_IPV6_DDNS'
#!/usr/bin/env bash
set -uo pipefail

CONF="/etc/easepi-r2-script/ipv6-ddns.env"
LOG_TAG="easepi-r2-ipv6-ddns"

log(){
  logger -t "$LOG_TAG" "$*" 2>/dev/null || true
  printf '%s\n' "$*"
}

fail(){
  log "失败：$*"
  exit 1
}

[ -r "$CONF" ] || fail "配置不存在：$CONF"
# shellcheck disable=SC1090
. "$CONF"

: "${DDNS_IFACE:=lte4g}"
: "${DDNS_RECORD_TYPE:=AAAA}"
: "${DDNS_API_ENDPOINT:=}"

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

json_string(){
  jq -Rn --arg v "$1" '$v'
}

urlencode(){
  jq -nr --arg v "$1" '$v|@uri' | sed 's/%7E/~/g'
}

get_iface_ipv6(){
  local ip
  ip="$(ip -6 -o addr show dev "$DDNS_IFACE" scope global 2>/dev/null | awk '!/ temporary / && !/ deprecated / {split($4,a,"/"); print a[1]; exit}')"
  [ -n "$ip" ] || ip="$(ip -6 -o addr show dev "$DDNS_IFACE" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
  [ -n "$ip" ] || return 1
  printf '%s\n' "$ip"
}

rr_from_domain(){
  local fqdn="${DDNS_DOMAIN%.}" zone="${DDNS_ZONE%.}" rr
  if [ "$fqdn" = "$zone" ]; then
    printf '@\n'
    return
  fi
  rr="${fqdn%.$zone}"
  [ "$rr" != "$fqdn" ] && [ -n "$rr" ] || rr="@"
  printf '%s\n' "$rr"
}

fqdn_dot(){
  local fqdn="${DDNS_DOMAIN%.}"
  printf '%s.\n' "$fqdn"
}

print_result_json(){
  jq . 2>/dev/null || cat
}

update_cloudflare(){
  local zone_id record_id body resp success
  zone_id="${DDNS_TOKEN_ID:-}"
  if [ -z "$zone_id" ]; then
    resp="$(curl -sS -X GET "https://api.cloudflare.com/client/v4/zones?name=$DDNS_ZONE" \
      -H "Authorization: Bearer $DDNS_TOKEN_KEY" \
      -H "Content-Type: application/json")"
    zone_id="$(printf '%s' "$resp" | jq -r '.result[0].id // empty')"
  fi
  [ -n "$zone_id" ] || fail "Cloudflare Zone ID 未找到。请确认 Token 具备 Zone Read 权限，或把 Token ID 填为 Zone ID。"

  resp="$(curl -sS -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=AAAA&name=$DDNS_DOMAIN" \
    -H "Authorization: Bearer $DDNS_TOKEN_KEY" \
    -H "Content-Type: application/json")"
  record_id="$(printf '%s' "$resp" | jq -r '.result[0].id // empty')"
  body="$(jq -n --arg name "$DDNS_DOMAIN" --arg content "$DDNS_IPV6" \
    '{type:"AAAA",name:$name,content:$content,ttl:120,proxied:false}')"

  if [ -n "$record_id" ]; then
    resp="$(curl -sS -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
      -H "Authorization: Bearer $DDNS_TOKEN_KEY" \
      -H "Content-Type: application/json" \
      --data "$body")"
  else
    resp="$(curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
      -H "Authorization: Bearer $DDNS_TOKEN_KEY" \
      -H "Content-Type: application/json" \
      --data "$body")"
  fi
  printf '%s\n' "$resp" | print_result_json
  success="$(printf '%s' "$resp" | jq -r '.success // false')"
  [ "$success" = true ] || fail "Cloudflare 解析提交失败。"
}

dnspod_post(){
  local action="$1"
  shift
  curl -sS -X POST "https://dnsapi.cn/$action" \
    --data-urlencode "login_token=$DDNS_TOKEN_ID,$DDNS_TOKEN_KEY" \
    --data-urlencode "format=json" \
    --data-urlencode "lang=cn" \
    "$@"
}

update_dnspod(){
  local rr record_id resp code
  rr="$(rr_from_domain)"
  resp="$(dnspod_post Record.List \
    --data-urlencode "domain=$DDNS_ZONE" \
    --data-urlencode "sub_domain=$rr" \
    --data-urlencode "record_type=AAAA")"
  record_id="$(printf '%s' "$resp" | jq -r '.records[0].id // empty')"

  if [ -n "$record_id" ]; then
    resp="$(dnspod_post Record.Modify \
      --data-urlencode "domain=$DDNS_ZONE" \
      --data-urlencode "record_id=$record_id" \
      --data-urlencode "sub_domain=$rr" \
      --data-urlencode "record_type=AAAA" \
      --data-urlencode "record_line=默认" \
      --data-urlencode "value=$DDNS_IPV6")"
  else
    resp="$(dnspod_post Record.Create \
      --data-urlencode "domain=$DDNS_ZONE" \
      --data-urlencode "sub_domain=$rr" \
      --data-urlencode "record_type=AAAA" \
      --data-urlencode "record_line=默认" \
      --data-urlencode "value=$DDNS_IPV6")"
  fi
  printf '%s\n' "$resp" | print_result_json
  code="$(printf '%s' "$resp" | jq -r '.status.code // empty')"
  [ "$code" = 1 ] || fail "DNSPod 解析提交失败。"
}

update_simple_dyndns(){
  local url="$1" resp
  resp="$(curl -sS --get -u "$DDNS_TOKEN_ID:$DDNS_TOKEN_KEY" \
    --data-urlencode "hostname=$DDNS_DOMAIN" \
    --data-urlencode "myip=$DDNS_IPV6" \
    "$url")"
  printf '%s\n' "$resp"
  case "$resp" in
    good*|nochg*|*'good '*|*'nochg '*) return 0 ;;
    *) fail "动态域名接口返回失败：$resp" ;;
  esac
}

aliyun_rpc(){
  local action="$1" tmp canonical first line key value string_to_sign signature url resp
  shift
  tmp="$(mktemp)"
  {
    printf 'Action=%s\n' "$action"
    printf 'Version=2015-01-09\n'
    printf 'Format=JSON\n'
    printf 'AccessKeyId=%s\n' "$DDNS_TOKEN_ID"
    printf 'SignatureMethod=HMAC-SHA1\n'
    printf 'SignatureVersion=1.0\n'
    printf 'SignatureNonce=%s-%s\n' "$(date +%s%N)" "$$"
    printf 'Timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } > "$tmp"

  canonical=""
  first=1
  while IFS='=' read -r key value; do
    [ -n "$key" ] || continue
    if [ "$first" -eq 1 ]; then
      first=0
    else
      canonical="${canonical}&"
    fi
    canonical="${canonical}$(urlencode "$key")=$(urlencode "$value")"
  done < <(sort "$tmp")
  rm -f "$tmp"

  string_to_sign="GET&%2F&$(urlencode "$canonical")"
  signature="$(printf '%s' "$string_to_sign" | openssl dgst -sha1 -hmac "${DDNS_TOKEN_KEY}&" -binary | openssl base64 | tr -d '\n')"
  url="https://alidns.aliyuncs.com/?Signature=$(urlencode "$signature")&$canonical"
  resp="$(curl -sS "$url")"
  printf '%s\n' "$resp"
}

update_aliyun(){
  local rr resp record_id
  rr="$(rr_from_domain)"
  resp="$(aliyun_rpc DescribeDomainRecords "DomainName=$DDNS_ZONE" "RRKeyWord=$rr" "TypeKeyWord=AAAA")"
  record_id="$(printf '%s' "$resp" | jq -r --arg rr "$rr" '.DomainRecords.Record[]? | select(.RR==$rr and .Type=="AAAA") | .RecordId' | head -n1)"

  if [ -n "$record_id" ]; then
    resp="$(aliyun_rpc UpdateDomainRecord "RecordId=$record_id" "RR=$rr" "Type=AAAA" "Value=$DDNS_IPV6")"
  else
    resp="$(aliyun_rpc AddDomainRecord "DomainName=$DDNS_ZONE" "RR=$rr" "Type=AAAA" "Value=$DDNS_IPV6")"
  fi
  printf '%s\n' "$resp" | print_result_json
  printf '%s' "$resp" | jq -e '.RecordId' >/dev/null 2>&1 || fail "阿里云解析提交失败。"
}

update_huaweicloud(){
  local endpoint zone_id name resp record_id body
  endpoint="${DDNS_API_ENDPOINT:-https://dns.myhuaweicloud.com}"
  zone_id="${DDNS_TOKEN_ID:-}"
  name="$(fqdn_dot)"
  if [ -z "$zone_id" ]; then
    resp="$(curl -sS -X GET "$endpoint/v2/zones?name=${DDNS_ZONE}." \
      -H "X-Auth-Token: $DDNS_TOKEN_KEY" \
      -H "Content-Type: application/json")"
    zone_id="$(printf '%s' "$resp" | jq -r '.zones[0].id // empty')"
  fi
  [ -n "$zone_id" ] || fail "华为云 Zone ID 未找到。请把 Token ID 填为 Zone ID，Token Key 填为 IAM X-Auth-Token。"

  resp="$(curl -sS -X GET "$endpoint/v2/zones/$zone_id/recordsets?name=$name&type=AAAA" \
    -H "X-Auth-Token: $DDNS_TOKEN_KEY" \
    -H "Content-Type: application/json")"
  record_id="$(printf '%s' "$resp" | jq -r '.recordsets[0].id // empty')"
  body="$(jq -n --arg name "$name" --arg ip "$DDNS_IPV6" \
    '{name:$name,type:"AAAA",records:[$ip],ttl:300}')"
  if [ -n "$record_id" ]; then
    resp="$(curl -sS -X PUT "$endpoint/v2/zones/$zone_id/recordsets/$record_id" \
      -H "X-Auth-Token: $DDNS_TOKEN_KEY" \
      -H "Content-Type: application/json" \
      --data "$body")"
  else
    resp="$(curl -sS -X POST "$endpoint/v2/zones/$zone_id/recordsets" \
      -H "X-Auth-Token: $DDNS_TOKEN_KEY" \
      -H "Content-Type: application/json" \
      --data "$body")"
  fi
  printf '%s\n' "$resp" | print_result_json
  printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1 || fail "华为云解析提交失败。"
}

main(){
  need_cmd ip
  need_cmd curl
  need_cmd jq
  need_cmd openssl

  [ "${DDNS_RECORD_TYPE^^}" = "AAAA" ] || fail "当前脚本只更新 AAAA 记录。"
  DDNS_IPV6="$(get_iface_ipv6)" || fail "未从 $DDNS_IFACE 获取到公网 IPv6。"

  log "准备更新：$DDNS_DOMAIN AAAA -> $DDNS_IPV6（接口：$DDNS_IFACE）"
  case "${DDNS_PROVIDER,,}" in
    cloudflare) update_cloudflare ;;
    dnspod) update_dnspod ;;
    aliyun) update_aliyun ;;
    huaweicloud) update_huaweicloud ;;
    3322) update_simple_dyndns "http://members.3322.net/dyndns/update" ;;
    oray) update_simple_dyndns "https://ddns.oray.com/ph/update" ;;
    *) fail "不支持的服务商：$DDNS_PROVIDER" ;;
  esac
  log "成功：$DDNS_DOMAIN AAAA 已提交为 $DDNS_IPV6"
}

main "$@"
EOF_IPV6_DDNS
  chmod 755 "$IPV6_DDNS_SCRIPT"

  cat > "$IPV6_DDNS_SERVICE" <<EOF_IPV6_DDNS_SERVICE
[Unit]
Description=EasePi-R2 IPv6 DDNS updater
After=network-online.target easepi-r2-lte4g-manager.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$IPV6_DDNS_SCRIPT
TimeoutStartSec=90
EOF_IPV6_DDNS_SERVICE

  cat > "$IPV6_DDNS_TIMER" <<'EOF_IPV6_DDNS_TIMER'
[Unit]
Description=Refresh EasePi-R2 IPv6 DDNS

[Timer]
OnBootSec=45s
OnUnitActiveSec=10min
AccuracySec=30s
Unit=easepi-r2-ipv6-ddns.service

[Install]
WantedBy=timers.target
EOF_IPV6_DDNS_TIMER
}

configure_ipv6_ddns(){
  need_root
  load_config
  ensure_ipv6_ddns_deps || { warn "IPv6 DDNS 依赖未安装，已取消。"; pause; return; }
  write_ipv6_ddns_files

  local provider_choice provider domain zone zone_default token_id token_key endpoint_note endpoint
  echo "请选择 IPv6 DDNS 服务商："
  echo "1. 3322 / 公云"
  echo "2. Oray / 花生壳"
  echo "3. DNSPod"
  echo "4. 阿里云 Aliyun DNS"
  echo "5. 华为云 HuaweiCloud DNS"
  echo "6. Cloudflare"
  read -r -p "请选择 [6]: " provider_choice
  case "${provider_choice:-6}" in
    1) provider=3322 ;;
    2) provider=oray ;;
    3) provider=dnspod ;;
    4) provider=aliyun ;;
    5) provider=huaweicloud ;;
    6) provider=cloudflare ;;
    *) warn "无效选择，默认使用 Cloudflare。"; provider=cloudflare ;;
  esac

  read -r -p "请输入完整域名，例如 home.example.com: " domain
  domain="$(trim "$domain")"
  [ -n "$domain" ] || { err "域名不能为空。"; pause; return; }
  zone_default="$(guess_dns_zone "$domain")"
  zone="$(read_default "主域名 / Zone" "$zone_default")"
  zone="$(trim "$zone")"

  case "$provider" in
    cloudflare)
      echo "Cloudflare：Token ID 可留空自动查 Zone；如果 Token 权限较窄，也可直接填写 Zone ID。"
      read -r -p "Token ID / Zone ID（可留空）: " token_id
      read -r -p "Token Key / API Token（可直接粘贴，明文显示）: " token_key
      echo
      ;;
    dnspod)
      echo "DNSPod：Token ID 填 DNSPod Token ID，Token Key 填 DNSPod Token。"
      read -r -p "Token ID: " token_id
      read -r -p "Token Key（可直接粘贴，明文显示）: " token_key
      echo
      ;;
    aliyun)
      echo "阿里云：Token ID 填 AccessKey ID，Token Key 填 AccessKey Secret。"
      read -r -p "Token ID / AccessKey ID: " token_id
      read -r -p "Token Key / AccessKey Secret（可直接粘贴，明文显示）: " token_key
      echo
      ;;
    huaweicloud)
      echo "华为云：Token ID 建议填写 DNS Zone ID；Token Key 填 IAM X-Auth-Token。"
      read -r -p "Token ID / Zone ID（可留空自动查）: " token_id
      read -r -p "Token Key / IAM X-Auth-Token（可直接粘贴，明文显示）: " token_key
      echo
      endpoint_note="https://dns.myhuaweicloud.com"
      endpoint="$(read_default "华为云 DNS API Endpoint" "$endpoint_note")"
      ;;
    3322|oray)
      echo "$provider：Token ID 填账号/用户名，Token Key 填密码或授权码。"
      read -r -p "Token ID / 用户名: " token_id
      read -r -p "Token Key / 密码或授权码（可直接粘贴，明文显示）: " token_key
      echo
      ;;
  esac
  token_id="$(trim "$token_id")"
  token_key="$(trim "$token_key")"
  [ -n "$token_key" ] || { err "Token Key 不能为空。"; pause; return; }
  info "Token Key 将保存到 $IPV6_DDNS_CONF，文件权限会设置为 600，仅 root 可读写。"

  mkdir -p "$BASE_DIR"
  cat > "$IPV6_DDNS_CONF" <<EOF_DDNS_CONF
DDNS_PROVIDER='$(quote_sq "$provider")'
DDNS_DOMAIN='$(quote_sq "$domain")'
DDNS_ZONE='$(quote_sq "$zone")'
DDNS_TOKEN_ID='$(quote_sq "$token_id")'
DDNS_TOKEN_KEY='$(quote_sq "$token_key")'
DDNS_IFACE='lte4g'
DDNS_RECORD_TYPE='AAAA'
DDNS_API_ENDPOINT='$(quote_sq "${endpoint:-}")'
EOF_DDNS_CONF
  chmod 600 "$IPV6_DDNS_CONF"

  systemctl daemon-reload || true
  systemctl enable --now easepi-r2-ipv6-ddns.timer >/dev/null 2>&1 || true
  echo
  info "正在提交 AAAA 解析，默认使用 lte4g 当前 IPv6..."
  if "$IPV6_DDNS_SCRIPT"; then
    ok "IPv6 DDNS 提交成功，定时刷新服务已启用。"
  else
    err "IPv6 DDNS 提交失败，请检查上方接口返回和 Token 权限。"
  fi
  pause
}

lte4g_ddns_menu(){
  while true; do
    clear 2>/dev/null || true
    echo "============================================================"
    echo " 4G网络管理 / IPV6 DDNS"
    echo "============================================================"
    echo "1. 4G网络管理"
    echo "2. IPV6 DDNS"
    echo "0. 返回"
    echo "============================================================"
    read -r -p "请选择：" choice
    case "$choice" in
      1) enable_lte4g ;;
      2) configure_ipv6_ddns ;;
      0) return ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

show_network(){
  load_config
  clear 2>/dev/null || true
  echo "============================================================"
  echo " 当前网络配置"
  echo "============================================================"
  echo "持久配置：$CONFIG_FILE"
  echo "WAN配置："
  while IFS='|' read -r ifname mode metric addr gateway dns_list; do
    [ -n "$ifname" ] || continue
    printf '  %-10s 模式=%-8s 跃点=%-5s 地址=%s 网关=%s DNS=%s\n' "$ifname" "${mode:-dhcp}" "${metric:-100}" "${addr:-自动}" "${gateway:-自动}" "${dns_list:-$DEVICE_DNS}"
  done <<< "$WAN_CONFIG"
  echo "LAN：br-lan $LAN_CIDR，绑定网卡：$LAN_IFACES"
  echo "DHCP：$DHCP_START - $DHCP_END，掩码 $DHCP_MASK"
  echo "设备DNS：$DEVICE_DNS"
  echo "LAN下发DNS：$LAN_DNS，上游DNS：$UPSTREAM_DNS"
  echo "NAT出口：$NAT_OUT"
  echo "WiFi：$WLAN_IFACE / $WLAN_MODE / 跃点 $WLAN_METRIC"
  echo "------------------------------------------------------------"
  echo "接口："; ip -br addr 2>/dev/null | sed 's/^/  /' || true
  echo "------------------------------------------------------------"
  echo "默认路由："; ip route show default 2>/dev/null | sed 's/^/  /' || true
  echo "------------------------------------------------------------"
  echo "桥接端口："; bridge link 2>/dev/null | sed 's/^/  /' || true
  echo "------------------------------------------------------------"
  echo "networkd："; networkctl list 2>/dev/null | sed 's/^/  /' || true
  echo "------------------------------------------------------------"
  echo "DNS："; resolvectl dns 2>/dev/null | sed 's/^/  /' || cat /etc/resolv.conf 2>/dev/null | sed 's/^/  /'
  echo "------------------------------------------------------------"
  echo "服务："
  local svc unit
  for svc in systemd-networkd dnsmasq nftables ssh sshd hostapd "wpa_supplicant@$WLAN_IFACE" easepi-r2-lte4g-manager.timer easepi-r2-lte4g-policy-route.timer easepi-r2-ipv6-ddns.timer; do
    case "$svc" in
      *.service|*.timer) unit="$svc" ;;
      *) unit="$svc.service" ;;
    esac
    systemctl list-unit-files "$unit" >/dev/null 2>&1 || continue
    printf '  %-36s %s / %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)" "$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  done
  pause
}

configure_wan(){
  need_root
  load_config
  local new_config="" count i ifname mode metric addr gateway dns_list mode_choice default_if
  echo "当前物理网卡："; physical_ifaces | sed 's/^/  /'
  echo
  read -r -p "要配置几个 WAN 口？[1]: " count
  count="${count:-1}"
  [[ "$count" =~ ^[0-9]+$ ]] || count=1
  for ((i=1; i<=count; i++)); do
    echo
    [ "$i" -eq 1 ] && default_if="eth0" || default_if="wan$i"
    ifname="$(read_default "第 $i 个 WAN 网卡" "$default_if")"
    echo "模式：1 DHCP，2 静态，3 禁用"
    read -r -p "请选择 [1]: " mode_choice
    case "${mode_choice:-1}" in
      2) mode=static ;;
      3) mode=disabled ;;
      *) mode=dhcp ;;
    esac
    metric="$(read_default "默认路由跃点 metric，越小优先级越高" "$( [ "$i" -eq 1 ] && echo 100 || echo $((100+i*100)) )")"
    addr=""
    gateway=""
    if [ "$mode" = static ]; then
      addr="$(read_default "静态地址/CIDR" "192.168.$i.2/24")"
      gateway="$(read_default "网关" "192.168.$i.1")"
    fi
    dns_list="$(read_default "该 WAN 使用的 DNS，空格分隔" "$DEVICE_DNS")"
    new_config="${new_config:+$new_config
}$ifname|$mode|$metric|$addr|$gateway|$dns_list"
  done
  WAN_CONFIG="$new_config"
  NAT_OUT="$(echo "$WAN_CONFIG" | awk -F'|' '$2!="disabled"{print $1}' | xargs)"
  write_all_configs
  ok "WAN 配置已写入。"
  confirm "是否立即重新加载服务？" y && reload_services
  pause
}

configure_lan(){
  need_root
  load_config
  local p3
  echo "当前物理网卡："; physical_ifaces | sed 's/^/  /'
  LAN_CIDR="$(read_default "br-lan 地址/CIDR" "$LAN_CIDR")"
  LAN_IP="$(cidr_ip "$LAN_CIDR")"
  LAN_IFACES="$(read_default "绑定到 br-lan 的网卡，空格分隔" "$LAN_IFACES")"
  DHCP_MASK="$(prefix_to_mask "$(cidr_prefix "$LAN_CIDR")")"
  p3="$(prefix3 "$LAN_IP")"
  if confirm "是否按 LAN 地址自动推荐 DHCP 池？" y; then
    DHCP_START="$p3.100"
    DHCP_END="$p3.200"
    LAN_DNS="$LAN_IP"
  fi
  write_all_configs
  ok "LAN 配置已写入。"
  confirm "是否立即重新加载服务？" y && reload_services
  pause
}

configure_dhcp(){
  need_root
  load_config
  DHCP_START="$(read_default "DHCP 起始地址" "$DHCP_START")"
  DHCP_END="$(read_default "DHCP 结束地址" "$DHCP_END")"
  DHCP_MASK="$(read_default "DHCP 子网掩码" "$DHCP_MASK")"
  write_all_configs
  ok "DHCP 配置已写入。"
  confirm "是否立即重启 dnsmasq？" y && systemctl restart dnsmasq 2>/dev/null || true
  pause
}

configure_dns(){
  need_root
  load_config
  DEVICE_DNS="$(read_default "设备本身 DNS，空格分隔" "$DEVICE_DNS")"
  UPSTREAM_DNS="$(read_default "dnsmasq 上游 DNS，空格分隔" "$UPSTREAM_DNS")"
  LAN_DNS="$(read_default "通过 DHCP 下发给 LAN 客户端的 DNS" "$LAN_DNS")"
  write_all_configs
  ok "DNS 配置已写入。"
  if confirm "是否立即重新加载 DNS 服务？" y; then
    systemctl restart systemd-resolved 2>/dev/null || true
    systemctl restart dnsmasq 2>/dev/null || true
  fi
  pause
}

configure_nat(){
  need_root
  load_config
  echo "当前 WAN："
  echo "$WAN_CONFIG" | awk -F'|' '{printf "  %s  模式=%s  跃点=%s\n",$1,$2,$3}'
  NAT_OUT="$(read_default "NAT 出口，可填多个网卡，空格分隔" "$NAT_OUT")"
  write_all_configs
  load_nft_rules || true
  ok "NAT 出口已更新。"
  pause
}

configure_metric(){
  need_root
  load_config
  local new_config="" ifname mode metric addr gateway dns_list new_metric
  echo "当前 WAN 跃点："
  echo "$WAN_CONFIG" | awk -F'|' '{printf "  %s  metric=%s  模式=%s\n",$1,$3,$2}'
  while IFS='|' read -r ifname mode metric addr gateway dns_list; do
    [ -n "$ifname" ] || continue
    new_metric="$(read_default "$ifname 的 metric" "${metric:-100}")"
    new_config="${new_config:+$new_config
}$ifname|$mode|$new_metric|$addr|$gateway|$dns_list"
  done <<< "$WAN_CONFIG"
  WAN_CONFIG="$new_config"
  write_all_configs
  ok "默认路由跃点已更新。"
  confirm "是否立即重载 networkd？" y && reload_services
  pause
}

local_network_router_menu(){
  while true; do
    clear 2>/dev/null || true
    echo "============================================================"
    echo " 本地网络路由管理"
    echo "============================================================"
    echo "1. WAN 口配置"
    echo "2. LAN 口配置"
    echo "3. DHCP 配置"
    echo "4. DNS 配置"
    echo "5. 修改 NAT 出口"
    echo "6. 修改默认路由跃点"
    echo "0. 返回"
    echo "============================================================"
    read -r -p "请选择：" choice
    case "$choice" in
      1) configure_wan ;;
      2) configure_lan ;;
      3) configure_dhcp ;;
      4) configure_dns ;;
      5) configure_nat ;;
      6) configure_metric ;;
      0) return ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

enable_lte4g(){
  need_root
  load_config
  LTE4G_METRIC="$(read_default "lte4g DHCP 路由 metric，默认不把 LTE 当作备用出网" "$LTE4G_METRIC")"
  if ! echo "$WAN_CONFIG" | awk -F'|' '$1=="lte4g"{found=1} END{exit !found}'; then
    WAN_CONFIG="${WAN_CONFIG:+$WAN_CONFIG
}lte4g|dhcp|$LTE4G_METRIC|||$DEVICE_DNS"
  else
    WAN_CONFIG="$(echo "$WAN_CONFIG" | awk -F'|' -v m="$LTE4G_METRIC" 'BEGIN{OFS="|"} $1=="lte4g"{$2="dhcp";$3=m} {print}')"
  fi
  guide_networkd_iface_conflicts lte4g
  write_all_configs
  info "功能 10 会安装 lte4g manager：自动拨起 ML307R RNDIS，并刷新 IPv4/IPv6 管理入口路由。"
  info "lte4g 会通过 DHCPv4 + IPv6 RA 获取双栈地址；IPv4 不加入主默认路由。"
  info "脚本会启用 IPv4/IPv6 策略路由：从 LTE 地址进入 R2 的 SSH，回复包仍从 lte4g 返回。"
  info "提示：下面直接回车，或只输入空格再回车，都会按 Y 处理。"
  if confirm "是否立即重新加载服务？" y; then
    reload_services
    test_lte4g_connectivity lte4g || true
  else
    warn "已写入配置，但尚未重新加载服务；暂不进行 lte4g 外网检测。"
  fi
  pause
}

wifi_client(){
  need_root
  load_config
  install_packages iw wireless-regdb wpasupplicant rfkill
  local scan_file ssid choice pass wpa_conf first_wifi
  first_wifi="$(wifi_ifaces | head -1)"
  WLAN_IFACE="$(read_default "无线网卡" "${first_wifi:-wlan0}")"
  systemctl disable --now hostapd >/dev/null 2>&1 || true
  remove_lan_iface "$WLAN_IFACE"
  rfkill unblock wifi 2>/dev/null || true
  echo "正在扫描 WiFi，请稍等..."
  scan_file="$(mktemp)"
  iw dev "$WLAN_IFACE" scan 2>/dev/null | awk -F': ' '/SSID: / && $2!="" {print $2}' | awk '!seen[$0]++' > "$scan_file" || true
  if [ ! -s "$scan_file" ]; then
    warn "未扫描到信号，可以手动输入。"
    read -r -p "SSID: " ssid
  else
    nl -w2 -s'. ' "$scan_file"
    read -r -p "请选择 WiFi 序号：" choice
    ssid="$(sed -n "${choice}p" "$scan_file")"
    [ -n "$ssid" ] || read -r -p "SSID: " ssid
  fi
  rm -f "$scan_file"
  read -r -s -p "WiFi 密码，开放网络直接回车: " pass
  echo
  mkdir -p "$WPA_DIR"
  wpa_conf="$WPA_DIR/wpa_supplicant-$WLAN_IFACE.conf"
  if [ -n "$pass" ]; then
    wpa_passphrase "$ssid" "$pass" > "$wpa_conf"
  else
    cat > "$wpa_conf" <<EOF_WPA_OPEN
network={
    ssid="$ssid"
    key_mgmt=NONE
}
EOF_WPA_OPEN
  fi
  chmod 600 "$wpa_conf"
  WLAN_METRIC="$(read_default "$WLAN_IFACE 作为客户端的默认路由 metric，建议 700-900" "$WLAN_METRIC")"
  if ! echo "$WAN_CONFIG" | awk -F'|' -v i="$WLAN_IFACE" '$1==i{found=1} END{exit !found}'; then
    WAN_CONFIG="${WAN_CONFIG:+$WAN_CONFIG
}$WLAN_IFACE|dhcp|$WLAN_METRIC|||$DEVICE_DNS"
  else
    WAN_CONFIG="$(echo "$WAN_CONFIG" | awk -F'|' -v i="$WLAN_IFACE" -v m="$WLAN_METRIC" 'BEGIN{OFS="|"} $1==i{$2="dhcp";$3=m} {print}')"
  fi
  WLAN_MODE="客户端：$ssid"
  save_config
  write_all_configs
  systemctl enable --now "wpa_supplicant@$WLAN_IFACE" 2>/dev/null || true
  reload_services
  info "已配置为客户端。metric 较高时，WiFi 通常只作为备用线路。"
  pause
}

wifi_ap(){
  need_root
  load_config
  install_packages iw wireless-regdb hostapd rfkill
  local first_wifi ssid enc pass country channel bridge_to_lan
  first_wifi="$(wifi_ifaces | head -1)"
  WLAN_IFACE="$(read_default "无线网卡" "${first_wifi:-wlan0}")"
  systemctl disable --now "wpa_supplicant@$WLAN_IFACE" >/dev/null 2>&1 || true
  remove_wan_iface "$WLAN_IFACE"
  ssid="$(read_default "热点名称" "EasePi-R2")"
  echo "加密方式：1 WPA2-PSK，2 开放"
  read -r -p "请选择 [1]: " enc
  enc="${enc:-1}"
  pass=""
  if [ "$enc" = 1 ]; then
    while true; do
      read -r -s -p "热点密码，至少 8 位: " pass
      echo
      [ "${#pass}" -ge 8 ] && break
      warn "密码至少 8 位。"
    done
  fi
  country="$(read_default "国家代码" "CN")"
  channel="$(read_default "2.4G 信道" "6")"
  bridge_to_lan=no
  confirm "是否把热点加入 br-lan？推荐开启" y && bridge_to_lan=yes
  mkdir -p /etc/hostapd /etc/default
  {
    echo "interface=$WLAN_IFACE"
    [ "$bridge_to_lan" = yes ] && echo "bridge=br-lan"
    echo "driver=nl80211"
    echo "ssid=$ssid"
    echo "country_code=$country"
    echo "hw_mode=g"
    echo "channel=$channel"
    echo "ieee80211n=1"
    echo "wmm_enabled=1"
    if [ "$enc" = 1 ]; then
      echo "auth_algs=1"
      echo "wpa=2"
      echo "wpa_key_mgmt=WPA-PSK"
      echo "rsn_pairwise=CCMP"
      echo "wpa_passphrase=$pass"
    else
      echo "auth_algs=1"
    fi
  } > "$HOSTAPD_CONF"
  cat > /etc/default/hostapd <<EOF_HOSTAPD
DAEMON_CONF="$HOSTAPD_CONF"
EOF_HOSTAPD
  if [ "$bridge_to_lan" = yes ]; then
    case " $LAN_IFACES " in
      *" $WLAN_IFACE "*) ;;
      *) LAN_IFACES="$LAN_IFACES $WLAN_IFACE" ;;
    esac
  else
    remove_lan_iface "$WLAN_IFACE"
  fi
  WLAN_MODE="热点：$ssid"
  save_config
  write_all_configs
  reload_services
  systemctl unmask hostapd 2>/dev/null || true
  systemctl enable --now hostapd 2>/dev/null || true
  systemctl restart hostapd 2>/dev/null || warn "hostapd 启动失败，请查看 journalctl -u hostapd"
  ok "热点配置已写入。"
  pause
}

wifi_menu(){
  while true; do
    clear 2>/dev/null || true
    echo "============================================================"
    echo " WLAN 设置"
    echo "============================================================"
    echo "1. 作为客户端使用"
    echo "2. 作为热点使用"
    echo "0. 返回"
    read -r -p "请选择：" choice
    case "$choice" in
      1) wifi_client ;;
      2) wifi_ap ;;
      0) return ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

install_all_deps(){
  need_root
  local -a deps missing installed
  local pkg
  deps=(
    iproute2 iputils-ping ethtool bridge-utils
    dnsmasq nftables iptables ebtables arptables conntrack ipset
    openssh-server curl ca-certificates systemd-resolved
    tcpdump socat iperf3
    ppp pppoe
    iw wireless-regdb wpasupplicant hostapd rfkill jq openssl
    kmod usbutils pciutils modemmanager usb-modeswitch
    rsync zstd xz-utils unzip
  )
  missing=()
  installed=()

  echo "正在检测网络依赖..."
  for pkg in "${deps[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      installed+=("$pkg")
    else
      missing+=("$pkg")
    fi
  done

  echo
  ok "已安装：${#installed[@]} 个"
  if [ "${#installed[@]}" -gt 0 ]; then
    printf '  %s\n' "${installed[@]}"
  fi

  echo
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "所有网络依赖都已安装，无需重复安装。"
    pause
    return
  fi

  warn "缺少以下网络依赖：${#missing[@]} 个"
  printf '  %s\n' "${missing[@]}"
  echo
  confirm "是否一键安装缺少的网络依赖？" y || { warn "已取消安装。"; pause; return; }

  install_packages "${missing[@]}"
  systemctl enable systemd-networkd dnsmasq nftables ssh 2>/dev/null || true
  ok "网络依赖已安装。"
  pause
}

bytes_human(){
  if has_cmd numfmt; then
    numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%s bytes\n' "$1"
  else
    awk -v b="$1" 'BEGIN{
      split("B KiB MiB GiB TiB", u, " ");
      i=1;
      while (b >= 1024 && i < 5) { b/=1024; i++ }
      printf "%.1f %s\n", b, u[i]
    }'
  fi
}

parse_size_to_mib(){
  local raw unit num
  raw="$(trim "$1")"
  case "${raw,,}" in
    ""|full|all|max|全部|最大|扩满)
      echo full
      return 0
      ;;
  esac

  if [[ "$raw" =~ ^([0-9]+)([KkMmGgTt]?[Bb]?)?$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2],,}"
    case "$unit" in
      ""|m|mb) echo "$num" ;;
      g|gb) echo $((num * 1024)) ;;
      t|tb) echo $((num * 1024 * 1024)) ;;
      k|kb) echo $(((num + 1023) / 1024)) ;;
      *) return 1 ;;
    esac
    return 0
  fi

  return 1
}

resolve_root_block_device(){
  local root_source root_dev root_majmin
  root_source="$(findmnt -no SOURCE / | head -n1 || true)"
  root_dev="$(readlink -f "$root_source" 2>/dev/null || true)"

  if [ -z "$root_dev" ] || [ ! -b "$root_dev" ]; then
    root_majmin="$(findmnt -no MAJ:MIN / | head -n1 || true)"
    if [ -n "$root_majmin" ] && [ -e "/dev/block/$root_majmin" ]; then
      root_dev="$(readlink -f "/dev/block/$root_majmin" 2>/dev/null || true)"
    fi
  fi

  [ -n "$root_dev" ] && [ -b "$root_dev" ] || return 1
  printf '%s\n' "$root_dev"
}

refresh_partition_table(){
  local disk="$1"
  partprobe "$disk" >/dev/null 2>&1 || true
  partx -u "$disk" >/dev/null 2>&1 || true
  blockdev --rereadpt "$disk" >/dev/null 2>&1 || true
  udevadm settle >/dev/null 2>&1 || true
}

expand_rootfs(){
  need_root
  install_packages cloud-guest-utils parted e2fsprogs util-linux || {
    err "扩容依赖安装失败，请先检查 APT 源和网络。"
    pause
    return
  }

  local root_dev root_fstype disk_name part_num disk current_bytes disk_bytes current_human disk_human
  local target_input target_value target_mib target_bytes root_start_sector target_sectors target_end_sector disk_sectors max_end_sector add_mode

  root_dev="$(resolve_root_block_device)" || { err "无法识别 / 所在的块设备。"; pause; return; }
  root_fstype="$(findmnt -no FSTYPE / | head -n1 || true)"
  case "$root_fstype" in
    ext2|ext3|ext4) ;;
    *)
      err "当前根文件系统是 ${root_fstype:-未知}，此功能只支持 ext2/ext3/ext4 在线扩容。"
      pause
      return
      ;;
  esac

  disk_name="$(lsblk -no PKNAME "$root_dev" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  part_num="$(lsblk -no PARTN "$root_dev" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  if [ -z "$disk_name" ] || [ -z "$part_num" ]; then
    err "当前根设备 $root_dev 不是普通磁盘分区，暂不自动扩容。"
    pause
    return
  fi

  disk="/dev/$disk_name"
  [ -b "$disk" ] || { err "父磁盘不存在：$disk"; pause; return; }

  current_bytes="$(blockdev --getsize64 "$root_dev" 2>/dev/null || echo 0)"
  disk_bytes="$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)"
  current_human="$(bytes_human "$current_bytes")"
  disk_human="$(bytes_human "$disk_bytes")"

  echo
  info "当前根分区：$root_dev"
  info "父磁盘：$disk"
  info "文件系统：$root_fstype"
  info "当前根分区大小：$current_human"
  info "父磁盘总容量：$disk_human"
  echo
  echo "输入目标 rootfs 分区大小，例如：8192M、8G、16G。"
  echo "输入 +2G：表示在当前根分区基础上增加 2G。"
  echo "输入 full / 直接回车：扩展到磁盘可用最大空间。"
  target_input="$(read_default "目标大小" "full")"

  add_mode=no
  target_value="$target_input"
  case "$(trim "$target_input")" in
    +*)
      add_mode=yes
      target_value="${target_input#+}"
      ;;
  esac

  target_mib="$(parse_size_to_mib "$target_value")" || {
    err "大小格式无效：$target_input"
    pause
    return
  }

  if [ "$target_mib" = full ]; then
    echo
    warn "将把 $root_dev 扩展到 $disk 的可用最大空间。"
    confirm "确认继续？" n || { warn "已取消。"; pause; return; }
    growpart "$disk" "$part_num" || { err "growpart 执行失败。"; pause; return; }
  else
    target_bytes=$((target_mib * 1024 * 1024))
    if [ "$add_mode" = yes ]; then
      target_bytes=$((current_bytes + target_bytes))
      target_mib=$(((target_bytes + 1024 * 1024 - 1) / (1024 * 1024)))
    fi
    if [ "$target_bytes" -le "$current_bytes" ]; then
      err "目标大小不能小于或等于当前根分区大小。当前：$current_human"
      pause
      return
    fi
    root_start_sector="$(parted -sm "$disk" unit s print 2>/dev/null | awk -F: -v p="$part_num" '$1 == p {sub(/s$/, "", $2); print $2; exit}')"
    disk_sectors="$(blockdev --getsz "$disk" 2>/dev/null || echo 0)"
    if ! [[ "$root_start_sector" =~ ^[0-9]+$ ]] || ! [[ "$disk_sectors" =~ ^[0-9]+$ ]]; then
      err "无法读取分区起始位置。"
      pause
      return
    fi
    target_sectors=$(((target_bytes + 511) / 512))
    target_end_sector=$((root_start_sector + target_sectors - 1))
    max_end_sector=$((disk_sectors - 34))
    if [ "$target_end_sector" -gt "$max_end_sector" ]; then
      err "目标大小超过磁盘可用空间。磁盘总容量：$disk_human"
      pause
      return
    fi

    echo
    warn "将把 $root_dev 调整到约 ${target_mib} MiB，然后在线扩容文件系统。"
    confirm "确认继续？" n || { warn "已取消。"; pause; return; }
    parted -s "$disk" unit s resizepart "$part_num" "${target_end_sector}s" || {
      err "parted resizepart 执行失败。"
      pause
      return
    }
  fi

  refresh_partition_table "$disk"
  resize2fs "$root_dev" || { err "resize2fs 执行失败。"; pause; return; }
  ok "rootfs 扩容完成。"
  df -h / | sed 's/^/  /'
  pause
}

backup_menu(){
  while true; do
    clear 2>/dev/null || true
    echo "============================================================"
    echo " 备份与恢复"
    echo "============================================================"
    echo "当前仅保留最新 5 个历史配置。"
    echo "1. 立即备份"
    echo "2. 恢复备份"
    echo "3. 查看备份"
    echo "0. 返回"
    read -r -p "请选择：" choice
    case "$choice" in
      1)
        local p
        p="$(backup_now 手动)"
        ok "已备份到：$p"
        pause
        ;;
      2) restore_backup ;;
      3) ls -1dt "$BACKUP_DIR"/* 2>/dev/null | head -5 | nl -w2 -s'. ' || true; pause ;;
      0) return ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

main_menu(){
  need_root
  load_config
  while true; do
    load_config
    clear 2>/dev/null || true
    echo "============================================================"
    echo " EasePi-R2 中文网络管理器  $VERSION"
    echo "============================================================"
    echo "1. 一键检测并切换APT软件源"
    echo "2. 一键检测并安装所有网络依赖"
    echo "3. 一键开启SSH-ROOT用户登录"
    echo "4. 一键查看当前网络配置"
    echo "5. 本地网络路由管理"
    echo "6. 4G网络管理 / IPV6 DDNS"
    echo "7. 无线网络管理"
    echo "8. 重新加载 networkd / dnsmasq / nftables"
    echo "9. 一键扩容 rootfs"
    echo "10. 设置备份及恢复"
    echo "0. 退出"
    echo "============================================================"
    read -r -p "请选择：" choice
    case "$choice" in
      1) configure_apt_mirror ;;
      2) install_all_deps ;;
      3) configure_ssh_root ;;
      4) show_network ;;
      5) local_network_router_menu ;;
      6) lte4g_ddns_menu ;;
      7) wifi_menu ;;
      8) backup_now 重载 >/dev/null; reload_services; pause ;;
      9) expand_rootfs ;;
      10) backup_menu ;;
      0) exit 0 ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

main_menu "$@"
