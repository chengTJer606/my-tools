#!/usr/bin/env bash
# 更新订阅：选订阅(可改名/加新) → 拉取 → 精简(节点域名独立解析) → 语义校验 → API热重载
set -e
LIST="$HOME/clash-setup/subs.list"
SUB_URL=""; SUB_NAME=""

# 更新锁：防止重复双击并发执行互相覆盖配置
exec 8>"${XDG_RUNTIME_DIR:-/tmp}/mihomo-update.lock"
flock -n 8 || { echo "⚠️ 另一个订阅更新正在进行，请稍候"; exit 1; }

# 解释器选择（优先当前 python3，缺 yaml 时回退系统 /usr/bin/python3）
PY=python3
$PY -c "import yaml" 2>/dev/null || PY=/usr/bin/python3

# 改subs.list中某URL对应的名称
rename_in_list() {
  "$PY" - "$LIST" "$SUB_URL" "$1" <<'PY'
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
$PY -c "import yaml" 2>/dev/null || { echo "❌ 缺少 python3-yaml（sudo apt install python3-yaml）"; exit 1; }
SUBNEW=$(mktemp /tmp/sub.new.XXXXXX) || { echo "❌ mktemp 失败"; exit 1; }
trap 'rm -f "$SUBNEW"' EXIT

echo "[1/4] 拉取订阅..."
http_code=$(curl -sS --max-time 60 -A "clash.meta/v1.19.30" "$SUB_URL" -o "$SUBNEW" -w "%{http_code}" 2>/dev/null) || http_code="000"
echo "  HTTP $http_code  size=$(stat -c%s "$SUBNEW" 2>/dev/null || echo 0)"
if [ "$http_code" != "200" ] || [ ! -s "$SUBNEW" ]; then
  echo "❌ 拉取失败（HTTP=$http_code）。请检查：订阅链接是否正确/网络是否通/是否已续订"
  exit 1
fi

echo "[2/4] 精简配置（先备份+原子写入+格式校验）..."
# 记录"本次更新前"的最近备份（按文件名排序，时间戳有序），供失败回滚使用
PREV_CFG=$(ls -1 "$HOME/.config/mihomo"/config.yaml.bak.[0-9]* 2>/dev/null | sort | tail -1)
export SUBNEW
"$PY" - <<'PY'
import yaml, os, shutil, time, glob
cfg = os.path.join(os.environ['HOME'], '.config/mihomo/config.yaml')
subnew = os.environ['SUBNEW']
d = yaml.safe_load(open(subnew))
# 格式校验：异常订阅（base64/非clash结构）不得触碰现有配置
if not isinstance(d, dict) or not isinstance(d.get('proxies'), list) or not d['proxies']:
    print("  ❌ 订阅格式异常（不含有效 proxies 列表），现有配置未改动")
    raise SystemExit(1)
proxies = d['proxies']
all_names = [p.get('name','') for p in proxies]
PSEUDO = ['剩余流量','剩余','套餐到期','到期时间','过滤掉','官网','重置','距离下次','流量重置']
real = [n for n in all_names if n and not any(k in n for k in PSEUDO)]
if not real:
    print("  ❌ 订阅中无有效节点（全是信息条目），现有配置未改动")
    raise SystemExit(1)
servers = set()
for p in proxies:
    h = str(p.get('server','')).split(':')[0]
    if h and not h.replace('.','').replace('-','').isdigit():
        servers.add(h)
dns = d.get('dns') or {'enable': True, 'enhanced-mode': 'fake-ip', 'nameserver': ['223.5.5.5','119.29.29.29']}
if servers:
    # 节点域名走 mihomo 专用 proxy-server-nameserver（国内DoH/UDP），不再依赖系统DNS；
    # 同时加入 fake-ip-filter，防止拿到 fake-ip 造成解析回环
    dns['proxy-server-nameserver'] = ['https://223.5.5.5/dns-query','https://doh.pub/dns-query','223.5.5.5','119.29.29.29']
    fip = dns.get('fake-ip-filter') or []
    for h in sorted(servers):
        if h not in fip:
            fip.append(h)
    dns['fake-ip-filter'] = fip
    # 清除订阅自带的 nameserver-policy 对节点域名的劫持（第三方 DoH 不可用即全断，且无回退）
    pol = dns.get('nameserver-policy')
    if isinstance(pol, dict):
        for h in list(pol.keys()):
            if h in servers or h == 'geosite:cn' and False:
                pol.pop(h, None)
        if not pol:
            dns.pop('nameserver-policy', None)
dns['ipv6'] = False  # 与顶层 ipv6: false 保持一致
out = {
    'mixed-port': d.get('mixed-port', 7890),
    'allow-lan': False, 'bind-address': '*', 'mode': 'rule', 'log-level': 'info', 'ipv6': False,
    'unified-delay': True, 'geodata-mode': True,
    'dns': dns,
    'proxies': proxies,
    'proxy-groups': [
        {'name': '节点选择', 'type': 'select', 'proxies': ['自动选择'] + real},
        {'name': '自动选择', 'type': 'url-test', 'proxies': real, 'url': 'https://www.google.com/generate_204', 'interval': 300, 'tolerance': 50},
    ],
    'rules': ['GEOIP,CN,DIRECT', 'MATCH,节点选择'],
    'external-controller': '127.0.0.1:9090', 'external-ui': 'ui',
}
# fake-ip 使用 benchmark 保留网段（订阅默认 28.0.0.0/8 是公网段，有冲突隐患）
dns['fake-ip-range'] = '198.18.0.0/16'
# 备份现有配置（保留最近5个时间戳备份，手工备份不动），再原子替换（防写一半损坏）
bak = f"{cfg}.bak.{time.strftime('%Y%m%d%H%M%S')}"
if os.path.exists(cfg):
    shutil.copy2(cfg, bak)
    os.chmod(bak, 0o600)
tmp = f"{cfg}.tmp.{os.getpid()}"
with open(tmp, 'w') as f:
    yaml.safe_dump(out, f, allow_unicode=True, sort_keys=False)
os.chmod(tmp, 0o600)   # 配置含节点 uuid，禁止同机其他用户读取
os.replace(tmp, cfg)
for old in sorted(glob.glob(cfg + '.bak.[0-9]*'))[:-5]:
    os.remove(old)
print(f"  已备份: {os.path.basename(bak) if os.path.exists(bak) else '无（首次）'}（保留最近5个）")
print(f"  精简完成: 节点={len(proxies)} 可选真实节点={len(real)} 节点域名独立解析={len(servers)}")
PY

echo "[3/4] 语义校验（mihomo -t）..."
if ! "$HOME/.local/bin/mihomo" -t -d "$HOME/.config/mihomo" > /tmp/mihomo-config-test.log 2>&1; then
  echo "  ❌ 新配置未通过语义校验，自动回滚到更新前配置..."
  if [ -n "$PREV_CFG" ] && [ -f "$PREV_CFG" ]; then
    cp -f "$PREV_CFG" "$HOME/.config/mihomo/config.yaml"; chmod 600 "$HOME/.config/mihomo/config.yaml"
    echo "  已回滚: $(basename "$PREV_CFG")"
  else
    echo "  ⚠️ 无可用备份，请手动检查配置"
  fi
  grep -E "error|failed" /tmp/mihomo-config-test.log | tail -3
  exit 1
fi
echo "  ✅ 语义校验通过"

echo "[4/4] 热重载mihomo（不重启进程，不碰gsettings，不崩溃）..."
if curl -s --max-time 15 -X PUT 'http://127.0.0.1:9090/configs?force=true' -H 'Content-Type: application/json' -d '{}' -w "  reload=%{http_code}\n" 2>/dev/null | grep -q "reload=204"; then
  echo "  热重载成功"
else
  echo "  热重载失败，尝试重启mihomo..."
  bash "$HOME/clash-setup/stop-mihomo.sh" 2>/dev/null || true
  sleep 1; bash "$HOME/clash-setup/start-mihomo.sh" 8>&- < /dev/null
fi
sleep 2
echo
echo "✅ 完成。打开 http://127.0.0.1:9090/ui 选节点"
echo "查看用量: 双击桌面「mihomo-查看用量」或 bash ~/clash-setup/sub-info.sh"
echo "管理订阅名称: 编辑 ~/clash-setup/subs.list"
