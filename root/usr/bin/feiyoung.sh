#!/bin/sh
#
# luci-app-feiyoung: 多账号多拨并发认证与带宽聚合引擎 (v2.2.0)
# 说明：支持多账号/多设备会话（PC + 移动端）并发在线与轻量内存级流量聚合。
# 注意：仅在 UCI 配置启用时运行。
#

UA_PC="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
UA_MOBILE="Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

# 运行时全局变量
enabled="0"
load_balancing="1"
gateway="http://58.53.199.144:8001"
passType="1"
check_interval=30
connect_timeout=5
total_timeout=10
pause_enabled="0"
pause_start=""
pause_end=""
pause_disconnect_wan="0"

NUM_ACCTS=0
LAST_MWAN_STATE=""
last_renew_time=0
was_online_overall=0

log() {
    logger -t feiyoung "$1"
}

# escape_sq: 对单引号进行标准 POSIX 转义以防 eval 注入与解析中断
escape_sq() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

# mask_user: 掩码手机号以保护隐私 (如 18900001111 -> 189****1111)
mask_user() {
    local u="$1"
    if [ ${#u} -ge 7 ]; then
        local prefix=$(echo "$u" | cut -c 1-3)
        local suffix=$(echo "$u" | cut -c $((${#u} - 3))-${#u})
        echo "${prefix}****${suffix}"
    else
        echo "$u"
    fi
}

# get_base: 从完整 URL 提取 scheme://host:port
get_base() {
    echo "$1" | sed -n 's#^\(https\?://[^/?]*\).*#\1#p'
}

# get_wan_device: 获取 WAN 物理网络设备（自适应 DSA 与非 DSA）
get_wan_device() {
    local dev=$(ifstatus wan 2>/dev/null | sed -n 's/.*"l3_device": *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$dev" ] && dev=$(ifstatus wan 2>/dev/null | sed -n 's/.*"device": *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$dev" ] && dev="wan"
    echo "$dev"
}

# get_lan_device: 获取 LAN 桥接或物理网络设备（自适应标准与自定义网桥）
get_lan_device() {
    local dev=$(uci -q get network.lan.device)
    [ -z "$dev" ] && dev=$(uci -q get network.lan.ifname)
    [ -z "$dev" ] && dev="br-lan"
    echo "$dev"
}

# generate_mac: 以物理 MAC 为基准生成唯一的本地管理 MAC (Locally Administered)
generate_mac() {
    local b="$1"
    local idx="$2"
    local oIFS="$IFS"; IFS=":"; set -- $b; IFS="$oIFS"
    local b2="$2" b3="$3" b4="$4" b5="$5" b6="$6"
    [ -z "$b6" ] && b6="00"
    local dec6=$((0x$b6))
    local new_dec6=$(( (dec6 + idx * 17) % 254 + 1 ))
    local hex6=$(printf "%02x" $new_dec6)
    echo "02:${b2:-11}:${b3:-22}:${b4:-33}:${b5:-44}:${hex6}"
}

# get_dev_ip: 获取指定网卡的 IPv4 地址
get_dev_ip() {
    local dev="$1"
    local ip=""
    if [ -f "/tmp/feiyoung_ip_${dev}" ]; then
        ip=$(cat "/tmp/feiyoung_ip_${dev}" 2>/dev/null)
    fi
    [ -z "$ip" ] && ip=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
    echo "$ip"
}

# get_dev_gw: 获取指定网卡的网关地址
get_dev_gw() {
    local dev="$1"
    local gw=""
    if [ -f "/tmp/feiyoung_gw_${dev}" ]; then
        gw=$(cat "/tmp/feiyoung_gw_${dev}" 2>/dev/null)
    fi
    if [ -z "$gw" ]; then
        gw=$(ip route show dev "$dev" 2>/dev/null | awk '/default via/ {print $3}' | head -1)
    fi
    if [ -z "$gw" ] && [ "$dev" = "$(get_wan_device)" ]; then
        gw=$(ifstatus wan 2>/dev/null | sed -n 's/.*"nexthop": *"\([^"]*\)".*/\1/p' | head -1)
    fi
    [ -z "$gw" ] && gw="100.64.0.1"
    echo "$gw"
}

# ensure_default_route: 确保 main 表存在默认路由
ensure_default_route() {
    [ -n "$(ip route show default 2>/dev/null)" ] && return 0
    local dev=$(get_wan_device)
    local gw=$(get_dev_gw "$dev")
    if ip route add default via "$gw" dev "$dev" >/dev/null 2>&1; then
        log "已补充默认路由 via $gw dev $dev"
    fi
}

# check_gateway_alive: 检查主 WAN 口网关二层连通性
check_gateway_alive() {
    local wan_up=$(ifstatus wan 2>/dev/null | sed -n 's/.*"up": *\([a-z]*\).*/\1/p' | head -1)
    [ "$wan_up" != "true" ] && return 0
    local gw=$(ifstatus wan 2>/dev/null | sed -n 's/.*"nexthop": *"\([^"]*\)".*/\1/p' | head -1)
    [ -z "$gw" ] && return 0

    local dev=$(get_wan_device)
    if ip neigh show dev "$dev" 2>/dev/null | grep -E "^$gw " | grep -q -E "INCOMPLETE|FAILED"; then
        return 1
    fi
    return 0
}

# renew_wan: 重置主 WAN 接口并重新请求 DHCP（带 60s 冷却保护）
renew_wan() {
    local now=$(date +%s)
    if [ $((now - last_renew_time)) -lt 60 ]; then
        log "WAN 口处于 60s 冷却保护中，跳过重置..."
        return 0
    fi
    last_renew_time=$now

    log "检测到上游网关不通或租约失效，正在重置 WAN 口 DHCP..."
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
}

# get_5g_radios: 获取 5G 无线设备名称
get_5g_radios() {
    local dev
    for dev in $(uci -q show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
        [ "$(uci -q get wireless.$dev.disabled)" = "1" ] && continue
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

        [ "$is_5g" = "1" ] && echo "$dev"
    done
}

disable_5g() {
    local dev
    rm -f /tmp/feiyoung_disabled_radios
    for dev in $(get_5g_radios); do
        log "正在临时关闭 5G 无线设备: $dev"
        echo "$dev" >> /tmp/feiyoung_disabled_radios
        wifi down "$dev" >/dev/null 2>&1
    done
}

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

get_lan_interfaces() {
    local port
    local lan_dev=$(get_lan_device)
    if [ -d "/sys/class/net/$lan_dev/brif" ]; then
        for port in $(ls "/sys/class/net/$lan_dev/brif"); do
            if ! echo "$port" | grep -qi -E "wlan|ath|wl|ap|ra|rai|mesh"; then
                echo "$port"
            fi
        done
    else
        local ports=$(uci -q get network.lan.ports)
        [ -z "$ports" ] && ports=$(uci -q get network.lan.ifname)
        for port in $ports; do
            if ! echo "$port" | grep -qi -E "wlan|ath|wl|ap|ra|rai|mesh"; then
                echo "$port"
            fi
        done
    fi
}

disable_lan_ports() {
    local port
    rm -f /tmp/feiyoung_disabled_lan_ports
    for port in $(get_lan_interfaces); do
        log "正在临时关闭有线网口: $port"
        echo "$port" >> /tmp/feiyoung_disabled_lan_ports
        ip link set "$port" down 2>/dev/null || ifconfig "$port" down 2>/dev/null
    done
}

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

# sync_ntp: NTP 同步
sync_ntp() {
    local server="$1"
    local rc=1
    if command -v ntpd >/dev/null; then
        ntpd -q -n -p "$server" >/dev/null 2>&1 &
        local pid=$!
        local count=0
        while [ $count -lt 5 ]; do
            if ! kill -0 $pid 2>/dev/null; then
                wait $pid; rc=$?; break
            fi
            sleep 1; count=$((count + 1))
        done
        if kill -0 $pid 2>/dev/null; then
            kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; rc=1
        fi
        [ $rc -eq 0 ] && return 0
    fi
    return 1
}

# sync_http: HTTP Date 响应头时间同步
sync_http() {
    local sites="http://www.baidu.com http://www.qq.com https://www.taobao.com"
    local site http_header http_date formatted_date
    for site in $sites; do
        http_header=$(curl -sI --connect-timeout 3 "$site")
        http_date=$(echo "$http_header" | grep -i "^Date:" | sed 's/^[Dd]ate: *//' | tr -d '\r')
        if [ -n "$http_date" ]; then
            formatted_date=$(date -u -D "%a, %d %b %Y %H:%M:%S GMT" -d "$http_date" +"%Y-%m-%d %H:%M:%S" 2>/dev/null)
            if [ -n "$formatted_date" ]; then
                date -u -s "$formatted_date" >/dev/null 2>&1 && return 0
            fi
            date -s "$http_date" >/dev/null 2>&1 && return 0
        fi
    done
    return 1
}

# check_pause_time: 检查是否处于休眠时间
check_pause_time() {
    [ "$pause_enabled" != "1" ] && return 1
    [ -z "$pause_start" ] || [ -z "$pause_end" ] && return 1
    [ -f /tmp/feiyoung_time_verified ] || return 1

    local current_time=$(date +%H%M)
    local start_time=$(echo "$pause_start" | tr -d ':')
    local end_time=$(echo "$pause_end" | tr -d ':')

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

# setup_dhcp_script: 创建用于虚拟网卡（vwan*）的专用轻量 DHCP 处理脚本（不污染主默认路由）
setup_dhcp_script() {
    [ -f /tmp/feiyoung_dhcp.sh ] && return 0
    cat << 'EOF' > /tmp/feiyoung_dhcp.sh
#!/bin/sh
[ -z "$1" ] && exit 1
case "$1" in
    bound|renew)
        [ -n "$ip" ] && ip -4 addr replace "$ip/${mask:-16}" broadcast "${broadcast:-+}" dev "$interface" 2>/dev/null
        if [ -n "$router" ] && [ "$router" != "0.0.0.0" ]; then
            vidx=$(echo "$interface" | sed 's/[^0-9]//g')
            [ -z "$vidx" ] && vidx=1
            table_id=$((100 + vidx))
            ip route replace default via "$router" dev "$interface" table "$table_id" 2>/dev/null
            echo "$router" > "/tmp/feiyoung_gw_${interface}"
            echo "$ip" > "/tmp/feiyoung_ip_${interface}"
            ip rule del priority $((100 + vidx)) 2>/dev/null || true
            ip rule del priority $((90 + vidx)) 2>/dev/null || true
            ip rule add priority $((100 + vidx)) from "$ip" lookup "$table_id" 2>/dev/null || true
            ip rule add priority $((90 + vidx)) oif "$interface" lookup "$table_id" 2>/dev/null || true
            ip route flush cache 2>/dev/null || true
        fi
    ;;
    deconfig)
        ip -4 addr flush dev "$interface" 2>/dev/null
    ;;
esac
exit 0
EOF
    chmod +x /tmp/feiyoung_dhcp.sh
}

# get_config: 从 UCI 读取全局配置与账号列表
get_config() {
    enabled=$(uci -q get feiyoung.general.enabled)
    load_balancing=$(uci -q get feiyoung.general.load_balancing)
    [ -z "$load_balancing" ] && load_balancing="1"

    gateway=$(uci -q get feiyoung.general.gateway)
    [ -z "$gateway" ] && gateway="http://58.53.199.144:8001"

    passType=$(uci -q get feiyoung.general.passType)
    [ -z "$passType" ] && passType="1"

    pause_enabled=$(uci -q get feiyoung.general.pause_enabled)
    pause_start=$(uci -q get feiyoung.general.pause_start)
    pause_end=$(uci -q get feiyoung.general.pause_end)
    pause_disconnect_wan=$(uci -q get feiyoung.general.pause_disconnect_wan)

    check_interval=$(uci -q get feiyoung.general.check_interval)
    [ -z "$check_interval" ] && check_interval=30

    connect_timeout=$(uci -q get feiyoung.general.connect_timeout)
    [ -z "$connect_timeout" ] && connect_timeout=5

    total_timeout=$(uci -q get feiyoung.general.total_timeout)
    [ -z "$total_timeout" ] && total_timeout=10

    # 遍历所有 account 节
    NUM_ACCTS=0
    local sections=$(uci -q show feiyoung | grep '=account' | cut -d. -f2 | cut -d= -f1)
    if [ -n "$sections" ]; then
        local sec
        for sec in $sections; do
            local acct_en=$(uci -q get feiyoung."$sec".enabled)
            [ "$acct_en" = "0" ] && continue

            local acct_u=$(uci -q get feiyoung."$sec".username)
            local acct_p=$(uci -q get feiyoung."$sec".password)
            local acct_t=$(uci -q get feiyoung."$sec".client_type)
            local acct_m=$(uci -q get feiyoung."$sec".macaddr)
            [ -z "$acct_u" ] && continue
            [ -z "$acct_t" ] && acct_t="pc"

            NUM_ACCTS=$((NUM_ACCTS + 1))
            eval "ACCT_${NUM_ACCTS}_USER='$(escape_sq "$acct_u")'"
            eval "ACCT_${NUM_ACCTS}_PASS='$(escape_sq "$acct_p")'"
            eval "ACCT_${NUM_ACCTS}_TYPE='$(escape_sq "$acct_t")'"
            eval "ACCT_${NUM_ACCTS}_MAC='$(escape_sq "$acct_m")'"
            eval "ACCT_${NUM_ACCTS}_SEC='$(escape_sq "$sec")'"
        done
    fi

    # 向后兼容：若无 account 节，回退读取旧版 general 配置
    if [ "$NUM_ACCTS" -eq 0 ]; then
        local gen_u=$(uci -q get feiyoung.general.username)
        local gen_p=$(uci -q get feiyoung.general.password)
        [ -z "$gen_p" ] && gen_p=$(uci -q get feiyoung.general.password_seed)
        if [ -n "$gen_u" ]; then
            NUM_ACCTS=1
            ACCT_1_USER="$gen_u"
            ACCT_1_PASS="$gen_p"
            ACCT_1_TYPE="pc"
            ACCT_1_MAC=""
            ACCT_1_SEC="general"
        fi
    fi
}

# setup_interfaces: 为各个会话分配与初始化网络接口
setup_interfaces() {
    setup_dhcp_script
    local wan_dev=$(get_wan_device)
    local base_mac=$(cat /sys/class/net/"$wan_dev"/address 2>/dev/null)
    [ -z "$base_mac" ] && base_mac="02:11:22:33:44:00"

    local i=1
    while [ $i -le $NUM_ACCTS ]; do
        if [ $i -eq 1 ]; then
            eval "ACCT_${i}_DEV=\"\$wan_dev\""
            eval "ACCT_${i}_IFACE=\"wan\""
        else
            local vif="vwan$((i - 1))"
            eval "ACCT_${i}_DEV=\"\$vif\""
            eval "ACCT_${i}_IFACE=\"\$vif\""

            local custom_mac
            eval "custom_mac=\"\$ACCT_${i}_MAC\""
            [ -z "$custom_mac" ] && custom_mac=$(generate_mac "$base_mac" $i)

            if [ ! -d "/sys/class/net/$vif" ]; then
                log "正在为会话 $i 创建虚拟网卡 $vif (MAC: $custom_mac)..."
                ip link add link "$wan_dev" name "$vif" type macvlan mode bridge 2>/dev/null
                ip link set "$vif" address "$custom_mac" 2>/dev/null
                sysctl -w net.ipv6.conf."$vif".disable_ipv6=1 >/dev/null 2>&1 || true
                ip link set "$vif" up 2>/dev/null
            else
                ip link set "$vif" up 2>/dev/null
            fi

            # 检查是否有有效 IPv4 地址
            local cur_ip=$(get_dev_ip "$vif")
            local pidfile="/var/run/udhcpc-$vif.pid"
            if [ -n "$cur_ip" ]; then
                local vidx=$(echo "$vif" | sed 's/[^0-9]//g')
                [ -z "$vidx" ] && vidx=1
                local table_id=$((100 + vidx))
                local cur_gw=$(get_dev_gw "$vif")
                ip route replace default via "$cur_gw" dev "$vif" table "$table_id" 2>/dev/null
                ip rule del priority $((100 + vidx)) 2>/dev/null || true
                ip rule del priority $((90 + vidx)) 2>/dev/null || true
                ip rule add priority $((100 + vidx)) from "$cur_ip" lookup "$table_id" 2>/dev/null || true
                ip rule add priority $((90 + vidx)) oif "$vif" lookup "$table_id" 2>/dev/null || true
            else
                if [ -f "$pidfile" ] && ! kill -0 $(cat "$pidfile") 2>/dev/null; then
                    rm -f "$pidfile"
                fi
                if [ ! -f "$pidfile" ]; then
                    log "正在为 $vif 启动 DHCP 客户端..."
                    udhcpc -i "$vif" -s /tmp/feiyoung_dhcp.sh -p "$pidfile" -t 3 -T 2 -b -R >/dev/null 2>&1 &
                fi
            fi
        fi
        i=$((i + 1))
    done
}

# check_account_online: 检查指定网卡与客户端类型是否处于已认证在线状态
check_account_online() {
    local dev="$1"
    local type="$2"
    local ua="$UA_PC"
    [ "$type" = "mobile" ] && ua="$UA_MOBILE"

    local http_code
    http_code=$(curl -s --interface "$dev" -A "$ua" --connect-timeout 2 --max-time 3 -o /dev/null -w "%{http_code}" "http://223.5.5.5" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ] || [ "$http_code" = "404" ]; then
        return 0
    fi
    # 偶发网络抖动时进行备用探测，避免晚高峰单包丢包误判掉线
    http_code=$(curl -s --interface "$dev" -A "$ua" --connect-timeout 2 --max-time 3 -o /dev/null -w "%{http_code}" "http://119.29.29.29" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ] || [ "$http_code" = "404" ]; then
        return 0
    fi
    return 1
}

# login_account: 针对特定账号执行门户发现与登录认证
login_account() {
    local idx="$1"
    local user pass type dev cookie_jar ua
    eval "user=\${ACCT_${idx}_USER}"
    eval "pass=\${ACCT_${idx}_PASS}"
    eval "type=\${ACCT_${idx}_TYPE}"
    eval "dev=\${ACCT_${idx}_DEV}"
    cookie_jar="/tmp/feiyoung_cookie_${idx}"

    if [ "$type" = "mobile" ]; then
        ua="$UA_MOBILE"
    else
        ua="$UA_PC"
    fi

    # 1. 门户探测
    local portal_url=""
    local site loc
    for site in "http://223.5.5.5" "http://119.29.29.29" "http://114.114.114.114"; do
        loc=$(curl -s --interface "$dev" -A "$ua" --connect-timeout 2 --max-time 3 -D - -o /dev/null "$site" 2>/dev/null \
            | grep -i '^Location:' | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')
        if [ -n "$loc" ] && echo "$loc" | grep -qi "userip="; then
            portal_url="$loc"
            break
        fi
    done

    if [ -z "$portal_url" ]; then
        log "会话 $idx ($dev) 未能探测到认证门户重定向"
        return 1
    fi

    local portal_base=$(get_base "$portal_url")
    if [ -n "$portal_base" ]; then
        gateway="$portal_base"
    else
        portal_base="$gateway"
    fi

    local param_str=""
    rm -f "$cookie_jar"

    if [ "$type" = "mobile" ]; then
        # 移动端专用逻辑 (Bypass WAF 412)：
        # 带移动端 UA 请求门户，从 302 重定向 Location 头中直接提取 paramStr
        local loc_dump="/tmp/feiyoung_mob_hdr_${idx}.txt"
        curl -s --interface "$dev" -A "$ua" --connect-timeout "$connect_timeout" --max-time "$total_timeout" \
            -D "$loc_dump" -c "$cookie_jar" -o /dev/null "$portal_url" 2>/dev/null
        local mob_loc=$(grep -i '^Location:' "$loc_dump" 2>/dev/null | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')
        rm -f "$loc_dump"

        if [ -n "$mob_loc" ]; then
            param_str=$(echo "$mob_loc" | sed -n 's/.*[?&]paramStr=\([^&]*\).*/\1/p')
        fi
    else
        # PC 端标准逻辑：请求门户页面并从 HTML 解析 paramStr
        local fyhtml
        fyhtml=$(curl -s --interface "$dev" -A "$ua" --connect-timeout "$connect_timeout" --max-time "$total_timeout" \
            -c "$cookie_jar" "$portal_url" 2>/dev/null)
        param_str=$(echo "$fyhtml" | sed -n 's/.*paramStr=\([^"]*\)".*/\1/p' | head -1)
    fi

    if [ -z "$param_str" ]; then
        log "会话 $idx ($dev) 解析 paramStr 失败 (type: $type)"
        return 1
    fi

    # 3. 提交登录 POST 请求 (采用 --data-urlencode 安全编码特殊密码字符)
    local resp post_loc
    resp=$(curl -s --interface "$dev" -A "$ua" --connect-timeout "$connect_timeout" --max-time "$total_timeout" \
        -i -b "$cookie_jar" -c "$cookie_jar" \
        --data "UserType=1&paramStr=${param_str}&pwdType=${passType}&aidcauthtype=0&vfcodeflg=false" \
        --data-urlencode "UserName=${user}" \
        --data-urlencode "PassWord=${pass}" \
        "${portal_base}/page_auth.jsp" 2>/dev/null)

    post_loc=$(echo "$resp" | grep -i '^Location:' | head -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')

    if echo "$post_loc" | grep -q "logon.jsp"; then
        log "会话 $idx 登录成功 (用户: $(mask_user "$user"), 类型: $type, 接口: $dev)"
        eval "LAST_KEEPALIVE_${idx}=$(date +%s)"
        return 0
    elif echo "$post_loc" | grep -q "login_fail.jsp"; then
        log "会话 $idx 登录失败 (用户: $(mask_user "$user"), 类型: $type)"
        return 1
    else
        log "会话 $idx 登录响应未知: $post_loc"
        return 1
    fi
}

# keepalive_account: 发送轻量保活请求刷新 BRAS 会话
keepalive_account() {
    local idx="$1"
    local dev type cookie_jar ua
    eval "dev=\"\$ACCT_${idx}_DEV\""
    eval "type=\"\$ACCT_${idx}_TYPE\""
    cookie_jar="/tmp/feiyoung_cookie_${idx}"

    [ ! -f "$cookie_jar" ] && return 0

    if [ "$type" = "mobile" ]; then
        ua="$UA_MOBILE"
        curl --interface "$dev" -s --connect-timeout 3 --max-time 5 -A "$ua" -b "$cookie_jar" \
            "${gateway}/style/school_hbct/mobile/logon.jsp" >/dev/null 2>&1 &
    else
        ua="$UA_PC"
        curl --interface "$dev" -s --connect-timeout 3 --max-time 5 -A "$ua" -b "$cookie_jar" \
            "${gateway}/style/school_hbct/pc/logon.jsp" >/dev/null 2>&1 &
    fi
}

# teardown_mwan_routing: 清理多拨聚合规则与路由
teardown_mwan_routing() {
    nft delete table inet feiyoung_mwan 2>/dev/null || true
    if nft list table inet fw4 >/dev/null 2>&1; then
        local handle
        for handle in $(nft -a list chain inet fw4 forward 2>/dev/null | grep 'comment "feiyoung_mwan"' | awk '{print $NF}'); do
            nft delete rule inet fw4 forward handle "$handle" 2>/dev/null || true
        done
    fi
    local p
    for p in $(seq 90 110); do
        ip rule del priority $p 2>/dev/null || true
    done
    for p in $(seq 1010 1050); do
        ip rule del priority $p 2>/dev/null || true
    done
    for p in $(seq 100 110); do
        ip rule del table $p 2>/dev/null || true
        ip route flush table $p 2>/dev/null || true
    done
    ip route flush cache 2>/dev/null || true
    LAST_MWAN_STATE=""
}

# apply_mwan_routing: 根据当前在线网卡动态应用 RAM-only 黏性连接聚合
apply_mwan_routing() {
    local num_online="$1"
    local online_devs="$2"

    if [ "$num_online" -lt 2 ] || [ "$load_balancing" != "1" ]; then
        if [ -n "$LAST_MWAN_STATE" ]; then
            log "在线会话少于 2 或未开启多拨聚合，切回原生单 WAN 路由..."
            teardown_mwan_routing
        fi
        return 0
    fi

    if ! command -v nft >/dev/null 2>&1; then
        log "系统未检测到 nftables 工具，无法应用多拨负载均衡规则"
        return 1
    fi

    local current_state="${num_online}_${online_devs}"
    [ "$current_state" = "$LAST_MWAN_STATE" ] && return 0

    log "正在配置多拨聚合路由 (在线数: $num_online, 网卡: $online_devs)..."

    # 清理旧的规则
    local p
    for p in $(seq 1010 1050); do
        ip rule del priority $p 2>/dev/null || true
    done

    local lan_dev=$(get_lan_device)
    local k=1
    local map_rules=""
    for dev in $online_devs; do
        local table_id
        local fwmark_hex
        if [ "$dev" = "$(get_wan_device)" ]; then
            table_id=100
            fwmark_hex="0x10"
            local gw=$(get_dev_gw "$dev")
            local ip=$(get_dev_ip "$dev")
            ip route replace default via "$gw" dev "$dev" table 100 2>/dev/null
            ip rule add priority 1010 fwmark 0x10 lookup main 2>/dev/null
            [ -n "$ip" ] && ip rule add priority 1030 from "$ip" lookup 100 2>/dev/null
        else
            local vidx=$(echo "$dev" | sed 's/[^0-9]//g')
            [ -z "$vidx" ] && vidx=1
            table_id=$((100 + vidx))
            fwmark_hex=$(printf "0x%x0" $k)
            local gw=$(get_dev_gw "$dev")
            local ip=$(get_dev_ip "$dev")
            ip route replace default via "$gw" dev "$dev" table "$table_id" 2>/dev/null
            ip rule add priority $((1010 + k)) fwmark "$fwmark_hex" lookup "$table_id" 2>/dev/null
            [ -n "$ip" ] && ip rule add priority $((1030 + k)) from "$ip" lookup "$table_id" 2>/dev/null
        fi

        local map_idx=$((k - 1))
        if [ -n "$map_rules" ]; then
            map_rules="${map_rules}, ${map_idx} : ${fwmark_hex}"
        else
            map_rules="${map_idx} : ${fwmark_hex}"
        fi
        k=$((k + 1))
    done

    # 载入 RAM-only nftables 表：本地/私网直通 + 黏性会话跟踪 + MSS 钳制 + Masquerade
    nft delete table inet feiyoung_mwan 2>/dev/null || true
    nft -f - << EOF
table inet feiyoung_mwan {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        iifname "$lan_dev" udp dport 53 accept
        iifname "$lan_dev" tcp dport 53 accept
        iifname "$lan_dev" fib daddr type { local, broadcast, multicast } accept
        iifname "$lan_dev" ip daddr { 127.0.0.0/8, 192.168.0.0/16 } accept
        iifname "$lan_dev" ct mark != 0x00000000 meta mark set ct mark
        iifname "$lan_dev" ct state new ct mark set numgen inc mod $num_online map { $map_rules }
        iifname "$lan_dev" ct state new meta mark set ct mark
    }
    chain forward {
        type filter hook forward priority filter - 1; policy accept;
        tcp flags syn tcp option maxseg size set 1400
        iifname "$lan_dev" oifname "vwan*" counter accept
        iifname "vwan*" oifname "$lan_dev" ct state { established, related } counter accept
    }
    chain postrouting {
        type nat hook postrouting priority srcnat + 1; policy accept;
        oifname "vwan*" counter masquerade
    }
}
EOF

    # 若系统运行 OpenWrt fw4，向 fw4 forward 链动态注入放行规则防止未知虚拟接口被拦截
    if nft list table inet fw4 >/dev/null 2>&1; then
        if ! nft list chain inet fw4 forward 2>/dev/null | grep -q 'comment "feiyoung_mwan"'; then
            nft insert rule inet fw4 forward iifname "$lan_dev" oifname "vwan*" counter accept comment "feiyoung_mwan" 2>/dev/null || true
        fi
    fi

    ip route flush cache 2>/dev/null || true
    LAST_MWAN_STATE="$current_state"
    log "多拨黏性聚合规则已生效！"
}

# update_overall_status: 将状态汇总写入 /tmp/feiyoung_status
update_overall_status() {
    local summary="$1"
    local status_file="/tmp/feiyoung_status"
    
    {
        echo "$summary"
        local i=1
        while [ $i -le $NUM_ACCTS ]; do
            local u t d ip st
            eval "u=\"\$ACCT_${i}_USER\""
            eval "t=\"\$ACCT_${i}_TYPE\""
            eval "d=\"\$ACCT_${i}_DEV\""
            eval "st=\"\$ACCT_${i}_STATUS\""
            ip=$(get_dev_ip "$d")
            [ -z "$ip" ] && ip="未获取IP"
            [ -z "$st" ] && st="未就绪"
            local u_mask=$(mask_user "$u")
            local t_upper="PC"
            [ "$t" = "mobile" ] && t_upper="Mobile"
            echo "• [$t_upper] $u_mask ($d): $st [$ip]"
            i=$((i + 1))
        done
    } > "$status_file"
}

# cleanup: 脚本退出时的彻底资源回收
cleanup() {
    log "正在清理 FeiYoung 运行资源..."
    teardown_mwan_routing
    
    # 清理虚拟网卡与其后台 udhcpc 进程
    local pidfile
    for pidfile in /var/run/udhcpc-vwan*.pid; do
        if [ -f "$pidfile" ]; then
            kill $(cat "$pidfile") 2>/dev/null || true
            rm -f "$pidfile"
        fi
    done
    
    local d
    for d in /sys/class/net/vwan*; do
        [ -d "$d" ] && ip link delete "${d##*/}" 2>/dev/null || true
    done
    
    rm -f /tmp/feiyoung_online /tmp/feiyoung_cookie_* /tmp/feiyoung_dhcp.sh /tmp/feiyoung_ip_* /tmp/feiyoung_gw_*
    
    if [ "${1:-}" = "stop" ]; then
        echo "未运行" > /tmp/feiyoung_status
    else
        rm -f /tmp/feiyoung_status
    fi

    if [ -f /tmp/feiyoung_wan_paused ]; then
        enable_5g
        enable_lan_ports
        local lan_dev=$(get_lan_device)
        ip link set "$lan_dev" up 2>/dev/null || ifconfig "$lan_dev" up 2>/dev/null
        wifi up >/dev/null 2>&1
        ifup wan >/dev/null 2>&1
        rm -f /tmp/feiyoung_wan_paused
    fi
}

if [ "${1:-}" = "stop" ]; then
    cleanup "stop"
    exit 0
fi

trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# main: 守护调度主循环
main() {
    get_config
    [ "$enabled" = "1" ] || { cleanup "stop"; exit 0; }
    [ "$NUM_ACCTS" -gt 0 ] || { log "未配置任何账号，退出运行"; cleanup "stop"; exit 0; }

    log "FeiYoung 守护服务已启动 (配置会话数: $NUM_ACCTS, 聚合模式: $load_balancing)"
    setup_interfaces

    while true; do
        get_config
        [ "$enabled" = "1" ] || { cleanup "stop"; exit 0; }

        # 1. 计划休眠处理
        if check_pause_time; then
            update_overall_status "休眠中 (计划任务 $pause_start - $pause_end)"
            teardown_mwan_routing

            if [ -f /tmp/feiyoung_online ]; then
                rm -f /tmp/feiyoung_online
                if [ -x "/etc/feiyoung.user" ]; then
                    log "进入休眠断网，执行自定义用户脚本 (/etc/feiyoung.user offline)..."
                    /etc/feiyoung.user offline >/dev/null 2>&1 &
                fi
            fi

            if [ "$pause_disconnect_wan" = "1" ]; then
                if [ ! -f /tmp/feiyoung_wan_paused ]; then
                    log "进入休眠时间，断开网络接口..."
                    ifdown wan
                    disable_5g
                    disable_lan_ports
                    touch /tmp/feiyoung_wan_paused
                fi
            elif [ -f /tmp/feiyoung_wan_paused ]; then
                enable_5g
                enable_lan_ports
                ifup wan
                rm -f /tmp/feiyoung_wan_paused
            fi

            sleep 60 &
            wait $!
            continue
        else
            if [ -f /tmp/feiyoung_wan_paused ]; then
                log "休眠结束，恢复网络接口..."
                enable_5g
                enable_lan_ports
                ifup wan
                rm -f /tmp/feiyoung_wan_paused
                sleep 10 &
                wait $!
            fi
        fi

        setup_interfaces
        ensure_default_route

        # 检查主 WAN 网关
        if ! check_gateway_alive; then
            renew_wan
        fi

        # 2. 会话状态检测与独立重连
        local online_count=0
        local online_dev_list=""
        local any_offline=0
        local now=$(date +%s)

        local i=1
        while [ $i -le $NUM_ACCTS ]; do
            local dev type user
            eval "dev=\${ACCT_${i}_DEV}"
            eval "type=\${ACCT_${i}_TYPE}"
            eval "user=\${ACCT_${i}_USER}"

            local is_online=0
            if check_account_online "$dev" "$type"; then
                is_online=1
            fi

            if [ "$is_online" = "1" ]; then
                eval "ACCT_${i}_STATUS=\"在线\""
                eval "ACCT_${i}_ONLINE=1"
                online_count=$((online_count + 1))
                online_dev_list="${online_dev_list} ${dev}"

                # 会话保活打卡 (每 5 分钟)
                local last_keepalive
                eval "last_keepalive=\"\${LAST_KEEPALIVE_${i}:-0}\""
                if [ $((now - last_keepalive)) -ge 300 ]; then
                    eval "LAST_KEEPALIVE_${i}=$now"
                    keepalive_account "$i"
                fi
            else
                any_offline=1
                eval "ACCT_${i}_STATUS=\"正在重连...\""
                eval "ACCT_${i}_ONLINE=0"
                log "检测到会话 $i ($(mask_user "$user"), $type, $dev) 离线，正在尝试认证..."

                if login_account "$i"; then
                    eval "ACCT_${i}_STATUS=\"在线\""
                    eval "ACCT_${i}_ONLINE=1"
                    online_count=$((online_count + 1))
                    online_dev_list="${online_dev_list} ${dev}"
                else
                    eval "ACCT_${i}_STATUS=\"认证失败 / 离线\""
                    eval "ACCT_${i}_ONLINE=0"
                fi
            fi

            i=$((i + 1))
        done

        # 3. 时间同步保护
        if [ "$online_count" -gt 0 ] && [ ! -f /tmp/feiyoung_time_verified ]; then
            local sync_success=0
            local sys_ntp=$(uci -q get system.ntp.server | awk '{print $1}')
            [ -n "$sys_ntp" ] && sync_ntp "$sys_ntp" && sync_success=1
            [ $sync_success -eq 0 ] && sync_ntp "203.107.6.88" && sync_success=1
            [ $sync_success -eq 0 ] && sync_http && sync_success=1
            [ $sync_success -eq 1 ] && touch /tmp/feiyoung_time_verified
        fi

        # 4. 自定义回调触发
        if [ "$online_count" -gt 0 ]; then
            if [ ! -f /tmp/feiyoung_online ]; then
                touch /tmp/feiyoung_online
                if [ -x "/etc/feiyoung.user" ]; then
                    log "网络已上线，执行自定义用户脚本 (/etc/feiyoung.user online)..."
                    /etc/feiyoung.user online >/dev/null 2>&1 &
                fi
            fi
        else
            if [ -f /tmp/feiyoung_online ]; then
                rm -f /tmp/feiyoung_online
                if [ -x "/etc/feiyoung.user" ]; then
                    log "所有会话均已离线，执行自定义用户脚本 (/etc/feiyoung.user offline)..."
                    /etc/feiyoung.user offline >/dev/null 2>&1 &
                fi
            fi
        fi

        # 5. 动态 MWAN 路由聚合
        online_dev_list=$(echo "$online_dev_list" | xargs)
        apply_mwan_routing "$online_count" "$online_dev_list"

        # 6. 状态汇总写入
        if [ "$online_count" -eq "$NUM_ACCTS" ]; then
            if [ "$online_count" -ge 2 ] && [ "$load_balancing" = "1" ]; then
                update_overall_status "运行中 - 网络正常 ($online_count/$NUM_ACCTS 在线，多拨聚合已生效)"
            else
                update_overall_status "运行中 - 网络正常 (所有会话在线)"
            fi
        elif [ "$online_count" -gt 0 ]; then
            if [ "$online_count" -ge 2 ] && [ "$load_balancing" = "1" ]; then
                update_overall_status "运行中 - 部分会话在线 ($online_count/$NUM_ACCTS 在线，多拨聚合生效中)"
            else
                update_overall_status "运行中 - 单线在线 ($online_count/$NUM_ACCTS 在线)"
            fi
        else
            update_overall_status "运行中 - 正在重连... (0/$NUM_ACCTS 在线)"
        fi

        # 在线时按 check_interval 轮询；有离线时按 5 秒秒级自愈
        local sleep_time="$check_interval"
        [ "$any_offline" -eq 1 ] && sleep_time=5

        sleep "$sleep_time" &
        wait $!
    done
}

main
