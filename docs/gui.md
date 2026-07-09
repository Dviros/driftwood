[← driftwood](../README.md)

# The App (driftwood.app)

A SwiftUI menu-less window that lists every installed app on your Mac,
grouped by source, and launches whichever one you click under a policy you
control — globally or per app. Builds with Command Line Tools only; no
Xcode, no `.xcodeproj`, no macro target.

```bash
cd app
./bundle.sh          # swift build -c release, wrapped into driftwood.app (ad-hoc signed)
open driftwood.app   # move it to /Applications first to skip the Downloads TCC prompt
```

Source: [`app/Sources/Driftwood/`](../app/Sources/Driftwood/) —
`Store.swift` (discovery, policies, monitoring), `StateSwap.swift` (Casual's
journaled stash/restore/commit), `VMManager.swift` (Paranoid VM lifecycle +
network posture), `Traces.swift` (footprint scan + purge), `ContentView.swift`
(UI).

Requirements: macOS 13+ and Command Line Tools (Casual / Persistent run on Intel
Macs too). **Paranoid** additionally needs Apple Silicon,
[`tart`](https://github.com/cirruslabs/tart), a one-time golden VM image, and
`/usr/bin/expect` (ships with macOS) for its SSH automation — see
[paranoid-vm.md](paranoid-vm.md).

---

## The grid

![driftwood](screenshots/grid.png)

`Store.rescan()` walks `/Applications`, `/Applications/Utilities`,
`/Applications/Setapp`, `/System/Applications`,
`/System/Applications/Utilities`, and `~/Applications`, collecting every
`*.app` bundle. Each one is read for its `CFBundleIdentifier` and classified
into a source group:

| Group | How it's detected |
|---|---|
| **App Store** | `Contents/_MASReceipt/receipt` exists in the bundle |
| **System** | path starts with `/System/` |
| **User (~)** | path starts with your home directory |
| **Applications** | everything else (`/Applications`, Setapp, etc.) |

The search field filters by name (case-insensitive substring) across all
groups at once. A green dot on an app's icon means it's currently running
under driftwood; the click-to-launch/click-to-close label under the name
tells you which action a click will take, and while running, a live
`CPU% · MB` readout updates every 2 seconds.

---

## The three policies

Set from the segmented control in the top bar — this is the **global
default**. Right-click any app card to override it for that one app; the
override persists (in `UserDefaults`, keyed by bundle ID) and shows as a blue
badge on the card. Choosing "Use default" from the context menu clears the
override.

| Policy | Mechanism | What rotates | Real confinement? |
|---|---|---|---|
| **Casual** | Native launch; real `~/Library` state is stashed to a journaled, crash-safe session dir before launch, then wiped (or archived, with *Ask on close*) | App-level state — fresh caches, cookies, saved UUIDs every launch | No — normal process on your real kernel, real hardware identity; only its on-disk profile is ephemeral |
| **Persistent** | Normal launch, nothing stashed | Nothing | No — this is just "run the app" |
| **Paranoid** | Disposable macOS VM: instant APFS linked clone of a golden image, serial + MAC rotated, app launched inside the guest, clone destroyed on window close | Hardware identity (serial, MAC) + the entire OS instance | Yes — the only policy with a real process/kernel boundary |

> **Why not just sandbox the process on the host?** Because it doesn't hold.
> `sandbox-exec` was verified escapable against a real GUI app (the Athas
> editor) — it relaunches itself via LaunchServices and steps outside the
> profile. For App Store / system apps, the state that matters lives in
> `~/Library/Containers`, which is TCC-locked — no unprivileged tool
> (driftwood included) can stash-and-swap it. **Casual only fully isolates
> non-sandboxed apps.** If you need an actual process/kernel boundary, that's
> Paranoid — see [paranoid-vm.md](paranoid-vm.md).

Clicking a running app's card calls `stop()`, which asks
`NSRunningApplication` to `terminate()` it; cleanup (restoring or archiving
stashed state) runs from the app-termination notification, not from the
click itself — so quitting the app from its own Quit menu tears down the
sandbox exactly the same way as clicking the card again.

### Casual: the state-swap mechanism

Casual's ephemerality comes from `StateSwap`, which treats the user's real
`~/Library` as data that must never be lost — the failure mode it's
engineered against is data loss, not confinement (confinement is what
Paranoid is for).

**Stash (before launch).** For the app's bundle ID, `StateSwap` looks for a
fixed list of state locations relative to `~/Library`:

```
Containers/<bundleID>
Application Support/<appName>
Application Support/<bundleID>
Preferences/<bundleID>.plist
Caches/<bundleID>
HTTPStorages/<bundleID>
HTTPStorages/<bundleID>.binarycookies
WebKit/<bundleID>
Cookies/<bundleID>.binarycookies
Saved Application State/<bundleID>.savedState
```

Whichever of those exist get moved into a per-launch session directory under
`~/Library/Application Support/driftwood/sessions/<uuid>/`. Before *each*
individual move, the intent (`orig` path → `stash` path) is written to that
session's `journal.json` — atomically, via write-to-temp-then-`replaceItemAt`
— so the on-disk record of "what got moved where" always exists before the
move itself happens. `cfprefsd` is then killed (it caches preferences and
would otherwise rewrite the plist you just moved out from under it) so the
app sees a clean slate. The app now launches with none of its prior caches,
cookies, saved UUIDs, or window state.

**Restore (discard, the default on close).** Reads the journal and, for each
entry, only deletes the real (`orig`) path once it has confirmed the matching
`stash` path is actually present to put back in its place — never the other
order. This means a crash mid-restore can leave the stash sitting there
unmoved, but it can never delete real data with nothing to replace it.
`cfprefsd` is bounced again, then the now-empty session directory is removed.

**Commit ("Keep" from Ask-on-close).** Instead of restoring, the session
directory itself is moved into `~/Library/Application Support/driftwood/archive/<uuid>/`
and the app's current (session) state simply stays where it already is — live.
Nothing is deleted; your prior real profile is archived, not discarded, so
the choice is reversible by hand later.

**Crash recovery.** `StateSwap.recoverAll()` runs once at app launch, before
anything else. It lists every directory under
`.../driftwood/sessions/`, and for each one still sitting there — meaning the
app that owned it never got a clean restore/commit, e.g. driftwood itself
crashed or was force-quit mid-session — it runs the same journal-driven
`restore()` on it. So an interrupted session self-heals the next time you
open driftwood.app, with no separate "did we crash last time" flag to get out
of sync: the sessions directory itself *is* the crash record.

### Ask on close

A checkbox in the top bar. Off (default): closing a Casual app silently
restores — the throwaway profile is gone, your real profile is exactly as you
left it. On: closing prompts **Discard** (restore) vs **Keep** (commit), so
you can promote a session's state to become your new real profile when you
want to (e.g., you signed into something during the sandboxed run and want to
keep that login).

---

## Data: Blank vs Cloned

Independent of the policy, a **Data** control (top bar, or per-app via
right-click) sets what state the app starts from:

| Mode | The app sees | Your real data |
|---|---|---|
| **Blank** (default) | a fresh profile — no cookies, logins, history, or config | moved safely aside (Casual) or untouched on the host (Paranoid); restored on close |
| **Cloned** | a **throwaway copy of your real profile** — logged in, your settings | copied via APFS copy-on-write (instant); the copy is discarded on close, your real data is never modified |

**Cloned** is what makes "run my real, logged-in browser — disposably" work: the
session starts from a clone of your actual profile, and on close that clone is
thrown away while your real profile is untouched. It's journaled and crash-safe
exactly like Blank — the session always works on a *copy*, never your original
(verified by the built-in `selftest`).

TCC rule (same as Casual): Casual can clone **non-sandboxed** apps only (App
Store containers are TCC-locked). For an App Store app, use **Paranoid + Cloned**
— the VM path seeds a copy of its container, but driftwood needs **Full Disk
Access** to read it (see [paranoid-vm.md](paranoid-vm.md)).

---

## Activity & traces

The chart-icon button in the top bar opens the inspector, which has two
independent sections.

**Running sessions.** A table of every app driftwood currently has open, each
row backed by a live 2-second poll of `ps -axo pid=,ppid=,%cpu=,rss=` plus
`proc_pid_rusage` for disk I/O:

| Column | Detail |
|---|---|
| App / Policy | which policy launched this instance |
| CPU / Memory | **summed across the entire process tree**, not just the main PID — so Electron/Chromium helper processes are counted, not invisible |
| Disk I/O | cumulative bytes read+written per the tree, via `RUSAGE_INFO_V4` |
| Procs | process count in that tree |

There's no network column here or anywhere in driftwood — macOS doesn't
expose per-process network usage to unprivileged apps, and driftwood doesn't
try to work around that.

**On-disk footprint.** driftwood's own honest ledger of what it has left on
your disk, split into two categories:

- **Protected** (never auto-deleted): active stashes (`sessions/`, i.e. a
  Casual app currently running with its real state parked) and commit
  archives (`archive/`, i.e. profiles you chose to Keep). Both hold your real
  data.
- **Safe to remove**: orphaned sandbox temp homes (stray `dw-sbx.*` dirs in
  `$TMPDIR`, left over from `driftwood run --sandboxed` sessions that didn't
  clean up) and leftover `tart` VM clones (any `dw-*` VM still registered from
  a Paranoid session that didn't get torn down).

**Clean orphans** runs `Traces.purgeOrphans()`: it deletes only the safe
category — stray temp homes and `tart delete`s any leftover `dw-*` clones. It
never touches `sessions/` or `archive/`, so it structurally cannot delete an
active stash or a kept profile, however aggressively you click it.

The inspector is also explicit about what it can't hide: macOS's unified log
still records every native app launch on the host, regardless of policy — no
unprivileged tool, driftwood included, can suppress that. The one exception
is Paranoid: because the app never actually runs on the host, a Paranoid
launch leaves nothing in the host's log at all. Details on the VM lifecycle,
network postures, and the App Store constraint live in
[paranoid-vm.md](paranoid-vm.md).

---

## See also

- [getting-started.md](getting-started.md) — install and first run
- [paranoid-vm.md](paranoid-vm.md) — golden image, clone lifecycle, network postures, App Store apps
- [cli.md](cli.md) — the `driftwood.sh` host rotation daemon and `driftwood run` sandboxes
- [privacy.md](privacy.md) — threat model, guarantees, and the iCloud caveat
