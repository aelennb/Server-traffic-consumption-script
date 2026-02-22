#!/bin/bash

# 流量消耗脚本
# ===================== 配置区 =====================
FILE_URL="自己填大文件地址"
NETWORK_INTERFACE="eth0"  # 网卡（自己改：eth0、ens3、ens160、eth1等）
ARIA2_THREADS=16  # Aria2线程数，最大16
DEFAULT_THRESHOLD=200  # 默认阈值（单位：MB）
DELETE_FILE_SIZE_MB=1024   # 1G清理阈值（单位：MB）
LOG_CLEAN_INTERVAL=43200   # 12小时（单位：秒）
# ===================== 配置结束 =====================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 处理流量阈值参数
if [ $# -ge 1 ]; then
    [[ "$1" =~ ^[0-9]+$ ]] && THRESHOLD_MB="$1" || { echo -e "${RED}错误：阈值必须是纯数字（单位MB）${NC}"; exit 1; }
else
    THRESHOLD_MB=$DEFAULT_THRESHOLD
fi

# 单位转换（字节）
DELETE_SIZE=$((DELETE_FILE_SIZE_MB * 1024 * 1024))
THRESHOLD_BYTES=$((THRESHOLD_MB * 1024 * 1024))

# 依赖检查（完全静默，无任何输出）
check_deps() {
    local deps="aria2c bc stat truncate"
    for cmd in $deps; do
        if ! command -v $cmd &> /dev/null; then
            # 适配Debian/Ubuntu
            if [ -f /etc/debian_version ]; then
                apt update -y >/dev/null 2>&1
                apt install -y $cmd >/dev/null 2>&1
            # 适配CentOS/RHEL
            elif [ -f /etc/redhat-release ]; then
                yum install -y $cmd >/dev/null 2>&1
            # 适配Alpine
            elif [ -f /etc/alpine-release ]; then
                apk update >/dev/null 2>&1
                apk add --no-cache $cmd >/dev/null 2>&1
            fi
        fi
    done
}

# 读取网卡入站流量（字节）
get_rx() {
    cat /sys/class/net/"$NETWORK_INTERFACE"/statistics/rx_bytes 2>/dev/null || echo 0
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

# 定时清理aria2日志（完全静默，仅清理时输出一次）
clean_aria2_log_periodically() {
    local last_clean_time=$(date +%s)
    while true; do
        local current_time=$(date +%s)
        if (( current_time - last_clean_time >= LOG_CLEAN_INTERVAL )); then
            [ -f "/tmp/aria2.log" ] && > /tmp/aria2.log
            echo -e "\n${YELLOW}📜 已定时清理aria2日志（12小时）${NC}"
            last_clean_time=$current_time
        fi
        sleep 60
    done
}

# 清理aria2临时文件（新增：清理.aria2后缀文件和废弃的tmp文件）
clean_aria2_temp_files() {
    local file_path=$1
    # 清理aria2的临时文件（.aria2后缀）
    [ -f "${file_path}.aria2" ] && rm -f "${file_path}.aria2" >/dev/null 2>&1
    # 清理历史废弃的tmp文件（tmp_数字 格式）
    for old_file in tmp_*; do
        # 排除当前正在使用的文件
        if [ "$old_file" != "$file_path" ] && [[ "$old_file" =~ ^tmp_[0-9]+$ ]]; then
            rm -f "$old_file" "${old_file}.aria2" >/dev/null 2>&1
        fi
    done
}

# 核心：静默监控文件大小（无任何进程检查输出）
monitor_and_clean_file() {
    local file_path=$1
    local delete_size=$2
    local aria_pid=$3
    local cleaned_flag="/tmp/cleaned_$(basename $file_path).flag"
    
    rm -f $cleaned_flag
    # 先清理一次历史临时文件
    clean_aria2_temp_files "$file_path"
    # 彻底屏蔽进程检查的输出
    while [ -d /proc/$aria_pid ] && [ ! -f $cleaned_flag ]; do
        if [ -f "$file_path" ]; then
            # 兼容获取文件大小，完全屏蔽错误输出
            local file_size=$(stat -c %s "$file_path" 2>/dev/null || stat -f %z "$file_path" 2>/dev/null || echo 0)
            [[ ! "$file_size" =~ ^[0-9]+$ ]] && file_size=0

            if (( file_size >= delete_size )); then
                > "$file_path" && truncate -s 0 "$file_path"
                # 清理对应的.aria2临时文件
                [ -f "${file_path}.aria2" ] && rm -f "${file_path}.aria2" >/dev/null 2>&1
                echo -e "\n${GREEN}✅ 触发清理：[$file_path]已达$(format_bytes_adaptive $delete_size)，已清空（下载继续）${NC}"
                touch $cleaned_flag
                # 持续清空，屏蔽所有输出
                while [ -d /proc/$aria_pid ]; do
                    [ -f "$file_path" ] && truncate -s 0 "$file_path" 2>/dev/null
                    [ -f "${file_path}.aria2" ] && rm -f "${file_path}.aria2" >/dev/null 2>&1
                    sleep 1
                done
            fi
        fi
        sleep 0.1
    done
    rm -f $cleaned_flag
}

# 退出清理（增强：全量清理临时文件）
cleanup() {
    # 清理所有tmp_*文件、.aria2后缀文件、标记文件、日志
    rm -f tmp_* *.aria2 /tmp/cleaned_*.flag /tmp/aria2.log 2>/dev/null
    # 彻底屏蔽kill/pkill的输出
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null
    echo -e "\n${YELLOW}📦 清理临时文件完成（含aria2临时文件）${NC}"
}

# ===================== 主程序 =====================
# 屏蔽所有后台进程的输出
exec 3>&1 4>&2
exec 1>/dev/null 2>&1
check_deps
exec 1>&3 4>&2

trap cleanup EXIT

# 启动日志清理线程（屏蔽输出）
clean_aria2_log_periodically >/dev/null 2>&1 &

# 初始化
START_RX=$(get_rx)
THRESHOLD_FMT=$(format_bytes_adaptive $THRESHOLD_BYTES)
TASK_ID=$(generate_random_task_id)

# 打印启动信息（仅一次）
echo -e "${YELLOW}=====================================${NC}"
echo -e "${GREEN}目标流量：${THRESHOLD_MB} MB (${THRESHOLD_FMT})${NC}"
echo -e "${GREEN}下载地址：${FILE_URL}${NC}"
echo -e "${GREEN}监控网卡：${NETWORK_INTERFACE}${NC}"
echo -e "${GREEN}aria2 线程：${ARIA2_THREADS}${NC}"
echo -e "${YELLOW}文件清理阈值：${DELETE_FILE_SIZE_MB} MB${NC}"
echo -e "${YELLOW}=====================================${NC}\n"

# 磁盘检查（仅一次，屏蔽输出）
available_space=$(df -P -B1 . 2>/dev/null | awk 'NR==2 {gsub(/[^0-9]/,"",$4); print $4}')
[[ ! "$available_space" =~ ^[0-9]+$ ]] && available_space=0
if (( $(echo "$available_space < $THRESHOLD_BYTES / 2" | bc -l) )); then
    echo -e "${YELLOW}⚠️  警告：当前磁盘可用空间不足，启用文件监控清理模式${NC}\n"
else
    echo -e "${GREEN}ℹ️  当前磁盘空间充足，启用文件监控清理模式${NC}\n"
fi

# 初始化变量
task=1
last_rx=$START_RX
last_time=$(date +%s)
aria_pid=0
TMP_FILE="tmp_$task"

# 启动前先清理一次残留的临时文件
clean_aria2_temp_files "$TMP_FILE"

# 先启动一次aria2（屏蔽所有输出）
aria2c -x "$ARIA2_THREADS" -s "$ARIA2_THREADS" \
    --file-allocation=none --auto-file-renaming=false \
    --summary-interval=0 --disable-ipv6=true --allow-overwrite=true \
    -o "$TMP_FILE" "$FILE_URL" > /tmp/aria2.log 2>&1 &
aria_pid=$!

# 启动监控线程（屏蔽输出）
monitor_and_clean_file "$TMP_FILE" $DELETE_SIZE $aria_pid >/dev/null 2>&1 &

# 主循环（仅输出单行状态，彻底屏蔽所有其他输出）
while true; do
    # 检查aria2是否存活（用/proc目录，无ps命令，无输出）
    if [ ! -d /proc/$aria_pid ]; then
        # 先清理上一个任务的临时文件
        clean_aria2_temp_files "$TMP_FILE"
        task=$((task + 1))
        TMP_FILE="tmp_$task"
        aria2c -x "$ARIA2_THREADS" -s "$ARIA2_THREADS" \
            --file-allocation=none --auto-file-renaming=false \
            --summary-interval=0 --disable-ipv6=true --allow-overwrite=true \
            -o "$TMP_FILE" "$FILE_URL" > /tmp/aria2.log 2>&1 &
        aria_pid=$!
        monitor_and_clean_file "$TMP_FILE" $DELETE_SIZE $aria_pid >/dev/null 2>&1 &
    fi

    # 计算流量/速度/ETA
    NOW_RX=$(get_rx)
    USED_BYTES=$((NOW_RX - START_RX))
    USED_FMT=$(format_bytes_adaptive $USED_BYTES)
    PROGRESS=$(echo "scale=0; if ($USED_BYTES == 0) 0 else $USED_BYTES * 100 / $THRESHOLD_BYTES" | bc)

    # 速度和ETA计算
    now_time=$(date +%s)
    if (( now_time - last_time >= 1 )); then
        rx_diff=$((NOW_RX - last_rx))
        speed_bps=$((rx_diff / (now_time - last_time)))
        speed=$(format_speed_adaptive $speed_bps)
        eta_seconds=$(echo "scale=0; if ($speed_bps == 0) 0 else ($THRESHOLD_BYTES - $USED_BYTES) / $speed_bps" | bc)
        eta_minutes=$((eta_seconds / 60))
        eta_seconds_remain=$((eta_seconds % 60))
        eta="${eta_minutes}m${eta_seconds_remain}s"

        last_rx=$NOW_RX
        last_time=$now_time
    fi

    # 仅输出这一行，用\r覆盖，无任何其他输出
    echo -ne "[${RED}${TASK_ID}${NC} ${GREEN}${USED_FMT}/${THRESHOLD_FMT}(${PROGRESS}%)${NC} ${CYAN}CN:${ARIA2_THREADS}${NC} ${GREEN}DL:${speed}${NC} ${YELLOW}ETA:${eta}${NC}]\r"

    # 流量阈值检查
    if [ $USED_BYTES -ge $THRESHOLD_BYTES ]; then
        kill $aria_pid 2>/dev/null
        wait $aria_pid 2>/dev/null
        echo -e "\n${GREEN}✅ 已达到阈值：${USED_FMT} / ${THRESHOLD_FMT}，停止脚本${NC}"
        exit 0
    fi

    sleep 0.5
done
