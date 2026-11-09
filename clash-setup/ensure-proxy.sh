#!/usr/bin/env bash
# ensure-proxy.sh —— 确保系统代理与 mihomo 状态一致
# 逻辑：mihomo 运行且节点连通 → 系统代理设为 127.0.0.1:7890
#       快速重试 4 次（间隔3秒）→ 仍不通转低频补设（每15秒×40次≈10分钟），通即设
# 可被 start-mihomo.sh / autostart-mihomo.sh 调用，也可单独运行手动修复

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

STOPMARK="$HOME/.config/mihomo/.user-stopped"

node_ok() {
  # 必须探测走 MATCH 规则的域名（google）才能验证节点真实可用；
  # 旧的 gstatic 命中 GEOIP,CN,DIRECT，节点全挂也会假阳性
  [ "$(curl -s --max-time 6 --noproxy '' --proxy http://127.0.0.1:7890 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 2>/dev/null)" = "204" ]
}

# 已在运行则跳过（避免 start/autostart 并发时重复补设）
LOCK="${XDG_RUNTIME_DIR:-/tmp}/ensure-proxy.lock"
exec 9>"$LOCK" && flock -n 9 || exit 0

for i in $(seq 1 44); do
  # 用户已主动停止 → 立即退出，绝不把系统代理写回 manual（修复与 stop 的竞态）
  [ -f "$STOPMARK" ] && { echo "用户已主动停止，退出"; exit 0; }
  # mihomo 进程不在了 → 无需补设，退出（以进程身份判定，非端口）
  pgrep -x mihomo >/dev/null 2>&1 || { echo "mihomo 未运行，退出"; exit 0; }
  if node_ok; then
    # 设置前再次确认停止标记，关闭检查后执行的竞态窗口
    [ -f "$STOPMARK" ] && { echo "用户已主动停止，退出"; exit 0; }
    set_proxy_manual
    echo "✅ 节点连通，系统代理已设为 127.0.0.1:7890"
    exit 0
  fi
  # 前4次快速重试，之后转入15秒一次的低频补设
  if [ "$i" -le 4 ]; then sleep 3; else sleep 15; fi
done

echo "⚠️ 约10分钟内节点未连通，系统代理保持原样（请检查节点/订阅）"
exit 1
