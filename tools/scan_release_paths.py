"""Look for build-machine paths in release files, including inside archives.

    python tools/scan_release_paths.py <file> [<file> ...]

Every file is read whole; a U-Boot-wrapped gzip cpio (rootfs.cpio.gz.u-boot), a .tar.gz and a zip
(.xsa) are opened and each member is scanned on its own. Only printable runs of 6 or more characters
are searched (like `strings`), for a home directory other than the board's own (/home/root,
/home/petalinux), a WSL mount (/mnt/c/ ...) or a Windows drive path (C:\\...\\ or C:/.../, the
letter not preceded by a letter, digit or %, so that glibc's "%N:/usr/..." does not count). Prints
one line per hit (at most 3 per member), one line per file, then the total; exit status 1 if
anything was found.
"""
import gzip
import io
import re
import sys
import tarfile
import zipfile

RUNS = re.compile(rb'[\x20-\x7e]{6,}')
PATH = re.compile(rb'/home/(?!root/|petalinux/|root\b|petalinux\b)[a-z][a-z0-9_-]*/'
                  rb'|/mnt/[a-z]/'
                  rb'|(?<![%A-Za-z0-9_])[A-Z]:[\\/][A-Za-z0-9_.-]{2,}[\\/]')


def hits(data):
    out = []
    for run in RUNS.findall(data):
        for m in PATH.finditer(run):
            out.append(run[max(0, m.start() - 20):m.end() + 30].decode('ascii', 'replace'))
    return out


def cpio_members(data):
    """Members of a "newc" cpio archive."""
    i = 0
    while i + 110 <= len(data) and data[i:i + 6] in (b'070701', b'070702'):
        size = int(data[i + 54:i + 62], 16)
        nlen = int(data[i + 94:i + 102], 16)
        name = data[i + 110:i + 110 + nlen - 1].decode('utf-8', 'replace')
        j = (i + 110 + nlen + 3) & ~3
        if name == 'TRAILER!!!':
            return
        yield name, data[j:j + size]
        i = (j + size + 3) & ~3


def members(path, data):
    if path.endswith('.cpio.gz.u-boot'):
        yield from cpio_members(gzip.decompress(data[64:]))       # 64-byte U-Boot header
    elif path.endswith('.tar.gz'):
        with tarfile.open(fileobj=io.BytesIO(data)) as t:
            for m in t.getmembers():
                if m.isfile():
                    yield m.name, t.extractfile(m).read()
    elif path.endswith('.xsa') or path.endswith('.zip'):
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for n in z.namelist():
                yield n, z.read(n)
    else:
        yield '', data


total = 0
for path in sys.argv[1:]:
    data = open(path, 'rb').read()
    n_members = 0
    for name, body in members(path, data):
        n_members += 1
        h = hits(body)
        total += len(h)
        for s in h[:3]:
            print('%s:%s: %s' % (path.replace('\\', '/').split('/')[-1], name, s))
    print('%-28s %6d member(s) scanned' % (path.replace('\\', '/').split('/')[-1], n_members))
print('TOTAL build paths found: %d' % total)
sys.exit(1 if total else 0)
