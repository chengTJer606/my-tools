# my-tools · 个人工具箱

自用工具聚合仓库（Monorepo），一台主力设备开发与实测：**华为擎云 L410（麒麟 990，aarch64）+ 银河麒麟桌面操作系统 V10 SP1（UKUI / Wayland）**；部分工具含 Windows 版本。其他环境未适配，请自行评估。

## 工具导航

| 目录 | 工具 | 平台 | 简介 |
|------|------|------|------|
| [`kylin-screen-recorder/`](kylin-screen-recorder/) | 录屏工具 | 麒麟 UKUI | 全屏/区域录制、系统声/麦克风/混音、暂停继续分段合并、麦克风设备可选、日志系统（kmsgrab 绕开 Wayland portal 限制） |
| [`video2audio/`](video2audio/) | 视频转音频 | Win + 麒麟 | 批量视频提取音频（MP3/M4A/WAV/原流复制），GUI，Win 便携包见 Releases |
| [`disk-cleanup/`](disk-cleanup/) | 磁盘清理 | 麒麟 | journal/coredump/APT/缓存清理，检查/手动/自动/cron 四模式，定时清理 |
| [`baidu-netdisk-mcp/`](baidu-netdisk-mcp/) | 百度网盘 MCP 工具集 | 跨平台 | 官方 MCP 实战手册（REST 端点/性能/坑）+ 重复文件扫描分析脚本 |
| [`tencent-docs-download/`](tencent-docs-download/) | 腾讯文档批量下载 | 跨平台 | 云端文档批量导出，断点续传、API 限流管理、失败重试 |

各目录内的 README 是该工具的详细文档。

## 分支策略

- `main`：稳定基线（对外门面）
- `cheng`：日常开发分支，所有改动先提交到这里，验证稳定后合入 main

## License

[MIT](LICENSE)
