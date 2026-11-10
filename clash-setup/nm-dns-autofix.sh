#!/bin/bash
# 90-mihomo-dns-autofix —— NetworkManager dispatcher 钩子
# 作用：任何 WiFi/有线网络上线时，自动把该连接的 DNS 固定为公共 DNS，
#       不再依赖路由器/热点的 DNS 转发（历史故障根源）。
# 安装位置：/etc/NetworkManager/dispatcher.d/90-mihomo-dns-autofix (root:root 755)
# 源文件：~/clash-setup/nm-dns-autofix.sh（git 跟踪，重装时复制过去即可）
#
# 日志：/home/huawei/clash-setup/network-events.log（面板菜单可查看）
# 注意：VPN/网桥/容器接口不处理；企业内网若需解析内网域名，手动把该连接
#       ipv4.ignore-auto-dns 改回 no 即可（本脚本只处理"从未固定过"的连接，
#       用户手动改过的会被再次自动固定——如需排除某连接，在下面 EXCLUDE 里加名字）。

LOG=/home/huawei/clash-setup/network-events.log
EXCLUDE=""   # 例："公司内网VPN|访客网络"

IFACE="$1"; ACTION="$2"
[ -z "$IFACE" ] && exit 0

log() { echo "$(date '+%F %T') [$IFACE/$ACTION] $*" >> "$LOG"; }

case "$ACTION" in
  up|dhcp4-change|reapply) ;;
  *) exit 0 ;;
esac

# 找到该接口的活动连接（nmcli -t 输出为 名称:设备:类型，设备在第二段）
CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v dev="$IFACE" '$2==dev{print $1; exit}')
[ -z "$CON" ] && exit 0

# 只处理 WiFi / 以太网，跳过 VPN、网桥、虚拟接口
TYPE=$(nmcli -g connection.type con show "$CON" 2>/dev/null)
case "$TYPE" in
  802-11-wireless|ethernet) ;;
  *) exit 0 ;;
esac

# 排除名单
if [ -n "$EXCLUDE" ] && echo "$CON" | grep -qE "$EXCLUDE"; then
  log "跳过（排除名单）: $CON"
  exit 0
fi

# 已固定过就只记一行状态，不动配置
CUR=$(nmcli -g ipv4.ignore-auto-dns con show "$CON" 2>/dev/null)
DNSNOW=$(nmcli -g ipv4.dns con show "$CON" 2>/dev/null)
if [ "$CUR" = "yes" ] && echo "$DNSNOW" | grep -q "223.5.5.5"; then
  log "OK（已固定）: $CON DNS=$DNSNOW"
  exit 0
fi

# 固定公共 DNS 并立即生效
if nmcli con mod "$CON" ipv4.ignore-auto-dns yes ipv4.dns "223.5.5.5 119.29.29.29" 2>>"$LOG"; then
  nmcli device reapply "$IFACE" >/dev/null 2>&1
  log "已自动固定DNS: $CON ($TYPE) → 223.5.5.5, 119.29.29.29 并已生效"
else
  log "⚠️ 固定DNS失败: $CON（详见上行错误）"
fi
exit 0
