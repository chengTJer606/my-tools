# -*- coding: utf-8 -*-
"""
analyze.py — 读取扫描清单 JSON，按文件名 + 文件大小找重复（不依赖 md5）。

判定规则：
  NAME_SIZE_DUP  同名 + 同 size → 同一文件（强判定，可安全删副本）
  SIZE_HINT_DUP  仅同 size（不同名）→ 可能是同一文件（弱判定，需人工确认）

  弱判定过滤：size > 100 KB 才纳入（避免小文件巧合），且 size 在全树出现次数 < 200
  （否则就是"3.2 MB"这类几乎每张照片都符合的常见 size，没意义）。

输入：dedup_result.json 或 scan_result.json（scan_example.py 的产物，
      记录自带 tree 字段标识所属根目录，分组统计直接读它，无需配置路径）
输出：
  dup_groups.json   结构化分组（NAME_SIZE_DUP 按 reclaimable_bytes 倒序，
                    SIZE_HINT_DUP 按 size 倒序）
  summary.json      统计数字 + 按根目录/类型分布
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")

HERE = Path(__file__).resolve().parent
INPUT = next((p for p in (HERE / "dedup_result.json", HERE / "scan_result.json")
              if p.is_file()), HERE / "dedup_result.json")
OUT_GROUPS = HERE / "dup_groups.json"
OUT_SUMMARY = HERE / "summary.json"

CATEGORY_NAMES = {
    1: "video", 2: "audio", 3: "image", 4: "doc",
    5: "app", 6: "other", 7: "torrent",
}

SIZE_HINT_MIN_BYTES = 100 * 1024      # 100 KB 门槛，弱判定
SIZE_HINT_MAX_GLOBAL_COUNT = 200      # 同 size 全树出现超过此次数视为"常见 size"，跳过


def human_bytes(n):
    if n is None:
        return "?"
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.2f} {unit}"
        n /= 1024
    return f"{n:.2f} PB"


def tree_of(record):
    """该文件属于哪个扫描根目录：优先读扫描时写入的 tree 字段，
    缺失时退化为第一个有意义的路径段。"""
    if record.get("tree"):
        return record["tree"]
    for p in record["path"].split("/")[1:]:
        if p:
            return p
    return "?"


def main():
    if not INPUT.is_file():
        sys.exit(f"[FATAL] {INPUT} 不存在，先跑 scan_example.py")
    with open(INPUT, "r", encoding="utf-8") as f:
        records = json.load(f)
    print(f"[analyze] input={INPUT.name}, loaded {len(records):,} records", flush=True)

    # ---------- groupings ----------
    by_name_size = defaultdict(list)
    by_size = defaultdict(list)
    for r in records:
        by_name_size[(r["name"], r["size"])].append(r)
        by_size[r["size"]].append(r)

    # ---------- NAME_SIZE_DUP (强判定) ----------
    name_size_groups = []
    covered_fids = set()
    for (name, size), items in by_name_size.items():
        if len(items) < 2:
            continue
        reclaimable = size * (len(items) - 1)
        group = {
            "type": "NAME_SIZE_DUP",
            "key": f"name={name}|size={size}",
            "name": name,
            "size": size,
            "category": items[0]["category"],
            "category_name": CATEGORY_NAMES.get(items[0]["category"], "?"),
            "n_files": len(items),
            "reclaimable_bytes": reclaimable,
            "files": [
                {
                    "path": it["path"],
                    "tree": tree_of(it),
                    "fsid": it["fsid"],
                    "md5": it.get("md5", ""),
                    "server_mtime": it.get("server_mtime", 0),
                }
                for it in items
            ],
        }
        name_size_groups.append(group)
        for it in items:
            covered_fids.add(it["fsid"])
    name_size_groups.sort(key=lambda g: g["reclaimable_bytes"], reverse=True)

    # ---------- SIZE_HINT_DUP (弱判定) ----------
    size_global_count = {s: len(items) for s, items in by_size.items()}
    size_hint_groups = []
    for size, items in by_size.items():
        if size < SIZE_HINT_MIN_BYTES:
            continue
        if size_global_count[size] > SIZE_HINT_MAX_GLOBAL_COUNT:
            continue
        leftover = [it for it in items if it["fsid"] not in covered_fids]
        if len(leftover) < 2:
            continue
        names = {it["name"] for it in leftover}
        if len(names) < 2:
            continue
        by_name_in_size = defaultdict(list)
        for it in leftover:
            by_name_in_size[it["name"]].append(it)
        if len(by_name_in_size) < 2:
            continue
        group = {
            "type": "SIZE_HINT_DUP",
            "key": f"size={size}",
            "size": size,
            "n_distinct_names": len(by_name_in_size),
            "n_files": len(leftover),
            "reclaimable_bytes": None,
            "files": [
                {
                    "name": name,
                    "paths": [
                        {"path": it["path"], "tree": tree_of(it),
                         "fsid": it["fsid"]}
                        for it in items_for_name
                    ],
                }
                for name, items_for_name in list(by_name_in_size.items())[:20]
            ],
        }
        size_hint_groups.append(group)
    size_hint_groups.sort(key=lambda g: g["size"], reverse=True)

    # ---------- write ----------
    all_groups = {
        "NAME_SIZE_DUP": name_size_groups,
        "SIZE_HINT_DUP": size_hint_groups,
    }
    with open(OUT_GROUPS, "w", encoding="utf-8") as f:
        json.dump(all_groups, f, ensure_ascii=False, indent=2)
    print(f"[analyze] wrote {OUT_GROUPS.name}", flush=True)

    # ---------- summary ----------
    def bytes_in(gtype):
        return sum(g["reclaimable_bytes"] for g in all_groups[gtype]
                   if g.get("reclaimable_bytes") is not None)

    summary = {
        "total_files": len(records),
        "total_bytes": sum(r["size"] for r in records),
        "NAME_SIZE_DUP": {
            "groups": len(name_size_groups),
            "files_in_groups": sum(g["n_files"] for g in name_size_groups),
            "reclaimable_bytes": bytes_in("NAME_SIZE_DUP"),
        },
        "SIZE_HINT_DUP": {
            "groups": len(size_hint_groups),
            "files_in_groups": sum(g["n_files"] for g in size_hint_groups),
        },
        "by_tree": _by_tree(records, name_size_groups),
        "by_category": _by_category(records, name_size_groups),
    }
    summary["total_reclaimable_bytes"] = summary["NAME_SIZE_DUP"]["reclaimable_bytes"]
    with open(OUT_SUMMARY, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    print(f"[analyze] wrote {OUT_SUMMARY.name}", flush=True)

    # ---------- console summary ----------
    print("", flush=True)
    print("=" * 70, flush=True)
    print(f"Total files:           {summary['total_files']:,}", flush=True)
    print(f"Total size:            {human_bytes(summary['total_bytes'])}", flush=True)
    print(f"NAME_SIZE_DUP groups:  {summary['NAME_SIZE_DUP']['groups']} "
          f"({summary['NAME_SIZE_DUP']['files_in_groups']} files, "
          f"{human_bytes(summary['NAME_SIZE_DUP']['reclaimable_bytes'])} reclaimable)",
          flush=True)
    print(f"SIZE_HINT_DUP (weak):  {summary['SIZE_HINT_DUP']['groups']} groups "
          f"({summary['SIZE_HINT_DUP']['files_in_groups']} files, needs human)",
          flush=True)
    print(f"Total reclaimable:     {human_bytes(summary['total_reclaimable_bytes'])}",
          flush=True)


def _by_tree(records, ns_groups):
    out = {}
    for r in records:
        t = tree_of(r)
        out.setdefault(t, {"files": 0, "bytes": 0})
        out[t]["files"] += 1
        out[t]["bytes"] += r["size"]
    reclaim = defaultdict(int)
    for g in ns_groups:
        for f in g["files"][1:]:
            reclaim[f["tree"]] += g["size"]
    for t, v in out.items():
        v["reclaimable_bytes"] = reclaim.get(t, 0)
    return out


def _by_category(records, ns_groups):
    out = {}
    for r in records:
        c = CATEGORY_NAMES.get(r["category"], "other")
        out.setdefault(c, {"files": 0, "bytes": 0})
        out[c]["files"] += 1
        out[c]["bytes"] += r["size"]
    reclaim = defaultdict(int)
    for g in ns_groups:
        reclaim[g["category_name"]] += g["size"] * (g["n_files"] - 1)
    for c, v in out.items():
        v["reclaimable_bytes"] = reclaim.get(c, 0)
    return out


if __name__ == "__main__":
    main()
