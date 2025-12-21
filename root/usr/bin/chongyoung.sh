#!/bin/sh

CURL_OPTS="-s --connect-timeout 5 --max-time 10"
HEARTBEAT_URL="http://58.53.199.146:8007/Hv6_dW"

# 缓存变量
CACHE_DAY=""
CACHE_PWD=""

# 记录日志
log() {
    logger -t chongyoung "$1"
}

# 更新状态文件
update_status() {
    echo "$1" > /tmp/chongyoung_status
}

# 读取UCI配置
get_config() {
    enabled=$(uci -q get chongyoung.general.enabled)
    [ "$enabled" = "1" ] || exit 0
    
    user=$(uci -q get chongyoung.general.username)
    password_seed=$(uci -q get chongyoung.general.password_seed)
    
    # 计划任务配置
    pause_enabled=$(uci -q get chongyoung.general.pause_enabled)
    pause_start=$(uci -q get chongyoung.general.pause_start)
    pause_end=$(uci -q get chongyoung.general.pause_end)
    pause_disconnect_wan=$(uci -q get chongyoung.general.pause_disconnect_wan)
    
    # 高级超时配置
    check_interval=$(uci -q get chongyoung.general.check_interval)
    [ -z "$check_interval" ] && check_interval=30
    
    connect_timeout=$(uci -q get chongyoung.general.connect_timeout)
    [ -z "$connect_timeout" ] && connect_timeout=5
    
    total_timeout=$(uci -q get chongyoung.general.total_timeout)
    [ -z "$total_timeout" ] && total_timeout=10
    
    # 更新 CURL 配置
    CURL_OPTS="-s --connect-timeout $connect_timeout --max-time $total_timeout"
    
    system=$(uci -q get chongyoung.general.system)
    prefix=$(uci -q get chongyoung.general.prefix)
    
    # 读取固定参数
    AidcAuthAttr3=$(uci -q get chongyoung.general.AidcAuthAttr3)
    AidcAuthAttr4=$(uci -q get chongyoung.general.AidcAuthAttr4)
    AidcAuthAttr5=$(uci -q get chongyoung.general.AidcAuthAttr5)
    AidcAuthAttr6=$(uci -q get chongyoung.general.AidcAuthAttr6)
    AidcAuthAttr8=$(uci -q get chongyoung.general.AidcAuthAttr8)
    AidcAuthAttr15=$(uci -q get chongyoung.general.AidcAuthAttr15)
    AidcAuthAttr22=$(uci -q get chongyoung.general.AidcAuthAttr22)
    AidcAuthAttr23=$(uci -q get chongyoung.general.AidcAuthAttr23)
}

# 初始化网络参数
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

# 登录
login() {
    # 计算日期
    if [ -z "$AidcAuthAttr1" ]; then
        log "获取服务器时间失败"
        return 1
    fi
    
    # 提取日期 (例如 21)
    # 使用 awk 替代 cut/sed 以提高兼容性
    day_num=$(echo "$AidcAuthAttr1" | awk '{print substr($0, 7, 2)}' | awk '{print int($0)}')
    
    passwd=""
    
    # 检查缓存
    if [ "$day_num" = "$CACHE_DAY" ] && [ -n "$CACHE_PWD" ]; then
        passwd="$CACHE_PWD"
        # log "使用缓存密码 (日期: $day_num)"
    else
        # 优先使用种子计算密码
        if [ -n "$password_seed" ]; then
            if [ -x "/usr/share/chongyoung/calc_pwd.lua" ]; then
                # 捕获输出并检查退出状态
                calc_out=$(/usr/share/chongyoung/calc_pwd.lua "$password_seed" "$day_num")
                if [ $? -eq 0 ] && [ -n "$calc_out" ]; then
                    passwd="$calc_out"
                else
                    log "密码计算失败"
                    # 不立即返回，尝试回退到列表模式
                fi
            else
                log "找不到密码计算脚本"
            fi
        fi

        # 如果没有计算出密码（未设置种子或计算失败），尝试从列表读取
        if [ -z "$passwd" ]; then
            # 从 password_list 中提取对应行的密码
            password_list=$(uci -q get chongyoung.daily.password_list)
            
            # 确保 password_list 不为空
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

# 心跳
heart() {
    curl $CURL_OPTS -d "" -H "User-Agent: CDMA+WLAN(Maod)" -H "Content-Type: application/x-www-form-urlencoded" "$HEARTBEAT_URL" > /dev/null
}

# 检查是否在休眠时间
check_pause_time() {
    [ "$pause_enabled" != "1" ] && return 1
    [ -z "$pause_start" ] || [ -z "$pause_end" ] && return 1
    
    # 防止系统时间未同步导致误判 (年份小于 2023 则认为时间未同步)
    current_year=$(date +%Y)
    [ "$current_year" -lt 2023 ] && return 1
    
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

# 主循环
main() {
    # 启动时读取一次配置即可
    # OpenWrt 的 procd 会在配置变更时自动重启此进程
    get_config
    
    while true; do
        # 检查是否处于休眠时段
        if check_pause_time; then
            update_status "休眠中 (计划任务 $pause_start - $pause_end)"
            
            # 如果启用了断开 WAN 选项
            if [ "$pause_disconnect_wan" = "1" ]; then
                if [ ! -f /tmp/chongyoung_wan_paused ]; then
                    log "进入休眠时间，正在断开 WAN 接口..."
                    ifdown wan
                    touch /tmp/chongyoung_wan_paused
                fi
            fi
            
            sleep 60
            continue
        else
            # 非休眠时间，检查是否需要恢复 WAN
            if [ -f /tmp/chongyoung_wan_paused ]; then
                log "休眠结束，正在恢复 WAN 接口..."
                ifup wan
                rm -f /tmp/chongyoung_wan_paused
                # 恢复后给一点时间获取 IP
                sleep 10
            fi
        fi

        # 状态检测 - 尝试 Ping 阿里DNS(223.5.5.5) 或 腾讯DNS(119.29.29.29)
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 119.29.29.29 >/dev/null 2>&1; then
            # log "网络正常，发送心跳"
            update_status "运行中 - 网络正常"
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
