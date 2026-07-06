#!/usr/bin/env bash
# driftwood — ephemeral identity rotation for macOS (host-safe subset)
#
# Rotates ONLY the identifiers that are safe to change on a live host without
# breaking iCloud/iMessage/FaceTime/Apple Pay:
#   - ComputerName / LocalHostName / HostName   (Bonjour/mDNS broadcast name)
#   - Wi-Fi MAC address                         (opt-in; briefly drops Wi-Fi)
#
# It deliberately does NOT touch: NVRAM ROM/MLB (the iMessage identity pair),
# APNs push token, serial, or IOPlatformUUID. See README for why.
#
# Subcommands: now | install | uninstall | status | selfcheck   [--dry-run]
#   run --linux <image> [-- cmd...]          ephemeral Linux app (Apple container)
#   run --macos <golden> --app <name>        ephemeral native macOS app (tart VM)
set -euo pipefail

# ---- config (env-overridable; install bakes these into the LaunchDaemon) ----
INTERVAL_HOURS="${DRIFTWOOD_INTERVAL_HOURS:-6}"   # how often the daemon fires
ROTATE_MAC="${DRIFTWOOD_ROTATE_MAC:-0}"           # 1 = also rotate Wi-Fi MAC
HOSTNAME_PREFIX="${DRIFTWOOD_PREFIX:-Mac}"        # hostname prefix

LABEL="com.driftwood.rotate"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
DEST="/usr/local/sbin/driftwood"
LOG="/var/log/driftwood.log"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
DRY=0

log()  { echo "$(/bin/date '+%Y-%m-%dT%H:%M:%S') $*"; }
die()  { echo "driftwood: $*" >&2; exit 1; }
need_root() { [[ ${EUID} -eq 0 ]] || die "run as root (sudo)"; }
need()      { command -v "$1" >/dev/null 2>&1 || die "missing '$1' — $2"; }

# ---- generators ----
new_hostname() { echo "${HOSTNAME_PREFIX}-$(openssl rand -hex 4)"; }

# Locally-administered, unicast MAC: set bit 0x02, clear bit 0x01 in octet 1.
new_mac() {
  local b1
  b1=$(( 0x$(openssl rand -hex 1) & 0xFC | 0x02 ))
  printf '%02x:%s:%s:%s:%s:%s\n' "${b1}" \
    "$(openssl rand -hex 1)" "$(openssl rand -hex 1)" \
    "$(openssl rand -hex 1)" "$(openssl rand -hex 1)" "$(openssl rand -hex 1)"
}

wifi_device() { networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2; exit}'; }

# ---- rotations ----
rotate_names() {
  local h; h="$(new_hostname)"
  if (( DRY )); then log "[dry] names -> ${h}"; return 0; fi
  scutil --set ComputerName  "${h}"
  scutil --set LocalHostName "${h}"
  scutil --set HostName      "${h}"
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
  log "names -> ${h}"
}

rotate_mac() {
  local dev mac; dev="$(wifi_device || true)"
  [[ -n "${dev}" ]] || { log "no Wi-Fi device; skip MAC"; return 0; }
  mac="$(new_mac)"
  if (( DRY )); then log "[dry] ${dev} MAC -> ${mac}"; return 0; fi
  log "cycling ${dev}, MAC -> ${mac}"
  networksetup -setairportpower "${dev}" off || true
  ifconfig "${dev}" ether "${mac}" 2>/dev/null \
    || log "warn: 'ifconfig ether' rejected (Apple Silicon can revert it; prefer native Rotating Private Address — see README)"
  networksetup -setairportpower "${dev}" on || true
}

# ---- commands ----
cmd_now() {
  (( DRY )) || need_root
  rotate_names
  (( ROTATE_MAC )) && rotate_mac || true
  log "rotation complete"
}

cmd_status() {
  echo "ComputerName:  $(scutil --get ComputerName  2>/dev/null || echo -)"
  echo "LocalHostName: $(scutil --get LocalHostName 2>/dev/null || echo -)"
  local dev; dev="$(wifi_device || true)"
  [[ -n "${dev}" ]] && echo "Wi-Fi ${dev} MAC: $(ifconfig "${dev}" 2>/dev/null | awk '/ether/{print $2}')"
  if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "daemon: loaded (every ${INTERVAL_HOURS}h)"
  else
    echo "daemon: not loaded"
  fi
}

# Runnable check for the two non-trivial paths (MAC bit math, hostname charset).
cmd_selfcheck() {
  local m hexfirst h
  m="$(new_mac)"; hexfirst="0x${m%%:*}"
  (( (hexfirst & 0x02) == 0x02 )) || die "MAC not locally-administered: ${m}"
  (( (hexfirst & 0x01) == 0 ))    || die "MAC not unicast: ${m}"
  h="$(new_hostname)"
  [[ "${h}" =~ ^[A-Za-z0-9-]+$ ]] || die "bad hostname charset: ${h}"
  echo "selfcheck OK  (sample mac=${m} host=${h})"
}

cmd_install() {
  need_root
  install -m 755 -o root -g wheel "${SELF}" "${DEST}"
  cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>${DEST}</string><string>now</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>DRIFTWOOD_ROTATE_MAC</key><string>${ROTATE_MAC}</string>
    <key>DRIFTWOOD_PREFIX</key><string>${HOSTNAME_PREFIX}</string>
  </dict>
  <key>StartInterval</key><integer>$(( INTERVAL_HOURS * 3600 ))</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG}</string>
  <key>StandardErrorPath</key><string>${LOG}</string>
</dict></plist>
EOF
  chown root:wheel "${PLIST}"; chmod 644 "${PLIST}"
  launchctl bootstrap system "${PLIST}" 2>/dev/null || launchctl load "${PLIST}"
  echo "installed: rotates every ${INTERVAL_HOURS}h (MAC rotation=${ROTATE_MAC}). Log: ${LOG}"
}

cmd_uninstall() {
  need_root
  launchctl bootout "system/${LABEL}" 2>/dev/null || launchctl unload "${PLIST}" 2>/dev/null || true
  rm -f "${PLIST}" "${DEST}"
  echo "uninstalled"
}

# ---- disposable per-app sandboxes ----
# Linux app: Apple `container` gives each one its own micro-VM + IP + MAC; --rm
# destroys it on exit. Fully ephemeral, identity fresh per run.
run_linux() {
  local image="$1"; shift || true
  [[ -n "${image}" ]] || die "run --linux needs an image (e.g. ubuntu)"
  local name="dw-$(openssl rand -hex 4)" tty=""
  [[ -t 0 && -t 1 ]] && tty="-i -t"   # interactive only when attached to a terminal
  if (( DRY )); then echo "+ container run --rm ${tty:--i -t} --name ${name} ${image} $*"; return 0; fi
  need container "install Apple's runtime: https://github.com/apple/container/releases"
  log "ephemeral linux container ${name} <- ${image} (dies + rotates on exit)"
  exec container run --rm ${tty} --name "${name}" "${image}" "$@"
}

# Native macOS app: clone a golden VM, rotate its identity (MAC + serial),
# launch ONE app inside, destroy the clone when its window closes.
# Needs a prepared golden with Remote Login enabled (see README).
run_macos() {
  local golden="$1" app="$2" rotate="$3" keep="$4"
  [[ -n "${golden}" && -n "${app}" ]] || die "run --macos needs <golden> and --app <name>"
  local clone="dw-$(openssl rand -hex 4)" user="${DRIFTWOOD_VM_USER:-admin}"
  if (( DRY )); then
    echo "+ tart clone ${golden} ${clone}"
    (( rotate )) && echo "+ tart set ${clone} --random-mac --random-serial"
    echo "+ tart run ${clone} &                       # VM window"
    echo "+ ip=\$(tart ip ${clone} --wait 90)"
    echo "+ ssh ${user}@\${ip} \"open -a '${app}'\"      # launch app inside"
    (( keep )) || echo "+ tart delete ${clone}          # when the window closes"
    return 0
  fi
  need tart "brew install cirruslabs/cli/tart"
  local cleanup="tart delete '${clone}' >/dev/null 2>&1 || true"
  (( keep )) && cleanup=":"
  trap "${cleanup}" EXIT INT TERM
  log "clone ${golden} -> ${clone}"
  tart clone "${golden}" "${clone}"
  (( rotate )) && { tart set "${clone}" --random-mac --random-serial || log "note: identity rotation failed"; }
  tart run "${clone}" &
  local vm=$!
  local ip; ip="$(tart ip "${clone}" --wait 90 2>/dev/null || true)"
  [[ -n "${ip}" ]] \
    || { log "VM never got an IP; close the window to clean up"; wait "${vm}" 2>/dev/null || true; return 1; }
  log "VM ${clone} up @ ${ip}; launching '${app}'. Close the VM window to destroy it."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${user}@${ip}" \
      "open -a '${app}'" 2>/dev/null || log "note: auto-launch failed; open '${app}' from the VM desktop"
  wait "${vm}" 2>/dev/null || true   # blocks until the window closes -> trap destroys the clone
}

cmd_run() {
  local backend="" target="" app="" rotate=1 keep=0
  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --linux) backend=linux ;;
      --macos) backend=macos ;;
      --app) app="${2:-}"; shift ;;
      --no-rotate) rotate=0 ;;
      --keep) keep=1 ;;
      --dry-run) DRY=1 ;;
      --) shift; rest=("$@"); break ;;
      -*) die "run: unknown flag $1" ;;
      *) [[ -z "${target}" ]] && target="$1" || rest+=("$1") ;;
    esac
    shift || true
  done
  case "${backend}" in
    linux) run_linux "${target}" ${rest[@]+"${rest[@]}"} ;;
    macos) run_macos "${target}" "${app}" "${rotate}" "${keep}" ;;
    *) die "run: use  --linux <image> [-- cmd...]  OR  --macos <golden> --app <name>" ;;
  esac
}

# ---- dispatch ----
CMD="${1:-now}"; [[ $# -gt 0 ]] && shift
case "${CMD}" in
  now|install|uninstall|status|selfcheck)
    for a in "$@"; do [[ "${a}" == "--dry-run" ]] && DRY=1; done
    "cmd_${CMD}" ;;
  run) cmd_run "$@" ;;
  -h|--help) grep '^# ' "${SELF}" | sed 's/^# //'; exit 0 ;;
  *) die "unknown command: ${CMD} (try: now install uninstall status selfcheck run)" ;;
esac
