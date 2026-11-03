#!/bin/bash
set -euo pipefail

# ============================================================
# uninstall.sh - 磁盘清理脚本卸载工具
#
# 功能：移除软链接、清理 crontab 定时任务
# 用法：bash uninstall.sh
# ============================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/.local/bin"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

BIN_LINK="${HOME}/.local/bin/disk-cleanup"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  磁盘清理脚本 - 卸载${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# 1. 移除软链接
echo -e "${YELLOW}[1/2] 移除软链接...${NC}"
if [ -L "$BIN_LINK" ] || [ -f "$BIN_LINK" ]; then
    rm -f "$BIN_LINK"
    echo -e "  ${GREEN}已移除: ${BIN_LINK}${NC}"
else
    echo -e "  ${GREEN}软链接不存在，跳过${NC}"
fi

# 2. 清理 crontab
echo -e "${YELLOW}[2/2] 清理 crontab 定时任务...${NC}"
(
    crontab -l 2>/dev/null | grep -v "disk-cleanup.sh" | grep -v "# disk-cleanup"
) | crontab - 2>/dev/null || true
echo -e "  ${GREEN}crontab 定时任务已移除${NC}"

echo ""
echo -e "${GREEN}卸载完成！${NC}"
echo -e "  软链接和定时任务已移除"
echo -e "  脚本文件夹、日志和配置文件保留（如需删除请手动）"
echo ""

if [ -t 0 ]; then
    read -r -p "按回车退出..." dummy
fi
