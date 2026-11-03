# 百度网盘 MCP + REST 操作手册（本机配置 + AI 上手指南）

> 给后续 AI 会话读：本文档自包含，读完即可上手操作用户的百度网盘。详细端点/性能/坑见 `MCP_USAGE_GUIDE.md`。

## 1. 这是什么

用户（百度 SVIP 账号，~13 TB 容量）已配置百度网盘官方 MCP 到本机 Claude Code。本目录是操作网盘的工具 + 教程集合。

- **官方 MCP 仓库**：https://github.com/baidu-netdisk/mcp
- **SSE 入口**：`https://mcp-pan.baidu.com/sse?access_token=<TOKEN>`
- **配置位置**：`<用户目录>/.claude.json`（Windows 示例：`C:SERS<用户名>.CLAUDE.JSON`） → `mcpServers.baidu-netdisk`
- **本机工具目录**：`<本地工具目录>/baidu-netdisk-mcp/`（文档最初记录于 Windows 环境，脚本本身跨平台）

## 2. 关键事实（必读，30 秒）

1. **两条路线分工**：
   - **MCP SSE 入口**（在 Claude Code 里调 `mcp__baidu-netdisk__*` 工具）= **写操作可用** + 单次交互式查询
   - **REST 直调**（用 `dedup_scan.py` 等 Python 脚本 + token）= **批量读取/扫描/分析最快路径**，但写操作被拒
2. **MCP 工具集没有 `file_del`**（2026-08-05 实测）。删除靠变通方案（见 §6）。
3. **个人体验 token 30 天有效**。失效后重新走授权流程（见 §4），不要重新申请。
4. **直调 REST 写 API 全部返回 31296**（个人体验 token 限制）。删除/移动/复制/重命名一律走 MCP SSE。

## 3. 两条路线分工

| 场景 | 用 MCP（Claude 内） | 用 REST（Python 脚本） |
|------|---------------------|------------------------|
| 列单层目录 | ✅ `file_list` 简单 | ✅ 但没必要 |
| 递归扫全树 | ⚠️ 慢（每层一次调用） | ✅ **首选** `dedup_scan.py` |
| 关键词搜索 | ✅ `file_keyword_search` | ✅ 同等 |
| 移动 / 重命名 / 复制 | ✅ **首选** `file_move` 等 | ❌ 全部 31296 |
| 创建目录 | ✅ `make_dir` | ✅ `create` 可用 |
| 删除 | ❌ 工具不存在 | ❌ 31296 |
| 上传本地文件 | ⚠️ SSE 不行；要 stdio 模式 | ❌（要走 OSS 分片，复杂） |
| 批量 md5/size 分析 | ⚠️ 要先 walk 取数 | ✅ **首选**（walk + 分组） |

**经验法则**：
- 要"读 + 分析" → REST（Python）
- 要"改" → MCP（在 Claude Code 里）
- 要"删" → MCP `file_move` 聚合到 `_待删除_<日期>/` + 用户手动删一个

## 4. Token 失效后如何更新

1. 浏览器打开授权链接（来源：官方 README，client_id 是官方体验密钥）：
   ```
   https://openapi.baidu.com/oauth/2.0/authorize?response_type=token&client_id=QHOuRXiepJBMjtk0esLhrPoNlQyYd0mF&redirect_uri=oob&scope=basic,netdisk
   ```
2. 登录百度账号 → 点"授权" → 浏览器地址栏跳到 `...#access_token=...&expires_in=2592000`
3. 把 `access_token=` 后面那段（到 `&` 之前）复制 → 替换 `<用户目录>/.claude.json`（Windows 示例：`C:SERS<用户名>.CLAUDE.JSON`） 里 `mcpServers.baidu-netdisk.url` 中的 `access_token=` 后面那段。**不需要 `claude mcp remove + add`**，直接改 URL 即可。

> Token 有效期 30 天。解绑在 https://pan.baidu.com/union 的"授权管理"。
> 体验密钥官方"将不定期变更"，正式生产需企业开发者认证。

## 5. MCP 工具速查表（在 Claude Code 内调 `mcp__baidu-netdisk__*`）

| 工具 | 用途 | 备注 |
|------|------|------|
| `user_info` | 验证 MCP 加载 + 拿账号信息 | 调用一次确认连接 |
| `get_quota` | 容量查询 | |
| `file_list` | 列单层目录（默认按 mtime 倒序） | **不递归**；要 walk 自己循环 |
| `file_doc_list` / `file_image_list` / `file_video_list` | 按类型列目录 | 比通用 list 快 |
| `file_keyword_search` | 文件名关键词全盘搜 | 精确匹配 |
| `file_semantics_search` | 自然语言语义搜 | 复杂查询用 |
| `file_meta` | 按 fsid 拿 md5/size 详情 | 一次最多 10 个 fsid |
| `make_dir` | 创建目录 | rtype=1 默认（冲突重命名） |
| `file_copy` | 复制 | async=0 同步 / 1 自适应 / 2 异步 |
| `file_move` | **移动**（也用于"聚合删除"） | 同上 |
| `file_rename` | 重命名 | 同上 |
| `file_sharelink_set` | 创建分享链接 | 需要 fsid + period + pwd |
| `file_upload_by_url` | 通过 URL 上传 | SSE 模式可用 |
| `file_upload_by_content` | 通过文本内容上传 | 文本 ≤ 2 万字 |

**没有的**：`file_del`（删除工具）、`file_upload_stdio`（本地文件上传，要 stdio 模式）。

## 6. 删除工作流（变通方案，因为没 `file_del`）

完整 4 步，**不要直接尝试任何 delete API**：

1. **列目标** — 用 `file_list` 确认要删的目录 / 文件路径
2. **建聚合目录** — `make_dir` 创建 `_待删除_<YYYY-MM-DD>/`
3. **聚合** — 用 `file_move`（`async=0` 同步、`ondup=skip` 防覆盖）把所有要删的目录 / 文件移进去。一次 file_move 调用的 `filelist` 可以包含多项，建议批量
4. **报告** — 告诉用户在网盘网页（https://pan.baidu.com/disk/main）或 APP 里手动删这一个聚合文件夹（进回收站，10 天可恢复）

参考：2026-08-05 已用此方案把 `with 诚（待整理）/` + 3 个测试目录共 4 项聚合到 `_待删除_2026-08-05/`。

## 7. 常见错误码

| 错误 | 含义 | 处理 |
|------|------|------|
| `errno=2 "unsupported api"` | 端点错了 | `list` 用 `/rest/2.0/xpan/file?method=list`（**不是 multimedia**）；`filemetas` 才在 multimedia 路径下 |
| `error_code=31296 "internal error"` | 个人 token 直调 REST 写 API 被拒 | 切换到 MCP SSE 入口；或确认是否在尝试 delete/move/copy/rename |
| `error_code=111` / `invalid session` | token 失效 | 走 §4 流程换 token |
| HTTP 404 | URL 拼错（域名是 `pan.baidu.com`，不是 `d.pcs.baidu.com`） | |

## 8. 相关文件

| 文件 | 内容 |
|------|------|
| `README.md` | **本文档** |
| `MCP_USAGE_GUIDE.md` | 详细实战指南：REST 端点、Python 调用模式、性能数据、md5 比对坑、Windows 编码坑 |
| `dedup_scan.py` | 通用 CLI 工具：递归 walk 网盘目录，输出全量文件 JSON 清单（read-only） |
| `cases/` | 重复文件分析案例方法论与通用脚本（scan/analyze 模板，个人场景数据已剔除） |

## 9. 不做的事

- ❌ 不要直调 REST 做 delete/move/copy/rename（已知全部 31296，浪费时间）
- ❌ 不要尝试 `multimedia?method=list`（已知 errno=2）
- ❌ 不要建议用户重新申请 token（个人 token 没问题，写权限是个人体验密钥的服务端策略）
- ❌ 不要让 Claude 在尝试写操作前不验证 MCP 加载（先调一次 `user_info` 确认）
