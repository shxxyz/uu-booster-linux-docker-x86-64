# UU Docker 技术审计与 Agent 维护手册

本文面向维护者和后续 Agent，记录用户版 README 刻意省略的调查证据、设计取舍、安全边界、失败历史和升级流程。用户安装说明见 [README.md](README.md)。

项目方案、脚本和文档主体由 OpenAI Codex 完成；需求、网络条件和实机结果由项目维护者提供并验证。

## 1. 当前状态快照

记录日期：2026-08-28。

### 官方插件锁

- 类型：`openwrt-x86_64`
- 版本：`v14.6.22`
- 固定下载地址：`https://uurouter-19.gdl.nieapps.com/uuplugin/openwrt-x86_64/v14.6.22/uu.tar.gz`
- 官方 API MD5：`a35ec2319472d54620af047d05d41640`
- 本项目锁定 SHA-256：`a1357032179379a21dc38d0c0fe6da5c35967c8c85920b924c8200d2530b8533`
- 大小：`3133127` 字节
- 官方 API 返回的无 key 地址使用 HTTP；同一路径的 HTTP、证书有效的 HTTPS 和带 key 主地址均实测返回相同文件，大小、MD5、SHA-256 和归档结构与锁一致。本项目固定其 HTTPS 形式。
- 本次执行 `./update.sh --apply --no-restart` 后，官方最新版本和 MD5 与 `plugin.lock` 一致。

### 实机环境与结果

用户提供并实测的目标环境：

- Arch Linux x86_64
- Linux `6.12.41-2-lts`
- 物理接口 `enp3s0`，服务器地址 `10.0.0.80/24`
- 原主路由 `10.0.0.1`
- PS5 与手机通过 Wi-Fi 接入同一局域网，服务器走有线

已经实机确认：

- Docker 镜像可构建，容器可健康运行；
- 当前网络允许服务器物理端口后的额外 macvlan MAC；
- 手机到有线服务器之间没有阻止该路径的客户端隔离；
- 手机 UU App 能发现、绑定和控制插件；
- PS5 把网关和 DNS 指向容器后能联网并实际加速。

最初的完整验收使用 `v14.2.2`。2026-08-28，用户先执行 `docker compose down`，更新仓库后运行 `sudo ./install.sh --apply` 部署 `v14.6.22`；原有命名 volume 被复用，不需要重新登录或绑定。新版容器健康运行，手机 App 控制和 PS5 实际加速均正常。

在新版已为 PS5 开启加速时，检查 nat `PREROUTING` 中目标端口 53 的规则没有输出，说明当时 UU 没有把该设备的 DNS 查询 DNAT 到其他服务器。此前看到的 `DOCKER_OUTPUT`、`127.0.0.11` 规则只服务于容器自身的 Docker 嵌入式 DNS，不属于 PS5 入站路径。

尚未由用户报告或单独验收：

- Switch；
- PS5 的具体 NAT 类型；
- 宿主机或 Docker daemon 重启后的自动恢复；
- `uninstall.sh --apply --purge` 的完整实机还原检查；
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
6. 安装和更新默认 dry-run，只有显式 `--apply` 才写入；
7. 能明确卸载，并区分“保留绑定”和“彻底清理”；
8. 网络失败时允许使用可选 HTTP 代理，但公开模板不预设私人代理。

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

### 精确 DNS 覆盖

项目提供可选的 `DNS_HOST_OVERRIDES`，用于把少量精确 FQDN 映射到 `UU_LAN_SUBNET` 内的 IPv4。选择环境变量而不是额外 DNS sidecar、宿主 DNS 或原始 dnsmasq 配置挂载，是因为当前用途只有少量 Twitch 推流入口；这种方式不增加 MAC、宿主端口、目录挂载或新的长期状态。

公开格式为逗号分隔的 `hostname=IPv4`：

```text
DNS_HOST_OVERRIDES=ingest.global-contribute.live-video.net=10.0.0.80
```

`install.sh --apply` 会先在宿主侧调用同一个独立 renderer 做 fail-fast 检查；renderer 也被复制进镜像，由入口脚本在 dnsmasq 启动前重新执行，避免绕过安装脚本直接启动容器时失去校验。处理规则如下：

- 最多 32 项，不允许空项、空格、通配符、额外等号、单标签主机名或项目保留的 `netease-uu.invalid` 内部后缀；
- 域名转为小写并移除一个末尾根点；每个 label 和总长度按普通 ASCII FQDN 边界验证；
- IPv4 每个 octet 必须合法，拒绝未指定、loopback、组播和保留高地址；
- 目标必须是 `UU_LAN_SUBNET` 内非网络地址、非广播地址，并且不能等于 `UU_CONTAINER_IP`；
- 重复域名、冲突或任意非法输入都会让容器 fail closed，不会带着部分配置启动；
- 只向 `/run/dnsmasq-overrides.conf` 写入经过验证的本地记录，文件位于容器 tmpfs；写完先由 `dnsmasq --test` 检查，再用于启动，并在拉起 dnsmasq 和闭源 UU 前从进程环境中删除原变量；
- 没有列出的域名继续交给 `UU_UPSTREAM_DNS`，宿主机和不使用 UU DNS 的设备不受影响。

不开放任意 dnsmasq directive，也不直接把环境变量拼接成 shell 命令。不能把原域名直接写成仅含 IPv4 的 `host-record`：镜像中的 dnsmasq 2.91 会把同名 AAAA 继续转发上游，可能产生 IPv6 绕行。也不能简单使用 `local=/原域名/`，因为它还会把该名字下的子域当成本地域。

renderer 因此为每项生成一个 `dns-override-N.netease-uu.invalid` 本地主机记录，并把用户指定的原域名精确 CNAME 到这个保留 `.invalid` 名字；只有合成的 `netease-uu.invalid` 域被标为 local。2026-08-28 的 Debian trixie 包为 `dnsmasq-base 2.91-1+deb13u1`；用与 Debian `orig.tar.gz` SHA-1 一致的官方 2.91 源码在本机编译实测：原域名 A 响应包含 CNAME 和目标 IPv4，AAAA 只包含 CNAME、没有公网 IPv6，原域名的子域仍转发上游。验收必须复查这三项以及无关域名解析。

`v14.6.22` 闭源二进制仍含有按设备动态插入 UDP 53 DNAT 的命令模板；当前实机未启用该规则不代表未来版本不会启用。每次插件升级后，应在 PS5 正在加速时检查 nat `PREROUTING`。如果出现针对该设备源地址的 53 端口 DNAT，内置 dnsmasq 可能被绕过；不要用规则顺序竞态修补，应改为同网段独立 DNS 地址，并让游戏主机直接查询它。

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

对这个精确 HTTP 地址及其 HTTPS 形式分别进行了完整 GET：两者都返回 200，下载 `3133127` 字节，MD5、SHA-256、tar 顶层和带 key 主地址逐字节一致。新 `nieapps.com` 主机的 HTTPS 证书校验正常，因此 `plugin.lock` 固定同一路径的 HTTPS 形式，不沿用 API 返回的明文协议。历史 `v14.2.2` 所在的 `uurouter.gdl04.netease.com` 与证书不匹配，旧版锁只能使用 HTTP；这个限制不再适用于当前主机。

普通安装的下载顺序和约束是：

1. 从 `plugin.lock` 读取固定版本、无 key URL、MD5、SHA-256 和大小，并验证 URL 只属于历史 `uurouter.gdl数字.netease.com` 或当前 `uurouter-数字.gdl.nieapps.com` 精确域名族，且路径和版本一致；
2. 通过 HTTPS API 检查最新版本；发现不同版本只输出 warning，不改变锁，也不自动下载新版；
3. 优先按锁中记录的协议下载固定 URL；API 为当前 `nieapps.com` 备用地址返回 HTTP 时，升级流程在严格验证域名和路径后将其固定为已实测可用的 HTTPS；
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

当前 `v14.6.22` 的固定无 key 地址使用证书有效的 HTTPS，仓库中预先记录的 SHA-256 仍是普通安装的内容完整性锚；传输内容不匹配时不会执行。显式升级时尚无预先可信的新 SHA-256，首次信任仍依赖 UU 官方 HTTPS API 提供的 MD5、随后计算的 SHA-256 和人工审计；官方没有可验证的代码签名，因此不能证明闭源程序本身安全。历史 `v14.2.2` 无 key 主机只能使用 HTTP，已不再是当前锁的传输边界。

`update.sh --apply` 与普通安装不同：它通过 API 返回的带临时 key 主地址下载新包，并强制使用 HTTPS；校验 API MD5 和归档路径后计算新 SHA-256，再把同版本的无 key `url_bak` 写入 `plugin.lock`，供后续普通安装固定使用。若备用地址属于已验证的当前 `nieapps.com` 精确域名族，则把协议提升为 HTTPS；同版本但 MD5 突变时不会自动改锁。

### `v14.6.22` 升级审计（2026-08-28）

- 上游把 `url_bak` 从旧的 `uurouter.gdl数字.netease.com` 迁到 `uurouter-数字.gdl.nieapps.com`。脚本只增加这个精确域名族，不接受任意 `nieapps.com` 子域、查询参数、fragment、其他架构或其他归档路径。
- 新旧包顶层均严格只有 `uu.conf`、`uuplugin`、`xtables-nft-multi` 和 `xuplugin-guardian`。
- `uu.conf` 仅把版本从 `v14.2.2` 改为 `v14.6.22`；`uuplugin` 发生变化。`xtables-nft-multi` 和 `xuplugin-guardian` 与旧包逐字节一致，SHA-256 分别仍为 `9cd422fa3bc89b5ef855faba274cfa01ecd4478a64171dd95bf78ef5bd1e957f` 和 `0353279bc1c2542a5fac0bfa9f6dc8b71e94cdae17b70db23241348f8d7af23e`。
- 三个可执行文件仍是静态链接的 Linux x86-64 ELF。针对新 `uuplugin` 的命令、路径和设备字符串检查仍可见 `/dev/net/tun`、`br-lan`、iproute2 与 iptables/nftables 假设，未发现需要新增宿主挂载、设备节点、系统包或 capability 的证据；新增的部分 TCP DNAT/INPUT 规则模板仍在既有 `NET_ADMIN` 和 netfilter 范围内。
- 没有找到网易发布的该版本公开 changelog。以上只能支持“现有容器边界大概率仍兼容”的静态判断，目标服务器上的容器健康、手机控制、PS5 加速、DNS/netfilter 规则和宿主机不受影响仍必须实测。

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

- 收到 `uu.update` 时只记录日志并要求维护者运行 `update.sh --apply`；
- 收到 `uu.uninstall` 时只删除持久化绑定身份并停止；
- 版本更新必须显式进行并重新构建镜像。

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
| `update.sh` | dry-run 默认；查询新版本、显式下载和更新锁 |
| `uninstall.sh` | dry-run 默认；删除项目 Docker 对象，可选清除绑定和缓存 |
| `scripts/lib.sh` | 官方 API、下载、代理、hash、archive allowlist 和 Compose 封装 |
| `scripts/container-entrypoint.sh` | 建立 `br-lan`、启动 DNS/插件、信号和重启监管 |
| `scripts/healthcheck.sh` | 容器内运行状态检查 |
| `scripts/render-dns-overrides.sh` | 严格验证 `DNS_HOST_OVERRIDES` 并生成只含精确记录的临时 dnsmasq 配置 |
| `tests/test-dns-overrides.sh` | DNS renderer 的正常、边界、拒绝和原子写入回归测试 |
| `.gitignore` / `.dockerignore` | 排除本地配置、闭源包、Mac App、日志和无关构建上下文 |
| `LICENSE` | 本项目自有脚本和文档采用的 WTFPL Version 2 全文 |

## 14. 后续 Agent 的插件更新流程

UU 发布新版本时，不要直接运行 `update.sh --apply` 后宣告完成。建议流程：

1. 先完整阅读本文件、`plugin.lock`、`scripts/lib.sh`、入口脚本和 Compose；
2. 运行 `./update.sh`，记录锁定版本与官方最新版本；
3. 用 `./update.sh --apply --no-restart` 下载并更新锁，但暂不运行；
4. 核对 API 主 URL 与 `url_bak` 的主机、协议、查询参数、版本，以及 MD5、SHA-256、大小和 tar 路径 allowlist；临时 key 不得写入仓库；
5. 对新旧包运行 `file`、归档列表和针对性 `strings` 审计；
6. 特别检查是否改变 TUN 名称、`br-lan` 假设、PID 文件、身份文件、更新标记、iproute2/netfilter 命令或所需设备节点；
7. 若包新增文件或 capability，先解释原因并更新安全模型，不能直接放宽；
8. 运行 Shell/YAML 静态检查和 Docker 构建；
9. 在目标服务器检查健康状态、容器内接口/路由/规则；
10. 用手机 App 完成发现和控制，再用 PS5/Switch 做实际联网与加速；
11. 核对宿主机默认路由、DNS、sysctl 和防火墙没有因项目改变；
12. 提交 `plugin.lock` 和相应审计记录，绝不提交 `vendor/uu.tar.gz`。

必须保留的行为：

- 安装、更新和卸载默认只报告，写入需要 `--apply`；
- 普通安装遇到官方新版时只 warning，继续使用 `plugin.lock` 的固定版本；
- 同版本官方 MD5 变化时，`update.sh` 拒绝自动改锁；已有缓存只能在锁定 SHA-256 仍匹配时继续使用；
- 插件 tar 出现额外路径时拒绝继续；
- 不自动执行 UU monitor 或未知下载脚本；
- 不使用 `--privileged`、host network 或 Docker socket；
- 不自动修改宿主机网络；
- 不把 `.env`、闭源包、Mac App、日志或用户身份文件提交 Git。

## 15. 验证清单

### 不需要目标机的静态检查

```sh
sh -n scripts/container-entrypoint.sh scripts/healthcheck.sh scripts/render-dns-overrides.sh
bash -n install.sh update.sh uninstall.sh scripts/lib.sh
tests/test-dns-overrides.sh
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
docker exec netease-uu sh -c 'iptables-save -t nat | grep -E -- "^-A PREROUTING .*--dport 53" || true'
```

验收必须覆盖：

- 容器为 `healthy` 且不反复重启；
- `br-lan` 拥有预期 IP/MAC，默认路由正确；
- dnsmasq 和 UU PID 均存活；
- 每项 DNS 覆盖的 A、AAAA 和未覆盖域名查询行为符合预期；
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
