#!/bin/bash
set -euo pipefail

# ============================================================
# install.sh - 磁盘清理脚本安装工具
#
# 功能：创建软链接、设置定时任务、初始化配置
# 用法：bash install.sh
# ============================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/.local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"
BIN_LINK="${HOME}/.local/bin/disk-cleanup"
CRON_JOB="0 10 * * 1 ${SCRIPT_DIR}/disk-cleanup.sh --cron >> ${SCRIPT_DIR}/logs/cron.log 2>&1"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  磁盘清理脚本 - 安装${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# 1. 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${YELLOW}[1/5] 创建配置文件...${NC}"

    if sudo -n true 2>/dev/null; then
        echo -e "  ${GREEN}检测到 sudo 免密已配置，无需存储密码${NC}"
        cat > "$CONFIG_FILE" << 'EOF'
# 磁盘清理脚本配置文件
# sudo 密码（留空=已配置 sudoers 免密）
SUDO_PASSWORD=""

# 自动清理阈值（GB）
DEFAULT_THRESHOLD_GB=2

# journal 日志保留天数
JOURNAL_RETENTION_DAYS=7

# 磁盘使用率告警阈值（%）
DISK_USAGE_THRESHOLD=80
EOF
    else
        echo -e "  ${YELLOW}sudo 免密未配置，系统级清理需要密码${NC}"
        echo -n "请输入 sudo 密码（用于系统级清理，直接回车跳过则需手动配置 sudoers 免密）: "
        read -r -s pwd_input
        echo ""

        if [ -n "$pwd_input" ]; then
            cat > "$CONFIG_FILE" << EOF
# 磁盘清理脚本配置文件
# sudo 密码（用于系统级清理）
SUDO_PASSWORD="${pwd_input}"

# 自动清理阈值（GB）
DEFAULT_THRESHOLD_GB=2

# journal 日志保留天数
JOURNAL_RETENTION_DAYS=7

# 磁盘使用率告警阈值（%）
DISK_USAGE_THRESHOLD=80
EOF
        else
            cat > "$CONFIG_FILE" << 'EOF'
# 磁盘清理脚本配置文件
# sudo 密码（留空则需配置 sudoers 免密: sudo visudo → huawei ALL=(ALL) NOPASSWD: ALL）
SUDO_PASSWORD=""

# 自动清理阈值（GB）
DEFAULT_THRESHOLD_GB=2

# journal 日志保留天数
JOURNAL_RETENTION_DAYS=7

# 磁盘使用率告警阈值（%）
DISK_USAGE_THRESHOLD=80
EOF
        fi
    fi
    chmod 600 "$CONFIG_FILE"
    echo -e "  ${GREEN}配置文件已创建: ${CONFIG_FILE}${NC}"
else
    echo -e "${GREEN}[1/5] 配置文件已存在，跳过${NC}"
fi

# 2. 创建目录
echo -e "${YELLOW}[2/5] 创建目录...${NC}"
mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/state"
echo -e "  ${GREEN}logs/ 和 state/ 目录已就绪${NC}"

# 3. 创建软链接
echo -e "${YELLOW}[3/5] 创建命令软链接...${NC}"
mkdir -p "${HOME}/.local/bin"
if [ -L "$BIN_LINK" ] || [ -f "$BIN_LINK" ]; then
    rm -f "$BIN_LINK"
fi
ln -s "${SCRIPT_DIR}/disk-cleanup.sh" "$BIN_LINK"
chmod +x "${SCRIPT_DIR}/disk-cleanup.sh"
echo -e "  ${GREEN}软链接: ${BIN_LINK} → ${SCRIPT_DIR}/disk-cleanup.sh${NC}"
echo -e "  ${GREEN}终端可直接使用: disk-cleanup --help${NC}"

# 4. 设置 crontab
echo -e "${YELLOW}[4/5] 设置 crontab 定时任务...${NC}"
CRON_MARKER="# disk-cleanup"
EXISTING_CRONS=""
if crontab -l 2>/dev/null | grep -q .; then
    EXISTING_CRONS=$(crontab -l 2>/dev/null | grep -v "disk-cleanup" || true)
fi
(
    [ -n "$EXISTING_CRONS" ] && echo "$EXISTING_CRONS" || true
    echo "${CRON_MARKER} - 每周一上午10点自动清理"
    echo "$CRON_JOB"
) | crontab -
echo -e "  ${GREEN}crontab 已设置: 每周一上午10点自动检查清理${NC}"
echo -e "  ${GREEN}定时任务: ${CRON_JOB}${NC}"

# 5. 验证
echo -e "${YELLOW}[5/5] 验证安装...${NC}"
echo ""
echo -e "${BOLD}安装结果:${NC}"
echo -e "  脚本目录: ${SCRIPT_DIR}"
echo -e "  配置文件: ${CONFIG_FILE}"
echo -e "  命令路径: ${BIN_LINK}"
echo -e "  日志目录: ${SCRIPT_DIR}/logs/"
echo -e "  状态目录: ${SCRIPT_DIR}/state/"
echo ""
echo -e "${GREEN}安装完成！${NC}"
echo -e "  检查磁盘: ${BOLD}disk-cleanup --check${NC}"
echo -e "  手动清理: ${BOLD}disk-cleanup --clean${NC}"
echo -e "  查看历史: ${BOLD}disk-cleanup --history${NC}"
echo -e "  查看帮助: ${BOLD}disk-cleanup --help${NC}"
echo ""
echo -e "${YELLOW}提示: 如果迁移了脚本文件夹，重新运行 install.sh 即可${NC}"
