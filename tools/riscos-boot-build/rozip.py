#!/usr/bin/env python3
"""Pack a HostFS ,xxx tree into a RISC OS zip for single-file deployment.

Writes each file's RISC OS filetype into the Info-ZIP/SparkFS Acorn extra-field
(header 0x4341 'AC', payload 'ARC0' + load + exec + attr) so a RISC OS unzipper
(!SparkFS, !SparkPlug, InfoZip) restores the type on extraction -- turning a
fragile 3600-file HostFS copy into one copy + one unzip.

Host<->RISC OS name mapping is already correct: HostFS stores RISC OS '.' (dir
sep) as host '/', and RISC OS '/' (a name char, e.g. "search/htm") as host '.'.
A zip uses '/' for dirs too, so the host relative path IS the RISC OS zip name.
We only strip the ,xxx filetype suffix off the leaf and move it into the field.
"""
import os, sys, zipfile, struct


def acorn_extra(ftype: int) -> bytes:
    load = 0xFFF00000 | ((ftype & 0xFFF) << 8)   # typed file, datestamp top byte 0
    execa = 0                                     # datestamp = 0 (1900); irrelevant to function
    attr = 0x03                                   # owner read+write
    body = b'ARC0' + struct.pack('<III', load, execa, attr)
    return struct.pack('<HH', 0x4341, len(body)) + body


def split_type(leaf: str):
    if len(leaf) >= 4 and leaf[-4] == ',':
        try:
            return leaf[:-4], int(leaf[-3:], 16)
        except ValueError:
            pass
    return leaf, None


def main(srcdir, outzip):
    n = typed = 0
    with zipfile.ZipFile(outzip, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in sorted(os.walk(srcdir)):
            for fn in sorted(files):
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, srcdir)
                base, ftype = split_type(fn)
                name = os.path.join(os.path.dirname(rel), base).replace(os.sep, '/')
                zi = zipfile.ZipInfo(name)
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = 0o644 << 16
                if ftype is not None:
                    zi.extra = acorn_extra(ftype)
                    typed += 1
                with open(full, 'rb') as f:
                    zf.writestr(zi, f.read())
                n += 1
    print(f"wrote {outzip}: {n} files ({typed} typed)")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit("usage: rozip.py <srcdir> <out.zip>")
    main(sys.argv[1], sys.argv[2])
