#!/usr/bin/env bash
# tests/diagnostics/core.sh
# 诊断工具核心解析器与字段提取单元测试
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
diagnose_src="$root/root/usr/bin/feiyoung-diagnose"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/feiyoung-test-core.XXXXXX")"
cleanup() {
    rm -rf "$test_dir"
}
trap cleanup EXIT

assertions=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$label (expected='$expected' actual='$actual')"
    fi
    assertions=$((assertions + 1))
}

assert_true() {
    local label="$1"
    shift
    if ! "$@"; then
        fail "$label"
    fi
    assertions=$((assertions + 1))
}

# 1. 提取被测函数
source <(sed -n '/^portal_fields() {/,/^}/p' "$diagnose_src")
source <(sed -n '/^kv() {/,/^}/p' "$diagnose_src")

# 2. Key-Value 格式化测试
assert_eq "version=2.2.0" "$(kv 'version' '2.2.0')" "kv format"
assert_eq "empty=unknown" "$(kv 'empty' '')" "kv fallback unknown"

# 3. 门户 HTML 隐藏字段提取解析器测试 (portal_fields)
mock_html="$test_dir/portal.html"
cat << 'EOF' > "$mock_html"
<html>
<head><title>Portal</title></head>
<body>
<form action="/login" method="POST">
    <input type="hidden" name="UserType" value="1">
    <input type="hidden" name="pwdType" value="2">
    <input type="hidden" name="aidcauthtype" value="0">
    <input type="hidden" name="vfcodeflg" value="false">
    <input type="hidden" name="paramStr" value="MOCK_TEST_SECRET">
</form>
</body>
</html>
EOF

output=$(portal_fields "pc_test" "$mock_html")

assert_true "category output present" echo "$output" | grep -q "portal.pc_test.UserType=1"
assert_true "pwdType output present" echo "$output" | grep -q "portal.pc_test.pwdType=2"
assert_true "aidcauthtype output present" echo "$output" | grep -q "portal.pc_test.aidcauthtype=0"
assert_true "vfcodeflg output present" echo "$output" | grep -q "portal.pc_test.vfcodeflg=false"
assert_true "fields listing contains paramStr" echo "$output" | grep -q "paramStr"

printf 'PASS: diagnostic core field extraction and kv parser assertions=%d\n' "$assertions"
