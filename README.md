# EasePi-R2-Script

EasePi-R2 常用中文脚本集合。仓库根目录下的 `*.sh` 会被 `EasePi-R2-Image-Build` / `EasePi-R2-LiteHost` 构建流程同步到镜像的 `/root/`，也可以在已启动的系统里单独下载执行。

## 快速下载

在 EasePi-R2 终端里直接执行下面这一行即可。默认已经是 `root`，命令会把本仓库根目录下所有 `.sh` 脚本下载到 `/root/`，并自动加执行权限。

```bash
cd /root && rm -rf /tmp/EasePi-R2-Script && git clone --depth=1 https://github.com/fk1124/EasePi-R2-Script.git /tmp/EasePi-R2-Script && cp -f /tmp/EasePi-R2-Script/*.sh /root/ && chmod +x /root/*.sh
```

下载后按需要执行：

```bash
bash 0.sh
bash 1.sh
bash 9.sh
```

## 脚本索引

| 脚本 | 状态 | 用途 |
| --- | --- | --- |
| `0.sh` | 可用 | EasePi-R2 Debian / Armbian 宿主网络管理 |
| `1.sh` | 可用 | LXC 专属一键布置与容器管理 |
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
<summary><code>0.sh</code>：EasePi-R2 宿主网络管理脚本</summary>

### 脚本定位

`0.sh` 是 EasePi-R2 的宿主网络管理菜单，主要管理 Debian / Armbian 系统里的这些组件：

- `systemd-networkd`：管理网口、网桥、默认路由。
- `dnsmasq`：给 LAN 侧发 DHCP，并提供本地 DNS。
- `nftables`：配置 NAT 出口和转发规则。
- `wpa_supplicant`：配置 WiFi 客户端模式。
- `hostapd`：配置 WiFi 热点模式。
- `sshd`：开启或调整 SSH root 登录。

### 主要功能

- 查看当前网口、IP、路由、DNS 和服务状态。
- 配置 WAN：支持 DHCP、静态地址、禁用、metric 调整。
- 配置 LAN：创建或调整 `br-lan`，绑定 LAN 网口。
- 配置 DHCP：设置 LAN 地址池、网关、DNS 下发。
- 配置 DNS：设置宿主 DNS 和 `dnsmasq` 上游 DNS。
- 配置 NAT：用 `nftables` 给 LAN 侧设备共享 WAN 出口。
- 配置 WiFi：支持客户端模式和热点模式。
- 配置 LTE 管理口：保留 LTE 地址访问 SSH，不默认抢主路由。
- 安装基础网络依赖。
- 扩展 rootfs。
- 备份和恢复脚本管理过的网络配置。

### 执行方式

```bash
cd /root
bash 0.sh
```

### 适合什么时候用

- 刚刷好 Debian / Armbian / EasePi-R2-LiteHost，需要配置宿主网络。
- 需要把 EasePi-R2 当普通路由宿主使用。
- 需要快速调整 WAN、LAN、DHCP、DNS、NAT。
- 需要临时查看网络状态或恢复脚本生成的配置。

### 不适合什么时候用

- 已经决定让 OpenWrt LXC 完全接管物理网口时，最终应使用 `1.sh` 完成切网。
- 不想改宿主网络服务时，不要随便进入写配置的菜单项。

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
<summary><code>1.sh</code>：LXC 专属一键布置与容器管理</summary>

### 脚本定位

`1.sh` 是 EasePi-R2-LiteHost 的 LXC 管理菜单，用来准备 LXC 宿主环境、管理 `/lxc` 目录、预下载 rootfs，并安装 OpenWrt / Debian / Ubuntu 容器。

### 菜单功能

```text
1. 一键检测并安装 LXC 所有依赖
2. 一键检测并安装 OpenWrt 所需 Kmod
3. LXC 目录管理
4. rootfs 管理
5. 一键安装 OpenWrt 24
6. 一键安装 OpenWrt 25
7. 一键安装 Debian 12 Bookworm
8. 一键安装 Debian 13 Trixie
9. 一键安装 Ubuntu 24.04 Noble
10. LXC 备份 / 还原
0. 退出
```

### 默认规划

```text
LXC 根目录：/lxc
容器目录：/lxc/containers
rootfs 缓存：/lxc/rootfs-cache
备份目录：/lxc/backups
OpenWrt LAN：10.10.0.1/24
宿主 IP：10.10.0.2/24
宿主回接桥：br-hostlan
```

OpenWrt 容器会接管你选择的物理 WAN/LAN 网口；Debian / Ubuntu 容器会自动桥接到 `br-hostlan`，也就是接在 OpenWrt LAN 下面。

### 执行方式

```bash
cd /root
bash 1.sh
```

### 注意

- SSD 挂载工具不会静默格式化磁盘，格式化前需要手工输入确认文本。
- OpenWrt 24 / OpenWrt 25 可以都下载 rootfs，但同一时间只建议运行一个路由型 OpenWrt 容器。
- 备份容器前必须先关机，脚本检测到容器运行中会拒绝备份。
- OpenWrt 最终切网阶段可能断开当前 SSH，完成后访问 `http://10.10.0.1`。

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
cd /root
curl -fL --retry 3 -o chr-arm64.img.zip https://download.mikrotik.com/routeros/7.22.3/chr-7.22.3-arm64.img.zip
apt-get update
apt-get install -y unzip
unzip -p chr-arm64.img.zip > /root/routeros.img
chmod 600 /root/routeros.img
```

### 执行方式

```bash
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
