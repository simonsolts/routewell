# Third-party notices

## RouterPilot

- Project: [RouterPilot](https://github.com/TCDemo777/RouterPilot)
- Creator: [Tristan](https://github.com/TCDemo777) (TCDemo777) and contributors
- Upstream copyright notice: Copyright © Tristan
- License: GNU General Public License v3.0 only (`GPL-3.0-only`)
- Reference revision: [`499613a5fa725a8d246f4fd80009e9a3eaeb1a8b`](https://github.com/TCDemo777/RouterPilot/tree/499613a5fa725a8d246f4fd80009e9a3eaeb1a8b)
- Upstream [license](https://github.com/TCDemo777/RouterPilot/blob/499613a5fa725a8d246f4fd80009e9a3eaeb1a8b/LICENSE)
  and [third-party notices](https://github.com/TCDemo777/RouterPilot/blob/499613a5fa725a8d246f4fd80009e9a3eaeb1a8b/RouterPilot/THIRD_PARTY_NOTICES.txt)

Routewell is heavily inspired by RouterPilot. It is the reference for Routewell's
feature set and how it is organised. Routewell is independently
maintained and is not an official RouterPilot release.

The reference revision identifies the local RouterPilot checkout consulted for
the initial scaffold. Its architecture notes informed the model and service
boundaries. The scaffold does not bundle RouterPilot's Windows application,
.NET dependencies, or community maintenance scripts.

### Adaptation record

No file-level source translations have been introduced in the initial mock
scaffold. Record copied or adapted files here as they are introduced, including
the upstream path and revision, Routewell destination, adaptation date, and
description of changes. Preserve applicable upstream copyright and license
notices in those files.

## AdGuard HostlistsRegistry

- Project: [HostlistsRegistry](https://github.com/AdguardTeam/HostlistsRegistry)
- Creator: AdGuard (AdguardTeam) and contributors
- License: GNU General Public License v3.0 (`GPL-3.0`), see the upstream [license](https://github.com/AdguardTeam/HostlistsRegistry/blob/d08718e04d45196725f86b460521b2ca0cbcd511/LICENSE)
- Snapshot: [`assets/filters.json`](https://github.com/AdguardTeam/HostlistsRegistry/blob/d08718e04d45196725f86b460521b2ca0cbcd511/assets/filters.json) at commit `d08718e04d45196725f86b460521b2ca0cbcd511` (2026-10-09)
- Routewell path: `RoutewellKit/Sources/RoutewellKit/Resources/adguard-filters.json`

The bundled file is an unmodified copy of the catalog: list names, groups,
descriptions, and URLs. Routewell does not bundle the content of any list. The
router downloads each list from its own URL, and each list has its own licence.
At release time, download https://raw.githubusercontent.com/AdguardTeam/HostlistsRegistry/main/assets/filters.json over the bundled file, and update the commit and date in this entry.

The GPLv3 text is included in [LICENSE](LICENSE). These credits supplement,
rather than replace, applicable license notices and source-distribution
requirements.
