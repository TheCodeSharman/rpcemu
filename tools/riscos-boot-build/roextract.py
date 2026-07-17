#!/usr/bin/env python3
"""RISC OS zip -> HostFS tree extractor.

RISC OS zips (created by Info-ZIP/SparkFS) store each file's load/exec addresses
in an Acorn extra-field, NOT in the filename.  A plain `unzip` therefore drops
every filetype.  This module reads that extra-field, recovers the filetype and
datestamp, and writes files named with the HostFS `,xxx` suffix so the result
drops straight onto RPCEmu's HostFS with correct types -- no renaming.

Acorn extra-field: header id 0x4341 ('AC'); payload = 'ARC0' signature then
load(4), exec(4), attr(4) little-endian.  A typed file has load = 0xFFFtttXX,
so filetype = (load>>8)&0xFFF and the 40-bit datestamp = ((load&0xFF)<<32)|exec
(centiseconds since 1900).  A load without 0xFFF at top is a real load/exec pair
(no filetype, no datestamp).
"""
import zipfile, struct, os

# Python 3.13's zipfile validates extra-fields strictly at open time and rejects
# some older RISC OS zips (e.g. the RISCOS-Ltd 1999 ro4install.zip) with
# "Corrupt extra field". We recover the Acorn filetype from the raw extra-field
# bytes ourselves (acorn_meta below) and never rely on the stdlib's decode, so
# make it lenient rather than fatal -- otherwise the archive can't even be opened.
_zi_decodeExtra = zipfile.ZipInfo._decodeExtra
def _lenient_decodeExtra(self, *a, **k):
    try:
        return _zi_decodeExtra(self, *a, **k)
    except Exception:
        pass
zipfile.ZipInfo._decodeExtra = _lenient_decodeExtra


def acorn_meta(extra: bytes):
    """Return {load, exec, ftype, stamp} from the Acorn extra-field, or None."""
    i = 0
    while i + 4 <= len(extra):
        hid, sz = struct.unpack_from('<HH', extra, i)
        body = extra[i + 4:i + 4 + sz]
        if hid == 0x4341 and body[:4] == b'ARC0' and len(body) >= 16:
            load, execa, attr = struct.unpack_from('<III', body, 4)
            if (load & 0xFFF00000) == 0xFFF00000:
                ftype = (load >> 8) & 0xFFF
                stamp = ((load & 0xFF) << 32) | execa
            else:
                ftype, stamp = None, None
            return {'load': load, 'exec': execa, 'ftype': ftype, 'stamp': stamp}
        i += 4 + sz
    return None


def hostfs_basename(basename: str, meta) -> str:
    """Append the HostFS ,xxx suffix for a typed file; leave untyped names alone."""
    if meta and meta.get('ftype') is not None:
        return f"{basename},{meta['ftype']:03x}"
    return basename


def extract(zippath, destdir, strip: str = '', only=None):
    """Extract `zippath` into `destdir` with HostFS ,xxx names.

    `strip` is a leading path prefix removed from every entry (e.g. 'HardDisc4/').
    `only`, if given, is a list of post-strip path prefixes; entries outside them
    are skipped (so a huge bundle can yield just the few subtrees we want).
    Returns a manifest {output_relative_path_with_xxx: meta}.
    """
    z = zipfile.ZipFile(zippath)
    manifest = {}
    for info in z.infolist():
        name = info.filename
        if strip and name.startswith(strip):
            name = name[len(strip):]
        if not name:
            continue
        if only is not None:
            nm = name.rstrip('/')
            if not any(nm == p or nm.startswith(p + '/') for p in only):
                continue
        if name.endswith('/'):
            # Directory entry. Recreate it even when empty -- RISC OS zips carry
            # meaningful empty dirs (e.g. the ROxxxHook.Res/.Apps folders that the
            # boot Filer_Boots, !Boot.Choices, Public), and skipping them would
            # silently drop those from the tree.
            os.makedirs(os.path.join(destdir, *name.rstrip('/').split('/')), exist_ok=True)
            continue
        meta = acorn_meta(info.extra)
        parts = name.split('/')
        parts[-1] = hostfs_basename(parts[-1], meta)
        rel = '/'.join(parts)
        outpath = os.path.join(destdir, *parts)
        os.makedirs(os.path.dirname(outpath), exist_ok=True)
        with open(outpath, 'wb') as f:
            f.write(z.read(info))
        manifest[rel] = meta
    return manifest


if __name__ == '__main__':
    import sys
    if len(sys.argv) < 3:
        sys.exit("usage: roextract.py <zip> <destdir> [strip-prefix]")
    m = extract(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else '')
    typed = sum(1 for v in m.values() if v and v.get('ftype') is not None)
    print(f"extracted {len(m)} files ({typed} typed) to {sys.argv[2]}")
