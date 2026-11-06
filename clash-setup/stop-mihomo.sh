#!/usr/bin/env bash
# 停止 mihomo（flock 防并发、写主动停止标记[看门狗据此不自动拉起]、恢复系统直连）
PIDF="$HOME/clash-setup/mihomo.pid"
STOPMARK="$HOME/.config/mihomo/.user-stopped"
stopped=0

# 全局操作锁：与 start/autostart/watchdog 串行
exec 9>/tmp/mihomo-control.lock
flock -w 30 9 || { echo "⚠️ 另一个启停操作正在进行，请稍候重试"; exit 1; }

# 写主动停止标记：看门狗检测到它将不再自动拉起，直到下次手动/开机启动
touch "$STOPMARK"

# PID文件方式
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  kill "$(cat "$PIDF")" 2>/dev/null && { echo "mihomo 已停止 (PID $(cat "$PIDF"))"; stopped=1; }
  rm -f "$PIDF"
fi

# 进程兜底（PID文件丢失时）
if [ "$stopped" = "0" ] && pgrep -x mihomo >/dev/null 2>&1; then
  pkill -x mihomo 2>/dev/null && { echo "mihomo 已停止（进程兜底）"; stopped=1; } || echo "停止失败"
  sleep 1
fi

# 验证
if pgrep -x mihomo >/dev/null 2>&1; then
  echo "⚠️ 仍有 mihomo 进程，强杀..."; pkill -9 -x mihomo 2>/dev/null || true; sleep 1
fi

# 恢复系统代理为直连（关键：停止mihomo后所有应用自动直连，网页/微信/QQ正常）
gsettings set org.gnome.system.proxy mode 'none'
if ss -tln 2>/dev/null | grep -q ":9090"; then
  echo "⚠️ 9090 仍被占用，可能其他实例"
else
  echo "✅ mihomo 已停止，系统代理已恢复直连（浏览器/微信/QQ 正常上网）"
fi
