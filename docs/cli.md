[← driftwood](../README.md)

# The CLI & Host Rotation (driftwood.sh)

`driftwood.sh` is the non-GUI half of the project: a single, root-executed
bash script (11 KB, no dependencies beyond stock macOS tools + `openssl`)
that does two unrelated jobs under one binary:

1. **Host identity rotation** — rewrites the cosmetic hostnames macOS
   broadcasts to every network you join, optionally on a schedule via a
   root `LaunchDaemon`.
2. **`driftwood run`** — launches one app in a throwaway environment from the
   command line: a **Linux container**, a **Seatbelt sandbox**, or a
   **disposable macOS VM**. Only the VM overlaps with the GUI (it's the same
   engine behind the GUI's Paranoid policy); the Linux and Seatbelt backends are
   CLI-only, and the GUI's Casual policy (state-swap, not Seatbelt) has no CLI
   equivalent.

Read it before you run it as root — it's short, and that's the point. See
[gui.md](gui.md) for the SwiftUI app, [paranoid-vm.md](paranoid-vm.md) for
the full VM lifecycle, and [privacy.md](privacy.md) for what any of this
does and doesn't defeat.

---

## Host identity rotation

macOS has no single "machine ID" — identity is a layered stack (hardware,
NVRAM, OS-level names, Apple Account), and most layers either can't be
changed or must not be while you're signed into iCloud. `driftwood.sh`
rotates only the layer that's genuinely safe to touch on a live host.

### Safe to rotate

| Identifier | Why it's safe | Who sees it |
|---|---|---|
| `ComputerName` / `LocalHostName` / `HostName` | Cosmetic; every service re-registers instantly | Broadcast to the whole LAN via Bonjour/mDNS — often leaks your real name |
| Wi-Fi MAC (opt-in) | Link-layer only; resets on reboot | Every network / router / AP you join |

### Refused — driftwood never touches these

| Identifier | What breaks if you rotate it |
|---|---|
| NVRAM `ROM` / `MLB` (iMessage identity pair) | De-registers iMessage & FaceTime; forces iCloud / Apple Pay re-auth |
| APNs push token | Breaks push for Mail, Messages, and every app that relies on it |
| Serial, `IOPlatformUUID`, Secure Enclave UID | Hardware-bound — can't actually be changed; trying only causes instability |
| Apple Account DSID | The master key of iCloud; changes only with a new Apple ID |

`rotate_names()` generates a new hostname as `${PREFIX}-$(openssl rand -hex 4)`
and applies it with three `scutil --set` calls (`ComputerName`,
`LocalHostName`, `HostName`), then flushes the DNS cache and HUPs
`mDNSResponder` so the new name propagates on the LAN immediately.

### Commands

```bash
./driftwood.sh now [--dry-run]     # rotate hostnames (+ Wi-Fi MAC if DRIFTWOOD_ROTATE_MAC=1)
./driftwood.sh install             # install the LaunchDaemon (env vars below)
./driftwood.sh uninstall
./driftwood.sh status              # current names / MAC / daemon state
./driftwood.sh selfcheck           # verify the generators, no root, no changes
```

`now` requires root unless `--dry-run` is passed. `status` prints the
current `ComputerName`/`LocalHostName`, the Wi-Fi interface's MAC (if any),
and whether the LaunchDaemon is loaded.

`selfcheck` is the one command safe to run with zero side effects and no
`sudo` — it exercises the two non-trivial code paths (MAC bit math and
hostname charset) against a sample value and exits non-zero if either is
malformed:

```bash
./driftwood.sh selfcheck
# selfcheck OK  (sample mac=6a:1f:...  host=Mac-9f3ac21b)
```

It checks that the generated MAC has bit `0x02` set (locally-administered)
and bit `0x01` clear (unicast) in its first octet, and that the generated
hostname matches `^[A-Za-z0-9-]+$`.

---

## The root LaunchDaemon

`install` sets up `com.driftwood.rotate` to fire on a schedule and at boot:

```bash
sudo DRIFTWOOD_INTERVAL_HOURS=6 DRIFTWOOD_ROTATE_MAC=1 ./driftwood.sh install
sudo ./driftwood.sh uninstall
```

What `install` actually does:

1. Copies the script itself to `/usr/local/sbin/driftwood`.
2. Writes `/Library/LaunchDaemons/com.driftwood.rotate.plist`, with
   `ProgramArguments` set to `driftwood now`, `StartInterval` set to
   `DRIFTWOOD_INTERVAL_HOURS * 3600` seconds, `RunAtLoad` true, and both
   stdout/stderr redirected to `/var/log/driftwood.log`.
3. Bootstraps it into the system domain
   (`launchctl bootstrap system ...`, falling back to `launchctl load` on
   older macOS).

`uninstall` reverses all of it: `launchctl bootout` (falling back to
`unload`), then removes the plist and the installed script copy.
Nothing about a prior rotation is undone by uninstalling — rotated names
and MACs simply stay as they are (or reset naturally on reboot/reassociation)
since nothing else depended on the old identity.

### Env vars

| Env var | Default | Meaning |
|---|---|---|
| `DRIFTWOOD_INTERVAL_HOURS` | `6` | how often the daemon rotates |
| `DRIFTWOOD_ROTATE_MAC` | `0` | `1` = also rotate the Wi-Fi MAC |
| `DRIFTWOOD_PREFIX` | `Mac` | hostname prefix (e.g. `Mac-1a2b3c4d`) |

Only `DRIFTWOOD_ROTATE_MAC` and `DRIFTWOOD_PREFIX` are baked into the
plist's `EnvironmentVariables` at install time; `DRIFTWOOD_INTERVAL_HOURS`
is consumed once, at install, to compute `StartInterval` — changing it
later requires reinstalling the daemon.

### Security: why root, why these perms

- The daemon runs as **root**, because rotating `ComputerName`/`HostName`
  system-wide requires it.
- `install` copies the script to `/usr/local/sbin/driftwood` owned
  **`root:wheel`, mode `0755`**, and writes the plist owned **`root:wheel`,
  mode `0644`** — so a non-root (and non-`wheel`) user cannot rewrite
  either the script root executes or the job definition that invokes it.
- Corollary: **don't point the daemon at a script living in a
  user-writable directory.** `install` always stages its own copy under
  `/usr/local/sbin`, precisely so the LaunchDaemon never executes anything
  from a path you or another local user could tamper with.
- It's a single audited bash script with no network calls of its own —
  read [`driftwood.sh`](../driftwood.sh) yourself before running it as
  root; that's a five-minute read, not a leap of faith.

---

## Wi-Fi MAC: prefer the native feature

`DRIFTWOOD_ROTATE_MAC=1` makes `now`/the daemon also cycle the Wi-Fi
interface's MAC: it generates a locally-administered, unicast address
(`new_mac()` sets bit `0x02` and clears bit `0x01` in the first octet),
toggles Wi-Fi off, applies it with `ifconfig <dev> ether <mac>`, and
toggles Wi-Fi back on.

Before turning this on, enable macOS's own rotation — it's more reliable
and won't fight the OS:

> **Settings → Wi-Fi → (i) on your network → Private Wi-Fi Address → Rotating**

On Apple Silicon, `ifconfig <dev> ether` can be silently reverted by the
OS on association; `driftwood.sh` logs a warning when this happens
(`ifconfig` failing is caught and logged, not treated as fatal). Treat the
script's MAC step as a scheduled *supplement* to the native *Rotating*
setting, not a replacement for it.

---

## `driftwood run` — the CLI's disposable sandboxes

Three backends — only `--macos` matches the GUI (its Paranoid policy);
`--linux` and `--sandboxed` are CLI-only:

```bash
./driftwood.sh run --sandboxed Safari            # native app, fresh throwaway home, 0 GB
./driftwood.sh run --linux ubuntu -- bash        # throwaway Linux box
./driftwood.sh run --macos golden --app Safari   # native app in a disposable VM
```

Every backend supports `--dry-run`, which prints the exact commands it
would run (and, for `--sandboxed`, the Seatbelt profile it would apply)
without executing anything.

### `--linux` — Apple `container`, one image per throwaway box

```bash
driftwood run --linux ubuntu -- bash        # fresh box; gone on exit
driftwood run --linux <image> --dry-run     # print the exact command first
```

Delegates straight to Apple's `container run --rm --name dw-<rand8hex> <image> ...`.
Each container gets its own micro-VM, IP, and MAC from `container`; `--rm`
destroys it on exit (cleanup is async — it briefly shows `stopped`, then
vanishes). Interactive flags (`-i -t`) are only added when stdin/stdout are
attached to a terminal.

Needs Apple's `container` runtime installed (signed `.pkg` from its
Releases) and `container system start` run once, plus **macOS 26**.

### `--sandboxed` — native macOS app, Seatbelt-confined, no VM

```bash
driftwood run --sandboxed Safari            # fresh throwaway home, wiped on quit
driftwood run --sandboxed Notes --no-net    # ...and no network
driftwood run --sandboxed /path/App.app     # app name, .app path, or binary path
#   --keep   keep the temp home for inspection
```

`resolve_app_binary()` accepts an app name (checked against
`/Applications` and `/System/Applications`), a `.app` bundle path, or a
direct binary path, and resolves it to the actual Mach-O under
`Contents/MacOS/`. `run_sandboxed()` then:

1. Creates a throwaway `$HOME` via `mktemp -d`.
2. Writes a Seatbelt profile (`sandbox-exec` `.sb` file) that starts from
   `(allow default)` and adds `(deny file-write* (subpath "<real $HOME>"))`
   — i.e. it's an allow-by-default profile with one explicit carve-out
   blocking writes back to your *real* home, not a deny-by-default jail.
   `--no-net` adds `(deny network*)` on top.
3. Runs the resolved binary with `HOME` redirected to the throwaway
   directory under that profile.
4. Deletes the throwaway `$HOME` on exit (`trap ... EXIT INT TERM`), unless
   `--keep` was passed.

This is CLI tool territory, not a hard boundary for GUI apps: `sandbox-exec`
is deprecated-but-present, and the README's own testing (the Athas editor)
showed a GUI app can relaunch itself via LaunchServices and step outside a
Seatbelt profile. It rotates **app-level state only** — a fresh `$HOME`
each run means fresh caches/cookies/UUIDs — and it does **not** rotate the
hardware serial; the app still reads the host's real serial via IOKit.
Reliable for CLI tools and simple apps; for hard isolation *and* serial
rotation, use `--macos` (see [paranoid-vm.md](paranoid-vm.md)).

### `--macos` — native app in a disposable VM, with the App Store warning

```bash
driftwood run --macos macos-golden --app Safari
driftwood run --macos macos-golden --app Notes --dry-run   # preview the lifecycle
#   --no-rotate  keep the identity     --keep  don't destroy on exit
#   DRIFTWOOD_VM_USER  guest SSH user (default 'admin')
```

`run_macos()` clones the named golden image
(`tart clone <golden> dw-<rand8hex>`), optionally rotates the clone's
identity (`tart set --random-mac --random-serial`, default on), boots it
(`tart run`), waits for an IP (`tart ip --wait 90`), and launches the app
inside the guest over SSH (`ssh admin@<ip> "open -a '<App>'"`). The clone
is deleted on exit via a `trap ... EXIT INT TERM`, unless `--keep` is
passed — this covers normal exit, Ctrl-C, and TERM alike, so an
interrupted run doesn't leak a VM.

> **App Store apps via the CLI — read before you script this.** Unlike
> `driftwood.app`, which detects App Store apps automatically and
> withholds rotation for them, **`driftwood.sh run --macos` does not
> auto-detect anything.** Rotation defaults to *on*. If the target app is
> an App Store app, its receipt is bound to the Apple ID and machine
> identity that installed it into the golden — rotating serial/MAC on the
> clone voids that receipt and the app exits `173`. You must pass
> `--no-rotate` yourself for any App Store app run through the CLI. There
> is no anonymous way to run an App Store app regardless — `--no-rotate`
> only gets you a clean disposable OS per run, not a rotated identity for
> that app. See [paranoid-vm.md](paranoid-vm.md#the-app-store-reality) for
> the full mechanism.

Needs a prepared golden VM with **Remote Login** enabled — see
[paranoid-vm.md](paranoid-vm.md) for how to build one with `tart`. Without
Remote Login, the VM still boots and self-destructs on window close; you
just have to open the app manually inside the guest.

---

## Requirements

| Feature | Needs |
|---|---|
| Host rotation (`now` / `install`) | macOS 13+ |
| `run --sandboxed` | any macOS (built-in `sandbox-exec`) |
| `run --linux` | macOS 26 + Apple [`container`](https://github.com/apple/container) |
| `run --macos` | Apple Silicon + [`tart`](https://github.com/cirruslabs/tart) + a one-time golden VM |

---

## See also

- [getting-started.md](getting-started.md) — install and first run
- [gui.md](gui.md) — `driftwood.app`, the SwiftUI launcher
- [paranoid-vm.md](paranoid-vm.md) — the Paranoid VM lifecycle in full
- [privacy.md](privacy.md) — threat model and honest ceilings
