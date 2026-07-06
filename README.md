# driftwood

**Ephemeral identity rotation for macOS.** Keep the host clean by rotating the
handful of identifiers that are *safe* to change on a live machine, and push all
aggressive rotation into disposable per-app VMs/containers (Qubes/Whonix style).

> **Scope & ethics.** This is a personal-privacy tool for hardware **you own**.
> It reduces cross-network and third-party fingerprinting. It is not an
> anti-forensics or fraud tool, and it cannot make you anonymous to Apple while
> you are signed into iCloud (see *The honest caveat*). Apple Silicon / macOS 13+.

---

## TL;DR

```bash
./driftwood.sh selfcheck        # sanity-check the generators (no root, no changes)
./driftwood.sh now --dry-run    # show what a rotation WOULD change
sudo ./driftwood.sh now         # rotate hostnames once, now
sudo DRIFTWOOD_INTERVAL_HOURS=6 DRIFTWOOD_ROTATE_MAC=1 ./driftwood.sh install
sudo ./driftwood.sh uninstall

./driftwood.sh run --linux ubuntu -- bash           # throwaway Linux app box
./driftwood.sh run --sandboxed Safari                # native app, Seatbelt-confined, fresh home (0 GB)
./driftwood.sh run --macos golden --app Safari       # native app in a throwaway VM (rotates serial+MAC)
```

`install` drops a root `LaunchDaemon` (`com.driftwood.rotate`) that fires every
`DRIFTWOOD_INTERVAL_HOURS` (default 6) and on boot.

---

## Disposable per-app sandboxes: `driftwood run`

Run a single app in a throwaway sandbox that is **destroyed and re-identified on
exit**. Three ways, trading isolation against cost — pick per app:

| Approach | Command | One-time cost | Native macOS app? | What rotates | Isolation |
|---|---|---|---|---|---|
| Linux container | `run --linux` | small image | no (Linux) | hostname + MAC + IP, fully ephemeral | own micro-VM |
| Seatbelt sandbox | `run --sandboxed` | **0 GB** | **yes** | app state (fresh `$HOME`) | process confinement; shares host kernel + real serial |
| Disposable macOS VM | `run --macos` | ~16–24 GB once | **yes** | **MAC + serial** + a clean OS | full VM; no iCloud in guest |

Rule of thumb: `--sandboxed` for most native apps (instant, free, keeps iCloud);
`--macos` when you specifically need the hardware serial/MAC to rotate; `--linux`
for anything that can run in Linux.

### Linux apps — fully working

Apple's [`container`](https://github.com/apple/container) gives every container
its own micro-VM, IP, and MAC; `--rm` deletes it on exit.

```bash
driftwood run --linux ubuntu -- bash          # fresh box; gone when you exit
driftwood run --linux <image> --dry-run       # print the exact command first
```

Prereq: install Apple `container` (v1.0.0 signed `.pkg` from its Releases), then
`container system start`.

### Native macOS apps, no VM — Seatbelt (`--sandboxed`, 0 GB)

Runs the real `.app` on the host under a `sandbox-exec` profile with a throwaway
`$HOME` wiped on exit. No download, instant, keeps iCloud. It rotates *app-level*
state (fresh home each run ⇒ fresh caches/cookies/UUIDs) and blocks the app from
writing to your real home; `--no-net` also cuts network. It does **not** rotate
the hardware serial — the app still sees the host's real serial via IOKit.

```bash
driftwood run --sandboxed Safari                # fresh throwaway home, wiped on quit
driftwood run --sandboxed Notes --no-net        # ...and no network
driftwood run --sandboxed /path/to/App.app      # or a full .app / binary path
#   --keep   keep the temp home for inspection
```

Caveats: `sandbox-exec` is deprecated-but-present; reliable for CLI tools and
simple apps. GUI apps that relaunch via LaunchServices/XPC, or read global prefs
through `cfprefsd`, can partially escape the fresh-home redirect. For hard
isolation **and** hardware-identity rotation, use `--macos` below.

### Native macOS apps, full VM — tart (`--macos`)

There is **no container for native macOS apps** — the only way to run a real
`.app` ephemerally is a disposable macOS VM. `driftwood run --macos` clones a
golden VM, rotates its MAC, launches one app, and **deletes the clone when you
close the VM window**.

```bash
driftwood run --macos macos-golden --app Safari
driftwood run --macos macos-golden --app Notes --dry-run    # preview the lifecycle
#   flags:  --no-rotate  (keep the MAC)      --keep  (don't destroy on exit)
#   env:    DRIFTWOOD_VM_USER  (guest SSH user; default 'admin')
```

**Prepare the golden once** (Apple Silicon; needs [`tart`](https://github.com/cirruslabs/tart)):

```bash
brew install cirruslabs/cli/tart

# Fastest: a prebuilt image that already has an 'admin' user + Remote Login (SSH).
tart clone ghcr.io/cirruslabs/macos-sequoia-vanilla:latest macos-golden

# Or from scratch (interactive Setup Assistant): install macOS, create an 'admin'
# user, enable Remote Login (Settings > General > Sharing), sign OUT of iCloud,
# shut down.
tart create --from-ipsw=latest macos-golden && tart run macos-golden
```

Images are large (tens of GB); the first pull/install dominates setup time.

**Honest limits of the macOS path:**

- Each run gets a **fresh MAC + serial number** (`tart set --random-mac
  --random-serial`) on a copy-on-write clone (near-instant, ~no extra disk), so
  the guest identity rotates per app. The guest still can't use iCloud (a
  Virtualization.framework limit), so this defeats app/network fingerprinting,
  not Apple first-party correlation.
- Auto-launch needs **Remote Login (SSH) enabled** in the golden. Without it the
  VM still boots and self-destructs on close — you just open the app manually.
- macOS guest VMs **cannot sign into iCloud/iMessage**, and macOS licensing caps
  ~2 concurrent macOS VMs per host. The `--linux` backend is unlimited.

---

## Why so little runs on the host

macOS has no single "MachineID". It has a **layered stack** of identifiers, and
most of them either **can't** be changed (hardware-bound) or **must not** be
changed while you use iCloud (doing so de-registers Apple services). The design
principle: *the host rotates only what is cosmetic and safe; everything else is
compartmentalized into throwaway VMs.*

### Safe to rotate on the host

| Identifier | Why it's safe | Who sees it |
|---|---|---|
| `ComputerName` / `LocalHostName` / `HostName` | Cosmetic; services re-register instantly | **Broadcast to the whole LAN via Bonjour/mDNS** — often leaks your real name |
| Wi-Fi MAC (opt-in) | Link-layer only; reset on reboot anyway | Every network/router/AP you join |

### NEVER rotate on the host (driftwood refuses to touch these)

| Identifier | What breaks if you rotate it |
|---|---|
| NVRAM `ROM` / `MLB` (the iMessage identity pair) | **De-registers iMessage & FaceTime**, triggers iCloud/Apple-Pay re-auth |
| APNs push token | Breaks push for Mail, Messages, and every app until re-provisioned |
| Serial, `IOPlatformUUID`, Secure Enclave UID | Hardware-bound — **cannot** be changed; attempting it only causes instability |
| Apple Account DSID | The master key of everything iCloud; only changes with a new Apple ID |

This is exactly why the real privacy gains live in the VM layer below.

---

## The honest caveat

While you are **fully signed into iCloud**, none of the host rotation decouples
you from Apple. The Apple Account **DSID** is the anchor, and MobileGestalt
(`MGCopyAnswer`) + the Anisette/ADI auth layer bind your *hardware* identity to
that account regardless of hostname or MAC. Host rotation defeats **LAN and
third-party** tracking. Defeating **first-party (Apple) correlation** requires
reducing or compartmentalizing iCloud — which is what the VM model is for.

---

## Wi-Fi MAC: prefer the native feature

macOS already randomizes your MAC per-network. Before enabling `DRIFTWOOD_ROTATE_MAC=1`,
turn on the built-in rotation, which is more reliable and won't fight the OS:

> **Settings → Wi-Fi → (i) on your network → Private Wi-Fi Address → *Rotating***

On Apple Silicon, `ifconfig <dev> ether` can be silently reverted by the system
on association; driftwood logs a warning when that happens. The native
*Rotating* setting is the primary mechanism; driftwood's MAC step is a
best-effort supplement for networks where you want a fresh MAC on a schedule.

---

## Security notes

- The daemon runs as **root**. `install` copies the script to
  `/usr/local/sbin/driftwood` owned `root:wheel`, `0755`, and writes the plist
  `root:wheel`, `0644` — so a non-root user can't rewrite what root executes.
  Don't point the daemon at a script in a user-writable directory.
- Everything is reversible: `uninstall` removes the daemon and the installed
  copy. Rotated names/MACs are cosmetic and reset naturally.
- Read the whole script; it's ~120 lines with no network calls.

---

## The VM / container layer (the part that actually matters)

Model, borrowed from **Qubes** (disposable per-activity VMs) and **Whonix**
(force all traffic through a Tor gateway VM): the **host stays boring and
consistent**; sensitive work runs in **short-lived VMs that are cloned from a
golden image, given a fresh MAC + machine identifier, used, then destroyed.**

### The disposable pattern

```
golden base image  ──clone──▶  ephemeral-<app>  ──use──▶  destroy
                                 │
                                 ├─ fresh MAC
                                 ├─ fresh machine identifier (VM "serial")
                                 └─ no personal accounts baked in
```

### Tooling on Apple Silicon

| Tool | Best for | Notes |
|---|---|---|
| **[`container`](https://github.com/apple/container)** (Apple, macOS 26) | Per-app **Linux** workloads | Native OCI containers; `container run --rm` is ephemeral by default. Closest to "Apple's own containers." |
| **[`tart`](https://github.com/cirruslabs/tart)** | macOS **or** Linux VMs | Thin wrapper over Virtualization.framework. `tart clone base ephemeral-$id` → run → `tart delete`; each clone gets its own MAC + machine identifier. |
| **[UTM](https://mac.getutm.app/)** | GUI VMs, QEMU or VZ backend | Easy disposable snapshots; can set a random MAC per VM. |
| **[Lima](https://github.com/lima-vm/lima) / [Colima](https://github.com/abiosoft/colima)** | Scriptable Linux dev VMs | Good for a per-project throwaway Linux box. |
| **[Whonix](https://www.whonix.org/)** (Gateway + Workstation) | Tor-routed VM | Run the pair under UTM/QEMU; the Workstation can only reach the network through the Tor Gateway. |

### Example: a fresh, throwaway Linux box per app (tart)

```bash
brew install cirruslabs/cli/tart
tart clone ghcr.io/cirruslabs/ubuntu:latest golden      # one-time golden image
# per session:
ID=$(openssl rand -hex 3)
tart clone golden "ephemeral-$ID"                        # fresh clone = fresh MAC + machine id
tart run "ephemeral-$ID"                                 # ...do the work...
tart delete "ephemeral-$ID"                              # nothing persists
```

Chain it through a VPN/Tor gateway VM for the Whonix property (the workstation
never learns your real IP).

### Honest limits of the VM approach

- **macOS *guest* VMs cannot sign into iCloud / iMessage.** Apple's
  Virtualization.framework macOS guests lack a provisioned identity, so a
  "rotated macOS-with-iCloud per app" setup is **not achievable**. Use **Linux**
  guests/containers for app compartmentalization; use macOS guests only for
  Mac-only software that doesn't need iCloud.
- **Licensing:** virtualizing macOS is permitted only on Apple hardware and
  historically limited to ~2 concurrent macOS VMs per host. Linux VMs/containers
  are unrestricted.
- **Requires Apple Silicon** (or a T2 Intel Mac, with more limits).

---

## Inspect your own identifiers

Read-only; run locally (values stay on your machine):

```bash
scutil --get ComputerName; scutil --get LocalHostName
ioreg -rd1 -c IOPlatformExpertDevice | grep -E 'UUID|Serial'   # hardware-bound, informational
ifconfig "$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline;print $2;exit}')" | grep ether
nvram -p | grep -Ei 'ROM|MLB'                                  # DO NOT rotate these
```

---

## License

MIT — see [LICENSE](LICENSE).
