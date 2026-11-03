#!/usr/bin/env python3
"""Scan Tencent Docs folder tree recursively via MCP API."""

import json
import urllib.request
import urllib.error
import os
import sys

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
EXCLUDE_NAMES = set()  # 要排除的文件夹名，按需填写，如 {"示例目录"}
API_LIMIT = 1800

# 根目录列表：从 data/02-root-folder-list.json 读取（首步产物，格式见 README）
_root_json = os.path.join(WORKDIR, "data", "02-root-folder-list.json")
ROOT_FOLDERS = []
if os.path.isfile(_root_json):
    with open(_root_json, encoding="utf-8") as _f:
        _raw = json.load(_f)
    ROOT_FOLDERS = [{"id": it["id"], "name": it["title"]}
                    for it in _raw.get("list", []) if it.get("is_folder")]


class ApiCounter:
    def __init__(self, start=0):
        self.count = start
        self.limit = API_LIMIT

    def check(self):
        return self.count < (self.limit - 50)


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
        print(f"  ERROR: {tool_name}({arguments}): {e}")
        return None


def scan_folder(folder_id, folder_path, depth=0):
    """Recursively scan a folder. Returns dict with folder_id, folder_path, folders, files."""
    if not counter.check():
        print("  WARNING: API limit approaching!")
        return None

    indent = "  " * depth
    print(f"{indent}[SCAN] {folder_path} (ID: {folder_id})")

    items = call_mcp("manage.folder_list", {"folder_id": folder_id})
    if items is None:
        return {"error": f"Failed to list {folder_id}"}

    result = {
        "folder_id": folder_id,
        "folder_path": folder_path,
        "folders": [],
        "files": [],
    }

    item_list = items.get("list", items) if isinstance(items, dict) else items
    if not item_list or not isinstance(item_list, list):
        return result

    for item in item_list:
        if not item or not counter.check():
            break

        name = item.get("title") or item.get("name", "")
        item_id = item.get("id", "")
        is_folder = item.get("is_folder", False)

        if is_folder:
            if name in EXCLUDE_NAMES:
                print(f"{indent}  [SKIP] Folder: {name}")
                continue
            child_path = f"{folder_path}/{name}" if folder_path else name
            sub = scan_folder(item_id, child_path, depth + 1)
            if sub:
                result["folders"].append(sub)
        else:
            print(f"{indent}  [FILE] {name}")
            result["files"].append({
                "file_id": item_id,
                "file_name": name,
                "folder_path": folder_path,
            })

    return result


def count_items(nodes):
    """Count total folders and files in tree."""
    folders, files = 0, 0
    for n in nodes:
        folders += 1
        files += len(n.get("files", []))
        if n.get("folders"):
            f, fl = count_items(n["folders"])
            folders += f
            files += fl
    return folders, files


def save_progress(extra=None):
    """Update progress file."""
    pf = os.path.join(WORKDIR, "data", "01-progress.json")
    if os.path.exists(pf):
        with open(pf, "r", encoding="utf-8-sig") as f:
            p = json.load(f)
    else:
        p = {}

    from datetime import datetime
    p["api_calls_used"] = counter.count
    p["last_updated"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if extra:
        p.update(extra)

    with open(pf, "w", encoding="utf-8") as f:
        json.dump(p, f, ensure_ascii=False, indent=2)


# --- MAIN ---
if __name__ == "__main__":
    # Load progress
    pf = os.path.join(WORKDIR, "data", "01-progress.json")
    if os.path.exists(pf):
        with open(pf, "r", encoding="utf-8-sig") as f:
            p = json.load(f)
        counter.count = p.get("api_calls_used", 0)

    print(f"=== Tree Scan ===")
    print(f"Starting API count: {counter.count}")
    print(f"Limit: {API_LIMIT}")
    print(f"Excluding: {EXCLUDE_NAMES}")

    full_tree = []
    for folder in ROOT_FOLDERS:
        r = scan_folder(folder["id"], folder["name"])
        if r:
            full_tree.append(r)

    # Save tree
    tree_file = os.path.join(WORKDIR, "data", "03-file-tree.json")
    with open(tree_file, "w", encoding="utf-8") as f:
        json.dump(full_tree, f, ensure_ascii=False, indent=2)

    # Save flat file list for easier processing
    all_files = []

    def flatten(node):
        for f in node.get("files", []):
            all_files.append(f)
        for sub in node.get("folders", []):
            flatten(sub)

    flatten({"folders": full_tree})

    flat_file = os.path.join(WORKDIR, "data", "04-files-flat.json")
    with open(flat_file, "w", encoding="utf-8") as f:
        json.dump(all_files, f, ensure_ascii=False, indent=2)

    # Count
    folders, files = count_items(full_tree)

    print(f"\n=== Scan Complete ===")
    print(f"Folders: {folders}, Files: {files}, API calls used: {counter.count}")
    print(f"Tree saved to: {tree_file}")
    print(f"Flat file list: {flat_file}")

    save_progress({
        "tree_scanned": True,
        "total_folders": folders,
        "total_files": files,
    })
