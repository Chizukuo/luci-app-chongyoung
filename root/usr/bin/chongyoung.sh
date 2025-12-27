#!/bin/sh
#
# luci-app-chongyoung: 自动认证与心跳脚本
# 说明：定时检测网络并在需要时进行认证，向心跳服务器发送心跳。
# 注意：仅在 UCI 配置启用时运行。
#
CURL_OPTS="-s --connect-timeout 5 --max-time 10"
HEARTBEAT_URL="http://58.53.199.146:8007/Hv6_dW"

# 全局缓存（用于避免重复计算每天密码）
CACHE_DAY=""
CACHE_PWD=""

# log: 写入系统日志（tag: chongyoung）
# 参数：$1 - 日志内容
log() {
    logger -t chongyoung "$1"
}

# update_status: 将状态写入 /tmp/chongyoung_status
# 参数：$1 - 状态文本
update_status() {
    echo "$1" > /tmp/chongyoung_status
}

# get_config: 从 UCI 读取脚本所需配置；若未启用则退出脚本
# 设置变量：user、password_seed、pause_*（计划任务）、check_interval、connect_timeout、total_timeout、system、prefix、AidcAuthAttr*
get_config() {
    enabled=$(uci -q get chongyoung.general.enabled)
    [ "$enabled" = "1" ] || exit 0
    
    user=$(uci -q get chongyoung.general.username)
    password_seed=$(uci -q get chongyoung.general.password_seed)
    
    # 计划任务相关配置（启用/起止时间/是否断开 WAN）
    pause_enabled=$(uci -q get chongyoung.general.pause_enabled)
    pause_start=$(uci -q get chongyoung.general.pause_start)
    pause_end=$(uci -q get chongyoung.general.pause_end)
    pause_disconnect_wan=$(uci -q get chongyoung.general.pause_disconnect_wan)
    
    # 超时与间隔配置（采用默认值兜底）
    check_interval=$(uci -q get chongyoung.general.check_interval)
    [ -z "$check_interval" ] && check_interval=30
    
    connect_timeout=$(uci -q get chongyoung.general.connect_timeout)
    [ -z "$connect_timeout" ] && connect_timeout=5
    
    total_timeout=$(uci -q get chongyoung.general.total_timeout)
    [ -z "$total_timeout" ] && total_timeout=10
    
    # 更新 curl 参数
    CURL_OPTS="-s --connect-timeout $connect_timeout --max-time $total_timeout"
    
    system=$(uci -q get chongyoung.general.system)
    prefix=$(uci -q get chongyoung.general.prefix)
    
    # 固定认证参数
    AidcAuthAttr3=$(uci -q get chongyoung.general.AidcAuthAttr3)
    AidcAuthAttr4=$(uci -q get chongyoung.general.AidcAuthAttr4)
    AidcAuthAttr5=$(uci -q get chongyoung.general.AidcAuthAttr5)
    AidcAuthAttr6=$(uci -q get chongyoung.general.AidcAuthAttr6)
    AidcAuthAttr8=$(uci -q get chongyoung.general.AidcAuthAttr8)
    AidcAuthAttr15=$(uci -q get chongyoung.general.AidcAuthAttr15)
    AidcAuthAttr22=$(uci -q get chongyoung.general.AidcAuthAttr22)
    AidcAuthAttr23=$(uci -q get chongyoung.general.AidcAuthAttr23)
} 

# init_network: 请求运营商网关以获取认证所需参数（fylgurl、AidcAuthAttr1）
# 返回：0 成功，1 失败
init_network() {
    fyxml=$(curl $CURL_OPTS -H "Accept: */*" -H "User-Agent:CDMA+WLAN(Maod)" -H "Accept-Language: zh-Hans-CN;q=1" -H "Accept-Encoding: gzip, deflate" -H "Connection: keep-alive" -H "Content-Type:application/x-www-form-urlencoded" -L "http://100.64.0.1")
    
    if [ -z "$fyxml" ]; then
        log "无法连接到认证服务器"
        return 1
    fi

    fylgurl=$(echo "$fyxml" | awk -v head="CDATA[" -v tail="]" 'index($0, head) {print substr($0, index($0,head)+length(head),index($0,tail)-index($0,head)-length(head))}' | head -n 1)
    AidcAuthAttr1=$(echo "$fyxml" | awk -v head="Attr1>" -v tail="</Aidc" 'index($0, head) {print substr($0, index($0,head)+length(head),index($0,tail)-index($0,head)-length(head))}' | head -n 1)
    
    if [ -z "$fylgurl" ] || [ -z "$AidcAuthAttr1" ]; then
        log "解析认证参数失败"
        return 1
    fi

    return 0
} 

# login: 根据 AidcAuthAttr1 计算当日密码并提交登录请求；记录登录结果
# 前置：AidcAuthAttr1 已由 init_network 设置
login() {
    # 提取服务器时间中的日期（示例：21）
    # 使用 awk 提取并转换为整数以兼容 BusyBox
    if [ -z "$AidcAuthAttr1" ]; then
        log "获取服务器时间失败"
        return 1
    fi

    day_num=$(echo "$AidcAuthAttr1" | awk '{print substr($0, 7, 2)}' | awk '{print int($0)}')
    
    passwd=""
    
    # 优先使用缓存避免重复计算
    if [ "$day_num" = "$CACHE_DAY" ] && [ -n "$CACHE_PWD" ]; then
        passwd="$CACHE_PWD"
        # log "使用缓存密码 (日期: $day_num)"
    else
        # 若设置了密码种子，尝试调用外部计算脚本
        if [ -n "$password_seed" ]; then
            if [ -x "/usr/share/chongyoung/calc_pwd.lua" ]; then
                # 调用脚本并检查退出码与输出
                calc_out=$(/usr/share/chongyoung/calc_pwd.lua "$password_seed" "$day_num")
                if [ $? -eq 0 ] && [ -n "$calc_out" ]; then
                    passwd="$calc_out"
                else
                    log "密码计算失败"
                    # 失败时回退到列表模式
                fi
            else
                log "找不到密码计算脚本"
            fi
        fi

# 回退：从 UCI 的 password_list 中获取对应行的密码
            if [ -z "$passwd" ]; then
                password_list=$(uci -q get chongyoung.daily.password_list)
                
                # password_list 为空视为配置错误
            if [ -z "$password_list" ]; then
                log "密码列表为空且未设置密码种子，请检查配置"
                return 1
            fi

            passwd=$(echo "$password_list" | sed -n "${day_num}p" | tr -d '\r')
        fi
        
        # 更新缓存
        if [ -n "$passwd" ]; then
            CACHE_DAY="$day_num"
            CACHE_PWD="$passwd"
        fi
    fi
    
    if [ -z "$passwd" ]; then
        log "未找到第 ${day_num} 天的密码"
        return 1
    fi

    log "正在尝试登录... 用户: $user, 日期: $day_num"
    
    lgg=$(curl $CURL_OPTS -d "&createAuthorFlag=0&UserName=${prefix}${user}&Password=${passwd}&AidcAuthAttr1=${AidcAuthAttr1}&AidcAuthAttr3=${AidcAuthAttr3}&AidcAuthAttr4=${AidcAuthAttr4}&AidcAuthAttr5=${AidcAuthAttr5}&AidcAuthAttr6=${AidcAuthAttr6}&AidcAuthAttr8=${AidcAuthAttr8}&AidcAuthAttr15=${AidcAuthAttr15}&AidcAuthAttr22=${AidcAuthAttr22}&AidcAuthAttr23=${AidcAuthAttr23}" -H "User-Agent: ${system}" -H "Content-Type: application/x-www-form-urlencoded" "${fylgurl}")
    
    result=$(echo "$lgg" | awk -v head="ReplyMessage>" -v tail="</ReplyMessage" '{print substr($0, index($0,head)+length(head),index($0,tail)-index($0,head)-length(head))}')
    log "登录结果: $result"
}

# heart: 向心跳服务器发送空 POST，保持会话
# 无返回值
heart() {
    curl $CURL_OPTS -d "" -H "User-Agent: CDMA+WLAN(Maod)" -H "Content-Type: application/x-www-form-urlencoded" "$HEARTBEAT_URL" > /dev/null
} 

# sync_ntp: 尝试使用系统可用的 NTP 工具同步系统时间（ntpd/ntpclient/sntp）
# 参数：$1 - NTP 服务器（域名或 IP）
# 返回：0 成功，1 失败
sync_ntp() {
    local server="$1"
    local rc=1
    
    # 1. 尝试 ntpd (BusyBox / 标准 ntpd)
    if command -v ntpd >/dev/null; then
        # BusyBox ntpd 参数示例：-q -n -p
        ntpd -q -n -p "$server" >/dev/null 2>&1
        rc=$?
        if [ $rc -eq 0 ]; then
            return 0
        else
            log "ntpd sync failed with code $rc"
        fi
    fi
    
    # 2. 尝试 ntpclient
    if command -v ntpclient >/dev/null; then
        ntpclient -s -h "$server" >/dev/null 2>&1
        rc=$?
        if [ $rc -eq 0 ]; then
            return 0
        else
            log "ntpclient sync failed with code $rc"
        fi
    fi

    # 3. 尝试 sntp
    if command -v sntp >/dev/null; then
        sntp -s "$server" >/dev/null 2>&1
        rc=$?
        if [ $rc -eq 0 ]; then
            return 0
        else
            log "sntp sync failed with code $rc"
        fi
    fi
    
    return 1
} 

# sync_http: 通过 HTTP(S) 响应头获取 Date 字段并设置系统时间（fallback）
# 返回：0 成功，1 失败
sync_http() {
    # 备选站点（HTTP/HTTPS）用于获取 Date 头
    local sites="http://www.baidu.com http://www.qq.com https://www.taobao.com https://www.aliyun.com"
    
    for site in $sites; do
        log "尝试使用 HTTP(S) 对时: $site"
        # 获取响应头并解析 Date
        http_header=$(curl -sI --connect-timeout 3 "$site")
        http_date=$(echo "$http_header" | grep -i "^Date:" | sed 's/Date: //i' | tr -d '\r')
        
        if [ -n "$http_date" ]; then
            log "获取到时间: $http_date"
            date -s "$http_date" >/dev/null 2>&1
            rc=$?
            if [ $rc -eq 0 ]; then
                return 0
            else
                log "设置时间失败 (RC=$rc)"
            fi
        else
            log "无法获取 Date 头"
        fi
    done
    
    return 1
} 

# 检查是否在休眠时间
check_pause_time() {
    [ "$pause_enabled" != "1" ] && return 1
    [ -z "$pause_start" ] || [ -z "$pause_end" ] && return 1
    
    # 防止系统时间未同步导致误判 (年份小于 2019 则认为时间未同步)
    current_year=$(date +%Y)
    [ "$current_year" -lt 2019 ] && return 1
    
    # 必须先成功联网一次（确保NTP有机会同步）才允许进入休眠
    [ -f /tmp/chongyoung_time_verified ] || return 1
    
    current_time=$(date +%H%M)
    # 去除冒号，例如 23:30 -> 2330
    start_time=$(echo "$pause_start" | tr -d ':')
    end_time=$(echo "$pause_end" | tr -d ':')
    
    # 跨天处理 (例如 2330 到 0630)
    if [ "$start_time" -gt "$end_time" ]; then
        if [ "$current_time" -ge "$start_time" ] || [ "$current_time" -lt "$end_time" ]; then
            return 0
        fi
    else
        # 当天处理 (例如 0900 到 1700)
        if [ "$current_time" -ge "$start_time" ] && [ "$current_time" -lt "$end_time" ]; then
            return 0
        fi
    fi
    
    return 1
}

# main: 主循环，读取配置后按配置周期检测网络状态、对时、登录并发送心跳
# 行为：在休眠时断开/恢复 WAN；网络断开时尝试认证
main() {
    # 启动时读取一次配置；OpenWrt 的 procd 会在配置变更时重启此进程
    get_config
    
    # 清理上次运行可能残留的时间验证标志
    rm -f /tmp/chongyoung_time_verified
    
    while true; do
        # 判断是否处于休眠时段
        if check_pause_time; then
            update_status "休眠中 (计划任务 $pause_start - $pause_end)"
            
            # 若配置要求，断开 WAN 并短暂关闭 LAN/Wi-Fi 信号
            if [ "$pause_disconnect_wan" = "1" ]; then
                if [ ! -f /tmp/chongyoung_wan_paused ]; then
                    log "进入休眠时间，正在断开 WAN 接口..."

                    ifdown wan
                    
                    log "正在执行全网闪断策略 (有线+无线)..."
                    
                    ifconfig br-lan down

                    wifi down
        
                    sleep 10
                    
                    ifconfig br-lan up

                    wifi up
                    
                    log "局域网及 Wi-Fi 信号已恢复"
    
                    touch /tmp/chongyoung_wan_paused
                fi
            fi
            
            sleep 60
            continue
        else
            # 非休眠时间，若之前暂停过则恢复 WAN
            if [ -f /tmp/chongyoung_wan_paused ]; then
                log "休眠结束，正在恢复 WAN 接口..."
                ifup wan
                rm -f /tmp/chongyoung_wan_paused
                # 恢复后给一点时间获取 IP
                sleep 10
            fi
        fi

        # 网络检测：ping 常用 DNS 作为连通性判定
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 119.29.29.29 >/dev/null 2>&1; then
            update_status "运行中 - 网络正常"
            
            # 首次检测到网络恢复时，尝试同步时间并标记为已验证
            if [ ! -f /tmp/chongyoung_time_verified ]; then
                sync_success=0
                
                # 1. 优先尝试系统配置的 NTP 服务器
                sys_ntp=$(uci -q get system.ntp.server | awk '{print $1}')
                if [ -n "$sys_ntp" ]; then
                    log "尝试系统 NTP 同步 (Server: $sys_ntp)..."
                    if sync_ntp "$sys_ntp"; then
                        sync_success=1
                        log "系统 NTP 时间同步成功"
                    else
                        log "系统 NTP 同步失败"
                    fi
                fi

                # 2. 兜底：使用阿里云 IP 避免 DNS 解析问题
                if [ $sync_success -eq 0 ]; then
                    ali_ntp_ip="203.107.6.88"
                    log "尝试阿里云 IP 兜底同步 (Server: $ali_ntp_ip)..."
                    if sync_ntp "$ali_ntp_ip"; then
                        sync_success=1
                        log "阿里云 IP 时间同步成功"
                    else
                        log "阿里云 IP 同步失败"
                    fi
                fi

                # 3. 最后手段：HTTP 协议对时
                if [ $sync_success -eq 0 ]; then
                    log "尝试 HTTP 协议对时..."
                    if sync_http; then
                        sync_success=1
                        log "HTTP 时间同步成功"
                    fi
                fi

                if [ $sync_success -eq 1 ]; then
                    touch /tmp/chongyoung_time_verified
                else
                    log "所有时间同步手段均失败，保留未验证状态"
                fi
            fi

            # 发送心跳
            heart
        else
            log "网络断开，开始重连"
            update_status "运行中 - 正在重连..."
            if init_network; then
                login
            else
                update_status "运行中 - 连接认证服务器失败"
            fi
        fi
        
        sleep "$check_interval"
    done
}

main
