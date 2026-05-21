# EasePi-R2-Script

EasePi-R2 常用中文脚本集合。仓库根目录下的 `*.sh` 会被 `EasePi-R2-Image-Build` / `EasePi-R2-LiteHost` 构建流程同步到镜像的 `/root/`，也可以在已启动的系统里单独下载执行。

## 快速下载

```bash
sudo -i
cd /root
curl -L -O https://raw.githubusercontent.com/fk1124/EasePi-R2-Script/main/0.sh
curl -L -O https://raw.githubusercontent.com/fk1124/EasePi-R2-Script/main/1.sh
curl -L -O https://raw.githubusercontent.com/fk1124/EasePi-R2-Script/main/9.sh
chmod +x /root/*.sh
```

## 脚本索引

| 脚本 | 状态 | 用途 |
| --- | --- | --- |
| `0.sh` | 可用 | Debian / Armbian 宿主基础网络、SSH、APT 源、路由配置 |
| `1.sh` | 可用 | 创建并切换到 OpenWrt LXC 宿主网络方案 |
| `2.sh` | 预留 | 待定义 |
| `3.sh` | 预留 | 待定义 |
| `4.sh` | 预留 | 待定义 |
| `5.sh` | 预留 | 待定义 |
| `6.sh` | 预留 | 待定义 |
| `7.sh` | 预留 | 待定义 |
| `8.sh` | 预留 | 待定义 |
| `9.sh` | 可用 | 安装和管理 RouterOS CHR KVM 虚拟机 |

## 使用说明

<details>
<summary><code>0.sh</code>：EasePi-R2 基础网络和宿主初始化</summary>

### 适用场景

- Debian / Armbian / EasePi-R2-LiteHost 宿主系统首次初始化。
- 配置 WAN、LAN、DHCP、DNS、NAT、WiFi 客户端/热点、LTE 管理口。
- 开启 SSH root 密码登录、切换国内 APT 源、安装基础网络依赖。
- 扩展 rootfs、查看网络状态、备份和恢复脚本管理的配置。

### 执行方式

```bash
sudo -i
cd /root
bash 0.sh
```

### 主要持久化配置

- `/etc/easepi-r2-script/`
- `/etc/systemd/network/`
- `/etc/dnsmasq.d/`
- `/etc/nftables.d/`
- `/etc/systemd/resolved.conf.d/`
- `/etc/hostapd/`
- `/etc/wpa_supplicant/`
- `/usr/local/sbin/easepi-r2-lte4g-policy-route.sh`

### 注意

网络配置切换可能导致当前 SSH 断开。首次执行建议保留 HDMI、串口、LTE 管理口或其他备用管理方式。

</details>

<details>
<summary><code>1.sh</code>：OpenWrt LXC 初始化和最终切网</summary>

### 适用场景

- 在 EasePi-R2 宿主上创建 OpenWrt 24.10.6 LXC。
- 将选定物理网口交给 OpenWrt LXC，宿主通过 `br-hostlan` / `host0` 回接到 OpenWrt LAN。
- 适合 EasePi-R2-LiteHost 作为轻量宿主，运行 OpenWrt LXC + Debian LXC + Redroid。

脚本整理自旧版设计：<https://gitee.com/fang-xiaomu/r2-openwrt-lxc/blob/master/lxc.openwrt.cn_source_fix.sh>

### 默认规划

```text
WAN：eth0
LAN：eth1 eth2 eth3
OpenWrt LAN：10.10.0.1/24
宿主 IP：10.10.0.2/24
DHCP：10.10.0.100 - 10.10.0.249
APT 源：清华 TUNA Debian 镜像
OpenWrt rootfs：上海交通大学 SJTUG OpenWrt 镜像
```

### 执行方式

```bash
sudo -i
cd /root
bash 1.sh
```

### 非交互示例

```bash
SKIP_WIZARD=1 SKIP_CONFIRM=1 \
WAN_IF=eth0 \
LAN_IFS="eth1 eth2 eth3" \
LAN_CIDR=10.10.0.0/24 \
OPENWRT_IP=10.10.0.1 \
HOST_IP=10.10.0.2 \
DHCP_START_IP=10.10.0.100 \
DHCP_END_IP=10.10.0.249 \
bash 1.sh
```

### 常用变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CT_NAME` | `openwrt` | LXC 容器名称 |
| `WAN_IF` | 交互选择，默认 `eth0` | OpenWrt WAN 物理口 |
| `LAN_IFS` | 交互选择，默认 `eth1 eth2 eth3` | OpenWrt LAN 物理口 |
| `HOST_BR` | `br-hostlan` | 宿主回接网桥 |
| `ROOTFS_URL` | SJTUG OpenWrt 24.10.6 rootfs | OpenWrt rootfs 下载地址 |
| `ENABLE_APT_CHINA_MIRROR` | `1` | 是否切换 Debian APT 国内源 |
| `DISABLE_HOST_ROUTER_STACK` | `1` | cutover 时停用宿主侧 networkd/dnsmasq/nftables，避免抢网口 |

### 执行后

如果当前 SSH 经过被直通给 OpenWrt 的物理网口，最终 `CUTOVER` 阶段断开是正常现象。断开后把电脑网线接到 OpenWrt LAN 口，电脑设置 DHCP，然后访问：

```text
OpenWrt: http://10.10.0.1
宿主 SSH: ssh root@10.10.0.2
```

排查日志：

```bash
cat /var/log/owrt-lxc-finalize.log
lxc-info -n openwrt
ip route
cat /etc/resolv.conf
```

</details>

<details>
<summary><code>2.sh</code>：预留脚本</summary>

当前为空文件，保留给后续功能。

</details>

<details>
<summary><code>3.sh</code>：预留脚本</summary>

当前为空文件，保留给后续功能。

</details>

<details>
<summary><code>4.sh</code>：预留脚本</summary>

当前为空文件，保留给后续功能。

</details>

<details>
<summary><code>5.sh</code>：预留脚本</summary>

当前为空文件，保留给后续功能。

</details>

<details>
<summary><code>6.sh</code>：预留脚本</summary>

当前为空文件，保留给后续功能。

</details>

<details>
<summary><code>7.sh</code>：预留脚本</summary>

当前为空文件，保留给后续功能。

</details>

<details>
<summary><code>8.sh</code>：预留脚本</summary>

当前为空文件，保留给后续功能。

</details>

<details>
<summary><code>9.sh</code>：RouterOS CHR KVM 安装和管理</summary>

### 适用场景

- 在 EasePi-R2 上安装和管理 RouterOS CHR ARM64 虚拟机。
- 默认使用 QEMU/KVM + virtio-net + Linux bridge。
- 支持一键安装、参数配置、RouterOS 预设导入、开机自启、控制台进入和维护。

### 准备镜像

到 MikroTik 官方下载 ARM64 CHR 镜像，或在宿主执行：

```bash
sudo -i
cd /root
curl -L -o chr-arm64.img.zip https://download.mikrotik.com/routeros/7.22.3/chr-7.22.3-arm64.img.zip
apt-get update
apt-get install -y unzip
unzip -p chr-arm64.img.zip > /root/routeros.img
chmod 600 /root/routeros.img
```

### 执行方式

```bash
sudo -i
cd /root
bash 9.sh
sudo routerosinstall
```

### 常用命令

```bash
systemctl status routeros-chr --no-pager
journalctl -u routeros-chr.service -n 80 --no-pager
systemctl start routeros-chr
systemctl stop routeros-chr
systemctl restart routeros-chr
sudo routeros
```

进入 `routeros` 控制台后，用 `Ctrl + ]` 退出。

### 注意

- 当前方案是 virtio-net + Linux bridge，不是 PCIe 网卡直通。
- 被分配给 RouterOS 的宿主物理网口会被 bridge/tap 接管。
- 不建议把当前 SSH 管理入口直接交给 RouterOS，除非保留串口、HDMI、LTE 或其他备用管理方式。

</details>

## 和镜像构建项目的关系

`EasePi-R2-Image-Build` 和 `EasePi-R2-LiteHost` 构建时会默认执行 `scripts/sync-root-scripts.sh`，从本仓库拉取根目录下的 `.sh` 文件并放入镜像 `/root/`。如需跳过同步，可在构建前设置：

```bash
EASEPI_R2_SCRIPT_SYNC=no bash build-image.sh armbian trixie 6.18 minimal
```
