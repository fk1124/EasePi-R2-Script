#!/usr/bin/env bash
set -uo pipefail

VERSION="2026-05-13-中文网络管理器"
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
  [ "$def" = y ] && hint="Y/n" || hint="y/N"
  read -r -p "$prompt [$hint]: " val
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
  OS_NAME=""
  OS_CODENAME=""
  OS_VERSION=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_NAME="${PRETTY_NAME:-$OS_ID}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    OS_VERSION="${VERSION_ID:-}"
  fi
  if [ -z "$OS_CODENAME" ] && has_cmd lsb_release; then
    OS_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
  fi
}

mirror_list(){
  case "$OS_ID" in
    ubuntu)
      cat <<'EOF_MIRROR'
阿里云|https://mirrors.aliyun.com/ubuntu/
清华大学|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/
中国科学技术大学|https://mirrors.ustc.edu.cn/ubuntu/
北京外国语大学|https://mirrors.bfsu.edu.cn/ubuntu/
南京大学|https://mirror.nju.edu.cn/ubuntu/
上海交通大学|https://mirror.sjtu.edu.cn/ubuntu/
腾讯云|https://mirrors.cloud.tencent.com/ubuntu/
华为云|https://repo.huaweicloud.com/ubuntu/
EOF_MIRROR
      ;;
    *)
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
  if [ "$OS_ID" = ubuntu ]; then
    test_url="${url%/}/dists/$OS_CODENAME/Release"
  else
    test_url="${url%/}/debian/dists/$OS_CODENAME/Release"
  fi
  if ! has_cmd curl; then
    echo 999999
    return
  fi
  start="$(date +%s%3N 2>/dev/null || date +%s000)"
  if curl -fsIL --connect-timeout 3 --max-time 6 "$test_url" >/dev/null 2>&1; then
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

write_apt_sources(){
  local name="$1" url="$2" ts armbian_url file found_armbian key_opt
  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BASE_DIR/apt备份"
  cp -a /etc/apt/sources.list "$BASE_DIR/apt备份/sources.list.$ts" 2>/dev/null || true
  if [ -d /etc/apt/sources.list.d ]; then
    cp -a /etc/apt/sources.list.d "$BASE_DIR/apt备份/sources.list.d.$ts" 2>/dev/null || true
  fi
  armbian_url="$(armbian_mirror_url "$url")"
  if [ "$OS_ID" = ubuntu ]; then
    cat > /etc/apt/sources.list <<EOF_APT
deb ${url%/}/ $OS_CODENAME main restricted universe multiverse
deb ${url%/}/ $OS_CODENAME-updates main restricted universe multiverse
deb ${url%/}/ $OS_CODENAME-backports main restricted universe multiverse
deb ${url%/}/ $OS_CODENAME-security main restricted universe multiverse
EOF_APT
  else
    cat > /etc/apt/sources.list <<EOF_APT
deb ${url%/}/debian/ $OS_CODENAME main contrib non-free non-free-firmware
deb ${url%/}/debian/ $OS_CODENAME-updates main contrib non-free non-free-firmware
deb ${url%/}/debian-security/ $OS_CODENAME-security main contrib non-free non-free-firmware
EOF_APT
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

configure_apt_mirror(){
  need_root
  detect_system
  echo
  info "当前系统：${OS_NAME:-未知}"
  info "发行代号：${OS_CODENAME:-未知}"
  if [ -z "$OS_CODENAME" ]; then
    err "无法识别发行代号，暂不自动改源。"
    pause
    return
  fi

  local name url latency choice best_idx=1 best_latency=999999 idx=0
  local -a names urls latencies
  names=()
  urls=()
  latencies=()
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
  echo
  read -r -p "请选择数字，直接回车或输入空格使用最优源 [$best_idx]: " choice
  choice="$(trim "$choice")"
  [ -z "$choice" ] && choice="$best_idx"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#names[@]}" ]; then
    warn "选择无效，使用最优源 $best_idx。"
    choice="$best_idx"
  fi
  write_apt_sources "${names[$((choice-1))]}" "${urls[$((choice-1))]}"
  if confirm "是否立即执行 apt update？" y; then
    apt-get update
  fi
  pause
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
    if [ "$mode" = static ]; then
      cat > "$NETWORK_DIR/$(printf '%02d' "$idx")-r2-wan-$ifname.network" <<EOF_WAN_STATIC
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
      cat > "$NETWORK_DIR/$(printf '%02d' "$idx")-r2-wan-$ifname.network" <<EOF_WAN_DHCP
[Match]
Name=$ifname

[Link]
RequiredForOnline=no

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=no
$(for d in $dns_list; do echo "DNS=$d"; done)

[DHCPv4]
UseDNS=no
$(if [ "$ifname" = lte4g ]; then echo "UseRoutes=no"; echo "RouteMetric=$metric"; else echo "RouteMetric=$metric"; fi)
EOF_WAN_DHCP
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

write_lte4g_policy_files(){
  mkdir -p "$(dirname "$LTE_POLICY_SCRIPT")" "$(dirname "$LTE_POLICY_SERVICE")"
  cat > "$LTE_POLICY_SCRIPT" <<'EOF_LTE_POLICY'
#!/usr/bin/env bash
set -u

IFACE="${1:-lte4g}"
TABLE="${2:-1004}"
PRIO="${3:-1004}"

[ -d "/sys/class/net/$IFACE" ] || exit 0

ADDR="$(ip -o -4 addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')"
[ -n "$ADDR" ] || exit 0
ADDR_IP="${ADDR%/*}"

IFINDEX="$(cat "/sys/class/net/$IFACE/ifindex" 2>/dev/null || true)"
LEASE="/run/systemd/netif/leases/$IFINDEX"
ROUTER=""
if [ -r "$LEASE" ]; then
  ROUTER="$(awk -F= '$1=="ROUTER"{print $2; exit}' "$LEASE")"
  ROUTER="${ROUTER%% *}"
fi
[ -n "$ROUTER" ] || ROUTER="$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')"
[ -n "$ROUTER" ] || exit 0

while ip -4 rule del priority "$PRIO" 2>/dev/null; do :; done
ip -4 route flush table "$TABLE" 2>/dev/null || true
ip -4 route show dev "$IFACE" scope link 2>/dev/null | while read -r route; do
  [ -n "$route" ] && ip -4 route replace table "$TABLE" $route 2>/dev/null || true
done
ip -4 route replace default via "$ROUTER" dev "$IFACE" table "$TABLE"
ip -4 rule add priority "$PRIO" from "$ADDR_IP/32" table "$TABLE"
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
    ip -4 route flush table "$LTE_POLICY_TABLE" 2>/dev/null || true
  fi
}

write_all_configs(){
  save_config
  write_dns_config
  write_networkd
  write_dnsmasq
  write_nft
  write_sysctl
  write_lte4g_policy_files
}

reload_services(){
  need_root
  load_config
  write_all_configs
  sysctl --system >/dev/null 2>&1 || true
  systemctl daemon-reload || true
  systemctl enable systemd-networkd dnsmasq nftables >/dev/null 2>&1 || true
  systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
  systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true
  systemctl restart systemd-networkd 2>/dev/null || warn "systemd-networkd 重启失败，请查看 journalctl -u systemd-networkd"
  load_nft_rules || true
  systemctl restart dnsmasq 2>/dev/null || warn "dnsmasq 重启失败，请查看 journalctl -u dnsmasq"
  systemctl restart systemd-resolved 2>/dev/null || true
  sync_lte4g_policy_service
  ok "networkd / dnsmasq / nftables 已重新加载。"
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
  for svc in systemd-networkd dnsmasq nftables ssh sshd hostapd "wpa_supplicant@$WLAN_IFACE" easepi-r2-lte4g-policy-route.timer; do
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
  write_all_configs
  info "lte4g 会通过 DHCP 获取地址，但 networkd 不把它加入主默认路由。"
  info "脚本会启用策略路由：从 LTE 地址进入 R2 的 SSH，回复包仍从 lte4g 返回。"
  confirm "是否立即重新加载服务？" y && reload_services
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
  install_packages iproute2 ethtool bridge-utils dnsmasq nftables openssh-server curl ca-certificates systemd-resolved iw wireless-regdb wpasupplicant hostapd rfkill
  systemctl enable systemd-networkd dnsmasq nftables ssh 2>/dev/null || true
  ok "网络依赖已安装。"
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
    echo "1. 智能识别系统并切换国内 APT 加速源"
    echo "2. SSH-root 一键开启"
    echo "3. 查看当前网络配置"
    echo "4. WAN 口配置"
    echo "5. LAN 口配置"
    echo "6. DHCP 配置"
    echo "7. DNS 配置"
    echo "8. 修改 NAT 出口"
    echo "9. 修改默认路由跃点"
    echo "10. 开启 lte4g 管理入口"
    echo "11. wlan 设置"
    echo "12. 重新加载 networkd / dnsmasq / nftables"
    echo "13. 一键安装所有网络依赖"
    echo "14. 设置备份及恢复"
    echo "0. 退出"
    echo "============================================================"
    read -r -p "请选择：" choice
    case "$choice" in
      1) configure_apt_mirror ;;
      2) configure_ssh_root ;;
      3) show_network ;;
      4) configure_wan ;;
      5) configure_lan ;;
      6) configure_dhcp ;;
      7) configure_dns ;;
      8) configure_nat ;;
      9) configure_metric ;;
      10) enable_lte4g ;;
      11) wifi_menu ;;
      12) backup_now 重载 >/dev/null; reload_services; pause ;;
      13) install_all_deps ;;
      14) backup_menu ;;
      0) exit 0 ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

main_menu "$@"
