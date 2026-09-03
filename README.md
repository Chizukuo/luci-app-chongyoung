# luci-app-feiyoung

[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02%2B-blue.svg)](https://openwrt.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

OpenWrt LuCI support for FeiYoung Campus Network Auto Login.  
专为湖北电信飞Young校园网设计的 OpenWrt 自动登录插件，提供原生的 LuCI 控制界面与高可用的后台守护进程。

> **关于 v2.0+ 的重大重构**：  
> 学校认证系统现已全面迁移至**湖北电信 school_hbct 网页认证门户**。本插件进行了协议级重写：  
> - 登录方式升级为「手机号 + 6 位静态密码」直连验证，**彻底告别每日算号**（已移除 `calc_pwd.lua`）。  
> - 通过未认证流量的 HTTP 302 重定向**自动发现认证门户**，无需手动抓包填写复杂的网关参数。

---

## 核心特性

- **静态密码直连**：仅需配置手机号与 6 位密码，开机与断网后全自动完成身份验证。
- **动态门户发现**：通过纯 IP 请求触发网关拦截重定向，自动提取 `userip`、`nasip`、`usermac` 与 `paramStr`，校园网节点变动无需重新配置。
- **双重存活研判**：结合 ICMP Ping 与 HTTP 状态码双重探测，精准识别上游机房 302 踢线，同时消除晚高峰偶发丢包导致的误断网。
- **会话定时打卡保活**：每 5 分钟轻量访问一次认证页面刷新会话 Cookie，防止机房 BRAS 因长连接或游戏纯 UDP 流量误判空闲超时踢线下线。
- **交换机防刷保护与极速自愈**：监控网关二层 ARP 状态，在租约失效时主动重置；内置 60 秒防抖冷却锁，彻底杜绝高频 DHCP 请求触发机房接入交换机（如华为 S5320）的泛洪限速惩罚。
- **缺省路由兜底**：机房 DHCP 偶发不下发默认网关时，自动检测并静态补齐默认路由，确保网络通信正常。
- **极简依赖与原生架构**：核心仅依赖系统内置的 `curl` 与 Shell 工具链；无缝集成 OpenWrt Procd 守护进程架构，开机自启、崩溃自愈、毫秒级平滑退出。
- **双轨全固件兼容**：同时适配现代 LuCI `menu.d` JSON 菜单定义与传统 Lua 控制器，覆盖 OpenWrt 21.02 至 25.12+ 全世代固件。
- **定时计划休眠**：支持自定义深夜休眠时段，支持定时断开 WAN 口，采用内存级射频控制命令关闭 5G WiFi，不损耗 Flash 寿命。

---

## 版本推荐

- **v2.1.1 (当前推荐)**：适配 school_hbct 新门户，具备完整的交换机防刷保护、会话保活、双重连通研判与秒级自愈能力。
- **v1.9.2 及更早**：仅适用于旧版 XML 接口认证（`http://100.64.0.1`），现已失效。

---

## 安装方法

本插件采用跨平台纯脚本开发，**支持所有 CPU 架构**（x86-64, ARM, MIPS 等）的 OpenWrt 路由器。

### 方法一：编译安装 (面向固件定制开发者)

1. 将本仓库克隆至 OpenWrt SDK 或源码根目录下的 `package/` 目录：
   ```bash
   cd package/
   git clone https://github.com/Chizukuo/luci-app-feiyoung.git
   ```
2. 运行配置菜单并在 `LuCI` -> `3. Applications` 中勾选 `luci-app-feiyoung`：
   ```bash
   make menuconfig
   ```
3. 编译整机固件或单独编译安装包：
   ```bash
   make package/luci-app-feiyoung/compile
   ```

### 方法二：安装 IPK 软件包 (适用于 OpenWrt 24.10 及以下固件)

从 [Releases](../../releases) 页面下载对应版本的 `.ipk` 文件上传至路由器 `/tmp` 目录，执行：
```bash
opkg update
opkg install /tmp/luci-app-feiyoung_*.ipk
```

### 方法三：安装 APK 软件包 (适用于 OpenWrt 25.12 及以上固件)

从 [Releases](../../releases) 页面下载对应版本的 `.apk` 文件上传至路由器 `/tmp` 目录，执行：
```bash
apk add --allow-untrusted /tmp/luci-app-feiyoung_*.apk
```

> [!NOTE]
> 由于手动安装的自编译 APK 未录入官方签名仓库，安装时需显式携带 `--allow-untrusted` 参数。

---

## 配置与使用

1. 登录路由器 OpenWrt 管理后台。
2. 进入导航栏：`服务 (Services)` -> `FeiYoung Network`。
3. **基础设置**：
   - 勾选 `启用 (Enable)`。
   - 输入 `手机号 (Phone Number)`。
   - 输入 `密码 (Password)`（即你在校园网认证页面使用的 6 位静态密码）。
4. 点击页面右下角的 `保存并应用 (Save & Apply)`。

保存后，守护进程将在 2~3 秒内自动感应上游网络状态，获取未认证重定向并完成登录，后续全自动在后台长效维持在线。

---

## 排错与日志观测

如需排查网络故障或观察守护进程行为，可通过 SSH 连接路由器执行查看：

```bash
# 查看最近的运行日志
logread -e feiyoung

# 实时跟随输出最新日志
logread -f -e feiyoung
```

### 典型日志释义

- `系统 NTP 时间同步成功`：已完成系统时间校准，定时休眠与调度系统已就绪。
- `检测到网络已上线`：认证成功且连通性校验通过，已触发外部联动任务。
- `网络断开，开始重连`：检测到无法访问外部网络或被机房 302 拦截重定向，守护进程进入自愈流程。
- `未发现认证门户`：重定向探测未返回合法门户特征，通常出现在上游物理网线未接通、或当前 IP 租约已被机房废弃时。
- `WAN 口最近已执行过重置，处于 60s 冷却保护中`：触发防泛洪保护，避免短时间内连续 DHCP 广播导致被机房接入交换机惩罚。

---

## 开发与版本历史

### 版本历史

**v2.1.1** (2026-09-03) - 极端网络环境高可用加固与会话保活
- 交换机防刷保护：在 `renew_wan` 引入 60 秒硬性冷却锁与网关空值保护，彻底杜绝连续 DHCP 广播触发交换机（如华为 S5320）`DHCP Snooping Rate-limit` 封禁惩罚。
- 极速无感自愈：离线重试轮询缩短至 5 秒，门户探测超时从 5 秒大幅缩减至 2 秒，掉线自愈恢复时间缩减至 3~5 秒。
- 网络存活双重研判：采用 ICMP Ping + HTTP 状态码双重研判；精准识别机房 302 重定向踢线，同时消除晚高峰 ICMP 丢包误判。
- 5 分钟定时打卡保活：在线状态下每 5 分钟轻量访问一次门户页面刷新 Cookie，防止机房 BRAS 因长连接或纯 UDP 游戏流量误判空闲超时踢线。
- 保护游戏 DNS 缓存：优化联动脚本逻辑，跳过运行中 `adblock-fast` 的重复启动，避免频繁重启 `dnsmasq` 导致游戏和网络卡顿假死。

**v2.1.0** (2026-09-03) - 稳定性修复与全架构规范优化
- 修复门户发现误接受 `1.1.1.1` 自身重定向（增加 `userip=` 校验）。
- 修复配置变更不生效：守护进程每轮重新读取 UCI 配置，不再依赖 procd reload。
- 修复默认路由判定逻辑错误导致网关兜底失效的问题。
- 修复 Web 前端状态动态轮询 DOM ID 不匹配的问题。
- 优化 5G WiFi 休眠机制：改用内存级控制命令，消除 Flash 擦写损耗并杜绝夜间重启后 5G 丢失死锁。
- 规范适配现代 LuCI `menu.d` JSON 菜单定义，同时保留 Lua 控制器实现新老版本全兼容。
- 适配 BusyBox HTTP 日期转换与夜间休眠时间判断解除死锁。
- 优化信号处理，实现毫秒级优雅退出，消除 procd 强制 SIGKILL 告警。
- 新增网关 ARP 失效检测与 WAN 口 DHCP 自动重置自愈机制。
- 重连失败原因写入日志（未发现门户 / 无法获取认证参数）。
- 新增 Windows/Android NCSI 标准门户探测 URL 兜底（直连 DHCP 纯 DNS 绕过 DoH）。

**v2.0.0** (2026-08-30) - 适配 school_hbct 新门户，静态密码直连登录
- 认证系统迁移：旧 XML 接口 (`100.64.0.1`) 迁移至湖北电信 school_hbct 网页门户 (`58.53.199.144:8001`)。
- 登录改为手机号 + 6 位静态密码直连提交，移除每日算号逻辑与 `calc_pwd.lua`。
- 新增 HTTP 重定向自动发现门户，动态获取 `userip`/`nasip`/`usermac` 参数。
- 新增默认路由兜底，修复校园网 DHCP 偶发不下发默认网关导致无法连接门户的问题。
- 未认证环境下本地 DNS 不可用，改用纯 IP 触发重定向。

**v1.9.2** (2026-06-05) - 引入自定义联动钩子并修复 NTP 阻塞
- 修复 NTP 同步无超时导致脚本阻塞的 Bug。
- 网络上线后自动拉起 adblock-fast 等联动服务。
- 壁纸自动更换脚本断网补刷机制。

更早的版本历史请参考 [Releases](../../releases) 页面。

---

## 目录结构

```
.
├── Makefile                        # OpenWrt 编译配置
├── README.md                       # 项目说明与技术文档
├── htdocs/                         # Web 前端资源文件
│   └── luci-static/resources/view/
│       ├── feiyoung/
│       │   └── general.js          # LuCI 视图配置界面
│       └── status/include/
│           └── 10_feiyoung.js      # 首页状态概览小部件
├── luasrc/                         # 兼容层 Lua 控制器
│   └── controller/feiyoung.lua     # 路由映射控制器
├── root/                           # 嵌入式系统运行时文件
│   ├── etc/config/feiyoung         # 默认 UCI 配置文件
│   ├── etc/init.d/feiyoung         # Procd 系统服务启动脚本
│   ├── etc/uci-defaults/99_feiyoung  # 版本平滑升级数据迁移脚本
│   ├── usr/bin/feiyoung.sh         # 核心后台守护进程
│   └── usr/share/
│       ├── luci/menu.d/luci-app-feiyoung.json  # 现代 LuCI 菜单清单
│       └── rpcd/acl.d/luci-app-feiyoung.json   # RPC 权限声明
└── LICENSE                         # MIT 开源授权协议
```

---

## 技术亮点

- **全纯净 Shell 实现**：核心无 Python、Node.js 等庞大运行时依赖，全流程基于 BusyBox 工具链与轻量 `curl`，在 16MB Flash / 64MB RAM 的低端设备上也能轻盈运转。
- **状态驱动自愈架构**：围绕二层 ARP 邻居状态、三层网关路由与七层 HTTP 状态码进行立体化状态建模，遇到机房切网、设备重启、上游断电均能自动恢复。
- **系统级 Procd 契约**：严格遵循 OpenWrt 服务接入规范，具备进程异常退出自动复活、整机软重启平滑退出等机制。

---

## 许可证

本项目采用 [MIT License](LICENSE) 授权许可。

---

## 作者与致谢

- **核心开发与维护**: chizukuo (<chizukuo@icloud.com>)
- **早期概念探索**: [electkismet](https://github.com/electkismet/feiyoung)

本项目基于 electkismet 的早期 Shell 脚本思路进行工业级重构与开发，并演进为符合现代 OpenWrt 标准规范的独立 LuCI 插件体系。
