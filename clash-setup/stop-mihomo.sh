#!/usr/bin/env bash
# 停止 mihomo（flock 防并发、写主动停止标记[看门狗据此不自动拉起]、恢复系统直连）
PIDF="$HOME/clash-setup/mihomo.pid"
STOPMARK="$HOME/.config/mihomo/.user-stopped"
stopped=0

# 先写主动停止标记（必须在拿锁之前）：若此刻 watchdog/autostart 正持锁做拉起
# （最坏约99秒），拿锁超时退出也不会丢失用户的停止意图——看门狗看到标记即不再拉起
touch "$STOPMARK"

# 全局操作锁：与 start/autostart/watchdog 串行
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/mihomo-control.lock"
flock -w 30 9 || { echo "⚠️ 另一个启停操作正在进行（停止意图已记录，看门狗已静默），请稍后重试"; exit 1; }

# PID文件方式（先校验该PID确实是mihomo，防PID复用时误杀无关进程）
if [ -f "$PIDF" ]; then
  pid=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$pid" ] && [ "$(cat /proc/$pid/comm 2>/dev/null)" = "mihomo" ]; then
    kill "$pid" 2>/dev/null && { echo "mihomo 已停止 (PID $pid)"; stopped=1; }
  fi
  rm -f "$PIDF"
fi

# 进程兜底（PID文件丢失时）
if [ "$stopped" = "0" ] && pgrep -x mihomo >/dev/null 2>&1; then
  pkill -x mihomo 2>/dev/null && { echo "mihomo 已停止（进程兜底）"; stopped=1; } || echo "停止失败"
  sleep 1
fi

# 立刻切直连：不要等进程完全退出再切。否则 SIGTERM 到退出这几秒里，
# 系统代理还指着已经不通的 7890，浏览器会报"无法连接代理服务器"。
gsettings set org.gnome.system.proxy mode 'none'

# 验证（先给 SIGTERM 最多5秒优雅退出，再考虑强杀，避免秒变 SIGKILL）
for i in $(seq 1 5); do
  pgrep -x mihomo >/dev/null 2>&1 || break
  sleep 1
done
if pgrep -x mihomo >/dev/null 2>&1; then
  echo "⚠️ 仍有 mihomo 进程，强杀..."; pkill -9 -x mihomo 2>/dev/null || true; sleep 1
fi

# 恢复系统代理为直连（关键：停止mihomo后所有应用自动直连，网页/微信/QQ正常）
gsettings set org.gnome.system.proxy mode 'none'
if pgrep -x mihomo >/dev/null 2>&1; then
  echo "⚠️ 仍有 mihomo 进程残留"
elif ss -tln "sport = :9090" 2>/dev/null | grep -q LISTEN; then
  echo "ℹ️ 9090 被其他程序占用（非 mihomo，不影响）；已停止并恢复直连"
else
  echo "✅ mihomo 已停止，系统代理已恢复直连（浏览器/微信/QQ 正常上网）"
fi
