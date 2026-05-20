# EasePi-R2-Script

EasePi-R2 中文脚本集合。

- `0.sh`：用于 Debian / Armbian 系统的基础网络、SSH、APT 加速源和路由配置。
- `9.sh`：用于在 EasePi-R2 上安装和管理 RouterOS CHR KVM 虚拟机，默认使用 virtio-net + bridge 方式把宿主机网口接入 RouterOS。

## 快速使用

基础网络配置：

```bash
sudo bash 0.sh
```

RouterOS CHR 安装管理：

```bash
sudo bash 9.sh
sudo routerosinstall
```

建议第一次运行前保留 HDMI、本地串口、COM 口或另一条可用管理入口，避免网络配置切换时 SSH 中断后无法继续操作。

## RouterOS CHR 安装教程

下面以 ARM64 CHR 镜像为例。推荐最终在 EasePi-R2 的 `/root` 目录下准备好两个文件：

- `/root/9.sh`
- `/root/routeros.img`

### 1. 下载脚本

在 EasePi-R2 上执行：

```bash
sudo -i
cd /root
curl -L -o 9.sh https://raw.githubusercontent.com/fk1124/EasePi-R2-Script/main/9.sh
chmod +x /root/9.sh
```

如果设备暂时不能联网，也可以先在电脑上下载 `9.sh`，再通过 SCP、WinSCP、WindTerm SFTP 等方式上传到 EasePi-R2 的 `/root` 目录。

### 2. 下载 RouterOS CHR 镜像

到 MikroTik 官方下载页选择 ARM64 CHR 镜像，文件名通常类似：

```text
chr-7.22.3-arm64.img.zip
```

也可以直接在 EasePi-R2 上下载一个指定版本，例如：

```bash
sudo -i
cd /root
curl -L -o chr-arm64.img.zip https://download.mikrotik.com/routeros/7.22.3/chr-7.22.3-arm64.img.zip
```

如果需要换版本，把 URL 里的版本号和文件名替换成你要安装的版本即可。

### 3. 解压并重命名镜像

推荐把镜像整理成脚本默认识别的文件名：

```bash
sudo -i
cd /root
apt-get update
apt-get install -y unzip
unzip -p chr-arm64.img.zip > /root/routeros.img
chmod 600 /root/routeros.img
```

确认文件存在：

```bash
ls -lh /root/9.sh /root/routeros.img
```

说明：`9.sh` 也支持在 `/root` 下直接选择 `.img.zip`、`.vdi.zip`、`.qcow2`、`.vdi` 等镜像文件；不过手动解压成 `/root/routeros.img` 最简单、最不容易选错。

### 4. 安装 routerosinstall 命令

执行：

```bash
cd /root
bash 9.sh
```

脚本会生成本地管理命令：

```bash
routerosinstall
```

以后直接输入 `routerosinstall` 就可以打开 RouterOS 安装和管理菜单。

### 5. 进入菜单完成安装

执行：

```bash
sudo routerosinstall
```

建议按这个顺序操作：

1. 推荐直接进入 `0. 一键安装（引导式）`。
2. 脚本会先检查并安装 KVM、QEMU、socat、unzip、coreutils 等依赖。
3. 脚本会给出简要网络提醒，不默认刷屏输出全部链路明细。
4. 脚本会检测 `/root/routeros.img`；如果没有，会提示把镜像放进去后按回车重新检测。
5. 按提示配置 CPU、内存、virtio-net 队列、宿主机网口、RouterOS 网口名称和宿主机 LAN 回接。
6. 确认 RouterOS 预设值，默认不需要修改；确认后通过 QEMU Guest Agent 无网络导入预设置。
7. 选择是否开机自启动，最后确认是否立即执行并启动 RouterOS。

如果不想走引导式流程，也可以手动按 `1. 依赖安装`、`2. 网络检查`、`3. 虚拟机参数配置`、`4. RouterOS 预设置`、`5. RouterOS 启动/关闭/卸载/开机自启动设置` 的顺序操作。

RK3588 / EasePi-R2 常用配置示例：

```text
镜像: /root/routeros.img
CPU: 8
内存: 1024 MB 或 2048 MB
virtio-net 队列: 4
第 1 个 virtio-net: eth0，RouterOS 内重命名为 eth0，作为 WAN
第 2 个 virtio-net: eth1，RouterOS 内重命名为 eth1，作为 LAN
第 3 个 virtio-net: eth2，RouterOS 内重命名为 eth2，作为 LAN
第 4 个 virtio-net: eth3，RouterOS 内重命名为 eth3，作为 LAN
宿主机 LAN 回接虚拟网卡: 一键安装默认创建；手动配置时可按需关闭
宿主机网络持久化模式: networkd
```

如果在第 3 项里开启“宿主机到 RouterOS LAN 的回接虚拟网卡”，脚本会额外创建一块 virtio-net：

```text
RouterOS 内网口名: host-lan
RouterOS 归属: br-lan
宿主机侧桥: br-ros-host
宿主机获取地址方式: 通过 RouterOS LAN DHCP 获取 10.10.10.x
```

这个选项适合让 EasePi-R2 宿主机环境也从虚拟 RouterOS 的 LAN 出口上网、测速或访问 LAN 侧服务。开启后宿主机可能新增或切换默认路由，建议保留串口、HDMI、LTE 管理口或其他备用管理方式。

一键安装默认启用 QEMU Guest Agent 无网络预配置。启动时脚本会先启动 RouterOS，再通过 QGA 的 `guest-exec` 把 `/etc/routerosinstall/routeros-preset.rsc` 导入 RouterOS；这个能力来自 MikroTik CHR 的 [KVM guest agent 支持](https://help.mikrotik.com/docs/spaces/ROS/pages/18350234/Cloud%20Hosted%20Router%20CHR)。如果导入失败，会按设置的回滚等待时间停止虚拟机并释放宿主机网口。常用排查命令：

```bash
journalctl -u routeros-chr-bootstrap-apply.service -f
tail -f /var/log/routerosinstall-bootstrap.log
```

默认 RouterOS 预设置：

```text
WAN: eth0，DHCP 获取上级地址
LAN bridge: br-lan
LAN ports: eth1 eth2 eth3；开启宿主机 LAN 回接时会额外加入 host-lan
LAN IP: 10.10.10.1/24
DHCP: 10.10.10.100-10.10.10.200
NAT: LAN 出口 masquerade 到 WAN
```

接线测试时可以这样接：

```text
上级网线 -> EasePi-R2 eth0 -> RouterOS WAN
下级设备 -> EasePi-R2 eth1/eth2/eth3 -> RouterOS LAN
```

下级设备应能拿到 `10.10.10.x` 地址，并通过 `http://10.10.10.1/` 访问 RouterOS WebFig。

### 6. 进入和退出 RouterOS 控制台

虚拟机启动后，在宿主机命令行输入：

```bash
sudo routeros
```

即可进入 RouterOS 串口控制台。

退出控制台：

```text
Ctrl + ]
```

首次登录一般使用：

```text
用户名: admin
密码: 空
```

如果 RouterOS 版本要求首次设置密码，按控制台或 Web 页面提示设置即可。

### 7. 常用维护命令

查看服务状态：

```bash
systemctl status routeros-chr --no-pager
```

查看启动失败日志：

```bash
journalctl -u routeros-chr.service -n 80 --no-pager
```

手动启动、停止、重启：

```bash
systemctl start routeros-chr
systemctl stop routeros-chr
systemctl restart routeros-chr
```

## 9.sh 注意事项

- `9.sh` 当前使用 virtio-net + Linux bridge 方案，不是 PCIe 网卡直通。
- 被分配给 RouterOS 的宿主机物理网口会被 bridge/tap 接管，宿主机本身不会继续在这些口上直接拿 IP。
- “宿主机 LAN 回接虚拟网卡”在一键安装里默认开启；开启后宿主机侧 `br-ros-host` 会尝试通过 RouterOS LAN DHCP 获取地址和默认路由，手动配置时可关闭。
- 一键安装和菜单 5 的启动流程默认使用 QEMU Guest Agent 导入 RouterOS 预设置，不需要先从 RouterOS 里手动执行配置。
- 不要把当前 SSH 管理入口选给 RouterOS，除非你有串口、HDMI 或其他备用管理方式。
- 如果脚本发现所选网口当前带有 IP、路由或疑似管理入口，会要求输入 `YES` 后才继续。
- 脚本会生成尽力回滚脚本：`/etc/routerosinstall/last-hostnet-rollback.sh`。
- 启动 RouterOS 后，菜单会提示：输入 `routeros` 进入控制台，按 `Ctrl+]` 退出控制台。

## 0.sh 功能

- 智能识别当前系统，并切换 Debian / Ubuntu / Armbian 国内 APT 加速源。
- 一键开启 SSH root 密码登录。
- 查看当前接口、路由、DNS、networkd、服务状态。
- 配置多 WAN：支持 DHCP、静态地址、禁用、独立 metric。
- 配置 LAN：设置 `br-lan` 地址和绑定网卡。
- 配置 DHCP 地址池和 LAN 下发 DNS。
- 配置设备本身 DNS、dnsmasq 上游 DNS。
- 配置 NAT 出口，支持多 WAN 出口。
- 调整默认路由 metric。
- 开启 `lte4g` 管理入口：不作为默认备用出网，通过策略路由保证可从 LTE 地址访问 R2 的 SSH。
- WLAN 客户端模式：扫描 WiFi、选择 SSID、输入密码、配置较高 metric。
- WLAN 热点模式：配置热点名称、加密、密码，并可加入 `br-lan`。
- 重新加载 `systemd-networkd`、`dnsmasq`、`nftables`。
- 一键安装常用网络依赖。
- 一键扩容 rootfs：安装扩容依赖，支持输入目标大小、增量大小或扩展到磁盘最大可用空间。
- 备份与恢复配置，保留最近 5 份历史配置。

## 0.sh 持久化配置

`0.sh` 生成的主要配置会在重启后继续生效，常见路径如下：

- `/etc/easepi-r2-script/网络配置.env`
- `/etc/systemd/network/`
- `/etc/dnsmasq.d/easepi-r2-router.conf`
- `/etc/nftables.d/easepi-r2-nat.nft`
- `/etc/systemd/resolved.conf.d/easepi-r2-dns.conf`
- `/etc/hostapd/hostapd.conf`
- `/etc/wpa_supplicant/wpa_supplicant-*.conf`
- `/usr/local/sbin/easepi-r2-lte4g-policy-route.sh`

## 0.sh 注意事项

- APT 换源会备份原配置，并尽量保留第三方源；Armbian 源会改为国内镜像。
- NAT 只管理脚本自己的 nftables 表，不会全局 `flush ruleset`，方便后续继续添加分流规则。
- WLAN 客户端和热点模式互斥，切换模式时脚本会自动停用另一侧服务并调整 WAN/LAN 归属。
- 备份恢复只恢复脚本管理的文件，不会整目录删除系统原有配置。
