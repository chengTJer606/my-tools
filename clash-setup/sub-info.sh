#!/usr/bin/env bash
# 查看订阅用量与套餐余额（图形弹窗，不跳终端）
# 订阅链接从 subs.list 读取（该文件含 token，已被 git 忽略，勿硬编码到本脚本）
SUB_LIST="$HOME/clash-setup/subs.list"
SUB_URL=$(head -1 "$SUB_LIST" 2>/dev/null | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
if [ -z "$SUB_URL" ]; then
  msg="未找到订阅链接：$SUB_LIST 不存在或为空（格式：名称 | 链接）"
  if [ -n "$DISPLAY" ] && command -v zenity >/dev/null 2>&1; then
    zenity --info --title="mihomo 订阅用量" --text="$msg" --width=360 2>/dev/null
  else
    echo "$msg"
  fi
  exit 1
fi
hdr=$(curl -k -sS --max-time 30 -A "clash.meta/v1.19.30" -D - -o /dev/null "$SUB_URL" 2>/dev/null | grep -i 'subscription-userinfo' | tr -d '\r')
if [ -z "$hdr" ]; then
  msg="未获取到用量信息（请检查网络或订阅是否过期）"
else
  msg=$(python3 - "$hdr" <<'PY'
import sys,re,datetime
hdr=sys.argv[1]
d=dict(re.findall(r'(\w+)=(\d*)',hdr))
up=int(d.get('upload',0));dl=int(d.get('download',0));total=int(d.get('total',0));exp=d.get('expire','')
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
)
fi
if [ -n "$DISPLAY" ] && command -v zenity >/dev/null 2>&1; then
  zenity --info --title="mihomo 订阅用量" --text="$msg" --width=320 2>/dev/null
else
  echo "$msg"
fi
