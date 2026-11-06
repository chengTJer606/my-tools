#!/usr/bin/env bash
# 更新订阅：选订阅(可改名/加新) → 拉取 → 精简(节点域名强制system DNS) → API热重载
set -e
LIST="$HOME/clash-setup/subs.list"
SUB_URL=""; SUB_NAME=""

# 改subs.list中某URL对应的名称
rename_in_list() {
  python3 - "$LIST" "$SUB_URL" "$1" <<'PY'
import sys
lst,url,new=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(lst).read().splitlines()
out=[]
for l in lines:
    if '|' in l and url in l:
        u=l.split('|',1)[1]; out.append(new+' |'+u)
    else: out.append(l)
open(lst,'w').write('\n'.join(out)+'\n')
PY
}

# 1. 选订阅 + 改名
if [ -n "$1" ]; then
  SUB_URL="$1"; SUB_NAME="命令行"
elif [ -f "$LIST" ] && [ -s "$LIST" ]; then
  if [ -n "$DISPLAY" ] && command -v zenity >/dev/null 2>&1; then
    names=$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if($1!="") print $1}' "$LIST")
    choice=$( (echo "$names"; echo "➕ 手动输入新链接") | zenity --list --title="选择订阅" --text="选择要更新的订阅" --column="订阅名称" --height=320 2>/dev/null) || true
    [ -z "$choice" ] && { echo "已取消"; exit 0; }
    if [[ "$choice" == *"手动输入"* ]]; then
      SUB_URL=$(zenity --entry --title="输入订阅链接" --text="粘贴订阅链接（含token）：" --width=520 2>/dev/null) || true
      SUB_NAME=$(zenity --entry --title="订阅名称" --text="给这个订阅起个名字：" --width=360 --entry-text="新订阅" 2>/dev/null) || true
      [ -z "$SUB_NAME" ] && SUB_NAME="未命名"
      grep -qF "$SUB_URL" "$LIST" 2>/dev/null || echo "$SUB_NAME | $SUB_URL" >> "$LIST"
    else
      SUB_URL=$(awk -F'|' -v n="$choice" '{a=$1;b=$2;gsub(/^[ \t]+|[ \t]+$/,"",a);gsub(/^[ \t]+|[ \t]+$/,"",b);if(a==n){print b;exit}}' "$LIST")
      SUB_NAME="$choice"
    fi
    # 改名（预填当前名，留空=不改）
    newname=$(zenity --entry --title="订阅名称（可修改）" --text="可修改此订阅名称，留空保持不变：" --width=360 --entry-text="$SUB_NAME" 2>/dev/null) || true
    if [ -n "$newname" ] && [ "$newname" != "$SUB_NAME" ]; then
      rename_in_list "$newname"; SUB_NAME="$newname"
      echo "  订阅名称已改为: $SUB_NAME"
    fi
  else
    echo "可用订阅："; i=1
    while IFS='|' read -r n u; do
      n=$(echo "$n"|xargs); u=$(echo "$u"|xargs)
      [ -z "$n" ] && continue
      echo "  $i) $n"; urls[i]="$u"; names[i]="$n"; i=$((i+1))
    done < "$LIST"
    echo "  0) 手动输入新链接"
    read -rp "选择 [1-$((i-1))/0]: " sel
    if [ "$sel" = "0" ]; then
      read -rp "粘贴订阅链接: " SUB_URL; read -rp "订阅名称: " SUB_NAME
      grep -qF "$SUB_URL" "$LIST" 2>/dev/null || echo "$SUB_NAME | $SUB_URL" >> "$LIST"
    elif [ "$sel" -ge 1 ] 2>/dev/null && [ "$sel" -le $((i-1)) ]; then
      SUB_URL="${urls[sel]}"; SUB_NAME="${names[sel]}"
    else echo "无效选择"; exit 1; fi
    read -rp "修改订阅名称（回车=不改）[$SUB_NAME]: " newname
    if [ -n "$newname" ] && [ "$newname" != "$SUB_NAME" ]; then rename_in_list "$newname"; SUB_NAME="$newname"; fi
  fi
else
  read -rp "未找到 $LIST，粘贴订阅链接: " SUB_URL; read -rp "订阅名称: " SUB_NAME
  echo "$SUB_NAME | $SUB_URL" >> "$LIST"
fi

[ -z "$SUB_URL" ] && { echo "未提供订阅链接，退出"; exit 1; }
echo "使用 [$SUB_NAME]: ${SUB_URL:0:60}..."

# 依赖预检
python3 -c "import yaml" 2>/dev/null || { echo "❌ 缺少 python3-yaml（sudo apt install python3-yaml）"; exit 1; }
SUBNEW=$(mktemp /tmp/sub.new.XXXXXX) || { echo "❌ mktemp 失败"; exit 1; }
trap 'rm -f "$SUBNEW"' EXIT

echo "[1/3] 拉取订阅..."
http_code=$(curl -k -sS --max-time 60 -A "clash.meta/v1.19.30" "$SUB_URL" -o "$SUBNEW" -w "%{http_code}" 2>/dev/null) || http_code="000"
echo "  HTTP $http_code  size=$(stat -c%s "$SUBNEW" 2>/dev/null || echo 0)"
if [ "$http_code" != "200" ] || [ ! -s "$SUBNEW" ]; then
  echo "❌ 拉取失败（HTTP=$http_code）。请检查：订阅链接是否正确/网络是否通/是否已续订"
  exit 1
fi

echo "[2/3] 精简配置（先备份+原子写入+格式校验）..."
export SUBNEW
python3 - <<'PY'
import yaml, os, shutil, time, glob
cfg = os.path.join(os.environ['HOME'], '.config/mihomo/config.yaml')
subnew = os.environ['SUBNEW']
d = yaml.safe_load(open(subnew))
# 格式校验：异常订阅（base64/非clash结构）不得触碰现有配置
if not isinstance(d, dict) or not isinstance(d.get('proxies'), list) or not d['proxies']:
    print("  ❌ 订阅格式异常（不含有效 proxies 列表），现有配置未改动")
    raise SystemExit(1)
proxies = d['proxies']
all_names = [p['name'] for p in proxies]
real = [n for n in all_names if '剩余流量' not in n and '套餐到期' not in n]
servers = set()
for p in proxies:
    h = str(p.get('server','')).split(':')[0]
    if h and not h.replace('.','').replace('-','').isdigit():
        servers.add(h)
dns = d.get('dns') or {'enable': True, 'enhanced-mode': 'fake-ip', 'nameserver': ['223.5.5.5','119.29.29.29']}
if servers:
    dns['nameserver-policy'] = {h: 'system://' for h in sorted(servers)}
out = {
    'mixed-port': d.get('mixed-port', 7890),
    'allow-lan': False, 'bind-address': '*', 'mode': 'rule', 'log-level': 'info', 'ipv6': False,
    'unified-delay': True, 'geodata-mode': True,
    'dns': dns,
    'proxies': proxies,
    'proxy-groups': [
        {'name': '节点选择', 'type': 'select', 'proxies': ['自动选择'] + all_names},
        {'name': '自动选择', 'type': 'url-test', 'proxies': real, 'url': 'http://www.gstatic.com/generate_204', 'interval': 300, 'tolerance': 50},
    ],
    'rules': ['GEOIP,CN,DIRECT', 'MATCH,节点选择'],
    'external-controller': '127.0.0.1:9090', 'external-ui': 'ui',
}
# 备份现有配置（保留最近5个），再原子替换（防写一半损坏）
bak = f"{cfg}.bak.{time.strftime('%Y%m%d%H%M%S')}"
if os.path.exists(cfg):
    shutil.copy2(cfg, bak)
tmp = f"{cfg}.tmp"
yaml.safe_dump(out, open(tmp, 'w'), allow_unicode=True, sort_keys=False)
os.replace(tmp, cfg)
for old in sorted(glob.glob(cfg + '.bak.*'))[:-5]:
    os.remove(old)
print(f"  已备份: {os.path.basename(bak) if os.path.exists(bak) else '无（首次）'}（保留最近5个）")
print(f"  精简完成: 节点={len(proxies)} 节点域名system解析={len(servers)}")
PY

echo "[3/3] 热重载mihomo（不重启进程，不碰gsettings，不崩溃）..."
if curl -s -X PUT 'http://127.0.0.1:9090/configs?force=true' -H 'Content-Type: application/json' -d '{}' -w "  reload=%{http_code}\n" 2>/dev/null | grep -q 204; then
  echo "  热重载成功"
else
  echo "  热重载失败，尝试重启mihomo..."
  bash "$HOME/clash-setup/stop-mihomo.sh" 2>/dev/null || true
  sleep 1; bash "$HOME/clash-setup/start-mihomo.sh"
fi
sleep 2
echo
echo "✅ 完成。打开 http://127.0.0.1:9090/ui 选节点"
echo "查看用量: 双击桌面「mihomo-查看用量」或 bash ~/clash-setup/sub-info.sh"
echo "管理订阅名称: 编辑 ~/clash-setup/subs.list"
