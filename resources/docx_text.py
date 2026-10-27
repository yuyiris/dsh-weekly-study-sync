# -*- coding: utf-8 -*-
"""docx_text.py — 把 .docx 还原成纯文本（零依赖：zipfile + 正则）。

用法:
    python docx_text.py "<input.docx>" [-o "<output.txt>"]
"""
import argparse
import io
import os
import re
import zipfile


def docx_to_text(path: str) -> str:
    with zipfile.ZipFile(path) as z:
        xml = z.read("word/document.xml").decode("utf-8", "replace")

    t = re.sub(r"<w:br[^>]*/>", "\n", xml)
    t = t.replace("</w:p>", "\n")
    t = re.sub(r"<w:tab[^>]*/>", "    ", t)
    t = re.sub(r"<w:tc[^>]*>", " | ", t)
    t = re.sub(r"<[^>]+>", "", t)
    t = (t.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
          .replace("&quot;", '"').replace("&apos;", "'"))
    t = re.sub(r"(\n\s*){2,}", "\n\n", t)
    return t.strip()


def main():
    ap = argparse.ArgumentParser(description="Extract plain text from a .docx file.")
    ap.add_argument("input")
    ap.add_argument("-o", "--output", default=None)
    args = ap.parse_args()

    text = docx_to_text(args.input)
    out = args.output or (os.path.splitext(args.input)[0] + ".txt")
    with io.open(out, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {out} ({len(text)} chars)")


if __name__ == "__main__":
    main()
