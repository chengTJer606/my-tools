#!/usr/bin/env bash
# run-in-terminal.sh —— 桌面双击专用包装器
# 作用：执行指定脚本，无论成功失败都暂停窗口，确保用户能看到结果/报错
# 用法（.desktop 的 Exec）：bash ~/clash-setup/run-in-terminal.sh <脚本名>
SCRIPT="$1"
[ -z "$SCRIPT" ] && { echo "用法: run-in-terminal.sh <脚本名>"; read -rp "按回车关闭"; exit 1; }

if [ ! -f "$HOME/clash-setup/$SCRIPT" ]; then
  echo "❌ 脚本不存在: $HOME/clash-setup/$SCRIPT"
  echo "   请检查 clash-setup 目录是否完整（软链: $(readlink -f "$HOME/clash-setup" 2>/dev/null)）"
  read -rp "按回车关闭"
  exit 1
fi

bash "$HOME/clash-setup/$SCRIPT"
rc=$?
echo
if [ $rc -ne 0 ]; then
  echo "⚠️ 脚本退出码: $rc（如有疑问请截图此窗口反馈）"
fi
read -rp "按回车关闭窗口"
exit $rc
