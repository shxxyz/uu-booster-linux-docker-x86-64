# UU Docker 技术审计与 Agent 维护手册

本文面向维护者和后续 Agent，记录用户版 README 刻意省略的调查证据、设计取舍、安全边界、失败历史和版本维护流程。用户安装说明见 [README.md](README.md)。

项目方案、脚本和文档主体由 OpenAI Codex 完成；需求、网络条件和实机结果由项目维护者提供并验证。

## 1. 当前状态快照

记录日期：2026-09-22。

### 官方插件锁

- 类型：`openwrt-x86_64`
- 版本：`v14.9.4`
- 固定下载地址：`https://uurouter-19.gdl.nieapps.com/uuplugin/openwrt-x86_64/v14.9.4/uu.tar.gz`
- 官方 API MD5：`760d0bead1a0fb8d459ced0f9ed087ac`
- 本项目锁定 SHA-256：`73e2eea46eb2d3cd3c34bf3945e1572efee5718b406014258d46e65e041b6dbc`
- 大小：`3142525` 字节
- 官方 API 返回的无 key 地址使用 HTTP；本次实测其证书有效的 HTTPS 形式与带 key 的 HTTPS 主地址返回相同文件，MD5、SHA-256、大小和归档结构与锁一致。本项目固定 HTTPS 形式；本次未重复测试明文 HTTP。
- 本次审计查询时，官方最新版本和 MD5 与以上锁一致。
- `v14.9.4` 通过包完整性和静态兼容性审计；尚未完成 Docker 构建、目标机启动和手机／游戏主机验收。下面的已验证运行结果属于旧版，不能当作新版的验收结果。

### 实机环境与结果

用户提供并实测的目标环境：

- Arch Linux x86_64
- Linux `6.12.41-2-lts`
- 物理接口 `enp3s0`，服务器地址 `10.0.0.80/24`
- 原主路由 `10.0.0.1`
- PS5 与手机通过 Wi-Fi 接入同一局域网，服务器走有线

旧版已经实机确认：

- Docker 镜像可构建，容器可健康运行；
- 当前网络允许服务器物理端口后的额外 macvlan MAC；
- 手机到有线服务器之间没有阻止该路径的客户端隔离；
- 手机 UU App 能发现、绑定和控制插件；
- PS5 把网关和 DNS 指向容器后能联网并实际加速。

最初的完整验收使用 `v14.2.2`。2026-08-28，用户先执行 `docker compose down`，更新仓库后运行 `sudo ./install.sh --apply` 部署 `v14.6.22`；原有命名 volume 被复用，不需要重新登录或绑定。新版容器健康运行，手机 App 控制和 PS5 实际加速均正常。

2026-08-29 对完整 nftables ruleset 和 conntrack 事件重新检查后，确认 `v14.6.22` 在 PS5 正在加速时会把该设备的 UDP DNS 流量 DNAT 到 `8.8.8.8`。此前依据 `iptables -t nat` 的空 `PREROUTING` 得出“没有 DNS DNAT”的结论是错误的：该命令只显示 iptables-nft 兼容表，没有显示 UU 创建的原生 nftables `XU_ACC_DEVICE_*_nat` 表。

尚未由用户报告或单独验收：

- Switch；
- PS5 的具体 NAT 类型；
- 宿主机或 Docker daemon 重启后的自动恢复；
- `uninstall.sh --apply --purge` 的完整实机还原检查；
- 移除精确 DNS 覆写后的目标机重建与基础解析回归；
- 当前锁定 `v14.9.4` 的镜像构建、容器健康、手机控制和 PS5/Switch 加速；
- 将来插件版本的实机兼容性；
- 游戏设备 IPv6 是否被主路由关闭或仍可能绕行。

不要把“本版本在这一套网络中成功”泛化为所有交换机、AP、网卡和内核都兼容。

## 2. 原始目标与不可破坏的约束

原始需求不是把服务器改造成主路由或旁路由，而是：

1. 在普通 Linux 服务器上运行 UU OpenWrt 插件；
2. 主要服务 PS5 和 Switch；
3. 宿主机默认路由、DNS 和普通流量路径不受 UU 影响；
4. 优先使用 Docker 隔离闭源插件的 TUN、路由和防火墙修改；
5. 不使用 `--privileged` 或 host network；
6. 安装和卸载默认 dry-run，只有显式 `--apply` 才写入；
7. 插件版本只通过经审计的仓库提交更新，不在目标机上自动改锁或追新；
8. 能明确卸载，并区分“保留绑定”和“彻底清理”；
9. 网络失败时允许使用可选 HTTP 代理，但公开模板不预设私人代理。

后续修改若破坏任意一项，必须在 README 和变更说明中显式披露，不能静默扩大宿主机影响面。

## 3. 最终架构和数据路径

```text
游戏主机
  IPv4 gateway + DNS = UU_CONTAINER_IP
          │
          │ 目标 MAC 为容器 macvlan MAC
          ▼
服务器物理网卡 ── Docker macvlan ── 容器网络命名空间
                                         │
                               eth0 → Linux bridge br-lan
                                         │
                         dnsmasq + UU 插件 + tun0 + netfilter
                                         │
                                         ▼
                                  原主路由 / Internet

宿主机自身：原 IP → 原默认网关，路径不经过 UU 容器
```

关键实现：

- Docker 在物理接口上建立 `macvlan` L2 bridge 网络，容器拥有独立 IP 和固定 MAC。
- 容器入口脚本创建真正的 Linux bridge `br-lan`，把 Docker 提供的 `eth0` 加入其中，并把容器 IP、MAC 和默认路由迁到 `br-lan`。这是为了满足闭源插件对 OpenWrt LAN 接口名和形态的假设。
- 插件只在容器网络命名空间内创建 TUN、策略路由和 nftables/iptables 规则。
- 独立 `dnsmasq` 在 `UU_CONTAINER_IP:53` 转发 DNS；游戏主机同时把网关和 DNS 指向容器。
- `/usr/sbin/uu` 是唯一持久卷，保存 `.sn`、`.uuplugin_uuid` 等绑定身份。
- `/tmp` 和 `/run` 是 tmpfs；插件每次启动从只读镜像内容复制到 `/tmp/uu` 后执行。
- `UU_SNAT_MODE=off` 只表示封装层不额外增加 `MASQUERADE`；闭源插件仍可能按自身逻辑写入 nat 表。

项目创建的 Docker 对象固定为：

- container：`netease-uu`
- network：`netease-uu-lan`
- image：`netease-uu-openwrt:local`
- volume：`netease-uu-state`
- local cache：`vendor/uu.tar.gz`，不提交 Git

## 4. 为什么选择 macvlan

需求要求局域网设备直接把容器当作 IPv4 网关，同时不在宿主机默认网络命名空间添加地址、路由和过滤规则。macvlan 为容器提供局域网可见的独立 MAC/IP，能把作为“网关”收到的任意三层目标流量交给容器。

代价和边界：

- 物理网卡、交换机和主路由必须接受同一物理端口后的额外 MAC；
- macvlan 通常不适合 Wi-Fi station 接口，所以目标服务器必须走有线；
- Linux 内核默认阻止 macvlan 容器直接与其父接口宿主通信；宿主机 ping 不通容器是预期隔离；
- 不应为了宿主可达性自动创建 host-side macvlan shim，因为这会改变宿主网络。

### 混杂模式与宿主物理接口

不需要在宿主机上手动或永久执行 `ip link set <parent> promisc on`。但“无需手动开启”不表示运行期间物理接口一定没有 `PROMISC` 标志，需要区分外部网络要求和 Linux 内核的动态行为。

外部二层网络方面，Docker 文档所说网络设备需要处理 macvlan 的“promiscuous mode”，核心要求是同一物理链路后能够学习和转发多个 MAC。普通物理交换机一般会自然学习；启用了端口安全的受管交换机、虚拟交换机和云网络可能拒绝额外源 MAC 或不把目标为容器 MAC 的帧送回该端口。当前实机已经成功完成手机发现和 PS5 加速，因此这套网卡、交换机和 AP 已满足该要求。

宿主 Linux 方面，当前配置有两层动作：

1. Docker 以 `macvlan_mode: bridge` 在物理父接口上创建具有独立 MAC 的容器接口。标准 macvlan 打开路径会先尝试二层转发卸载，否则通过 `dev_uc_add()` 把这个额外单播地址加入父接口；仅创建 macvlan 本身不等于无条件要求管理员预先开启混杂模式。
2. 容器入口脚本随后创建默认 `vlan_filtering=0` 的 Linux bridge `br-lan`，并把 macvlan 接口 `eth0` 加入该 bridge。Linux 6.12 的 bridge 代码会自动把这种 bridge 的端口置为混杂模式；macvlan 的 `macvlan_change_rx_flags()` 又会把 `IFF_PROMISC` 变化向下传到物理父接口。

因此在目标 Linux 6.12 环境中，容器运行时宿主物理接口 `enp3s0` 预计会显示 `PROMISC` 或非零 `promiscuity` 计数。这是内核按引用计数管理的运行时状态，不是项目写入的永久网卡配置。bridge、容器网络命名空间和 macvlan endpoint 被销毁时，对应引用会递减；`uninstall.sh --apply` 删除容器和 `netease-uu-lan` 后应恢复项目启动前的状态。若还有抓包程序、其他 bridge/macvlan 或虚拟化软件持有混杂引用，计数可能仍不为零，不能据此认定项目未还原。

可在安装前、容器运行时和卸载后分别检查：

```sh
ip -details link show dev enp3s0
```

这项状态变化会让网卡把交换机实际送到该物理端口的更多帧交给内核，但不等于交换机进行了端口镜像，也不会凭空把全局域网的所有单播流量送到服务器。若某环境只有手动执行 `promisc on` 后才能工作，应把它视为网卡单播过滤、驱动或虚拟交换机配置问题；不要把永久开启命令静默加入安装流程，并优先检查端口安全、MAC spoofing/forged-transmit 策略和多 MAC 限制。

### 为什么不是 Docker bridge

普通 Docker bridge 不会让局域网设备直接把容器当作同网段网关。要实现相同效果，需要宿主机端口映射、转发、NAT 或策略路由，违背“宿主网络不受影响”的约束。

### 为什么不是 host network

闭源插件会创建 TUN、路由规则和 netfilter 规则。`--network host --privileged` 会让这些变化直接进入宿主机，并将容器隔离基本清空，因此明确禁止。

### 为什么不能直接替换成 ipvlan L2

ipvlan L2 可以共用父接口 MAC，但内核按目标 IPv4/IPv6 地址把入站单播分发给 ipvlan 子接口。游戏主机把 UU 当网关时，帧的二层目标是网关 MAC，三层目标仍是公网地址，不是容器 IP；这类转发包不能作为普通容器地址流量稳定地交给该命名空间。

若坚持共用宿主 MAC，只能先让宿主网络栈接收，再添加主机侧地址、转发、策略路由或过滤规则把流量送入专用命名空间。这不是当前项目的隔离模型。

### 为什么桥接 VM 也不是“单 MAC”解法

普通桥接 OpenWrt VM 同样在服务器物理端口后出现虚拟 MAC。若网络明确限制每端口一个 MAC，可靠的完整隔离方案是增加一块专用物理网卡并直通给 VM 或专用命名空间。

## 5. 容器权限与安全边界

Compose 当前明确禁止或不提供：

- `privileged`；
- host network；
- host PID；
- Docker socket；
- 宿主目录挂载；
- 可写 root filesystem；
- 安装时修改宿主默认路由、DNS、sysctl、iptables/nftables 或 Docker daemon 配置。

容器删除所有默认 capability，只增加：

- `NET_ADMIN`：创建 bridge/TUN、路由和 netfilter；
- `NET_RAW`：插件的原始套接字与网络探测；
- `NET_BIND_SERVICE`：监听 DNS 53 端口。

另外只映射 `/dev/net/tun`，启用 `no-new-privileges`，限制 PID 和内存，并把网络 sysctl 限定在容器命名空间。

闭源 UU 进程仍以容器内 root 运行并持有上述网络能力。这套封装降低了宿主机影响范围，不等于证明闭源二进制安全。

Docker Engine 自身会在宿主机建立服务、`docker0` 和 Docker 防火墙链。项目不安装或卸载 Docker，也不把这些 Docker 固有变化宣传为“零宿主改动”。

### 镜像内容与尚未锁定的依赖

- 平台固定为 `linux/amd64`；
- 基础镜像标签为 `debian:trixie-20260803-slim`；
- 安装 `ca-certificates`、`dnsmasq-base`、`iproute2`、`iptables`、`mawk`、`nftables`、`procps`、`tar`、`tini`；
- 明确选择 `iptables-nft` / `ip6tables-nft`；
- Dockerfile 在解包前再次校验 `plugin.lock` 中的 UU SHA-256。

基础镜像尚未固定 digest，apt 依赖也没有逐包固定版本，所以目前只有 UU 插件输入被强锁，整个镜像并非字节级完全可复现。未来若补 digest 或软件包快照，应兼顾 Debian 安全更新与长期可构建性，并在目标机重新验证。

## 6. PID 1、DNS 和进程监管

- 镜像 `ENTRYPOINT` 使用 `/usr/bin/tini`，因此 Compose 不能再设置 `init: true`，否则会出现两层 tini。
- `dnsmasq` 使用 `--no-daemon` 在前台运行，入口脚本记录并监管其 PID。
- 选择该模式是为了避免给整个容器增加 `SETUID` / `SETGID`。在第一次实测中，`dnsmasq --user=root --group=root` 会因 capability 已裁剪而在 `setgroups`/组身份切换阶段失败。
- UU 插件退出后最多自动重试；短时间连续失败达到阈值后容器退出，让 `restart: unless-stopped` 接管。
- 容器停止时先向插件发送 `SIGINT`，等待后再发送 `SIGTERM`，同时终止 dnsmasq。
- 健康检查验证 TUN、IPv4 转发、ICMP redirect 设置、`br-lan`、默认路由、dnsmasq PID 和 UU PID。

如果未来改回 `dnsmasq --keep-in-foreground`，必须重新评估身份切换 capability，不能仅为了消除错误就增加 `--privileged`。

### dnsmasq 上游与 UU 的设备级 DNS DNAT

游戏主机在本项目的正常配置中把 DNS 指向 `UU_CONTAINER_IP`，所以容器仍需在该地址的 UDP/TCP 53 端口运行 dnsmasq。`DNSMASQ_UPSTREAM` 只指定 dnsmasq 的普通转发上游，同时作为 Compose 为容器自身配置的 DNS；它不是 UU 的配置项，也不能约束闭源插件随后写入的规则。

2026-08-29 在 `v14.6.22`、PS5 地址为 `10.0.0.11` 且正在加速时取得以下证据：

- `iptables -t nat -vnL PREROUTING` 为空，但完整 `nft -a list ruleset` 中存在独立的 `table ip XU_ACC_DEVICE_10.0.0.11_nat`；因此只查看 iptables-nft 兼容表会漏报；
- 设备级 mangle 表按 `iifname "br-lan" ip saddr 10.0.0.11 udp dport 53` 设置加速 mark，计数器已有流量；
- 设备级 nat 表按同一入口、源地址和 UDP/53 匹配，并执行 `dnat to 8.8.8.8`，现场计数器已有 `967` 个包；
- `conntrack -E` 显示原始方向是 `src=10.0.0.11 dst=10.0.0.10 ... dport=53`，回复方向却是 `src=8.8.8.8 dst=10.0.0.11 ... sport=53`，直接证明查询目的地址被透明改写；
- 同一设备的 IPv6 表还按源 MAC 丢弃 UDP/53，但现场没有观察到对应的 IPv6 DNS DNAT。

因此，只要这条规则处于活动状态，原本发往容器 dnsmasq 的 UDP 查询就会在进入本地 DNS 进程前被改写，dnsmasq 中的精确域名记录无法可靠生效。项目曾为 Twitch/PStream 重定向需求提供 `DNS_HOST_OVERRIDES`，但其成立前提已被现场数据否定；该变量、renderer 和测试于 2026-08-29 移除，`UU_UPSTREAM_DNS` 同时更名为语义更窄的 `DNSMASQ_UPSTREAM`。

不要通过抢 nftables hook 优先级、循环删除 UU 规则或与插件竞态来恢复覆写，这会改变闭源加速数据路径且难以稳定验证。如果需要自定义或分流 DNS，应在同一 LAN 上提供另一个独立 IP，并让游戏主机直接把 DNS 指向该地址，使同网段 DNS 流量在二层直达而不进入 UU 网关；仍需在目标网络实测，因为设备子网、IPv6 和主机网络设置都可能改变路径。

## 7. 官方插件获取与供应链边界

官方元数据接口：

```text
https://router.uu.163.com/api/plugin?type=openwrt-x86_64
```

2026-08-28 的接口行为分两种：普通请求返回 JSON；带 `Accept: text/plain` 时返回四个 CSV 字段，依次为带 `key1`/`key2` 的主 URL、MD5、无 key 的 `url_bak` 和空字段。签名参数是临时数据，不写入锁文件、日志或文档。

当时的无 key 备用地址为：

```text
http://uurouter-19.gdl.nieapps.com/uuplugin/openwrt-x86_64/v14.6.22/uu.tar.gz
```

当时对这个精确 HTTP 地址及其 HTTPS 形式分别进行了完整 GET：两者都返回 200，下载 `3133127` 字节，MD5、SHA-256、tar 顶层和带 key 主地址逐字节一致。新 `nieapps.com` 主机的 HTTPS 证书校验正常，因此当时的 `plugin.lock` 固定同一路径的 HTTPS 形式，不沿用 API 返回的明文协议。历史 `v14.2.2` 所在的 `uurouter.gdl04.netease.com` 与证书不匹配，旧版锁只能使用 HTTP；这个限制不再适用于当前主机。2026-09-22 的 `v14.9.4` 仍使用同一域名和 API 字段格式，现有解析器及 URL allowlist 无需改动。

普通安装的下载顺序和约束是：

1. 从 `plugin.lock` 读取固定版本、无 key URL、MD5、SHA-256 和大小，并验证 URL 只属于历史 `uurouter.gdl数字.netease.com` 或当前 `uurouter-数字.gdl.nieapps.com` 精确域名族，且路径和版本一致；
2. 通过 HTTPS API 检查最新版本；发现不同版本只输出 `NOTE`，不改变锁，也不自动下载新版；元数据查询失败或同版本 MD5 异常仍输出 `WARNING`；
3. 优先按锁中记录的协议下载固定 URL；维护者制作版本 bump 提交时，可在严格验证域名、路径和内容后，把当前 `nieapps.com` 备用地址固定为已实测可用的 HTTPS；
4. 仅当固定地址发生传输失败、且 API 返回的版本与 MD5 仍和锁完全一致时，才回退到带临时 key 的主地址；主地址的已知 `http://uurouter.gdl.netease.com` 会提升为 HTTPS；
5. 下载后同时校验锁定 MD5、SHA-256、大小和 tar 路径 allowlist，任一不符都拒绝构建；
6. 直连失败时才尝试 `.env` 中显式配置的 `DOWNLOAD_PROXY`。

`DOWNLOAD_PROXY` 也会映射为 Docker 构建期的 `HTTP_PROXY` / `HTTPS_PROXY`，供 Debian 依赖下载使用，但不会注入运行中的 UU 容器，不能把它理解为 UU 的前置代理。

当前包顶层必须严格只有：

```text
uu.conf
uuplugin
xtables-nft-multi
xuplugin-guardian
```

三个可执行文件都是静态链接 Linux x86-64 ELF；`uuplugin` 和 guardian 已 strip。

当前 `v14.9.4` 的固定无 key 地址使用证书有效的 HTTPS，仓库中预先记录的 SHA-256 仍是普通安装的内容完整性锚；传输内容不匹配时不会执行。制作新版本锁提交时尚无预先可信的新 SHA-256，首次信任仍依赖 UU 官方 HTTPS API 提供的 MD5、随后计算的 SHA-256 和人工审计；官方没有可验证的代码签名，因此不能证明闭源程序本身安全。历史 `v14.2.2` 无 key 主机只能使用 HTTP，已不再是当前锁的传输边界。

仓库不提供自动更新锁文件的脚本。上游版本只能在独立工作区中下载和审计，由维护者手动更新 `plugin.lock`、适配代码与本文件，并作为一个可复核的提交发布。目标机上的 `install.sh` 无论官方版本多新，都只能安装当前 checkout 已锁定的包。

### `v14.6.22` 升级审计（2026-08-28）

- 上游把 `url_bak` 从旧的 `uurouter.gdl数字.netease.com` 迁到 `uurouter-数字.gdl.nieapps.com`。脚本只增加这个精确域名族，不接受任意 `nieapps.com` 子域、查询参数、fragment、其他架构或其他归档路径。
- 新旧包顶层均严格只有 `uu.conf`、`uuplugin`、`xtables-nft-multi` 和 `xuplugin-guardian`。
- `uu.conf` 仅把版本从 `v14.2.2` 改为 `v14.6.22`；`uuplugin` 发生变化。`xtables-nft-multi` 和 `xuplugin-guardian` 与旧包逐字节一致，SHA-256 分别仍为 `9cd422fa3bc89b5ef855faba274cfa01ecd4478a64171dd95bf78ef5bd1e957f` 和 `0353279bc1c2542a5fac0bfa9f6dc8b71e94cdae17b70db23241348f8d7af23e`。
- 三个可执行文件仍是静态链接的 Linux x86-64 ELF。针对新 `uuplugin` 的命令、路径和设备字符串检查仍可见 `/dev/net/tun`、`br-lan`、iproute2 与 iptables/nftables 假设，未发现需要新增宿主挂载、设备节点、系统包或 capability 的证据；新增的部分 TCP DNAT/INPUT 规则模板仍在既有 `NET_ADMIN` 和 netfilter 范围内。
- 没有找到网易发布的该版本公开 changelog。以上只能支持“现有容器边界大概率仍兼容”的静态判断，目标服务器上的容器健康、手机控制、PS5 加速、DNS/netfilter 规则和宿主机不受影响仍必须实测。

### `v14.9.4` 升级审计（2026-09-22）

静态审计未发现与现有 Docker 封装不兼容的变化，可更新 `plugin.lock`；未发现需要修改镜像依赖、capability、挂载或入口脚本的证据。由于审计机为 macOS 且没有 Docker CLI，本次没有构建或执行新版，也没有目标机实测，运行兼容性仍待用户验收。

**下载与包结构：** 官方 API 返回 `v14.9.4` 和 MD5 `760d0bead1a0fb8d459ced0f9ed087ac`。分别完整下载签名 HTTPS 主地址及本节开头锁定的无 key HTTPS 地址，二者内容一致，大小 `3142525` 字节，SHA-256 `73e2eea46eb2d3cd3c34bf3945e1572efee5718b406014258d46e65e041b6dbc`。没有扩大 URL allowlist。tar 仍仅含四个普通文件，没有额外路径或链接。

| 文件 | 相对 `v14.6.22` 的变化 |
| --- | --- |
| `uu.conf` | 仅 `version=v14.6.22` → `version=v14.9.4`；`log_level=info` 不变 |
| `uuplugin` | `5620208` → `5636592` 字节，增加 `16384` 字节；新 SHA-256 为 `caaa7935cb3bb5d514d3ce7040a9f8520a817ee23dceb78c79c36b16fb690044` |
| `xuplugin-guardian` | 逐字节不变；SHA-256 仍为 `0353279bc1c2542a5fac0bfa9f6dc8b71e94cdae17b70db23241348f8d7af23e` |
| `xtables-nft-multi` | 逐字节不变；SHA-256 仍为 `9cd422fa3bc89b5ef855faba274cfa01ecd4478a64171dd95bf78ef5bd1e957f` |

**主程序的变化线索：** 没有找到该版本的官方公开 changelog。以下来自旧包 SHA-256 核验后的逐文件比较、ELF `.rodata` 字符串差集及简单混淆日志解码，属于静态线索，不能据此确定服务端开关、默认行为、修复范围或性能收益。

- 新增主链路／TCP channel 的 QUIC 和混淆配置：`quic_config`、`tun2proxy_mainlink_quic`、`tun2proxy_tcpchannel_quic`、对应 `_obfs` 开关、`quic_max_streams`、`quic_max_stream_data`、`quic_idle_timeout_ms`；新增 `select_proto` 和 `proto fallback` 日志，表明传输协议选择／回退逻辑有所扩展。不是本封装新增的环境变量，不应直接写入 `.env` 并假定生效。
- 新增 `check_and_kill_slow_conns`、`slow_conn_kill_speed/duration/cnts` 等键，以及按速度窗口清理慢 TCP 通道的日志；网络类型切换日志新增清理旧测速记录的描述。
- TCP／域名质量上报格式加入 `proto`、`srv_ip`、`srv_port`、`conn_ms`、`conn_ok` 等字段，上报标识改为 `quality_report_proxy_v2` / `quality_report_tproxy_v2`；域名／URI 日志新增长度限制。
- 主链路发送相关日志改为 pending buffer / SSL write 错误，TCP 通道新增 client/server half-close 日志，提示发送缓冲和连接关闭处理有变化。
- 部分内置 IPv4 字符串变化；不能仅凭这些地址判断节点覆盖或游戏支持范围。构建时间字符串由 `2026-08-24 13:17:12` 改为 `2026-09-16 13:09:43`，它不是经过认证的发布日期。

**封装兼容性依据：** 三个可执行文件仍为静态链接 Linux x86-64 ELF；`uuplugin` 无动态加载器／共享库依赖，编译器标识仍为 OpenWrt GCC 7.3.0。比较 `.rodata` 中匹配网络命令、模块加载和系统路径的 175 条字符串，集合完全一致；`/dev/net/tun`、`br-lan`、`/var/run/uuplugin.pid`、`/usr/sbin/uu/`、`.sn`、`.uuplugin_uuid`、`uu.update`、`uu.uninstall` 均保留。iptables/nftables DNS DNAT 模板仍在，不能把此次升级当作已取消 DNS 劫持。字符串不变只支持“未发现接口变化”，不能证明机器码逻辑或运行时资源需求完全不变。

**复核方法：** 从 ELF section headers 定位 `.rodata`，提取长度至少 4 的连续 ASCII 可打印字符串，按集合比较，排除 `.text` 中指令字节误识别产生的噪声；新包新增 75 条、移除 52 条。175 条子集的筛选式为 `iptables|ip6tables|nft |ip rule|ip route|br-lan|/dev/|/proc/|/sys/|/usr/|/etc/|/tmp/|/var/|uu\.update|uu\.uninstall|modprobe|insmod|mount |sysctl`。部分以 `/` 包裹的日志按 95 个可打印 ASCII 字符循环减 13 后可读，例如恢复为 `quic env mainlink:%d tcpchannel:%d ...`；这只是日志混淆解码，不是完整反编译。

**验证与复查：** 本次检查官方 API 解析、锁字段、MD5/SHA-256/大小、tar allowlist、ELF 静态属性、Shell 语法、Compose YAML 语法和安装／卸载 dry-run；还将缓存路径指向独立 `tmp/` 目录，直接调用现有 `ensure_locked_plugin`，实际完成从官方 API 查询到新锁包下载、全项校验的流程。没有执行 `install.sh --apply` 或新版二进制。目标机更新后必须检查健康状态、手机控制、PS5/Switch 加速，并在加速期间查看完整 `nft -a list ruleset`；尤其留意新传输策略的连通性、慢连接重试和实际 DNS 目标。绑定卷沿用原有配置，保留旧版本提交以便重新构建回退。

## 8. 官方 OpenWrt 安装器审计

2026-08-23 的官方百科指向 2026-07-15 版安装脚本。其 OpenWrt 分支会：

1. 建立 `/usr/sbin/uu/`；
2. 下载并执行官方卸载脚本来清理旧版本；
3. 下载 `uuplugin_monitor.sh`，写入 router/model 配置并以 root 后台运行；
4. 建立 `/etc/rc.d/S99uuplugin`，目标脚本依赖 `/etc/rc.common`；
5. monitor 从官方 API 下载包到 `/tmp/uu`，按 API MD5 校验后执行；
6. 监控 `uu.update` / `uu.uninstall`，允许服务端触发更新或卸载。

不能在 Arch 宿主机上原样执行该安装器：Arch 没有 OpenWrt 的启动体系和默认 `br-lan`，而且官方脚本存在 HTTP 或关闭 TLS 校验的回退下载路径。

本项目不运行 monitor：

- 收到 `uu.update` 时只记录日志并删除标记，继续使用当前锁定版本，直到安装经审计的仓库 bump；
- 收到 `uu.uninstall` 时只删除持久化绑定身份并停止；
- 版本更新必须先形成仓库提交，再由用户拉取并重新构建镜像。

## 9. Linux 闭源二进制静态审计

从字符串、命令模板和配置路径可确认 `uuplugin` 会：

- 打开 `/dev/net/tun`，创建和配置 `tun0`；
- 执行 `ip route`、`ip rule`，使用 fwmark 和独立路由表；
- 写入 iptables/nftables 的 filter、mangle、nat 规则，包括 MARK、DNAT、DNS DNAT 和 FORWARD；
- 尝试加载 `tun`、`nfnetlink`、`nf_conntrack_netlink`；
- 读取 `/proc/net/arp`、dnsmasq lease 和 conntrack 信息识别设备；
- 使用 `/usr/sbin/uu/` 保存 `.sn`、`.uuplugin_uuid` 等身份；
- 假定 LAN 接口名为 `br-lan`。

这正是容器必须拥有独立网络命名空间、又不能使用 host network 的原因。未来版本若新增文件、系统命令、设备节点、capability 或宿主挂载需求，应默认视为安全边界变化，先审计再适配。

## 10. Mac 版 2.8.14 运行时对照

该部分只用于理解 UU 的另一种数据路径，Mac App 不属于仓库，也绝不能提交到 GitHub。

在正在加速 PS5 的 Mac 上进行了只读检查，没有停止 UU 或修改网络。工作区副本与实际运行副本的主程序、提权助手 SHA-256 分别一致。

### 包与进程

- App：`UUBooster 2.8.14 (264)`，universal x86_64/arm64 Mach-O；
- 用户进程：`/Applications/UUBooster.app/Contents/MacOS/UUBooster`；
- root LaunchDaemon：`/Library/PrivilegedHelperTools/com.netease.uumac.helper`；
- Team ID：`PU9BNSBJW7`；
- App 通过 `SMPrivilegedExecutables` 安装 XPC 提权助手；
- 包内没有 Network Extension，助手直接使用 `com.apple.net.utun_control`。

### 现场网络状态

- `en0` 原地址：`10.0.0.3/24`；
- UU 在同一 `en0` 上增加：`172.22.0.246/16`；
- 两个地址使用同一个 Wi-Fi MAC，没有额外虚拟以太网 MAC；
- PS5：`172.22.1.246/16`，网关 `172.22.0.246`，DNS `6.6.6.6`；
- PS5 以自己的 MAC 出现在 `en0` 邻居表，说明两台设备是同一 AP 上的两个普通 station，Mac 没有透传 PS5 源 MAC；
- `net.inet.ip.forwarding=1`，IPv6 forwarding 保持 `0`；
- 公网路由拆分后指向 `utun8`，`utun8` 使用 `192.0.0.1`；
- `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 作为局域网绕行范围；
- Wi-Fi 系统 DNS 被全局改为 `6.6.6.6`；HTTP、HTTPS、SOCKS 和 PAC 系统代理保持关闭。

`UUBooster` 持有 utun 控制套接字、监听 `192.0.0.1` 并建立真实外连。日志同时出现本机虚拟入口 `192.0.0.1` 和 PS5 源地址 `172.22.1.246`；PS5 会话可见 `sniproxy` / `sproxy` 路径。

### 提权助手行为

助手的类名、命令模板和错误文本包含：

- 创建 TUN；
- 写 `net.inet.ip.forwarding=1`；
- `ifconfig ... alias` 添加/移除地址；
- `route` 添加/移除 include/exclude 路由；
- 保存/恢复系统 DNS；
- HUP `mDNSResponder`；
- 在 `/Library/Application Support/UUBooster/` 保存 PID、DNS 和路由状态。

未以 root 导出 PF 规则，也没有通过停止加速验证完整自动回滚。运行时数据、依赖和命令模板未显示 PF 是这个版本的必要组件，但不应把“未发现”写成绝对不存在。

### 对 Docker 设计的意义

Mac 现场证明了同一 Wi-Fi 二层可承载不同 CIDR，也证明当时无线客户端间没有隔离；它没有证明服务器有线端口能学习第二个 MAC，因为 Mac 只在自己的既有 Wi-Fi MAC 上增加 IP。

Mac 版还会接管 Mac 自身公网路由和 DNS，不满足本项目“宿主机路径不变”的约束，因此只能作为协议行为参考，不能照搬其部署方式。

## 11. 非官方旧 Docker 参考实现

历史参考：`dianqk/uuplugin`。

审计时其最后提交为 2021-02-06，固定使用 OpenWrt 19.07.6，容器启动时在线下载并执行变化中的安装脚本，并要求 `--privileged`。它能作为“单网口 macvlan 旁挂模式曾被使用”的历史证据，但不能直接复用：

- 基础 OpenWrt 和插件流程过旧；
- 无当前包的可复现锁；
- 权限过大；
- 允许运行时远程脚本变化；
- 不满足宿主机清洁安装与明确卸载要求。

## 12. 首次实测故障与修复

首次在目标 Arch 服务器运行时，容器反复以状态 5 重启，日志包含：

```text
Tini is not running as PID 1 ...
dnsmasq: failed to change group-id to root: Operation not permitted
```

根因分为两项：

1. Dockerfile 已把 tini 放在 ENTRYPOINT，Compose 又设置 `init: true`，形成两层 tini；
2. 容器先 `cap_drop: ALL`，`dnsmasq --user=root --group=root` 仍尝试组身份操作，但没有 `SETGID`。

最终修复：

- 删除 Compose 的 `init: true`，只保留镜像内 tini 为 PID 1；
- dnsmasq 改用 `--no-daemon`，不执行用户/组切换；
- 不增加 `SETUID`、`SETGID` 或更宽权限；
- 入口脚本直接记录、健康检查并监管 dnsmasq PID。

用户同步修复并重建后，容器成功运行，随后完成手机控制和 PS5 加速验证。未来重构 PID 1 或 dnsmasq 启动方式时必须保留这条回归记录。

## 13. 文件职责

| 文件 | 职责 |
| --- | --- |
| `README.md` | 面向用户的安装、绑定、使用、更新和卸载说明 |
| `AUDIT.md` | 技术证据、设计决策、风险边界和 Agent 维护手册 |
| `.env.example` | 可公开的无秘密配置模板 |
| `plugin.lock` | 当前审计插件的固定无 key URL、版本、MD5、SHA-256 和大小 |
| `Dockerfile` | 构建运行环境并执行包内 SHA-256 检查 |
| `compose.yaml` | macvlan、capability、TUN、只读文件系统、卷和健康检查 |
| `install.sh` | dry-run 默认；目标机检查、官方包校验、构建和健康等待 |
| `uninstall.sh` | dry-run 默认；删除项目 Docker 对象，可选清除绑定和缓存 |
| `scripts/lib.sh` | 官方 API、下载、代理、hash、archive allowlist 和 Compose 封装 |
| `scripts/container-entrypoint.sh` | 建立 `br-lan`、启动 DNS/插件、信号和重启监管 |
| `scripts/healthcheck.sh` | 容器内运行状态检查 |
| `.gitignore` / `.dockerignore` | 排除本地配置、闭源包、Mac App、日志和无关构建上下文 |
| `LICENSE` | 本项目自有脚本和文档采用的 WTFPL Version 2 全文 |

## 14. 后续 Agent 的上游版本 bump 流程

UU 发布新版本时，版本 bump 必须作为一次独立、可复核的仓库变更完成，不能在用户目标机上自动改锁。建议流程：

1. 先完整阅读本文件、`plugin.lock`、`scripts/lib.sh`、入口脚本和 Compose；
2. 使用带 `Accept: text/plain` 的官方 API 查询版本，并把响应保存到项目 `tmp/` 下的临时文件；记录版本和官方 MD5，但不要把带 `key1` / `key2` 的签名 URL 写入仓库、日志或文档；
3. 在 `tmp/` 中通过 API 返回的签名 HTTPS 主地址下载候选包，校验官方 MD5，并确认归档路径仍严格符合 allowlist；
4. 核对 `url_bak` 的主机、协议、查询参数和版本；单独验证无 key 地址可下载相同内容，优先实测证书有效的 HTTPS 形式，再计算 SHA-256 和大小；
5. 对新旧包运行 `file`、归档列表、hash 比较和针对性 `strings` 审计；
6. 特别检查是否改变 TUN 名称、`br-lan` 假设、PID 文件、身份文件、更新标记、iproute2/netfilter 命令或所需设备节点；
7. 若包新增文件、系统依赖、设备节点或 capability，先解释原因并更新安全模型，不能直接放宽；
8. 审计完成后手动更新 `plugin.lock`、必要的下载域名 allowlist、适配代码和本文件；不要新增自动改锁或自动追新的用户入口；
9. 运行 Shell/YAML 静态检查、回归测试和 Docker 构建；
10. 在目标服务器检查健康状态、容器内接口、路由和规则；
11. 用手机 App 完成发现和控制，再用 PS5/Switch 做实际联网与加速；
12. 核对宿主机默认路由、DNS、sysctl 和防火墙没有因项目改变；
13. 把锁文件、适配和审计记录放在同一个版本 bump 提交中，绝不提交 `vendor/uu.tar.gz` 或 `tmp/` 内容。用户只需拉取该提交后运行 `install.sh --apply`。

必须保留的行为：

- 安装和卸载默认只报告，写入需要 `--apply`；
- 普通安装遇到官方新版时只输出 `NOTE`，继续使用 `plugin.lock` 的固定版本；
- 同版本官方 MD5 变化时输出 `WARNING`，且绝不自动改锁；已有缓存只能在锁定 SHA-256 仍匹配时继续使用；
- 插件 tar 出现额外路径时拒绝继续；
- 不自动执行 UU monitor 或未知下载脚本；
- 不使用 `--privileged`、host network 或 Docker socket；
- 不自动修改宿主机网络；
- 不把 `.env`、闭源包、Mac App、日志或用户身份文件提交 Git。

## 15. 验证清单

### 不需要目标机的静态检查

```sh
sh -n scripts/container-entrypoint.sh scripts/healthcheck.sh
bash -n install.sh uninstall.sh scripts/lib.sh
./install.sh
./uninstall.sh
```

如果本机有 Docker，还应运行：

```sh
docker compose --env-file .env -f compose.yaml config
```

### 目标 Linux 服务器

```sh
./install.sh --apply
docker compose ps
docker compose logs --tail 200 uu
docker inspect --format '{{.State.Health.Status}}' netease-uu
docker exec netease-uu ip address show br-lan
docker exec netease-uu ip rule show
docker exec netease-uu nft list ruleset
```

验收必须覆盖：

- 容器为 `healthy` 且不反复重启；
- `br-lan` 拥有预期 IP/MAC，默认路由正确；
- dnsmasq 和 UU PID 均存活；
- 未被 UU 设备级规则改写的查询能通过 `DNSMASQ_UPSTREAM` 正常解析；
- 加速期间从完整 nftables ruleset 和 conntrack 核对游戏设备的实际 DNS 目标，不能依据空的 iptables-nft `PREROUTING` 下结论；
- 手机 App 可以发现和控制；
- 游戏主机能联网并出现实际加速流量；
- 宿主机仍使用原 IP、默认网关和 DNS；
- 重启 Docker/宿主机后绑定与服务恢复；
- 卸载只删除列出的项目对象，`--purge` 才删除绑定卷和缓存。

## 16. 公开仓库边界

应提交：

- 脚本、Dockerfile、Compose、`.env.example`、`plugin.lock`、README、本审计文档和 `LICENSE`。

不得提交：

- `.env`；
- `vendor/uu.tar.gz` 或解包后的闭源文件；
- `UUBooster.app`；
- UU 日志、缓存、账号、SN、UUID 或设备身份；
- 本地 `tmp/` 和 `.DS_Store`。

仓库不再分发 UU 闭源二进制；安装时从官方服务下载。项目自身的脚本和文档采用 WTFPL Version 2，许可证只覆盖本仓库自有内容，不覆盖网易 UU 的闭源程序、名称或商标。

## 17. 参考资料

- [UU 官方 OpenWrt 插件百科](https://router.uu.163.com/app/v3/baike/public/5f963c9304c215e129ca40e8)
- [UU 官方 x86_64 插件元数据 API](https://router.uu.163.com/api/plugin?type=openwrt-x86_64)
- [Docker macvlan 文档](https://docs.docker.com/engine/network/drivers/macvlan/)
- [Docker ipvlan 文档](https://docs.docker.com/engine/network/drivers/ipvlan/)
- [Docker Compose services 文档](https://docs.docker.com/reference/compose-file/services/)
- [Linux 内核 ipvlan 文档](https://docs.kernel.org/networking/ipvlan.html)
- [Linux 内核 IPVLAN Kconfig 说明](https://github.com/torvalds/linux/blob/master/drivers/net/Kconfig)
- [Linux 6.12 macvlan 实现](https://github.com/torvalds/linux/blob/v6.12/drivers/net/macvlan.c)
- [Linux 6.12 bridge 混杂模式管理](https://github.com/torvalds/linux/blob/v6.12/net/bridge/br_if.c)
- [dnsmasq 官方手册](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
- [Debian trixie dnsmasq-base 2.91-1+deb13u1](https://packages.debian.org/stable/dnsmasq-base)
- [Codming：PS5 无采集卡推流国内直播平台完整教程](https://codming.com/posts/ps5-streaming-to-chinese-platforms/)
- [历史参考实现 dianqk/uuplugin](https://github.com/dianqk/uuplugin)
