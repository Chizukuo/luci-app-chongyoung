#!/usr/bin/env bash

set -u

test_root=$(mktemp -d "${TMPDIR:-/tmp}/feiyoung-upstream-sync.XXXXXX") || exit 1
test_cleanup() {
    rm -f -- "$test_root/feiyoung.sh" "$test_root/disabled_radios" "$test_root/disabled_lan_ports" \
        "$test_root/online" "$test_root/status" "$test_root/wan_paused" "$test_root/time_verified" \
        "$test_root/route.trace" "$test_root/neigh.trace" "$test_root/wifi.trace"
    rmdir -- "$test_root"
}
trap test_cleanup EXIT

src="$test_root/feiyoung.sh"
sed \
    -e 's#/tmp/feiyoung_disabled_radios#"$test_root/disabled_radios"#g' \
    -e 's#/tmp/feiyoung_disabled_lan_ports#"$test_root/disabled_lan_ports"#g' \
    -e 's#/tmp/feiyoung_online#"$test_root/online"#g' \
    -e 's#/tmp/feiyoung_status#"$test_root/status"#g' \
    -e 's#/tmp/feiyoung_wan_paused#"$test_root/wan_paused"#g' \
    -e 's#/tmp/feiyoung_time_verified#"$test_root/time_verified"#g' \
    root/usr/bin/feiyoung.sh > "$src"

assertions=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
assert_eq() {
    assertions=$((assertions + 1))
    [ "$1" = "$2" ] || fail "$3 (got '$1', want '$2')"
}
assert_true() {
    assertions=$((assertions + 1))
    "$@" || fail "assertion failed: $*"
}
assert_false() {
    assertions=$((assertions + 1))
    "$@" && fail "assertion unexpectedly passed: $*"
}

# Route and ARP probes use the same mocked WAN device selected by the real functions.
source <(sed -n '/^get_wan_device() {/,/^}/p' "$src")
source <(sed -n '/^get_lan_device() {/,/^}/p' "$src")
source <(sed -n '/^get_dev_gw() {/,/^}/p' "$src")
source <(sed -n '/^ensure_default_route() {/,/^}/p' "$src")
source <(sed -n '/^check_gateway_alive() {/,/^}/p' "$src")
log() { :; }
route_trace="$test_root/route.trace"
neigh_trace="$test_root/neigh.trace"
ifstatus_mode=l3
ifstatus() {
    case "$ifstatus_mode" in
        l3) printf '%s\n' '{"l3_device":"eth0.2","device":"br-wan","nexthop":"192.0.2.1","up":true}' ;;
        device) printf '%s\n' '{"device":"eth1","nexthop":"192.0.2.1","up":true}' ;;
        empty) printf '%s\n' '{}' ;;
        arp) printf '%s\n' '{"l3_device":"eth9","nexthop":"192.0.2.1","up":true}' ;;
    esac
}
ip() {
    case "$1 $2 $3" in
        'route show default') return 0 ;;
        'route add default') printf '%s\n' "$*" > "$route_trace"; return 0 ;;
        'neigh show dev') printf '%s\n' "$*" > "$neigh_trace"; printf '%s\n' '192.0.2.1 FAILED'; return 0 ;;
        *) return 0 ;;
    esac
}
logger() { :; }

assert_eq "$(get_wan_device)" eth0.2 'l3_device preferred'
ifstatus_mode=device
assert_eq "$(get_wan_device)" eth1 'device fallback'
ifstatus_mode=empty
assert_eq "$(get_wan_device)" wan 'wan fallback'
ifstatus_mode=device
rm -f "$route_trace"
ensure_default_route
assert_eq "$(cat "$route_trace")" 'route add default via 192.0.2.1 dev eth1' 'default route uses selected device'
ifstatus_mode=arp
rm -f "$neigh_trace"
assert_false check_gateway_alive
assert_eq "$(cat "$neigh_trace")" 'neigh show dev eth9' 'ARP probe uses selected device'

# A configured pause window is ignored until time has been verified, even when the
# mocked clock is in the window; once verified, the real schedule logic applies.
date() {
    case "$*" in
        '+%H%M') printf '%s\n' 2330 ;;
        '+%s') printf '%s\n' 1700000000 ;;
        *) command date "$@" ;;
    esac
}
source <(sed -n '/^check_pause_time() {/,/^}/p' "$src")
pause_enabled=1; pause_start=23:00; pause_end=23:59
rm -f "$test_root/time_verified"
assert_false check_pause_time
touch "$test_root/time_verified"
assert_true check_pause_time
pause_start=00:00; pause_end=01:00
assert_false check_pause_time

# Disabled radios are never selected, and cleanup restores only radios recorded by
# the real disable/enable functions while clearing status state in the isolated dir.
source <(sed -n '/^get_5g_radios() {/,/^}/p' "$src")
source <(sed -n '/^disable_5g() {/,/^}/p' "$src")
uci() {
    case "$*" in
        '-q show wireless') printf '%s\n' 'wireless.radio0=wifi-device' 'wireless.radio1=wifi-device' 'wireless.radio2=wifi-device' ;;
        '-q get wireless.radio0.disabled') printf '%s\n' 1 ;;
        '-q get wireless.radio1.disabled') printf '%s\n' 0 ;;
        '-q get wireless.radio2.disabled') printf '%s\n' 0 ;;
        '-q get wireless.radio1.band') printf '%s\n' 5g ;;
        '-q get wireless.radio2.band') printf '%s\n' 2g ;;
        *) printf '\n' ;;
    esac
}
wifi_trace="$test_root/wifi.trace"
wifi() { printf '%s\n' "$*" >> "$wifi_trace"; }
rm -f "$wifi_trace" "$test_root/disabled_radios"
assert_eq "$(get_5g_radios)" radio1 'disabled 5G radio excluded'
disable_5g
assert_eq "$(cat "$test_root/disabled_radios")" radio1 'only enabled 5G radio recorded'
assert_eq "$(cat "$wifi_trace")" 'down radio1' 'only enabled 5G radio disabled'

source <(sed -n '/^enable_5g() {/,/^}/p' "$src")
source <(sed -n '/^enable_lan_ports() {/,/^}/p' "$src")
enable_5g
assert_eq "$(cat "$wifi_trace")" $'down radio1\nup radio1' 'recorded radio restored'
assert_false test -e "$test_root/disabled_radios"

source <(sed -n '/^cleanup_virtual_interfaces() {/,/^}/p' "$src")
source <(sed -n '/^renew_interface() {/,/^}/p' "$src")
source <(sed -n '/^cleanup() {/,/^}/p' "$src")
# Keep cleanup's logger fully local even if a sourced function changes the shell scope.
log() { :; }
teardown_mwan_routing() { :; }
setup_dhcp_script() { :; }
touch "$test_root/status" "$test_root/online" "$test_root/wan_paused"
ip() { :; }
ifup() { :; }
cleanup
assert_false test -e "$test_root/status"
assert_false test -e "$test_root/online"
assert_false test -e "$test_root/wan_paused"

# 验证 renew_interface 的 60 秒冷却锁保护机制
renew_wan_calls=0
ifup() { renew_wan_calls=$((renew_wan_calls + 1)); }
renew_interface "wan"
assert_eq "1" "$renew_wan_calls" "first renew_interface triggers ifup"
renew_interface "wan"
assert_eq "1" "$renew_wan_calls" "second renew_interface within 60s is blocked by cooldown lock"

printf 'PASS: upstream sync network, pause-time, radio, cleanup assertions=%d\n' "$assertions"
