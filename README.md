# EasePi-R2-Script

EasePi-R2 中文脚本集合。当前主要脚本是 `0.sh`，用于在 Debian / Armbian 系统上快速配置 EasePi-R2 的网络、SSH、APT 加速源和基础路由功能。

## 使用方式

```bash
sudo bash 0.sh
```

建议第一次运行前保留 HDMI、本地串口或另一条可用管理入口，避免网络配置切换时 SSH 中断后无法继续操作。

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
- 备份与恢复配置，保留最近 5 份历史配置。

## 持久化配置

脚本生成的主要配置会在重启后继续生效，常见路径如下：

- `/etc/easepi-r2-script/网络配置.env`
- `/etc/systemd/network/`
- `/etc/dnsmasq.d/easepi-r2-router.conf`
- `/etc/nftables.d/easepi-r2-nat.nft`
- `/etc/systemd/resolved.conf.d/easepi-r2-dns.conf`
- `/etc/hostapd/hostapd.conf`
- `/etc/wpa_supplicant/wpa_supplicant-*.conf`
- `/usr/local/sbin/easepi-r2-lte4g-policy-route.sh`

## 注意事项

- APT 换源会备份原配置，并尽量保留第三方源；Armbian 源会改为国内镜像。
- NAT 只管理脚本自己的 nftables 表，不会全局 `flush ruleset`，方便后续继续添加分流规则。
- WLAN 客户端和热点模式互斥，切换模式时脚本会自动停用另一侧服务并调整 WAN/LAN 归属。
- 备份恢复只恢复脚本管理的文件，不会整目录删除系统原有配置。
