#!/usr/bin/env bash
# tests/authentication/flow.sh
# v2.2.0 多会话并发认证与移动端 WAF 绕过 Mock 自动化测试套件
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
src="$root/root/usr/bin/feiyoung.sh"

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/feiyoung-test-flow.XXXXXX")"
cleanup() {
    rm -rf "$test_dir"
}
trap cleanup EXIT

assertions=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    if [ -f "$trace_file" ]; then
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

assert_false() {
    local label="$1"
    shift
    if "$@"; then
        fail "$label"
    fi
    assertions=$((assertions + 1))
}

# 1. 提取被测生产函数 (直接从 root/usr/bin/feiyoung.sh 提取)
source <(sed -n '/^mask_user() {/,/^}/p' "$src")
source <(sed -n '/^get_base() {/,/^}/p' "$src")
source <(sed -n '/^check_account_online() {/,/^}/p' "$src")
source <(sed -n '/^login_account() {/,/^}/p' "$src")
source <(sed -n '/^keepalive_account() {/,/^}/p' "$src")

# 2. Mock 基础环境与配置变量
UA_PC="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151.0.0.0 Safari/537.36"
UA_MOBILE="Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36"
gateway="http://58.53.199.144:8001"
passType="1"
connect_timeout=2
total_timeout=3

trace_file="$test_dir/curl.trace"
mock_stage=""

log() { :; }

# 3. 手机号隐私掩码单元测试
assert_eq "189****1111" "$(mask_user "18900001111")" "11-digit phone masking"
assert_eq "138****1234" "$(mask_user "13800131234")" "standard phone masking"
assert_eq "admin" "$(mask_user "admin")" "short username untouched"
assert_eq "http://58.53.199.144:8001" "$(get_base "http://58.53.199.144:8001/style/school_hbct/pc/index.jsp?userip=1.1.1.1")" "get_base extraction"

# 4. 在线状态探测单元测试 (check_account_online)
curl_http_code=200
curl() {
    printf '%s\n' "$*" >> "$trace_file"
    for arg in "$@"; do
        if [ "$arg" = '%{http_code}' ]; then
            printf '%s' "$curl_http_code"
            return 0
        fi
    done
}

assert_true "online check when HTTP 200" check_account_online "wan" "pc"
curl_http_code=204
assert_true "online check when HTTP 204" check_account_online "wan" "pc"
curl_http_code=404
assert_true "online check when HTTP 404" check_account_online "wan" "pc"
curl_http_code=302
assert_false "offline check when intercepted with HTTP 302" check_account_online "wan" "pc"
curl_http_code=000
assert_false "offline check when connection failed" check_account_online "wan" "pc"

# 5. Mock 模拟完整 PC 认证流 (HTML 页面提取 paramStr)
ACCT_1_USER="18900001111"
ACCT_1_PASS="654321"
ACCT_1_TYPE="pc"
ACCT_1_DEV="wan"

mock_stage="pc_success"
curl() {
    local dump_hdr="" out_file="" ua="" data="" url="" interface=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -D) dump_hdr="$2"; shift 2 ;;
            -o) out_file="$2"; shift 2 ;;
            -A) ua="$2"; shift 2 ;;
            --interface) interface="$2"; shift 2 ;;
            --data|--data-urlencode)
                if [ -n "$data" ]; then
                    data="${data}&${2}"
                else
                    data="$2"
                fi
                shift 2 ;;
            http://*|https://*) url="$1"; shift ;;
            *) shift ;;
        esac
    done

    printf 'stage=%s method=%s url=%s dev=%s dump_hdr=%s data=%s\n' \
        "$mock_stage" "$([ -n "$data" ] && echo POST || echo GET)" "$url" "$interface" "$dump_hdr" "$data" >> "$trace_file"

    # Stage: 门户探测重定向
    if [[ "$url" =~ (223.5.5.5|119.29.29.29|114.114.114.114) ]]; then
        if [ "$dump_hdr" = "-" ] || [ -z "$dump_hdr" ]; then
            printf 'HTTP/1.1 302 Found\r\nLocation: http://58.53.199.144:8001/style/school_hbct/pc/index.jsp?userip=100.64.42.36\r\n\r\n'
        else
            printf 'HTTP/1.1 302 Found\r\nLocation: http://58.53.199.144:8001/style/school_hbct/pc/index.jsp?userip=100.64.42.36\r\n\r\n' > "$dump_hdr"
        fi
        return 0
    fi

    # Stage: PC 页面抓取 (HTML 内嵌 paramStr)
    if [[ "$url" =~ /style/school_hbct/pc/index.jsp ]]; then
        printf '<html><frame src="/style/school_hbct/pc/index.jsp?paramStr=PC_MOCK_TOKEN_12345"/></html>'
        return 0
    fi

    # Stage: POST 登录提交
    if [[ "$url" =~ /page_auth.jsp ]]; then
        if [[ "$mock_stage" == "pc_success" || "$mock_stage" == "mobile_success" ]]; then
            printf 'HTTP/1.1 302 Found\r\nLocation: http://58.53.199.144:8001/style/school_hbct/pc/logon.jsp\r\n\r\n'
        elif [[ "$mock_stage" == "fail_password" ]]; then
            printf 'HTTP/1.1 302 Found\r\nLocation: http://58.53.199.144:8001/login_fail.jsp?reason=auth_error\r\n\r\n'
        fi
        return 0
    fi
}

: > "$trace_file"
assert_true "PC login flow succeeds" login_account 1
assert_true "trace recorded PC portal and POST" grep -q "paramStr=PC_MOCK_TOKEN_12345" "$trace_file"

# 6. Mock 模拟移动端 (Mobile) 认证流 (302 Location 提取 paramStr 绕过 WAF 412)
ACCT_2_USER="18900001111"
ACCT_2_PASS="654321"
ACCT_2_TYPE="mobile"
ACCT_2_DEV="vwan1"

mock_stage="mobile_success"
curl() {
    local dump_hdr="" out_file="" ua="" data="" url="" interface=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -D) dump_hdr="$2"; shift 2 ;;
            -o) out_file="$2"; shift 2 ;;
            -A) ua="$2"; shift 2 ;;
            --interface) interface="$2"; shift 2 ;;
            --data|--data-urlencode)
                if [ -n "$data" ]; then
                    data="${data}&${2}"
                else
                    data="$2"
                fi
                shift 2 ;;
            http://*|https://*) url="$1"; shift ;;
            *) shift ;;
        esac
    done

    printf 'stage=%s method=%s url=%s dev=%s data=%s\n' \
        "$mock_stage" "$([ -n "$data" ] && echo POST || echo GET)" "$url" "$interface" "$data" >> "$trace_file"

    # Stage: 移动端门户探测
    if [[ "$url" =~ (223.5.5.5|119.29.29.29|114.114.114.114) ]]; then
        printf 'HTTP/1.1 302 Found\r\nLocation: http://58.53.199.144:8001/style/school_hbct/pc/index.jsp?userip=100.64.84.223\r\n\r\n'
        return 0
    fi

    # Stage: 移动端请求门户被 302 拦截到 mobile/index.jsp?paramStr=... (绕过 412)
    if [[ "$url" =~ /style/school_hbct/pc/index.jsp ]]; then
        if [ -n "$dump_hdr" ]; then
            printf 'HTTP/1.1 302 Found\r\nLocation: http://58.53.199.144:8001/style/school_hbct/mobile/index.jsp?paramStr=MOB_MOCK_TOKEN_67890\r\n\r\n' > "$dump_hdr"
        fi
        return 0
    fi

    # Stage: 提交认证
    if [[ "$url" =~ /page_auth.jsp ]]; then
        printf 'HTTP/1.1 302 Found\r\nLocation: http://58.53.199.144:8001/style/school_hbct/mobile/logon.jsp\r\n\r\n'
        return 0
    fi
}

: > "$trace_file"
assert_true "Mobile login flow succeeds via 302 token extraction" login_account 2
assert_true "trace recorded Mobile paramStr extraction" grep -q "paramStr=MOB_MOCK_TOKEN_67890" "$trace_file"

# 7. Mock 登录失败场景 (密码错误)
mock_stage="fail_password"
assert_false "login fails on incorrect credentials" login_account 1

# 8. 会话保活打卡测试 (keepalive_account)
: > "$trace_file"
touch "/tmp/feiyoung_cookie_1" "/tmp/feiyoung_cookie_2"
curl() {
    printf 'keepalive args=%s\n' "$*" >> "$trace_file"
}
keepalive_account 1
wait $! 2>/dev/null || true
assert_true "PC keepalive targeting pc/logon.jsp" grep -q "/style/school_hbct/pc/logon.jsp" "$trace_file"

keepalive_account 2
wait $! 2>/dev/null || true
assert_true "Mobile keepalive targeting mobile/logon.jsp" grep -q "/style/school_hbct/mobile/logon.jsp" "$trace_file"
rm -f "/tmp/feiyoung_cookie_1" "/tmp/feiyoung_cookie_2"

# 9. 特殊密码字符转义与 URL 编码测试 (含引号、美元符号、连接符)
ACCT_3_USER="18912345678"
ACCT_3_PASS='P@ss"w&o+r$d'
ACCT_3_TYPE="pc"
ACCT_3_DEV="wan"
mock_stage="pc_success"
curl() {
    local dump_hdr="" out_file="" ua="" data="" url="" interface=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -D) dump_hdr="$2"; shift 2 ;;
            -o) out_file="$2"; shift 2 ;;
            -A) ua="$2"; shift 2 ;;
            --interface) interface="$2"; shift 2 ;;
            --data|--data-urlencode)
                if [ -n "$data" ]; then data="${data}&${2}"; else data="$2"; fi; shift 2 ;;
            http://*|https://*) url="$1"; shift ;;
            *) shift ;;
        esac
    done
    printf 'stage=%s method=%s url=%s dev=%s dump_hdr=%s data=%s\n' \
        "$mock_stage" "$([ -n "$data" ] && echo POST || echo GET)" "$url" "$interface" "$dump_hdr" "$data" >> "$trace_file"
    if [[ "$url" =~ (223.5.5.5|119.29.29.29|114.114.114.114) ]]; then
        if [ "$dump_hdr" = "-" ] || [ -z "$dump_hdr" ]; then
            printf 'HTTP/1.1 302 Found\r\nLocation: http://58.53.199.144:8001/style/school_hbct/pc/index.jsp?userip=100.64.42.36\r\n\r\n'
        else
            printf 'HTTP/1.1 302 Found\r\nLocation: http://58.53.199.144:8001/style/school_hbct/pc/index.jsp?userip=100.64.42.36\r\n\r\n' > "$dump_hdr"
        fi
        return 0
    fi
    if [[ "$url" =~ /style/school_hbct/pc/index.jsp ]]; then
        printf '<html><frame src="/style/school_hbct/pc/index.jsp?paramStr=PC_SPECIAL_TOKEN"/></html>'
        return 0
    fi
    if [[ "$url" =~ /page_auth.jsp ]]; then
        printf 'HTTP/1.1 302 Found\r\nLocation: http://58.53.199.144:8001/style/school_hbct/pc/logon.jsp\r\n\r\n'
        return 0
    fi
}
: > "$trace_file"
assert_true "Special character password login flow succeeds" login_account 3
assert_true "trace recorded encoded special password" grep -q "PassWord=P@ss\"w&o+r\$d" "$trace_file"

printf 'PASS: authentication flow, WAF bypass, status probing, and keepalive assertions=%d\n' "$assertions"
