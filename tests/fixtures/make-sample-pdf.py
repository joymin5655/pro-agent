#!/usr/bin/env python3
"""Write tests/fixtures/sample.pdf: 3 pages of plain English text (stdlib only)."""
import os

PAGES = [
    ("Sample Report", "The first page says the harbor opens at seven in the morning."),
    ("Second Section", "The second page says the ferry carries forty passengers."),
    ("Third Section", "The third page says tickets cost twelve dollars."),
]


def build():
    objs = {1: "<< /Type /Catalog /Pages 2 0 R >>"}
    kids = []
    next_id = 4  # 3 = font
    for title, body in PAGES:
        page_id, content_id = next_id, next_id + 1
        next_id += 2
        kids.append("%d 0 R" % page_id)
        stream = ("BT /F1 20 Tf 72 720 Td (%s) Tj ET\n"
                  "BT /F1 12 Tf 72 690 Td (%s) Tj ET\n" % (title, body))
        objs[page_id] = ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                         "/Resources << /Font << /F1 3 0 R >> >> /Contents %d 0 R >>" % content_id)
        objs[content_id] = "<< /Length %d >>\nstream\n%sendstream" % (len(stream), stream)
    objs[2] = "<< /Type /Pages /Kids [%s] /Count %d >>" % (" ".join(kids), len(PAGES))
    objs[3] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    out = bytearray(b"%PDF-1.4\n")
    offsets = {}
    for i in sorted(objs):
        offsets[i] = len(out)
        out += ("%d 0 obj\n%s\nendobj\n" % (i, objs[i])).encode("latin-1")
    xref = len(out)
    out += ("xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)).encode()
    for i in sorted(objs):
        out += ("%010d 00000 n \n" % offsets[i]).encode()
    out += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objs) + 1, xref)).encode()
    return bytes(out)


if __name__ == "__main__":
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sample.pdf")
    with open(path, "wb") as f:
        f.write(build())
