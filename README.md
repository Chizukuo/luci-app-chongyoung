# luci-app-chongyoung

[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02%2B-blue.svg)](https://openwrt.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

OpenWrt LuCI support for ChongYoung Campus Network Auto Login.
专为崇扬校园网设计的 OpenWrt 自动登录插件，提供图形化配置界面与稳定的守护进程。

## ✨ 功能特点

- **零依赖**: 纯 Shell 脚本核心，无需 Python/Node.js，仅依赖系统自带的 `curl`。
- **LuCI 集成**: 原生 OpenWrt 界面风格，支持 Argon 等第三方主题。
- **智能守护**: 集成 Procd 进程守护，开机自启，崩溃自动重启。
- **断线重连**: 内置网络状态检测与心跳保活机制，实现 7x24 小时在线。
- **便捷配置**: 支持一键粘贴 31 天密码列表，自动匹配日期登录。
- **低资源占用**: 内存占用极低，日志自动轮转，不占用路由器存储空间。

## 📦 安装方法

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

### 第一步：生成密码
1. 在电脑浏览器中打开项目根目录下的 `index.html` 文件。
2. 输入你的 **6位原始密码**。
3. 点击 **生成密码**，然后点击 **一键复制**。

### 第二步：配置插件
1. 登录路由器 OpenWrt 后台。
2. 进入菜单：`服务 (Services)` -> `ChongYoung Network`。
3. **基本设置**:
   - 勾选 `启用 (Enable)`。
   - 输入 `手机号 (Phone Number)`。
4. **密码设置**:
   - 在 `每日密码 (Daily Passwords)` 区域的文本框中，直接 **粘贴** 刚才复制的 31 行密码。
5. 点击右下角的 `保存并应用 (Save & Apply)`。

## 🔍 故障排查

如果遇到无法登录的情况，请通过 SSH 登录路由器查看日志：

```bash
# 查看最近的日志
logread -e chongyoung

# 实时监控日志
logread -f -e chongyoung
```

**常见日志说明**:
- `网络断开，开始重连`: 检测到无法 ping 通外网，正在尝试重新认证。
- `登录结果: ...`: 显示服务器返回的认证结果。
- `未找到第 XX 天的密码`: 请检查密码列表是否完整填写了 31 行。

## 🛠️ 开发相关

### 目录结构
```
.
├── Makefile                    # OpenWrt 编译配置
├── htdocs/                     # Web 界面 (JavaScript)
├── luasrc/                     # 控制器逻辑 (Lua)
├── root/                       # 系统文件
│   ├── etc/config/chongyoung   # UCI 默认配置
│   ├── etc/init.d/chongyoung   # Procd 启动脚本
│   └── usr/bin/chongyoung.sh   # 核心 Shell 脚本
└── index.html                  # 密码生成工具
```

## 📄 许可证

本项目采用 [MIT License](LICENSE) 开源。

## 👨‍💻 作者与致谢

- **核心开发/维护**: chizukuo (<chizukuo@icloud.com>)
- **原脚本逻辑**: dapaoxixixi

本项目基于 dapaoxixixi 的 Shell 脚本进行深度重构与开发，将其移植为标准的 OpenWrt LuCI 插件，引入了图形化配置、进程守护 (Procd) 及系统日志集成等现代化特性。
