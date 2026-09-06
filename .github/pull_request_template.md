## 变更描述 (Description)

请简要说明本次 PR 的变更动机、解决的问题以及达成的效果：
<!-- 例如：优化了移动端 302 重定向解析逻辑，解决了特定校区环境下 WAF 拦截问题。 -->

---

## 变更类型 (Type of Change)

- [ ] 🐛 Bug 修复 (Bug Fix)
- [ ] ✨ 新功能 (Feature)
- [ ] ⚡ 性能优化 / 架构重构 (Performance / Refactoring)
- [ ] 📝 文档更新 (Documentation)
- [ ] 🧪 自动化测试补充 (Testing)
- [ ] 🔧 构建或辅助工具调整 (Chore)

---

## 架构合规自查清单 (Checklist)

在提交 PR 前，请确保已逐项核对并勾选以下标准：

- [ ] **核心纯净通用原则**：代码中**未包含**任何个人私有定制需求或第三方插件（如 SQM/AdBlock 等）硬编码；个性化扩展已通过 `/etc/feiyoung.user` 承载。
- [ ] **Flash 零损耗原则**：运行期间未向 Flash/ROM 频繁写入文件；多拨或聚合规则为 RAM-only（纯内存，停止服务可平滑释放）。
- [ ] **Shell 兼容性**：路由器侧脚本遵循 POSIX sh / BusyBox ash 语法规范，未使用 Bash 专有语法。
- [ ] **隐私保护**：syslog 与状态输出中的手机号、密码或敏感凭据均已进行掩码脱敏。
- [ ] **自动化测试通过**：本地执行 `bash tests/run_all.sh` 全部通过（5/5 Pass）。
- [ ] **实机验证**：已在 OpenWrt 真实路由器或仿真环境中测试，无语法错误或异常崩溃。

---

## 验证证据与日志 (Verification & Logs)

请粘贴本地测试套件输出，或在实机上运行 `logread -e feiyoung` 的相关测试日志：

```text
<!-- 在此处粘贴验证日志 -->
```
