#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
src="$root/root/usr/bin/feiyoung.sh"

# Extract only the production functions under test.  The daemon entry point is
# deliberately never sourced: this test must not touch router services.
source <(awk '/^get_base\(\)/,/^}/' "$src")
source <(awk '/^mode_path\(\)/,/^}/' "$src")
source <(awk '/^portal_url\(\)/,/^}/' "$src")
source <(awk '/^portal_entry_from_html\(\)/,/^}/' "$src")
source <(awk '/^fetch_portal_page\(\)/,/^}/' "$src")
source <(awk '/^init_network\(\)/,/^}/' "$src")
source <(awk '/^login\(\)/,/^}/' "$src")
source <(awk '/^set_client_mode\(\)/,/^}/' "$src")
source <(awk '/^keepalive\(\)/,/^}/' "$src")
source <(awk '/^diag\(\)/,/^}/' "$src")

gateway='http://portal.test:8001'
PC_UA='PC-UA'
MOBILE_UA='MOBILE-UA'
CURL_OPTS='-s --connect-timeout 5 --max-time 10'
diagnostics=1
diag_seq=0
pass_fixtures=0
total_assertions=0
fixture_assertions=0
fixture_name=''

test_root="$(mktemp -d)"
cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT

log() {
    printf '%s\n' "$*" >> "$RUN_DIR/log"
}

logger() {
    printf '%s\n' "$*" >> "$RUN_DIR/diag"
}

fail() {
    printf 'FAIL fixture=%s assertion=%s\n' "${fixture_name:-none}" "$1" >&2
    if [ -n "${RUN_DIR:-}" ] && [ -f "$RUN_DIR/failure" ] && [ -s "$RUN_DIR/failure" ]; then
        printf '%s\n' 'stub failures:' >&2
        cat "$RUN_DIR/failure" >&2
    fi
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$label (expected=$expected actual=$actual)"
    fi
    fixture_assertions=$((fixture_assertions + 1))
    total_assertions=$((total_assertions + 1))
}

assert_true() {
    local label="$1"
    shift
    if ! "$@"; then
        fail "$label"
    fi
    fixture_assertions=$((fixture_assertions + 1))
    total_assertions=$((total_assertions + 1))
}

assert_file_contains() {
    local file="$1" needle="$2" label="$3"
    if ! grep -Fq -- "$needle" "$file"; then
        fail "$label (missing=$needle file=$file)"
    fi
    fixture_assertions=$((fixture_assertions + 1))
    total_assertions=$((total_assertions + 1))
}

assert_file_not_contains() {
    local file="$1" needle="$2" label="$3"
    if grep -Fq -- "$needle" "$file"; then
        fail "$label (unexpected=$needle file=$file)"
    fi
    fixture_assertions=$((fixture_assertions + 1))
    total_assertions=$((total_assertions + 1))
}

assert_requests_not_contains() {
    local needle="$1" label="$2"
    if grep -RFq -- "$needle" "$RUN_DIR/requests"; then
        fail "$label (unexpected=$needle request logs=$RUN_DIR/requests)"
    fi
    fixture_assertions=$((fixture_assertions + 1))
    total_assertions=$((total_assertions + 1))
}

assert_ua_sequence() {
    local expected="$1" label="$2" actual
    actual=$(for request in "$RUN_DIR"/requests/*.log; do sed -n 's/^ua=//p' "$request"; done | paste -sd/ -)
    assert_eq "$expected" "$actual" "$label"
}

start_fixture() {
    fixture_name="$1"
    FIXTURE="$1"
    RUN_DIR="$test_root/$FIXTURE"
    mkdir -p "$RUN_DIR/requests"
    : > "$RUN_DIR/sequence"
    : > "$RUN_DIR/failure"
    : > "$RUN_DIR/log"
    : > "$RUN_DIR/diag"
    fixture_assertions=0

    # Set the mode through the production function, then redirect only the
    # test's cookie I/O to the fixture directory.  Keeping last_client_type
    # equal avoids the function's real-router cleanup paths.
    client_type="$2"
    last_client_type="$client_type"
    set_client_mode "$client_type"
    if [ "$client_type" = mobile ]; then
        assert_eq '/tmp/feiyoung_cookie_mobile' "$COOKIE_JAR" 'set_client_mode mobile cookie contract'
    else
        assert_eq '/tmp/feiyoung_cookie_pc' "$COOKIE_JAR" 'set_client_mode pc cookie contract'
    fi
    COOKIE_JAR="$RUN_DIR/cookie"

    gateway='http://portal.test:8001'
    PORTAL_URL=''
    paramStr=''
    fyhtml=''
    auth_ready=0
    auth_client_type=''
    PAGE_HTTP=000
    PAGE_BODY=''
    PAGE_URL=''
    user='demo-user'
    password='demo-pass'
    passType=1
    login_attempts=0
    login_successes=0
}

pass_fixture() {
    local requests
    requests=$(find "$RUN_DIR/requests" -type f -name '*.log' | wc -l | tr -d ' ')
    if [ -s "$RUN_DIR/failure" ]; then
        fail 'stub failure file is not empty'
    fi
    printf 'PASS fixture=%s assertions=%d requests=%s\n' "$fixture_name" "$fixture_assertions" "$requests"
    pass_fixtures=$((pass_fixtures + 1))
}

stub_failure() {
    printf '%s\n' "$*" >> "$RUN_DIR/failure"
}

# The curl function is intentionally a shell stub.  Each invocation persists
# its sequence number and request fields in the mktemp directory because curl
# is called through command substitution inside the production functions.
curl() {
    local out_h='' out_b='' writeout='' ua='' cookie_in='' cookie_out='' referer=''
    local include=0 method=GET data='' url='' arg header_line='' data_urlencoded=''
    local index headers='' body='' status='' rc=0
    local sequence

    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
            -D|--dump-header) [ "$#" -gt 0 ] || { stub_failure "missing -D value"; return 97; }; out_h="$1"; shift ;;
            -o|--output) [ "$#" -gt 0 ] || { stub_failure "missing -o value"; return 97; }; out_b="$1"; shift ;;
            -A|--user-agent) [ "$#" -gt 0 ] || { stub_failure "missing -A value"; return 97; }; ua="$1"; shift ;;
            -b|--cookie) [ "$#" -gt 0 ] || { stub_failure "missing -b value"; return 97; }; cookie_in="$1"; shift ;;
            -c|--cookie-jar) [ "$#" -gt 0 ] || { stub_failure "missing -c value"; return 97; }; cookie_out="$1"; shift ;;
            -e|--referer) [ "$#" -gt 0 ] || { stub_failure "missing -e value"; return 97; }; referer="$1"; shift ;;
            -w|--write-out) [ "$#" -gt 0 ] || { stub_failure "missing -w value"; return 97; }; writeout="$1"; shift ;;
            --data|--data-raw|--data-binary|-d) [ "$#" -gt 0 ] || { stub_failure "missing --data value"; return 97; }; method=POST; data="$1"; shift ;;
            --data-urlencode) [ "$#" -gt 0 ] || { stub_failure "missing --data-urlencode value"; return 97; }; method=POST; data_urlencoded="${data_urlencoded}${data_urlencoded:+$'\n'}$1"; shift ;;
            -H|--header) [ "$#" -gt 0 ] || { stub_failure "missing -H value"; return 97; }; header_line="$1"; shift ;;
            -i|--include) include=1 ;;
            --proto|--connect-timeout|--max-time) [ "$#" -gt 0 ] || { stub_failure "missing $arg value"; return 97; }; shift ;;
            -s|-q|--silent|--compressed) : ;;
            --) [ "$#" -gt 0 ] || { stub_failure 'missing URL after --'; return 97; }; url="$1"; shift ;;
            http://*|https://*) url="$arg" ;;
            *) stub_failure "unparsed curl argument: $arg"; return 97 ;;
        esac
    done

    sequence=$(cat "$RUN_DIR/sequence")
    index=$((sequence + 1))
    printf '%s\n' "$index" > "$RUN_DIR/sequence"
    {
        printf 'index=%s\n' "$index"
        printf 'fixture=%s\n' "$FIXTURE"
        printf 'method=%s\n' "$method"
        printf 'url=%s\n' "$url"
        printf 'ua=%s\n' "$ua"
        printf 'cookie_in=%s\n' "$cookie_in"
        printf 'cookie_out=%s\n' "$cookie_out"
        printf 'cookie_before=%s\n' "$([ -n "$cookie_in" ] && [ -f "$cookie_in" ] && printf 1 || printf 0)"
        printf 'output=%s\n' "$out_b"
        printf 'referer=%s\n' "$referer"
        printf 'data=%s\n' "$data"
        printf 'data_urlencoded=%s\n' "$data_urlencoded"
        printf 'fixed_fields=%s\n' "$([ -n "$data" ] && printf '%s' "$data" | awk -F'&' '{print NF}' || printf 0)"
        printf 'encoded_fields=%s\n' "$([ -n "$data_urlencoded" ] && printf '%s' "$data_urlencoded" | awk 'NF {n++} END {print n+0}' || printf 0)"
        if [ "$method" = POST ]; then
            printf 'total_fields=%s\n' "$(( $( [ -n "$data" ] && printf '%s' "$data" | awk -F'&' '{print NF}' || printf 0) + $( [ -n "$data_urlencoded" ] && printf '%s' "$data_urlencoded" | awk 'NF {n++} END {print n+0}' || printf 0) ))"
        fi
        printf 'header=%s\n' "$header_line"
        printf 'writeout=%s\n' "$writeout"
    } > "$RUN_DIR/requests/$(printf '%03d' "$index").log"

    case "$url" in
        *evil.test*)
            stub_failure "forbidden evil request index=$index url=$url"
            return 98
            ;;
    esac

    case "$FIXTURE:$index" in
        pc_direct:1)
            status=200; body='direct-pc'
            ;;
        mobile_direct:1)
            status=200; body='direct-mobile'
            ;;
        mobile_root_frame:1)
            status=412; body=''
            ;;
        mobile_root_frame:2)
            status=200; body='<frameset><frame name="mainFrame" src="/style/school_hbct/pc/index.jsp?paramStr=FRAME_TOKEN"></frameset>'
            ;;
        mobile_root_frame:3)
            status=200; body='selected-mobile'
            ;;
        mobile_bootstrap_redirect:1)
            status=412; body=''
            ;;
        mobile_bootstrap_redirect:2)
            status=302; body=''; headers=$'HTTP/1.1 302 Found\r\nLocation: /style/school_hbct/mobile/index.jsp?paramStr=BOOT_TOKEN\r\n\r\n'
            ;;
        mobile_bootstrap_redirect:3)
            status=200; body='mobile-terminal-desktop-ua'
            ;;
        mobile_bootstrap_redirect:4)
            status=200; body='mobile-terminal-mobile-ua'
            ;;
        final_412:1|final_empty:1|final_curl:1)
            status=412; body=''
            ;;
        final_412:2|final_empty:2|final_curl:2)
            status=200; body='<frameset><frame name="mainFrame" src="/style/school_hbct/pc/index.jsp?paramStr=FAIL_TOKEN"></frameset>'
            ;;
        final_412:3)
            status=412; body=''
            ;;
        final_empty:3)
            status=200; body=''
            ;;
        final_curl:3)
            return 7
            ;;
        frame_external:1)
            status=412; body=''
            ;;
        frame_external:2)
            status=200; body='<frameset><frame name="mainFrame" src="http://evil.test/style/school_hbct/pc/index.jsp?paramStr=EVIL_FRAME"></frameset>'
            ;;
        redirect_external:1)
            status=302; body=''; headers=$'HTTP/1.1 302 Found\r\nLocation: http://evil.test/style/school_hbct/pc/index.jsp?paramStr=EVIL_REDIRECT\r\n\r\n'
            ;;
        login_success:1)
            status=200; body='login-init'
            ;;
        login_success:2)
            status=302; body=''; headers=$'HTTP/1.1 302 Found\r\nLocation: /style/school_hbct/pc/logon.jsp\r\n\r\n'
            ;;
        keepalive_200:1)
            status=200; body=''
            ;;
        keepalive_500:1)
            status=500; body=''
            ;;
        *)
            stub_failure "unexpected fixture request index=$index url=$url"
            return 99
            ;;
    esac

    if [ -z "$headers" ]; then
        headers="HTTP/1.1 $status Status\r\n\r\n"
    fi
    [ -z "$out_h" ] || printf '%b' "$headers" > "$out_h"
    [ -z "$out_b" ] || printf '%s' "$body" > "$out_b"
    if [ "$rc" -eq 0 ] && [ -n "$cookie_out" ] && [[ "$status" = 2* || "$status" = 3* ]]; then
        printf '# Netscape HTTP Cookie File\nportal.test\tFALSE\t/\tFALSE\t0\tSESSION\tfixture-%s\n' "$index" > "$cookie_out"
    fi
    if [ "$include" -eq 1 ]; then
        printf '%b' "$headers"
    fi
    if [ "$writeout" = '%{http_code}' ]; then
        printf '%s' "$status"
    fi
    return "$rc"
}

init_common() {
    PORTAL_URL="$1"
    if ! init_network; then
        return 1
    fi
    assert_eq 1 "$auth_ready" 'init auth_ready'
    assert_eq "$client_type" "$auth_client_type" 'init auth client type'
    assert_true 'init paramStr is nonempty' test -n "$paramStr"
}

start_fixture pc_direct pc
init_common "$gateway/style/school_hbct/pc/index.jsp?paramStr=PC_TOKEN"
assert_eq 1 "$(cat "$RUN_DIR/sequence")" 'pc direct request count'
assert_file_contains "$RUN_DIR/requests/001.log" 'method=GET' 'pc direct method'
assert_file_contains "$RUN_DIR/requests/001.log" 'ua=PC-UA' 'pc direct UA'
assert_file_contains "$RUN_DIR/requests/001.log" 'url=http://portal.test:8001/style/school_hbct/pc/index.jsp?paramStr=PC_TOKEN' 'pc direct URL'
pass_fixture

start_fixture mobile_direct mobile
init_common "$gateway/style/school_hbct/pc/index.jsp?paramStr=MOBILE_TOKEN"
assert_eq 1 "$(cat "$RUN_DIR/sequence")" 'mobile direct request count'
assert_file_contains "$RUN_DIR/requests/001.log" 'method=GET' 'mobile direct method'
assert_file_contains "$RUN_DIR/requests/001.log" 'ua=MOBILE-UA' 'mobile direct UA'
assert_file_contains "$RUN_DIR/requests/001.log" 'url=http://portal.test:8001/style/school_hbct/mobile/index.jsp?paramStr=MOBILE_TOKEN' 'mobile path replacement'
pass_fixture

start_fixture mobile_root_frame mobile
init_common "$gateway/"
assert_eq 3 "$(cat "$RUN_DIR/sequence")" 'mobile root frame request count'
assert_file_contains "$RUN_DIR/requests/001.log" 'ua=MOBILE-UA' 'mobile root first UA'
assert_file_contains "$RUN_DIR/requests/002.log" 'ua=PC-UA' 'mobile root desktop bootstrap UA'
assert_file_contains "$RUN_DIR/requests/003.log" 'ua=MOBILE-UA' 'mobile root selected UA'
assert_file_contains "$RUN_DIR/requests/001.log" 'url=http://portal.test:8001/' 'mobile root first URL'
assert_file_contains "$RUN_DIR/requests/002.log" 'url=http://portal.test:8001/' 'mobile root bootstrap URL'
assert_file_contains "$RUN_DIR/requests/003.log" 'url=http://portal.test:8001/style/school_hbct/mobile/index.jsp?paramStr=FRAME_TOKEN' 'mobile root selected URL'
assert_file_contains "$RUN_DIR/requests/002.log" 'cookie_before=0' 'mobile root starts bootstrap without cookie'
assert_file_contains "$RUN_DIR/requests/003.log" 'cookie_before=0' 'desktop bootstrap cookie cleared before selected request'
assert_ua_sequence 'MOBILE-UA/PC-UA/MOBILE-UA' 'mobile root exact UA sequence'
pass_fixture

start_fixture mobile_bootstrap_redirect mobile
init_common "$gateway/"
assert_eq 4 "$(cat "$RUN_DIR/sequence")" 'mobile bootstrap redirect request count'
assert_file_contains "$RUN_DIR/requests/001.log" 'ua=MOBILE-UA' 'bootstrap initial mobile UA'
assert_file_contains "$RUN_DIR/requests/002.log" 'ua=PC-UA' 'bootstrap redirect root UA'
assert_file_contains "$RUN_DIR/requests/003.log" 'ua=PC-UA' 'bootstrap redirected terminal desktop UA'
assert_file_contains "$RUN_DIR/requests/004.log" 'ua=MOBILE-UA' 'bootstrap terminal mobile reGET UA'
assert_file_contains "$RUN_DIR/requests/003.log" 'url=http://portal.test:8001/style/school_hbct/mobile/index.jsp?paramStr=BOOT_TOKEN' 'bootstrap redirected terminal URL'
assert_file_contains "$RUN_DIR/requests/004.log" 'url=http://portal.test:8001/style/school_hbct/mobile/index.jsp?paramStr=BOOT_TOKEN' 'bootstrap mobile reGET URL'
assert_file_contains "$RUN_DIR/requests/004.log" 'cookie_before=0' 'bootstrap cookie cleared before mobile reGET'
assert_ua_sequence 'MOBILE-UA/PC-UA/PC-UA/MOBILE-UA' 'bootstrap exact UA sequence'
pass_fixture

for failing_fixture in final_412 final_empty final_curl; do
    start_fixture "$failing_fixture" mobile
    PORTAL_URL="$gateway/"
    if init_network; then
        fail 'selected final page unexpectedly accepted'
    fi
    assert_eq 0 "$auth_ready" "$failing_fixture auth_ready reset"
    assert_eq '' "$paramStr" "$failing_fixture paramStr reset"
    before_login=$(cat "$RUN_DIR/sequence")
    if login; then
        fail "$failing_fixture login unexpectedly accepted"
    fi
    assert_eq "$before_login" "$(cat "$RUN_DIR/sequence")" "$failing_fixture login does not call curl"
    pass_fixture
done

start_fixture frame_external mobile
if init_network; then
    fail 'external frame unexpectedly accepted'
fi
assert_eq 0 "$auth_ready" 'external frame auth_ready reset'
assert_eq 2 "$(cat "$RUN_DIR/sequence")" 'external frame request count'
assert_requests_not_contains 'evil.test' 'external frame no evil request'
pass_fixture

start_fixture redirect_external pc
PORTAL_URL="$gateway/"
if init_network; then
    fail 'external redirect unexpectedly accepted'
fi
assert_eq 0 "$auth_ready" 'external redirect auth_ready reset'
assert_eq 1 "$(cat "$RUN_DIR/sequence")" 'external redirect request count'
assert_file_not_contains "$RUN_DIR/requests/001.log" 'evil.test' 'external redirect no evil request'
pass_fixture

start_fixture login_success pc
init_common "$gateway/style/school_hbct/pc/index.jsp?paramStr=LOGIN_TOKEN"
if ! login; then
    fail 'login success fixture failed'
fi
assert_eq 2 "$(cat "$RUN_DIR/sequence")" 'login request count'
assert_file_contains "$RUN_DIR/requests/002.log" 'method=POST' 'login method'
assert_file_contains "$RUN_DIR/requests/002.log" 'ua=PC-UA' 'login UA'
assert_file_contains "$RUN_DIR/requests/002.log" 'cookie_before=1' 'login cookie'
assert_file_contains "$RUN_DIR/requests/002.log" 'referer=http://portal.test:8001/style/school_hbct/pc/index.jsp?paramStr=LOGIN_TOKEN' 'login mode Referer'
assert_file_contains "$RUN_DIR/requests/002.log" 'data=UserType=1&paramStr=LOGIN_TOKEN&pwdType=1&aidcauthtype=0&vfcodeflg=false' 'login fixed fields'
assert_file_contains "$RUN_DIR/requests/002.log" $'data_urlencoded=UserName=demo-user\nPassWord=demo-pass' 'login encoded credentials'
assert_file_contains "$RUN_DIR/requests/002.log" 'fixed_fields=5' 'login fixed field count'
assert_file_contains "$RUN_DIR/requests/002.log" 'encoded_fields=2' 'login encoded field count'
assert_file_contains "$RUN_DIR/requests/002.log" 'total_fields=7' 'login total field count'
pass_fixture

for keepalive_fixture in keepalive_200 keepalive_500; do
    start_fixture "$keepalive_fixture" pc
    PORTAL_URL="$gateway/style/school_hbct/pc/index.jsp?paramStr=KEEPALIVE_TOKEN"
    printf 'cookie\n' > "$COOKIE_JAR"
    if [ "$keepalive_fixture" = keepalive_200 ]; then
        if ! keepalive; then
            fail 'keepalive 200 rejected'
        fi
    else
        if keepalive; then
            fail 'keepalive 500 accepted'
        fi
    fi
    assert_eq 1 "$(cat "$RUN_DIR/sequence")" "$keepalive_fixture request count"
    assert_file_contains "$RUN_DIR/requests/001.log" 'output=/dev/null' "$keepalive_fixture output sink"
    assert_file_contains "$RUN_DIR/requests/001.log" 'writeout=%{http_code}' "$keepalive_fixture write-out"
    assert_file_contains "$RUN_DIR/requests/001.log" 'url=http://portal.test:8001/style/school_hbct/pc/logon.jsp' "$keepalive_fixture endpoint"
    assert_file_contains "$RUN_DIR/requests/001.log" 'cookie_before=1' "$keepalive_fixture cookie"
    assert_file_contains "$RUN_DIR/requests/001.log" 'referer=http://portal.test:8001/style/school_hbct/pc/index.jsp?paramStr=KEEPALIVE_TOKEN' "$keepalive_fixture referer"
    pass_fixture
done

printf 'PASS summary fixtures=%d assertions=%d\n' "$pass_fixtures" "$total_assertions"
