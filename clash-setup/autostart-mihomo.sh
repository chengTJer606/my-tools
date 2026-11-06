#!/usr/bin/env bash
# 开机自启 mihomo + 节点通才设系统代理（避免节点不通时桌面走代理崩溃）
BIN="$HOME/.local/bin/mihomo"; DIR="$HOME/.config/mihomo"; LOG="$HOME/clash-setup/mihomo.log"; PIDF="$HOME/clash-setup/mihomo.pid"
STOPMARK="$DIR/.user-stopped"
[ -x "$BIN" ] || exit 1

# 全局操作锁：与手动启动/停止/看门狗串行，杜绝并发互杀
exec 9>/tmp/mihomo-control.lock
flock -w 60 9 || exit 1

# 开机=新会话，清除上轮「主动停止」标记，恢复自动运行
rm -f "$STOPMARK"

# 已运行则跳过（以进程身份判定：9090 端口可能被其他程序占用）
pgrep -x mihomo >/dev/null 2>&1 && exit 0

# 等待网络就绪（默认路由存在且能 ping 通公网 DNS，最多 60 秒）
# 关键修复：开机时网络就绪晚于自启，直接检测节点必然失败 → 代理漏设
for i in $(seq 1 30); do
  ip route 2>/dev/null | grep -q '^default' && ping -c1 -W2 223.5.5.5 >/dev/null 2>&1 && break
  sleep 2
done

# 停旧 + 启动（9>&- 关闭锁描述符，防止 mihomo 继承后永久持有操作锁）
pkill -x mihomo 2>/dev/null || true; sleep 1
nohup "$BIN" -d "$DIR" > "$LOG" 2>&1 9>&- &
echo $! > "$PIDF"

# 等待进程存活且 9090 监听（最多15秒，双重确认防端口被占误判）
for i in $(seq 1 15); do pgrep -x mihomo >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":9090" && break; sleep 1; done
pgrep -x mihomo >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":9090" || exit 1

# 节点通才设系统代理（不通则保持none，浏览器直连，不崩）
# 检测目标用 generate_204（轻量，mihomo 健康检查同款），比整页 google.com 快且稳
ok=0
for i in $(seq 1 4); do
  c=$(curl -s --max-time 6 --proxy http://127.0.0.1:7890 -o /dev/null -w "%{http_code}" http://www.gstatic.com/generate_204 2>/dev/null)
  [ "$c" = "204" ] && { ok=1; break; }
  sleep 2
done

if [ "$ok" = "1" ]; then
  gsettings set org.gnome.system.proxy mode 'manual'
  gsettings set org.gnome.system.proxy.http host '127.0.0.1'
  gsettings set org.gnome.system.proxy.http port 7890
  gsettings set org.gnome.system.proxy.https host '127.0.0.1'
  gsettings set org.gnome.system.proxy.https port 7890
  gsettings set org.gnome.system.proxy.socks host '127.0.0.1'
  gsettings set org.gnome.system.proxy.socks port 7890
  gsettings set org.gnome.system.proxy ignore-hosts "['localhost','127.0.0.0/8','::1','10.0.0.0/8','192.168.0.0/16']"
else
  # 首轮不通 → 后台持续补设（约10分钟），节点一旦连通自动设上系统代理
  nohup bash "$HOME/clash-setup/ensure-proxy.sh" >> "$LOG" 2>&1 9>&- &
fi
