# 更新日志 (CHANGELOG)

本文件记录 disk-cleanup 工具的所有修改历史。最新版本在前。

---

## 2026-10-12

### 交互模式（disk-cleanup.sh）

- 新增 `do_interactive()` 函数，双击运行（无参数）时进入交互模式
- 流程：显示检查报告 → 提示选择（y=清理 / n=重新检查 / 回车=退出）→ 清理后自动回到检查报告
- 添加 `[ ! -t 0 ]` 检测：stdin 非终端时回退到只检查模式，避免卡住
- 清理后直接循环回到检查报告，无需中间按回车暂停

### journal 大小统计修复（disk-cleanup.sh）

- 新增 `get_item_size()` ：journal_old 只统计旧机器ID目录大小，journal_vacuum 只统计当前机器ID目录大小
- 新增 `get_item_oldest_date()` 函数：同理分别计算最旧文件日期
- 修复：之前两项 journal 清理项检查路径都是 `/var/log/journal`，导致检查报告中显示两次相同大小

### 检查报告优化（disk-cleanup.sh）

- `do_check` 跳过大小为0的清理项不显示（如无旧机器ID目录时 journal_old 不再出现）
- `do_clean` 同样跳过0大小项，不记录到日志

### 清理失败检测（disk-cleanup.sh）

- `do_clean` 中清理后 `after_bytes >= before_bytes` 时标记 `[失败]` 并提示"权限不足或被占用"
- 之前 sudo 失败时静默显示"完成 释放=0B"，用户无法察觉

### 清理函数简化（disk-cleanup.sh）

- 去掉所有 `clean_*` 函数中无用的 `before` 计算和 `echo` 返回值（`do_clean` 用 before/after 差值计算释放量，函数返回值从未被使用）
- 清理调用改为 `$func >/dev/null 2>&1`，避免函数输出干扰格式化显示

### format_size 去 bc 依赖（disk-cleanup.sh）

- 用纯 bash 算术 `$((bytes / N))` 和 `$((bytes % N * 10 / N))` 替代 `echo "scale=1; ..." | bc`
- 在没有安装 bc 的系统上也能正常运行

### 日志轮转（disk-cleanup.sh）

- 新增 `rotate_logs()` 函数：
  - `logs/cleanup-*.log` 保留最近 20 个，自动删除旧文件
  - `state/cleanup.log` 保留最近 50 行
  - `logs/cron.log` 超过 1MB 时截断保留最近 200 行
- `do_clean` 末尾调用一次（清理后轮转）
- `do_auto` 开头调用一次（cron 模式下轮转 cron.log）

### PATH 去重（disk-cleanup.sh / install.sh / uninstall.sh）

- 三个脚本的 `export PATH` 去掉末尾 `${PATH}`，避免标准路径重复出现两次

### install.sh 优化

- 询问密码前先 `sudo -n true` 检测 sudoers 免密是否已配置
  - 已配置免密 → 写入空密码配置，不询问密码
  - 未配置 → 询问密码或留空（留空则提示手动配置 sudoers）

### uninstall.sh 优化

- 末尾添加 `read -r -p "按回车退出..."`（仅终端环境），双击运行不再一闪而过

### README.md 更新

- 路径改为通用 `/path/to/disk-cleanup`（原 `~/桌面/disk-cleanup` 已过时）
- 命令说明表添加"无参数=交互模式"
- 功能列表添加交互模式、日志轮转、失败检测说明
- 文件结构更新：新增 cron.log、轮转策略注释
- 配置说明添加 install.sh 自动检测 sudoers 免密说明
- 清理项表格补充"无旧目录时不显示"说明
