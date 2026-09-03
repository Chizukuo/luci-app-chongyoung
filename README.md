# luci-app-feiyoung

[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02%2B-blue.svg)](https://openwrt.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

OpenWrt LuCI support for FeiYoung Campus Network Auto Login.
专为飞young校园网设计的 OpenWrt 自动登录插件，提供图形化配置界面与稳定的守护进程。

> **v2.0 重大变更**：学校认证系统已从旧 XML 接口迁移到**湖北电信 school_hbct 网页门户**，本插件同步重构：
> - 登录改为「手机号 + 6 位静态密码」直连提交，**不再每日算号**（`calc_pwd.lua` 已移除）。
> - 通过 HTTP 重定向**自动发现门户地址**，无需手填网关参数。

## ✨ 功能特点

- **🔐 静态密码登录** (v2.0): 仅需手机号 + 6 位静态密码，无需每日算号。
- **🌐 自动发现门户**: 未认证时通过 HTTP 重定向动态获取门户地址与 `userip`/`nasip`/`usermac` 参数，网关变动无需改配置。
- **🛡️ 默认路由兜底**: 校园网 DHCP 偶发不下发默认网关时自动补齐。
- **零依赖**: 纯 Shell 脚本核心，仅依赖系统自带的 `curl`。
- **LuCI 集成**: 原生 OpenWrt 界面风格，支持 Argon 等第三方主题。
- **智能守护**: 集成 Procd 进程守护，开机自启，崩溃自动重启。
- **断线重连**: 内置网络状态检测，实现 7x24 小时在线。
- **计划休眠**: 支持定时断开 WAN、关闭 5G/有线网口，触发设备切换网络。
- **无缝升级**: 升级时自动将旧配置（`password_seed`）迁移为新字段（`password`）。

## 📝 版本选择建议

- **v2.1.0 (推荐)**: 适配新的 school_hbct 门户，静态密码直连登录。
- **v1.9.2 及更早**: 仅适用于旧的 XML 接口认证（`http://100.64.0.1`），现已失效。

## 📦 安装方法

### 兼容性说明
本插件采用纯脚本编写，**支持所有 CPU 架构** (x86, ARM, MIPS 等) 的 OpenWrt 路由器。

### 方法一：编译安装 (推荐)

1. 将本仓库克隆到 OpenWrt SDK 的 `package/` 目录下：
   ```bash
   cd package/
   git clone https://github.com/Chizukuo/luci-app-feiyoung.git
   ```
2. 运行 `make menuconfig`，在 `LuCI` -> `3. Applications` 中选中 `luci-app-feiyoung`。
3. 编译固件或单独编译 IPK 包：
   ```bash
   make package/luci-app-feiyoung/compile
   ```

### 方法二：安装 IPK (适用于 OpenWrt 24.10 及以下版本)

```bash
opkg update
opkg install /tmp/luci-app-feiyoung_*.ipk
```

### 方法三：安装 APK (适用于 OpenWrt 25.12 及以上版本)

```bash
apk add --allow-untrusted /tmp/luci-app-feiyoung_*.apk
```

> [!IMPORTANT]
> 手动安装的 APK 未签名，必须加 `--allow-untrusted`。

## 📖 使用指南

1. 登录路由器 OpenWrt 后台。
2. 进入菜单：`服务 (Services)` -> `FeiYoung Network`。
3. **基本设置**:
   - 勾选 `启用 (Enable)`。
   - 输入 `手机号 (Phone Number)`。
   - 输入 `密码 (Password)` —— **你的 6 位静态密码**。
4. 点击 `保存并应用 (Save & Apply)` 即可。

**就这么简单！** 路由器会自动登录并保持在线，无需进一步操作。

### 日志查看

```bash
# 查看最近的日志
logread -e feiyoung

# 实时监控日志
logread -f -e feiyoung
```

### 常见日志说明

- `网络断开，开始重连`: 检测到无法 ping 通外网，正在尝试重新认证。
- `登录成功 (用户: xxx)`: 成功登录到校园网。
- `未发现认证门户`: 未能通过重定向发现门户（可能已认证或网络异常）。
- `连接认证门户失败` / `解析 paramStr 失败`: 门户请求异常，请检查网络与 `gateway` 配置。

### 升级说明

**从旧版 (v1.x) 升级至 v2.0.0**：

升级脚本会自动：
1. 将旧的 `password_seed`（6 位原始密码）迁移为 `password`。
2. 删除废弃的 `AidcAuthAttr*`、`system`、`prefix`、每日密码列表等字段。
3. 移除 `calc_pwd.lua`。
4. 重启服务使配置生效。

无需手动操作，你只需确认「密码」字段填的是你的 6 位静态密码即可。

## 🛠️ 开发相关

### 版本历史

**v2.1.0** (2026-09-03) - 稳定性修复与全架构规范优化
- 🐛 修复门户发现误接受 `1.1.1.1` 自身重定向（加 `userip=` 校验）
- 🐛 修复配置变更不生效：守护进程每轮重新读取 UCI 配置，不再依赖 procd reload
- 🐛 修复默认路由判定逻辑错误导致网关兜底失效的问题
- 🐛 修复 Web 前端状态动态轮询 DOM ID 不匹配的问题
- 🛡️ 优化 5G WiFi 休眠机制：改用内存级控制命令，消除 Flash 擦写损耗并杜绝夜间重启后 5G 丢失死锁
- 🌐 规范适配现代 LuCI `menu.d` JSON 菜单定义，同时保留 Lua 控制器实现新老版本全兼容
- ⏱️ 适配 BusyBox HTTP 日期转换与夜间休眠时间判断解除死锁
- ⚡ 优化信号处理，实现毫秒级优雅退出，消除 procd 强制 SIGKILL 告警
- 🔄 新增网关 ARP 失效检测与 WAN 口 DHCP 自动重置自愈机制（彻底解决踢线后租约失效死锁、免去拔插网线）
- 📝 重连失败原因写入日志（未发现门户 / 无法获取认证参数）
- 🌐 新增 Windows/Android NCSI 标准门户探测 URL 兜底（用 DHCP 纯 DNS 绕过 DoH）

**v2.0.0** (2026-08-30) - 适配 school_hbct 新门户，静态密码直连登录
- 🔄 认证系统迁移：旧 XML 接口 (`100.64.0.1`) → 湖北电信 school_hbct 网页门户 (`58.53.199.144:8001`)
- 🔐 登录改为「手机号 + 6 位静态密码」直连提交，移除每日算号逻辑与 `calc_pwd.lua`
- 🌐 新增 HTTP 重定向自动发现门户，动态获取 `userip`/`nasip`/`usermac` 参数（参数缺失会导致「不存在该热点bras配置」）
- 🛡️ 新增默认路由兜底，修复校园网 DHCP 偶发不下发默认网关导致无法连接门户的问题
- 🐛 使用纯 IP 触发重定向（未认证时 DNS 不可用，不能用域名）

**v1.9.2** (2026-06-05) - 引入自定义联动钩子并修复 NTP 阻塞
- ⚡ 修复 NTP 同步无超时导致脚本阻塞的 Bug
- 🛡️ 网络上线后自动拉起 adblock-fast 等联动服务
- 🖼️ 壁纸自动更换脚本断网补刷

更早的版本历史请参考 [Releases](../../releases) 页面。

### 目录结构
```
.
├── Makefile                        # OpenWrt 编译配置
├── README.md                       # 项目说明
├── htdocs/                         # Web 界面文件
│   └── luci-static/resources/view/
│       ├── feiyoung/
│       │   └── general.js          # LuCI 配置界面
│       └── status/include/
│           └── 10_feiyoung.js      # 状态页仪表盘组件
├── luasrc/                         # Lua 控制层
│   └── controller/feiyoung.lua     # LuCI 路由器
├── root/                           # 系统集成文件
│   ├── etc/config/feiyoung         # UCI 配置文件
│   ├── etc/init.d/feiyoung         # Procd 启动脚本
│   ├── etc/uci-defaults/99_feiyoung  # 升级迁移脚本
│   ├── usr/bin/feiyoung.sh         # 核心守护进程
│   └── usr/share/rpcd/acl.d/luci-app-feiyoung.json  # RPC 权限控制
└── LICENSE                         # MIT 许可证
```

### 技术亮点

- **纯 Shell** 实现，最小化依赖（仅 `curl`）。
- **HTTP 重定向发现**: 未认证时访问任意 HTTP 站点会被 NAS 302 重定向到门户，脚本据此动态获取带参数的完整门户地址。
- **Procd 守护**: 利用 OpenWrt 标准的 init 系统，确保服务稳定运行。
- **UCI 配置**: 遵循 OpenWrt 配置规范，与其他插件和谐共处。

## 📄 许可证

本项目采用 [MIT License](LICENSE) 开源。

## 👨‍💻 作者与致谢

- **核心开发/维护**: chizukuo (<chizukuo@icloud.com>)
- **原脚本逻辑**: [electkismet](https://github.com/electkismet/feiyoung)

本项目基于 electkismet 的 Shell 脚本进行深度重构与开发，将其移植为标准的 OpenWrt LuCI 插件。
