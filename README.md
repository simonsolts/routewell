<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/simonsolts/routewell/main/images/routewell-header-light-text.png">
  <img src="https://raw.githubusercontent.com/simonsolts/routewell/main/images/routewell-header-dark-text.png" alt="Routewell" width="380">
</picture>

# Routewell

**An (unofficial) macOS app for your GL.iNet Flint router.**

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![Status: early development](https://img.shields.io/badge/status-early%20development-orange)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

</div>

Routewell shows you what your router is doing, in real time. See the health
of your network at a glance. Find every device on your network. Pause ad
blocking with one click.

Routewell talks directly to your router on your local network. It has no
account and no cloud service.

<p align="center">
  <img src="https://raw.githubusercontent.com/simonsolts/routewell/main/images/overview-screen.png" alt="The Routewell Overview screen, with router, internet, AdGuard Home, and client status" width="900">
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
- **Control ad blocking.** Turn AdGuard Home protection on or off, or pause it
  for a short time.
- **Check your router.** See performance, DNS, Wi‑Fi, SQM, and firmware
  updates. With SSH on, you can also see ports, storage, and system logs.
- **Stay in the menu bar.** Check your network status without opening the main
  window.

<table>
  <tr>
    <td width="50%"><img src="https://raw.githubusercontent.com/simonsolts/routewell/main/images/clients-screen-1.png" alt="The Clients screen with a device's overview in the details pane"></td>
    <td width="50%"><img src="https://raw.githubusercontent.com/simonsolts/routewell/main/images/clients-screen-2.png" alt="The Clients screen with a device's recent DNS requests and top blocked domains"></td>
  </tr>
  <tr>
    <td align="center"><sub>Every device on your network, with signal and DNS counts</sub></td>
    <td align="center"><sub>Recent DNS requests and top blocked domains for one device</sub></td>
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

Routewell is in early development. Next on the list: a live DNS activity log,
Protection rules and filters, Network settings, notifications, analytics, VPN,
and applications.

Tested on the GL.iNet Flint 4 (GL-BE14000) with firmware 4.9.1.

## Get Routewell

There is no signed release yet. To build Routewell from source, see
[Building Routewell](docs/building.md).

---

#### Acknowledgements

Routewell is heavily inspired by
[RouterPilot](https://github.com/TCDemo777/RouterPilot), created by
[Tristan](https://github.com/TCDemo777) and its contributors.

#### Copyright

Copyright © 2026 Simon Solts. Routewell is licensed
under the GNU General Public License v3.0 only. See [LICENSE](LICENSE) and
[COPYRIGHT](COPYRIGHT). Third-party contributions retain their respective
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
