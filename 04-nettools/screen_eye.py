#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# screen_eye 屏幕感知 v1.0 (261115 千问) — 给内核装眼睛：截屏+视觉理解
# capture: screencap->PNG+尺寸元数据（图存设备本地）；understand: 截屏->多模态模型读图
import os, json, time, struct, subprocess, base64, uuid
DIR = "/data/lemonbrain/autonomic"
SHOTS = os.path.join(DIR, "screenshots")
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

def capture(path=None, now=None):
    now = now if now is not None else time.time()
    try:
        os.makedirs(SHOTS, exist_ok=True)
    except Exception:
        pass
    if path is None:
        path = os.path.join(SHOTS, "shot_%d_%s.png" % (int(now), uuid.uuid4().hex[:8]))
    try:
        subprocess.run(["screencap", "-p", path], capture_output=True, timeout=30)
    except Exception:
        pass
    if not os.path.exists(path):
        return {"ok": False, "error": "screencap failed", "path": path}
    w = h = 0
    try:
        head = open(path, "rb").read(33)
        if head[:8] == PNG_MAGIC:
            w, h = struct.unpack(">II", head[16:24])
    except Exception:
        pass
    return {"ok": True, "path": path, "width": w, "height": h,
            "bytes": os.path.getsize(path), "ts": now}

def understand(prompt="描述这个屏幕的内容", model="qwen3.8-27b", path=None, max_tokens=500):
    if path and os.path.exists(path):
        cap = {"ok": True, "path": path}
    else:
        cap = capture(path)
    if not cap.get("ok"):
        return {"ok": False, "error": "capture failed"}
    try:
        img_b64 = base64.b64encode(open(cap["path"], "rb").read()).decode()
    except Exception as e:
        return {"ok": False, "error": "read image: " + type(e).__name__}
    content = [{"type": "text", "text": prompt},
               {"type": "image_url", "image_url": {"url": "data:image/png;base64," + img_b64}}]
    try:
        import ai_vision
        desc = ai_vision.call(model, content, max_tokens)
    except Exception as e:
        desc = "[error:%s]" % type(e).__name__
    return {"ok": True, "path": cap["path"], "model": model, "description": desc}

def main():
    import sys
    a = sys.argv[1:]
    mode = a[0] if a else "understand"
    if mode == "capture":
        print(json.dumps(capture(), ensure_ascii=False))
    else:
        prompt = a[1] if len(a) > 1 and a[1] else "描述这个屏幕的内容"
        model = a[2] if len(a) > 2 and a[2] else "qwen3.8-27b"
        print(json.dumps(understand(prompt, model), ensure_ascii=False))

if __name__ == "__main__":
    main()