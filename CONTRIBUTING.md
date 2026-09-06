# 贡献指南 (Contributing Guide)

感谢你关注并愿意为 **luci-app-feiyoung** 贡献代码！湖北电信校园网认证环境复杂多样，开源社区的力量对于项目的稳定演进至关重要。

为了确保插件的高可用性、代码质量以及在各种低配置路由器上的稳定运行，请在参与贡献前阅读以下规范与指南。

---

## 一、 核心架构设计原则

所有提交的 PR 必须严格遵守以下三大架构原则：

### 1. 插件核心纯净通用原则（严禁私货与硬编码）
- **通用性**：插件核心代码（`feiyoung.sh`、UCI 模版、Web 前端）必须保持 100% 通用，服务于所有湖北电信校园网用户。
- **解耦边界**：**严禁**将用户个人特定需求（如特定的第三方插件联动、自定义 SQM QoS 流控规则、特定免流规则、自定义壁纸脚本等）直接硬编码写入插件源码。
- **自定义钩子扩展**：任何进阶或个性化需求，应引导用户使用项目提供的标准扩展钩子脚本 `/etc/feiyoung.user`（支持 `online` 与 `offline` 状态回调，自动在 `sysupgrade.conf` 中固化持久化）。

### 2. 嵌入式闪存零损耗原则（Zero Flash Overhead）
- 目标设备很多为只有 16MB SPI Flash、且 `/overlay` 仅剩几百 KB 的低端嵌入式设备（如 MT7621）。
- 守护进程运行期间**严禁频繁向 Flash 写入数据**；临时状态、Cookie、标记一律存放在 `/tmp` (tmpfs 内存)。
- 多拨聚合、策略路由与防火墙规则必须是纯内存的（RAM-only，如基于动态 nftables 表），服务停止即刻平滑释放，不得向 `/etc/config/firewall` 或 `/etc/config/network` 追加不可逆的临时持久化配置。
- 严禁引入 Python、Node.js 等庞大运行时作为插件依赖。

### 3. 网络自愈与稳定性契约（Invariants）
- **交换机防刷保护**：必须保留 DHCP 重置的硬性 60 秒冷却锁（`renew_wan`），杜绝因连续高频请求触发机房接入交换机（如华为 S5320）的泛洪限速惩罚。
- **无 RTC 设备时间防死锁**：在 NTP/HTTP 完成时钟授时之前，严禁直接激活定时休眠断网逻辑。
- **全架构网络接口自适应**：统一通过 `get_wan_device` 与 `get_lan_device` 动态解析三层及物理设备，严禁硬编码 `dev wan` 或 `dev br-lan`。

---

## 二、 自动化测试流程

本项目内置了完整的**离线 Mock 自动化回归测试套件**（位于 `tests/` 目录），覆盖了认证流、移动端 WAF 绕过、多拨聚合路由生成与网络自愈等关键路径。

在提交 PR 之前，请务必在本地运行测试流水线，确保所有测试用例通过：

```bash
# 在 Linux 终端、macOS 或 Windows Git Bash 中运行：
bash tests/run_all.sh
```

**期望输出**：
```text
======================================================================
 测试完成: 总计 5 个套件, 通过: 5, 失败: 0
======================================================================
```

如果你新增了新特性或修复了新边界 Bug，强烈建议在 `tests/` 下同步补充对应的自动化测试用例。

---

## 三、 代码与提交规范

### 1. 脚本代码规范
- 路由端运行的 Shell 脚本（`feiyoung.sh`、`feiyoung.user`、init 脚本）必须遵循 **POSIX sh / BusyBox ash** 语法，严禁使用 Bash 专有语法（如 `[[ ... ]]`、进程替换 `<(...)`、关联数组等）。
- 变量使用时注意空值保护，如使用 `${1:-}` 代替 `$1`，避免在 `set -u` 严格模式下抛出未定义异常。
- 所有敏感信息（手机号、密码、Cookie）在打印到 syslog 或状态文件前必须脱敏（使用 `mask_user` 等函数）。

### 2. 前端 JS 规范
- LuCI 前端视图采用现代 LuCI client-side JavaScript 规范（ES5/ES6 严格模式 `'use strict'`），基于 `form.Map` 与 `form.TableSection` 构建。

### 3. Git Commit 提交信息规范
推荐使用 [Conventional Commits](https://www.conventionalcommits.org/) 规范撰写提交信息：
- `feat:` 新功能（如：`feat: 支持动态 MACVLAN 派生`）
- `fix:` 修复 Bug（如：`fix: 解决无 RTC 设备开机误判休眠死锁`）
- `docs:` 文档更新
- `refactor:` 代码重构
- `test:` 测试用例更新

---

## 四、 提 Pull Request 流程

1. **Fork** 本仓库到你的个人 GitHub 账号。
2. 基于 `main` 分支拉取新的特性分支：`git checkout -b feature/my-feature`。
3. 完成代码修改，并在本地运行 `bash tests/run_all.sh` 确认全部通过。
4. 如有条件，请在真实 OpenWrt 路由器（或虚拟机）上验证运行表现与资源占用。
5. 提交代码并推送至你的 Fork 仓库。
6. 发起 Pull Request，按照 PR 模板详细填写变更内容、测试证据与实机日志。

再次感谢你为湖北电信校园网用户的用网体验所做出的贡献！
