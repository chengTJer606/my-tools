#!/bin/bash
# ============================================================
# 启动.sh - 视频转音频工具 Linux 启动器
# 双击或终端运行此脚本即可启动 GUI
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 检查 Python3
if ! command -v python3 &>/dev/null; then
    echo "[错误] 未找到 python3，请先安装 Python 3"
    echo "  麒麟系统: sudo apt install python3 python3-tk"
    exit 1
fi

# 检查 tkinter
if ! python3 -c "import tkinter" 2>/dev/null; then
    echo "[错误] tkinter 模块未安装，请执行:"
    echo "  sudo apt install python3-tk"
    exit 1
fi

# 检查 ffmpeg
FF_FOUND=""
for name in ffmpeg ffmpeg.exe; do
    if [ -x "$SCRIPT_DIR/$name" ]; then
        FF_FOUND="$SCRIPT_DIR/$name"
        break
    fi
done
if [ -z "$FF_FOUND" ] && ! command -v ffmpeg &>/dev/null; then
    echo "[错误] 未找到 ffmpeg，请安装:"
    echo "  sudo apt install ffmpeg"
    exit 1
fi

# 启动 GUI
python3 "$SCRIPT_DIR/video2audio.py"
