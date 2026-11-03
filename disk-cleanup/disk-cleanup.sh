#!/bin/bash
set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/.local/bin"

# ============================================================
# disk-cleanup.sh - 磁盘清理检查脚本
#
# 功能：检查并清理系统垃圾文件，支持检查报告/手动清理/自动清理
#
# 用法:
#   disk-cleanup --check              检查并输出报告（不清理）
#   disk-cleanup --clean               执行清理
#   disk-cleanup --auto [阈值GB]       超过阈值自动清理（默认2GB）
#   disk-cleanup --cron                cron模式（=--auto，精简输出）
#   disk-cleanup --history             查看清理历史
#   disk-cleanup --help                显示帮助
#
# 安装: 运行 install.sh 自动创建软链接和定时任务
# ============================================================

# --- 自动定位脚本目录（解析软链接） ---
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"
STATE_DIR="${SCRIPT_DIR}/state"
LOGS_DIR="${SCRIPT_DIR}/logs"
STATE_FILE="${STATE_DIR}/last-clean"
HISTORY_FILE="${STATE_DIR}/cleanup.log"

# --- 加载配置 ---
SUDO_PASSWORD=""
DEFAULT_THRESHOLD_GB=2
JOURNAL_RETENTION_DAYS=7
DISK_USAGE_THRESHOLD=80

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "[错误] 配置文件不存在: $CONFIG_FILE"
    echo "请先运行 install.sh 或手动创建配置文件"
    exit 1
fi

# sudo 帮助函数
sudo_run() {
    if [ -n "$SUDO_PASSWORD" ]; then
        echo "$SUDO_PASSWORD" | sudo -S "$@" 2>/dev/null
    else
        sudo "$@" 2>/dev/null
    fi
}

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# 工具函数
# ============================================================

get_size_bytes() {
    local path="$1"
    if [ -d "$path" ] || [ -f "$path" ]; then
        du -sb "$path" 2>/dev/null | cut -f1
    else
        echo 0
    fi
}

format_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        printf "%d.%dG" $((bytes / 1073741824)) $((bytes % 1073741824 * 10 / 1073741824))
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        printf "%d.%dM" $((bytes / 1048576)) $((bytes % 1048576 * 10 / 1048576))
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        printf "%dK" $((bytes / 1024))
    else
        printf "%dB" "$bytes"
    fi
}

get_oldest_file_date() {
    local path="$1"
    local oldest=""
    if [ -d "$path" ]; then
        oldest=$(find "$path" -type f -printf '%T+\n' 2>/dev/null | sort | head -1)
        if [ -n "$oldest" ]; then
            echo "${oldest:0:10}"
        else
            echo "-"
        fi
    else
        echo "-"
    fi
}

get_disk_usage() {
    local partition="${1:-/}"
    df -h "$partition" 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " 已用, " $4 " 可用 (" $5 ")"}'
}

get_disk_usage_percent() {
    local partition="${1:-/}"
    df "$partition" 2>/dev/null | tail -1 | awk '{gsub(/%/,"",$5); print $5}'
}

get_machine_id() {
    cat /etc/machine-id 2>/dev/null || echo "unknown"
}

get_item_size() {
    local id="$1" path="$2"
    local mid
    mid=$(get_machine_id)

    case "$id" in
        journal_old)
            local total=0
            for dir in /var/log/journal/*/; do
                [ -d "$dir" ] || continue
                local dname
                dname=$(basename "$dir")
                if [ "$dname" != "$mid" ]; then
                    total=$((total + $(get_size_bytes "$dir")))
                fi
            done
            echo "$total"
            ;;
        journal_vacuum)
            get_size_bytes "/var/log/journal/${mid}"
            ;;
        *)
            get_size_bytes "$path"
            ;;
    esac
}

get_item_oldest_date() {
    local id="$1" path="$2"
    local mid
    mid=$(get_machine_id)

    case "$id" in
        journal_old)
            local oldest=""
            for dir in /var/log/journal/*/; do
                [ -d "$dir" ] || continue
                local dname
                dname=$(basename "$dir")
                if [ "$dname" != "$mid" ]; then
                    local d
                    d=$(get_oldest_file_date "$dir")
                    [ "$d" != "-" ] && {
                        [ -z "$oldest" ] && oldest="$d" || {
                            [ "$d" \< "$oldest" ] && oldest="$d"
                        }
                    }
                fi
            done
            [ -n "$oldest" ] && echo "$oldest" || echo "-"
            ;;
        journal_vacuum)
            get_oldest_file_date "/var/log/journal/${mid}"
            ;;
        *)
            get_oldest_file_date "$path"
            ;;
    esac
}

rotate_logs() {
    local log_count
    log_count=$(ls -1 "$LOGS_DIR"/cleanup-*.log 2>/dev/null | wc -l)
    if [ "$log_count" -gt 20 ] 2>/dev/null; then
        ls -1 "$LOGS_DIR"/cleanup-*.log 2>/dev/null | sort | head -n -20 | while IFS= read -r old_log; do
            rm -f "$old_log"
        done
    fi

    if [ -f "$HISTORY_FILE" ]; then
        local hist_count
        hist_count=$(wc -l < "$HISTORY_FILE" 2>/dev/null || echo 0)
        if [ "$hist_count" -gt 50 ] 2>/dev/null; then
            tail -50 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
        fi
    fi

    local cron_log="${LOGS_DIR}/cron.log"
    if [ -f "$cron_log" ]; then
        local cron_size
        cron_size=$(stat -c%s "$cron_log" 2>/dev/null || echo 0)
        if [ "$cron_size" -gt 1048576 ] 2>/dev/null; then
            tail -200 "$cron_log" > "${cron_log}.tmp" && mv "${cron_log}.tmp" "$cron_log"
        fi
    fi
}

# ============================================================
# 清理函数
# ============================================================

clean_journal_old() {
    local mid
    mid=$(get_machine_id)
    for dir in /var/log/journal/*/; do
        [ -d "$dir" ] || continue
        local dname
        dname=$(basename "$dir")
        [ "$dname" != "$mid" ] && sudo_run rm -rf "$dir"
    done
}

clean_journal_vacuum() {
    sudo_run journalctl --vacuum-time="${JOURNAL_RETENTION_DAYS}d"
}

clean_coredump() {
    sudo_run rm -rf /var/lib/systemd/coredump/*
}

clean_apt() {
    sudo_run apt clean
}

clean_hwupdate() {
    sudo_run rm -rf /var/log/hwupdate/*
}

clean_user_cache() {
    rm -rf "${HOME}/.cache/"* 2>/dev/null
}

clean_npm_cache() {
    rm -rf "${HOME}/.npm/_cacache" 2>/dev/null
    npm cache clean --force 2>/dev/null
}

# 清理项数组: "ID|名称|检查路径|类型|清理函数"
CLEAN_ITEMS=(
    "journal_old|journal旧日志(旧机器ID)|/var/log/journal|system|clean_journal_old"
    "journal_vacuum|journal日志(vacuum${JOURNAL_RETENTION_DAYS}天)|/var/log/journal|system|clean_journal_vacuum"
    "coredump|核心转储文件|/var/lib/systemd/coredump|system|clean_coredump"
    "apt_cache|APT包缓存|/var/cache/apt|system|clean_apt"
    "hwupdate|硬件更新日志|/var/log/hwupdate|system|clean_hwupdate"
    "user_cache|应用缓存(.cache)|${HOME}/.cache|user|clean_user_cache"
    "npm_cache|npm缓存|${HOME}/.npm|user|clean_npm_cache"
)

# ============================================================
# 检查报告
# ============================================================

do_check() {
    local total_bytes=0
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    local last_clean="无"
    if [ -f "$STATE_FILE" ]; then
        last_clean=$(cat "$STATE_FILE" 2>/dev/null)
    fi

    echo ""
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${CYAN}  磁盘清理检查报告${NC}"
    echo -e "${CYAN}  生成时间: ${now}${NC}"
    echo -e "${CYAN}  上次清理: ${last_clean}${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo ""

    echo -e "${BOLD}根分区状态:${NC} $(get_disk_usage /)"
    echo ""

    echo -e "${BOLD}清理项检查:${NC}"
    echo -e "${GRAY}--------------------------------------------------------${NC}"
    printf "%-6s %-28s %10s %12s %s\n" "类型" "项目" "当前大小" "最旧文件" "状态"
    echo -e "${GRAY}--------------------------------------------------------${NC}"

    for item in "${CLEAN_ITEMS[@]}"; do
        IFS='|' read -r id name path typpe func <<< "$item"
        local size_bytes size_str oldest status
        size_bytes=$(get_item_size "$id" "$path")
        [ "$size_bytes" -eq 0 ] 2>/dev/null && continue
        size_str=$(format_size "$size_bytes")
        oldest=$(get_item_oldest_date "$id" "$path")

        if [ "$size_bytes" -gt 10485760 ] 2>/dev/null; then
            status="${YELLOW}可清理${NC}"
        elif [ "$size_bytes" -gt 1024 ] 2>/dev/null; then
            status="${GRAY}少量${NC}"
        else
            status="${GREEN}干净${NC}"
        fi

        local type_label
        if [ "$typpe" = "system" ]; then
            type_label="${GRAY}系统${NC}"
        else
            type_label="${GRAY}用户${NC}"
        fi

        printf "%-8b %-28s %10s %12s " "$type_label" "$name" "$size_str" "$oldest"
        echo -e "$status"

        total_bytes=$((total_bytes + size_bytes))
    done

    echo -e "${GRAY}--------------------------------------------------------${NC}"
    echo -e "${BOLD}可清理总计: $(format_size $total_bytes)${NC}"
    echo ""
}

# ============================================================
# 执行清理
# ============================================================

do_clean() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    local timestamp
    timestamp=$(date '+%Y-%m-%d-%H%M%S')
    local total_freed=0
    local disk_before disk_after
    disk_before=$(get_disk_usage /)

    # 准备日志目录
    mkdir -p "$LOGS_DIR" "$STATE_DIR"

    # 本次清理单独日志文件
    local log_file="${LOGS_DIR}/cleanup-${timestamp}.log"

    # 写入日志头
    {
        echo "=============================================="
        echo "  磁盘清理日志"
        echo "  日期: ${now}"
        echo "  清理前磁盘: ${disk_before}"
        echo "=============================================="
        echo ""
    } > "$log_file"

    echo -e "${CYAN}========================================================${NC}"
    echo -e "${CYAN}  开始磁盘清理  ${now}${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo ""

    echo -e "${BOLD}清理前: ${disk_before}${NC}"
    echo ""

    # 逐项清理
    for item in "${CLEAN_ITEMS[@]}"; do
        IFS='|' read -r id name path typpe func <<< "$item"

        local before_bytes before_str
        before_bytes=$(get_item_size "$id" "$path")
        [ "$before_bytes" -eq 0 ] 2>/dev/null && continue
        before_str=$(format_size "$before_bytes")

        if [ "$before_bytes" -lt 1024 ] 2>/dev/null; then
            echo -e "  ${GRAY}[跳过]${NC} $name (${before_str}) - 无需清理"
            echo "  [跳过] $name (${before_str}) - 无需清理" >> "$log_file"
            continue
        fi

        echo -e "  ${YELLOW}[清理]${NC} $name (${before_str})..."
        $func >/dev/null 2>&1

        local after_bytes after_str freed_bytes freed_str
        after_bytes=$(get_item_size "$id" "$path")
        after_str=$(format_size "$after_bytes")
        freed_bytes=$((before_bytes - after_bytes))
        freed_str=$(format_size "$freed_bytes")

        if [ "$after_bytes" -ge "$before_bytes" ] 2>/dev/null; then
            echo -e "         ${RED}[失败]${NC} 清理前=${before_str} 清理后=${after_str}（权限不足或被占用）"
            echo "  [失败] $name | 清理前=${before_str} 清理后=${after_str}（权限不足或被占用）" >> "$log_file"
        else
            echo -e "         ${GREEN}完成${NC} 清理前=${before_str} 清理后=${after_str} 释放=${freed_str}"
            echo "  [完成] $name | 清理前=${before_str} 清理后=${after_str} 释放=${freed_str}" >> "$log_file"
            total_freed=$((total_freed + freed_bytes))
        fi
    done

    disk_after=$(get_disk_usage /)
    local total_freed_str
    total_freed_str=$(format_size $total_freed)

    echo ""
    echo -e "${BOLD}清理后: ${disk_after}${NC}"
    echo -e "${GREEN}本次共释放: ${total_freed_str}${NC}"
    echo ""

    # 写入日志尾
    {
        echo ""
        echo "----------------------------------------------"
        echo "  清理后磁盘: ${disk_after}"
        echo "  本次共释放: ${total_freed_str}"
        echo "  日志文件: ${log_file}"
        echo "----------------------------------------------"
    } >> "$log_file"

    # 更新状态文件
    echo "${now} (释放 ${total_freed_str})" > "$STATE_FILE"
    echo "${now} | 释放: ${total_freed_str} | 磁盘: ${disk_after} | 日志: ${log_file}" >> "$HISTORY_FILE"

    echo -e "${GRAY}本次日志: ${log_file}${NC}"
    echo -e "${GRAY}历史记录: ${HISTORY_FILE}${NC}"

    rotate_logs
}

# ============================================================
# 自动模式
# ============================================================

do_auto() {
    rotate_logs
    local threshold_gb="${1:-$DEFAULT_THRESHOLD_GB}"
    local threshold_bytes=$((threshold_gb * 1073741824))

    local total_bytes=0
    for item in "${CLEAN_ITEMS[@]}"; do
        IFS='|' read -r id name path typpe func <<< "$item"
        local size_bytes
        size_bytes=$(get_item_size "$id" "$path")
        total_bytes=$((total_bytes + size_bytes))
    done

    local percent
    percent=$(get_disk_usage_percent /)

    echo -e "${GRAY}[$(date '+%H:%M:%S')] 自动检查: 可清理 $(format_size $total_bytes), 阈值 $(format_size $threshold_bytes), 磁盘使用率 ${percent}%${NC}"

    if [ "$total_bytes" -ge "$threshold_bytes" ] 2>/dev/null || [ "$percent" -ge "$DISK_USAGE_THRESHOLD" ] 2>/dev/null; then
        echo -e "${YELLOW}超过阈值或磁盘使用率>=${DISK_USAGE_THRESHOLD}%，开始清理...${NC}"
        do_clean
    else
        echo -e "${GREEN}未超过阈值，无需清理${NC}"
    fi
}

# ============================================================
# 历史记录
# ============================================================

do_history() {
    echo ""
    echo -e "${CYAN}=== 清理历史 (最近20条) ===${NC}"
    if [ -f "$HISTORY_FILE" ]; then
        tail -20 "$HISTORY_FILE"
    else
        echo "暂无清理记录"
    fi
    echo ""
    echo -e "${CYAN}=== 上次清理 ===${NC}"
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "尚未执行过清理"
    fi
    echo ""
    echo -e "${CYAN}=== 日志文件列表 ===${NC}"
    if [ -d "$LOGS_DIR" ]; then
        ls -1 "$LOGS_DIR"/cleanup-*.log 2>/dev/null | sort -r | head -10
    else
        echo "暂无日志文件"
    fi
    echo ""
}

# ============================================================
# 帮助
# ============================================================

show_help() {
    cat << HELP
磁盘清理检查脚本

用法:
  disk-cleanup（无参数）             交互模式（检查→确认→清理）
  disk-cleanup --check              检查并输出报告（不清理）
  disk-cleanup --clean               执行清理
  disk-cleanup --auto [阈值GB]       超过阈值自动清理（默认${DEFAULT_THRESHOLD_GB}GB）
  disk-cleanup --cron                cron模式（=--auto，精简输出）
  disk-cleanup --history             查看清理历史和日志
  disk-cleanup --help                显示帮助

清理项:
  [系统] journal旧日志(旧机器ID目录)
  [系统] journal日志(vacuum保留${JOURNAL_RETENTION_DAYS}天)
  [系统] 核心转储文件(coredump)
  [系统] APT包缓存
  [系统] 硬件更新日志(hwupdate)
  [用户] 应用缓存(~/.cache)
  [用户] npm缓存(~/.npm)

文件结构:
  ${SCRIPT_DIR}/
  ├── disk-cleanup.sh       主脚本
  ├── install.sh            安装脚本
  ├── uninstall.sh          卸载脚本
  ├── README.md             使用说明
  ├── config/config.conf    配置文件(密码/阈值)
  ├── logs/                 每次清理的单独日志
  └── state/                状态文件

安装: bash install.sh
卸载: bash uninstall.sh

HELP
}

# ============================================================
# 交互模式（双击运行时默认进入）
# ============================================================

do_interactive() {
    if [ ! -t 0 ]; then
        do_check
        return
    fi

    while true; do
        do_check

        echo ""
        echo -e "${BOLD}操作: ${GREEN}y${NC}=执行清理  ${YELLOW}n${NC}=重新检查  ${GRAY}（直接回车退出）${NC}"
        read -r -p "> " choice

        case "$choice" in
            y|Y)
                echo ""
                do_clean
                ;;
            n|N)
                continue
                ;;
            *)
                break
                ;;
        esac
    done

    echo ""
    echo -e "${GREEN}已退出磁盘清理工具${NC}"
}

# ============================================================
# 主入口
# ============================================================

main() {
    local mode="${1:-}"

    case "$mode" in
        --check|-c)
            do_check
            ;;
        --clean)
            do_clean
            ;;
        --auto)
            do_auto "${2:-}"
            ;;
        --cron)
            do_auto "${2:-}"
            ;;
        --history|-h)
            do_history
            ;;
        --help)
            show_help
            ;;
        "")
            do_interactive
            ;;
        *)
            echo "未知参数: $mode"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
}

main "$@"
