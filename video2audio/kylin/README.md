# 视频转音频工具 - Linux 便携版

基于原 Windows 版改编，适配麒麟 ARM64 Linux。无需安装，整个文件夹拷到哪里都能运行。

## 文件组成

| 文件 | 说明 |
| --- | --- |
| `video2audio.py` | 主程序（Python 图形界面） |
| `启动.sh` | Linux 启动脚本 |
| `README.md` | 本说明文件 |

> 不再内置 ffmpeg（原 Windows 版的 `ffmpeg.exe` 约 62MB，在 Linux 上无法运行）。
> 程序自动使用系统安装的 ffmpeg。如需离线便携，可将 Linux 版 ffmpeg 二进制放入本文件夹。

## 环境要求

- **Python 3.7+**（仅用标准库 tkinter，无需额外 pip 包）
- **ffmpeg**（系统安装即可）

安装依赖（麒麟/Ubuntu 系）：

```bash
sudo apt install python3 python3-tk ffmpeg
```

## 使用方法

### 方式一：终端启动

```bash
cd <工具目录>/kylin
bash 启动.sh
```

### 方式二：双击启动

1. 右键 `启动.sh` → 属性 → 权限 → 勾选「允许以程序执行」
2. 双击 `启动.sh` 即可

## 操作流程

1. **选择视频**：
   - `选择视频文件…`：单选或多选（Ctrl/Shift 多选）
   - `选择文件夹（批量）…`：递归读取文件夹及子文件夹中的视频
   - `移除选中` / `清空列表`：编辑任务列表
2. **设置参数**：
   - **音频格式**：默认 MP3 (192kbps)，可选 128/192/320kbps MP3、M4A/AAC、WAV 无损、原流复制
   - **文件名后缀**：默认 `_audio`，生成 `视频_audio.mp3`
   - **转换成功后删除原视频**：勾选后永久删除原视频（不可恢复）
3. **开始转换**：点击 `▶ 开始转换`，实时显示状态
4. **输出位置**：与输入文件相同的目录

## 支持的视频格式

`.mp4 .mkv .avi .mov .flv .wmv .webm .ts .m4v .mpg .mpeg .3gp .rmvb .rm .vob .ogv .mts .m2ts .f4v`

## 输出格式

| 格式 | 扩展名 | 特点 |
| --- | --- | --- |
| MP3 (192kbps) | `.mp3` | 默认，体积小、兼容性好 |
| MP3 (320/128 kbps) | `.mp3` | 高质量 / 更小体积 |
| M4A / AAC | `.m4a` | 同等音质下比 MP3 略小 |
| WAV (无损 PCM) | `.wav` | 无损，体积大，适合后期剪辑 |
| 原流复制(最快) | 视源而定 | 不重新编码，秒级完成 |

## 与原 Windows 版的区别

| 项目 | Windows 版 | Linux 版 |
| --- | --- | --- |
| ffmpeg | 内置 `ffmpeg.exe` (62MB) | 使用系统 ffmpeg，不内置 |
| 启动方式 | `启动.bat` 双击 | `启动.sh` 双击或终端运行 |
| 路径分隔符 | `\` | `/` |
| 窗口隐藏 | `creationflags` | 不需要（Linux 无此问题） |
| 其他 | 完全一致 | 完全一致 |

## 便携性说明

- 整个 `linux版/` 文件夹可复制到任意位置运行
- 脚本通过 `__file__` 自动定位自身目录，不写死路径
- ffmpeg 查找顺序：同目录 ffmpeg → 系统 ffmpeg
- 如需完全离线便携，可将 Linux ARM64 版 ffmpeg 二进制放入文件夹内

## 常见问题

### 启动报错 "未找到 python3"

```bash
sudo apt install python3
```

### 启动报错 "tkinter 模块未安装"

```bash
sudo apt install python3-tk
```

### 启动报错 "未找到 ffmpeg"

```bash
sudo apt install ffmpeg
```

### 转换失败 "未检测到音频流"

源视频本身是无声的，无法提取音频。

### 想移到其他 Linux 电脑

直接把整个 `linux版/` 文件夹拷过去，确保目标机器有 python3 和 ffmpeg 即可。
