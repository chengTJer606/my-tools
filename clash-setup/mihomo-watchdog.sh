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
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/mihomo-control.lock"
flock -w 20 9 || exit 0

# 1) 用户主动停止过 → 不动
[ -f "$STOPMARK" ] && exit 0

# 日志防膨胀：>10MB 保留尾部1MB（copytruncate 方式：保持 inode 不变，
# 运行中的 mihomo fd 不受影响；配合启动处的 >> O_APPEND 追加模式无稀疏空洞）
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
  tail -c 1048576 "$LOG" > "$LOG.tmp.$$" && cat "$LOG.tmp.$$" > "$LOG" && rm -f "$LOG.tmp.$$"
fi

set_proxy_manual() {
  gsettings set org.gnome.system.proxy mode 'manual'
  gsettings set org.gnome.system.proxy.http host '127.0.0.1'
  gsettings set org.gnome.system.proxy.http port 7890
  gsettings set org.gnome.system.proxy.https host '127.0.0.1'
  gsettings set org.gnome.system.proxy.https port 7890
  gsettings set org.gnome.system.proxy.socks host '127.0.0.1'
  gsettings set org.gnome.system.proxy.socks port 7890
  gsettings set org.gnome.system.proxy ignore-hosts "['localhost','127.0.0.0/8','::1','10.0.0.0/8','172.16.0.0/12','192.168.0.0/16']"
}

node_ok() {
  [ "$(curl -s --noproxy '' --max-time 6 --proxy http://127.0.0.1:7890 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 2>/dev/null)" = "204" ]
}

# 2) mihomo 未运行 → 拉起（以进程身份判定：9090 端口可能被其他程序占用，不能作为存活依据）
if ! pgrep -x mihomo >/dev/null 2>&1; then
  pkill -x mihomo 2>/dev/null || true; sleep 1
  nohup "$BIN" -d "$DIR" >> "$LOG" 2>&1 9>&- 8>&- &
  echo $! > "$PIDF"
  for i in $(seq 1 15); do pgrep -x mihomo >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ':9090' && break; sleep 1; done
  if pgrep -x mihomo >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ':9090'; then
    echo "$(date '+%F %T') watchdog: mihomo 未运行，已自动拉起" >> "$LOG"
  else
    if ss -tln 2>/dev/null | grep -q ':9090'; then
      echo "$(date '+%F %T') watchdog: 拉起失败——9090 被其他程序占用，下分钟重试" >> "$LOG"
    else
      echo "$(date '+%F %T') watchdog: mihomo 拉起失败，下分钟重试" >> "$LOG"
    fi
    exit 1
  fi
fi

# 3) 系统代理补设：完整校验(模式+三协议地址端口)，任一项不对且节点通 → 重设为正确值
proxy_ok() {
  [ "$(gsettings get org.gnome.system.proxy mode 2>/dev/null)" = "'manual'" ] || return 1
  for k in http https socks; do
    [ "$(gsettings get org.gnome.system.proxy.$k host 2>/dev/null)" = "'127.0.0.1'" ] || return 1
    [ "$(gsettings get org.gnome.system.proxy.$k port 2>/dev/null)" = "7890" ] || return 1
  done
  return 0
}

if ! proxy_ok; then
  if node_ok; then
    set_proxy_manual
    echo "$(date '+%F %T') watchdog: 系统代理缺失/配置不正确，已自动补设 127.0.0.1:7890" >> "$LOG"
  fi
fi
