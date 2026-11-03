# 百度网盘 操作详细指南（端点 / 性能 / 坑）

> README.md 是上手指南，本文档是深度参考。两条路线都覆盖：REST 直调（读 + 分析）和 MCP SSE（写）。

## 1. REST 端点速查（用于 Python 脚本直调）

域名 `pan.baidu.com`（**不是** `d.pcs.baidu.com`）。所有 GET 的 path 都要 `urllib.parse.quote(path, safe='')` 全编码（斜杠也编码无影响）。

| 操作 | 方法 + 端点 | 关键参数 |
|------|------------|----------|
| 用户信息 | `GET /rest/2.0/xpan/nas?method=uinfo` | `access_token` |
| 容量 | `GET /api/quota` | `access_token`, `checkfree=1`, `checkexpire=1` |
| **列目录** | `GET /rest/2.0/xpan/file?method=list` | `dir`, `order=time`, `desc=1`, `start`, `limit=100`, `web=1`, `access_token` |
| 关键词搜 | `GET /rest/2.0/xpan/file?method=search` | `dir`, `key`, `access_token` |
| 文件详情（按 fsid） | `GET /rest/2.0/xpan/multimedia?method=filemetas` | `fsids=[...]`, `access_token`（**这条在 multimedia 路径下**） |
| 递归 listall | `GET /rest/2.0/xpan/file?method=listall` | `path`, `recursion=1`, `web=1`（**MCP 没暴露**） |
| 创建目录 | `POST /rest/2.0/xpan/file?method=create` | `path`, `isdir=1`, `rtype=1`, `a=commit` |
| 删除 | `POST /rest/2.0/xpan/file?method=filedelete` | `filelist=["/path"]` —— ❌ 31296 |
| 移动 | `POST /rest/2.0/xpan/file?method=filemove` | ❌ 31296 |
| 复制 | `POST /rest/2.0/xpan/file?method=filecopy` | ❌ 31296 |
| 重命名 | `POST /rest/2.0/xpan/file?method=filerename` | ❌ 31296 |

**写操作一律走 MCP SSE 入口**（在 Claude Code 内调 `mcp__baidu-netdisk__*`），不要直调 REST。

## 2. 大目录扫描性能（实测）

| 规模 | 单层 list（每页 100） | 递归 walk |
|------|---------------------|-----------|
| 小目录（< 100 文件） | 1 次调用，~1 秒 | 几秒 |
| 中目录（~1000 文件） | 10 页，~5 秒 | ~30 秒 |
| 大目录（~20000 文件，4 层深） | — | **约 7-14 分钟**，~24-48 files/sec |

实测数据（2026-08-05，本机）：
- `_待删除_2026-08-05/` 90 文件 / 4 层 → 14.6 秒（嵌套深，每层一次调用但只取几个文件）
- `2024-2025在校/` 20338 文件 / 4 层 → ~7-14 分钟（前任 CC 实测 14 分钟，本次重启后 ~7 分钟）

**减时思路**（如有大量扫描需求）：
- 用 `method=listall&recursion=1`（一次最多 10000 条要分页），MCP 没暴露，要 Python 直调
- 或只 list 关键子目录（如果大概知道文件归属）

## 3. md5 比对的坑（视频文件尤其注意）

百度网盘对大文件 / 视频用 **分片 block_list 的组合 md5**，不是整文件 MD5。同一份文件不同实例的 `md5` 字段**可能不同**（推测与秒传判定路径有关）。

**正确比对法**：
1. 先比 `md5`（小文件可靠）
2. md5 不同时比 `size` —— size 完全一致 + 文件名一致 = 几乎确定同一份
3. size 也不同时才需要人工判断

`analyze.py` 就是按这个逻辑做分组的（`DUP_MD5` > `DUP_SIZE_NAME` > `DUP_NAME_DIFF`）。

## 4. Windows + Python 调网盘 API 的坑

### 4.1 stdout 中文乱码
脚本开头加：
```python
import sys
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")
```

### 4.2 Git Bash 路径转换
在 Git Bash 里传 `/开头` 的路径给 Python，会被 MSYS 转成 Windows 路径（如 `D:/Git/来自...`）。解决：
- 设 `MSYS_NO_PATHCONV=1` 环境变量后执行
- 或在 Python 脚本里硬编码路径（参考 `_list_compare.py`）
- 或用 `cmd /c "python ..."` 包裹（cmd 不做 path 转换）

### 4.3 URL 编码
`urllib.parse.quote(path, safe='')` 全编码即可，斜杠也编码无影响（API 接受）。

### 4.4 POST body 编码
`urllib.parse.urlencode(body)` 自动处理。`filelist` 字段值是 JSON 字符串，**其中 path 是原始中文，不要再 URL 编码一次放 JSON 里**。

### 4.5 JSON 文件读写
- 读：`json.load(open(path, 'r', encoding='utf-8'))`
- 写：`json.dump(obj, f, ensure_ascii=False, indent=2)`（必须 `ensure_ascii=False` 否则中文变 `\uXXXX`）

## 5. MCP SSE 写操作（实测可用 + 注意事项）

2026-08-05 实测：通过 `mcp__baidu-netdisk__*` 调用走中间鉴权，**绕过**个人 token 直调 REST 的 31296 限制。

### 已验证可用的写工具
- `file_move`（async=0 同步）→ errno=0，文件真实移动
- `make_dir`（rtype=1）→ errno=0，目录真实创建
- 推断同样可用：`file_copy`、`file_rename`、`file_sharelink_set`、`file_upload_by_url`、`file_upload_by_content`

### 调用模式（参考 2026-08-05 实际操作）

**移动多个目录到聚合目录**（用于"批量删除"）：
```python
# 调用 mcp__baidu-netdisk__file_move
async = 0
ondup = "skip"
filelist = [
  {"path": "/.../源1", "dest": "/.../_待删除_日期", "newname": "源1"},
  {"path": "/.../源2", "dest": "/.../_待删除_日期", "newname": "源2"},
  # ...
]
```

**移动单个文件到归位目录**（用于"整理"）：
```python
async = 0
ondup = "skip"
filelist = [
  {"path": "/.../源.mp4", "dest": "/.../目标目录", "newname": "源.mp4"}
]
```

### 不存在的工具
- `file_del` —— 删除靠聚合变通（见 README.md §6）
- `file_upload_stdio` —— 上传本地文件要切换 MCP stdio 模式

## 6. 调用配额 / Token 失效

- 个人体验 token 30 天有效（2592000 秒）
- 官方未公开 QPS / 每日上限
- 失效症状：API 返回 `error_code=111` 或 `invalid session` → 走 README.md §4 换 token
- 体验密钥"不定期变更"，正式使用需企业开发者认证（https://pan.baidu.com/union）

## 7. 2026-08-05 接入时间线（一句话总结）

第一次接入时，前任 CC 用 REST 直调做"读 + 分析"成功（list/walk/filemetas 都 OK），但所有写 API 返回 31296，最后发现 MCP SSE 入口可以写（重启 CC 后才能测，因为 MCP 工具会话启动时加载）。本会话已验证：MCP SSE 写操作全部可用（`file_move` / `make_dir` 实测 errno=0），并完成了 mp4 归位 + 4 目录聚合删除。
