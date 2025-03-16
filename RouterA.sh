#!/bin/sh

# ============================= 配置说明 =============================
# 功能：通过SSH持续监控并重拨路由器的PPPoE接口
# 参数：
#   $1 = 路由器SSH地址（格式：user@hostname，默认 root@192.168.1.1）
#   $2 = 路由器密码（默认 1919810）
#   $3 = 接口名（默认 wan）
#   $4 = 检测间隔时间（单位：秒，默认 60）
#   $5 = SSH端口（默认 22）
# 示例：
#   ./redial.sh "root@192.168.1.1" "1919810" wan 60 22
# ===================================================================

# -------------------------- 初始化配置 --------------------------
ROUTER_SSH="${1:-root@192.168.1.1}"
ROUTER_PASSWORD="${2:-1919810}"
LINE="${3:-wan}"
INTERVAL="${4:-60}"
SSH_PORT="${5:-22}"
IP_FAIL_THRESHOLD=3  # IP连续失败阈值
last_public_ip_log=0  # 上次公网IP日志时间戳
last_public_ip=""     # 上次记录的公网IP

# -------------------------- 日志模块 --------------------------
log() {
    local message=$1
    echo "$(date '+[%Y-%m-%d_%H:%M]') $message" | tee -a /var/log/redial.log
    logger -t "pppoe-monitor" "$message"
}

# -------------------------- 重拨模块 --------------------------
reconnect_pppoe() {
    log "开始重拨接口: $LINE"
    if ! sshpass -p "$ROUTER_PASSWORD" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "$ROUTER_SSH" \
    "ifdown $LINE && sleep 10 && ifup $LINE"; then
        log "‼️ 重拨失败！请检查路由器配置"
        return 1
    else
        log "✅ 重拨成功"
        return 0
    fi
}

# -------------------------- IP检测模块 --------------------------
is_private_ip() {
    local ip=$1
    local first_octet=$(echo "$ip" | cut -d. -f1)
    local second_octet=$(echo "$ip" | cut -d. -f2)

    [ "$first_octet" -eq 10 ] && return 0
    [ "$first_octet" -eq 172 ] && [ "$second_octet" -ge 16 ] && [ "$second_octet" -le 31 ] && return 0
    [ "$first_octet" -eq 192 ] && [ "$second_octet" -eq 168 ] && return 0
    [ "$first_octet" -eq 100 ] && [ "$second_octet" -ge 64 ] && [ "$second_octet" -le 127 ] && return 0
    return 1
}

get_remote_ip() {
    sshpass -p "$ROUTER_PASSWORD" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no "$ROUTER_SSH" \
    "ip addr show pppoe-$LINE 2>/dev/null | awk '/inet / {print \$2}' | cut -d/ -f1"
}

# -------------------------- 主流程 --------------------------
ip_fail_count=0         # IP连续失败计数器
skip_cycles=0           # 跳过周期计数器

log "启动监控：路由器 $ROUTER_SSH 接口 pppoe-$LINE 检测间隔 ${INTERVAL}秒"

while true; do
    if [ $skip_cycles -gt 0 ]; then
        log "[跳过周期] 剩余次数: $skip_cycles"
        skip_cycles=$((skip_cycles - 1))
        sleep "$INTERVAL"
        continue
    fi

    IP=$(get_remote_ip)
    ssh_exit_code=$?

    # 处理密码错误立即退出
    if [ $ssh_exit_code -eq 5 ]; then
        log "‼️ SSH密码错误，脚本终止！"
        exit 1
    fi

    # IP状态判断
    if [ -z "$IP" ]; then
        ip_fail_count=$((ip_fail_count + 1))
        log "未获取到IP地址（连续失败次数: $ip_fail_count/3）"
        
        if [ $ip_fail_count -ge $IP_FAIL_THRESHOLD ]; then
            log "‼️ 连续3次未获取到IP，触发重拨"
            if ! reconnect_pppoe; then
                log "重拨失败，跳过后续操作"
                skip_cycles=2
            fi
            ip_fail_count=0  # 重置计数器
        fi
    elif is_private_ip "$IP"; then
        log "检测到私有IP: $IP（接口: pppoe-$LINE）"
        if ! reconnect_pppoe; then
            log "‼️ 重拨失败，跳过后续操作"
            skip_cycles=2
        fi
        ip_fail_count=0  # 重置计数器
    else
        current_time=$(date +%s)
        time_diff=$((current_time - last_public_ip_log))

        # 核心逻辑：IP变化或超时均记录
        if [ "$IP" != "$last_public_ip" ] || [ $time_diff -ge 3600 ]; then
            log "✅ 当前为公网IP: $IP（接口: pppoe-$LINE）"
            last_public_ip_log=$current_time
            last_public_ip="$IP"  # 更新记录的IP
        fi
        ip_fail_count=0
    fi

    sleep "$INTERVAL"
done
