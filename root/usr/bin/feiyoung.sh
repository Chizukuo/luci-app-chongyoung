#!/bin/sh
#
# luci-app-feiyoung: 自动认证脚本 (v2 - 湖北电信 school_hbct 门户)
# 说明：定时检测网络，未认证时通过重定向发现门户并自动登录。
# 注意：仅在 UCI 配置启用时运行。
#
CURL_OPTS="-s --connect-timeout 5 --max-time 10"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
COOKIE_JAR="/tmp/feiyoung_cookie"

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
        if [ "$band" = "5g" ]; then
            is_5g=1
        elif [ "$band" = "2g" ]; then
            is_5g=0
        elif echo "$hwmode" | grep -q -E "a|ac|ax"; then
            is_5g=1
        elif [ -n "$channel" ] && [ "$channel" != "auto" ] && [ "$channel" -gt 14 ] 2>/dev/null; then
            is_5g=1
        fi

        if [ "$is_5g" = "1" ]; then
            echo "$dev"
        fi
    done
}

# disable_5g: 临时禁用 5G 无线广播
disable_5g() {
    local dev
    local changed=0
    rm -f /tmp/feiyoung_disabled_radios
    for dev in $(get_5g_radios); do
        if [ "$(uci -q get wireless.$dev.disabled)" != "1" ]; then
            log "正在临时关闭 5G 无线设备: $dev"
            echo "$dev" >> /tmp/feiyoung_disabled_radios
            uci set wireless.$dev.disabled='1'
            changed=1
        fi
    done
    if [ "$changed" = "1" ]; then
        uci commit wireless
        wifi reload >/dev/null 2>&1 || wifi >/dev/null 2>&1
    fi
}

# enable_5g: 恢复被临时禁用的 5G 无线广播
enable_5g() {
    local dev
    local changed=0
    if [ -f /tmp/feiyoung_disabled_radios ]; then
        for dev in $(cat /tmp/feiyoung_disabled_radios); do
            log "正在恢复 5G 无线设备: $dev"
            uci delete wireless.$dev.disabled
            changed=1
        done
        rm -f /tmp/feiyoung_disabled_radios
    fi
    if [ "$changed" = "1" ]; then
        uci commit wireless
        wifi reload >/dev/null 2>&1 || wifi >/dev/null 2>&1
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
        ifconfig "$port" down >/dev/null 2>&1
    done
}

# enable_lan_ports: 恢复有线 LAN 网口
enable_lan_ports() {
    local port
    if [ -f /tmp/feiyoung_disabled_lan_ports ]; then
        for port in $(cat /tmp/feiyoung_disabled_lan_ports); do
            log "正在恢复有线网口: $port"
            ifconfig "$port" up >/dev/null 2>&1
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
        ifconfig br-lan up >/dev/null 2>&1
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
    echo "$1" | sed -n 's#^\(http://[^/?]*\).*#\1#p'
}

# ensure_default_route: 确保存在默认路由（校园网 DHCP 偶发不下发网关到内核）
ensure_default_route() {
    ip route show default >/dev/null 2>&1 && return 0
    local gw=$(ifstatus wan 2>/dev/null | sed -n 's/.*"nexthop": *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$gw" ] && gw="100.64.0.1"
    if ip route add default via "$gw" dev wan >/dev/null 2>&1; then
        log "已补充默认路由 via $gw"
    fi
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
}

# discover_portal: 通过访问普通 HTTP 站点触发重定向，获取完整门户地址（含参数）
# 返回：0 成功（PORTAL_URL 已设置），1 失败
discover_portal() {
    local site loc host ip
    # 1. 纯 IP 触发 NAS 重定向（未认证时 DNS 不可用，纯 IP 最可靠）
    for site in "http://223.5.5.5" "http://119.29.29.29" "http://114.114.114.114"; do
        loc=$(curl $CURL_OPTS -A "$UA" -D - -o /dev/null "$site" 2>/dev/null \
            | grep -i '^Location:' | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')
        # 只接受门户地址（带 userip= 参数），避免误接受目标站点自身的重定向
        if [ -n "$loc" ] && echo "$loc" | grep -q "userip="; then
            PORTAL_URL="$loc"
            return 0
        fi
    done
    # 2. 标准门户探测 URL（Windows/Android NCSI），用 DHCP 纯 DNS 解析域名（绕过未认证时不可用的 DoH）
    for site in "www.msftconnecttest.com/redirect" "connectivitycheck.gstatic.com/generate_204"; do
        host="${site%%/*}"
        ip=$(nslookup "$host" 202.103.44.150 2>/dev/null | awk '/^Address:/ {print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        [ -z "$ip" ] && continue
        loc=$(curl $CURL_OPTS -A "$UA" -H "Host: $host" -D - -o /dev/null "http://${ip}/${site#*/}" 2>/dev/null \
            | grep -i '^Location:' | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')
        if [ -n "$loc" ] && echo "$loc" | grep -q "userip="; then
            PORTAL_URL="$loc"
            return 0
        fi
    done
    return 1
}

# init_network: 请求门户获取 paramStr（cookie 存于 COOKIE_JAR）
# 返回：0 成功，1 失败
init_network() {
    rm -f "$COOKIE_JAR"
    local url="$PORTAL_URL"
    [ -z "$url" ] && url="$gateway"

    fyhtml=$(curl $CURL_OPTS -A "$UA" -c "$COOKIE_JAR" "$url")

    if [ -z "$fyhtml" ]; then
        log "无法连接到认证门户 ($url)"
        return 1
    fi

    paramStr=$(echo "$fyhtml" | sed -n 's/.*paramStr=\([^"]*\)".*/\1/p' | head -1)

    if [ -z "$paramStr" ]; then
        log "解析 paramStr 失败"
        return 1
    fi

    return 0
}

# login: 提交登录请求并判断结果
# 返回：0 成功，1 失败
login() {
    local base resp loc
    base=$(get_base "$PORTAL_URL")
    [ -z "$base" ] && base="$gateway"

    log "正在尝试登录... 用户: $user"

    resp=$(curl $CURL_OPTS -A "$UA" -i -b "$COOKIE_JAR" -H "Content-Type: application/x-www-form-urlencoded" \
        --data "UserType=1&paramStr=${paramStr}&pwdType=${passType}&aidcauthtype=0&vfcodeflg=false&UserName=${user}&PassWord=${password}" \
        "${base}/page_auth.jsp")

    loc=$(echo "$resp" | grep -i '^Location:' | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')

    if echo "$loc" | grep -q "logon.jsp"; then
        log "登录成功 (用户: $user)"
        return 0
    elif echo "$loc" | grep -q "login_fail.jsp"; then
        log "登录失败 (用户: $user)"
        return 1
    else
        log "登录结果未知: $loc"
        return 1
    fi
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
        http_date=$(echo "$http_header" | grep -i "^Date:" | sed 's/Date: //i' | tr -d '\r')

        if [ -n "$http_date" ]; then
            date -s "$http_date" >/dev/null 2>&1
            [ $? -eq 0 ] && return 0
        fi
    done

    return 1
}

# check_pause_time: 检查是否在休眠时间
check_pause_time() {
    [ "$pause_enabled" != "1" ] && return 1
    [ -z "$pause_start" ] || [ -z "$pause_end" ] && return 1

    current_year=$(date +%Y)
    [ "$current_year" -lt 2019 ] && return 1
    [ -f /tmp/feiyoung_time_verified ] || return 1

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

    while true; do
        # 每个循环重新读取配置，确保配置变更即时生效（修复 procd reload 不触发重启的问题）
        get_config

        if check_pause_time; then
            update_status "休眠中 (计划任务 $pause_start - $pause_end)"
            if [ -f /tmp/feiyoung_online ]; then
                rm -f /tmp/feiyoung_online
                if [ -x "/etc/feiyoung.user" ]; then
                    log "进入休眠断网，正在执行自定义用户脚本 (/etc/feiyoung.user offline)..."
                    /etc/feiyoung.user offline >/dev/null 2>&1 &
                fi
            fi

            if [ "$pause_disconnect_wan" = "1" ]; then
                if [ ! -f /tmp/feiyoung_wan_paused ]; then
                    log "进入休眠时间，正在断开 WAN 接口..."
                    ifdown wan
                    disable_5g
                    disable_lan_ports
                    touch /tmp/feiyoung_wan_paused
                fi
            fi

            sleep 60
            continue
        else
            if [ -f /tmp/feiyoung_wan_paused ]; then
                log "休眠结束，正在恢复网络接口..."
                enable_5g
                enable_lan_ports
                ifup wan
                rm -f /tmp/feiyoung_wan_paused
                sleep 10
            fi
        fi

        # 网络检测
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 119.29.29.29 >/dev/null 2>&1; then
            update_status "运行中 - 网络正常"

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
                    /etc/feiyoung.user online >/dev/null 2>&1 &
                fi
            fi
        else
            log "网络断开，开始重连"
            update_status "运行中 - 正在重连..."
            if [ -f /tmp/feiyoung_online ]; then
                rm -f /tmp/feiyoung_online
                if [ -x "/etc/feiyoung.user" ]; then
                    log "检测到网络断开，正在执行自定义用户脚本 (/etc/feiyoung.user offline)..."
                    /etc/feiyoung.user offline >/dev/null 2>&1 &
                fi
            fi

            # 确保默认路由存在，然后发现门户并登录
            ensure_default_route
            if discover_portal; then
                if init_network; then
                    login
                else
                    log "重连失败：无法获取认证参数（连接门户失败）"
                    update_status "运行中 - 连接认证门户失败"
                fi
            else
                log "重连失败：未发现认证门户（NAS 未重定向）"
                update_status "运行中 - 未发现认证门户"
            fi
        fi

        sleep "$check_interval"
    done
}

main
