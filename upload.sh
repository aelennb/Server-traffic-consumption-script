#!/bin/bash
# ==============================================================================
# 基于 iperf3 的上行流量消耗脚本（多端口自动递增，-P 并行流数）
# ==============================================================================
# 用法：./upload.sh [-P 并行流数] [阈值_MB] [限速_Mbps] [端口]
#   -P 并行流数      自动从 <端口> 开始占用连续端口（每个流一个端口）
#   阈值_MB          目标上行总流量（MB）
#   限速_Mbps        总上行速率限制（Mbps，0=不限速，将均分给每个流）
#   端口             起始端口（默认5201）
# 示例：
#   ./upload.sh -P 4 1024 100 5201   # 占用5201~5204，总流量1GB，总限速100Mbps
#   ./upload.sh 500 0 8080           # 单流，端口8080
#   ./upload.sh -P 8                 # 8流，端口5201~5208，其他默认
# ==============================================================================

# ===================== 配置区 =====================
SERVER_IP="127.0.0.1"                  # iperf3 服务端 IP 或域名（必填）
SERVER_PORT=5201                       # 起始端口
DEFAULT_THRESHOLD=200                  # 默认总流量（MB）
DEFAULT_RATE_LIMIT_MBPS=0              # 默认总限速（Mbps，0=不限速）
NETWORK_INTERFACE="eth0"               # 监控网卡
DEFAULT_PARALLEL=1                     # 默认并行流数
# ===================== 配置结束 =====================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# -------------------- 参数解析 --------------------
PARALLEL=$DEFAULT_PARALLEL
while getopts "P:" opt; do
    case "$opt" in
        P)
            if [[ "$OPTARG" =~ ^[0-9]+$ ]] && [ "$OPTARG" -ge 1 ]; then
                PARALLEL="$OPTARG"
            else
                echo -e "${RED}错误：-P 参数必须是大于0的整数${NC}"
                exit 1
            fi
            ;;
        \?) exit 1 ;;
    esac
done
shift $((OPTIND-1))

# 位置参数：阈值(MB) 限速(Mbps) 端口
if [ $# -ge 1 ]; then
    [[ "$1" =~ ^[0-9]+$ ]] && THRESHOLD_MB="$1" || { echo -e "${RED}错误：阈值必须为数字${NC}"; exit 1; }
else
    THRESHOLD_MB=$DEFAULT_THRESHOLD
fi

if [ $# -ge 2 ]; then
    [[ "$2" =~ ^[0-9]+$ ]] && RATE_LIMIT_MBPS="$2" || { echo -e "${RED}错误：限速必须为数字${NC}"; exit 1; }
else
    RATE_LIMIT_MBPS=$DEFAULT_RATE_LIMIT_MBPS
fi

if [ $# -ge 3 ]; then
    if [[ "$3" =~ ^[0-9]+$ ]] && [ "$3" -ge 1 ] && [ "$3" -le 65535 ]; then
        SERVER_PORT="$3"
    else
        echo -e "${RED}错误：端口范围 1-65535${NC}"; exit 1
    fi
fi

# 端口范围检查
END_PORT=$((SERVER_PORT + PARALLEL - 1))
if [ $END_PORT -gt 65535 ]; then
    echo -e "${RED}错误：起始端口 $SERVER_PORT + 并行数 $PARALLEL 超过最大端口65535${NC}"
    exit 1
fi

# 计算每个流的限速（总限速均分，至少1Mbps）
if [ $RATE_LIMIT_MBPS -gt 0 ]; then
    PER_STREAM_LIMIT=$((RATE_LIMIT_MBPS / PARALLEL))
    if [ $PER_STREAM_LIMIT -lt 1 ]; then
        PER_STREAM_LIMIT=1
        echo -e "${YELLOW}⚠️  总限速${RATE_LIMIT_MBPS}Mbps无法均分给${PARALLEL}流，已自动调整为每个流至少1Mbps${NC}"
    fi
fi

THRESHOLD_BYTES=$((THRESHOLD_MB * 1024 * 1024))

# -------------------- 通用函数 --------------------
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
    fi
}

check_deps() {
    for cmd in iperf3 bc stat; do
        if ! command -v $cmd &> /dev/null; then
            if [ -f /etc/debian_version ]; then
                apt update -y >/dev/null 2>&1 && apt install -y $cmd >/dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                yum install -y $cmd >/dev/null 2>&1
            elif [ -f /etc/alpine-release ]; then
                apk update >/dev/null 2>&1 && apk add --no-cache $cmd >/dev/null 2>&1
            fi
        fi
    done
}

get_tx() {
    cat /sys/class/net/"$NETWORK_INTERFACE"/statistics/tx_bytes 2>/dev/null || echo 0
}

format_bytes_adaptive() {
    local bytes=$1
    if (( bytes < 1024 )); then echo "$bytes B"
    elif (( bytes < 1048576 )); then echo "$(echo "scale=1; $bytes/1024" | bc)KiB"
    elif (( bytes < 1073741824 )); then echo "$(echo "scale=1; $bytes/1048576" | bc)MiB"
    else echo "$(echo "scale=1; $bytes/1073741824" | bc)GiB"
    fi
}

format_speed_adaptive() {
    local bps=$1
    if (( bps < 1024 )); then echo "$bps B/s"
    elif (( bps < 1048576 )); then echo "$(echo "scale=1; $bps/1024" | bc)KiB/s"
    elif (( bps < 1073741824 )); then echo "$(echo "scale=1; $bps/1048576" | bc)MiB/s"
    else echo "$(echo "scale=1; $bps/1073741824" | bc)GiB/s"
    fi
}

generate_random_task_id() {
    printf "#%06x" $((RANDOM % 16777216))
}

cleanup() {
    for pid in "${pids[@]}"; do
        kill $pid 2>/dev/null
    done
    wait 2>/dev/null
    echo -e "\n${YELLOW}清理完成${NC}"
}

# ===================== 主程序 =====================
# 安装阶段隐藏输出，启动后恢复
exec 3>&1 4>&2
exec 1>/dev/null 2>&1
check_deps
optimize_alpine_network
exec 1>&3 4>&2

trap cleanup EXIT

START_TX=$(get_tx)
THRESHOLD_FMT=$(format_bytes_adaptive $THRESHOLD_BYTES)
TASK_ID=$(generate_random_task_id)

echo -e "${YELLOW}=====================================${NC}"
echo -e "${GREEN}目标流量：${THRESHOLD_MB} MB (${THRESHOLD_FMT})${NC}"
echo -e "${GREEN}服务端地址：${SERVER_IP}${NC}"
echo -e "${GREEN}端口范围：${SERVER_PORT} ~ ${END_PORT}（${PARALLEL} 个端口）${NC}"
echo -e "${GREEN}监控网卡：${NETWORK_INTERFACE}${NC}"
if [ $RATE_LIMIT_MBPS -gt 0 ]; then
    echo -e "${GREEN}总限速：${RATE_LIMIT_MBPS} Mbps（每流 ${PER_STREAM_LIMIT} Mbps）${NC}"
else
    echo -e "${GREEN}总限速：不限速${NC}"
fi
echo -e "${YELLOW}=====================================${NC}\n"

# 启动所有并行流（每个流独立端口）
declare -a pids
for ((i=0; i<PARALLEL; i++)); do
    port=$((SERVER_PORT + i))
    if [ $RATE_LIMIT_MBPS -gt 0 ]; then
        iperf3 -c "$SERVER_IP" -p $port -t 0 -b ${PER_STREAM_LIMIT}M > /dev/null 2>&1 &
    else
        iperf3 -c "$SERVER_IP" -p $port -t 0 > /dev/null 2>&1 &
    fi
    pids+=($!)
done

# 监控循环
last_tx=$START_TX
last_time=$(date +%s)

while true; do
    # 检查并重启退出的子进程
    for i in "${!pids[@]}"; do
        if [ ! -d /proc/${pids[$i]} ]; then
            port=$((SERVER_PORT + i))
            echo -e "\n${RED}端口 ${port} 的流已断开，正在重连...${NC}"
            if [ $RATE_LIMIT_MBPS -gt 0 ]; then
                iperf3 -c "$SERVER_IP" -p $port -t 0 -b ${PER_STREAM_LIMIT}M > /dev/null 2>&1 &
            else
                iperf3 -c "$SERVER_IP" -p $port -t 0 > /dev/null 2>&1 &
            fi
            pids[$i]=$!
        fi
    done

    NOW_TX=$(get_tx)
    USED_BYTES=$((NOW_TX - START_TX))
    USED_FMT=$(format_bytes_adaptive $USED_BYTES)
    PROGRESS=$(awk "BEGIN {printf \"%.0f\", $USED_BYTES*100/$THRESHOLD_BYTES}")

    now_time=$(date +%s)
    if (( now_time - last_time >= 2 )); then
        tx_diff=$((NOW_TX - last_tx))
        speed_bps=$((tx_diff / (now_time - last_time)))
        speed=$(format_speed_adaptive $speed_bps)
        eta_seconds=$(awk "BEGIN {printf \"%.0f\", ($THRESHOLD_BYTES - $USED_BYTES) / ($speed_bps + 1)}")
        eta_minutes=$((eta_seconds / 60))
        eta_seconds_remain=$((eta_seconds % 60))
        eta="${eta_minutes}m${eta_seconds_remain}s"
        last_tx=$NOW_TX
        last_time=$now_time
    fi

    echo -ne "[${RED}${TASK_ID}${NC} ${GREEN}${USED_FMT}/${THRESHOLD_FMT}(${PROGRESS}%)${NC} ${CYAN}${SERVER_IP}:${SERVER_PORT}-${END_PORT}${NC} ${GREEN}UP:${speed}${NC} ${YELLOW}ETA:${eta}${NC}]\r"

    if [ $USED_BYTES -ge $THRESHOLD_BYTES ]; then
        cleanup
        echo -e "\n${GREEN}✅ 已达到阈值：${USED_FMT} / ${THRESHOLD_FMT}，停止所有流${NC}"
        exit 0
    fi

    sleep 1
done
