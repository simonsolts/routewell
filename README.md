<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/simonsolts/routewell/main/images/routewell-header-light-text.png">
  <img src="https://raw.githubusercontent.com/simonsolts/routewell/main/images/routewell-header-dark-text.png" alt="Routewell" width="380">
</picture>

# Routewell - for GL.iNet Routers

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![Status: alpha](https://img.shields.io/badge/status-early%20alpha-orange)
[![Release](https://img.shields.io/github/v/release/simonsolts/routewell?include_prereleases&sort=semver)](https://github.com/simonsolts/routewell/releases)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

</div>

Routewell shows you what your GL.iNet router is doing, in real time. See the health
of your network at a glance. Find every device on your network. See every DNS
request, and control AdGuard Home from your Mac.

Routewell talks directly to your router on your local network. It has no
account and no cloud service.

<p align="center">
  <a href="https://github.com/simonsolts/routewell/releases"><b>Download the latest alpha</b></a>
  · macOS 26 or later · tested on the GL.iNet Flint 4 with firmware 4.9.1
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/simonsolts/routewell/main/images/overview.png" alt="The Routewell Overview screen, with router, internet, AdGuard Home, and client status" width="900">
</p>

## What you can do

- **See everything at a glance.** The Overview shows your router, internet
  connection, AdGuard Home, and connected devices. It also shows load, memory,
  temperature, and uptime.
- **Know every device.** The Clients screen lists each device with its IP
  address, connection, Wi‑Fi signal, and DNS queries. Routewell tells you when
  a new device joins.
- **Look closer at one device.** See when it was online, which domains it asks
  for, and which requests AdGuard blocked. Give it a name, a category, and
  notes. Ping it or wake it.
- **Control AdGuard Home.** See queries, blocks, and the top blocked domains
  and devices. Turn protection on or off, or pause it. Manage blocklists,
  allowlists, and custom rules. Set upstream DNS servers and the cache.
- **Watch every DNS request.** Read the query log live. Search it, filter it by
  device, and block or unblock a domain from a request.
- **Keep AdGuard Home safe.** With SSH on, back up and restore its settings.
- **Check your router.** See performance, DNS, Wi‑Fi, SQM, and firmware
  updates. With SSH on, you can also see ports, storage, and system logs.
- **Stay in the menu bar.** Check your network status without opening the main
  window.

<p align="center">
  <img src="https://raw.githubusercontent.com/simonsolts/routewell/main/images/adguard-overview.png" alt="The AdGuard Home screen, with protection status, a 24-hour activity chart, protection switches, and the top blocked domains, queried domains, and devices" width="900">
</p>

<table>
  <tr>
    <td width="50%"><img src="https://raw.githubusercontent.com/simonsolts/routewell/main/images/clients-screen.png" alt="The Clients screen with a device's overview in the details pane"></td>
    <td width="50%"><img src="https://raw.githubusercontent.com/simonsolts/routewell/main/images/adguard-query-log.png" alt="The AdGuard Home Query Log, with one request open in the inspector"></td>
  </tr>
  <tr>
    <td align="center"><sub>Every device on your network, with signal and DNS counts</sub></td>
    <td align="center"><sub>Every DNS request, live, with the reason it was blocked or allowed</sub></td>
  </tr>
</table>

## Built with care

- **Native.** Routewell is a SwiftUI app for macOS 26. It looks and works like
  the other apps on your Mac, in light and dark mode.
- **Private.** Routewell talks only to your router, on your own network. It has
  no account, no cloud service, and no tracking. 
- **Secure.** Your router password stays in the macOS Keychain, and the app
  runs in the macOS sandbox. Optional SSH access uses your keys but never sees them.

## Coming next

Routewell is a very early alpha. Next on the list: network settings,
maintenance tasks, notifications, analytics, VPN, and applications.

## Get Routewell

> [!WARNING]
> **Routewell is a very early alpha build.** Many screens are not finished,
> and you can find bugs. It has been tested on one router only. Do not rely on
> it to manage a network that other people depend on.

Download the latest alpha from the
[Releases page](https://github.com/simonsolts/routewell/releases). The app is
signed and notarized by Apple. Unzip it and move **Routewell (Alpha)** to your
Applications folder.

Routewell needs macOS 26 or later. It has been tested on the GL.iNet Flint 4
(GL-BE14000) with firmware 4.9.1.

When you open Routewell for the first time, a setup assistant finds your
router. Sign in with your router's admin password. AdGuard Home and SSH are
optional, and you can set up SSH later.

To build Routewell from source, see [Building Routewell](docs/building.md).

---

#### Acknowledgements

Routewell is heavily inspired by
[RouterPilot](https://github.com/TCDemo777/RouterPilot), created by
[Tristan](https://github.com/TCDemo777) and its contributors.

#### Copyright

Copyright © 2026 Simon Solts. Routewell is licensed
under the GNU General Public License v3.0 only, with one additional term under
Section 7(b): you must keep the attribution to the author. See [LICENSE](LICENSE),
[NOTICE](NOTICE) and [COPYRIGHT](COPYRIGHT). Third-party contributions retain their respective
copyright notices; see [Third-party notices](THIRD_PARTY_NOTICES.md).


#### Disclaimer

Routewell is an independent, unofficial project. It is not
affiliated with, endorsed, sponsored, or supported by GL.iNet. GL.iNet and its
product names, logos, and trademarks belong to their respective owners. All
other trademarks are the property of their respective owners. Use Routewell at
your own risk. The software is provided "as is", without warranty of any kind.
To the extent permitted by applicable law, the authors and contributors are not
liable for any loss or damage arising from its use, including data loss, device
damage, or network disruption. See [LICENSE](LICENSE) for the full warranty
disclaimer and limitation of liability.
