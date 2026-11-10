#!/usr/bin/env bash
# mihomo-panel.sh —— mihomo 集成控制面板
# 设计原则：
#   1) 本面板是「调度器」：所有功能都通过 bash 调用 clash-setup 里现有脚本，
#      不复制任何逻辑、不修改任何现有脚本。
#   2) 有 whiptail 用图形菜单，没有则降级为纯文本菜单（保证任何环境可用）。
#   3) 所有操作执行后在终端回显完整输出，按回车回菜单，方便截图排查。
#   4) 每次操作自动写入历史日志 panel-history.log（含执行结果状态快照），
#      排查问题时可供 AI / 人工回溯每一次操作。
set -u
DIR="$HOME/clash-setup"
LOG="$DIR/mihomo.log"
HLOG="$DIR/panel-history.log"
TITLE="mihomo 控制面板"

pause() { echo; read -rp "── 按回车返回菜单 ──" _; }

# ---------- 操作历史日志 ----------
# 用法: log_h "操作名" "结果摘要"（结果可省略）
log_h() { echo "$(date '+%F %T') | $1${2:+ | $2}" >> "$HLOG"; }
# 执行后状态快照：进程 + 系统代理模式
snapshot() {
  echo "mihomo=$(pgrep -x mihomo >/dev/null 2>&1 && echo 运行 || echo 未运行) 系统代理=$(gsettings get org.gnome.system.proxy mode 2>/dev/null)"
}

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
    local node; node=$(curl -s --max-time 4 -H "Authorization: Bearer $(cat "$DIR/api.secret" 2>/dev/null)" http://127.0.0.1:9090/proxies/自动选择 2>/dev/null | /usr/bin/python3 -c "import json,sys
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
do_status()   { clear; echo "═══════════ 状态总览 ═══════════"; status_text; log_h "查看状态总览" "$(snapshot)"; echo; pause; }
do_start()    { clear; echo "═══════════ 启动 mihomo ═══════════"; log_h "执行启动 start-mihomo.sh"; bash "$DIR/start-mihomo.sh"; log_h "启动结束" "$(snapshot)"; pause; }
do_stop()     { clear; echo "═══════════ 停止 mihomo（恢复直连） ═══════════"; log_h "执行停止 stop-mihomo.sh"; bash "$DIR/stop-mihomo.sh"; log_h "停止结束" "$(snapshot)"; pause; }
do_restart()  { clear; echo "═══════════ 重启 mihomo ═══════════"; log_h "执行重启（自动确认）"; printf 'y\n' | bash "$DIR/start-mihomo.sh"; log_h "重启结束" "$(snapshot)"; pause; }
do_update()   { clear; echo "═══════════ 更新订阅 ═══════════"; log_h "执行更新订阅 update-sub.sh"; bash "$DIR/update-sub.sh"; log_h "更新订阅结束" "$(snapshot)"; pause; }
do_usage()    { clear; echo "═══════════ 订阅用量 ═══════════"; log_h "查看订阅用量"; bash "$DIR/sub-info.sh"; pause; }
do_web()      { log_h "打开 Web 控制面板"; bash "$DIR/open-panel.sh" >/dev/null 2>&1; log_h "Web面板启动" "$(snapshot)"; }
do_logs()     { clear; echo "═══════════ 最近 100 行日志（$LOG） ═══════════"; tail -100 "$LOG" 2>/dev/null | cut -c1-160; log_h "查看最近日志"; pause; }
do_follow()   { clear; echo "═══════════ 实时日志（Ctrl-C 退出跟踪） ═══════════"; log_h "实时跟踪日志（Ctrl-C 退出）" "$(snapshot)"; tail -f "$LOG" 2>/dev/null | cut -c1-160; clear; }
do_netlog()   { clear; echo "═══════════ 网络事件日志（自动DNS适配记录，最近50条） ═══════════"
  log_h "查看网络事件日志"
  tail -50 "$DIR/network-events.log" 2>/dev/null || echo "（暂无记录——任何WiFi/网线上线时会自动写这里）"
  echo; echo "说明：任何 WiFi/有线网络连上时，系统会自动把该网络 DNS 固定为"
  echo "      223.5.5.5/119.29.29.29 并记录在此，无需手动处理。"
  pause; }
do_zhanlu()   { clear; echo "═══════════ 湛卢连通性 ═══════════"
  log_h "检查湛卢连通性"
  pgrep -f "zl serve" >/dev/null && echo "zl-serve 进程: ✅ 运行中" || echo "zl-serve 进程: ❌ 未运行（湛卢没开？）"
  for u in https://moma.cmecloud.cn/v1 https://ecloud.10086.cn; do
    c=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)
    echo "  $u → $c（404/302=网络层通）"
    log_h "湛卢探测 $u → $c"
  done
  echo "提示：湛卢走的是直连，不吃代理；它报错多半是系统 DNS 问题，"
  echo "      而系统 DNS 已固定为 223.5.5.5/119.29.29.29 + FallbackDNS 兜底。"
  pause; }

# ---------- 360 浏览器连通性（走与浏览器一致的通道） ----------
do_browser() {
  clear; echo "═══════════ 360 浏览器连通性测试 ═══════════"
  log_h "检查360浏览器连通性"
  pgrep -f "browser360" >/dev/null 2>&1 && echo "360浏览器进程: ✅ 运行中" || echo "360浏览器进程: ❌ 未检测到（不影响通道测试）"
  local mode; mode=$(gsettings get org.gnome.system.proxy mode 2>/dev/null)
  echo "系统代理模式  : $mode"
  if [ "$mode" = "'manual'" ]; then
    echo "360 当前走    : mihomo 代理 (127.0.0.1:7890)"
    echo
    echo "── 经代理通道测试经典网页（与360实际访问路径一致） ──"
    local fail=0
    for u in "https://www.google.com/generate_204" "https://github.com" "https://www.youtube.com" "https://x.com"; do
      local r; r=$(curl -s --max-time 10 -x http://127.0.0.1:7890 -o /dev/null -w '%{http_code} %{size_download}B %{time_total}s' "$u" 2>/dev/null)
      local code=${r%% *}
      if [ "$code" = "204" ] || [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
        echo "  ✅ $u → $r"
      else
        echo "  ❌ $u → $r"
        fail=1
      fi
      log_h "网页测试 $u → $r"
    done
    local ip; ip=$(curl -s --max-time 8 -x http://127.0.0.1:7890 https://api.ipify.org 2>/dev/null)
    echo "  代理出口 IP : ${ip:-获取失败}"
    log_h "代理出口IP ${ip:-获取失败}"
    [ "$fail" = "0" ] && echo "── 结论：360 浏览器可正常打开国外网页 ──" || echo "── 结论：部分网页异常，请看日志或重启/更新订阅 ──"
  else
    echo "360 当前走    : 直连（mihomo 未接管）"
    echo
    echo "── 直连通道测试（当前能打开的网页） ──"
    for u in "https://www.baidu.com" "https://moma.cmecloud.cn/v1"; do
      local r; r=$(curl -s --max-time 8 -o /dev/null -w '%{http_code} %{size_download}B %{time_total}s' "$u" 2>/dev/null)
      echo "  $u → $r"
      log_h "直连网页测试 $u → $r"
    done
    echo "提示：需要代理请先用「启动 mihomo」；github 等国外网页直连打不开属正常。"
  fi
  pause
}
do_hist()     { clear; echo "═══════════ 操作历史记录（最近50条，完整记录在 $HLOG） ═══════════"
  tail -50 "$HLOG" 2>/dev/null || echo "（暂无记录）"
  echo; echo "说明：本面板每次操作（含结果状态）都会追加到此日志，"
  echo "      排查历史问题可直接让 AI 读取 $HLOG。"
  pause; }

# ---------- 菜单 ----------
menu_whiptail() {
  while true; do
    choice=$(whiptail --title "$TITLE" --backtitle "clash-setup 集成控制台" \
      --menu "【常用】1-4   【订阅】5-7   【诊断】8-9   【日志】10-13" 22 64 13 \
      "1" "状态总览（一键体检：进程/代理/直连/DNS/节点）" \
      "2" "启动 mihomo（已在运行会询问）" \
      "3" "重启 mihomo" \
      "4" "停止 mihomo（立刻恢复直连）" \
      "5" "更新订阅" \
      "6" "查看订阅用量" \
      "7" "打开 Web 控制面板" \
      "8" "360浏览器连通性（含经典网页测试）" \
      "9" "湛卢连通性检查" \
      "10" "查看最近日志（100行）" \
      "11" "实时跟踪日志（Ctrl-C 退出）" \
      "12" "网络事件日志（自动DNS适配记录）" \
      "13" "操作历史记录（本面板执行过的所有操作）" \
      "0" "退出" \
      3>&1 1>&2 2>&3) || break
    [ -z "${choice:-}" ] && break
    case "$choice" in
      1) do_status;; 2) do_start;; 3) do_restart;; 4) do_stop;; 5) do_update;;
      6) do_usage;; 7) do_web;; 8) do_browser;; 9) do_zhanlu;;
      10) do_logs;; 11) do_follow;; 12) do_netlog;; 13) do_hist;; 0|"") break;;
      *) : ;;
    esac
  done
}

menu_text() {
  while true; do
    clear
    echo "═════════ $TITLE ═════════"
    echo "── 常用 ──"
    echo " 1) 状态总览       2) 启动       3) 重启       4) 停止(恢复直连)"
    echo "── 订阅 ──"
    echo " 5) 更新订阅       6) 查看用量   7) 打开Web面板"
    echo "── 诊断 ──"
    echo " 8) 360浏览器连通性   9) 湛卢连通性"
    echo "── 日志 ──"
    echo " 10) 最近日志   11) 实时日志(Ctrl-C退)   12) 网络事件   13) 操作历史"
    echo " 0) 退出"
    read -rp "选择: " choice
    case "$choice" in
      1) do_status;; 2) do_start;; 3) do_restart;; 4) do_stop;; 5) do_update;;
      6) do_usage;; 7) do_web;; 8) do_browser;; 9) do_zhanlu;;
      10) do_logs;; 11) do_follow;; 12) do_netlog;; 13) do_hist;; 0|"") break;;
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
