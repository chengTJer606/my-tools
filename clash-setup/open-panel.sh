#!/usr/bin/env bash
# open-panel.sh —— 打开 mihomo Web 面板（未运行则弹窗提示）
if pgrep -x mihomo >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":9090"; then
  /usr/bin/browser360-cn http://127.0.0.1:9090/ui
else
  zenity --info --title="提示" --text="mihomo 未运行\n请先双击「mihomo-启动」" --width=300 2>/dev/null \
    || echo "mihomo 未运行，请先双击「mihomo-启动」"
fi
