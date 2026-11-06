#!/usr/bin/env bash
# 启动 mihomo（flock 防并发互杀、zenity 失败回退终端确认、节点检测+后台补设、清除主动停止标记）
BIN="$HOME/.local/bin/mihomo"
DIR="$HOME/.config/mihomo"
LOG="$HOME/clash-setup/mihomo.log"
PIDF="$HOME/clash-setup/mihomo.pid"
STOPMARK="$DIR/.user-stopped"

if [ ! -x "$BIN" ]; then echo "❌ 未找到 mihomo: $BIN"; read -rp "按回车关闭"; exit 1; fi
for cmd in curl ss gsettings pgrep; do command -v "$cmd" >/dev/null 2>&1 || { echo "❌ 缺少依赖命令: $cmd"; read -rp "按回车关闭"; exit 1; }; done

# 全局操作锁：与开机自启/看门狗/重复双击串行，杜绝并发互杀（19:58 双实例事故的根因之一）
exec 9>/tmp/mihomo-control.lock
flock -w 30 9 || { echo "⚠️ 另一个启停操作正在进行，请稍候重试"; read -rp "按回车关闭"; exit 1; }

# 用户主动启动 → 清除「主动停止」标记，看门狗恢复工作
rm -f "$STOPMARK"

# 检测是否已运行（以进程身份判定：9090 端口可能被其他程序占用，不能作为存活依据）
if pgrep -x mihomo >/dev/null 2>&1; then
  echo "⚠️ mihomo 已在运行（进程存活）"
  r=""
  if [ -n "$DISPLAY" ] && command -v zenity >/dev/null 2>&1; then
    zerr=$(zenity --question --title="mihomo 已运行" --text="mihomo 已在运行。是否重启？" --ok-label="重启" --cancel-label="取消" 2>&1) && r="y"
    # zenity 弹窗本身失败（有错误输出）→ 回退终端确认，绝不静默当取消
    if [ -z "$r" ] && [ -n "$zerr" ]; then
      echo "（弹窗不可用，改用终端确认）"
      read -rp "是否重启？[y/N]: " r
    fi
  else
    read -rp "是否重启？[y/N]: " r
  fi
  if [ "$r" != "y" ] && [ "$r" != "Y" ]; then
    echo "已取消（mihomo 继续运行）"
    # 即使不重启，也顺手修复「内核在跑但系统代理没设上」的异常状态
    # 快速预检一次（避免前台长跑 ensure-proxy 持锁阻塞 stop/watchdog 长达10分钟）
    if [ "$(gsettings get org.gnome.system.proxy mode 2>/dev/null)" != "'manual'" ]; then
      echo "检测到系统代理未设置，正在尝试补设..."
      c=$(curl -s --max-time 6 --proxy http://127.0.0.1:7890 -o /dev/null -w "%{http_code}" http://www.gstatic.com/generate_204 2>/dev/null)
      if [ "$c" = "204" ]; then
        bash "$HOME/clash-setup/ensure-proxy.sh" 9>&-
        echo "✅ 已补设系统代理 127.0.0.1:7890"
      else
        echo "⚠️ 节点暂不通，已转入后台持续补设（看门狗每分钟也会兜底）"
        nohup bash "$HOME/clash-setup/ensure-proxy.sh" >> "$LOG" 2>&1 9>&- &
      fi
    else
      echo "系统代理正常（manual 127.0.0.1:7890）"
    fi
    exit 0
  fi
fi

# 停旧进程（PID文件需校验进程身份[防PID复用误杀] + pkill 兜底）
if [ -f "$PIDF" ]; then
  pid=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$pid" ] && [ "$(cat /proc/$pid/comm 2>/dev/null)" = "mihomo" ]; then
    kill "$pid" 2>/dev/null || true; sleep 1
  fi
  rm -f "$PIDF"
fi
pkill -x mihomo 2>/dev/null || true
sleep 1

# 端口占用容错（旧进程没退干净则强杀）
for p in 7890 9090; do
  if ss -tln 2>/dev/null | grep -q ":$p "; then
    echo "端口 $p 仍被占用，强杀旧进程..."; pkill -9 -x mihomo 2>/dev/null || true; sleep 2
  fi
done

# 启动（9>&- 关闭锁描述符防锁继承；>> O_APPEND 追加，配合看门狗 copytruncate 截断无稀疏空洞）
nohup "$BIN" -d "$DIR" >> "$LOG" 2>&1 9>&- &
echo $! > "$PIDF"
sleep 2

# 启动验证（进程身份+端口双重确认，防 9090 被其他程序占用时误判成功）
if pgrep -x mihomo >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":9090"; then
  echo "✅ mihomo 已启动，PID: $(cat "$PIDF")"
  echo "检测节点连通性（决定是否设系统代理）..."
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
    echo "✅ 系统代理已设为 127.0.0.1:7890（节点通，浏览器/微信/QQ 自动走代理）"
  else
    echo "⚠️ 节点暂不通，已转入后台持续检测（约10分钟），连通后自动补设系统代理"
    echo "   另有看门狗每分钟自动巡检兜底，无需反复点启动"
    nohup bash "$HOME/clash-setup/ensure-proxy.sh" >> "$LOG" 2>&1 9>&- &
  fi
  echo "面板: http://127.0.0.1:9090/ui（双击「mihomo-打开面板」）"
  echo "停止: 双击「mihomo-停止」（自动恢复直连）"
else
  echo "❌ mihomo 启动失败，最近日志："
  tail -5 "$LOG" 2>/dev/null
  echo "端口占用情况（若非 mihomo 占用需手动处理）："
  ss -tlnp 2>/dev/null | grep -E ':7890 |:9090 ' || echo "  （7890/9090 空闲）"
fi
