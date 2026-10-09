#!/usr/bin/env python3
"""Refresh the bundled AdGuard Home list catalog (run at release time).

Downloads AdGuard's canonical HostlistsRegistry file (assets/filters.json)
at its newest commit and writes it unchanged into RoutewellKit. It prints
the commit for THIRD_PARTY_NOTICES.md. It downloads nothing else: the
router downloads each list. The app never calls the network for the catalog.

Usage: python3 -I scripts/update-adguard-catalog.py
"""
import json
import os
import urllib.request

COMMITS = "https://api.github.com/repos/AdguardTeam/HostlistsRegistry/commits?path=assets/filters.json&sha=main&per_page=1"
RAW = "https://raw.githubusercontent.com/AdguardTeam/HostlistsRegistry/{commit}/assets/filters.json"
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                      "RoutewellKit", "Sources", "RoutewellKit", "Resources", "adguard-filters.json")


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Routewell catalog script"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def main():
    # The newest upstream commit that changed the file, so the copy and
    # THIRD_PARTY_NOTICES.md name the same revision.
    latest = json.loads(fetch(COMMITS))[0]
    commit = latest["sha"]
    date = latest["commit"]["committer"]["date"]
    data = fetch(RAW.format(commit=commit))
    registry = json.loads(data)  # Fails before writing when the file is not JSON.
    if not registry.get("filters") or not registry.get("groups"):
        raise SystemExit("filters.json has no filters or groups; nothing written")
    with open(OUTPUT, "wb") as file:
        file.write(data)
    print(f"{len(registry['filters'])} lists in {len(registry['groups'])} groups written to {os.path.normpath(OUTPUT)}")
    print(f"Upstream commit {commit} ({date}). Update THIRD_PARTY_NOTICES.md to match:")
    print(f"https://github.com/AdguardTeam/HostlistsRegistry/blob/{commit}/assets/filters.json")


if __name__ == "__main__":
    main()
