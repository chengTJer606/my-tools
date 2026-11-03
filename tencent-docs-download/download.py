#!/usr/bin/env python3
"""
Download all files from Tencent Docs, preserving folder structure.
Supports resume from progress file.
Handles API rate limiting and error recording.
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
FILES_DIR = os.path.join(WORKDIR, "files")

POLL_INTERVAL = 5  # seconds between export progress polls
MAX_POLLS = 12     # max polls per file (60 seconds total)


class ApiCounter:
    def __init__(self, start=0):
        self.count = start
        self.limit = API_LIMIT

    def check(self):
        """Return True if we have capacity, False if we should stop."""
        return self.count < (self.limit - 20)

    def warn(self):
        return self.count >= (self.limit - 50)


counter = ApiCounter()


def call_mcp(tool_name, arguments=None):
    """Call MCP tool, return parsed result dict or None."""
    if arguments is None:
        arguments = {}

    counter.count += 1

    payload = {
        "jsonrpc": "2.0",
        "id": counter.count,
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
    """Remove invalid Windows filename characters."""
    # Replace chars that are invalid in Windows filenames
    invalid = r'[<>:"/\\|?*]'
    name = re.sub(invalid, '_', name)
    # Also replace leading/trailing spaces and dots
    name = name.strip(' .')
    if not name:
        name = "unnamed"
    return name


def sanitize_folder_path(path):
    """Sanitize each component of a folder path."""
    parts = path.split('/')
    safe_parts = [sanitize_filename(p) for p in parts if p]
    return os.path.join(*safe_parts)


def ensure_dir(path):
    """Create directory if not exists."""
    os.makedirs(path, exist_ok=True)


def load_progress():
    """Load progress file, return dict."""
    pf = os.path.join(WORKDIR, "data", "01-progress.json")
    if os.path.exists(pf):
        with open(pf, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    return {}


def save_progress(progress):
    """Save progress to file."""
    pf = os.path.join(WORKDIR, "data", "01-progress.json")
    progress["api_calls_used"] = counter.count
    progress["last_updated"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(pf, "w", encoding="utf-8") as f:
        json.dump(progress, f, ensure_ascii=False, indent=2)


def save_error_log(errors):
    """Save error log file."""
    ef = os.path.join(WORKDIR, "data", "05-errors.json")
    with open(ef, "w", encoding="utf-8") as f:
        json.dump(errors, f, ensure_ascii=False, indent=2)


def log_error(progress, file_info, error_msg):
    """Record an error for a file."""
    if "download_errors" not in progress:
        progress["download_errors"] = []
    progress["download_errors"].append({
        "file_id": file_info.get("file_id", ""),
        "file_name": file_info.get("file_name", ""),
        "folder_path": file_info.get("folder_path", ""),
        "error": str(error_msg),
        "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    })
    save_error_log(progress["download_errors"])


def export_file(file_id):
    """Export a file, return task_id or None."""
    result = call_mcp("manage.export_file", {"file_id": file_id})
    if result is None:
        return None
    if "_error" in result:
        print(f"    Export error: {result['_error']}")
        return None
    # The response may contain task_id directly or nested
    task_id = result.get("task_id") or result.get("taskId") or result.get("id")
    if not task_id and isinstance(result, dict):
        # Try to find it anywhere in the response
        for key in result:
            if "task" in key.lower():
                task_id = result[key]
                break
    return task_id


def poll_export(task_id):
    """Poll export progress until complete or timeout. Return file_url or None."""
    for i in range(MAX_POLLS):
        if not counter.check():
            print(f"    API limit reached while polling")
            return None

        time.sleep(POLL_INTERVAL)

        result = call_mcp("manage.export_progress", {"task_id": task_id})
        if result is None:
            print(f"    Poll {i+1} failed to get response")
            continue
        if "_error" in result:
            print(f"    Poll {i+1} error: {result['_error']}")
            continue

        progress_val = result.get("progress") or result.get("progress_percent") or 0
        if isinstance(progress_val, str):
            try:
                progress_val = int(progress_val)
            except ValueError:
                progress_val = 0

        print(f"    Poll {i+1}: progress={progress_val}%")

        if progress_val >= 100 or progress_val == -1:
            file_url = result.get("file_url") or result.get("fileUrl") or result.get("url")
            if file_url:
                return file_url
            # Check nested content
            if "data" in result and isinstance(result["data"], dict):
                file_url = result["data"].get("file_url") or result["data"].get("url")
                if file_url:
                    return file_url
            print(f"    Progress=100 but no file_url in response: {json.dumps(result, ensure_ascii=False)[:200]}")
            return None

    print(f"    Timeout after {MAX_POLLS} polls")
    return None


def download_file(url, local_path):
    """Download file from URL to local path. Return True if successful."""
    try:
        ensure_dir(os.path.dirname(local_path))
        urllib.request.urlretrieve(url, local_path)
        size = os.path.getsize(local_path)
        print(f"    Downloaded: {local_path} ({size} bytes)")
        return True
    except Exception as e:
        print(f"    Download error: {e}")
        return False


def is_completed(progress, file_id):
    """Check if a file has already been completed."""
    for f in progress.get("files_completed", []):
        if f.get("file_id") == file_id:
            return True
    return False


# --- MAIN ---
if __name__ == "__main__":
    # Load state
    progress = load_progress()
    counter.count = progress.get("api_calls_used", 31)  # continue from scan

    # Load flat file list
    flat_file = os.path.join(WORKDIR, "data", "04-files-flat.json")
    with open(flat_file, "r", encoding="utf-8") as f:
        all_files = json.load(f)

    # Initialize tracking
    if "files_completed" not in progress:
        progress["files_completed"] = []
    if "files_failed" not in progress:
        progress["files_failed"] = []
    if "download_errors" not in progress:
        progress["download_errors"] = []

    # Filter out already completed files
    completed_ids = {f["file_id"] for f in progress["files_completed"]}
    pending_files = [f for f in all_files if f["file_id"] not in completed_ids]

    print(f"=== Download Phase ===")
    print(f"Total files: {len(all_files)}")
    print(f"Already completed: {len(progress['files_completed'])}")
    print(f"Previously failed: {len(progress['files_failed'])}")
    print(f"Pending: {len(pending_files)}")
    print(f"API calls used: {counter.count} / {API_LIMIT}")
    print(f"Files directory: {FILES_DIR}")
    print()

    if not pending_files:
        print("All files have been processed!")
        sys.exit(0)

    for i, file_info in enumerate(pending_files):
        file_id = file_info["file_id"]
        file_name = file_info["file_name"]
        folder_path = file_info.get("folder_path", "")

        print(f"[{i+1}/{len(pending_files)}] {folder_path}/{file_name}")

        # Check API limits
        if not counter.check():
            print(f"\n*** API LIMIT REACHED ({counter.count}/{API_LIMIT}) ***")
            print("Saving progress and stopping. Resume tomorrow to continue.")
            save_progress(progress)
            sys.exit(0)

        if counter.warn():
            print(f"  WARNING: Approaching API limit ({counter.count}/{API_LIMIT})")

        # Create local directory
        safe_folder = sanitize_folder_path(folder_path) if folder_path else ""
        target_dir = os.path.join(FILES_DIR, safe_folder)
        safe_file_name = sanitize_filename(file_name)

        # Step 1: Export
        task_id = export_file(file_id)
        if not task_id:
            error_msg = f"Failed to export file {file_id}"
            print(f"  ERROR: {error_msg}")
            progress["files_failed"].append(file_info)
            log_error(progress, file_info, error_msg)
            save_progress(progress)
            continue

        print(f"  Export task: {task_id}")

        # Step 2: Poll for completion
        file_url = poll_export(task_id)
        if not file_url:
            error_msg = f"Export timed out or failed for task {task_id}"
            print(f"  ERROR: {error_msg}")
            progress["files_failed"].append(file_info)
            log_error(progress, file_info, error_msg)
            save_progress(progress)
            continue

        # Step 3: Determine extension and full path
        # Try to get extension from URL
        ext = ".docx"  # default
        if ".pdf" in file_url.lower():
            ext = ".pdf"
        elif ".xlsx" in file_url.lower():
            ext = ".xlsx"
        elif ".pptx" in file_url.lower():
            ext = ".pptx"
        elif ".doc" in file_url.lower():
            ext = ".doc"

        # If filename already has extension, use it
        if "." in safe_file_name:
            base, existing_ext = os.path.splitext(safe_file_name)
            if existing_ext.lower() in (".pdf", ".docx", ".doc", ".xlsx", ".pptx", ".txt", ".csv"):
                ext = existing_ext
                safe_file_name = base + ext
            else:
                safe_file_name = base + ext
        else:
            safe_file_name = safe_file_name + ext

        local_path = os.path.join(target_dir, safe_file_name)

        # Step 4: Download
        if download_file(file_url, local_path):
            progress["files_completed"].append({
                "file_id": file_id,
                "file_name": file_name,
                "folder_path": folder_path,
                "local_path": local_path,
                "completed_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            })
        else:
            error_msg = f"Failed to download from {file_url[:80]}..."
            print(f"  ERROR: {error_msg}")
            progress["files_failed"].append(file_info)
            log_error(progress, file_info, error_msg)

        # Save progress after each file
        save_progress(progress)

    # Final summary
    print(f"\n=== Download Complete ===")
    print(f"Completed: {len(progress['files_completed'])}")
    print(f"Failed: {len(progress['files_failed'])}")
    print(f"API calls used: {counter.count} / {API_LIMIT}")
    save_progress(progress)
