> 本项目由 Codex 和 GPT-5.6-Sol、GPT-6 Astra 完成。

# 网易 UU 路由器插件 Docker 封装

在普通 x86_64 Linux 服务器上运行网易 UU 加速器，无需 OpenWrt 环境。  
容器不提供 DHCP，也不会成为全网默认网关。

```text
PS5 / Switch ── 网关和 DNS 指向 UU ─────┐
                                      ｜
手机（首次绑定时临时指向 UU）──────────────┤
                                       ▼
                              [UU Docker：独立 IP]
                                       │
                                       ▼
                                  原主路由/互联网

Linux 宿主机 ───────────────────────> 原主路由（路径不变）
```

## 使用前提

- x86_64 Linux 服务器；本项目当前锁定的是 x86_64 插件，不支持 ARM。
- rootful Docker Engine 和 Docker Compose v2.23.2 或更高版本。
- 服务器通过物理以太网连接局域网；不支持 Wi-Fi 接口作为父接口。
- `/dev/net/tun` 可用。若不存在，可先运行 `sudo modprobe tun`。
- 为容器准备一个与服务器同网段、未被占用且已从 DHCP 地址池排除的固定 IP。
- 交换机或主路由允许服务器所在物理端口出现一个额外 MAC，且 AP 没有隔离游戏主机与有线服务器。

以下命令假定当前用户有权使用 Docker；否则在脚本前加 `sudo`。

## 安装

克隆本项目到本地，复制配置模板：

```sh
cp .env.example .env
```

编辑 `.env`：

| 配置 | 含义 |
| --- | --- |
| `UU_PARENT_INTERFACE` | 连接局域网的物理以太网接口，例如 `enp3s0` |
| `UU_LAN_SUBNET` | 服务器接口实际所在子网，例如 `10.0.0.0/24` |
| `UU_UPSTREAM_GATEWAY` | 原主路由地址，例如 `10.0.0.1` |
| `UU_CONTAINER_IP` | 为 UU 保留的未占用地址，例如 `10.0.0.2` |
| `UU_MAC_ADDRESS` | 为 UU 固定的、本局域网唯一的 MAC |
| `DNSMASQ_UPSTREAM` | 容器内 dnsmasq 的上游*，通常填原主路由 |
| `UU_SNAT_MODE` | 保持默认 `off`；仅在文末所述特殊故障下尝试 `masquerade` |
| `UU_LOG_LEVEL` | UU 内置日志级别：`debug` / `info` / `warning` / `fatal`，默认 `info` |
| `DOWNLOAD_PROXY` | 可选，仅供插件包和镜像构建下载；不会传给运行中的 UU |

\* `DNSMASQ_UPSTREAM` 只配置本封装启动的 dnsmasq 和容器自身的 DNS。UU 开启加速后，闭源插件可能把正在加速设备的 UDP DNS 流量改写到它指定的服务器，因此该变量不能强制指定游戏主机最终使用的 DNS，也不是 UU 的自定义 DNS 配置入口。

安装脚本默认不会安装或修改任何内容：

```sh
./install.sh
```

确认配置后实施安装：

```sh
./install.sh --apply
```

安装脚本只会安装当前仓库 `plugin.lock` 锁定的版本。  
锁定包通过 MD5、SHA-256、大小和归档路径校验后才会用于构建。  
脚本最终应显示容器已经健康运行。

## 用手机绑定 UU 插件

1. 确保手机与服务器处于同一个局域网。
2. 临时把手机当前 Wi-Fi 的 IPv4 网关和 DNS 都改成 `.env` 中的 `UU_CONTAINER_IP`；手机 IP 和子网掩码仍使用原局域网配置。
3. 下载并打开「UU 主机加速」App，按 OpenWrt／合作款路由器流程发现并绑定设备。
4. 确认 App 可以控制加速后，把手机的 IP 和 DNS 恢复为原设置（通常是自动获取）。
5. 后续加速、更换游戏等操作无需再修改 IP、DNS。

绑定身份保存在 Docker volume `netease-uu-state` 中，重建容器时会保留。

## 配置 PS5 或 Switch

在游戏主机的互联网连接中使用手动 IPv4 配置：

- IP 地址：继续使用该设备原来的局域网地址，建议在主路由中做 DHCP 保留。
- 子网掩码：与当前局域网一致。
- 默认网关：填写 `UU_CONTAINER_IP`。
- DNS：填写 `UU_CONTAINER_IP`。

保存后运行主机自带的联网测试，并在手机 UU App 中选择使用中选择游戏、开启加速。只有采用这组网关和 DNS 的设备会经过容器。

## 日常操作

查看状态和日志：

```sh
docker compose ps
docker compose logs --tail 100 uu
```

需要详细日志时，在 `.env` 中设置 `UU_LOG_LEVEL=debug`，然后运行：

```sh
sudo ./install.sh --apply
sudo docker compose logs --tail 100 -f uu
```

修改环境变量需要重新创建容器，仅 `docker compose restart` 不会读取新的 `.env`。日志级别控制 UU 自身日志，封装脚本和 dnsmasq 的启动／错误日志仍会显示。排障结束后可改回 `info` 并重新部署；分享 debug 日志前请检查其中的账号、设备和访问域名等信息。

重启：

```sh
docker compose restart uu
```

停止和重新启动：

```sh
docker compose stop uu
docker compose start uu
```

## 更新项目与 UU 插件

本项目不提供自动追踪或切换上游版本的命令。每个 UU 插件版本都必须先完成审计，再通过新的仓库提交更新 `plugin.lock`。

```sh
git pull --ff-only
sudo ./install.sh --apply
```

`install.sh` 仍只安装刚刚拉取到的锁定版本。命名 volume `netease-uu-state` 会被复用，正常更新无需重新登录或绑定 UU。

## 卸载与还原

查看卸载计划：

```sh
./uninstall.sh
```

移除容器、网络和镜像，但保留 UU 绑定：

```sh
./uninstall.sh --apply
```

连绑定状态和插件下载缓存一起删除：

```sh
./uninstall.sh --apply --purge
```

项目不会删除 Docker Engine、修改 Docker daemon 配置或清理其他项目的 Docker 缓存。

## 常见问题

### 容器反复重启

先查看日志：

```sh
docker compose ps
docker compose logs --tail 200 uu
```

提交问题时请附上这两段输出，交给 Codex。不要上传 `.env` 或 UU 账号信息。

### UU App 找不到插件

检查手机是否与服务器在同一局域网、手机临时网关和 DNS 是否都指向 `UU_CONTAINER_IP`，以及 AP 是否启用了客户端隔离*。还需确认交换机或主路由接受服务器端口后的额外 MAC**。

\* 指通过有线接入的设备与通过无线接入的设备之间的隔离。  
\** 大部分路由器都支持。

### 宿主机无法 ping 容器

这是 macvlan 的正常隔离行为。局域网内其他设备可以访问容器，但宿主机默认不能直接访问；不要为此在宿主机上额外创建 macvlan 接口。

### 主机能联网但没有加速

确认游戏主机的默认网关和 DNS 都是 `UU_CONTAINER_IP`，并检查手机 App 是否已为正确设备开启加速。如果局域网发布 IPv6，游戏主机可能绕过这个 IPv4 网关；可在主路由中仅对游戏设备关闭 IPv6。

### 请求能发出但没有回包

先保留 `UU_SNAT_MODE=off` 并检查日志、网关和地址冲突。只有确认是回程问题后，才把它改为 `masquerade` 并重建；额外 NAT 可能影响主机显示的 NAT 类型。

## 技术资料

架构选择、权限边界、官方插件审计、Mac 版运行时对照、首次部署故障、实机证据和后续 Agent 更新手册都在 [AUDIT.md](AUDIT.md)。

## 许可证

本仓库自有的脚本和文档采用 [WTFPL Version 2](LICENSE)。该许可证不适用于安装时另行下载的网易 UU 闭源程序。

## 声明

仓库不提交或再分发网易 UU 的闭源二进制；安装时由脚本从 UU 官方服务下载并校验。UU、网易及相关名称和商标归其权利人所有。使用者应自行确认服务条款、网络环境和账号风险。
