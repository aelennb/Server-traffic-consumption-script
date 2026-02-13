#!/bin/bash

# 流量消耗脚本

# ===================== 配置区 =====================
# 大文件下载地址
FILE_URL="自己填大文件地址"
# 网卡（自己改：eth0、ens3、ens160、eth1等）
NETWORK_INTERFACE="eth0"
# aria2 线程数（默认16线程）
ARIA2_THREADS=16
# 默认阈值（单位：MB）
DEFAULT_THRESHOLD=200
# ===================== 配置结束 =====================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===================== 处理阈值 =====================
if [ $# -ge 1 ]; then
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        THRESHOLD_MB="$1"
    else
        echo -e "${RED}阈值必须是纯数字（单位MB）${NC}"
        exit 1
    fi
else
    THRESHOLD_MB=$DEFAULT_THRESHOLD
fi

# 依赖检查
check_deps() {
    if ! command -v aria2c &> /dev/null || ! command -v bc &> /dev/null; then
        echo -e "${YELLOW}安装依赖...${NC}"
        if [ -f /etc/debian_version ]; then
            apt update > /dev/null 2>&1
            apt install -y aria2 bc > /dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum install -y aria2 bc > /dev/null 2>&1
        fi
    fi
}

# 读取网卡入站流量（字节）
get_rx() {
    cat /sys/class/net/"$NETWORK_INTERFACE"/statistics/rx_bytes
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

# 生成随机6位十六进制任务ID
generate_random_task_id() {
    printf "#%06x" $((RANDOM % 16777216))
}

check_deps

START_RX=$(get_rx)
THRESHOLD_BYTES=$((THRESHOLD_MB * 1024 * 1024))
THRESHOLD_FMT=$(format_bytes_adaptive $THRESHOLD_BYTES)

echo -e "${YELLOW}=====================================${NC}"
echo -e "${GREEN}目标流量：${THRESHOLD_MB} MB (${THRESHOLD_FMT})${NC}"
echo -e "${GREEN}下载地址：${FILE_URL}${NC}"
echo -e "${GREEN}监控网卡：${NETWORK_INTERFACE}${NC}"
echo -e "${GREEN}aria2 线程：${ARIA2_THREADS}${NC}"
echo -e "${YELLOW}=====================================${NC}"
echo

task=1
last_rx=$START_RX
last_time=$(date +%s)

while true; do
    # 每次下载任务生成新的随机任务ID
    TASK_ID=$(generate_random_task_id)

    NOW_RX=$(get_rx)
    USED_BYTES=$((NOW_RX - START_RX))
    USED_FMT=$(format_bytes_adaptive $USED_BYTES)
    PROGRESS=$(echo "scale=0; $USED_BYTES * 100 / $THRESHOLD_BYTES" | bc)

    # 到达阈值立即停止
    if [ $USED_BYTES -ge $THRESHOLD_BYTES ]; then
        echo -e "\n${GREEN}✅ 已达到阈值：${USED_FMT} / ${THRESHOLD_FMT}，停止脚本${NC}"
        exit 0
    fi

    # 启动aria2下载
    aria2c -x "$ARIA2_THREADS" -s "$ARIA2_THREADS" \
        --file-allocation=none --summary-interval=1 \
        -o "tmp_$task" "$FILE_URL" > /tmp/aria2.log 2>&1 &
    aria_pid=$!

    # 实时监控并输出样式
    while kill -0 $aria_pid 2>/dev/null; do
        NOW_RX=$(get_rx)
        USED_BYTES=$((NOW_RX - START_RX))
        USED_FMT=$(format_bytes_adaptive $USED_BYTES)
        PROGRESS=$(echo "scale=0; $USED_BYTES * 100 / $THRESHOLD_BYTES" | bc)

        # 计算速度和ETA
        now_time=$(date +%s)
        time_diff=$((now_time - last_time))
        if [ $time_diff -ge 1 ]; then
            rx_diff=$((NOW_RX - last_rx))
            speed_bps=$((rx_diff / time_diff))
            speed=$(format_speed_adaptive $speed_bps)
            eta_seconds=$(((THRESHOLD_BYTES - USED_BYTES) / (speed_bps + 1)))
            eta_minutes=$((eta_seconds / 60))
            eta_seconds_remain=$((eta_seconds % 60))
            eta="${eta_minutes}m${eta_seconds_remain}s"

            last_rx=$NOW_RX
            last_time=$now_time
        fi

        # 输出样式：[#xxxxxx 9.5GiB/10GiB(95%) CN:16 DL:17MiB ETA:16m11s]
        echo -ne "[${RED}${TASK_ID}${NC} ${GREEN}${USED_FMT}/${THRESHOLD_FMT}(${PROGRESS}%)${NC} ${CYAN}CN:${ARIA2_THREADS}${NC} ${GREEN}DL:${speed}${NC} ${YELLOW}ETA:${eta}${NC}]\r"

        # 再次检查阈值
        if [ $USED_BYTES -ge $THRESHOLD_BYTES ]; then
            kill $aria_pid 2>/dev/null
            wait $aria_pid 2>/dev/null
            echo -e "\n${GREEN}✅ 已达到阈值：${USED_FMT} / ${THRESHOLD_FMT}，停止脚本${NC}"
            exit 0
        fi

        sleep 0.5
    done

    rm -f "tmp_$task"
    task=$((task + 1))
    echo
done
