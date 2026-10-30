"""Add a build to this repo's sideloading source (AltStore source format).

FlareStore, AltStore, SideStore, Feather and ESign all read this format.
The source lives on the `source` branch as source.json; app details that
don't come from the IPA are in .github/source-meta.json.

Usage: update-source.py <source.json> <ipa> <download_url> <release_notes.md>
"""
import json
import plistlib
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

KEEP = 25  # versions kept in the source

src_path, ipa_path, download_url, notes_path = sys.argv[1:5]
meta = json.loads((Path(__file__).parent.parent / "source-meta.json").read_text(encoding="utf-8"))

with zipfile.ZipFile(ipa_path) as ipa:
    plist_name = next(
        n for n in ipa.namelist()
        if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")
    )
    info = plistlib.loads(ipa.read(plist_name))

# Changelog lines from the release notes: everything between the "###" header and the "---" footer.
lines, inside = [], False
for line in Path(notes_path).read_text(encoding="utf-8").splitlines():
    if line.startswith("### "):
        inside = True
        continue
    if line.strip() == "---":
        break
    if inside and line.strip():
        lines.append(line.strip())
notes = "\n".join(lines) or "No changes listed."

entry = {
    "version": info["CFBundleShortVersionString"],
    "buildVersion": str(info["CFBundleVersion"]),
    "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": notes,
    "downloadURL": download_url,
    "size": Path(ipa_path).stat().st_size,
    "minOSVersion": info.get("MinimumOSVersion", "16.0"),
}

p = Path(src_path)
old = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
old_versions = (old.get("apps") or [{}])[0].get("versions", [])
versions = [entry] + [v for v in old_versions if v.get("buildVersion") != entry["buildVersion"]]
versions = versions[:KEEP]

app = {
    "name": meta["name"],
    "bundleIdentifier": info["CFBundleIdentifier"],
    "developerName": meta.get("developerName", "soum91"),
    "subtitle": meta["subtitle"],
    "localizedDescription": meta["description"],
    "iconURL": meta["iconURL"],
    "tintColor": meta.get("tintColor", "0A84FF"),
    "category": meta.get("category", "utilities"),
    "screenshotURLs": [],
    "versions": versions,
    # Flat fields for older clients and signers that only read the newest build.
    "version": entry["version"],
    "versionDate": entry["date"],
    "versionDescription": entry["localizedDescription"],
    "downloadURL": entry["downloadURL"],
    "size": entry["size"],
    "appPermissions": {},
}

source = {
    "name": meta["sourceName"],
    "identifier": meta["sourceIdentifier"],
    "subtitle": meta["subtitle"],
    "description": meta["description"],
    "iconURL": meta["iconURL"],
    "website": meta["website"],
    "sourceURL": meta["sourceURL"],
    "tintColor": app["tintColor"],
    "apps": [app],
    "news": [],
}

p.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"{app['bundleIdentifier']} {entry['version']} ({entry['buildVersion']}) -> {p}, {len(versions)} version(s)")
