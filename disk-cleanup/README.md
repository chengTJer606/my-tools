# disk-cleanup - 磁盘清理检查工具

银河麒麟桌面环境的磁盘垃圾清理工具，支持检查报告、手动清理、自动清理和定时任务。

## 功能

- **交互模式**：双击运行，检查→确认→清理，窗口不自动关闭
- **检查报告**：查看各清理项的占用大小、最旧文件日期、可清理总量
- **手动清理**：一键清理系统垃圾和用户缓存
- **自动清理**：超过阈值或磁盘使用率过高时自动清理
- **定时任务**：crontab 每周日凌晨3点自动检查清理
- **日志记录**：每次清理生成单独日志文件，自动轮转保留最近20条
- **失败检测**：清理失败时显示 `[失败]` 并提示原因（权限不足或被占用）

## 清理项

| 类型 | 项目 | 说明 |
|------|------|------|
| 系统 | journal 旧日志 | 删除旧机器ID的journal目录（无旧目录时不显示） |
| 系统 | journal 日志 | vacuum保留7天 |
| 系统 | coredump | 核心转储文件 |
| 系统 | APT包缓存 | `apt clean` |
| 系统 | hwupdate日志 | 硬件更新日志 |
| 用户 | 应用缓存 | `~/.cache` |
| 用户 | npm缓存 | `~/.npm/_cacache` |

## 快速开始

```bash
# 1. 安装（创建软链接 + 设置定时任务）
cd /path/to/disk-cleanup
bash install.sh

# 2. 检查磁盘占用情况
disk-cleanup --check

# 3. 手动清理
disk-cleanup --clean

# 4. 查看清理历史
disk-cleanup --history
```

## 命令说明

| 命令 | 说明 |
|------|------|
| `disk-cleanup`（无参数） | 交互模式（检查→确认→清理） |
| `disk-cleanup --check` | 检查并输出报告（不清理） |
| `disk-cleanup --clean` | 执行清理 |
| `disk-cleanup --auto [阈值GB]` | 超过阈值自动清理（默认2GB） |
| `disk-cleanup --cron` | cron模式（=--auto，精简输出） |
| `disk-cleanup --history` | 查看清理历史和日志列表 |
| `disk-cleanup --help` | 显示帮助 |

## 文件结构

```
disk-cleanup/
├── disk-cleanup.sh       主脚本
├── install.sh            安装脚本（创建软链接、设置crontab）
├── uninstall.sh          卸载脚本（移除软链接、清理crontab）
├── README.md             使用说明
├── CHANGELOG.md          更新日志
├── config/
│   ├── config.conf.example  配置模板（入库；密码留空）
│   └── config.conf          真实配置（install.sh 生成，权限600，不入库）
├── logs/                 每次清理的单独日志（自动轮转保留20条）
│   ├── cleanup-*.log     各次清理日志
│   └── cron.log          cron定时任务输出日志（超1MB自动截断）
└── state/                状态文件
    ├── last-clean        上次清理信息
    └── cleanup.log       累积历史记录（保留最近50条）
```

## 配置说明

配置文件 `config/config.conf`：

```bash
SUDO_PASSWORD="你的密码"        # sudo密码，留空则需配置sudoers免密
DEFAULT_THRESHOLD_GB=2          # 自动清理阈值（GB）
JOURNAL_RETENTION_DAYS=7        # journal日志保留天数
DISK_USAGE_THRESHOLD=80         # 磁盘使用率告警阈值（%）
```

install.sh 会自动检测 sudo 免密是否已配置：
- 已配置 → 写入空密码配置，无需存储密码
- 未配置 → 询问密码或留空（留空则需手动配置 sudoers 免密）

### sudo 免密配置（推荐）

避免明文存储密码，可配置 sudoers 免密：

```bash
echo "<用户名> ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/<用户名>
```

然后将 `config.conf` 中的 `SUDO_PASSWORD` 留空。

## 定时任务

安装后自动设置 crontab，每周日凌晨3点执行：

```
0 3 * * 0 /path/to/disk-cleanup.sh --cron >> /path/to/logs/cron.log 2>&1
```

**注意**：crontab 在关机或睡眠时不会执行，错过的任务不会补执行。

## 迁移

整个文件夹可复制到任意位置，运行 `bash install.sh` 重新安装即可：

```bash
# 迁移到新位置后
cd /new/path/disk-cleanup
bash install.sh
```

## 卸载

```bash
bash uninstall.sh
```

卸载仅移除软链接和 crontab，保留脚本文件夹、日志和配置文件。
