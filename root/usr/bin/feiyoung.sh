#!/bin/sh
#
# luci-app-feiyoung: 自动认证脚本 (v2 - 湖北电信 school_hbct 门户)
# 说明：定时检测网络，未认证时通过重定向发现门户并自动登录。
# 注意：仅在 UCI 配置启用时运行。
#
CURL_OPTS="-s --connect-timeout 5 --max-time 10"
PC_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
MOBILE_UA="Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36"
UA="$PC_UA"
client_type=pc
COOKIE_JAR="/tmp/feiyoung_cookie_pc"
last_client_type=pc
auth_ready=0
auth_client_type=""

# 运行时变量（由 get_config / discover_portal / init_network 设置）
gateway=""      # 门户 base 地址，如 http://58.53.199.144:8001
PORTAL_URL=""   # 完整门户地址（含 userip/nasip/usermac 参数）
paramStr=""     # 登录 token

# get_5g_radios: 获取所有 5G 无线设备名称
get_5g_radios() {
    local dev
    for dev in $(uci -q show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
        local band=$(uci -q get wireless.$dev.band)
        local hwmode=$(uci -q get wireless.$dev.hwmode)
        local channel=$(uci -q get wireless.$dev.channel)

        local is_5g=0
        if [ "$band" = "5g" ] || [ "$band" = "6g" ]; then
            is_5g=1
        elif [ "$band" = "2g" ]; then
            is_5g=0
        elif [ "$hwmode" != "auto" ] && echo "$hwmode" | grep -q -E "11a|11ac|11ax|11be"; then
            is_5g=1
        elif [ -n "$channel" ] && [ "$channel" != "auto" ] && [ "$channel" -gt 14 ] 2>/dev/null; then
            is_5g=1
        fi

        if [ "$is_5g" = "1" ]; then
            echo "$dev"
        fi
    done
}

# disable_5g: 临时禁用 5G 无线广播（使用内存命令，避免 Flash 闪存磨损与夜间重启后永久丢失）
disable_5g() {
    local dev
    rm -f /tmp/feiyoung_disabled_radios
    for dev in $(get_5g_radios); do
        log "正在临时关闭 5G 无线设备: $dev"
        echo "$dev" >> /tmp/feiyoung_disabled_radios
        wifi down "$dev" >/dev/null 2>&1
    done
}

# enable_5g: 恢复被临时禁用的 5G 无线广播
enable_5g() {
    local dev
    if [ -f /tmp/feiyoung_disabled_radios ]; then
        for dev in $(cat /tmp/feiyoung_disabled_radios); do
            log "正在恢复 5G 无线设备: $dev"
            wifi up "$dev" >/dev/null 2>&1
        done
        rm -f /tmp/feiyoung_disabled_radios
    fi
}

# get_lan_interfaces: 获取所有物理有线 LAN 接口名称
get_lan_interfaces() {
    local port
    if [ -d "/sys/class/net/br-lan/brif" ]; then
        for port in $(ls /sys/class/net/br-lan/brif); do
            if ! echo "$port" | grep -q -E "wlan|ath|wl|ap"; then
                echo "$port"
            fi
        done
    else
        local ports=$(uci -q get network.lan.ports)
        [ -z "$ports" ] && ports=$(uci -q get network.lan.ifname)
        for port in $ports; do
            if ! echo "$port" | grep -q -E "wlan|ath|wl|ap"; then
                echo "$port"
            fi
        done
    fi
}

# disable_lan_ports: 临时关闭所有有线 LAN 网口以防止电脑 NCSI 误判
disable_lan_ports() {
    local port
    rm -f /tmp/feiyoung_disabled_lan_ports
    for port in $(get_lan_interfaces); do
        log "正在临时关闭有线网口: $port"
        echo "$port" >> /tmp/feiyoung_disabled_lan_ports
        ip link set "$port" down 2>/dev/null || ifconfig "$port" down 2>/dev/null
    done
}

# enable_lan_ports: 恢复有线 LAN 网口
enable_lan_ports() {
    local port
    if [ -f /tmp/feiyoung_disabled_lan_ports ]; then
        for port in $(cat /tmp/feiyoung_disabled_lan_ports); do
            log "正在恢复有线网口: $port"
            ip link set "$port" up 2>/dev/null || ifconfig "$port" up 2>/dev/null
        done
        rm -f /tmp/feiyoung_disabled_lan_ports
    fi
}

# cleanup: 脚本退出时若处于休眠断网状态，恢复网络接口
cleanup() {
    log "脚本退出，正在恢复网络接口..."
    rm -f /tmp/feiyoung_online
    if [ -f /tmp/feiyoung_wan_paused ]; then
        enable_5g
        enable_lan_ports
        ip link set br-lan up 2>/dev/null || ifconfig br-lan up 2>/dev/null
        wifi up >/dev/null 2>&1
        ifup wan >/dev/null 2>&1
        rm -f /tmp/feiyoung_wan_paused
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# log: 写入系统日志（tag: feiyoung）
log() {
    logger -t feiyoung "$1"
}

# update_status: 将状态写入 /tmp/feiyoung_status
update_status() {
    echo "$1" > /tmp/feiyoung_status
}

# get_base: 从完整 URL 提取 base（scheme://host:port）
get_base() {
    echo "$1" | sed -n 's#^\(https\?://[^/?]*\).*#\1#p'
}

# ensure_default_route: 确保存在默认路由（校园网 DHCP 偶发不下发网关到内核）
ensure_default_route() {
    [ -n "$(ip route show default 2>/dev/null)" ] && return 0
    local gw=$(ifstatus wan 2>/dev/null | sed -n 's/.*"nexthop": *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$gw" ] && gw="100.64.0.1"
    if ip route add default via "$gw" dev wan >/dev/null 2>&1; then
        log "已补充默认路由 via $gw"
    fi
}

# check_gateway_alive: 检查 WAN 网关二层 ARP 连通性
check_gateway_alive() {
    # 若 WAN 口尚未处于 UP 状态，说明正在申请 DHCP 或未就绪，绝不判定为网关失效
    local wan_up=$(ifstatus wan 2>/dev/null | sed -n 's/.*"up": *\([a-z]*\).*/\1/p' | head -1)
    [ "$wan_up" != "true" ] && return 0
    local gw=$(ifstatus wan 2>/dev/null | sed -n 's/.*"nexthop": *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$gw" ] && return 0

    if ip neigh show dev wan 2>/dev/null | grep -E "^$gw " | grep -q -E "INCOMPLETE|FAILED"; then
        return 1
    fi
    return 0
}

last_renew_time=0
last_keepalive_time=0
diag_seq=0
login_attempts=0
login_successes=0
diagnostics=0

# diag: emit bounded, secret-free structured diagnostics to the existing syslog.
diag() {
    [ "$diagnostics" = "1" ] || return 0
    diag_seq=$((diag_seq + 1))
    logger -t feiyoung "FEIYOUNG_DIAG build=2.2.0-1 seq=$diag_seq client_type=${client_type:-pc} $*" >/dev/null 2>&1 || :
}

clear_auth_state() {
    paramStr=""
    PORTAL_URL=""
    fyhtml=""
    auth_ready=0
    auth_client_type=""
    PAGE_URL=""
    PAGE_BODY=""
    if [ -n "${COOKIE_JAR:-}" ]; then
        rm -f -- "$COOKIE_JAR"
    fi
}

set_client_mode() {
    case "$1" in
        mobile) client_type=mobile; UA="$MOBILE_UA"; COOKIE_JAR=/tmp/feiyoung_cookie_mobile ;;
        *) client_type=pc; UA="$PC_UA"; COOKIE_JAR=/tmp/feiyoung_cookie_pc ;;
    esac
    umask 077
    if [ "$last_client_type" != "$client_type" ]; then
        clear_auth_state
        rm -f /tmp/feiyoung_cookie_pc /tmp/feiyoung_cookie_mobile
        diag "event=client_mode_changed"
    fi
    last_client_type="$client_type"
}

mode_path() {
    local origin tail path suffix
    origin=$(get_base "$1")
    tail=${1#"$origin"}
    path=${tail%%[?#]*}
    suffix=${tail#"$path"}
    case "$path" in
        /style/school_hbct/pc/index.jsp|/style/school_hbct/mobile/index.jsp)
            path="/style/school_hbct/$client_type/index.jsp" ;;
    esac
    printf '%s' "$origin$path$suffix"
}

# Redirects and frame targets must stay on the configured authentication origin.
portal_url() {
    local candidate="$1" base="$2" origin
    origin=$(get_base "$gateway")
    [ -n "$origin" ] || return 1
    case "$candidate" in
        //*) return 1 ;;
        http://*|https://*) : ;;
        /*) candidate="$origin$candidate" ;;
        \?*) candidate="${base%%\?*}$candidate" ;;
        *) candidate="${base%%\?*}"; candidate="${candidate%/*}/$1" ;;
    esac
    [ "$(get_base "$candidate")" = "$origin" ] || return 1
    printf '%s' "${candidate%%#*}"
}

portal_entry_from_html() {
    # Accept only the same-origin school_hbct frame URL; preserve its query bytes.
    local html="$1" src origin
    src=$(printf '%s' "$html" | sed -n 's/.*[Mm]ain[Ff]rame[^>]*src=["'"'"']\([^"'"'"']*school_hbct\/\(pc\|mobile\)\/index\.jsp[^"'"'"']*\).*/\1/p' | head -1)
    [ -n "$src" ] || src=$(printf '%s' "$html" | sed -n 's/.*src=["'"'"']\([^"'"'"']*school_hbct\/\(pc\|mobile\)\/index\.jsp[^"'"'"']*\).*/\1/p' | head -1)
    case "$src" in
        http://*|https://*) : ;;
        /*) origin=$(get_base "$PORTAL_URL"); [ -z "$origin" ] && origin="$gateway"; src="${origin}${src}" ;;
        *) return 1 ;;
    esac
    src=$(printf '%s' "$src" | sed 's/&amp;/\&/g')
    src=$(portal_url "$src" "$PORTAL_URL") || return 1
    mode_path "$src"
}

accept_portal_location() {
    local candidate
    candidate=$(portal_url "$1" "$gateway/") || { diag "event=portal_reject reason=origin_mismatch"; return 1; }
    PORTAL_URL="$candidate"
    return 0
}

# diag_url: map URLs to a fixed category; never emit URL material.
diag_url() {
    local value="$1"
    case "$value" in
        *page_auth.jsp*) printf 'page_auth' ;;
        *logon.jsp*/*mobile*|*logon.jsp*/*wap*|*/mobile/*|*/wap/*) printf 'school_hbct_mobile' ;;
        *logon.jsp*|*school_hbct*) printf 'school_hbct_pc' ;;
        *223.5.5.5*|*119.29.29.29*|*114.114.114.114*|*msftconnecttest*|*connectivitycheck*) printf 'connectivity_probe' ;;
        *) printf 'other' ;;
    esac
}

# renew_wan: 重置 WAN 接口并重新请求 DHCP 租约（带 60s 冷却保护，防止触发交换机 DHCP 泛洪限速）
renew_wan() {
    local now=$(date +%s)
    if [ $((now - last_renew_time)) -lt 60 ]; then
        log "WAN 口最近已执行过重置，处于 60s 冷却保护中，跳过重置..."
        diag "event=wan_renew_skip reason=cooldown"
        return 0
    fi
    last_renew_time=$now

    log "检测到上游网关不通或租约失效，正在重置 WAN 口并重新请求 DHCP..."
    diag "event=wan_renew_start reason=gateway_or_lease"
    update_status "运行中 - 正在重置 WAN 口 DHCP..."
    ifup wan >/dev/null 2>&1
    local count=0
    while [ $count -lt 8 ]; do
        sleep 1 &
        wait $!
        local gw=$(ifstatus wan 2>/dev/null | sed -n 's/.*"nexthop": *"\([^"]*\)".*/\1/p' | head -1)
        [ -n "$gw" ] && break
        count=$((count + 1))
    done
    ensure_default_route
    local ensure_rc=$?
    diag "event=wan_renew_done"
    return $ensure_rc
}

# get_config: 从 UCI 读取脚本所需配置；若未启用则退出脚本
get_config() {
    enabled=$(uci -q get feiyoung.general.enabled)
    [ "$enabled" = "1" ] || exit 0

    user=$(uci -q get feiyoung.general.username)
    password=$(uci -q get feiyoung.general.password)
    # 兼容旧配置字段
    [ -z "$password" ] && password=$(uci -q get feiyoung.general.password_seed)

    passType=$(uci -q get feiyoung.general.passType)
    [ -z "$passType" ] && passType=1

    gateway=$(uci -q get feiyoung.general.gateway)
    [ -z "$gateway" ] && gateway="http://58.53.199.144:8001"

    # 计划任务相关配置
    pause_enabled=$(uci -q get feiyoung.general.pause_enabled)
    pause_start=$(uci -q get feiyoung.general.pause_start)
    pause_end=$(uci -q get feiyoung.general.pause_end)
    pause_disconnect_wan=$(uci -q get feiyoung.general.pause_disconnect_wan)

    # 超时与间隔配置（默认值兜底）
    check_interval=$(uci -q get feiyoung.general.check_interval)
    [ -z "$check_interval" ] && check_interval=30

    connect_timeout=$(uci -q get feiyoung.general.connect_timeout)
    [ -z "$connect_timeout" ] && connect_timeout=5

    total_timeout=$(uci -q get feiyoung.general.total_timeout)
    [ -z "$total_timeout" ] && total_timeout=10

    CURL_OPTS="-s --connect-timeout $connect_timeout --max-time $total_timeout"
    diagnostics=$(uci -q get feiyoung.general.diagnostics)
    [ "$diagnostics" = "1" ] || diagnostics=0
    configured_client_type=$(uci -q get feiyoung.general.client_type)
    set_client_mode "$configured_client_type"
    return 0
}

# discover_portal: 通过访问普通 HTTP 站点触发重定向，获取完整门户地址（含参数）
# 返回：0 成功（PORTAL_URL 已设置），1 失败
discover_portal() {
    local site loc host ip headers curl_rc
    PORTAL_URL=""

    # 1. 纯 IP 触发 NAS 重定向（本地 NAS 拦截响应极快，设置 2s 超时加速探测）
    for site in "http://223.5.5.5" "http://119.29.29.29" "http://114.114.114.114"; do
        headers=$(curl -s --connect-timeout 2 --max-time 3 -A "$UA" -D - -o /dev/null "$site" 2>/dev/null); curl_rc=$?
        loc=$(printf '%s' "$headers" | grep -i '^Location:' | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')
        diag "event=portal_probe path=$(diag_url "$site") curl_rc=$curl_rc http_status=$(printf '%s' "$headers" | sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | head -1) location_present=$([ -n "$loc" ] && echo 1 || echo 0)"
        # 接受同源门户的网络参数或直接认证入口。
        if [ -n "$loc" ] && echo "$loc" | grep -Eq "userip=|paramStr="; then
            accept_portal_location "$loc" || continue
            return 0
        fi
    done

    # 2. 标准门户探测 URL（Windows/Android NCSI），优先使用 DHCP 分配的 DNS 解析
    local dns_server=""
    [ -f /tmp/resolv.conf.d/resolv.conf.auto ] && dns_server=$(awk '/^nameserver/ {print $2; exit}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null)
    [ -z "$dns_server" ] && [ -f /tmp/resolv.conf.auto ] && dns_server=$(awk '/^nameserver/ {print $2; exit}' /tmp/resolv.conf.auto 2>/dev/null)
    [ -z "$dns_server" ] && dns_server="202.103.44.150"

    for site in "www.msftconnecttest.com/redirect" "connectivitycheck.gstatic.com/generate_204"; do
        host="${site%%/*}"
        ip=$(nslookup "$host" "$dns_server" 2>/dev/null | awk '/^Address:/ {print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        [ -z "$ip" ] && continue
        headers=$(curl -s --connect-timeout 2 --max-time 3 -A "$UA" -H "Host: $host" -D - -o /dev/null "http://${ip}/${site#*/}" 2>/dev/null); curl_rc=$?
        loc=$(printf '%s' "$headers" | grep -i '^Location:' | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')
        diag "event=portal_probe path=$(diag_url "$site") curl_rc=$curl_rc http_status=$(printf '%s' "$headers" | sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | head -1) location_present=$([ -n "$loc" ] && echo 1 || echo 0)"
        if [ -n "$loc" ] && echo "$loc" | grep -Eq "userip=|paramStr="; then
            accept_portal_location "$loc" || continue
            return 0
        fi
    done
    return 1
}

# fetch_portal_page: bounded same-origin redirects; never log response bodies.
fetch_portal_page() {
    local url="$1" request_ua="$2" tmp hop=0 location next rc=1
    PAGE_HTTP=000; PAGE_BODY=""; PAGE_URL=""
    url=$(portal_url "$url" "$gateway/") || return 1
    url=$(mode_path "$url")
    tmp=$(mktemp -d /tmp/feiyoung-page.XXXXXX) || return 1
    while [ "$hop" -lt 5 ]; do
        PAGE_URL="$url"
        PAGE_HTTP=$(curl -q $CURL_OPTS --proto '=http,https' -A "$request_ua" \
            -b "$COOKIE_JAR" -c "$COOKIE_JAR" -D "$tmp/headers" -o "$tmp/body" \
            -w '%{http_code}' "$url" 2>/dev/null)
        local curl_rc=$?
        diag "event=portal_get curl_rc=$curl_rc http_status=$PAGE_HTTP hop=$hop"
        [ "$curl_rc" -eq 0 ] || break
        case "$PAGE_HTTP" in
            301|302|303|307|308)
                location=$(sed -n 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//p' "$tmp/headers" | head -1 | tr -d '\r')
                [ -n "$location" ] || break
                next=$(portal_url "$location" "$url") || { diag "event=portal_reject reason=origin_mismatch"; break; }
                url=$(mode_path "$next")
                hop=$((hop + 1))
                ;;
            2[0-9][0-9])
                [ -s "$tmp/body" ] || break
                [ "$(wc -c < "$tmp/body")" -le 1048576 ] || break
                PAGE_BODY=$(cat "$tmp/body")
                rc=0
                break
                ;;
            *) break ;;
        esac
    done
    rm -f "$tmp/headers" "$tmp/body"
    rmdir "$tmp"
    return "$rc"
}

# init_network: obtain a fresh token and cookie for the selected entry.
init_network() {
    local url="$PORTAL_URL" selected_entry path bootstrap=0
    clear_auth_state
    [ -n "$url" ] || url="$gateway/"
    url=$(portal_url "$url" "$gateway/") || { clear_auth_state; return 1; }
    url=$(mode_path "$url")
    if ! fetch_portal_page "$url" "$UA"; then
        # This portal rejects mobile UA at its root, but serves a PC frameset.
        # The bootstrap only supplies an entry URL; the selected entry uses mobile UA.
        path=${url#"$(get_base "$url")"}
        path=${path%%[?#]*}
        if [ "$client_type" != mobile ] || [ "$PAGE_HTTP" != 412 ] || \
            { [ -n "$path" ] && [ "$path" != / ]; } || \
            ! fetch_portal_page "$gateway/" "$PC_UA"; then
            log "无法取得所选模式的认证入口"
            clear_auth_state
            return 1
        fi
        bootstrap=1
        rm -f "$COOKIE_JAR"
    fi
    PORTAL_URL="$PAGE_URL"
    case "$PAGE_BODY" in
        *school_hbct/*/index.jsp*)
            selected_entry=$(portal_entry_from_html "$PAGE_BODY") || {
                log "认证入口来源或路径无效"
                clear_auth_state
                return 1
            }
            fetch_portal_page "$selected_entry" "$UA" || {
                log "所选模式认证页面请求失败"
                clear_auth_state
                return 1
            }
            ;;
        *)
            if [ "$bootstrap" = 1 ]; then
                fetch_portal_page "$PAGE_URL" "$UA" || { clear_auth_state; return 1; }
            fi
            ;;
    esac
    path=${PAGE_URL#"$(get_base "$PAGE_URL")"}
    path=${path%%[?#]*}
    if [ "$path" != "/style/school_hbct/$client_type/index.jsp" ]; then
        log "未取得所选模式的认证页面"
        clear_auth_state
        return 1
    fi
    PORTAL_URL="$PAGE_URL"
    fyhtml="$PAGE_BODY"
    paramStr=$(printf '%s' "$PORTAL_URL" | sed -n 's/.*[?&]paramStr=\([^&]*\).*/\1/p' | head -1)
    if [ -z "$paramStr" ]; then
        log "解析 paramStr 失败"
        clear_auth_state
        return 1
    fi
    auth_ready=1; auth_client_type="$client_type"
    diag "event=init_param param_present=1 param_len=${#paramStr} cookie_present=$([ -f "$COOKIE_JAR" ] && echo 1 || echo 0)"
    return 0
}

# login: 提交登录请求并判断结果
# 返回：0 成功，1 失败
login() {
    local base resp loc
    if [ "$auth_ready" != 1 ] || [ "$auth_client_type" != "$client_type" ] || [ -z "$paramStr" ] || \
        ! portal_url "$PORTAL_URL" "$gateway/" >/dev/null; then
        log "认证参数尚未就绪"
        clear_auth_state
        return 1
    fi
    base=$(get_base "$PORTAL_URL")
    [ -z "$base" ] && base="$gateway"

    login_attempts=$((login_attempts + 1))
    local diag_pwd_type=unknown
    [ "$passType" = "1" ] && diag_pwd_type=static
    [ "$passType" = "2" ] && diag_pwd_type=dynamic
    log "正在尝试登录..."
    diag "event=login_start attempt=$login_attempts pwdType=$diag_pwd_type fixed_UserType=1 fixed_aidcauthtype=0 fixed_vfcodeflg=false fields=7 user_present=$([ -n "$user" ] && echo 1 || echo 0) password_present=$([ -n "$password" ] && echo 1 || echo 0) param_present=$([ -n "$paramStr" ] && echo 1 || echo 0) param_len=${#paramStr}"

    resp=$(curl $CURL_OPTS -A "$UA" -i -b "$COOKIE_JAR" -e "$PORTAL_URL" -H "Content-Type: application/x-www-form-urlencoded" \
        --data "UserType=1&paramStr=${paramStr}&pwdType=${passType}&aidcauthtype=0&vfcodeflg=false" \
        --data-urlencode "UserName=$user" --data-urlencode "PassWord=$password" \
        "${base}/page_auth.jsp"); local curl_rc=$?

    loc=$(echo "$resp" | grep -i '^Location:' | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')
    local http_status=$(printf '%s' "$resp" | sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | head -1)
    diag "event=login_result curl_rc=$curl_rc http_status=${http_status:-unknown} location_present=$([ -n "$loc" ] && echo 1 || echo 0) cookie_present=$([ -f "$COOKIE_JAR" ] && echo 1 || echo 0)"

    if [ "$curl_rc" -ne 0 ]; then
        clear_auth_state
        return 1
    fi
    local result_url
    result_url=$(portal_url "$loc" "$PORTAL_URL") || result_url=""
    result_url=${result_url%%\?*}
    if [ "$http_status" = 302 ] && [ "$result_url" = "$base/style/school_hbct/$client_type/logon.jsp" ]; then
        login_successes=$((login_successes + 1))
        log "登录成功"
        diag "event=login_success attempts=$login_attempts successes=$login_successes"
        return 0
    elif echo "$loc" | grep -q "login_fail.jsp"; then
        clear_auth_state
        log "登录失败"
        diag "event=login_failure attempts=$login_attempts successes=$login_successes"
        return 1
    else
        log "登录结果未知（已隐藏重定向内容）"
        clear_auth_state
        diag "event=login_unknown attempts=$login_attempts successes=$login_successes"
        return 1
    fi
}

keepalive() {
    local base http_status curl_rc
    base=$(get_base "$PORTAL_URL"); [ -z "$base" ] && base="$gateway"
    [ "$base" = "$(get_base "$gateway")" ] || return 1
    diag "event=keepalive_start"
    if [ ! -f "$COOKIE_JAR" ]; then
        diag "event=keepalive_result curl_rc=skip http_status=unknown"
        return 1
    fi
    http_status=$(curl -q -s --connect-timeout 3 --max-time 5 -A "$UA" -b "$COOKIE_JAR" -e "$PORTAL_URL" \
        -o /dev/null -w '%{http_code}' "$base/style/school_hbct/$client_type/logon.jsp" 2>/dev/null)
    curl_rc=$?
    case "$http_status" in [0-9][0-9][0-9]) : ;; *) http_status=unknown ;; esac
    diag "event=keepalive_result curl_rc=$curl_rc http_status=$http_status"
    [ "$curl_rc" -eq 0 ] || return 1
    case "$http_status" in 2[0-9][0-9]) return 0 ;; *) return 1 ;; esac
}

# sync_ntp: 尝试使用系统可用的 NTP 工具同步系统时间
sync_ntp() {
    local server="$1"
    local rc=1

    if command -v ntpd >/dev/null; then
        ntpd -q -n -p "$server" >/dev/null 2>&1 &
        local pid=$!
        local count=0
        while [ $count -lt 5 ]; do
            if ! kill -0 $pid 2>/dev/null; then
                wait $pid
                rc=$?
                break
            fi
            sleep 1
            count=$((count + 1))
        done
        if kill -0 $pid 2>/dev/null; then
            kill -9 $pid 2>/dev/null
            wait $pid 2>/dev/null
            rc=1
        fi
        [ $rc -eq 0 ] && return 0
    fi

    if command -v ntpclient >/dev/null; then
        ntpclient -s -h "$server" >/dev/null 2>&1 &
        local pid=$!
        local count=0
        while [ $count -lt 5 ]; do
            if ! kill -0 $pid 2>/dev/null; then
                wait $pid
                rc=$?
                break
            fi
            sleep 1
            count=$((count + 1))
        done
        if kill -0 $pid 2>/dev/null; then
            kill -9 $pid 2>/dev/null
            wait $pid 2>/dev/null
            rc=1
        fi
        [ $rc -eq 0 ] && return 0
    fi

    if command -v sntp >/dev/null; then
        sntp -s "$server" >/dev/null 2>&1 &
        local pid=$!
        local count=0
        while [ $count -lt 5 ]; do
            if ! kill -0 $pid 2>/dev/null; then
                wait $pid
                rc=$?
                break
            fi
            sleep 1
            count=$((count + 1))
        done
        if kill -0 $pid 2>/dev/null; then
            kill -9 $pid 2>/dev/null
            wait $pid 2>/dev/null
            rc=1
        fi
        [ $rc -eq 0 ] && return 0
    fi

    return 1
}

# sync_http: 通过 HTTP(S) 响应头获取 Date 字段并设置系统时间（fallback）
sync_http() {
    local sites="http://www.baidu.com http://www.qq.com https://www.taobao.com https://www.aliyun.com"

    for site in $sites; do
        http_header=$(curl -sI --connect-timeout 3 "$site")
        http_date=$(echo "$http_header" | grep -i "^Date:" | sed 's/^[Dd]ate: *//' | tr -d '\r')

        if [ -n "$http_date" ]; then
            # 1. 优先使用 BusyBox date -D 转换格式并设置 UTC 时间
            local formatted_date=$(date -u -D "%a, %d %b %Y %H:%M:%S GMT" -d "$http_date" +"%Y-%m-%d %H:%M:%S" 2>/dev/null)
            if [ -n "$formatted_date" ]; then
                date -u -s "$formatted_date" >/dev/null 2>&1 && return 0
            fi
            # 2. 回退到标准 date -s（GNU date 兼容固件）
            date -s "$http_date" >/dev/null 2>&1 && return 0
        fi
    done

    return 1
}

# check_pause_time: 检查是否在休眠时间
check_pause_time() {
    [ "$pause_enabled" != "1" ] && return 1
    if [ -z "$pause_start" ] || [ -z "$pause_end" ]; then
        return 1
    fi

    local current_year=$(date +%Y)
    # 若年份小于 2024 且未经验证，判定为 1970 等未授时状态，避免误判休眠
    [ "$current_year" -lt 2024 ] && [ ! -f /tmp/feiyoung_time_verified ] && return 1

    current_time=$(date +%H%M)
    start_time=$(echo "$pause_start" | tr -d ':')
    end_time=$(echo "$pause_end" | tr -d ':')

    if [ "$start_time" -gt "$end_time" ]; then
        if [ "$current_time" -ge "$start_time" ] || [ "$current_time" -lt "$end_time" ]; then
            return 0
        fi
    else
        if [ "$current_time" -ge "$start_time" ] && [ "$current_time" -lt "$end_time" ]; then
            return 0
        fi
    fi

    return 1
}

# main: 主循环
main() {
    get_config

    rm -f /tmp/feiyoung_time_verified
    local portal_fail_count=0

    while true; do
        # 每个循环重新读取配置，确保配置变更即时生效（修复 procd reload 不触发重启的问题）
        get_config
        diag "event=round_start ping_path=223.5.5.5,119.29.29.29 http_path=223.5.5.5 online_file=$([ -f /tmp/feiyoung_online ] && echo 1 || echo 0)"

        if check_pause_time; then
            diag "event=pause state=active disconnect_wan=$pause_disconnect_wan"
            update_status "休眠中 (计划任务 $pause_start - $pause_end)"
            if [ -f /tmp/feiyoung_online ]; then
                rm -f /tmp/feiyoung_online
                if [ -x "/etc/feiyoung.user" ]; then
                    log "进入休眠断网，正在执行自定义用户脚本 (/etc/feiyoung.user offline)..."
                    diag "event=callback state=pause mode=offline present=1 triggered=1"
                    /etc/feiyoung.user offline >/dev/null 2>&1 &
                else
                    diag "event=callback state=pause mode=offline present=0 triggered=0"
                fi
            fi

            if [ "$pause_disconnect_wan" = "1" ]; then
                if [ ! -f /tmp/feiyoung_wan_paused ]; then
                    log "进入休眠时间，正在断开 WAN 接口..."
                    diag "event=ifdown reason=scheduled_pause"
                    ifdown wan
                    disable_5g
                    disable_lan_ports
                    touch /tmp/feiyoung_wan_paused
                fi
            elif [ -f /tmp/feiyoung_wan_paused ]; then
                log "休眠断网选项已关闭，正在恢复网络接口..."
                enable_5g
                enable_lan_ports
                ifup wan
                rm -f /tmp/feiyoung_wan_paused
            fi

            diag "event=sleep seconds=60 reason=scheduled_pause"
            sleep 60 &
            wait $!
            continue
        else
            if [ -f /tmp/feiyoung_wan_paused ]; then
                diag "event=wake state=active"
                log "休眠结束，正在恢复网络接口..."
                enable_5g
                enable_lan_ports
                ifup wan
                rm -f /tmp/feiyoung_wan_paused
                sleep 10 &
                wait $!
            fi
        fi

        # 网络检测：ICMP Ping + HTTP 状态码双重研判，防止高峰期丢包误判并精准识别机房 302 踢线
        local is_online=0
        ping1_rc=skipped
        ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; ping1_rc=$?
        ping2_rc=skipped
        if [ "$ping1_rc" -eq 0 ]; then
            is_online=1
        else
            ping -c 1 -W 2 119.29.29.29 >/dev/null 2>&1; ping2_rc=$?
            [ "$ping2_rc" -eq 0 ] && is_online=1
        fi
        diag "event=probe_ping path=223.5.5.5 rc=$ping1_rc path2=119.29.29.29 rc2=$ping2_rc"
        if [ "$is_online" != "1" ]; then
            # ICMP 丢包时，采用 HTTP 探测进一步研判真实网络连通性
            local http_code
            http_code=$(curl -s --connect-timeout 2 --max-time 3 -o /dev/null -w "%{http_code}" "http://223.5.5.5" 2>/dev/null); http_rc=$?
            diag "event=probe_http path=223.5.5.5 curl_rc=$http_rc http_status=${http_code:-unknown}"
            if [ "$http_code" = "200" ] || [ "$http_code" = "204" ] || [ "$http_code" = "404" ]; then
                is_online=1
            elif [ "$http_code" = "302" ] || [ "$http_code" = "301" ]; then
                # 机房网关拦截重定向，确认已被踢下线
                is_online=0
            else
                # HTTP 也无响应，等待 1 秒复测一次 Ping
                sleep 1
                ping3_rc=skipped
                ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; ping3_rc=$?
                ping4_rc=skipped
                if [ "$ping3_rc" -ne 0 ]; then
                    ping -c 1 -W 2 119.29.29.29 >/dev/null 2>&1; ping4_rc=$?
                fi
                diag "event=probe_ping_retry path=223.5.5.5 rc=$ping3_rc path2=119.29.29.29 rc2=$ping4_rc"
                if [ "$ping3_rc" -eq 0 ] || [ "$ping4_rc" -eq 0 ]; then
                    is_online=1
                fi
            fi
        fi
        diag "event=online_decision value=$is_online login_attempts=$login_attempts login_successes=$login_successes"

        if [ "$is_online" = "1" ]; then
            portal_fail_count=0
            update_status "运行中 - 网络正常"

            # 每隔 5 分钟访问所选模式的门户 logon 页面。
            local now=$(date +%s)
            if [ $((now - last_keepalive_time)) -ge 300 ]; then
                last_keepalive_time=$now
                keepalive >/dev/null 2>&1 &
            fi

            if [ ! -f /tmp/feiyoung_time_verified ]; then
                sync_success=0
                sys_ntp=$(uci -q get system.ntp.server | awk '{print $1}')
                if [ -n "$sys_ntp" ]; then
                    if sync_ntp "$sys_ntp"; then
                        sync_success=1
                        log "系统 NTP 时间同步成功"
                    fi
                fi
                if [ $sync_success -eq 0 ]; then
                    if sync_ntp "203.107.6.88"; then
                        sync_success=1
                        log "阿里云 IP 时间同步成功"
                    fi
                fi
                if [ $sync_success -eq 0 ]; then
                    if sync_http; then
                        sync_success=1
                        log "HTTP 时间同步成功"
                    fi
                fi
                if [ $sync_success -eq 1 ]; then
                    touch /tmp/feiyoung_time_verified
                fi
            fi

            if [ ! -f /tmp/feiyoung_online ]; then
                touch /tmp/feiyoung_online
                if [ -x "/etc/feiyoung.user" ]; then
                    log "检测到网络已上线，正在执行自定义用户脚本 (/etc/feiyoung.user online)..."
                    diag "event=callback state=online mode=online present=1 triggered=1"
                    /etc/feiyoung.user online >/dev/null 2>&1 &
                else
                    diag "event=callback state=online mode=online present=0 triggered=0"
                fi
            fi
        else
            log "网络断开，开始重连"
            update_status "运行中 - 正在重连..."
            if [ -f /tmp/feiyoung_online ]; then
                rm -f /tmp/feiyoung_online
                if [ -x "/etc/feiyoung.user" ]; then
                    log "检测到网络断开，正在执行自定义用户脚本 (/etc/feiyoung.user offline)..."
                    diag "event=callback state=offline mode=offline present=1 triggered=1"
                    /etc/feiyoung.user offline >/dev/null 2>&1 &
                else
                    diag "event=callback state=offline mode=offline present=0 triggered=0"
                fi
            fi

            # 确保默认路由存在
            ensure_default_route

            # 检查网关二层连通性，若已失效则主动刷新 WAN DHCP 租约
            if ! check_gateway_alive; then
                renew_wan
            fi

            if discover_portal; then
                portal_fail_count=0
                if init_network; then
                    login
                else
                    log "重连失败：无法获取认证参数（连接门户失败）"
                    update_status "运行中 - 连接认证门户失败"
                fi
            else
                portal_fail_count=$((portal_fail_count + 1))
                log "重连失败：未发现认证门户（NAS 未重定向，连续失败 $portal_fail_count 次）"
                update_status "运行中 - 未发现认证门户"
                # 若连续 2 次未能发现门户，说明当前 DHCP 租约可能已被上游废弃，主动重置 WAN 接口以自愈
                if [ "$portal_fail_count" -ge 2 ]; then
                    renew_wan
                    portal_fail_count=0
                    if discover_portal; then
                        if init_network; then
                            login
                        else
                            log "重连失败：无法获取认证参数（连接门户失败）"
                            update_status "运行中 - 连接认证门户失败"
                        fi
                    fi
                fi
            fi
        fi

        # 在线时按 check_interval（默认30秒）轮询；离线/重连时按 5 秒极速重试，实现断网秒级自愈
        local sleep_time="$check_interval"
        [ "$is_online" != "1" ] && sleep_time=5

        diag "event=sleep seconds=$sleep_time reason=$([ "$is_online" = "1" ] && echo online || echo reconnect)"
        sleep "$sleep_time" &
        wait $!
    done
}

main
