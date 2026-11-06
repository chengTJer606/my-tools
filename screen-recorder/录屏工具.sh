#!/bin/bash
# 录屏工具 · 启动器（双击运行；若双击询问请选择「运行」）
cd "$(dirname "$0")" || exit 1

# 字体渲染修复（v1.9）：优先使用系统 python3.8（自带 tk 8.6）。
# ~/.local/bin/python3（3.12 + tk 9.0.4）的字体子系统异常：
# 仅能枚举 29 个字体，Noto Sans CJK SC 等全部回退为点阵 fixed，
# 导致界面锯齿严重、行距异常；tk 8.6 下渲染正常。
if [ -x /usr/bin/python3.8 ] && /usr/bin/python3.8 -c "import tkinter" 2>/dev/null; then
    exec /usr/bin/python3.8 recorder_gui.py
fi
exec python3 recorder_gui.py
