#!/usr/bin/env python3
"""Fill the AltStore source with the Ghost Remote .ipa of each release.

    update-altstore-source.py --repository owner/name --source altstore.json

The checked-in source holds what never changes (names, descriptions, the
icon). The Pages run fills in the rest from GitHub's releases, the way the
depiction's changelog is filled: one entry under `versions` for every recent
release that carries `GhostRemote-<version>.ipa`, newest first, and the same
newest entry again in the pre-2.0 fields (`version`, `downloadURL`, …) that
SideStore and older AltStore read.

AltStore 2 refuses an install whose app disagrees with the source, so each
entry is read off the .ipa itself rather than assumed: the bundle id must be
the source's, the version and build are the bundle's, `minOSVersion` is its
`MinimumOSVersion`, and the newest bundle's usage descriptions become
`appPermissions.privacy`. CI already refuses an .ipa with entitlements, so
that list stays empty.
"""

import argparse
import io
import json
import os
import plistlib
import re
import sys
import urllib.request
import zipfile

API = "https://api.github.com"
MAX_VERSIONS = 8


def request(url, accept="application/vnd.github+json"):
    headers = {"Accept": accept, "User-Agent": "ighostvt-altstore-source"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as response:
        return response.read()


def bundle_info(ipa):
    with zipfile.ZipFile(io.BytesIO(ipa)) as archive:
        names = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(names) != 1:
            raise SystemExit(f"error: expected one app Info.plist in the .ipa, found {names}")
        return plistlib.loads(archive.read(names[0]))


def notes(body):
    """The release note without its closing paragraph about which package to
    choose — that one is about the debs and the Mac zip."""
    paragraphs = [p for p in re.split(r"\n\s*\n", (body or "").strip()) if p.strip()]
    kept = [p for p in paragraphs if not p.lstrip().startswith("Choose ")]
    return "\n\n".join(kept)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--source", required=True)
    args = parser.parse_args()

    with open(args.source, encoding="utf-8") as handle:
        source = json.load(handle)
    app = source["apps"][0]

    releases = json.loads(request(f"{API}/repos/{args.repository}/releases?per_page=30"))
    versions = []
    privacy = {}
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        tag = release["tag_name"].removeprefix("v")
        asset = next((a for a in release["assets"] if a["name"] == f"GhostRemote-{tag}.ipa"), None)
        if asset is None:
            continue
        ipa = request(asset["url"], accept="application/octet-stream")
        if len(ipa) != asset["size"]:
            raise SystemExit(f"error: {asset['name']} is {len(ipa)} bytes, GitHub says {asset['size']}")
        info = bundle_info(ipa)
        if info.get("CFBundleIdentifier") != app["bundleIdentifier"]:
            raise SystemExit(f"error: {asset['name']} is {info.get('CFBundleIdentifier')}, not {app['bundleIdentifier']}")
        if info.get("CFBundleShortVersionString") != tag:
            raise SystemExit(f"error: {asset['name']} says version {info.get('CFBundleShortVersionString')}")
        if not versions:
            privacy = {k: v for k, v in sorted(info.items()) if re.fullmatch(r"NS\w+UsageDescription", k)}
        versions.append({
            "version": tag,
            "buildVersion": str(info["CFBundleVersion"]),
            "date": release["published_at"],
            "localizedDescription": notes(release.get("body")),
            "downloadURL": asset["browser_download_url"],
            "size": asset["size"],
            "minOSVersion": info.get("MinimumOSVersion", "15.0"),
        })
        print(f"{tag} build {info['CFBundleVersion']}: {asset['browser_download_url']}")
        if len(versions) == MAX_VERSIONS:
            break

    if not versions:
        # Nothing to install yet: an app with no version is an error to
        # AltStore, so the source lists none until a release carries one.
        print("no release carries a Ghost Remote .ipa yet; the source lists no app", file=sys.stderr)
        source["apps"] = []
        source["featuredApps"] = []
    else:
        newest = versions[0]
        app["versions"] = versions
        app["appPermissions"] = {"entitlements": [], "privacy": privacy}
        app["version"] = newest["version"]
        app["versionDate"] = newest["date"]
        app["versionDescription"] = newest["localizedDescription"]
        app["downloadURL"] = newest["downloadURL"]
        app["size"] = newest["size"]

    with open(args.source, "w", encoding="utf-8") as handle:
        json.dump(source, handle, indent=4, ensure_ascii=False)
        handle.write("\n")


if __name__ == "__main__":
    main()
