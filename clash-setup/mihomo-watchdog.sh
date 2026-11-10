#!/usr/bin/env bash
# mihomo-watchdog.sh —— 自愈看门狗（由 systemd --user timer 每30秒触发，也可手动运行）
# 1) 用户双击「停止」过（存在停止标记）→ 尊重用户意图，不做任何事
# 2) mihomo 未运行 → fail-open 切直连 + 自动拉起
# 2.5) mihomo 假活（进程在但 7890 无监听，卡死/热重载失败）→ fail-open + 强杀重启
# 3) mihomo 在跑 + 系统代理≠manual + 节点连通 → 自动补设代理
# 4) mihomo 在跑但节点连续 5 个周期(约2.5分钟)不可达 → 自动降级直连（恢复可达后自动补设）
BIN="$HOME/.local/bin/mihomo"
DIR="$HOME/.config/mihomo"
LOG="$HOME/clash-setup/mihomo.log"
PIDF="$HOME/clash-setup/mihomo.pid"
STOPMARK="$DIR/.user-stopped"
FAILCNT="/tmp/mihomo-node-fail.count"

# 全局操作锁：与 start/stop/autostart 串行，防互杀
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/mihomo-control.lock"
flock -w 20 9 || exit 0

# 1) 用户主动停止过 → 不动
[ -f "$STOPMARK" ] && { rm -f "$FAILCNT"; exit 0; }

# 日志防膨胀：>10MB 保留尾部1MB（copytruncate 方式：保持 inode 不变，
# 运行中的 mihomo fd 不受影响；tmp 文件放 /tmp，避免残留污染 clash-setup）
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
  tail -c 1048576 "$LOG" > /tmp/mihomo.log.trunc.$$ && cat /tmp/mihomo.log.trunc.$$ > "$LOG" && rm -f /tmp/mihomo.log.trunc.$$
fi

# 端口精确匹配（ss 过滤器语法，避免解析列格式的脆弱 grep）
port_listen() { ss -tln "sport = :$1" 2>/dev/null | grep -q LISTEN; }

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

# 拉起 mihomo 并等待就绪（分支 2 与 2.5 共用）
pull_up() {
  pkill -x mihomo 2>/dev/null || true; sleep 1
  nohup "$BIN" -d "$DIR" >> "$LOG" 2>&1 9>&- 8>&- &
  echo $! > "$PIDF"
  for i in $(seq 1 15); do pgrep -x mihomo >/dev/null 2>&1 && port_listen 9090 && break; sleep 1; done
  if pgrep -x mihomo >/dev/null 2>&1 && port_listen 9090; then
    echo "$(date '+%F %T') watchdog: mihomo 未运行，已自动拉起" >> "$LOG"
  else
    if port_listen 9090; then
      echo "$(date '+%F %T') watchdog: 拉起失败——9090 被其他程序占用，下周期重试" >> "$LOG"
    else
      echo "$(date '+%F %T') watchdog: mihomo 拉起失败，下周期重试" >> "$LOG"
    fi
    exit 1
  fi
}

# fail-open：系统代理还是 manual 且 7890 无监听 → 切直连，浏览器立即可用
fail_open() {
  if [ "$(gsettings get org.gnome.system.proxy mode 2>/dev/null)" = "'manual'" ]; then
    if port_listen 7890; then
      : # 7890 仍有监听（可能是别的进程），不动代理设置
    else
      gsettings set org.gnome.system.proxy mode 'none'
      echo "$(date '+%F %T') watchdog: $1，系统代理已临时切回直连(fail-open)" >> "$LOG"
    fi
  fi
}

# 2) mihomo 未运行 → 先 fail-open 切直连，再拉起
#    为什么先切：进程已死但系统代理还是 manual 时，浏览器/微信会全部指向
#    127.0.0.1:7890 这个没有监听的端口，表现就是"网全断了"。
if ! pgrep -x mihomo >/dev/null 2>&1; then
  fail_open "mihomo 不在且 7890 无监听"
  pull_up
fi

# 2.5) 假活检测：进程在但 7890 无监听（进程卡死/热重载失败/配置损坏导致端口关闭）
#      此时系统代理若还是 manual，浏览器会长期指向死端口——这是历史上唯一的
#      高危假连接路径。判定：9090 也无监听（彻底卡死）或进程已存活超过60秒
#      （排除刚启动还没监听的窗口期）→ 强杀重启。
if ! port_listen 7890; then
  _pid=$(pgrep -x mihomo | head -1)
  if [ -n "$_pid" ]; then
    _age=$(ps -o etimes= -p "$_pid" 2>/dev/null | tr -d ' ')
    _age=${_age:-0}
    if port_listen 9090 || [ "$_age" -ge 60 ]; then
      fail_open "mihomo 假活（进程在 PID $_pid 但 7890 无监听）"
      echo "$(date '+%F %T') watchdog: mihomo 假活（进程在但 7890 无监听，存活${_age}s），已强杀重启" >> "$LOG"
      pull_up
    else
      # 刚启动还没监听，交给下一周期
      exit 0
    fi
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

# 4) 节点持续不可达降级：进程和端口都正常但节点连续 5 个周期不通（约2.5分钟，
#    典型场景：换到封端口/劣质网络），manual 挂着只会让浏览器报错——切直连
#    保证可用，节点恢复后下一周期自动补设回来。
if node_ok; then
  rm -f "$FAILCNT"
  if ! proxy_ok; then
    # 刚拉起的 mihomo 可能需要几秒才把节点测通，这里给 3 次机会再放弃
    ok=0
    for i in 1 2 3; do
      node_ok && { ok=1; break; }
      sleep 3
    done
    if [ "$ok" = "1" ]; then
      set_proxy_manual
      echo "$(date '+%F %T') watchdog: 系统代理缺失/配置不正确，已自动补设 127.0.0.1:7890" >> "$LOG"
    fi
  fi
else
  if proxy_ok; then
    n=$(cat "$FAILCNT" 2>/dev/null || echo 0); n=$((n+1))
    echo "$n" > "$FAILCNT"
    if [ "$n" -ge 5 ]; then
      gsettings set org.gnome.system.proxy mode 'none'
      rm -f "$FAILCNT"
      echo "$(date '+%F %T') watchdog: 节点连续5个周期不可达，已自动降级直连（节点恢复后自动切回代理）" >> "$LOG"
    else
      echo "$(date '+%F %T') watchdog: 节点暂不可达（第${n}/5个周期），暂不动作" >> "$LOG"
    fi
  else
    rm -f "$FAILCNT"  # 本来就没设代理，无需降级
  fi
fi
