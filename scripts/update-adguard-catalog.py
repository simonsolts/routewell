#!/usr/bin/env python3
"""Refresh the bundled AdGuard Home list catalog (run at release time).

Downloads AdGuard's canonical HostlistsRegistry file (assets/filters.json)
and writes it unchanged into RoutewellKit. It downloads nothing else: the
router downloads each list. The app never calls the network for the catalog.

Usage: python3 -I scripts/update-adguard-catalog.py
"""
import json
import os
import urllib.request

REGISTRY = "https://raw.githubusercontent.com/AdguardTeam/HostlistsRegistry/main/assets/filters.json"
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                      "RoutewellKit", "Sources", "RoutewellKit", "Resources", "adguard-filters.json")


def main():
    request = urllib.request.Request(REGISTRY, headers={"User-Agent": "Routewell catalog script"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    registry = json.loads(data)  # Fails before writing when the file is not JSON.
    if not registry.get("filters") or not registry.get("groups"):
        raise SystemExit("filters.json has no filters or groups; nothing written")
    with open(OUTPUT, "wb") as file:
        file.write(data)
    print(f"{len(registry['filters'])} lists in {len(registry['groups'])} groups written to {os.path.normpath(OUTPUT)}")


if __name__ == "__main__":
    main()
