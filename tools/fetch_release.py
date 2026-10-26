#!/usr/bin/env python3
"""Download the release assets listed in tools/release_assets.json, check their SHA-256, and put
each one where the scripts of this tree expect it (paths under artifacts/, models/, golden/ and
train/, all ignored by git).

    python tools/fetch_release.py                      # everything (about 125 MB)
    python tools/fetch_release.py --group boot model   # only the boot files and the exported model
    python tools/fetch_release.py --from-dir <dir>     # assets already downloaded by hand into <dir>
    python tools/fetch_release.py --check              # only verify the files already in place

Groups: boot (BOOT.BIN, bitstream, XSA, kernel, device trees, boot script, root file system), kit
(the board kit), model (the two exported weight files of models/mbv2_pose and the backbone weights
in the accelerator's layout), checkpoints (PyTorch checkpoints of the pose and task models).

The base URL is the GitHub release of the version in the manifest; --url or the environment
variable TERNPOSE_RELEASE_URL overrides it (for a mirror or a fork). Standard library only.
A file whose hash does not match is deleted and reported; the script exits non-zero.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "tools", "release_assets.json")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, dst):
    tmp = dst + ".part"
    with urllib.request.urlopen(url) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    os.replace(tmp, dst)


def main():
    m = json.load(open(MANIFEST, encoding="utf-8"))
    groups = sorted({a["group"] for a in m["assets"]})
    ap = argparse.ArgumentParser(description="fetch and verify the release assets of zynq-ternary-mobilenet-codesign")
    ap.add_argument("--group", nargs="+", choices=groups, help="only these groups (default: all)")
    ap.add_argument("--url", default=os.environ.get("TERNPOSE_RELEASE_URL", m["base_url"]),
                    help="base URL of the release assets (default: %(default)s)")
    ap.add_argument("--from-dir", help="take the assets from this directory instead of downloading")
    ap.add_argument("--check", action="store_true", help="only verify the files already in place")
    ap.add_argument("--force", action="store_true", help="fetch again even when a matching file is in place")
    a = ap.parse_args()

    bad = 0
    for asset in m["assets"]:
        if a.group and asset["group"] not in a.group:
            continue
        dst = os.path.join(ROOT, *asset["dest"].split("/"))
        if os.path.isfile(dst) and not a.force and sha256(dst) == asset["sha256"]:
            print("ok       %-36s %s" % (asset["name"], asset["dest"]))
            continue
        if a.check:
            print("%-8s %-36s %s" % ("missing" if not os.path.isfile(dst) else "DIFFERS", asset["name"], asset["dest"]))
            bad += 1
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with tempfile.TemporaryDirectory(dir=os.path.dirname(dst)) as td:
            tmp = os.path.join(td, asset["name"])
            try:
                if a.from_dir:
                    shutil.copyfile(os.path.join(a.from_dir, asset["name"]), tmp)
                else:
                    print("fetch    %-36s %d bytes" % (asset["name"], asset["size"]))
                    download(a.url.rstrip("/") + "/" + asset["name"], tmp)
            except (OSError, ValueError) as e:
                print("FAILED   %-36s %s" % (asset["name"], e))
                bad += 1
                continue
            got = sha256(tmp)
            if got != asset["sha256"]:
                print("BAD HASH %-36s got %s, want %s (file discarded)" % (asset["name"], got[:16], asset["sha256"][:16]))
                bad += 1
                continue
            os.replace(tmp, dst)
        print("ok       %-36s %s" % (asset["name"], asset["dest"]))
    if bad:
        sys.exit("%d asset(s) missing or wrong" % bad)
    print("all requested assets in place and verified")


if __name__ == "__main__":
    main()
