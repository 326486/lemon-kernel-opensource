#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 日志生命周期轮换 v1.1 (261114 千问) — #418 + 尺寸帽（自主稳态）
# 归档迁出 logs 树（/data/lemonbrain/toolout_archive）；按龄+按尺寸双重轮换；dry-run 默认
import os, sys, time, json, shutil, argparse

TOOLOUT = "/data/lemonbrain/logs/toolout"
TOOLOUT_ARC = "/data/lemonbrain/toolout_archive"
SCAN = "/data/小柠檬资源/小柠檬bug检测/扫描记录"
SCAN_ARC = "/data/小柠檬资源/小柠檬bug检测/扫描记录_archive"

def dir_size_mb(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total / (1024 * 1024)

def rotate_dir(src, archive, days, dry=True):
    moved = 0
    if not os.path.isdir(src):
        return 0
    cutoff = time.time() - days * 86400
    if not dry:
        os.makedirs(archive, exist_ok=True)
    for name in os.listdir(src):
        p = os.path.join(src, name)
        if not os.path.isfile(p):
            continue
        try:
            if os.path.getmtime(p) < cutoff:
                if not dry:
                    shutil.move(p, os.path.join(archive, name))
                moved += 1
        except OSError:
            continue
    return moved

def rotate_by_size(src, archive, max_mb, dry=True):
    if not os.path.isdir(src):
        return 0
    cur = dir_size_mb(src)
    if cur <= max_mb:
        return 0
    if not dry:
        os.makedirs(archive, exist_ok=True)
    files = []
    for name in os.listdir(src):
        p = os.path.join(src, name)
        if os.path.isfile(p):
            try:
                files.append((os.path.getmtime(p), name, p))
            except OSError:
                pass
    files.sort()
    moved = 0
    for mt, name, p in files:
        if cur <= max_mb:
            break
        try:
            sz = os.path.getsize(p) / (1024 * 1024)
            if not dry:
                shutil.move(p, os.path.join(archive, name))
            cur -= sz
            moved += 1
        except OSError:
            pass
    return moved

def purge_archive(archive, days, dry=True):
    purged = 0
    if not os.path.isdir(archive):
        return 0
    cutoff = time.time() - days * 86400
    for name in os.listdir(archive):
        p = os.path.join(archive, name)
        if not os.path.isfile(p):
            continue
        try:
            if os.path.getmtime(p) < cutoff:
                if not dry:
                    os.remove(p)
                purged += 1
        except OSError:
            continue
    return purged

def run(toolout_days=7, scan_days=30, purge_days=30, toolout_max_mb=12, dry=True,
        toolout=TOOLOUT, toolout_arc=TOOLOUT_ARC, scan=SCAN, scan_arc=SCAN_ARC):
    return {
        "dry_run": dry,
        "toolout_moved_age": rotate_dir(toolout, toolout_arc, toolout_days, dry),
        "toolout_moved_size": rotate_by_size(toolout, toolout_arc, toolout_max_mb, dry),
        "scan_moved": rotate_dir(scan, scan_arc, scan_days, dry),
        "toolout_archive_purged": purge_archive(toolout_arc, purge_days, dry),
        "scan_archive_purged": purge_archive(scan_arc, purge_days, dry),
        "toolout_mb_after": round(dir_size_mb(toolout), 1),
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--toolout-days", type=int, default=7)
    ap.add_argument("--scan-days", type=int, default=30)
    ap.add_argument("--purge-days", type=int, default=30)
    ap.add_argument("--toolout-max-mb", type=float, default=12)
    a = ap.parse_args()
    print(json.dumps(run(a.toolout_days, a.scan_days, a.purge_days, a.toolout_max_mb, dry=not a.apply), ensure_ascii=False))

if __name__ == "__main__":
    main()