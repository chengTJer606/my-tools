#!/usr/bin/env bash
# mihomo-watchdog.sh —— 自愈看门狗（由 systemd --user timer 每分钟触发，也可手动运行）
# 1) 用户双击「停止」过（存在停止标记）→ 尊重用户意图，不做任何事
# 2) mihomo 未运行 → 自动拉起
# 3) mihomo 在跑 + 系统代理≠manual + 节点连通 → 自动补设代理
BIN="$HOME/.local/bin/mihomo"
DIR="$HOME/.config/mihomo"
LOG="$HOME/clash-setup/mihomo.log"
PIDF="$HOME/clash-setup/mihomo.pid"
STOPMARK="$DIR/.user-stopped"

# 全局操作锁：与 start/stop/autostart 串行，防互杀
exec 9>/tmp/mihomo-control.lock
flock -w 20 9 || exit 0

# 1) 用户主动停止过 → 不动
[ -f "$STOPMARK" ] && exit 0

set_proxy_manual() {
  gsettings set org.gnome.system.proxy mode 'manual'
  gsettings set org.gnome.system.proxy.http host '127.0.0.1'
  gsettings set org.gnome.system.proxy.http port 7890
  gsettings set org.gnome.system.proxy.https host '127.0.0.1'
  gsettings set org.gnome.system.proxy.https port 7890
  gsettings set org.gnome.system.proxy.socks host '127.0.0.1'
  gsettings set org.gnome.system.proxy.socks port 7890
  gsettings set org.gnome.system.proxy ignore-hosts "['localhost','127.0.0.0/8','::1','10.0.0.0/8','192.168.0.0/16']"
}

node_ok() {
  [ "$(curl -s --max-time 6 --proxy http://127.0.0.1:7890 -o /dev/null -w '%{http_code}' http://www.gstatic.com/generate_204 2>/dev/null)" = "204" ]
}

# 2) mihomo 未运行 → 拉起
if ! ss -tln 2>/dev/null | grep -q ':9090'; then
  pkill -x mihomo 2>/dev/null || true; sleep 1
  nohup "$BIN" -d "$DIR" >> "$LOG" 2>&1 9>&- &
  echo $! > "$PIDF"
  for i in $(seq 1 15); do ss -tln 2>/dev/null | grep -q ':9090' && break; sleep 1; done
  if ss -tln 2>/dev/null | grep -q ':9090'; then
    echo "$(date '+%F %T') watchdog: mihomo 未运行，已自动拉起" >> "$LOG"
  else
    echo "$(date '+%F %T') watchdog: mihomo 拉起失败，下分钟重试" >> "$LOG"
    exit 1
  fi
fi

# 3) 系统代理补设：节点连通但代理不是 manual → 设上
if [ "$(gsettings get org.gnome.system.proxy mode 2>/dev/null)" != "'manual'" ]; then
  if node_ok; then
    set_proxy_manual
    echo "$(date '+%F %T') watchdog: 检测到系统代理缺失，已自动补设 127.0.0.1:7890" >> "$LOG"
  fi
fi
