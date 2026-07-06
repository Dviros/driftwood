# driftwood

**Ephemeral identity rotation for macOS.** Two things:

1. a small daemon that safely rotates the handful of host identifiers you *can*
   change without breaking anything, and
2. `driftwood run` — launch a single app in a disposable, self-destructing
   sandbox (Linux container, native Seatbelt sandbox, or a throwaway macOS VM).

> **Scope & ethics.** A personal-privacy tool for hardware **you own**. It
> reduces cross-network and third-party fingerprinting. It is not an
> anti-forensics or fraud tool, and it can't make you anonymous to Apple while
> you're signed into iCloud — see [The iCloud caveat](#the-icloud-caveat).

**Requirements**

| Feature | Needs |
|---|---|
| Host rotation (`now` / `install`) | macOS 13+ |
| `run --sandboxed` | any macOS (built-in `sandbox-exec`) |
| `run --linux` | macOS 26 + Apple [`container`](https://github.com/apple/container) |
| `run --macos` | Apple Silicon + [`tart`](https://github.com/cirruslabs/tart) + a golden VM |

---

## driftwood.app — native launcher (GUI)

A SwiftUI app that lists your installed apps grouped by source and launches each
under a chosen **policy**. Builds with **Command Line Tools only — no Xcode**.

![driftwood grid](docs/screenshots/grid.png)

### Install & run

```bash
cd app
./bundle.sh          # swift build -c release + wrap into driftwood.app (ad-hoc signed)
open driftwood.app   # (move it to /Applications first to avoid the Downloads TCC prompt)
```

Requirements: Apple Silicon, macOS 13+. The **Paranoid** policy also needs
[`tart`](https://github.com/cirruslabs/tart) (`brew install cirruslabs/cli/tart`)
plus a one-time golden image — downloadable from inside the app.

### Policies

| Policy | What it does | Confines the app? |
|---|---|---|
| **Casual** | Native launch with a fresh throwaway profile — the app's `~/Library` state is stashed, then wiped (or kept, with *Ask on close*) | no — ephemeral *state*, app runs normally |
| **Persistent** | Normal launch; the app's changes are kept | no |
| **Paranoid** | Disposable macOS VM (linked clone, rotated serial + MAC), destroyed on close | **yes — full VM boundary** |

Set a policy globally (top bar) or **per app** (right-click a card → policy;
shown as a badge, persisted across launches).

> **Why not just "sandbox" the process?** You can't retrofit a Seatbelt jail onto
> an arbitrary GUI app — it re-launches via LaunchServices and escapes (verified
> with Athas). And App-Store / system apps keep state in `~/Library/Containers`,
> which is TCC-locked, so **Casual only fully isolates non-sandboxed apps** (state
> in `Application Support` / `Preferences`). Real confinement of *any* app = the
> VM. The stash/restore is journaled and crash-safe: a crash mid-session is undone
> on next launch, and it never deletes real data without a stash to replace it.

### Paranoid: disposable VMs

![Paranoid — disposable VM](docs/screenshots/paranoid.png)

Select **Paranoid** and the top bar shows the VM controls:

- **Download golden (~25 GB, once)** — pulls a macOS VM to your SSD. Every session
  after is an instant APFS copy-on-write clone (≈ 0 extra disk).
- **Network** — **Full** (shared NAT) or **Isolated** (softnet). *Split-tunnel /
  offline are roadmap (need a gateway VM).*
- Each launch: linked clone → rotate serial + MAC → boot → the app opens **inside
  the VM** → the clone is **destroyed when you close the window**.

**Your apps aren't in the VM** (it's a separate macOS). Two ways in:

- **Self-contained apps** (Electron, direct downloads) are copied into the clone and opened — best-effort.
- **App Store & system apps** must be installed once via **Manage golden** (boots
  the golden read-write and opens the App Store — sign in, install, shut down).
  They then run in every clone **without identity rotation**, because the receipt
  is Apple-ID/machine-bound and rotating it would void it (exit 173). Signing in
  links that golden to your Apple ID for those apps — there is **no anonymous way**
  to run Store apps (their license is tied to your Apple ID, and the auth keys are
  Secure-Enclave-bound and non-copyable).

### Activity & traces

The chart button opens the inspector: live **CPU / memory / disk I/O / process
count** per running app (summed across the whole process tree, so Electron helpers
count), plus driftwood's full **on-disk footprint** with a **Clean orphans** purge.
Per-process network isn't exposed to unprivileged apps on macOS — it's
enforced/visible only in the Paranoid VM, and macOS's unified log still records
native launches (only the VM keeps launches off the host log entirely).

Source in [`app/`](app/).

---

## Quickstart

```bash
# Host identity rotation
./driftwood.sh selfcheck                 # sanity-check generators (no root, no changes)
./driftwood.sh now --dry-run             # preview what a rotation would change
sudo ./driftwood.sh now                  # rotate hostnames once
sudo DRIFTWOOD_INTERVAL_HOURS=6 DRIFTWOOD_ROTATE_MAC=1 ./driftwood.sh install
sudo ./driftwood.sh uninstall

# Disposable per-app sandboxes
./driftwood.sh run --sandboxed Safari            # native app, fresh throwaway home, 0 GB
./driftwood.sh run --linux ubuntu -- bash        # throwaway Linux box
./driftwood.sh run --macos golden --app Safari   # native app in a disposable VM
```

---

## How it works

macOS has no single "MachineID" — identity is a **layered stack**: hardware
(serial, `IOPlatformUUID`, Secure Enclave), NVRAM (`ROM`/`MLB`), OS (hostnames,
MAC), and your Apple Account (**DSID**). Most layers either **can't** be changed
(hardware-bound) or **must not** be changed while you use iCloud (it de-registers
Apple services).

So driftwood splits the job, Qubes/Whonix-style:

- **On the host** it rotates only the cosmetic, safe layer (hostnames + optionally
  the Wi-Fi MAC) and refuses everything else.
- **For real isolation** it runs each app in a **disposable sandbox** that's
  destroyed and re-identified on exit.

### The iCloud caveat

While you're fully signed into iCloud, host rotation only defeats **LAN and
third-party** tracking. It can't decouple you from Apple: the **DSID** is the
anchor, and MobileGestalt (`MGCopyAnswer`) + the Anisette/ADI auth layer bind
your hardware to that account regardless of hostname or MAC. Defeating
first-party correlation means compartmentalizing iCloud — which is what the
sandbox layer is for.

---

## Host identity rotation

### Safe to rotate

| Identifier | Why it's safe | Who sees it |
|---|---|---|
| `ComputerName` / `LocalHostName` / `HostName` | Cosmetic; services re-register instantly | Broadcast to the whole LAN via Bonjour/mDNS — often leaks your real name |
| Wi-Fi MAC (opt-in) | Link-layer only; resets on reboot | Every network / router / AP you join |

### Refused — driftwood never touches these

| Identifier | What breaks if you rotate it |
|---|---|
| NVRAM `ROM` / `MLB` (iMessage identity pair) | De-registers iMessage & FaceTime; forces iCloud / Apple-Pay re-auth |
| APNs push token | Breaks push for Mail, Messages, and every app |
| Serial, `IOPlatformUUID`, Secure Enclave UID | Hardware-bound — can't change; trying only causes instability |
| Apple Account DSID | Master key of iCloud; only changes with a new Apple ID |

### Commands

```bash
./driftwood.sh now [--dry-run]     # rotate hostnames (+ Wi-Fi MAC if DRIFTWOOD_ROTATE_MAC=1)
./driftwood.sh install             # install the LaunchDaemon (env vars below)
./driftwood.sh uninstall
./driftwood.sh status              # current names / MAC / daemon state
./driftwood.sh selfcheck           # verify the generators
```

`install` drops a root `LaunchDaemon` (`com.driftwood.rotate`) that fires every
`DRIFTWOOD_INTERVAL_HOURS` and on boot.

| Env var | Default | Meaning |
|---|---|---|
| `DRIFTWOOD_INTERVAL_HOURS` | `6` | how often the daemon rotates |
| `DRIFTWOOD_ROTATE_MAC` | `0` | `1` = also rotate the Wi-Fi MAC |
| `DRIFTWOOD_PREFIX` | `Mac` | hostname prefix (e.g. `Mac-1a2b3c4d`) |

### Wi-Fi MAC: prefer the native feature

macOS already randomizes your MAC per network. Before setting
`DRIFTWOOD_ROTATE_MAC=1`, enable the built-in rotation — it's more reliable and
won't fight the OS:

> **Settings → Wi-Fi → (i) on your network → Private Wi-Fi Address → *Rotating***

On Apple Silicon, `ifconfig <dev> ether` can be silently reverted on
association; driftwood logs a warning when that happens. Treat its MAC step as a
scheduled *supplement* to the native *Rotating* setting.

---

## Disposable per-app sandboxes — `driftwood run`

Launch a single app in a throwaway sandbox that's **destroyed and re-identified
on exit**. Three backends, trading isolation against cost:

| Backend | One-time cost | Native macOS app? | What rotates | Isolation |
|---|---|---|---|---|
| `run --linux` | small image | no (Linux) | hostname + MAC + IP, fully ephemeral | own micro-VM |
| `run --sandboxed` | **0 GB** | **yes** | app state (fresh `$HOME`) | process confinement; shares host kernel + real serial |
| `run --macos` | ~16–24 GB once | **yes** | **MAC + serial** + a clean OS | full VM; no iCloud in guest |

Rule of thumb: **`--sandboxed`** for most native apps (instant, free, keeps
iCloud); **`--macos`** when you specifically need the hardware serial to rotate;
**`--linux`** for anything that runs on Linux.

### `--linux` — Linux app in a container

Apple's `container` gives each container its own micro-VM, IP, and MAC; `--rm`
deletes it on exit (cleanup is async — it briefly shows `stopped`, then vanishes).

```bash
driftwood run --linux ubuntu -- bash        # fresh box; gone on exit
driftwood run --linux <image> --dry-run     # print the exact command first
```

Prereq: install Apple `container` (signed `.pkg` from its Releases), then
`container system start`.

### `--sandboxed` — native macOS app, no VM (0 GB)

Runs the real `.app` on the host under a `sandbox-exec` profile with a throwaway
`$HOME` wiped on exit. Instant, no download, keeps iCloud. It rotates *app-level*
state (a fresh home each run ⇒ fresh caches / cookies / UUIDs) and blocks the app
from writing to your real home; `--no-net` also cuts network. It does **not**
rotate the hardware serial — the app still reads the host's real serial via IOKit.

```bash
driftwood run --sandboxed Safari            # fresh throwaway home, wiped on quit
driftwood run --sandboxed Notes --no-net    # ...and no network
driftwood run --sandboxed /path/App.app     # app name, .app path, or binary path
#   --keep   keep the temp home for inspection
```

`sandbox-exec` is deprecated-but-present; reliable for CLI tools and simple apps.
GUI apps that relaunch via LaunchServices/XPC, or read global prefs through
`cfprefsd`, can partially escape the fresh-home redirect. For hard isolation
**and** serial rotation, use `--macos`.

### `--macos` — native macOS app in a disposable VM

The only way to run a real `.app` ephemerally with a *rotated hardware identity*.
`driftwood run --macos` clones a golden VM, gives it a **fresh MAC + serial**
(`tart set --random-mac --random-serial`), launches one app over SSH, and
**deletes the clone when you close the VM window**.

```bash
driftwood run --macos macos-golden --app Safari
driftwood run --macos macos-golden --app Notes --dry-run   # preview the lifecycle
#   --no-rotate  keep the identity     --keep  don't destroy on exit
#   DRIFTWOOD_VM_USER  guest SSH user (default 'admin')
```

**Prepare the golden once** (needs `tart`):

```bash
brew install cirruslabs/cli/tart

# Fastest — prebuilt image with an 'admin' user + Remote Login (SSH) already set:
tart clone ghcr.io/cirruslabs/macos-sequoia-vanilla:latest macos-golden

# Or from scratch (interactive Setup Assistant): create an 'admin' user, enable
# Remote Login (Settings → General → Sharing), sign OUT of iCloud, shut down:
tart create --from-ipsw=latest macos-golden && tart run macos-golden
```

Golden images are tens of GB — that one-time pull dominates setup. Every per-app
clone after it is copy-on-write (≈ no extra disk).

**Limits:**

- macOS guest VMs **can't sign into iCloud/iMessage** (a Virtualization.framework
  limit), so this rotates hardware identity for fingerprinting, not Apple
  first-party correlation.
- Auto-launch needs **Remote Login** enabled in the golden; without it the VM
  still boots and self-destructs on close — you just open the app manually.
- macOS licensing caps ~2 concurrent macOS VMs per host. `--linux` is unlimited.
- Want the Whonix property (guest never learns your real IP)? Chain the VM
  through a Tor/VPN gateway VM. Alternatives to `tart`: UTM, Lima/Colima.

---

## Security notes

- The daemon runs as **root**. `install` copies the script to
  `/usr/local/sbin/driftwood` (`root:wheel`, `0755`) and writes the plist
  (`root:wheel`, `0644`), so a non-root user can't rewrite what root executes.
  Don't point the daemon at a script in a user-writable directory.
- Everything is reversible: `uninstall` removes the daemon and the installed
  copy; rotated names / MACs reset naturally.
- It's a single audited bash script with no network calls — read it before you
  run it as root.

---

## Inspect your own identifiers

Read-only; values stay on your machine:

```bash
scutil --get ComputerName; scutil --get LocalHostName
ioreg -rd1 -c IOPlatformExpertDevice | grep -E 'UUID|Serial'   # hardware-bound, informational
ifconfig "$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline;print $2;exit}')" | grep ether
nvram -p | grep -Ei 'ROM|MLB'                                  # DO NOT rotate these
```

---

## License

MIT — see [LICENSE](LICENSE).
