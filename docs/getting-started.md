[← driftwood](../README.md)

# Getting Started

## Requirements

Requirements are per-feature — you don't need `tart` or Apple `container` just
to rotate your hostname.

| Feature | Needs |
|---|---|
| Host rotation (`driftwood.sh now` / `install`) | macOS 13+ |
| `driftwood.app` (GUI) — Casual / Persistent | macOS 13+, Command Line Tools (no Xcode) |
| `driftwood.app` (GUI) — Paranoid | above, + [`tart`](https://github.com/cirruslabs/tart) + a one-time golden VM |
| `run --sandboxed` | any macOS (built-in `sandbox-exec`) |
| `run --linux` | macOS 26 + Apple [`container`](https://github.com/apple/container) |
| `run --macos` | Apple Silicon + [`tart`](https://github.com/cirruslabs/tart) + a one-time golden VM |

Only the **VM tiers** (Paranoid / `run --macos`) require Apple Silicon — `tart`
is Apple Silicon–only. Host rotation, Casual, Persistent, and `run --sandboxed`
run on Intel Macs too.

---

## Installing the GUI (`driftwood.app`)

**Builds with Command Line Tools only — no Xcode.** The whole toolchain is
Swift Package Manager: there's no `.xcodeproj` and no macro target.

```bash
cd app
./bundle.sh          # swift build -c release, then hand-assembles driftwood.app
open driftwood.app
```

`bundle.sh` runs `swift build -c release`, copies the binary into
`driftwood.app/Contents/MacOS/`, writes `Info.plist`
(`LSMinimumSystemVersion` 13.0), and ad-hoc `codesign`s the bundle so it runs
locally without a paid Developer ID.

**Move it to `/Applications` before you open it.** Launching straight out of
`~/Downloads` trips the Downloads-folder TCC prompt the first time the app
touches anything outside its own bundle; `/Applications` doesn't have that
restriction.

```bash
mv driftwood.app /Applications/
open /Applications/driftwood.app
```

If Gatekeeper still balks on first launch (ad-hoc signed, not notarized):
right-click the app → **Open** → **Open** in the dialog. You only do this once.

### First run

The GUI opens on a list of every installed app, grouped by source (App Store
/ System / User / Applications). Global policy (**Casual** / **Persistent** /
**Paranoid**) is set from the top bar; right-click any card to override the
policy for just that app — the override persists and shows as a badge on the
card.

- **Casual** and **Persistent** work immediately, no extra setup.
- **Paranoid** surfaces VM controls in the top bar and needs `tart` + a golden
  image — see below. Until that's done, the app reports **no golden** and
  won't launch under Paranoid.

---

## Installing the CLI (`driftwood.sh`)

No install step — it's a single bash script, run in place:

```bash
./driftwood.sh selfcheck                 # sanity-check the generators, no root, no changes
./driftwood.sh now --dry-run             # preview a rotation
sudo ./driftwood.sh now                  # rotate ComputerName/LocalHostName/HostName once
sudo DRIFTWOOD_INTERVAL_HOURS=6 DRIFTWOOD_ROTATE_MAC=1 ./driftwood.sh install
```

`install` copies the script to `/usr/local/sbin/driftwood` (`root:wheel`,
`0755`) and drops a root `LaunchDaemon`
(`/Library/LaunchDaemons/com.driftwood.rotate.plist`, `root:wheel`, `0644`) —
a non-root user can't rewrite what root executes. `uninstall` removes both and
is fully reversible; rotated names and MACs reset naturally.

Read the script before running it as root — it's a single audited file with
no network calls of its own: [`driftwood.sh`](../driftwood.sh).

### For `run --sandboxed` / `--linux` / `--macos`

These are subcommands of the same script — nothing extra to install for
`--sandboxed` (uses the built-in `sandbox-exec`). `--linux` needs Apple
`container` (macOS 26); `--macos` needs `tart` + a golden image, same as the
GUI's Paranoid tier — see the next section.

---

## Installing `tart` + the one-time golden (for Paranoid / `run --macos`)

Both the GUI's **Paranoid** policy and the CLI's `run --macos` share this
setup. It's a one-time pull; every launch after it is an instant,
copy-on-write clone.

```bash
brew install cirruslabs/cli/tart
```

Then get a golden VM image. Two paths:

**Fastest — prebuilt image, `admin` user + Remote Login already configured:**

```bash
tart clone ghcr.io/cirruslabs/macos-sequoia-vanilla:latest macos-golden
```

The GUI does this for you: click **Download golden (~25 GB, once)** in the
Paranoid top bar — it pulls the same image
(`ghcr.io/cirruslabs/macos-sequoia-vanilla:latest`) via `tart` and names the
local clone `driftwood-golden`.

**Or from scratch** (interactive Setup Assistant) if you want to build the
image yourself:

```bash
tart create --from-ipsw=latest macos-golden && tart run macos-golden
```

Inside that VM: create an `admin` user **with the password `admin`** (the GUI's
SSH automation assumes exactly this and can't prompt for a different one), enable
**Remote Login** (Settings → General → Sharing), **sign out of iCloud**, then
shut down. The prebuilt `macos-sequoia-vanilla` image already ships `admin`/`admin`.

Either way, the exact download size is set by the image publisher, not
driftwood — every session after the pull is an APFS copy-on-write linked
clone, ≈0 extra disk and near-instant.

**Signing into the App Store inside this golden** (via **Manage golden** in
the GUI, or manually) lets every future clone run that app — see
[gui.md](gui.md) for the App Store tradeoff (clones running an App Store app
skip identity rotation, or the receipt voids with `exit 173`).

### Notes and limits

- macOS guest VMs **can't sign into iCloud/iMessage** — a
  Virtualization.framework limit. This rotates hardware identity for
  fingerprinting, not Apple first-party correlation ([privacy.md](privacy.md)).
- Auto-launch needs **Remote Login** enabled in the golden; without it the VM
  still boots and self-destructs on close, you just open the app manually
  inside it.
- macOS licensing caps ~2 concurrent macOS VMs per host. `run --linux` has no
  such cap.
- The GUI's Paranoid automation (auto-launching the app, **Manage golden**)
  shells out to `/usr/bin/expect` to drive SSH. It ships with macOS; the
  `driftwood.sh` CLI path doesn't use it.
- **Cloned** data mode copies your real app data into the clone so the app opens
  logged in. Non-sandboxed apps need nothing extra; to seed an **App Store**
  app's data (its TCC-protected `~/Library/Containers`), grant driftwood **Full
  Disk Access** (System Settings ▸ Privacy & Security ▸ Full Disk Access).

---

## Verify it works — `selfcheck`

`driftwood.sh selfcheck` sanity-checks the two non-trivial generators —
**no root, no changes to your system**:

```bash
./driftwood.sh selfcheck
```

It generates a sample MAC and hostname and asserts:

- the MAC is **locally-administered** (bit `0x02` set) and **unicast** (bit
  `0x01` clear) — so it can never collide with a real vendor-assigned MAC
- the hostname matches `^[A-Za-z0-9-]+$` — safe for `scutil`/Bonjour

```
$ ./driftwood.sh selfcheck
selfcheck OK  (sample mac=... host=Mac-a1b2c3d4)
```

Anything else printed means the generators broke — file it before you `sudo
install` the daemon.

For the GUI, there's no separate selfcheck: launch it, confirm the app list
populates, and try one **Casual** launch — close the window and check the
app's `~/Library` state came back clean (see [gui.md](gui.md)). For Paranoid,
the top bar itself reports state (**no golden** / **ready** / downloading
progress), which is your readiness signal.

To confirm current host state at any time:

```bash
./driftwood.sh status
```

---

## Next steps

- [gui.md](gui.md) — the three GUI policies (Casual / Persistent / Paranoid) in depth
- [cli.md](cli.md) — full `driftwood.sh` command reference
- [paranoid-vm.md](paranoid-vm.md) — the Paranoid VM lifecycle, network postures, App Store caveat
- [privacy.md](privacy.md) — threat model, what driftwood defeats, the iCloud caveat
