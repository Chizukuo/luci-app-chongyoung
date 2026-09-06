#!/usr/bin/env bash
# tests/run_all.sh
# luci-app-feiyoung v2.2.0 统一离线自动化 Mock 测试运行器
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
tests=(
    "network/upstream-sync.sh:网络链路与上游时间同步防死锁测试"
    "authentication/flow.sh:多终端并发认证与移动端 WAF 绕过测试"
    "authentication/mode.sh:多拨聚合策略路由 (MWAN) 与 MAC 派生测试"
    "diagnostics/collector.sh:诊断工具环境隔离与权限防护测试"
    "diagnostics/core.sh:诊断字段提取与 Key-Value 解析器测试"
)

passed=0
failed=0

echo "======================================================================"
echo "    luci-app-feiyoung v2.2.0 离线 Mock 自动化回归测试流水线"
echo "======================================================================"
echo ""

for entry in "${tests[@]}"; do
    script="${entry%%:*}"
    desc="${entry##*:}"
    echo ">> 正在执行: $desc ($script)"
    if bash "$dir/$script"; then
        echo "   [SUCCESS] $desc 测试通过"
        passed=$((passed + 1))
    else
        echo "   [FAILURE] $desc 测试失败!"
        failed=$((failed + 1))
    fi
    echo "----------------------------------------------------------------------"
done

echo ""
echo "======================================================================"
echo " 测试完成: 总计 ${#tests[@]} 个套件, 通过: $passed, 失败: $failed"
echo "======================================================================"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
