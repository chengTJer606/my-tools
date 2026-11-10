#!/usr/bin/env bash
# open-panel.sh —— 打开 mihomo Web 面板（未运行则提示）
# 9090 API 已启用 secret，通过 URL 参数自动带给 metacubexd（首次会存入其 localStorage）
SECRET=""; [ -f "$HOME/clash-setup/api.secret" ] && SECRET=$(cat "$HOME/clash-setup/api.secret")
if pgrep -x mihomo >/dev/null 2>&1 && ss -tln "sport = :9090" 2>/dev/null | grep -q LISTEN; then
  /usr/bin/browser360-cn "http://127.0.0.1:9090/ui/?hostname=127.0.0.1&port=9090&secret=${SECRET}"
else
  zenity --info --title="提示" --text="mihomo 未运行\n请先在控制面板选择「启动」" --width=300 2>/dev/null \
    || echo "mihomo 未运行，请先在控制面板选择「启动」"
fi
