# 视频转音频工具（video2audio）

便携、可视化的视频批量转音频工具。基于 Python + ffmpeg，无需安装，整个文件夹拷到哪里就能在哪里运行。Windows 与银河麒麟（ARM64 Linux）双平台版本。

## 平台目录

| 目录 | 平台 | 说明 |
|------|------|------|
| [`win/`](win/) | Windows | 图形界面版，需配合 ffmpeg.exe 使用（见下方说明） |
| [`kylin/`](kylin/) | 银河麒麟 V10 SP1（aarch64，UKUI） | 使用系统自带 ffmpeg，无需内置 |

## 功能

- 单选 / 多选 / 文件夹递归批量导入视频
- 输出格式：MP3（128/192/320 kbps）、M4A/AAC、WAV 无损、原流复制（最快）
- 实时显示每个任务状态、原视频大小、输出大小、处理耗时
- 可选"转换成功后删除原视频"（带二次确认）

## ffmpeg 获取说明（Win 版）

`ffmpeg.exe` 为第三方开源组件（[FFmpeg 官网](https://ffmpeg.org/download.html)，GPL 协议），体积约 62MB，**不包含在本仓库中**。获取方式任选其一：

1. **下载 Release 便携包**（推荐）：本仓库 [Releases](../../releases) 页面的 `video2audio-win便携版.zip`，解压即用（已含 ffmpeg.exe）
2. **手动下载**：从 https://www.gyan.dev/ffmpeg/builds/ 下载 `ffmpeg-release-essentials.zip`，解压后将其 `bin/ffmpeg.exe` 放到 `win/` 目录下
3. **命令下载**（Windows PowerShell）：
   ```powershell
   Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile "$env:TEMP\ffmpeg.zip"
   ```

麒麟版无需此步骤（系统自带 ffmpeg）。

## 分支说明

- `main`：稳定基线
- `cheng`：日常开发分支

## License

[MIT](LICENSE)（ffmpeg.exe 本身遵循其原有 GPL/LGPL 许可）
