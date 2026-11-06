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
  gsettings set org.gnome.system.proxy ignore-hosts "['localhost','127.0.0.0/8','::1','10.0.0.0/8','192.168.0.0/16']"
}

node_ok() {
  # generate_204 轻量探测（返回204即通），比重试整页 google.com 更快更稳
  [ "$(curl -s --max-time 6 --proxy http://127.0.0.1:7890 -o /dev/null -w '%{http_code}' http://www.gstatic.com/generate_204 2>/dev/null)" = "204" ]
}

# 已在运行则跳过（避免 start/autostart 并发时重复补设）
LOCK=/tmp/ensure-proxy.lock
exec 9>"$LOCK" && flock -n 9 || exit 0

for i in $(seq 1 44); do
  # mihomo 代理端口不在了 → 无需补设，退出
  ss -tln 2>/dev/null | grep -q ':7890 ' || { echo "mihomo 未运行，退出"; exit 0; }
  if node_ok; then
    set_proxy_manual
    echo "✅ 节点连通，系统代理已设为 127.0.0.1:7890"
    exit 0
  fi
  # 前4次快速重试，之后转入15秒一次的低频补设
  if [ "$i" -le 4 ]; then sleep 3; else sleep 15; fi
done

echo "⚠️ 约10分钟内节点未连通，系统代理保持原样（请检查节点/订阅）"
exit 1
