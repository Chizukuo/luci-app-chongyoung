#!/bin/sh

# 记录日志
log() {
    logger -t chongyoung "$1"
}

# 读取UCI配置
get_config() {
    enabled=$(uci -q get chongyoung.general.enabled)
    [ "$enabled" = "1" ] || exit 0
    
    user=$(uci -q get chongyoung.general.username)
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
    fyxml=$(curl -s -H "Accept: */*" -H "User-Agent:CDMA+WLAN(Maod)" -H "Accept-Language: zh-Hans-CN;q=1" -H "Accept-Encoding: gzip, deflate" -H "Connection: keep-alive" -H "Content-Type:application/x-www-form-urlencoded" -L "http://100.64.0.1")
    
    if [ -z "$fyxml" ]; then
        log "无法连接到认证服务器"
        return 1
    fi

    fylgurl=$(echo "$fyxml" | awk -v head="CDATA[" -v tail="]" '{print substr($0, index($0,head)+length(head),index($0,tail)-index($0,head)-length(head))}')
    usmac=$(echo "$fyxml" | awk -v head="sermac=" -v tail="&wlanacname" '{print substr($0, index($0,head)+length(head),index($0,tail)-index($0,head)-length(head))}')
    acname=$(echo "$fyxml" | awk -v head="wlanacname=" -v tail="&wlanuserip" '{print substr($0, index($0,head)+length(head),index($0,tail)-index($0,head)-length(head))}')
    usip=$(echo "$fyxml" | awk -v head="wlanuserip=" -v tail="]" '{print substr($0, index($0,head)+length(head),index($0,tail)-index($0,head)-length(head))}')
    AidcAuthAttr1=$(echo "$fyxml" | awk -v head="Attr1>" -v tail="</Aidc" '{print substr($0, index($0,head)+length(head),index($0,tail)-index($0,head)-length(head))}')
    
    return 0
}

# 登录
login() {
    # 计算日期
    if [ -z "$AidcAuthAttr1" ]; then
        log "获取服务器时间失败"
        return 1
    fi
    
    day_num=$(echo "$AidcAuthAttr1" | cut -c 7-8 | sed -r 's/^0*([^0]+|0)$/\1/')
    
    # 从 password_list 中提取对应行的密码
    # sed -n "${day_num}p" 输出第 day_num 行
    password_list=$(uci -q get chongyoung.daily.password_list)
    passwd=$(echo "$password_list" | sed -n "${day_num}p" | tr -d '\r')
    
    if [ -z "$passwd" ]; then
        log "未找到第 ${day_num} 天的密码"
        return 1
    fi

    log "正在尝试登录... 用户: $user, 日期: $day_num"
    
    lgg=$(curl -s -d "&createAuthorFlag=0&UserName=${prefix}${user}&Password=${passwd}&AidcAuthAttr1=${AidcAuthAttr1}&AidcAuthAttr3=${AidcAuthAttr3}&AidcAuthAttr4=${AidcAuthAttr4}&AidcAuthAttr5=${AidcAuthAttr5}&AidcAuthAttr6=${AidcAuthAttr6}&AidcAuthAttr8=${AidcAuthAttr8}&AidcAuthAttr15=${AidcAuthAttr15}&AidcAuthAttr22=${AidcAuthAttr22}&AidcAuthAttr23=${AidcAuthAttr23}" -H "User-Agent: ${system}" -H "Content-Type: application/x-www-form-urlencoded" "${fylgurl}")
    
    result=$(echo "$lgg" | awk -v head="ReplyMessage>" -v tail="</ReplyMessage" '{print substr($0, index($0,head)+length(head),index($0,tail)-index($0,head)-length(head))}')
    log "登录结果: $result"
}

# 心跳
heart() {
    curl -s -d "" -H "User-Agent: CDMA+WLAN(Maod)" -H "Content-Type: application/x-www-form-urlencoded" "http://58.53.199.146:8007/Hv6_dW" > /dev/null
}

# 主循环
main() {
    # 启动时读取一次配置即可
    # OpenWrt 的 procd 会在配置变更时自动重启此进程
    get_config
    
    while true; do
        # 状态检测
        if ping -c 1 -W 2 114.114.114.114 >/dev/null 2>&1; then
            # log "网络正常，发送心跳"
            heart
        else
            log "网络断开，开始重连"
            if init_network; then
                login
            fi
        fi
        
        sleep 30
    done
}

main
