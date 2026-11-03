# tencent-docs-download · 腾讯文档批量下载

通过腾讯文档 MCP API 批量下载云端文档，保持原始文件夹嵌套结构，支持断点续传与 API 限流管理。

## 功能

- 递归扫描云端文件夹树（自动排除指定目录）
- 批量导出下载，保持云端目录结构
- **断点续传**：进度实时落盘（`data/01-progress.json`），中断后重跑自动续传
- API 限流管理：每日上限约 1800 次调用，计数持久化，次日重置
- 失败记录与跳过机制（`data/05-errors.json`）

## 文件说明

| 文件 | 说明 |
|------|------|
| `scan_tree.py` | 递归扫描文件夹树，产出 `data/03-file-tree.json`、`data/04-files-flat.json` |
| `scan-tree.ps1` | 上述的 PowerShell 版本（Windows 用） |
| `download.py` | 批量下载主脚本（读 `data/04-files-flat.json`） |
| `download_share.py` | 分享链接文件下载（读 `data/share_files.json`） |
| `data/` | 数据目录：进度、文件树、错误记录（**不入库**，见 .gitignore） |
| `token.txt` | 访问令牌（**不入库**，权限 600） |

## 配置 Token（二选一）

1. 同目录 `token.txt` 写入令牌（推荐，本地使用）
2. 环境变量：`export TENCENT_DOCS_TOKEN=<你的令牌>`（Windows：`setx TENCENT_DOCS_TOKEN ...`）

令牌获取：腾讯文档 MCP 授权流程，详见官方文档。Token 过期后更新上述任一位置即可。

## 使用

```bash
# 1. 扫描云端文件夹树（需先准备好 data/02-root-folder-list.json——
#    手动调用一次 folder_list 获取根目录保存为该文件，格式：{"finish":true,"list":[{"id","is_folder","title","url"},...]}）
python3 scan_tree.py

# 2. 批量下载（断点续传：中断后重新运行即可继续）
python3 download.py

# 3. 查看进度
python3 -c "import json;p=json.load(open('data/01-progress.json',encoding='utf-8-sig'));print(f\"完成:{len(p.get('files_completed',[]))} 失败:{len(p.get('files_failed',[]))} API:{p['api_calls_used']}/{p['api_calls_limit']}\")"
```

## 排错

- **API 达到上限**：`data/01-progress.json` 中 `api_calls_used` 记录已用次数，次日 0:00 重置；手动改为 0 可立即重置计数
- **个别文件持续失败**：记录在 `files_failed`，可人工核对后将其条目移入 `files_completed` 跳过
- **排除目录**：编辑 `scan_tree.py` 顶部 `EXCLUDE_NAMES` 集合
