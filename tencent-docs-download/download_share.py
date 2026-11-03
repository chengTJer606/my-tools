#!/usr/bin/env python3
"""
下载从腾讯文档分享链接提取的收藏文件。
从 share_files.json 读取文件列表，通过 MCP API 导出下载。
"""

import json
import urllib.request
import urllib.error
import os
import sys
import time
import re
from datetime import datetime

WORKDIR = os.path.dirname(os.path.abspath(__file__))
def _load_token():
    """Token 加载：环境变量 TENCENT_DOCS_TOKEN > 同目录 token.txt（不入库）"""
    tok = os.environ.get("TENCENT_DOCS_TOKEN", "").strip()
    if tok:
        return tok
    tok_file = os.path.join(WORKDIR, "token.txt")
    if os.path.isfile(tok_file):
        with open(tok_file, encoding="utf-8") as _f:
            return _f.read().strip()
    return ""

TOKEN = _load_token()
MCP_URL = "https://docs.qq.com/openapi/mcp"
API_LIMIT = 1800
FILES_DIR = os.path.join(WORKDIR, "share_files_output")

POLL_INTERVAL = 5
MAX_POLLS = 12

PROGRESS_FILE = os.path.join(WORKDIR, "data", "share_download_progress.json")


def call_mcp(tool_name, arguments=None, counter_ref=None):
    """Call MCP tool, return parsed result dict."""
    if arguments is None:
        arguments = {}
    if counter_ref:
        counter_ref[0] += 1

    payload = {
        "jsonrpc": "2.0",
        "id": counter_ref[0] if counter_ref else 1,
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": arguments},
    }

    req = urllib.request.Request(
        MCP_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": TOKEN,
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            text = data["result"]["content"][0]["text"]
            return json.loads(text)
    except Exception as e:
        return {"_error": str(e)}


def sanitize_filename(name):
    invalid = r'[<>:"/\\|?*]'
    name = re.sub(invalid, '_', name)
    name = name.strip(' .')
    if not name:
        name = "unnamed"
    return name


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def load_progress():
    if os.path.exists(PROGRESS_FILE):
        with open(PROGRESS_FILE, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    return {}


def save_progress(progress, api_count):
    progress["api_calls_used"] = api_count
    progress["last_updated"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(PROGRESS_FILE, "w", encoding="utf-8") as f:
        json.dump(progress, f, ensure_ascii=False, indent=2)


def export_file(file_id, counter_ref):
    result = call_mcp("manage.export_file", {"file_id": file_id}, counter_ref)
    if result is None or "_error" in result:
        return None
    task_id = result.get("task_id") or result.get("taskId") or result.get("id")
    return task_id


def poll_export(task_id, counter_ref):
    for i in range(MAX_POLLS):
        if counter_ref[0] >= API_LIMIT - 20:
            return None
        time.sleep(POLL_INTERVAL)
        result = call_mcp("manage.export_progress", {"task_id": task_id}, counter_ref)
        if result is None or "_error" in result:
            continue
        progress_val = result.get("progress") or result.get("progress_percent") or 0
        if isinstance(progress_val, str):
            try:
                progress_val = int(progress_val)
            except ValueError:
                progress_val = 0
        print(f"    轮询 {i+1}: progress={progress_val}%")
        if progress_val >= 100 or progress_val == -1:
            file_url = result.get("file_url") or result.get("fileUrl") or result.get("url")
            if not file_url and "data" in result and isinstance(result["data"], dict):
                file_url = result["data"].get("file_url") or result["data"].get("url")
            return file_url
    return None


def download_file(url, local_path):
    try:
        ensure_dir(os.path.dirname(local_path))
        urllib.request.urlretrieve(url, local_path)
        size = os.path.getsize(local_path)
        print(f"    已下载: {local_path} ({size} bytes)")
        return True
    except Exception as e:
        print(f"    下载失败: {e}")
        return False


def get_ext_for_file(ext_str):
    """Map tencent doc ext to file extension."""
    ext_map = {
        "tencentsheet": ".xlsx",
        "tencentdoc": ".docx",
        "tencentslide": ".pptx",
        "tencentpdf": ".pdf",
        "tencentmind": ".mind",
        "tencentflowchart": ".flowchart",
        "smartsheet": ".xlsx",
    }
    return ext_map.get(ext_str, ".docx")


def main():
    ensure_dir(FILES_DIR)

    # Load share file list
    share_json = os.path.join(WORKDIR, "data", "share_files.json")
    with open(share_json, "r", encoding="utf-8") as f:
        share_data = json.load(f)
    all_files = share_data["files"]

    # Load progress
    progress = load_progress()
    api_count = [progress.get("api_calls_used", 0)]
    completed = set(progress.get("completed_ids", []))
    failed = set(progress.get("failed_ids", []))

    pending = [f for f in all_files if f["id"] not in completed and f["id"] not in failed]

    print(f"=== 腾讯文档收藏导出 ===")
    print(f"总文件数: {len(all_files)}")
    print(f"已完成: {len(completed)}")
    print(f"失败: {len(failed)}")
    print(f"待处理: {len(pending)}")
    print(f"API 已用: {api_count[0]} / {API_LIMIT}")
    print(f"输出目录: {FILES_DIR}")
    print()

    if not pending:
        print("全部文件已处理完毕！")
        return

    for i, f in enumerate(pending):
        file_id = f["id"]
        file_name = f["name"]
        ext_str = f.get("ext", "")

        print(f"[{i+1}/{len(pending)}] {file_name} (ID: {file_id})")

        if api_count[0] >= API_LIMIT - 30:
            print(f"\n*** 达到 API 上限 ({api_count[0]}/{API_LIMIT}) ***")
            save_progress(progress, api_count[0])
            sys.exit(0)

        # Step 1: Export
        task_id = export_file(file_id, api_count)
        if not task_id:
            print(f"  ERROR: 导出失败")
            progress.setdefault("failed_ids", []).append(file_id)
            save_progress(progress, api_count[0])
            continue
        print(f"  导出任务: {task_id}")

        # Step 2: Poll
        file_url = poll_export(task_id, api_count)
        if not file_url:
            print(f"  ERROR: 导出超时")
            progress.setdefault("failed_ids", []).append(file_id)
            save_progress(progress, api_count[0])
            continue

        # Step 3: Download
        ext = get_ext_for_file(ext_str)
        safe_name = sanitize_filename(file_name)
        if "." not in safe_name:
            safe_name += ext
        local_path = os.path.join(FILES_DIR, safe_name)

        if download_file(file_url, local_path):
            progress.setdefault("completed_ids", []).append(file_id)
        else:
            progress.setdefault("failed_ids", []).append(file_id)

        save_progress(progress, api_count[0])

    # Final summary
    print(f"\n=== 导出完成 ===")
    print(f"成功: {len(progress.get('completed_ids', []))}")
    print(f"失败: {len(progress.get('failed_ids', []))}")
    print(f"API 调用: {api_count[0]} / {API_LIMIT}")
    save_progress(progress, api_count[0])


if __name__ == "__main__":
    main()
