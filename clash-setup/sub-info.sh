#!/usr/bin/env bash
# 查看订阅用量与套餐余额（支持多订阅，图形弹窗，不跳终端）
# 订阅链接从 subs.list 读取（该文件含 token，已被 git 忽略，勿硬编码到本脚本）
SUB_LIST="$HOME/clash-setup/subs.list"

PY=python3
$PY -c "import yaml" 2>/dev/null || PY=/usr/bin/python3

show() { # $1=消息
  if [ -n "$DISPLAY" ] && command -v zenity >/dev/null 2>&1; then
    zenity --info --title="mihomo 订阅用量" --text="$1" --width=380 2>/dev/null
  else
    echo "$1"
  fi
}

if [ ! -s "$SUB_LIST" ]; then
  show "未找到订阅链接：$SUB_LIST 不存在或为空（格式：名称 | 链接）"
  exit 1
fi

msg=""
idx=0
while IFS='|' read -r name url; do
  name=$(echo "$name" | xargs); url=$(echo "$url" | xargs)
  [ -z "$url" ] && continue
  idx=$((idx+1))
  [ -z "$name" ] && name="订阅$idx"
  hdr=$(curl -sS --max-time 30 -A "clash.meta/v1.19.30" -D - -o /dev/null "$url" 2>/dev/null | grep -i 'subscription-userinfo' | tr -d '\r')
  if [ -z "$hdr" ]; then
    msg+="【$name】未获取到用量信息（检查网络或订阅是否过期）\n\n"
  else
    msg+="【$name】\n$(HDR="$hdr" "$PY" - <<'PY'
import os,re,datetime
hdr=os.environ['HDR']
d=dict(re.findall(r'(\w+)=(\d*)',hdr))
up=int(d.get('upload') or 0);dl=int(d.get('download') or 0);total=int(d.get('total') or 0);exp=d.get('expire','')
used=up+dl
def h(b):
    if b>=1073741824:return f'{b/1073741824:.2f} GB'
    if b>=1048576:return f'{b/1048576:.2f} MB'
    return f'{b} B'
lines=[f'已用: {h(used)}', f'剩余: {h(total-used)}', f'总量: {h(total)}']
if total: lines.append(f'使用率: {used/total*100:.1f}%')
lines.append(f'到期: {datetime.datetime.fromtimestamp(int(exp)).strftime("%Y-%m-%d")}' if exp else '到期: 长期有效')
print('\n'.join(lines))
PY
)\n\n"
  fi
done < "$SUB_LIST"

show "$(printf "%b" "$msg" | sed -e '$ d')"
