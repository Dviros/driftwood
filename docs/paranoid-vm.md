[← driftwood](../README.md)

# Paranoid — Disposable VMs

Paranoid is the one policy with a real process/kernel boundary: every launch
happens inside a throwaway macOS VM — a fresh MAC and serial number, a clean
OS instance, and nothing left behind when you close the window.

```
Casual      → app-level state swap, same kernel, same hardware identity
Persistent  → normal launch, nothing rotates
Paranoid    → disposable VM, hardware identity + whole OS instance rotate
```

See [gui.md](gui.md) for how the three policies are chosen and badged in the
app, and [README.md#honest-ceilings](../README.md#honest-ceilings) for what
none of this can do.

---

## The golden image

Paranoid clones don't boot from scratch — they're **APFS copy-on-write linked
clones** of a single "golden" macOS VM you pull once.

- **Download golden (~25 GB, once)** — the GUI pulls
  `ghcr.io/cirruslabs/macos-sequoia-vanilla` via [`tart`](https://github.com/cirruslabs/tart)
  (`VMManager.swift`, `downloadGolden()`). The exact size is set by the image
  publisher, not driftwood.
- Every clone made from it afterward is instant and ≈0 extra disk — a linked
  clone, not a fresh 25 GB copy.
- From the CLI, prepare it yourself:

  ```bash
  brew install cirruslabs/cli/tart

  # Fastest — prebuilt image with an 'admin' user + Remote Login already set:
  tart clone ghcr.io/cirruslabs/macos-sequoia-vanilla:latest macos-golden

  # Or from scratch (interactive Setup Assistant): create an 'admin' user,
  # enable Remote Login (Settings → General → Sharing), sign OUT of iCloud,
  # shut down:
  tart create --from-ipsw=latest macos-golden && tart run macos-golden
  ```

Remote Login (SSH) on the golden is what lets driftwood open the app inside
the guest automatically. Without it the VM still boots and still
self-destructs on close — you just launch the app by hand once it's up.

---

## Lifecycle, one launch

```
click an app card (policy = Paranoid)
              │
              ▼
  tart clone driftwood-golden dw-<rand8>
  (APFS copy-on-write — ~0 extra disk, ~instant)
              │
              ▼
      isAppStore == true?
     ┌────────┴────────┐
    NO                 YES
     │                  │
     ▼                  ▼
tart set --random-mac   keep golden's MAC/serial
  --random-serial       (App Store receipt is machine-
                          bound; rotating it → exit 173)
     └────────┬────────┘
              ▼
  [optional] scutil --nc start <VPN>
  wait until "Connected" (native NetworkExtension:
  Tailscale / ProtonVPN / WireGuard) — up BEFORE boot
              ▼
  tart run <net-flags> dw-<rand8>   (VM window opens)
              ▼
      tart ip dw-<rand8> --wait 120
              ▼
ssh admin@<guest-ip> 'open -a "<App>" && echo DW_OK'
     ┌────────┴────────┐
already in golden   not in golden (non-MAS only)
     │                  │
     ▼                  ▼
opens instantly    scp the .app bundle in, then
                    open it from /Users/admin/
     └────────┬────────┘
              ▼
   app runs INSIDE the guest macOS —
   your host apps are not in this VM
              ▼
     user closes the VM window
              ▼
tart delete dw-<rand8>   (clone destroyed —
nothing about this session persists)
```

Source: `app/Sources/Driftwood/VMManager.swift`, `launch(appPath:appName:isAppStore:)`.
The diagram above is the **GUI** path. The CLI's `run_macos()` in
[`driftwood.sh`](../driftwood.sh) is similar but simpler: it takes **no network
flags** (always Full / shared NAT — see below), waits `--wait 90` (not 120), and
does **not** auto-detect App Store apps (pass `--no-rotate` yourself for those).

**Rotation is conditional on one check**: is this an App Store app? If yes,
the clone keeps the golden's MAC/serial — see
[The App Store reality](#the-app-store-reality) below for why. The GUI makes
this check for you (`isAppStore`); the CLI does not (see
[CLI vs GUI: who detects App Store apps](#cli-vs-gui-who-detects-app-store-apps)).

---

## Network postures

Picked per session from the top bar — **GUI only.** The CLI's `run --macos`
always uses **Full / shared NAT**; there is no CLI flag for Isolated, Offline,
or VPN routing. All four are enforced **at the VM boundary only** — the host
app itself was never and can never be network-gated by this mechanism.

| Posture | Mechanism | Effect |
|---|---|---|
| **Full** | Shared NAT (`tart run` default, no extra flags) | Normal outbound access, like any VM on a home network |
| **Isolated** | `--net-softnet` | A private virtual network — off your LAN, still has a path out |
| **Offline** | `--net-softnet --net-softnet-block=0.0.0.0/0` | Softnet with everything blocked — no network at all |
| **Route through a native VPN** | `scutil --nc list` enumerates your macOS `NetworkExtension` VPNs (Tailscale, ProtonVPN, WireGuard, anything registered), driftwood connects the one you pick and polls `scutil --nc status` for `Connected` **before the VM boots**, then the guest's shared-NAT traffic egresses through it | Whatever your VPN provider gives you — its exit node is the guest's exit node |

The VPN list isn't hardcoded — it's rebuilt from `scutil --nc list` every
time the Paranoid bar appears in the GUI, so any VPN profile you add on the
host shows up automatically (`VMManager.swift`, `listVPNs()` / `refreshNet()`).

This is a **whole-VM** posture, not per-process: everything running inside
that one guest shares whatever posture you picked for the session. There's no
per-app network rule inside the VM.

---

## Getting apps into the VM

**Your installed host apps aren't inside the VM — it's a separate macOS
instance.** There are exactly two ways an app ends up runnable in a clone:

### 1. Self-contained copy-in (per-launch, non-App-Store only)

If the app isn't already present in the golden, driftwood `scp`'s the `.app`
bundle into the fresh clone and opens it from `/Users/admin/`:

```
ssh admin@<ip> 'open -a "<App>"'     # tried first — already in golden?
      │ fails
      ▼
scp -r <app.app> admin@<ip>:/Users/admin/
ssh admin@<ip> 'open "/Users/admin/<App>.app"'
```

This is **best-effort**. It works well for self-contained bundles (Electron
apps, simple direct downloads). Apps that expect an installer, a system
framework, or files outside their own bundle may not run unmodified. This
path is only attempted for non-App-Store apps — see below.

### 2. Manage golden (one-time, persists across every future clone)

For App Store apps, system apps, or anything you want present in *every*
clone without a copy-in step each time: **Manage golden** boots the golden
image read-write and opens the App Store for you.

```bash
# GUI: click "Manage golden" in the Paranoid bar
# equivalent manually:
tart run macos-golden
```

You sign in and install normally inside that booted golden, then shut it
down. Every clone made from the golden afterward carries the app pre-installed
— no per-launch copy, no re-download. `VMManager.swift`'s `manageGolden()`
does exactly this: boot the golden, wait for an IP, `ssh` in and
`open -a "App Store"`.

Signing into the App Store during "Manage golden" authorizes that Apple ID on
the golden exactly as it would on any Mac — driftwood just opens the App
Store for you; the account linking is Apple's doing, not driftwood's.

---

## The App Store reality

There is **no anonymous way to run an App Store app.** This is the one place
driftwood says "no" up front, on purpose.

- An App Store app's license is a receipt
  (`Contents/_MASReceipt/receipt`) cryptographically bound to your Apple ID
  **and** the Secure Enclave of the machine that installed it.
- That binding is non-copyable — it can't be lifted into a clone with a
  different hardware identity.
- Rotate a clone's serial/MAC *after* an App Store app is installed on it,
  and the app rejects its own receipt outright: **`exit 173`**.

So the tradeoff driftwood ships, honestly: App Store and system apps installed
via Manage golden run in every clone **without identity rotation** for that
clone. You still get a clean, disposable OS each time — no leftover state, no
cross-session correlation from the app's own cookies/caches/UUIDs — but not a
rotated hardware identity, because that identity is exactly what the receipt
is checked against.

This isn't a gap driftwood could close with more engineering. The license is
bound to your Apple ID and the authorization keys are Secure-Enclave-bound and
non-copyable by design — no tool routes around that.

### CLI vs GUI: who detects App Store apps

The GUI tracks `isAppStore` per app (from how it discovered the app — see
[gui.md](gui.md)) and skips rotation automatically when you launch one under
Paranoid.

The CLI (`driftwood run --macos <golden> --app <name>`) has no such detection
— it always rotates unless you tell it not to:

```bash
driftwood run --macos macos-golden --app "App Store App" --no-rotate
```

Forget `--no-rotate` on an App Store app and the clone boots with a fresh
serial/MAC, the receipt fails, and the app exits `173`. This is the single
sharpest edge in the CLI path — see [cli.md](cli.md) for the rest of
`run --macos`'s flags.

---

## Honest limitations

Carried over from the README's [Honest ceilings](../README.md#honest-ceilings)
and specific to the VM path:

1. **macOS guest VMs can't sign into iCloud/iMessage** — a
   Virtualization.framework limit, not a driftwood choice. Paranoid rotates
   hardware identity for third-party fingerprinting purposes; it does not
   and cannot touch Apple first-party correlation. See
   [privacy.md](privacy.md#the-icloud-caveat).
2. **Auto-launch needs Remote Login enabled in the golden.** Without it the
   VM still boots and still self-destructs on window close — you just have
   to open the app by hand once it's up.
3. **~2 concurrent macOS VMs per host**, an Apple licensing cap on
   Virtualization.framework guests — not a driftwood limit. `driftwood run
   --linux` has no such cap.
4. **No anonymous App Store apps**, covered above — a hard Apple platform
   constraint.
5. **No network-usage telemetry per VM.** The Activity inspector
   (`Traces.swift`) reports CPU/memory/disk/proc-tree for host processes; it
   has no per-VM network metric, and the network posture picker is a
   boundary you set going in, not something you can observe afterward from
   inside driftwood.
6. **Copy-in is best-effort.** Apps that expect an installer, license
   daemon, or system framework outside their own bundle may not run
   unmodified when `scp`'d into a clone — the reliable path for those is
   Manage golden.
7. **Want the Whonix property** (the guest never learns your real IP)?
   driftwood's own network postures don't provide that — chain the VM
   through a Tor/VPN gateway VM yourself, or rely on the native-VPN posture
   above if your provider's client supports it. Alternatives to `tart`: UTM,
   Lima/Colima (not integrated with driftwood).

---

## Requirements

| Needs | Why |
|---|---|
| Apple Silicon | `tart` / Virtualization.framework requirement |
| macOS 13+ | Same |
| [`tart`](https://github.com/cirruslabs/tart) (`brew install cirruslabs/cli/tart`) | Clone/boot/network/delete the golden and its clones |
| One-time golden VM | Everything above depends on it existing first |

---

**See also**: [getting-started.md](getting-started.md) for first-run setup,
[gui.md](gui.md) for the policy picker and per-app overrides, [cli.md](cli.md)
for `driftwood run --macos` flags, [privacy.md](privacy.md) for what Paranoid
does and doesn't defeat.
