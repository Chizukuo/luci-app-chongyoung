# luci-app-chongyoung

[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02%2B-blue.svg)](https://openwrt.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

OpenWrt LuCI support for FeiYoung Campus Network Auto Login.
专为飞扬校园网设计的 OpenWrt 自动登录插件，提供图形化配置界面与稳定的守护进程。

## ✨ 功能特点

- **🔐 本地自动算号** (v1.7.4+): 仅需输入 6 位原始密码，插件自动计算每日密码。彻底告别手动生成 31 行密码的繁琐操作！
- **⚡ 智能降级机制**: 支持将 31 天密码列表作为备用方案。若自动计算失败，脚本自动切换至列表模式，确保登录可靠。
- **零依赖**: 纯 Shell 脚本核心，无需 Python/Node.js，仅依赖系统自带的 `curl`。
- **LuCI 集成**: 原生 OpenWrt 界面风格，支持 Argon 等第三方主题。
- **智能守护**: 集成 Procd 进程守护，开机自启，崩溃自动重启。
- **断线重连**: 内置网络状态检测与心跳保活机制，实现 7x24 小时在线。
- **性能优化**: 密码缓存机制降低 CPU 占用；严格的网络超时控制防止进程卡死。
- **无缝升级**: 升级时自动保留用户配置，无需重新设置手机号或密码。
- **低资源占用**: 内存占用极低，日志自动轮转，不占用路由器存储空间。

## � 版本选择建议

本插件提供不同版本以适应不同需求，请按需选择：

- **v1.8.0+ (推荐)**: 功能最全，支持本地自动算号、计划休眠、断网控制、仪表盘组件等高级功能。
- **v1.7.4**: 持本地自动算号。
- **v1.6.0**: 仅保留核心登录功能，需手动粘贴密码列表。代码量更少，体积极致轻量，适合存储空间极度受限的设备。

## �📦 安装方法

### 兼容性说明
本插件采用纯脚本编写，**支持所有 CPU 架构** (x86, ARM, MIPS 等) 的 OpenWrt 路由器。
编译生成的 IPK 包名可能包含 `_all` 或特定架构后缀，但它们在功能上是通用的。

### 方法一：编译安装 (推荐)

1. 将本仓库克隆到 OpenWrt SDK 的 `package/` 目录下：
   ```bash
   cd package/
   git clone https://github.com/your-username/luci-app-chongyoung.git
   ```
2. 运行 `make menuconfig`，在 `LuCI` -> `3. Applications` 中选中 `luci-app-chongyoung`。
3. 编译固件或单独编译 IPK 包：
   ```bash
   make package/luci-app-chongyoung/compile
   ```

### 方法二：安装 IPK

如果你已经有了编译好的 `.ipk` 文件：

1. 将 `.ipk` 文件上传到路由器 `/tmp` 目录。
2. 执行安装命令：
   ```bash
   opkg update
   opkg install /tmp/luci-app-chongyoung_*.ipk
   ```

## 📖 使用指南

### 推荐方式：仅需 6 位原始密码 (v1.7.4+)
这是最便捷的方式，只需一次性配置，无需每月更新。

1. 登录路由器 OpenWrt 后台。
2. 进入菜单：`服务 (Services)` -> `ChongYoung Network`。
3. **基本设置**:
   - 勾选 `启用 (Enable)`。
   - 输入 `手机号 (Phone Number)`。
   - 输入 `密码种子 (Password Seed)` —— **你的 6 位原始密码（默认身份证后六位）**。
4. 点击右下角的 `保存并应用 (Save & Apply)` 即可。

**就这么简单！** 路由器将自动计算每日密码，无需进一步操作。

---

### 备用方式：使用 31 天密码列表

### 日志查看

若遇到无法登录的情况，请通过 SSH 登录路由器查看日志：

```bash
# 查看最近的日志
logread -e chongyoung

# 实时监控日志
logread -f -e chongyoung
```

### 常见日志说明

- `网络断开，开始重连`: 检测到无法 ping 通外网，正在尝试重新认证。
- `登录结果: 50：认证成功`: 成功登录到校园网。
- `密码计算失败`: 密码种子有误或计算脚本缺失，请检查配置或升级到最新版本。
- `未找到第 XX 天的密码`: 使用密码列表模式时，该行密码缺失或列表不完整。

### 升级说明

**从旧版升级至 v1.7.4+**：

升级过程中，OpenWrt 包管理器可能会提示配置文件冲突。**无需手动操作**，升级脚本会自动：
1. 保留你的手机号和已有的密码列表。
2. 添加新的"密码种子"配置字段。
3. 重启服务使配置生效。

升级完成后，建议在 Web 界面补充填写"密码种子"字段以享受全自动登录的便利

## 🛠️ 开发相关

### 版本历史

**v1.7.4** (2025-12-21) - 本地自动算号与稳定性大幅提升
- ✨ 新增内置自动算号功能，仅需 6 位原始密码
- ✨ 智能降级机制：计算失败自动切换至密码列表
- 🚀 密码缓存优化，显著降低 CPU 占用
- 🛡️ 网络超时控制防止进程卡死
- 🔧 配置无缝迁移，升级时自动保留用户设置
- 🐛 修复脚本语法错误，提升进程稳定性

更早的版本历史请参考 [Releases](../../releases) 页面。

### 目录结构
```
.
├── Makefile                        # OpenWrt 编译配置
├── index.html                      # 密码生成工具 (Web 界面)
├── README.md                       # 项目说明
├── htdocs/                         # Web 界面文件
│   └── luci-static/resources/view/chongyoung/
│       └── general.js              # LuCI 配置界面
├── luasrc/                         # Lua 控制层
│   └── controller/chongyoung.lua   # LuCI 路由器
├── root/                           # 系统集成文件
│   ├── etc/config/chongyoung       # UCI 配置文件
│   ├── etc/init.d/chongyoung       # Procd 启动脚本
│   ├── etc/uci-defaults/99_chongyoung  # 升级迁移脚本
│   ├── usr/bin/chongyoung.sh       # 核心守护进程
│   ├── usr/share/chongyoung/calc_pwd.lua  # 密码算法 (Lua 版)
│   └── usr/share/rpcd/acl.d/luci-app-chongyoung.json  # RPC 权限控制
└── LICENSE                         # MIT 许可证
```

### 技术亮点

- **纯 Shell + Lua** 实现，最小化依赖。
- **密码算法**: 采用 RC4 派生的 KSA 算法，完全兼容原校园网实现。
- **Procd 守护**: 利用 OpenWrt 标准的 init 系统，确保服务稳定运行。
- **UCI 配置**: 遵循 OpenWrt 配置规范，与其他插件和谐共处。

## 📄 许可证

本项目采用 [MIT License](LICENSE) 开源。

## 👨‍💻 作者与致谢

- **核心开发/维护**: chizukuo (<chizukuo@icloud.com>)
- **原脚本逻辑**: dapaoxixixi

本项目基于 dapaoxixixi 的 Shell 脚本进行深度重构与开发，将其移植为标准的 OpenWrt LuCI 插件，引入了图形化配置、进程守护 (Procd) 及系统日志集成等现代化特性。
