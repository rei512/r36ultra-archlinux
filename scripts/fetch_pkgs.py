#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Collect Arch Linux ARM (aarch64) packages for an offline `pacman -U` on the R36Ultra.

Resolves the dependency closure of the given targets against the core/extra/alarm
repos, skips what the device already has, and downloads the missing packages with
their signatures, checked against the SHA256 in the repo db.

--installed takes the device's `pacman -Q` output (name version per line). Installed
packages whose repo version differs are then fetched too, so that `pacman -U` of the
whole set upgrades the device as a whole (Arch does not support partial upgrades).
With names only (`pacman -Qq`) installed packages are assumed current, and versioned
dependencies they satisfy are only listed; pacman on the device checks them.

  ./fetch_pkgs.py --out pkgs/gui sway foot ttf-dejavu      # resolve + download
  ./fetch_pkgs.py --out pkgs/gui --dry-run sway            # resolve only
"""
import argparse
import hashlib
import pathlib
import re
import sys
import tarfile
import urllib.request

MIRROR = "http://mirror.archlinuxarm.org/aarch64"
REPOS = ["core", "extra", "alarm"]  # pacman.conf order on Arch Linux ARM: first match wins

# Virtual names offered by several packages: which provider to pull in.
PREFER = {
    "ttf-font": "ttf-dejavu",
    "opengl-driver": "mesa",
    "vulkan-driver": "vulkan-swrast",
}


def dep_name(dep):
    return re.split(r"[<>=]", dep, maxsplit=1)[0]


def parse_db(path, repo):
    # The ALARM dbs use the older layout: DEPENDS/PROVIDES live in a separate
    # "depends" file next to "desc", so merge both per package directory.
    entries = {}
    with tarfile.open(path) as tf:
        for member in tf:
            if not member.name.endswith(("/desc", "/depends")):
                continue
            fields = entries.setdefault(member.name.rsplit("/", 1)[0], {})
            for block in tf.extractfile(member).read().decode().strip().split("\n\n"):
                lines = block.split("\n")
                fields[lines[0].strip("%")] = lines[1:]
    pkgs = {}
    for entry, fields in entries.items():
        if "NAME" not in fields:  # seen in the ALARM extra.db: a zero-filled desc
            print(f"warning: {repo}.db: unreadable {entry}/desc, skipped", file=sys.stderr)
            continue
        pkgs[fields["NAME"][0]] = {
            "repo": repo,
            "name": fields["NAME"][0],
            "version": fields["VERSION"][0],
            "filename": fields["FILENAME"][0],
            "sha256": fields["SHA256SUM"][0],
            "csize": int(fields["CSIZE"][0]),
            "isize": int(fields.get("ISIZE", ["0"])[0]),
            "depends": fields.get("DEPENDS", []),
            "provides": fields.get("PROVIDES", []),
        }
    return pkgs


def fetch(url, dest):
    with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("targets", nargs="+")
    ap.add_argument("--out", required=True, type=pathlib.Path)
    ap.add_argument("--installed", default="pkgs/installed.txt", type=pathlib.Path)
    ap.add_argument("--refresh", nargs="*", default=[],
                    help="take these from the repo even though they are installed "
                         "(e.g. glibc, when the new binaries need a newer one)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    dbdir = args.out / "db"
    dbdir.mkdir(parents=True, exist_ok=True)
    db = {}  # name -> pkg, first repo wins
    for repo in REPOS:
        path = dbdir / f"{repo}.db"
        if not path.exists():
            fetch(f"{MIRROR}/{repo}/{repo}.db", path)
        for name, pkg in parse_db(path, repo).items():
            db.setdefault(name, pkg)

    providers = {}
    for pkg in db.values():
        for prov in pkg["provides"]:
            providers.setdefault(dep_name(prov), []).append(pkg["name"])

    installed = {}  # name -> version, or None when the list has names only
    for line in args.installed.read_text().splitlines():
        if line.split():
            name, *ver = line.split()
            installed[name] = ver[0] if ver else None
    # With versions (`pacman -Q`), every installed package whose repo build differs is
    # taken too, so the device is upgraded as a whole instead of partially.
    outdated = sorted({n for n, v in installed.items() if v and n in db and db[n]["version"] != v}
                      | {n for n in args.refresh if n in db})
    current = set(installed) - set(outdated)
    # What the up-to-date installed packages provide, taken from their repo entries.
    satisfied = set(current)
    for name in current:
        if name in db:
            satisfied.update(dep_name(p) for p in db[name]["provides"])

    chosen, versioned_on_installed, queue = {}, [], list(args.targets) + outdated
    while queue:
        dep = queue.pop(0)
        name = dep_name(dep)
        if name in chosen or any(name == dep_name(p) for c in chosen.values() for p in c["provides"]):
            continue
        if name in satisfied:
            if dep != name:
                versioned_on_installed.append(dep)
            continue
        if name in db:
            pick = name
        elif name in PREFER:
            pick = PREFER[name]
        elif len(set(providers.get(name, []))) == 1:
            pick = providers[name][0]
        else:
            sys.exit(f"cannot resolve {dep!r}: providers {sorted(set(providers.get(name, [])))}")
        pkg = db[pick]
        chosen[pick] = pkg
        queue.extend(pkg["depends"])

    total_c = sum(p["csize"] for p in chosen.values())
    total_i = sum(p["isize"] for p in chosen.values())
    for p in sorted(chosen.values(), key=lambda p: p["name"]):
        print(f"{p['repo']:6} {p['name']} {p['version']}")
    print(f"\n{len(chosen)} packages, download {total_c / 2**20:.1f} MiB, installed {total_i / 2**20:.1f} MiB")
    if outdated:
        print(f"including {len(outdated)} installed packages whose repo version differs: {' '.join(outdated)}")
    if versioned_on_installed:
        print("\nversioned deps satisfied by installed packages (pacman checks these on the device):")
        for dep in sorted(set(versioned_on_installed)):
            print(f"  {dep}  (repo: {db[dep_name(dep)]['version'] if dep_name(dep) in db else 'provided'})")
    if args.dry_run:
        return

    for p in sorted(chosen.values(), key=lambda p: p["name"]):
        dest = args.out / p["filename"]
        base = f"{MIRROR}/{p['repo']}/{p['filename']}"
        if not dest.exists() or hashlib.sha256(dest.read_bytes()).hexdigest() != p["sha256"]:
            print(f"fetch {p['filename']}", flush=True)
            fetch(base, dest)
            fetch(base + ".sig", args.out / (p["filename"] + ".sig"))
        if hashlib.sha256(dest.read_bytes()).hexdigest() != p["sha256"]:
            sys.exit(f"sha256 mismatch: {p['filename']}")
    (args.out / "list.txt").write_text("".join(f"{p['name']} {p['version']}\n" for p in sorted(chosen.values(), key=lambda p: p["name"])))
    print(f"all {len(chosen)} packages verified in {args.out}")


if __name__ == "__main__":
    main()
