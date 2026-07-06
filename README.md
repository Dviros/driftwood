<div align="center">

# 🪵 driftwood

### Your Mac forgets you were ever there.

**A disposable-identity layer for macOS.** Rotate the hostname that leaks on
every network you join — then launch any installed app inside a policy-enforced
sandbox that ends the moment you close the window: from a throwaway browser tab
to a full macOS VM with a rotated serial number, routed through your VPN.

[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Apple%20Silicon-black?logo=apple)](docs/getting-started.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![No Xcode required](https://img.shields.io/badge/Xcode-not%20required-success?logo=swift)](docs/getting-started.md)
[![Host daemon: Bash](https://img.shields.io/badge/host%20daemon-bash-4EAA25?logo=gnu-bash&logoColor=white)](driftwood.sh)

</div>

---

# What it is

driftwood is a privacy tool for hardware **you own**. Two pieces:

- **`driftwood.app`** — a SwiftUI launcher that lists your installed apps and
  runs each under a **policy**: **Casual** (a fresh throwaway state every
  launch), **Persistent** (normal), or **Paranoid** (a disposable macOS VM with
  a rotated hardware identity, optionally routed through a native VPN). Builds
  with **Command Line Tools only — no Xcode.**
- **`driftwood.sh`** — the CLI + root LaunchDaemon underneath. It rotates the
  host identifiers that are actually *safe* to change, and drives the same
  sandboxing backends from the terminal.

It's also honest about the one thing it can't do: make you anonymous to Apple
while you're signed into iCloud.

---

# Screenshots

![The grid — apps grouped by source](docs/screenshots/grid.png)

![Paranoid — disposable VMs with a network posture](docs/screenshots/paranoid.png)

---

# Why you'd want it

- **Click a link you don't trust.** Casual hands the browser a fresh `~/Library`
  — no cookies, no history, no logins — and wipes it on close. Your real profile
  is exactly as you left it.
- **Run an app with a new identity, through your VPN.** Paranoid clones a golden
  macOS image (instant, copy-on-write), gives the clone a random MAC + serial,
  connects your Tailscale / ProtonVPN / WireGuard *before* the VM boots, and
  deletes the whole clone when you close the window.
- **Different network rules per app.** Full, Isolated, Offline, or route through
  any native VPN — chosen per launch.
- **An App Store app in a clean, disposable OS.** Install it once into the
  golden; every clone runs it with no leftover state.

---

# Quickstart

```bash
# GUI — no Xcode needed
cd app && ./bundle.sh && open driftwood.app

# CLI — host identity rotation
./driftwood.sh now --dry-run           # preview what changes
sudo ./driftwood.sh now                # rotate ComputerName/LocalHostName/HostName

# CLI — disposable sandboxes
./driftwood.sh run --linux ubuntu -- bash
./driftwood.sh run --macos golden --app Safari
```

Full setup is in **[Getting started](docs/getting-started.md)**.

---

# Documentation

| Guide | Inside |
|---|---|
| 📦 **[Getting started](docs/getting-started.md)** | Requirements, install / build (no Xcode), `tart` + the one-time golden |
| 🖥️ **[The app](docs/gui.md)** | The three policies, per-app overrides, the Activity & traces inspector |
| 🛡️ **[Paranoid — disposable VMs](docs/paranoid-vm.md)** | Golden image, the clone → rotate → destroy lifecycle, network postures + native VPN, App Store apps |
| ⌨️ **[The CLI & host rotation](docs/cli.md)** | `driftwood.sh`: what's safe to rotate, the daemon, the `run` backends |
| 🔒 **[Privacy model & honest ceilings](docs/privacy.md)** | Threat model, what it defeats vs what it can't, the iCloud caveat |

---

# Privacy, honestly

driftwood defeats **LAN / Bonjour name leakage**, **cross-network hostname + MAC
correlation**, **per-app state fingerprinting** (a fresh profile every launch),
and gives a **disposable, rotated hardware identity** inside the Paranoid VM —
optionally behind your VPN.

It does **not** make you anonymous to Apple while you're signed into iCloud (the
Apple Account **DSID** anchors first-party correlation), it can't confine an
arbitrary GUI *process* on the bare host (which is exactly why Paranoid uses a
VM), and there is **no anonymous way to run App Store apps** (their license is
Secure-Enclave-bound to your Apple ID). The full, unflinching version lives in
**[Privacy model & honest ceilings](docs/privacy.md)**.

---

# Requirements

| Feature | Needs |
|---|---|
| Host rotation (`driftwood.sh`) | macOS 13+ |
| `driftwood.app` — Casual / Persistent | macOS 13+, Command Line Tools (no Apple Silicon needed) |
| Paranoid — disposable VM | Apple Silicon + [`tart`](https://github.com/cirruslabs/tart) + a one-time golden |
| `run --linux` | macOS 26 + Apple [`container`](https://github.com/apple/container) |

---

# License

MIT — see [LICENSE](LICENSE).
