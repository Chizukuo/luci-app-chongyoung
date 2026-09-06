#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
src="$root/root/usr/bin/feiyoung.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
source <(awk '/^get_base\(\)/,/^}/' "$src")
source <(awk '/^mode_path\(\)/,/^}/' "$src")
source <(awk '/^portal_url\(\)/,/^}/' "$src")
source <(awk '/^portal_entry_from_html\(\)/,/^}/' "$src")
source <(awk '/^fetch_portal_page\(\)/,/^}/' "$src")
# The production function names fixed cookie paths.  Rewrite only those paths
# while loading the function so this test cannot touch a real session jar.
test_cookie_dir="$(mktemp -d "${TMPDIR:-/tmp}/feiyoung-mode.XXXXXX")" || fail 'create cookie test directory'
test_cookie_pc="$test_cookie_dir/feiyoung_cookie_pc"
test_cookie_mobile="$test_cookie_dir/feiyoung_cookie_mobile"
cleanup_cookie_test() {
    rm -f -- "$test_cookie_pc" "$test_cookie_mobile" "$test_cookie_dir/curl-trace"
    rmdir -- "$test_cookie_dir"
}
trap cleanup_cookie_test EXIT
source <(awk '/^clear_auth_state\(\)/,/^}/' "$src" | sed \
    -e 's|/tmp/feiyoung_cookie_pc|"$test_cookie_pc"|g' \
    -e 's|/tmp/feiyoung_cookie_mobile|"$test_cookie_mobile"|g')
source <(awk '/^set_client_mode\(\)/,/^}/' "$src" | sed \
    -e 's|/tmp/feiyoung_cookie_pc|"$test_cookie_pc"|g' \
    -e 's|/tmp/feiyoung_cookie_mobile|"$test_cookie_mobile"|g')
source <(awk '/^keepalive\(\)/,/^}/' "$src")
diag() { :; }
diagnostics=0; last_client_type=pc; PC_UA='PC-UA'; MOBILE_UA='MOBILE-UA'
COOKIE_JAR="$test_cookie_pc"
CURL_OPTS='-s'; FETCH_FIXTURE=ok
curl_trace="$test_cookie_dir/curl-trace"
curl() {
    local headers='' body='' out_h='' out_b='' arg url=''
    while [ "$#" -gt 0 ]; do
        arg="$1"; shift
        case "$arg" in
            -D) out_h="$1"; shift ;;
            -o) out_b="$1"; shift ;;
            -w) shift ;;
            http://*|https://*) url="$arg" ;;
        esac
    done
    case "$FETCH_FIXTURE" in
        cross) headers='HTTP/1.1 302 Found\r\nLocation: http://evil.test/style/school_hbct/pc/index.jsp\r\n\r\n'; body='' ;;
        412) headers='HTTP/1.1 412 Precondition Failed\r\n\r\n'; body='' ;;
        empty) headers='HTTP/1.1 200 OK\r\n\r\n'; body='' ;;
        fail) return 7 ;;
        500) headers='HTTP/1.1 500 Server Error\r\n\r\n'; body='error' ;;
        *) headers='HTTP/1.1 200 OK\r\n\r\n'; body='paramStr=SAFE%2BVALUE' ;;
    esac
    if [ -n "$curl_trace" ]; then printf '%s' "$out_b" > "$curl_trace"; fi
    if [ -n "$out_h" ]; then printf '%b' "$headers" > "$out_h"; fi
    if [ -n "$out_b" ]; then printf '%s' "$body" > "$out_b"; fi
    case "$FETCH_FIXTURE" in cross) printf '302';; 412) printf '412';; 500) printf '500';; *) printf '200';; esac
}
gateway='http://portal.test:8001'; PORTAL_URL="$gateway/root"
client_type=mobile
got=$(mode_path 'http://portal.test:8001/style/school_hbct/pc/index.jsp?paramStr=A%2BB+%2F&path=/pc/keep')
[ "$got" = 'http://portal.test:8001/style/school_hbct/mobile/index.jsp?paramStr=A%2BB+%2F&path=/pc/keep' ] || fail 'mobile path/query preservation'
[ "$(mode_path 'http://portal.test:8001/style/school_hbct/pc/index.jsp?paramStr=A%2BB+%2F')" = 'http://portal.test:8001/style/school_hbct/mobile/index.jsp?paramStr=A%2BB+%2F' ] || fail 'direct pc entry mode switch'
[ "$(mode_path 'http://portal.test:8001/other?next=/style/school_hbct/pc/index.jsp')" = 'http://portal.test:8001/other?next=/style/school_hbct/pc/index.jsp' ] || fail 'query template must not be rewritten'
html='<frameset><frame name="mainFrame" src="/style/school_hbct/pc/index.jsp?paramStr=A%2BB+%2F"></frameset>'
[ "$(portal_entry_from_html "$html")" = 'http://portal.test:8001/style/school_hbct/mobile/index.jsp?paramStr=A%2BB+%2F' ] || fail 'same origin frame extraction'
bad='<frame name="mainFrame" src="http://evil.test/style/school_hbct/pc/index.jsp?paramStr=SECRET">'
if portal_entry_from_html "$bad"; then fail 'cross origin frame accepted'; fi
if portal_entry_from_html '<frame name="mainFrame" src="https://portal.test:8443/style/school_hbct/pc/index.jsp?paramStr=X">'; then fail 'cross origin port accepted'; fi
client_type=pc
[ "$(mode_path 'http://portal.test:8001/style/school_hbct/mobile/index.jsp?x=/mobile/')" = 'http://portal.test:8001/style/school_hbct/pc/index.jsp?x=/mobile/' ] || fail 'pc path/query preservation'
[ "$(mode_path 'http://portal.test:8001/style/school_hbct/mobile/index.jsp?paramStr=A%2BB+%2F')" = 'http://portal.test:8001/style/school_hbct/pc/index.jsp?paramStr=A%2BB+%2F' ] || fail 'direct mobile entry mode switch'
if portal_url 'http://evil.test/style/school_hbct/pc/index.jsp' "$gateway/" >/dev/null; then fail 'cross-origin Location accepted'; fi
FETCH_FIXTURE=412; if fetch_portal_page "$gateway/" test; then fail '412 accepted'; fi
FETCH_FIXTURE=empty; if fetch_portal_page "$gateway/" test; then fail 'empty 200 accepted'; fi
FETCH_FIXTURE=fail; if fetch_portal_page "$gateway/" test; then fail 'curl failure accepted'; fi
touch "$test_cookie_pc" "$test_cookie_mobile"
paramStr=OLD; PORTAL_URL=OLD; fyhtml=OLD; auth_ready=1; auth_client_type=pc
set_client_mode mobile
[ "$client_type" = mobile ] || fail 'mobile mode selection'
[ "$UA" = MOBILE-UA ] || fail 'mobile UA selection'
[ "$COOKIE_JAR" = "$test_cookie_mobile" ] || fail 'mobile cookie selection'
[ ! -e "$test_cookie_pc" ] && [ ! -e "$test_cookie_mobile" ] || fail 'mode switch did not clear cookies'
[ -z "$paramStr" ] && [ -z "$PORTAL_URL" ] && [ -z "$fyhtml" ] || fail 'mode switch did not clear portal state'
[ "$auth_ready" = 0 ] && [ -z "$auth_client_type" ] || fail 'mode switch did not clear auth state'
touch "$COOKIE_JAR"; PORTAL_URL="$gateway/style/school_hbct/mobile/index.jsp?paramStr=X"; FETCH_FIXTURE=ok
: > "$curl_trace"
if ! keepalive; then fail '200 keepalive failed'; fi
[ "$(<"$curl_trace")" = /dev/null ] || fail 'keepalive must discard response body'
FETCH_FIXTURE=500
if keepalive; then fail '500 keepalive accepted'; fi
printf 'PASS: authentication mode path, query bytes, and same-origin frame checks\n'
