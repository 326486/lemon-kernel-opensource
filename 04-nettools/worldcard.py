#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
worldcard.py — 小柠檬内核 · 世界卡检索助脚 v1.0 (261106)
资产: /data/adb/lemon_kernel/assets/worldcard/ (382条攻防词条世界卡 + A/B词条卡 + NULL角色卡 + 攻防文本)
用法:
  worldcard.py query <关键词>...              # keys/secondary_keys 匹配(大小写不敏感), 返回前5条
  worldcard.py list [页码=1]                    # 词条索引(id+comment+keys), 每页40条
  worldcard.py read <id>                        # 读词条全文
  worldcard.py asset <a|b|null|text> [关键词]    # 读资产(a/b=词条卡tags, null=角色卡, text=攻防文本可按行过滤)
出口: 正常=0 参数错=2 加载失败=3 未命中=4
防空转自检: 全部单遍有限遍历(词条382条/资产单文件), 无 while, 有界 readline。
"""
import json, sys, os

BASE = "/data/adb/lemon_kernel/assets/worldcard"
WCPATH = os.path.join(BASE, "渗透世界卡.json")
ASSETS = {"a": "A渗透工具词条.json", "b": "B渗透工具词条.json",
          "null": "NULL渗透.json", "text": "渗透文本完整.txt"}
PAGE = 40

def out(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False, indent=1))
    sys.exit(code)

def norm(s):
    return str(s).strip().lower()

def load_wc():
    try:
        with open(WCPATH, encoding="utf-8") as f:
            d = json.load(f)
        if not isinstance(d.get("entries"), list):
            raise ValueError("entries非列表")
        return d
    except Exception as e:
        out({"error": "load_fail", "detail": str(e)}, 3)

def main():
    av = sys.argv[1:]
    if not av:
        out({"error": "no_mode", "modes": ["query 关键词...", "list [页码]", "read <id>", "asset <a|b|null|text> [关键词]"]}, 2)
    mode = av[0]

    if mode == "query":
        if len(av) < 2:
            out({"error": "no_keywords"}, 2)
        words = [norm(x) for x in av[1:]]
        d = load_wc()
        ents = d["entries"]
        hits = []
        for e in ents:  # 单遍有界遍历(382条)
            ks = [norm(x) for x in (e.get("keys") or [])]
            ks += [norm(x) for x in (e.get("secondary_keys") or [])]
            if any((w in k or k in w) for w in words for k in ks):
                hits.append(e)
        r = {"total_entries": len(ents), "matched": len(hits), "shown": min(5, len(hits))}
        r["hits"] = [{"id": e.get("id"), "comment": e.get("comment"), "keys": e.get("keys"),
                      "content": str(e.get("content", ""))[:1500]} for e in hits[:5]]
        if not hits:
            r["note"] = "未命中, 换关键词或用 list 浏览"
        elif len(hits) > 5:
            r["note"] = "content截断1500字, 全文用 worldcard_read 按 id 取"
        out(r, 0 if hits else 4)

    elif mode == "list":
        page = 1
        if len(av) > 1:
            try:
                page = int(av[1])
            except ValueError:
                out({"error": "bad_page"}, 2)
        if page < 1:
            page = 1
        d = load_wc()
        ents = d["entries"]
        s, t = (page - 1) * PAGE, (page - 1) * PAGE + PAGE
        out({"name": d.get("name"), "total": len(ents), "page": page,
             "pages": (len(ents) + PAGE - 1) // PAGE,
             "items": [{"id": e.get("id"), "comment": e.get("comment"),
                        "keys": (e.get("keys") or [])[:4]} for e in ents[s:t]]}, 0)

    elif mode == "read":
        if len(av) < 2:
            out({"error": "no_id"}, 2)
        try:
            tid = int(av[1])
        except ValueError:
            out({"error": "bad_id"}, 2)
        d = load_wc()
        for e in d["entries"]:  # 单遍有界
            if e.get("id") == tid:
                out({"id": tid, "comment": e.get("comment"), "keys": e.get("keys"),
                     "secondary_keys": e.get("secondary_keys"),
                     "position": e.get("position"), "enabled": e.get("enabled"),
                     "content": e.get("content", "")}, 0)
        out({"error": "not_found", "id": tid}, 4)

    elif mode == "asset":
        which = av[1] if len(av) > 1 else ""
        if which not in ASSETS:
            out({"error": "bad_asset", "valid": list(ASSETS)}, 2)
        kw = norm(av[2]) if len(av) > 2 else ""
        path = os.path.join(BASE, ASSETS[which])
        try:
            with open(path, encoding="utf-8") as f:
                raw = f.read()
        except Exception as e:
            out({"error": "read_fail", "detail": str(e)}, 3)
        if which == "text":
            lines = raw.splitlines()
            if kw:
                seg = [l for l in lines if kw in norm(l)][:120]
                out({"asset": "text", "total_lines": len(lines), "kw_filter": kw,
                     "matched_lines": len(seg), "content": "\n".join(seg)[:6000]}, 0)
            else:
                out({"asset": "text", "total_lines": len(lines),
                     "content": "\n".join(lines[:800])[:6000],
                     "note": "超过800行, 用关键词过滤 asset text <kw>"}, 0)
        else:
            try:
                j = json.loads(raw)
            except Exception as e:
                out({"error": "json_fail", "detail": str(e)}, 3)
            if which in ("a", "b"):
                tags = j.get("tags", [])
                shown = [t for t in tags if (not kw) or kw in norm(str(t.get("name", "")) + str(t.get("description", "")))]
                out({"asset": which, "format": j.get("format"), "total_tags": len(tags),
                     "shown": min(10, len(shown)),
                     "tags": [{"name": t.get("name"),
                               "description": str(t.get("description", ""))[:400],
                               "content": str(t.get("content", ""))[:800]} for t in shown[:10]]}, 0)
            else:
                dat = j.get("data", {})
                core = {}
                for k in ("name", "description", "personality", "scenario", "first_mes", "creator_notes"):
                    v = dat.get(k)
                    if v is not None:
                        core[k] = str(v)[:1200]
                out({"asset": "null", "spec": j.get("spec"), "data_fields": list(dat.keys()),
                     "core": core}, 0)
    else:
        out({"error": "bad_mode", "modes": ["query", "list", "read", "asset"]}, 2)

if __name__ == "__main__":
    main()