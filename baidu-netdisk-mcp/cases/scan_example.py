# -*- coding: utf-8 -*-
"""
scan_example.py — 网盘重复分析·扫描模板（复用上层的 dedup_scan.walk）

用法
----
1. 按实际情况修改下方 TREES / SKIP / OUTPUT
2. python scan_example.py
3. 产出清单 JSON，交给 analyze.py 做重复判定

参数说明
--------
TREES : 要扫描的网盘根目录列表（每个根递归遍历）
SKIP  : 已知无需扫描的子目录（如待删除区），可节省大量 API 调用
OUTPUT: 清单输出文件（JSON）
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from dedup_scan import resolve_token, walk  # noqa: E402

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")

# ================= 按你的实际情况修改 =================
TREES = [
    "/目录A",
    "/目录B",
]
SKIP = [
    "/目录A/_待删除",
]
OUTPUT = HERE / "dedup_result.json"
# =====================================================


def main() -> None:
    token = resolve_token(None)
    print(f"[scan] token resolved (len={len(token)})", flush=True)
    print(f"[scan] output -> {OUTPUT}", flush=True)

    all_records: list[dict] = []
    t0 = time.time()
    for root in TREES:
        n_before = len(all_records)
        print(f"[SCAN] {root}", flush=True)
        for rec in walk(root, token, label=root, skip_dirs=SKIP):
            all_records.append(rec)
        print(f"[SCAN]   -> {len(all_records) - n_before} files "
              f"(total {len(all_records)}, elapsed {time.time() - t0:.1f}s)",
              flush=True)

    with open(OUTPUT, "w", encoding="utf-8") as f:
        json.dump(all_records, f, ensure_ascii=False, indent=2)

    total_bytes = sum(r["size"] for r in all_records)
    print(f"[DONE] {len(all_records)} files, "
          f"{total_bytes / 1e9:.2f} GB, {time.time() - t0:.1f}s elapsed",
          flush=True)
    print(f"[SAVED] {OUTPUT}", flush=True)


if __name__ == "__main__":
    main()
