#!/usr/bin/env bash
set -euo pipefail
source_file="$(cd "$(dirname "$0")/../.." && pwd)/root/usr/bin/feiyoung.sh"
test_parent="$(cd "$(dirname "$0")" && pwd)"
tmp_dir="$(mktemp -d "$test_parent/.core.XXXXXX")"
case "$tmp_dir" in "$test_parent"/*) ;; *) exit 1 ;; esac
trap 'case "$tmp_dir" in "$test_parent"/*) rm -rf -- "$tmp_dir" ;; esac' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "missing expected text: $2"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "forbidden text found: $2"; }
logger() { printf '%s\n' "$*" >> "$tmp_dir/log"; }
log() { printf '%s\n' "$*" >> "$tmp_dir/log"; }
source <(awk '/^diag_url\(\)/,/^}/' "$source_file")
source <(awk '/^diag\(\)/,/^}/' "$source_file")
assert_eq "$(diag_url 'http://user:pass@example.com/path-token-SECRET?token=SECRET#frag')" other 'URL category'
assert_eq "$(diag_url $'http://user:pass@example.com/path-token-SECRET\nleak')" other 'newline URL category'
: > "$tmp_dir/log"; diagnostics=1; diag_seq=0
diag 'event=test secret_free=1'
assert_contains "$tmp_dir/log" 'FEIYOUNG_DIAG build=2.2.0-1 seq=1 client_type=pc event=test'
: > "$tmp_dir/log"; diagnostics=0; diag 'event=must_not_emit'
[ ! -s "$tmp_dir/log" ] || fail 'diagnostics=0 emitted a record'
network_fixture="$tmp_dir/network_probe.sh"
{
    printf 'network_probe() {\n'
    awk '/local is_online=0/{p=1} p{print} /online_decision/{exit}' "$source_file"
    printf 'printf "%%s\\n" "$is_online"\n}\n'
} > "$network_fixture"
source "$network_fixture"
diagnostics=1; diag_seq=0; login_attempts=0; login_successes=0
PING_RESULTS=(); PING_INDEX=0; HTTP_CODE=000
ping() {
    local target="${!#}"
    printf 'ping %s\n' "$target" >> "$tmp_dir/trace"
    local result="${PING_RESULTS[$PING_INDEX]:-1}"
    PING_INDEX=$((PING_INDEX + 1)); return "$result"
}
curl() { printf 'curl %s\n' "$*" >> "$tmp_dir/trace"; printf '%s' "$HTTP_CODE"; return 0; }
sleep() { printf 'sleep %s\n' "$*" >> "$tmp_dir/trace"; }
run_probe() { PING_RESULTS=($1); PING_INDEX=0; HTTP_CODE="$2"; : > "$tmp_dir/trace"; if network_probe > "$tmp_dir/result"; then :; else :; fi; }
run_probe '0' 000
assert_eq "$(<"$tmp_dir/result")" 1 'first ping decision'; assert_eq "$(grep -c '^ping ' "$tmp_dir/trace")" 1 'first ping count'; assert_not_contains "$tmp_dir/trace" 'curl '
run_probe '1 0' 000
assert_eq "$(<"$tmp_dir/result")" 1 'second ping decision'; assert_eq "$(grep -c '^ping ' "$tmp_dir/trace")" 2 'second ping count'; assert_not_contains "$tmp_dir/trace" 'curl '
run_probe '1 1' 200
assert_eq "$(<"$tmp_dir/result")" 1 'HTTP 200 decision'; assert_eq "$(grep -c '^ping ' "$tmp_dir/trace")" 2 'HTTP 200 ping count'; assert_contains "$tmp_dir/trace" 'curl '
run_probe '1 1' 302; assert_eq "$(<"$tmp_dir/result")" 0 'HTTP 302 decision'
run_probe '1 1 0' 000
assert_eq "$(<"$tmp_dir/result")" 1 'retry decision'; assert_eq "$(grep -c '^ping ' "$tmp_dir/trace")" 3 'retry ping count'; assert_eq "$(grep -c '^sleep 1$' "$tmp_dir/trace")" 1 'retry sleep count'
run_probe '1 1 1 1' 000
assert_eq "$(<"$tmp_dir/result")" 0 'all failed decision'; assert_eq "$(grep -c '^ping ' "$tmp_dir/trace")" 4 'all failed ping count'; assert_eq "$(grep -c '^sleep 1$' "$tmp_dir/trace")" 1 'all failed sleep count'
source <(awk '/^get_base\(\)/,/^}/' "$source_file")
source <(awk '/^portal_url\(\)/,/^}/' "$source_file")
source <(awk '/^login\(\)/,/^}/' "$source_file")
COOKIE_JAR="$tmp_dir/cookie"; : > "$COOKIE_JAR"; CURL_OPTS=''; UA=test; gateway='http://portal.test'
user='TEST_USER'; password='TEST_PASS'; paramStr='TEST_PARAM'; passType=1; PORTAL_URL='http://portal.test/style/school_hbct/pc/index.jsp?paramStr=TEST_PARAM'
client_type=pc; auth_ready=1; auth_client_type=pc
login_attempts=0; login_successes=0; diagnostics=1; diag_seq=0; CURL_MODE=success
curl() {
    local data='' arg
    while [ "$#" -gt 0 ]; do
        arg="$1"; shift
        if [ "$arg" = '--data' ]; then data="$1"; shift; fi
        if [ "$arg" = '--data-urlencode' ]; then data="$data&$1"; shift; fi
    done
    printf '%s\n' "$data" >> "$tmp_dir/login_data"
    case "$CURL_MODE" in
        success) printf 'HTTP/1.1 302 Found\r\nLocation: /style/school_hbct/pc/logon.jsp\r\n\r\n'; return 0 ;;
        failure) printf 'HTTP/1.1 302 Found\r\nLocation: /login_fail.jsp\r\n\r\n'; return 0 ;;
        error) return 28 ;;
        *) return 1 ;;
    esac
}
run_login() { : > "$tmp_dir/login_data"; auth_ready=1; auth_client_type=pc; paramStr=TEST_PARAM; if login; then return 0; else return 1; fi; }
expected_data='UserType=1&paramStr=TEST_PARAM&pwdType=1&aidcauthtype=0&vfcodeflg=false&UserName=TEST_USER&PassWord=TEST_PASS'
if ! run_login; then fail 'success login failed'; fi
assert_eq "$login_attempts" 1 'success attempt count'; assert_eq "$login_successes" 1 'success count'; assert_eq "$(<"$tmp_dir/login_data")" "$expected_data" 'complete login data'
CURL_MODE=failure; if run_login; then fail 'failure login succeeded'; fi
assert_eq "$login_attempts" 2 'failure attempt count'; assert_eq "$login_successes" 1 'failure success count'
CURL_MODE=error; if run_login; then fail 'curl error succeeded'; fi
assert_eq "$login_attempts" 3 'error attempt count'; assert_eq "$login_successes" 1 'error success count'
assert_not_contains "$tmp_dir/log" 'TEST_USER'; assert_not_contains "$tmp_dir/log" 'TEST_PASS'; assert_not_contains "$tmp_dir/log" 'TEST_PARAM'
printf 'PASS: diagnostics privacy, probe paths, HTTP decisions, and login contract\n'
