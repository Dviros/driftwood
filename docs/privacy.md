[← driftwood](../README.md)

# Privacy Model & Honest Ceilings

## Threat model

Every Mac leaks a small constellation of identifiers the moment it touches a
network or opens an app:

- **Bonjour/mDNS broadcasts your `ComputerName`** to every device on the
  LAN — coffee-shop Wi-Fi, hotel networks, your friend's router. `"Joe's
  MacBook Pro"` is a name, a signal, and a cross-network correlation key, all
  at once.
- **Your Wi-Fi MAC** is a stable link-layer fingerprint every AP you
  associate with can log.
- **Every app you run accumulates state** — caches, cookies, UUIDs, saved
  application state — that ties your activity together across sessions even
  if you never signed into anything.
- **A GUI app is not a jail.** Even a "sandboxed" launch on stock macOS
  re-enters via LaunchServices and inherits your real environment, your real
  serial number, your real everything — unless it's run somewhere that isn't
  your host at all.

driftwood attacks this at two layers: it rotates what's safe to rotate on the
**host** (cosmetic identity — the network never needs your real name), and
it gives every app you launch a genuinely **disposable execution
environment** (state, process, or full hardware identity, depending on how
paranoid you want to be). It will not pretend to solve problems it
structurally can't — that's the rest of this page.

See [gui.md](gui.md) for the three launch policies and [cli.md](cli.md) for
the `driftwood run` backends that implement this model from the command
line.

## Privacy guarantees: defeats vs. does not defeat

| | driftwood defeats | driftwood does **not** |
|---|---|---|
| **LAN / Bonjour** | Real `ComputerName`/`LocalHostName` broadcast to every device on the network | — |
| **Cross-network correlation** | Same hostname/MAC following you from coffee shop to office to hotel | Correlation via your Apple ID / iCloud session (see [The iCloud caveat](#the-icloud-caveat)) |
| **Per-app state tracking** | An app building a fingerprint across launches (cookies, caches, saved UUIDs) — Casual policy gives it a fresh profile every time | `~/Library/Containers` state for *sandboxed* apps (App Store apps) — TCC-locked, Casual can't touch it |
| **Third-party fingerprinting inside a sandboxed app** | Hardware serial / MAC seen by an app running in a Paranoid VM — both are rotated per session | Fingerprinting by **Apple itself** while you're signed into iCloud (DSID-anchored) |
| **Process confinement of arbitrary GUI apps** | Full isolation via a disposable macOS VM (Paranoid) — a real boundary | `sandbox-exec` confinement of a GUI app on the bare host — provably escapable (see below) |
| **Off-host launch traces** | Paranoid VM launches never touch the host's unified log at all | The host's unified log recording *native* app launches — no unprivileged tool can suppress this |
| **Anonymous App Store apps** | Nothing — this is a hard Apple constraint, not a driftwood limitation | Licenses are Secure-Enclave-bound to your Apple ID; there is no anonymous path |

## Honest ceilings

Presented as credibility, not fine print — these are the walls we hit, and
we'd rather you know them going in.

1. **You can't process-jail an arbitrary GUI app on the bare host.**
   `sandbox-exec` is deprecated and escapable — verified by launching the
   Athas editor under it and watching it step outside the profile via
   LaunchServices. This is why Paranoid exists as a wholly separate tier:
   see [paranoid-vm.md](paranoid-vm.md).
2. **`~/Library/Containers` is TCC-locked.** Sandboxed apps (most App Store
   titles) keep their real state there, which no unprivileged tool —
   driftwood included — can stash and swap. `StateSwap.swift` moves a fixed
   list of state locations (`Containers/<bundleID>`, `Application
   Support/...`, `Preferences/....plist`, `Caches/...`, cookie/WebKit
   storage, saved app state) aside before launch and restores them on close —
   but only for **non-sandboxed** apps. **Casual only fully isolates
   non-sandboxed apps.**
3. **The Paranoid VM is a separate macOS instance.** Your host-installed apps
   are not "in" it. Getting an app in means either `scp`-ing a self-contained
   bundle into the clone (best-effort — installers and apps needing system
   frameworks may not run unmodified) or installing it into the golden once
   via "Manage golden." A macOS guest also **can't sign into
   iCloud/iMessage** — a Virtualization.framework limit — so Paranoid rotates
   hardware identity for fingerprinting purposes, not Apple first-party
   correlation.
4. **There is no anonymous way to run App Store apps.** The license is tied
   to your Apple ID, and the cryptographic keys backing the receipt
   (`Contents/_MASReceipt/receipt`) are Secure-Enclave-bound and
   non-copyable — they can't be lifted into a clone with a different
   identity. `VMManager.launch` checks `isAppStore` and skips `tart set
   --random-mac --random-serial` for those apps specifically because rotating
   a clone's identity *after* an App Store app is installed makes the app
   reject its own receipt outright (`exit 173`). The CLI does **not**
   auto-detect this the way the GUI does — pass `--no-rotate` yourself for
   App Store apps with `driftwood run --macos`, or expect `exit 173`.
5. **While signed into iCloud, nothing decouples you from Apple.** See
   [The iCloud caveat](#the-icloud-caveat) below.
6. **The unified log still records native launches.** macOS logs every
   native app launch on the host regardless of policy — Casual and
   Persistent both run as real processes on your real kernel. Only the
   Paranoid VM keeps a launch off the host log entirely, because the app
   never actually runs on the host.

## The iCloud caveat

macOS has no single "machine ID" — identity is a **layered stack**: hardware
(serial, `IOPlatformUUID`, Secure Enclave), NVRAM (`ROM`/`MLB`), OS
(hostnames, MAC), and your Apple Account (**DSID**). Most layers either
**can't** be changed (hardware-bound) or **must not** be changed while you
use iCloud, because doing so de-registers Apple services out from under you.

While you're fully signed into iCloud, host rotation only defeats **LAN and
third-party** tracking. It cannot decouple you from Apple: your **DSID** is
the anchor, and MobileGestalt (`MGCopyAnswer`) plus the Anisette/ADI auth
layer bind your hardware to that account regardless of hostname or MAC.
Defeating first-party Apple correlation means compartmentalizing iCloud
entirely — which is what the sandbox/VM layer is for, not host rotation. And
even inside a Paranoid VM, the guest can't sign into iCloud/iMessage at all,
so this axis is simply out of scope rather than partially solved.

## What driftwood refuses to rotate, and why

`driftwood.sh` (host rotation) only ever touches `ComputerName` /
`LocalHostName` / `HostName`, and optionally the Wi-Fi MAC. It flatly refuses
everything else, on purpose:

| Identifier | What breaks if you rotate it |
|---|---|
| NVRAM `ROM` / `MLB` (iMessage identity pair) | De-registers iMessage & FaceTime; forces iCloud / Apple Pay re-auth |
| APNs push token | Breaks push for Mail, Messages, and every app that relies on it |
| Serial, `IOPlatformUUID`, Secure Enclave UID | Hardware-bound — can't actually be changed; trying only causes instability |
| Apple Account DSID | The master key of iCloud; changes only with a new Apple ID |

This refusal is enforced in the script itself, not left to the operator's
judgment at runtime — see [cli.md](cli.md) for the exact commands.

## What you actually get

driftwood defeats LAN and third-party fingerprinting (Bonjour hostname
broadcast, per-network MAC tracking, per-app state correlation across
launches) and, inside a Paranoid VM, gives you a genuinely disposable
hardware identity (rotated serial + MAC) with a real process/kernel
boundary — the only policy where that boundary actually holds. It does
**not** make you anonymous to Apple: DSID-anchored iCloud correlation
survives every layer of this tool by design, App Store apps can never run
with a rotated identity because their receipts are Secure-Enclave-bound, and
native launches on the host are always visible in the unified log. If a tool
tells you otherwise about any of these, be skeptical of that tool.

---

See also: [getting-started.md](getting-started.md),
[gui.md](gui.md), [paranoid-vm.md](paranoid-vm.md), [cli.md](cli.md).
