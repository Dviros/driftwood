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
```

`install` drops a root `LaunchDaemon` (`com.driftwood.rotate`) that fires every
`DRIFTWOOD_INTERVAL_HOURS` (default 6) and on boot.

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
