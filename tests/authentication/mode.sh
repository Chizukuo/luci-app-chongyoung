#!/usr/bin/env bash
# tests/authentication/mode.sh
# v2.2.0 多拨聚合 (MWAN)、MACVLAN 虚拟链路与多会话路由状态 Mock 测试
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
src="$root/root/usr/bin/feiyoung.sh"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/feiyoung-test-mwan.XXXXXX")"
cleanup() {
    rm -rf "$test_dir"
}
trap cleanup EXIT

assertions=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    if [ -f "${trace_file:-}" ]; then
        printf '%s\n' '--- TRACE ---' >&2
        cat "$trace_file" >&2
    fi
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

# 1. 提取被测生产函数
source <(sed -n '/^generate_mac() {/,/^}/p' "$src")
source <(sed -n '/^setup_dhcp_script() {/,/^}/p' "$src")
source <(sed -n '/^get_lan_device() {/,/^}/p' "$src")
source <(awk '/^apply_mwan_routing\(\) \{/{flag=1} /^# update_overall_status/{flag=0} flag' "$src")
source <(sed -n '/^teardown_mwan_routing() {/,/^}/p' "$src")
source <(sed -n '/^update_overall_status() {/,/^}/p' "$src")
source <(sed -n '/^mask_user() {/,/^}/p' "$src")

# 2. MAC 地址派生算法测试 (确保前缀 02 且根据会话序号不冲突)
mac1=$(generate_mac "02:11:22:33:44:00" 1)
mac2=$(generate_mac "02:11:22:33:44:00" 2)
assert_eq "02:11:22:33:44:12" "$mac1" "session 1 derived MAC format"
assert_eq "02:11:22:33:44:23" "$mac2" "session 2 derived MAC format"
[ "$mac1" != "$mac2" ] || fail "MACs must be distinct"
assertions=$((assertions + 1))

# 3. 虚拟网卡专享轻量 DHCP 处理脚本生成测试
setup_dhcp_script
assert_true "DHCP handler exists" test -x /tmp/feiyoung_dhcp.sh
assert_true "DHCP handler contains table isolation" grep -q "table_id=\$((100 + vidx))" /tmp/feiyoung_dhcp.sh
assert_true "DHCP handler contains oif policy rule" grep -q "oif \"\$interface\" lookup \"\$table_id\"" /tmp/feiyoung_dhcp.sh
assert_true "DHCP handler cleans rules by priority" grep -q "ip rule del priority" /tmp/feiyoung_dhcp.sh
rm -f /tmp/feiyoung_dhcp.sh

# 4. 多拨聚合路由生成与 nftables 规则测试
log() { :; }
load_balancing="1"
LAST_MWAN_STATE=""
trace_file="$test_dir/mwan.trace"

get_wan_device() { echo "wan"; }
get_lan_device() { echo "br-lan"; }
get_dev_gw() { echo "100.64.0.1"; }
get_dev_ip() { echo "100.64.1.$1"; }

ip() {
    printf 'ip %s\n' "$*" >> "$trace_file"
}

nft() {
    if [ "$1" = "-f" ] && [ "$2" = "-" ]; then
        cat >> "$trace_file"
    else
        printf 'nft %s\n' "$*" >> "$trace_file"
    fi
}

: > "$trace_file"
# 4.1 在线数 < 2 时不触发聚合
apply_mwan_routing 1 "wan"
assert_eq "" "$(<"$trace_file")" "single wan does not trigger mwan"

# 4.2 在线数 = 2 时动态下发黏性聚合与策略路由
: > "$trace_file"
apply_mwan_routing 2 "wan vwan1"
assert_true "mwan creates priority 1010 for wan" grep -q "ip rule add priority 1010 fwmark 0x10 lookup main" "$trace_file"
assert_true "mwan creates priority 1012 for vwan1" grep -q "ip rule add priority 1012 fwmark 0x20 lookup 101" "$trace_file"
assert_true "mwan creates priority 1030 for wan source ip" grep -q "ip rule add priority 1030 from 100.64.1.wan lookup 100" "$trace_file"
assert_true "mwan creates priority 1032 for vwan1 source ip" grep -q "ip rule add priority 1032 from 100.64.1.vwan1 lookup 101" "$trace_file"
assert_true "mwan generates sticky nft table" grep -q "table inet feiyoung_mwan" "$trace_file"
assert_true "mwan contains numgen mod 2 map" grep -q "ct mark set numgen inc mod 2 map { 0 : 0x10, 1 : 0x20 }" "$trace_file"
assert_true "mwan sets mss 1400" grep -q "tcp option maxseg size set 1400" "$trace_file"

# 4.3 聚合规则平滑卸载
: > "$trace_file"
teardown_mwan_routing
assert_true "teardown removes feiyoung_mwan table" grep -q "nft delete table inet feiyoung_mwan" "$trace_file"
assert_true "teardown flushes route cache" grep -q "ip route flush cache" "$trace_file"

# 5. 多会话状态文件汇总格式测试 (update_overall_status)
NUM_ACCTS=2
ACCT_1_USER="18900001111"
ACCT_1_TYPE="pc"
ACCT_1_DEV="wan"
ACCT_1_STATUS="在线"

ACCT_2_USER="18900001111"
ACCT_2_TYPE="mobile"
ACCT_2_DEV="vwan1"
ACCT_2_STATUS="在线"

get_dev_ip() {
    case "$1" in
        wan) echo "100.64.42.36" ;;
        vwan1) echo "100.64.84.223" ;;
    esac
}

update_overall_status "运行中 - 网络正常 (2/2 在线，多拨聚合已生效)"
status_content=$(cat /tmp/feiyoung_status)
rm -f /tmp/feiyoung_status

assert_true "summary header present" echo "$status_content" | grep -q "2/2 在线，多拨聚合已生效"
assert_true "pc masked line present" echo "$status_content" | grep -q "• \[PC\] 189\*\*\*\*1111 (wan): 在线 \[100.64.42.36\]"
assert_true "mobile masked line present" echo "$status_content" | grep -q "• \[Mobile\] 189\*\*\*\*1111 (vwan1): 在线 \[100.64.84.223\]"

printf 'PASS: MWAN policy routing, MAC derivation, DHCP template, and status assertions=%d\n' "$assertions"
