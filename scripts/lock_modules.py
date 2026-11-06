#!/usr/bin/env python3
"""Dev tool: pin PSGallery modules into catalog/modules.lock.json.

Usage: python3 scripts/lock_modules.py Name@Version [Name@Version ...] [--out PATH] [--work-dir DIR]

For each spec it reads the public PSGallery OData feed (read-only HTTPS GETs), takes the pinned version's
PackageHash and PackageHashAlgorithm, downloads the .nupkg, verifies the package really hashes to PackageHash,
reads the nuspec dependencies and checks the module files for an Authenticode signature block. Nothing from the
package is executed; it is only opened as a zip. Standard library only. Run it with `python3 -I`.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

FEED = "https://www.powershellgallery.com/api/v2"
ATOM = "{http://www.w3.org/2005/Atom}"
DATA = "{http://schemas.microsoft.com/ado/2007/08/dataservices}"
META = "{http://schemas.microsoft.com/ado/2007/08/dataservices/metadata}"
SIG_BEGIN = "# SIG # Begin signature block"
SIG_END = "# SIG # End signature block"
SIGNED_SUFFIXES = (".psd1", ".psm1", ".ps1")
DEFAULT_SIGNER = "Evotec Services sp. z o.o."
OUT = Path(__file__).resolve().parent.parent / "catalog" / "modules.lock.json"


def _get(url: str) -> bytes:
    if not url.startswith("https://www.powershellgallery.com/"):
        raise SystemExit(f"refusing to fetch {url}")
    with urllib.request.urlopen(url, timeout=60) as resp:  # noqa: S310 (fixed https host)
        return resp.read()


def find_entry(name: str, version: str) -> dict[str, str]:
    url = f"{FEED}/FindPackagesById()?id='{urllib.parse.quote(name)}'"
    while url:
        root = ET.fromstring(_get(url))
        for entry in root.findall(f"{ATOM}entry"):
            props = entry.find(f"{META}properties")
            if props is not None and props.findtext(f"{DATA}Version") == version:
                return {child.tag.removeprefix(DATA): (child.text or "") for child in props if child.tag.startswith(DATA)}
        nxt = next((ln.get("href") for ln in root.findall(f"{ATOM}link") if ln.get("rel") == "next"), None)
        url = nxt or ""
    raise SystemExit(f"{name} {version} is not in the PowerShell Gallery feed")


def nuspec_dependencies(zf: zipfile.ZipFile) -> list[str]:
    nuspec = next((n for n in zf.namelist() if n.endswith(".nuspec") and "/" not in n), None)
    if nuspec is None:
        raise SystemExit("package has no nuspec")
    root = ET.fromstring(zf.read(nuspec))
    names = [el.get("id") for el in root.iter() if el.tag.endswith("dependency") and el.get("id")]
    return sorted(dict.fromkeys(names), key=names.index)


def nuspec_license(zf: zipfile.ZipFile) -> str:
    nuspec = next(n for n in zf.namelist() if n.endswith(".nuspec") and "/" not in n)
    root = ET.fromstring(zf.read(nuspec))
    for el in root.iter():
        if el.tag.endswith("licenseUrl") and (el.text or "").strip():
            return el.text.strip()
        if el.tag.endswith("license") and (el.text or "").strip():
            return el.text.strip()
    return ""


def signature_blob(text: str) -> bytes | None:
    start = text.find(SIG_BEGIN)
    if start < 0:
        return None
    end = text.find(SIG_END, start)
    lines = text[start + len(SIG_BEGIN):end if end > 0 else None].splitlines()
    b64 = "".join(ln.strip().removeprefix("#").strip() for ln in lines)
    return base64.b64decode(b64 + "=" * (-len(b64) % 4))


def signer_names(blob: bytes) -> list[str]:
    """Common-name strings (OID 2.5.4.3) inside the PKCS#7 block, in order. Best effort, for reporting."""
    out = []
    for m in re.finditer(rb"\x06\x03\x55\x04\x03[\x0c\x13\x16\x1e]", blob):
        i = m.end()
        n = blob[i]
        i += 1
        if n & 0x80:
            k = n & 0x7F
            n = int.from_bytes(blob[i:i + k], "big")
            i += k
        raw = blob[i:i + n]
        try:
            out.append(raw.decode("utf-16-be" if blob[m.end() - 1] == 0x1E else "utf-8"))
        except UnicodeDecodeError:
            pass
    return out


def lock_one(name: str, version: str, work: Path) -> dict:
    entry = find_entry(name, version)
    algo = entry.get("PackageHashAlgorithm", "")
    if algo != "SHA512":
        raise SystemExit(f"{name} {version}: PackageHashAlgorithm is {algo!r}, expected SHA512")
    nupkg = work / f"{name}.{version}.nupkg"
    nupkg.write_bytes(_get(f"{FEED}/package/{urllib.parse.quote(name)}/{version}"))
    actual = base64.b64encode(hashlib.sha512(nupkg.read_bytes()).digest()).decode()
    if actual != entry["PackageHash"]:
        raise SystemExit(f"{name} {version}: nupkg SHA512 {actual} != feed PackageHash {entry['PackageHash']}")
    signed, unsigned, names = [], [], []
    with zipfile.ZipFile(nupkg) as zf:
        deps = nuspec_dependencies(zf)
        license_ = entry.get("LicenseUrl", "").strip() or nuspec_license(zf)
        for info in zf.infolist():
            if not info.filename.lower().endswith(SIGNED_SUFFIXES):
                continue
            blob = signature_blob(zf.read(info).decode("utf-8-sig", errors="replace"))
            if blob is None:
                unsigned.append(info.filename)
            else:
                signed.append(info.filename)
                names += signer_names(blob)
    signer = None
    if signed:
        signer = DEFAULT_SIGNER if any(DEFAULT_SIGNER in n for n in names) else None
        print(f"  {name}: {len(signed)} signed / {len(unsigned)} unsigned script files; certificate CNs seen: {sorted(set(names))}",
              file=sys.stderr)
        if signer is None:
            raise SystemExit(f"{name}: signature block present but signer {DEFAULT_SIGNER!r} not found in it; decide manually")
        if unsigned:
            raise SystemExit(f"{name}: unsigned script files alongside signed ones, install-time check would fail: {unsigned}")
    else:
        print(f"  {name}: no signature block in {len(unsigned)} script files -> signer null", file=sys.stderr)
    print(f"  {name} {version}: nupkg SHA512 matches PackageHash; nuspec dependencies: {deps}", file=sys.stderr)
    return {
        "name": name, "version": version, "package_hash": entry["PackageHash"], "hash_algorithm": algo,
        "license": license_, "project_url": entry.get("ProjectUrl", "").strip(), "signer": signer, "requires": deps,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("specs", nargs="+", help="Name@Version")
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--work-dir", type=Path, help="parent folder for the untrusted .nupkg downloads")
    args = ap.parse_args()
    if args.work_dir:
        args.work_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="nupkg-", dir=args.work_dir))
    mods = []
    for spec in args.specs:
        name, _, version = spec.partition("@")
        if not name or not version:
            raise SystemExit(f"bad spec {spec!r}; use Name@Version")
        mods.append(lock_one(name, version, work))
    pinned = {m["name"] for m in mods}
    for m in mods:
        outside = [d for d in m["requires"] if d not in pinned]
        if outside:
            raise SystemExit(f"{m['name']} depends on unpinned modules: {outside}")
    args.out.write_text(json.dumps({"modules": mods}, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out} ({len(mods)} modules); downloads in {work}", file=sys.stderr)


if __name__ == "__main__":
    main()
