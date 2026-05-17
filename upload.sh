#!/bin/bash
# ==============================================================================
# 基于 iperf3 的上行流量消耗脚本（可指定对端服务端口）
# ==============================================================================
# 功能：以 iperf3 客户端模式运行，持续向指定 iperf3 服务端发送数据（上行流量），
#       监控 TX 方向流量，达到设定阈值后自动停止。
# 用法：./upload.sh [阈值_MB] [限速_Mbps] [端口]
#       阈值_MB   - 目标上行流量总量（单位：MB），默认见配置区
#       限速_Mbps - 限制 iperf3 发送带宽（单位：Mbps），0 表示不限速，默认见配置区
#       端口      - 服务端监听端口，默认见配置区
# 示例：./upload.sh 1024 50 5201       # 1GB 上行，限速 50Mbps，端口 5201
#       ./upload.sh 500 0 8080         # 500MB 上行，不限速，端口 8080
#       ./upload.sh                    # 全部使用默认配置
# ==============================================================================

# ===================== 配置区 =====================
SERVER_IP="127.0.0.1"                  # iperf3 服务端 IP或域名（必填）
SERVER_PORT=5201                       # 服务端监听端口（默认 5201）
DEFAULT_THRESHOLD=200                  # 默认阈值（单位：MB）
DEFAULT_RATE_LIMIT_MBPS=0              # 默认不限速（单位：Mbps，0 表示不限速）
NETWORK_INTERFACE="eth0"               # 监控网卡（自己改：eth0、ens3、ens160、eth1 等）
# ===================== 配置结束 =====================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# -------------------- 参数解析 --------------------
# 第一个参数：阈值（MB）
if [ $# -ge 1 ]; then
    [[ "$1" =~ ^[0-9]+$ ]] && THRESHOLD_MB="$1" || {
        echo -e "${RED}错误：阈值必须是纯数字（单位MB）${NC}"
        exit 1
    }
else
    THRESHOLD_MB=$DEFAULT_THRESHOLD
fi

# 第二个参数：限速（Mbps）
if [ $# -ge 2 ]; then
    if [[ "$2" =~ ^[0-9]+$ ]]; then
        RATE_LIMIT_MBPS="$2"
    else
        echo -e "${RED}错误：限速必须是纯数字（单位Mbps）${NC}"
        exit 1
    fi
else
    RATE_LIMIT_MBPS=$DEFAULT_RATE_LIMIT_MBPS
fi

# 第三个参数：端口
if [ $# -ge 3 ]; then
    if [[ "$3" =~ ^[0-9]+$ ]] && [ "$3" -ge 1 ] && [ "$3" -le 65535 ]; then
        SERVER_PORT="$3"
    else
        echo -e "${RED}错误：端口必须是 1-65535 之间的整数${NC}"
        exit 1
    fi
fi

# 单位转换（字节）
THRESHOLD_BYTES=$((THRESHOLD_MB * 1024 * 1024))

# 构造 iperf3 限速参数（仅当限速 >0 时使用）
if (( RATE_LIMIT_MBPS > 0 )); then
    LIMIT_PARAM="-b ${RATE_LIMIT_MBPS}M"
else
    LIMIT_PARAM=""
fi

# -------------------- 通用函数 --------------------
# 适配 Alpine 网络参数优化（核心修复）
optimize_alpine_network() {
    if [ -f /etc/alpine-release ]; then
        sysctl -w net.ipv4.tcp_congestion_control=bic >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null 2>&1
        sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1
        sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_no_metrics_save=1 >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_syn_retries=2 >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_fin_timeout=10 >/dev/null 2>&1
        ulimit -n 65535 >/dev/null 2>&1
        echo -e "${GREEN}✅ Alpine网络参数优化完成${NC}"
    fi
}

# 依赖检查
check_deps() {
    local deps="iperf3 bc stat"
    for cmd in $deps; do
        if ! command -v $cmd &> /dev/null; then
            if [ -f /etc/debian_version ]; then
                apt update -y >/dev/null 2>&1
                apt install -y $cmd >/dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                yum install -y $cmd >/dev/null 2>&1
            elif [ -f /etc/alpine-release ]; then
                apk update >/dev/null 2>&1
                apk add --no-cache $cmd >/dev/null 2>&1
            fi
        fi
    done
}

# 读取网卡发送流量（字节）
get_tx() {
    cat /sys/class/net/"$NETWORK_INTERFACE"/statistics/tx_bytes 2>/dev/null || echo 0
}

# 自适应格式化字节大小
format_bytes_adaptive() {
    local bytes=$1
    if (( bytes < 1024 )); then
        echo "$bytes B"
    elif (( bytes < 1024 * 1024 )); then
        echo "$(echo "scale=1; $bytes / 1024" | bc)KiB"
    elif (( bytes < 1024 * 1024 * 1024 )); then
        echo "$(echo "scale=1; $bytes / 1024 / 1024" | bc)MiB"
    else
        echo "$(echo "scale=1; $bytes / 1024 / 1024 / 1024" | bc)GiB"
    fi
}

# 自适应格式化速度
format_speed_adaptive() {
    local bps=$1
    if (( bps < 1024 )); then
        echo "$bps B/s"
    elif (( bps < 1024 * 1024 )); then
        echo "$(echo "scale=1; $bps / 1024" | bc)KiB/s"
    elif (( bps < 1024 * 1024 * 1024 )); then
        echo "$(echo "scale=1; $bps / 1024 / 1024" | bc)MiB/s"
    else
        echo "$(echo "scale=1; $bps / 1024 / 1024 / 1024" | bc)GiB/s"
    fi
}

# 生成随机6位十六进制任务 ID
generate_random_task_id() {
    printf "#%06x" $((RANDOM % 16777216))
}

# 退出清理
cleanup() {
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null
    echo -e "\n${YELLOW}清理完成${NC}"
}

# ===================== 主程序 =====================
# 屏蔽所有后台进程的输出
exec 3>&1 4>&2
exec 1>/dev/null 2>&1

check_deps
optimize_alpine_network

exec 1>&3 4>&2
trap cleanup EXIT

# 初始化
START_TX=$(get_tx)
THRESHOLD_FMT=$(format_bytes_adaptive $THRESHOLD_BYTES)
TASK_ID=$(generate_random_task_id)

# 打印启动信息
echo -e "${YELLOW}=====================================${NC}"
echo -e "${GREEN}目标流量：${THRESHOLD_MB} MB (${THRESHOLD_FMT})${NC}"
echo -e "${GREEN}服务端地址：${SERVER_IP}:${SERVER_PORT}${NC}"
echo -e "${GREEN}监控网卡：${NETWORK_INTERFACE}${NC}"
if (( RATE_LIMIT_MBPS > 0 )); then
    echo -e "${GREEN}上行限速：${RATE_LIMIT_MBPS} Mbps${NC}"
else
    echo -e "${GREEN}上行限速：不限速${NC}"
fi
echo -e "${YELLOW}=====================================${NC}\n"

# 启动 iperf3 客户端（持续发送上行流量）
iperf3 -c "$SERVER_IP" -p "$SERVER_PORT" -t 0 $LIMIT_PARAM > /dev/null 2>&1 &
iperf_pid=$!

# 主循环
last_tx=$START_TX
last_time=$(date +%s)

while true; do
    # 检查 iperf3 是否存活
    if [ ! -d /proc/$iperf_pid ]; then
        echo -e "\n${RED}iperf3 进程异常退出，尝试重启...${NC}"
        iperf3 -c "$SERVER_IP" -p "$SERVER_PORT" -t 0 $LIMIT_PARAM > /dev/null 2>&1 &
        iperf_pid=$!
    fi

    # 计算流量/速度/ETA
    NOW_TX=$(get_tx)
    USED_BYTES=$((NOW_TX - START_TX))
    USED_FMT=$(format_bytes_adaptive $USED_BYTES)
    PROGRESS=$(echo "scale=0; if ($USED_BYTES == 0) 0 else $USED_BYTES * 100 / $THRESHOLD_BYTES" | bc)

    now_time=$(date +%s)
    if (( now_time - last_time >= 2 )); then
        tx_diff=$((NOW_TX - last_tx))
        speed_bps=$((tx_diff / (now_time - last_time)))
        speed=$(format_speed_adaptive $speed_bps)
        eta_seconds=$(echo "scale=0; if ($speed_bps == 0) 0 else ($THRESHOLD_BYTES - $USED_BYTES) / $speed_bps" | bc)
        eta_minutes=$((eta_seconds / 60))
        eta_seconds_remain=$((eta_seconds % 60))
        eta="${eta_minutes}m${eta_seconds_remain}s"
        last_tx=$NOW_TX
        last_time=$now_time
    fi

    # 输出进度
    echo -ne "[${RED}${TASK_ID}${NC} ${GREEN}${USED_FMT}/${THRESHOLD_FMT}(${PROGRESS}%)${NC} ${CYAN}IP:${SERVER_IP}:${SERVER_PORT}${NC} ${GREEN}UP:${speed}${NC} ${YELLOW}ETA:${eta}${NC}]\r"

    # 流量阈值检查
    if [ $USED_BYTES -ge $THRESHOLD_BYTES ]; then
        kill $iperf_pid 2>/dev/null
        wait $iperf_pid 2>/dev/null
        echo -e "\n${GREEN}✅ 已达到阈值：${USED_FMT} / ${THRESHOLD_FMT}，停止脚本${NC}"
        exit 0
    fi

    sleep 1
done
