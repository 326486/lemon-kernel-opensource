#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""柠檬内核 文档工具引擎 (doc_* 插件后端)
来源: 取长补短并入一加「文档」App(andes.oplus.documentsreader v16.8.32) 的
     文档处理能力思路(Pdfium/PDFBox/永中), 自研纯 Python 轻量实现。
子命令:
  text <path> [maxchars]   提取文本(默认4000字符)
  info <path>              文档信息(类型/大小/页数)
铁律: 单文件处理无目录遍历 | 大小上限100MB | 截断哨兵防空转 | fail-closed
"""
import sys, os, zipfile, re, time

MAX_SIZE = 100 * 1024 * 1024
TAG = re.compile(r'<[^>]+>')


def die(msg):
    print("ERROR: " + msg)
    sys.exit(1)


def sniff(path):
    if not os.path.isfile(path):
        die("文件不存在: " + path)
    if os.path.getsize(path) > MAX_SIZE:
        die("文件过大(>100MB): " + path)
    with open(path, 'rb') as f:
        h = f.read(64)
    if h.startswith(b'%PDF'):
        return 'pdf'
    if h[:2] == b'PK':
        try:
            names = zipfile.ZipFile(path).namelist()
        except Exception:
            return 'zip'
        if any(n.startswith('word/') for n in names):
            return 'docx'
        if any(n.startswith('xl/') for n in names):
            return 'xlsx'
        if any(n.startswith('ppt/slides') for n in names):
            return 'pptx'
        if 'mimetype' in names:
            return 'epub'
        return 'zip'
    try:
        h.decode('utf-8')
        return 'txt'
    except Exception:
        return 'bin'


def xml_texts(zf, names, tags, cap):
    """从 zip 内 XML 提取指定标签文本, cap 为累计上限(防空转)"""
    from xml.etree import ElementTree as ET
    buf = []
    total = 0
    for n in names:
        if total > cap:
            break
        try:
            root = ET.fromstring(zf.read(n))
        except Exception:
            continue
        for el in root.iter():
            t = el.tag.split('}')[-1]
            if t in tags and el.text:
                buf.append(el.text)
                total += len(el.text)
                if total > cap:
                    break
    return buf


def pdf_text(path, maxc):
    try:
        from pypdf import PdfReader
    except ImportError:
        die('缺少 pypdf, 请在 Termux 执行: pip install pypdf')
    r = PdfReader(path)
    out, total = [], 0
    for i, p in enumerate(r.pages, 1):
        t = (p.extract_text() or '').strip()
        if t:
            out.append("[第%d页] %s" % (i, t))
            total += len(t)
        if total > maxc:
            break
    return "\n".join(out), len(r.pages)


def docx_text(path, maxc):
    with zipfile.ZipFile(path) as zf:
        buf = xml_texts(zf, ['word/document.xml'], {'t'}, maxc * 2)
    return "\n".join(buf), len(buf)


def pptx_text(path, maxc):
    with zipfile.ZipFile(path) as zf:
        names = sorted(n for n in zf.namelist()
                       if re.match(r'ppt/slides/slide\d+\.xml$', n))
        out = []
        for i, n in enumerate(names, 1):
            buf = xml_texts(zf, [n], {'t'}, maxc * 2)
            if buf:
                out.append("[幻灯片%d] %s" % (i, " ".join(buf)))
    return "\n".join(out), len(names)


def xlsx_text(path, maxc):
    with zipfile.ZipFile(path) as zf:
        names = [n for n in zf.namelist()
                 if 'sharedStrings' in n or n.startswith('xl/worksheets/')]
        buf = xml_texts(zf, names, {'t', 'v'}, maxc * 2)
    return "\n".join(buf), len(names)


def epub_text(path, maxc):
    with zipfile.ZipFile(path) as zf:
        names = sorted(n for n in zf.namelist()
                       if n.endswith(('.xhtml', '.html', '.htm')))
        out, total = [], 0
        for n in names:
            if total > maxc:
                break
            try:
                x = zf.read(n).decode('utf-8', 'ignore')
            except Exception:
                continue
            t = re.sub(r'\n{3,}', '\n\n', TAG.sub('', x)).strip()
            if t:
                out.append(t)
                total += len(t)
    return "\n\n".join(out), len(names)


def main():
    if len(sys.argv) < 3:
        die("用法: doc_tool.py text|info <path> [maxchars]")
    cmd, path = sys.argv[1], sys.argv[2]
    try:
        maxc = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].strip() else 4000
    except ValueError:
        die("maxchars 须为整数")
    if maxc <= 0:
        maxc = 4000
    kind = sniff(path)
    size = os.path.getsize(path)
    if cmd == 'info':
        extra = ""
        if kind == 'pdf':
            try:
                from pypdf import PdfReader
                extra = "页数: %d" % len(PdfReader(path).pages)
            except Exception as e:
                extra = "页数: 读取失败(%s)" % e
        print("路径: %s\n类型: %s\n大小: %d 字节 (%.1f KB)\n修改: %s\n%s" % (
            path, kind, size, size / 1024.0,
            time.strftime('%Y-%m-%d %H:%M:%S',
                         time.localtime(os.path.getmtime(path))), extra))
        return
    if cmd != 'text':
        die("未知子命令: " + cmd)
    fn = {'pdf': pdf_text, 'docx': docx_text, 'pptx': pptx_text,
          'xlsx': xlsx_text, 'epub': epub_text}
    if kind in fn:
        body, _ = fn[kind](path, maxc)
    elif kind == 'txt':
        body = open(path, encoding='utf-8', errors='ignore').read()
    else:
        die("不支持的类型: %s (支持 pdf/docx/pptx/xlsx/epub/txt)" % kind)
    n = len(body)
    if n > maxc:
        print("[截断] 全文 %d 字符, 显示前 %d (调大 maxchars 取更多)" % (n, maxc))
        print(body[:maxc])
    else:
        print(body)


if __name__ == '__main__':
    main()