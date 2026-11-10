#!/usr/bin/env bash
# mihomo-panel.sh —— mihomo 集成控制面板
# 设计原则（重要）：
#   1) 本面板只是「调度器」：所有功能都通过 bash 调用 clash-setup 里现有脚本，
#      不复制任何逻辑、不修改任何现有脚本。本面板出任何问题，删除本文件
#      和桌面快捷方式即可，其他快捷方式/看门狗/自启完全不受影响。
#   2) 有 whiptail 用图形菜单，没有则降级为纯文本菜单（保证任何环境可用）。
#   3) 所有操作执行后在终端回显完整输出，按回车回菜单，方便截图排查。
set -u
DIR="$HOME/clash-setup"
LOG="$DIR/mihomo.log"
TITLE="mihomo 控制面板"

pause() { echo; read -rp "── 按回车返回菜单 ──" _; }

# ---------- 状态总览（全部只读探测，不改任何状态） ----------
status_text() {
  local out=""
  if pgrep -x mihomo >/dev/null 2>&1; then
    local pid; pid=$(pgrep -x mihomo | head -1)
    out+="mihomo 进程   : ✅ 运行中 (PID $pid, $(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//'))"
  else
    out+="mihomo 进程   : ❌ 未运行"
  fi
  out+=$'\n'"系统代理      : $(gsettings get org.gnome.system.proxy mode 2>/dev/null)  http=$(gsettings get org.gnome.system.proxy.http host 2>/dev/null | tr -d "'"):$(gsettings get org.gnome.system.proxy.http port 2>/dev/null)"
  if [ "$(gsettings get org.gnome.system.proxy mode 2>/dev/null)" = "'none'" ]; then
    out+=$'\n'"代理通道      : ⏭ 未启用（当前为直连模式）"
  else
    local c; c=$(curl -s --noproxy '' --max-time 6 -x http://127.0.0.1:7890 -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 2>/dev/null)
    [ "$c" = "204" ] && out+=$'\n'"代理通道      : ✅ 通 (google generate_204 = 204)" \
                    || out+=$'\n'"代理通道      : ❌ 不通 (code=$c)——节点或线路问题"
  fi
  local d; d=$(curl -s --max-time 6 -o /dev/null -w '%{http_code}' https://www.baidu.com 2>/dev/null)
  [ "$d" = "200" ] && out+=$'\n'"直连通道      : ✅ 通 (百度 200)" \
                  || out+=$'\n'"直连通道      : ❌ 不通 (code=$d)——系统 DNS 或网络问题"
  local dns; dns=$(resolvectl status wlan0 2>/dev/null | grep -m1 "Current DNS" | awk '{print $NF}')
  out+=$'\n'"系统 DNS      : ${dns:-未知}（主 223.5.5.5 / 备 119.29.29.29 / Fallback）"
  if pgrep -x mihomo >/dev/null 2>&1; then
    local node; node=$(curl -s --max-time 4 http://127.0.0.1:9090/proxies/自动选择 2>/dev/null | /usr/bin/python3 -c "import json,sys
try: print(json.load(sys.stdin)['now'])
except Exception: print('读取失败')" 2>/dev/null)
    out+=$'\n'"当前节点      : ${node:-未知}（自动选择组）"
    local zl; zl=$(curl -s --max-time 6 -o /dev/null -w '%{http_code}' https://moma.cmecloud.cn/v1 2>/dev/null)
    out+=$'\n'"湛卢 API 直连 : $([ "$zl" = "404" ] && echo '✅ 通' || echo "code=$zl（404=正常路由响应）")"
  fi
  out+=$'\n'"看门狗        : $(systemctl --user is-active mihomo-watchdog.timer 2>/dev/null)（每30秒自愈巡检）"
  [ -f "$HOME/.config/mihomo/.user-stopped" ] && out+=$'\n'"停止标记      : 存在（你主动停止过，看门狗不会拉起）"
  out+=$'\n'$'\n'"最近看门狗记录："
  out+=$(grep "watchdog" "$LOG" 2>/dev/null | tail -3 | sed 's/^/  /')
  [ -z "$(grep watchdog "$LOG" 2>/dev/null | tail -1)" ] && out+=$'\n'"  （无记录）"
  printf '%s' "$out"
}

# ---------- 各功能：只调用现有脚本 ----------
do_status()   { clear; echo "═══════════ 状态总览 ═══════════"; status_text; echo; pause; }
do_start()    { clear; echo "═══════════ 启动 mihomo ═══════════"; bash "$DIR/start-mihomo.sh"; pause; }
do_stop()     { clear; echo "═══════════ 停止 mihomo（恢复直连） ═══════════"; bash "$DIR/stop-mihomo.sh"; pause; }
do_restart()  { clear; echo "═══════════ 重启 mihomo ═══════════"; printf 'y\n' | bash "$DIR/start-mihomo.sh"; pause; }
do_update()   { clear; echo "═══════════ 更新订阅 ═══════════"; bash "$DIR/update-sub.sh"; pause; }
do_usage()    { clear; echo "═══════════ 订阅用量 ═══════════"; bash "$DIR/sub-info.sh"; pause; }
do_web()      { bash "$DIR/open-panel.sh" >/dev/null 2>&1 & }
do_logs()     { clear; echo "═══════════ 最近 100 行日志（$LOG） ═══════════"; tail -100 "$LOG" 2>/dev/null | cut -c1-160; pause; }
do_follow()   { clear; echo "═══════════ 实时日志（Ctrl-C 退出跟踪） ═══════════"; tail -f "$LOG" 2>/dev/null | cut -c1-160; clear; }
do_netlog()   { clear; echo "═══════════ 网络事件日志（自动DNS适配记录，最近50条） ═══════════"
  tail -50 "$DIR/network-events.log" 2>/dev/null || echo "（暂无记录——任何WiFi/网线上线时会自动写这里）"
  echo; echo "说明：任何 WiFi/有线网络连上时，系统会自动把该网络 DNS 固定为"
  echo "      223.5.5.5/119.29.29.29 并记录在此，无需手动处理。"
  pause; }
do_zhanlu()   { clear; echo "═══════════ 湛卢连通性 ═══════════"
  pgrep -f "zl serve" >/dev/null && echo "zl-serve 进程: ✅ 运行中" || echo "zl-serve 进程: ❌ 未运行（湛卢没开？）"
  for u in https://moma.cmecloud.cn/v1 https://ecloud.10086.cn; do
    c=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)
    echo "  $u → $c（404/302=网络层通）"
  done
  echo "提示：湛卢走的是直连，不吃代理；它报错多半是系统 DNS 问题，"
  echo "      而系统 DNS 已固定为 223.5.5.5/119.29.29.29 + FallbackDNS 兜底。"
  pause; }

# ---------- 菜单 ----------
menu_whiptail() {
  while true; do
    choice=$(whiptail --title "$TITLE" --backtitle "clash-setup 集成控制台（独立于其他快捷方式）" \
      --menu "方向键选择，回车执行。所有操作与桌面其他快捷方式等价且互不影响。" 22 64 10 \
      "1" "状态总览（一键体检：进程/代理/直连/DNS/节点）" \
      "2" "启动 mihomo（已在运行会询问）" \
      "3" "重启 mihomo" \
      "4" "停止 mihomo（立刻恢复直连）" \
      "5" "更新订阅" \
      "6" "查看订阅用量" \
      "7" "打开 Web 控制面板" \
      "8" "查看最近日志（100行）" \
      "9" "实时跟踪日志（Ctrl-C 退出）" \
      "10" "湛卢连通性检查" \
      "11" "网络事件日志（自动DNS适配记录）" \
      "0" "退出" \
      3>&1 1>&2 2>&3) || break
    [ -z "${choice:-}" ] && break
    case "$choice" in
      1) do_status;; 2) do_start;; 3) do_restart;; 4) do_stop;; 5) do_update;;
      6) do_usage;; 7) do_web;; 8) do_logs;; 9) do_follow;; 10) do_zhanlu;; 11) do_netlog;; 0|"") break;;
      *) : ;;
    esac
  done
}

menu_text() {
  while true; do
    clear
    echo "═════════ $TITLE ═════════"
    echo " 1) 状态总览   2) 启动   3) 重启   4) 停止(恢复直连)"
    echo " 5) 更新订阅   6) 查看用量          7) 打开Web面板"
    echo " 8) 最近日志   9) 实时日志(Ctrl-C退) 10) 湛卢连通性"
    echo " 11) 网络事件日志(自动DNS适配)"
    echo " 0) 退出"
    read -rp "选择: " choice
    case "$choice" in
      1) do_status;; 2) do_start;; 3) do_restart;; 4) do_stop;; 5) do_update;;
      6) do_usage;; 7) do_web;; 8) do_logs;; 9) do_follow;; 10) do_zhanlu;; 11) do_netlog;; 0|"") break;;
      *) echo "无效选项"; sleep 1;;
    esac
  done
}

# MIHOMO_PANEL_LIB=1 时只加载函数不进菜单（测试/复用入口）
# MIHOMO_PANEL_TEXT=1 时强制纯文本菜单（终端环境异常时的兜底）
if [ "${MIHOMO_PANEL_LIB:-0}" != "1" ]; then
  if command -v whiptail >/dev/null 2>&1 && [ "${MIHOMO_PANEL_TEXT:-0}" != "1" ]; then
    menu_whiptail
  else
    menu_text
  fi
  clear
  echo "已退出控制面板。"
fi
