# -*- coding: utf-8 -*-
"""
视频转音频工具 - 便携版
依赖: 同目录下的 ffmpeg.exe
"""

import os
import sys
import time
import threading
import subprocess
import queue
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

# ---------- 常量 ----------
APP_TITLE = "视频转音频工具 v1.0"
VIDEO_EXTS = {
    ".mp4", ".mkv", ".avi", ".mov", ".flv", ".wmv", ".webm",
    ".ts", ".m4v", ".mpg", ".mpeg", ".3gp", ".rmvb", ".rm",
    ".vob", ".ogv", ".mts", ".m2ts", ".f4v",
}

# 格式 -> (扩展名, ffmpeg 编码参数, 是否需编码)
FORMATS = {
    "MP3 (192kbps)":   ("mp3", ["-b:a", "192k"], True),
    "MP3 (320kbps)":   ("mp3", ["-b:a", "320k"], True),
    "MP3 (128kbps)":   ("mp3", ["-b:a", "128k"], True),
    "M4A / AAC":       ("m4a", ["-c:a", "aac", "-b:a", "192k"], True),
    "WAV (无损 PCM)":  ("wav", ["-c:a", "pcm_s16le"], True),
    "原流复制(最快)":  ("m4a", ["-c:a", "copy"], False),
}

SUFFIX_DEFAULT = "_audio"
_CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0


# ---------- 工具函数 ----------
def app_dir():
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def locate_ffmpeg():
    local = os.path.join(app_dir(), "ffmpeg.exe")
    if os.path.isfile(local):
        return local
    return "ffmpeg"


def probe_audio_ext(ff, src):
    """用 ffmpeg -i 探测源音频编码，给出建议扩展名（用于原流复制）。"""
    try:
        p = subprocess.Popen(
            [ff, "-hide_banner", "-i", src],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, creationflags=_CREATE_NO_WINDOW,
        )
        _, err = p.communicate(timeout=15)
    except Exception:
        return None, "m4a"
    codec = None
    for line in err.splitlines():
        if "Audio:" in line:
            after = line.split("Audio:", 1)[1].strip()
            codec = after.split()[0].lower() if after else None
            break
    codec_to_ext = {
        "mp3": "mp3", "aac": "m4a", "ac3": "ac3", "eac3": "eac3",
        "opus": "opus", "vorbis": "ogg", "flac": "flac",
        "pcm_s16le": "wav", "pcm_s24le": "wav", "mp2": "mp2",
        "alac": "m4a", "wmav2": "wma", "wmav1": "wma",
    }
    ext = codec_to_ext.get(codec, "m4a") if codec else "m4a"
    return codec, ext


def fmt_size(n):
    if n is None:
        return ""
    try:
        f = float(n)
    except Exception:
        return ""
    for u in ["B", "KB", "MB", "GB"]:
        if f < 1024:
            return f"{f:.1f} {u}"
        f /= 1024
    return f"{f:.1f} TB"


def fmt_dur(sec):
    if sec is None or sec < 0:
        return ""
    if sec < 60:
        return f"{sec:.1f} 秒"
    total = int(sec)
    m, s = divmod(total, 60)
    if m < 60:
        return f"{m:02d}:{s:02d}"
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


# ---------- 主应用 ----------
class VideoToAudioApp:
    def __init__(self, root):
        self.root = root
        self.root.title(APP_TITLE)
        self.root.geometry("980x660")
        self.root.minsize(880, 560)

        self.tasks = []
        self.task_lock = threading.Lock()
        self.msg_queue = queue.Queue()
        self.running = False
        self.worker_thread = None
        self.total_start = None   # 总计时起点
        self.total_end = None     # 总计时终点（全部结束时锁定）

        self.suffix_var = tk.StringVar(value=SUFFIX_DEFAULT)
        self.format_var = tk.StringVar(value="MP3 (192kbps)")
        self.delete_var = tk.BooleanVar(value=False)

        self._build_ui()
        self._poll_messages()
        self._tick_total()

    # ---------- UI ----------
    def _build_ui(self):
        pad = {"padx": 8, "pady": 6}

        top = ttk.Frame(self.root)
        top.pack(fill="x", **pad)
        ttk.Button(top, text="选择视频文件…", command=self.pick_files).pack(side="left", padx=(0, 6))
        ttk.Button(top, text="选择文件夹（批量）…", command=self.pick_folder).pack(side="left", padx=6)
        ttk.Button(top, text="移除选中", command=self.remove_selected).pack(side="left", padx=6)
        ttk.Button(top, text="清空列表", command=self.clear_list).pack(side="left", padx=6)

        # 任务列表
        list_frame = ttk.LabelFrame(self.root, text="任务列表")
        list_frame.pack(fill="both", expand=True, **pad)

        cols = ("file", "status", "src_size", "out_size", "elapsed")
        self.tree = ttk.Treeview(list_frame, columns=cols, show="headings", selectmode="extended")
        self.tree.heading("file", text="视频文件")
        self.tree.heading("status", text="状态")
        self.tree.heading("src_size", text="原视频大小")
        self.tree.heading("out_size", text="输出音频大小")
        self.tree.heading("elapsed", text="处理耗时")
        self.tree.column("file", width=400, anchor="w")
        self.tree.column("status", width=90, anchor="center")
        self.tree.column("src_size", width=110, anchor="e")
        self.tree.column("out_size", width=120, anchor="e")
        self.tree.column("elapsed", width=100, anchor="center")
        vsb = ttk.Scrollbar(list_frame, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=vsb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")

        self.tree.tag_configure("done", foreground="#2e7d32")
        self.tree.tag_configure("fail", foreground="#c62828")
        self.tree.tag_configure("run",  foreground="#1565c0")
        self.tree.tag_configure("wait", foreground="#616161")

        # 参数区
        opt = ttk.LabelFrame(self.root, text="输出参数")
        opt.pack(fill="x", **pad)
        ttk.Label(opt, text="音频格式：").grid(row=0, column=0, sticky="w", padx=6, pady=8)
        ttk.Combobox(opt, textvariable=self.format_var, values=list(FORMATS.keys()),
                     state="readonly", width=22).grid(row=0, column=1, sticky="w", padx=6)
        ttk.Label(opt, text="文件名后缀：").grid(row=0, column=2, sticky="w", padx=(20, 6))
        ttk.Entry(opt, textvariable=self.suffix_var, width=12).grid(row=0, column=3, sticky="w")
        ttk.Label(opt, text="(原名 + 后缀 + .扩展名)", foreground="#666").grid(
            row=0, column=4, sticky="w", padx=6)
        ttk.Checkbutton(
            opt, text="转换成功后删除原视频（不可撤销，请谨慎勾选）",
            variable=self.delete_var
        ).grid(row=1, column=0, columnspan=5, sticky="w", padx=6, pady=(0, 8))
        ttk.Label(opt, text="输出位置：与输入文件相同的目录", foreground="#555").grid(
            row=2, column=0, columnspan=5, sticky="w", padx=6, pady=(0, 8))

        # 底部
        bottom = ttk.Frame(self.root)
        bottom.pack(fill="x", **pad)
        self.progress = ttk.Progressbar(bottom, mode="determinate")
        self.progress.pack(side="left", fill="x", expand=True, padx=(0, 8))
        self.start_btn = ttk.Button(bottom, text="▶  开始转换", command=self.start)
        self.start_btn.pack(side="right", padx=(8, 0))

        self.status_var = tk.StringVar(value="就绪。请选择视频文件或文件夹。  |  总用时：00:00")
        ttk.Label(self.root, textvariable=self.status_var, anchor="w", relief="sunken").pack(
            fill="x", side="bottom")

    # ---------- 选择输入 ----------
    def pick_files(self):
        paths = filedialog.askopenfilenames(
            title="选择一个或多个视频",
            filetypes=[("视频文件", "*.mp4 *.mkv *.avi *.mov *.flv *.wmv *.webm *.ts *.m4v "
                                 "*.mpg *.mpeg *.3gp *.rmvb *.rm *.vob *.ogv *.mts *.m2ts *.f4v"),
                       ("所有文件", "*.*")],
        )
        if paths:
            self._add_files(paths)

    def pick_folder(self):
        folder = filedialog.askdirectory(title="选择一个文件夹（会递归读取子文件夹中的视频）")
        if not folder:
            return
        found = []
        for dirpath, _d, files in os.walk(folder):
            for f in files:
                if os.path.splitext(f)[1].lower() in VIDEO_EXTS:
                    found.append(os.path.join(dirpath, f))
        if not found:
            messagebox.showinfo("提示", "该文件夹下未找到任何视频文件。")
            return
        self._add_files(found)

    def _add_files(self, files):
        with self.task_lock:
            existing = {t["src"] for t in self.tasks}
            for f in files:
                if f in existing:
                    continue
                try:
                    size = os.path.getsize(f)
                except Exception:
                    size = None
                self.tasks.append({
                    "src": f,
                    "status": "等待",
                    "src_size": size,
                    "out_size": None,
                    "elapsed": None,
                    "started_at": None,
                    "iid": None,
                    "msg": "",
                })
        self._refresh_tree()
        self._set_status(f"已加入 {len(files)} 个视频，等待开始。")

    def clear_list(self):
        if self.running:
            messagebox.showwarning("提示", "正在转换中，无法清空。")
            return
        with self.task_lock:
            self.tasks.clear()
        self._refresh_tree()
        self.progress["value"] = 0
        self.total_start = None
        self.total_end = None
        self._set_status("列表已清空。")

    def remove_selected(self):
        if self.running:
            messagebox.showwarning("提示", "正在转换中，无法修改列表。")
            return
        sel = set(self.tree.selection())
        if not sel:
            return
        with self.task_lock:
            self.tasks = [t for t in self.tasks if t["iid"] not in sel]
        self._refresh_tree()

    def _refresh_tree(self):
        for iid in list(self.tree.get_children()):
            self.tree.delete(iid)
        with self.task_lock:
            for t in self.tasks:
                iid = self.tree.insert(
                    "", "end",
                    values=self._row_values(t),
                    tags=(self._tag_for(t["status"]),))
                t["iid"] = iid

    @staticmethod
    def _row_values(t):
        return (
            t["src"],
            t["status"],
            fmt_size(t.get("src_size")),
            fmt_size(t.get("out_size")),
            fmt_dur(t.get("elapsed")),
        )

    @staticmethod
    def _tag_for(status):
        for key, tag in (("转换中", "run"), ("完成", "done"), ("失败", "fail")):
            if status.startswith(key):
                return tag
        return "wait"

    # ---------- 转换入口 ----------
    def start(self):
        if self.running:
            return
        with self.task_lock:
            todo = list(self.tasks)
        if not todo:
            messagebox.showinfo("提示", "请先选择视频。")
            return
        suffix = self.suffix_var.get().strip()
        if not suffix:
            messagebox.showwarning("提示", "请填写文件名后缀（不可为空）。")
            return
        fmt_key = self.format_var.get()
        if fmt_key not in FORMATS:
            messagebox.showwarning("提示", "请选择有效的音频格式。")
            return

        delete_original = self.delete_var.get()
        if delete_original:
            if not messagebox.askyesno(
                "确认删除原视频",
                "你已勾选「转换成功后删除原视频」。\n\n"
                "每个视频成功转出音频后，其原视频会被永久删除（送入回收站之外，不可恢复）。\n\n"
                "确定继续吗？",
                icon="warning", default="no",
            ):
                return

        self.running = True
        self.start_btn.config(state="disabled")
        self.progress["value"] = 0
        self.progress["maximum"] = len(todo)
        self.total_start = time.time()
        self.total_end = None

        self.worker_thread = threading.Thread(
            target=self._worker,
            args=(todo, fmt_key, suffix, delete_original),
            daemon=True,
        )
        self.worker_thread.start()

    def _worker(self, todo, fmt_key, suffix, delete_original):
        ff = locate_ffmpeg()
        ext, codec_args, need_encode = FORMATS[fmt_key]
        total = len(todo)
        ok = fail = 0
        fail_details = []

        for i, task in enumerate(todo):
            src = task["src"]
            start_t = time.time()
            self.msg_queue.put(("start", task))
            self.msg_queue.put(("status", f"({i + 1}/{total}) 正在转换：{os.path.basename(src)}"))

            try:
                out_ext = ext
                if not need_encode:
                    codec, hint = probe_audio_ext(ff, src)
                    if codec is None:
                        raise RuntimeError("未检测到音频流")
                    out_ext = hint

                base = os.path.splitext(os.path.basename(src))[0]
                dirname = os.path.dirname(src)
                out_path = os.path.join(dirname, f"{base}{suffix}.{out_ext}")
                if os.path.abspath(out_path).lower() == os.path.abspath(src).lower():
                    out_path = os.path.join(dirname, f"{base}{suffix}_audio.{out_ext}")

                cmd = [ff, "-y", "-hide_banner", "-loglevel", "error",
                       "-i", src, "-vn"] + codec_args + [out_path]
                proc = subprocess.Popen(
                    cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    universal_newlines=True, creationflags=_CREATE_NO_WINDOW,
                )
                _, err = proc.communicate()
                if proc.returncode != 0:
                    last = err.strip().splitlines()[-1] if err.strip() else "未知错误"
                    raise RuntimeError(last[:200])
                if not os.path.isfile(out_path):
                    raise RuntimeError("输出文件未生成")

                out_size = os.path.getsize(out_path)
                elapsed = time.time() - start_t

                del_note = ""
                if delete_original:
                    try:
                        os.remove(src)
                        del_note = "（原视频已删除）"
                    except Exception as e:
                        del_note = f"（删除原视频失败：{e}）"

                ok += 1
                self.msg_queue.put(("done", task, out_size, elapsed, del_note))
            except Exception as e:
                elapsed = time.time() - start_t
                err_msg = str(e)[:240]
                fail += 1
                fail_details.append(f"• {os.path.basename(src)}\n    → {err_msg}")
                self.msg_queue.put(("fail", task, elapsed, err_msg))

            self.msg_queue.put(("progress", i + 1))

        self.msg_queue.put(("finish", ok, fail, fail_details))

    # ---------- 消息处理 ----------
    def _poll_messages(self):
        try:
            while True:
                msg = self.msg_queue.get_nowait()
                kind = msg[0]
                if kind == "start":
                    task = msg[1]
                    with self.task_lock:
                        task["status"] = "转换中"
                        task["started_at"] = time.time()
                        task["elapsed"] = None
                        task["out_size"] = None
                        task["msg"] = ""
                    self._update_row(task)
                elif kind == "done":
                    _, task, out_size, elapsed, del_note = msg
                    with self.task_lock:
                        task["status"] = "完成" + del_note
                        task["out_size"] = out_size
                        task["elapsed"] = elapsed
                    self._update_row(task)
                elif kind == "fail":
                    _, task, elapsed, err = msg
                    with self.task_lock:
                        task["status"] = "失败"
                        task["elapsed"] = elapsed
                        task["out_size"] = None
                        task["msg"] = err
                    self._update_row(task)
                elif kind == "status":
                    self._set_status(msg[1])
                elif kind == "progress":
                    self.progress["value"] = msg[1]
                elif kind == "finish":
                    _, ok, fail, details = msg
                    self.total_end = time.time()
                    self.running = False
                    self.start_btn.config(state="normal")
                    self._set_status(f"全部完成：成功 {ok}，失败 {fail}")
                    if details:
                        messagebox.showwarning(
                            "部分任务失败",
                            "以下视频转换失败：\n\n" + "\n".join(details)
                        )
        except queue.Empty:
            pass
        self.root.after(80, self._poll_messages)

    def _update_row(self, task):
        iid = task.get("iid")
        if not iid or not self.tree.exists(iid):
            return
        self.tree.item(
            iid,
            values=self._row_values(task),
            tags=(self._tag_for(task["status"]),),
        )

    # ---------- 总计时与状态栏 ----------
    def _elapsed_total(self):
        if self.total_start is None:
            return 0
        end = self.total_end if self.total_end is not None else time.time()
        return end - self.total_start

    def _set_status(self, text):
        self.status_var.set(f"{text}  |  总用时：{fmt_dur(self._elapsed_total())}")

    def _tick_total(self):
        """转换过程中每秒刷新状态栏里的总用时。"""
        if self.running and self.total_end is None:
            cur = self.status_var.get()
            idx = cur.rfind("  |  总用时：")
            base = cur[:idx] if idx >= 0 else cur
            self.status_var.set(f"{base}  |  总用时：{fmt_dur(self._elapsed_total())}")
        self.root.after(500, self._tick_total)


def main():
    root = tk.Tk()
    try:
        ttk.Style(root).theme_use("clam")
    except Exception:
        pass
    VideoToAudioApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
