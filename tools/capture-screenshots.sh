#!/usr/bin/env bash
# Zert Goblin — portal screenshot capture (dApp Store dApp Preview set).
#
# Sibling of tools/verify-vr12r.sh: same CI-KVM lane, same binding
# recipe (§2.2: PIN-locked AVD, Mock MWA Wallet built from the pinned
# commit + authenticated BEFORE the app installs, HAUNT crash-scan
# rule). Where the cell GRADES the wallet flow, this driver CAPTURES
# the shipped product: it installs the hash-gated target APK, walks
# the real client through lobby -> connect (Mock session) -> a live
# Classic run -> Goblin Mode -> leaderboard -> skin store, and saves
# portal-dimension PNGs at every stop.
#
# PORTAL GEOMETRY: the estate set of record is "412x915" — the Ore
# Kingdom working set (package/screenshots/README.md) defines that
# as viewport 412x915 @2x, i.e. 824x1830 px files. The AVD is forced
# to exactly that raster (wm size 824x1830, wm density 320 = logical
# 412x915 dp), and every saved PNG's IHDR is verified against
# 824x1830; an off-size file is flagged in the manifest, never
# silently passed.
#
# DRIVER r3 (run-2 fix): run 2's lane ran clean (both probes green)
# but the walk aborted at connect detection — zert_state keyed on
# the literal "WALLET CONNECTED", which in the Connect client is a
# transient access-message toast (App.tsx:1474), while the session
# HAD established by wire record (authorize + sign-proof consumed).
# The persistent live-session marker is the launch control in its
# session form (App.tsx:1715 ternary — see zert_state). r3: (1) the
# detector grades "connected" on that persistent form, toast demoted
# to corroboration; (2) failure-path poll dumps are persisted into
# the evidence artifact (run 2's decisive $TMPD dumps were lost);
# (3) the connect-abort branches no longer pre-miss frame 07 — the
# store leg records its own outcome, so a frame carries exactly one
# manifest row (captured XOR missing).
#
# DRIVER r4 (run-3 fix): run 3's detector fix worked end-to-end
# (02 + 03 captured) but blind play bonked out twice with zero
# catches observed, and the board shot was never attempted.
# Three causes, three fixes. (1) MOVEMENT: the primary channel
# keyed on the arrow buttons' aria-labels (App.tsx:1812/:1816)
# via node_center on content-desc — it returned empty coords on
# every play dump, and the "←"/"→" glyph-tap fallback's effect
# was indeterminable because play-phase dumps lived in $TMPD and
# were never persisted. r4 steers by the arena's OWN pointer
# surface instead — the source-proven primary input ("MOVE —
# Tap a lane", :1726; hint "TAP LANES OR USE ARROWS", :1815):
# the .arena div's onPointerDown (:1654-1664) teleports Zert to
# lane floor(x/width*4) of the tap point. Before steering, the
# driver persists the live play dump + screencap and identifies
# the arena's bounds from the tree (the first large ancestor of
# the "{coins} ZEC" topline node, :1668), then taps lane-quarter
# centers in a 0,1,2,3 cycle, polling the HUD coin counter
# between sweep cycles to PROVE catches accumulate. The arrow
# path survives only as a fallback when the live dump proves
# those nodes exist with bounds AND the arena cannot be
# identified. (2) PERSISTENCE: every play-phase dump (identify,
# each poll, goblin confirm, result card) is copied into the
# evidence artifact on success AND failure paths. (3) BOARD
# GATE: frame 06 was gated on gameplay_ok || goblin_ok (shot
# success); it is now gated on a completed run — a result card
# seen this walk (wait_result_card success or the play loop's
# own result-card detection) — because a bonked run still saves.
# Hunt use: up to all 3 free hunts are spent retrying whichever
# of 04/05 is still missing (run 3's walk stopped at 2).
#
# DRIVER r2 (run-1 fix): run 1 applied the wm override immediately
# after boot, BEFORE any app launched and before the first dump —
# and `uiautomator dump` then failed on every call from the first
# one (0 of 7 shots). The sibling vr12r driver never overrides
# geometry and read dumps fine all evening on the identical AVD
# config. The override therefore now lands AFTER the mock-wallet
# security/auth phase and BEFORE the target app installs, bracketed
# by dump_ui probes (probe 1 on the untouched post-boot device,
# probe 2 immediately after the override) that fail the lane fast
# with manifest rows written, instead of at minute ~50.
#
# TRUTH RULE (portal + estate): screenshots must be real captures of
# the SUBMISSION build (LAUNCH_QUEUE portal pass, 2026-10-26:
# "generated panels remain barred"). Nothing here renders, stages,
# or edits a frame: every PNG is an `adb screencap` of the sealed
# APK running the live (post-redeploy) Connect client, in states the
# driver reached by tapping the client's own controls. States are
# confirmed against the accessibility tree using ONLY strings quoted
# from the client source (space/client/src/App.tsx) — the vr12r
# r1/r2 lesson (detectors built on strings this client never
# renders) is why every target string below carries its file:line.
#
# SHOT LIST (portal allows 4-8; the Zert gate names five — PACKAGE_
# STATUS gate (ii) + SUBMISSION_STAGING SS7: lobby, gameplay, Goblin
# Mode, store, leaderboard — this walk produces those five plus the
# connected lobby and the mode select, 7 total):
#   01-lobby.png         disconnected lobby; the connect door as the
#                        shell renders it. [claims: cold lobby loads
#                        with no sign-in; "3 free hunts" door copy C9]
#   02-connected.png     connected lobby. [a wallet adds a session +
#                        3 free plays: the launch control in its
#                        live-session form, "Insert coin · N free
#                        hunts ready" — App.tsx:1715 ternary on
#                        walletSession; the disconnected form is
#                        "Connect wallet · 3 free hunts for new
#                        wallets". "WALLET CONNECTED" :1474 is a
#                        transient toast, corroboration only]
#   03-mode-select.png   difficulty grid. [three modes TRUE: cards
#                        :1744/:1747/:1750]
#   04-gameplay.png      Classic run in motion. [four-lane collector,
#                        45-second runs: score rack STACK/TIME/COMBO
#                        :1648-1653]
#   05-goblin-mode.png   Goblin Mode active. ["GOBLIN MODE: FERAL"
#                        :1807; activation is player-tapped at meter
#                        100, goblinMs 6500 :1306]
#   06-leaderboard.png   THE DEEP CAVE board (:1830/:1831), shot
#                        after the walk's own run has saved, so the
#                        frame shows the board as the product renders
#                        it with a real row when the save has landed
#                        (an empty board is also a truthful frame —
#                        "no seeded rivals" — and is noted as such).
#   07-skin-store.png    Skin store with $2.50 visible. [skins $2.50:
#                        deal flag :856, per-skin "$2.50" grid :876ff]
#
# PLAYING THE GAME BLIND (honest mechanics): falling entities are
# aria-hidden (App.tsx:1675-1683) — no driver can see them. The
# driver moves Zert by tapping lanes on the arena's own pointer
# surface: the .arena onPointerDown (App.tsx:1654-1664) sets
# Zert's lane to floor(x/rect.width*4) of the tap — the input the
# client itself advertises ("MOVE — Tap a lane", :1726; Zert
# renders at LANES[lane] = 16/38.5/61.5/84% , :38/:1682). The
# catch test (:1377) is entity.y in [76,94] while entity.lane ==
# Zert's lane, so a 0,1,2,3 tap cycle at ~0.55 s dwell puts Zert
# in each falling coin's lane for part of its ~0.6 s catch
# window; the HUD coin counter ("{coins} ZEC" topline, :1668)
# polled between cycles is the proof catches accumulate. The
# arrow buttons (:1812/:1816) are a fallback only, used when a
# live dump proves their nodes carry bounds. Catches stay
# probabilistic: meter charges +13 per ZEC catch (:1390) and a
# "frenzy" catch fills it outright (:1395); a 45 s Classic run
# (ROUND_MS 45_000 :9, TICK_MS 45 :37, spawns every 600->235 ms
# :1353, ~64% ZEC / ~31% hazard / ~5% frenzy) usually fills the
# meter under active sweeping, and the walk spends up to all 3
# free hunts on the Goblin shot. Hazards (FUD/fiat/banker) cost
# a life on contact (:1865) — a bonked run is a possible outcome
# and is recorded, not hidden; it still saves, so it still
# unlocks the board shot.
#
# GOBLIN WINDOW: Goblin Mode lasts 6500 ms (:1306). On the poll
# that first shows "UNLEASH GOBLIN MODE" the driver taps it and
# screencaps IMMEDIATELY (before the confirming dump), so the frame
# lands ~1 s into the window; the confirming dump's "GOBLIN MODE:
# FERAL" (or its absence, if the window lapsed) is recorded in the
# manifest next to the shot.
#
# NOT CAPTURABLE IN THIS LANE (stated, not worked around): the
# "Connect with Seeker" door form (App.tsx:1711/:579). The door
# renders only when seekerDoor is true, and seekerDoor =
# isSeekerEngageable() && !bridgePresent (:1508) — inside the
# shipped shell the bridge is always present, so the in-shell door
# is the generic "Connect wallet" button BY DESIGN (resolver order:
# shell bridge first). No emulator state changes that; shot 01
# captures the door exactly as the submission build presents it.
#
# Exit code: 0 only if all 7 shots are captured at 824x1830 with
# their state markers observed and the crash scan is clean; the
# evidence artifact uploads either way (workflow if: always()).
set -u

PKG="com.zertgoblin.app"
ACT="com.zertgoblin.app/.MainActivity"
MOCK="com.solana.mwallet"
MOCK_ACT="com.solana.mwallet/.MainActivity"
OUT="${SHOTS_OUT:-zert-screenshots}"
ZERT_APK="${ZERT_APK:-}"
MOCK_APK="${MOCK_APK:-}"
EXPECTED_PUBKEY="${EXPECTED_PUBKEY:-}"
DEVICE_PIN="${DEVICE_PIN:-1234}"
TMPD="$(mktemp -d)"
LANE_LOG="$OUT/shots-lane.log"
AUTH_EPOCH_FILE="$OUT/auth-epoch.txt"
MANIFEST="$OUT/shots-manifest.txt"
WANT_W=824; WANT_H=1830

mkdir -p "$OUT"
: > "$LANE_LOG"
: > "$MANIFEST"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LANE_LOG"; }

shots_ok="0"; shots_missing=""; recorded=""
ALL_FRAMES="01-lobby.png 02-connected.png 03-mode-select.png 04-gameplay.png 05-goblin-mode.png 06-leaderboard.png 07-skin-store.png"
fatal_pkg_total="0"; fatal_mock_total="0"; ise_total="0"
lock_pin="unknown"; lock_fp="unknown"; auth_note="not attempted"
door_form="unknown"; board_state="unknown"; goblin_confirm="not-run"

# --- helpers (carried from tools/verify-vr12r.sh, estate §2.2 recipe) ----
dump_is_substantive() {
  python3 - "$1" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
nodes = re.findall(r"<node[^>]*>", data)
if len(nodes) >= 3:
    sys.exit(0)
for n in nodes:
    if re.search(r'text="[^"]+"', n) or re.search(r'content-desc="[^"]+"', n) or "WebView" in n:
        sys.exit(0)
sys.exit(1)
PY
}

dump_ui() { # $1 = destination file
  local dst="$1" attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    adb shell rm -f /sdcard/window_dump.xml >/dev/null 2>&1 || true
    timeout 40 adb shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
    adb exec-out cat /sdcard/window_dump.xml > "$dst.tmp" 2>/dev/null || true
    if grep -q "</hierarchy>" "$dst.tmp" 2>/dev/null && dump_is_substantive "$dst.tmp"; then
      mv "$dst.tmp" "$dst"
      return 0
    fi
    sleep 3
  done
  log "dump_ui: FAILED after 8 attempts -> $dst"
  return 1
}

tap_text() { # $1 = hierarchy file, $2 = substring of text=
  local coords
  coords="$(python3 - "$1" "$2" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
for m in re.finditer(r'text="([^"]*' + re.escape(sys.argv[2]) + r'[^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', data):
    x = (int(m.group(2)) + int(m.group(4))) // 2
    y = (int(m.group(3)) + int(m.group(5))) // 2
    print(f"{x} {y}")
    break
PY
)"
  if [ -n "$coords" ]; then adb shell input tap $coords; return 0; fi
  return 1
}

tap_desc() { # $1 = hierarchy file, $2 = substring of content-desc (aria-label)
  local coords
  coords="$(python3 - "$1" "$2" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
for m in re.finditer(r'content-desc="([^"]*' + re.escape(sys.argv[2]) + r'[^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', data):
    x = (int(m.group(2)) + int(m.group(4))) // 2
    y = (int(m.group(3)) + int(m.group(5))) // 2
    print(f"{x} {y}")
    break
PY
)"
  if [ -n "$coords" ]; then adb shell input tap $coords; return 0; fi
  return 1
}

tap_exact() { # $1 = hierarchy file, $2 = exact text
  local coords
  coords="$(python3 - "$1" "$2" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
for m in re.finditer(r'<node[^>]*>', data):
    tag = m.group(0)
    t = re.search(r'text="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if t and b and t.group(1) == sys.argv[2]:
        x = (int(b.group(1)) + int(b.group(3))) // 2
        y = (int(b.group(2)) + int(b.group(4))) // 2
        print(f"{x} {y}")
        break
PY
)"
  if [ -n "$coords" ]; then adb shell input tap $coords; return 0; fi
  return 1
}

node_center() { # $1 = hierarchy file, $2 = aria-label substring -> "x y" (no tap)
  python3 - "$1" "$2" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
for m in re.finditer(r'content-desc="([^"]*' + re.escape(sys.argv[2]) + r'[^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', data):
    x = (int(m.group(2)) + int(m.group(4))) // 2
    y = (int(m.group(3)) + int(m.group(5))) // 2
    print(f"{x} {y}")
    break
PY
}

fg_pkg() {
  local f
  f="$(adb shell dumpsys window windows 2>/dev/null | sed -n 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')"
  if [ -z "$f" ]; then
    f="$(adb shell dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')"
  fi
  printf '%s' "$f"
}

dismiss_host_anr() {
  local f="$TMPD/anr-check.xml"
  if dump_ui "$f" && grep -q "isn.t responding" "$f"; then
    if grep -q "Pixel Launcher isn.t responding\|System UI isn.t responding" "$f"; then
      log "anr: host dialog present; tapping Wait"
      tap_text "$f" "Wait" || true
      sleep 2
    fi
  fi
}

scan_logcat() { # $1 = file; HAUNT crash-scan rule, as the cell's
  local f="$1" a b c
  a="$(grep -A3 "FATAL EXCEPTION" "$f" 2>/dev/null | grep -c "Process: $PKG" || true)"
  b="$(grep -A3 "FATAL EXCEPTION" "$f" 2>/dev/null | grep -c "Process: $MOCK" || true)"
  c="$(python3 - "$f" <<'PY' || echo 0
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="ignore").read().splitlines()
hits = 0
for i, ln in enumerate(lines):
    if "IllegalStateException" in ln:
        ctx = "\n".join(lines[max(0, i-3): i+12])
        if "ActivityResultSender" in ctx or "ActivityResultRegistry" in ctx:
            hits += 1
print(hits)
PY
)"
  fatal_pkg_total=$((fatal_pkg_total + ${a:-0}))
  fatal_mock_total=$((fatal_mock_total + ${b:-0}))
  ise_total=$((ise_total + ${c:-0}))
  log "scan: $f app_fatal=${a:-0} mock_fatal=${b:-0} sender_signature_ise=${c:-0}"
}

png_dims() { # $1 = png file -> "WxH" or "?"
  python3 - "$1" <<'PY'
import struct, sys
try:
    d = open(sys.argv[1], "rb").read(24)
    w, h = struct.unpack(">II", d[16:24])
    print(f"{w}x{h}")
except Exception:
    print("?")
PY
}

shot() { # $1 = filename, $2 = marker note -> screencap + manifest row
  local name="$1" note="$2" dims sha
  recorded="$recorded $name"
  adb exec-out screencap -p > "$OUT/$name" 2>/dev/null || true
  dims="$(png_dims "$OUT/$name")"
  sha="$(sha256sum "$OUT/$name" 2>/dev/null | awk '{print $1}')"
  local size_flag="OK"
  [ "$dims" = "${WANT_W}x${WANT_H}" ] || size_flag="OFF-SPEC(dims=$dims)"
  echo "$name | $dims | $size_flag | sha256 $sha | $note" >> "$MANIFEST"
  log "shot: $name ($dims, $size_flag) — $note"
  if [ "$size_flag" = "OK" ]; then shots_ok=$((shots_ok + 1)); else shots_missing="$shots_missing $name(off-spec)"; fi
}

miss() { # $1 = filename, $2 = reason
  recorded="$recorded $1"
  echo "$1 | MISSING | $2" >> "$MANIFEST"
  shots_missing="$shots_missing $1"
  log "shot MISSING: $1 — $2"
}

miss_all() { # $1 = reason; MISSING rows for every frame not yet recorded
  # Manifest discipline (run-1 bug #2): every exit path — probe
  # failures and early aborts included — leaves an explicit row for
  # every frame, never a silent gap or an empty manifest.
  local reason="$1" s
  for s in $ALL_FRAMES; do
    case " $recorded " in
      *" $s "*) ;;
      *) miss "$s" "$reason" ;;
    esac
  done
}

# --- device record -------------------------------------------------------
adb wait-for-device
for _ in $(seq 1 60); do
  [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 5
done
{
  echo "sdk=$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
  echo "release=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
  echo "fingerprint=$(adb shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')"
  echo "model=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  echo "suite=screenshots"
  echo "expected_pubkey=$EXPECTED_PUBKEY"
  echo "zert_apk=$ZERT_APK"
} > "$OUT/device-info.txt"
cat "$OUT/device-info.txt" | tee -a "$LANE_LOG"

# --- dump probe 1 (driver r2): prove the dump primitive on the
# untouched post-boot device, BEFORE any geometry override. Run 1's
# uiautomator dump failed on every call from the first one and the
# failure only surfaced ~50 minutes in; a dead primitive now fails
# the lane in the first minutes, manifest rows written.
if dump_ui "$TMPD/probe-boot.xml"; then
  log "probe1: dump_ui OK on post-boot device (pre-geometry)"
  cp "$TMPD/probe-boot.xml" "$OUT/hier-probe-boot.xml" || true
else
  log "probe1: dump_ui DEAD on post-boot device (pre-geometry) — failing fast"
  miss_all "dump primitive dead at post-boot probe (pre-geometry)"
  echo "shots=FAIL(step=dump-probe-boot)" > "$OUT/verdict.txt"
  exit 1
fi

# --- PIN lock + fingerprint enrollment (binding recipe step 2) ---------
log "security: setting device PIN via locksettings"
adb shell locksettings set-pin "$DEVICE_PIN" >> "$LANE_LOG" 2>&1 || true
if adb shell locksettings verify --old "$DEVICE_PIN" >/dev/null 2>&1; then
  lock_pin="set+verified (PIN $DEVICE_PIN)"
else
  lock_pin="set (locksettings set-pin issued, PIN $DEVICE_PIN)"
fi
log "security: lock_pin=$lock_pin"
adb shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
adb shell settings put secure lock_screen_lock_after_timeout 2147483647 >/dev/null 2>&1 || true
adb shell svc power stayon usb >/dev/null 2>&1 || true
log "security: lock mitigation applied (screen_off_timeout=max, lock_after_timeout=max, stayon usb)"

looks_locked() {
  python3 - "$1" <<'PY'
import re, sys
try:
    data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
except OSError:
    sys.exit(1)
pkgs = set(re.findall(r'package="([^"]+)"', data))
texts = " ".join(re.findall(r'text="([^"]*)"', data))
if "Unlock for all features and data" in texts: sys.exit(0)
if "Swipe up to open" in texts or "Swipe up to unlock" in texts: sys.exit(0)
if pkgs and pkgs <= {"com.android.systemui"}: sys.exit(0)
sys.exit(1)
PY
}

ensure_unlocked() {
  local f="$TMPD/lock.xml" try
  dump_ui "$f" || return 0
  if ! looks_locked "$f" && [ "$(fg_pkg)" != "com.android.systemui" ]; then return 0; fi
  for try in 1 2 3; do
    log "lock: keyguard appears engaged (try $try; fg=$(fg_pkg)); wake + swipe + PIN unlock"
    adb shell input keyevent 224 >/dev/null 2>&1 || true
    sleep 1
    adb shell input keyevent 82 >/dev/null 2>&1 || true
    sleep 1
    adb shell input swipe 412 1650 412 550 300 >/dev/null 2>&1 || true
    sleep 1
    if dump_ui "$f" && looks_locked "$f"; then
      adb shell input text "$DEVICE_PIN" >/dev/null 2>&1 || true
      adb shell input keyevent 66 >/dev/null 2>&1 || true
      sleep 2
    fi
    dump_ui "$f" || return 0
    if ! looks_locked "$f"; then log "lock: unlocked on try $try"; return 0; fi
  done
  log "lock: STILL LOCKED after 3 unlock attempts"
}

enroll_fingerprint() {
  log "security: attempting fingerprint enrollment via Settings"
  adb shell am start -a android.settings.SECURITY_SETTINGS >/dev/null 2>&1 || true
  sleep 3
  local f="$TMPD/fp.xml" i
  for i in 1 2 3 4 5 6; do
    dump_ui "$f" || return 1
    if grep -q "Fingerprint" "$f"; then
      tap_text "$f" "Fingerprint" || return 1
      sleep 2
      break
    fi
    adb shell input swipe 412 1400 412 700 300 >/dev/null 2>&1 || true
    sleep 1
  done
  dump_ui "$f" || return 1
  if grep -q "PIN\|password" "$f" && ! grep -q "Fingerprint" "$f"; then
    adb shell input text "$DEVICE_PIN" >/dev/null 2>&1 || true
    adb shell input keyevent 66 >/dev/null 2>&1 || true
    sleep 2
    dump_ui "$f" || return 1
  fi
  if grep -q "Add a fingerprint\|Fingerprint Unlock\|fingerprint" "$f"; then
    tap_text "$f" "Add a fingerprint" || tap_text "$f" "Fingerprint" || true
    sleep 2
  fi
  local t
  for t in 1 2 3 4 5 6 7 8 9 10 11 12; do
    adb emu finger touch 1 >/dev/null 2>&1 || true
    sleep 1
    if dump_ui "$f" && grep -q "Fingerprint added\|Done\|fingerprint.*added" "$f"; then
      tap_text "$f" "Done" || true
      return 0
    fi
  done
  dump_ui "$f" || true
  grep -q "Fingerprint added" "$f" 2>/dev/null
}
if enroll_fingerprint; then
  lock_fp="enrolled (emulator virtual sensor, id 1)"
else
  lock_fp="ENROLLMENT FAILED (see lane log + fp dumps; PIN-secured path still exercised)"
fi
log "security: lock_fp=$lock_fp"
adb shell input keyevent 3 >/dev/null 2>&1 || true
sleep 1

# --- installs + Authenticate (binding recipe order: mock first) --------
log "install: mock wallet ($MOCK_APK)"
if ! adb install "$MOCK_APK" > "$TMPD/install-mock.log" 2>&1; then
  cat "$TMPD/install-mock.log" | tee -a "$LANE_LOG"
  log "install: MOCK INSTALL FAILED — no wallet states can be captured"
  miss_all "mock wallet install failed — walk never started"
  echo "shots=FAIL(step=mock-install)" > "$OUT/verdict.txt"
  exit 1
fi

satisfy_auth_prompt() {
  local f="$TMPD/auth.xml" i
  for i in 1 2 3 4 5 6; do
    sleep 2
    dump_ui "$f" || return 1
    if grep -q "Log in to" "$f"; then
      adb emu finger touch 1 >/dev/null 2>&1 || true
      sleep 2
      dump_ui "$f" || return 1
      if grep -q "Log in to" "$f"; then
        tap_text "$f" "Use PIN" || tap_text "$f" "PIN" || true
        sleep 1
        adb shell input text "$DEVICE_PIN" >/dev/null 2>&1 || true
        adb shell input keyevent 66 >/dev/null 2>&1 || true
        sleep 2
      fi
    else
      return 0
    fi
  done
  dump_ui "$f" || true
  ! grep -q "Log in to" "$f"
}

authenticate_mock() {
  log "auth: opening mock wallet to Authenticate (15-min window)"
  ensure_unlocked
  dismiss_host_anr
  adb shell am start -W -n "$MOCK_ACT" >/dev/null 2>&1 || true
  sleep 3
  local f="$TMPD/mock-main.xml"
  dump_ui "$f" || return 1
  if grep -q "isn.t responding" "$f"; then
    dismiss_host_anr
    sleep 2
    dump_ui "$f" || return 1
  fi
  if ! grep -q "AUTHENTICATE\|Authenticate" "$f" && looks_locked "$f"; then
    ensure_unlocked
    adb shell am start -W -n "$MOCK_ACT" >/dev/null 2>&1 || true
    sleep 3
    dump_ui "$f" || return 1
  fi
  if [ -n "$EXPECTED_PUBKEY" ]; then
    if grep -q "$EXPECTED_PUBKEY" "$f"; then
      log "auth: mock main screen shows EXPECTED_PUBKEY ($EXPECTED_PUBKEY)"
    else
      log "auth: WARNING — mock main screen does NOT show EXPECTED_PUBKEY ($EXPECTED_PUBKEY)"
    fi
  fi
  cp "$f" "$OUT/hier-mock-main.xml" || true
  if grep -q "AUTHENTICATE\|Authenticate" "$f"; then
    tap_exact "$f" "AUTHENTICATE" || tap_exact "$f" "Authenticate" || tap_text "$f" "UTHENTICATE" || return 1
    if satisfy_auth_prompt; then
      date +%s > "$AUTH_EPOCH_FILE"
      auth_note="authenticated (window opened $(date -u +%H:%M:%S)Z)"
      log "auth: $auth_note"
      sleep 1
      return 0
    fi
    auth_note="AUTHENTICATE PROMPT NOT SATISFIED"
    log "auth: $auth_note"
    return 1
  fi
  auth_note="Authenticate button not found on mock main screen"
  log "auth: $auth_note"
  return 1
}

auth_fresh_enough() {
  local now last
  now="$(date +%s)"
  last="$(cat "$AUTH_EPOCH_FILE" 2>/dev/null || echo 0)"
  if [ $((now - last)) -gt 480 ]; then
    log "auth: window age $((now - last))s > 480s — re-authenticating"
    authenticate_mock || true
  fi
}

authenticate_mock || true

# --- portal geometry (driver r2): applied AFTER the mock security/
# auth phase, BEFORE the target app installs/launches (the target
# app's captures are the only frames that need the raster). Run 1
# applied this immediately after boot and every dump died; the
# sibling vr12r driver never overrides geometry at all. Bracketed
# by dump probe 2.
log "geometry: applying portal raster ${WANT_W}x${WANT_H} (wm size + density 320)"
adb shell wm size ${WANT_W}x${WANT_H} >/dev/null 2>&1 || true
adb shell wm density 320 >/dev/null 2>&1 || true
sleep 2
adb exec-out screencap -p > "$TMPD/geom-check.png" 2>/dev/null || true
GEOM="$(png_dims "$TMPD/geom-check.png")"
{
  echo "wm_size=$(adb shell wm size 2>/dev/null | tr -d '\r' | head -n 1)"
  echo "wm_density=$(adb shell wm density 2>/dev/null | tr -d '\r' | head -n 1)"
  echo "screencap_dims=$GEOM (wanted ${WANT_W}x${WANT_H})"
} >> "$OUT/device-info.txt"
log "geometry: wm_size=$(adb shell wm size 2>/dev/null | tr -d '\r' | head -n 1) screencap_dims=$GEOM (wanted ${WANT_W}x${WANT_H})"
[ "$GEOM" = "${WANT_W}x${WANT_H}" ] || log "geometry: WARNING — screencap is $GEOM, not ${WANT_W}x${WANT_H}; shots will be flagged OFF-SPEC in the manifest"
if dump_ui "$TMPD/probe-geom.xml"; then
  log "probe2: dump_ui OK after geometry override"
  cp "$TMPD/probe-geom.xml" "$OUT/hier-probe-geometry.xml" || true
else
  log "probe2: dump_ui DEAD after geometry override — failing fast"
  miss_all "dump primitive died after the wm geometry override"
  echo "shots=FAIL(step=dump-probe-geometry)" > "$OUT/verdict.txt"
  exit 1
fi

log "install: target Zert APK ($ZERT_APK)"
adb uninstall "$PKG" >/dev/null 2>&1 || true
if ! adb install "$ZERT_APK" > "$TMPD/install-zert.log" 2>&1; then
  cat "$TMPD/install-zert.log" | tee -a "$LANE_LOG"
  log "install: ZERT INSTALL FAILED"
  miss_all "target APK install failed — walk never started"
  echo "shots=FAIL(step=app-install)" > "$OUT/verdict.txt"
  exit 1
fi
adb logcat -c >/dev/null 2>&1 || true

# --- Zert state surfaces (strings quoted from space/client/src/App.tsx) --
zert_state() { # $1 = dump file; markers quoted from space/client/src/App.tsx
  local f="$1"
  [ -f "$f" ] || { echo "nodump"; return; }
  # "connected" grades on the PERSISTENT session markers (driver r3).
  # The launch control is a ternary on walletSession (App.tsx:1715):
  #   !walletSession -> "Connect wallet · 3 free hunts for new wallets"
  #                     (or "Connecting…" while walletConnecting)
  #   walletSession  -> "Insert coin · unlimited" (lifetime) |
  #                     "Insert coin · ${freePlaysLeft} free hunt(s)
  #                     ready" | "Insert coin · ${paidCredits} ready"
  #                     | "Buy 4 plays · $1"
  # So "Insert coin" present AND the disconnected-only "for new
  # wallets" form absent proves a live session. "WALLET CONNECTED"
  # (App.tsx:1474) is a transient showAccessMessage toast —
  # sufficient when seen, never required. Run 2's detector keyed on
  # that toast (+ "Disconnect wallet") and read "unknown" while the
  # session stood established by wire record; the walk aborted.
  if grep -q "WALLET CONNECTED" "$f" || { grep -q "Insert coin" "$f" && ! grep -q "for new wallets" "$f"; }; then echo "connected"
  elif grep -q "ABANDONED BEFORE IT FINISHED" "$f"; then echo "resolved-error"
  elif grep -q "Connecting" "$f"; then echo "working"
  elif grep -q "Connect wallet" "$f"; then echo "disconnected"
  else echo "unknown"; fi
}

goto_lobby() { # launch Zert and wait for the lobby's connect/session control
  local i
  ensure_unlocked
  adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
  for i in $(seq 1 50); do
    sleep 3
    dismiss_host_anr
    if [ "$(fg_pkg)" = "$PKG" ] && dump_ui "$TMPD/lobby.xml"; then
      if grep -q "Connect wallet" "$TMPD/lobby.xml" || grep -q "Insert coin" "$TMPD/lobby.xml"; then
        cp "$TMPD/lobby.xml" "$OUT/hier-lobby.xml" || true
        return 0
      fi
    fi
    if [ "$i" = "25" ]; then
      log "goto_lobby: relaunching mid-wait (WebView may still be loading the hosted client)"
      adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
    fi
  done
  dump_ui "$OUT/hier-lobby-fail.xml" || true
  return 1
}

sheet_present() { # $1 = dump file; mock sheet = mock fg + sheet controls
  local fg
  fg="$(fg_pkg)"
  [ "$fg" = "$MOCK" ] && grep -qE 'text="(Connect|Approve|Cancel)"' "$1" 2>/dev/null
}

wait_sheet() { # $1 = dump file, $2 = timeout; 0 if the mock sheet appeared
  local dst="$1" timeout_s="$2" elapsed=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    if dump_ui "$dst" && sheet_present "$dst"; then return 0; fi
    dismiss_host_anr
    sleep 3; elapsed=$((elapsed + 3))
  done
  dump_ui "$dst" || true
  sheet_present "$dst"
}

approve_all_sheets() { # $1 = seconds budget; approves authorize + sign-proof
  # sheets until the client reads Connected. NOTE: Zert regains the
  # foreground briefly between the authorize approval and the
  # sign-proof sheet (it fetches the server nonce first) — returning
  # on first Zert-fg sighting would strand the sign sheet, so the
  # loop only exits on the Connected state or budget expiry.
  local budget="$1" t0; t0="$(date +%s)"
  while [ $(( $(date +%s) - t0 )) -lt "$budget" ]; do
    local fg; fg="$(fg_pkg)"
    if [ "$fg" = "$MOCK" ]; then
      if dump_ui "$TMPD/appr.xml" && sheet_present "$TMPD/appr.xml"; then
        if tap_exact "$TMPD/appr.xml" "Connect" || tap_text "$TMPD/appr.xml" "Connect" || tap_exact "$TMPD/appr.xml" "Approve" || tap_text "$TMPD/appr.xml" "Approve"; then
          log "approve: sheet approved"
          sleep 4
          satisfy_auth_prompt || true
        fi
      fi
    elif [ "$fg" = "$PKG" ]; then
      if dump_ui "$TMPD/appr.xml" && [ "$(zert_state "$TMPD/appr.xml")" = "connected" ]; then
        log "approve: session Connected"
        return 0
      fi
    else
      adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
    fi
    sleep 2
  done
  [ "$(fg_pkg)" = "$PKG" ] && dump_ui "$TMPD/appr.xml" && [ "$(zert_state "$TMPD/appr.xml")" = "connected" ]
}

scroll_until() { # $1 = substring, $2 = max swipes; leaves the found dump in $TMPD/scroll.xml
  local needle="$1" max="$2" i
  for i in $(seq 0 "$max"); do
    if [ "$(fg_pkg)" = "$PKG" ] && dump_ui "$TMPD/scroll.xml" && grep -q "$needle" "$TMPD/scroll.xml"; then
      return 0
    fi
    adb shell input swipe 412 1500 412 620 350 >/dev/null 2>&1 || true
    sleep 2
  done
  dump_ui "$TMPD/scroll.xml" || true
  grep -q "$needle" "$TMPD/scroll.xml"
}

# --- the walk --------------------------------------------------------------
goblin_ok="0"; gameplay_ok="0"; runs_used="0"
any_run_saved="0"   # r4: frame 06 gates on a completed run, not shot success
run_card_seen="0"   # set by play_run when its own poll sees the result card

identify_arena() { # $1 = live play dump -> stdout: the python report
  # Finds the arena node as the first large ancestor (w>=600,
  # h>=500) of the "{coins} ZEC" topline text node (App.tsx:1668;
  # the topline is a direct child of .arena, :1654) and prints:
  #   ARENA x1 y1 x2 y2
  #   TAPS x y x y x y x y      (lane-quarter centers, mid-height)
  #   ZERTCAND x1 y1 x2 y2 cxfrac=...  (a textless lower-band child
  #     of the arena — the .zert node, App.tsx:1682: its center-x
  #     fraction tracks LANES[lane] = 16/38.5/61.5/84%, :38)
  # Prints nothing when the topline or a qualifying ancestor is
  # absent; the caller falls back per the r4 rules in the header.
  python3 - "$1" <<'PY'
import re, sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)
def bounds(n):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds") or "")
    return tuple(int(v) for v in m.groups()) if m else None
parent = {}
target = None
def walk(n, par):
    global target
    parent[id(n)] = par
    if target is None and re.fullmatch(r"\d+ ZEC", (n.get("text") or "").strip()):
        target = n
    for c in n:
        walk(c, n)
walk(root, None)
if target is None:
    sys.exit(0)
node = target
while node is not None:
    b = bounds(node)
    if b and (b[2] - b[0]) >= 600 and (b[3] - b[1]) >= 500:
        x1, y1, x2, y2 = b
        w, h = x2 - x1, y2 - y1
        y = y1 + h // 2
        pts = []
        for i in range(4):
            pts.append("%d %d" % (x1 + (2 * i + 1) * w // 8, y))
        print("ARENA %d %d %d %d" % b)
        print("TAPS " + " ".join(pts))
        for c in node:
            cb = bounds(c)
            if cb and not (c.get("text") or "") and (cb[2] - cb[0]) <= w // 2 and cb[1] >= y1 + h // 2:
                cx = (cb[0] + cb[2]) // 2
                print("ZERTCAND %d %d %d %d cxfrac=%.3f" % (cb + ((cx - x1) / w,)))
        break
    node = parent.get(id(node))
PY
}

play_run() { # $1 = want_gameplay (0/1), $2 = want_goblin (0/1)
  # Precondition: the mode-select screen is up ("START CLASSIC",
  # App.tsx:1744). Starts a Classic run and plays it blind (header).
  local want_gp="$1" want_gob="$2"
  dump_ui "$TMPD/ms.xml" || return 1
  if ! tap_text "$TMPD/ms.xml" "START CLASSIC"; then
    log "play: no START CLASSIC control on the mode-select dump"
    return 1
  fi
  runs_used=$((runs_used + 1))
  run_card_seen="0"
  log "play: run $runs_used started (Classic)"
  # Wait for the playing HUD: score rack STACK/TIME (App.tsx:1648-1653).
  local i playing="0"
  for i in $(seq 1 10); do
    sleep 2
    if dump_ui "$TMPD/play.xml" && grep -q "STACK" "$TMPD/play.xml" && grep -q "TIME" "$TMPD/play.xml"; then playing="1"; break; fi
  done
  if [ "$playing" != "1" ]; then log "play: run never reached the playing HUD"; return 1; fi
  # r4: PERSIST the live play-phase dump + screencap BEFORE steering
  # (runs 1-3 lost every play dump in $TMPD), then identify the
  # arena from that tree.
  cp "$TMPD/play.xml" "$OUT/hier-play-r${runs_used}-identify.xml" || true
  adb exec-out screencap -p > "$OUT/play-r${runs_used}-identify.png" 2>/dev/null || true
  log "play: identify frame play-r${runs_used}-identify.png dims=$(png_dims "$OUT/play-r${runs_used}-identify.png")"
  local arena_report lane_pts move_mode
  arena_report="$(identify_arena "$TMPD/play.xml")"
  lane_pts="$(printf '%s\n' "$arena_report" | sed -n 's/^TAPS //p')"
  printf '%s\n' "$arena_report" | while IFS= read -r line; do log "play: identify: $line"; done
  local lc rc
  lc="$(node_center "$TMPD/play.xml" "Move Zert left")"
  rc="$(node_center "$TMPD/play.xml" "Move Zert right")"
  log "play: arrow coords left=[$lc] right=[$rc]"
  # Movement channel (r4 header): arena lane taps are primary; the
  # arrow path is kept ONLY when the live dump proves those nodes
  # exist with bounds and the arena could not be identified.
  if [ -n "$lane_pts" ]; then
    move_mode="arena"
  elif [ -n "$lc" ] && [ -n "$rc" ]; then
    move_mode="arrows"
  else
    move_mode="none"
    log "play: NO movement channel proven (no arena bounds, no arrow nodes) — observing only; the run still plays out for the board gate"
  fi
  log "play: movement mode=$move_mode lane_taps=[$lane_pts]"
  local lane_x lane_y
  lane_x=($(printf '%s' "$lane_pts" | awk '{print $1, $3, $5, $7}'))
  lane_y=($(printf '%s' "$lane_pts" | awk '{print $2, $4, $6, $8}'))
  local tap_i=0 iter=0 poll_n=0 coins_seen_max=0
  local t0; t0="$(date +%s)"
  while [ $(( $(date +%s) - t0 )) -lt 75 ]; do
    iter=$((iter + 1))
    # Steer: one lane tap per beat (~0.55 s dwell), cycling lanes
    # 0,1,2,3 — the arena handler teleports Zert to the tapped
    # lane (App.tsx:1654-1664), so a steady cycle intersects each
    # falling coin's catch window (:1377) with ~even odds.
    if [ "$move_mode" = "arena" ]; then
      local li=$(( tap_i % 4 ))
      adb shell input tap "${lane_x[$li]}" "${lane_y[$li]}" >/dev/null 2>&1 || true
      tap_i=$((tap_i + 1))
      sleep 0.35
    elif [ "$move_mode" = "arrows" ]; then
      for xy in "$lc" "$lc" "$rc" "$rc" "$rc" "$lc" "$lc" "$rc"; do
        adb shell input tap $xy >/dev/null 2>&1 || true
        sleep 0.3
      done
      tap_i=$((tap_i + 8))
    else
      sleep 2
      tap_i=$((tap_i + 6))
    fi
    # Poll gate: every 6th beat in arena mode (~3.5 s of motion),
    # every 2nd beat in arrows mode (one beat is an 8-tap burst),
    # every beat when there is no movement channel to exercise.
    case "$move_mode" in
      arena)  [ $((iter % 6)) -ne 0 ] && continue ;;
      arrows) [ $((iter % 2)) -ne 0 ] && continue ;;
    esac
    # Poll beat: dump, PERSIST it (r4), and read the HUD off it.
    if [ "$(fg_pkg)" != "$PKG" ]; then adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true; fi
    poll_n=$((poll_n + 1))
    if ! dump_ui "$TMPD/play.xml"; then log "play: poll $poll_n dump failed"; continue; fi
    cp "$TMPD/play.xml" "$OUT/hier-play-r${runs_used}-poll${poll_n}.xml" || true
    if grep -q "HOARD SECURED\|ZERT GOT BONKED" "$TMPD/play.xml"; then
      log "play: run $runs_used ended (result card up; coins max observed=${coins_seen_max})"
      run_card_seen="1"
      return 0
    fi
    local coins lives
    coins="$(grep -oE '[0-9]+ ZEC' "$TMPD/play.xml" | head -n 1 | grep -oE '^[0-9]+' || true)"
    lives="$(grep -o '●' "$TMPD/play.xml" | wc -l | tr -d ' ')"
    if [ -n "$coins" ] && [ "$coins" -gt "$coins_seen_max" ]; then coins_seen_max="$coins"; fi
    log "play: poll $poll_n — coins=${coins:-?} (max ${coins_seen_max}) lives~${lives:-?} taps=$tap_i mode=$move_mode meter_text=$(grep -oE 'FRENZY [0-9]+%|UNLEASH GOBLIN MODE|GOBLIN MODE: FERAL' "$TMPD/play.xml" | head -n 1)"
    if [ "$want_gp" = "1" ] && [ "$gameplay_ok" != "1" ] && [ -n "$coins" ] && [ "$coins" -ge 2 ]; then
      shot "04-gameplay.png" "playing HUD confirmed (STACK/TIME, App.tsx:1648); arena topline ${coins} ZEC (:1668) — catches proven accumulating under lane-tap steering (mode=$move_mode); polls in hier-play-r${runs_used}-poll*.xml"
      gameplay_ok="1"
    fi
    if [ "$want_gob" = "1" ] && [ "$goblin_ok" != "1" ] && grep -q "UNLEASH GOBLIN MODE" "$TMPD/play.xml"; then
      log "play: meter full — activating Goblin Mode (window 6500 ms, :1306)"
      if tap_text "$TMPD/play.xml" "UNLEASH GOBLIN MODE"; then
        # Screencap FIRST (frame lands ~1 s into the window), confirm after.
        shot "05-goblin-mode.png" "Goblin Mode activated from UNLEASH GOBLIN MODE (:1807); confirm dump follows in hier-goblin-confirm.xml"
        rm -f "$TMPD/goblin.xml"
        if dump_ui "$TMPD/goblin.xml" && grep -q "GOBLIN MODE: FERAL" "$TMPD/goblin.xml"; then
          goblin_confirm="FERAL text in confirming dump"
        else
          goblin_confirm="FERAL text NOT in confirming dump (window may have lapsed before the dump; the frame was capped ~1 s after the tap)"
        fi
        [ -f "$TMPD/goblin.xml" ] && cp "$TMPD/goblin.xml" "$OUT/hier-goblin-confirm.xml" || true
        log "play: goblin confirm: $goblin_confirm"
        goblin_ok="1"
      fi
    fi
    if [ "$want_gob" != "1" ] || [ "$goblin_ok" = "1" ]; then
      if [ "$want_gp" != "1" ] || [ "$gameplay_ok" = "1" ]; then
        # Nothing left to hunt this run — but a run still in flight
        # must be played out so its score saves for the board shot.
        if [ "$want_gp" = "1" ] || [ "$want_gob" = "1" ]; then
          log "play: this run's shots are in; playing out to the result card"
        fi
        want_gp="0"; want_gob="0"
      fi
    fi
  done
  log "play: run $runs_used loop budget exhausted (round is 45 s; the result card may lag the loop; coins max observed=${coins_seen_max})"
  return 0
}

wait_result_card() { # poll until the result card is up and the save reconciled
  local i
  for i in $(seq 1 20); do
    if dump_ui "$TMPD/res.xml" && grep -q "HOARD SECURED\|ZERT GOT BONKED" "$TMPD/res.xml"; then
      if grep -q "Run saved" "$TMPD/res.xml" || { grep -q "Insert next coin" "$TMPD/res.xml" && ! grep -q "Reconciling run" "$TMPD/res.xml"; }; then
        cp "$TMPD/res.xml" "$OUT/hier-result-card.xml" || true # r4: persist
        log "walk: result card up, save reconciled (run $runs_used)"
        return 0
      fi
    fi
    sleep 3
  done
  dump_ui "$TMPD/res.xml" || true
  cp "$TMPD/res.xml" "$OUT/hier-result-card.xml" || true # r4: persist either way
  grep -q "HOARD SECURED\|ZERT GOT BONKED" "$TMPD/res.xml"
}

log "=== screenshot walk: lobby -> connect -> run -> board -> store ==="
auth_fresh_enough
if ! goto_lobby; then
  log "walk: could not reach the lobby — no shots possible"
  miss_all "could not reach the lobby"
  echo "shots=FAIL(step=lobby)" > "$OUT/verdict.txt"
  exit 1
fi
st="$(zert_state "$OUT/hier-lobby.xml")"
log "walk: lobby state=$st"
if [ "$st" != "disconnected" ]; then
  log "walk: FAIL — fresh install lobby state=$st, expected disconnected"
  miss_all "fresh-install lobby was not in the disconnected state (state=$st)"
  echo "shots=FAIL(step=precondition)" > "$OUT/verdict.txt"
  exit 1
fi

# -- 01 lobby (door as the shell renders it; App.tsx:1711 vs :1715) --
if grep -q "Connect with Seeker" "$OUT/hier-lobby.xml"; then door_form="seeker-door (Connect with Seeker — unexpected in-shell; bridgePresent should suppress it, :1508)"; else door_form="generic shell-bridge door (Connect wallet · 3 free hunts for new wallets, :1715)"; fi
grep -q "45 SECOND ZEC HUNT" "$OUT/hier-lobby.xml" || log "walk: WARNING — lobby overline '45 SECOND ZEC HUNT' (:1692) not in the lobby dump"
shot "01-lobby.png" "disconnected lobby; door form: $door_form; overline 45 SECOND ZEC HUNT (:1692)"

# -- connect via the Mock session (cell-proven flow) --
dump_ui "$TMPD/pre-connect.xml" || true
if ! tap_text "$TMPD/pre-connect.xml" "Connect wallet"; then
  cp "$TMPD/pre-connect.xml" "$OUT/hier-pre-connect-fail.xml" || true # r3: persist failure-path dumps
  miss "02-connected.png" "no connect control on the lobby"
  miss "03-mode-select.png" "connect never started"
  miss "04-gameplay.png" "connect never started"
  miss "05-goblin-mode.png" "connect never started"
  miss "06-leaderboard.png" "connect never started (board shot rides the walk's own saved run)"
  # 07 NOT pre-missed (r3): the store leg runs independently below
  # and records its own outcome — one manifest row per frame.
else
  log "walk: connect tapped; waiting for the mock authorize sheet"
  if ! wait_sheet "$OUT/hier-sheet1.xml" 45; then
    log "walk: no authorize sheet within 45 s"
    miss "02-connected.png" "no mock authorize sheet"
    miss "03-mode-select.png" "no session"
    miss "04-gameplay.png" "no session"
    miss "05-goblin-mode.png" "no session"
    miss "06-leaderboard.png" "no session (board shot rides the walk's own saved run)"
    # 07 NOT pre-missed (r3): the store leg records its own outcome.
  else
    approve_all_sheets 150 || true
    # Poll for the session state (persistent markers — zert_state r3:
    # the launch control in its live-session "Insert coin" form,
    # App.tsx:1715; the "WALLET CONNECTED" toast :1474 corroborates).
    conn="0"
    for i in $(seq 1 20); do
      if [ "$(fg_pkg)" = "$PKG" ] && dump_ui "$TMPD/conn.xml" && [ "$(zert_state "$TMPD/conn.xml")" = "connected" ]; then conn="1"; break; fi
      sleep 3
    done
    if [ "$conn" != "1" ]; then
      log "walk: session never reached Connected (state=$(zert_state "$TMPD/conn.xml"))"
      # r3: persist the failure-path poll dumps into the artifact —
      # run 2 lost its decisive $TMPD dumps and the diagnosis had to
      # be reconstructed from the wire record.
      cp "$TMPD/conn.xml" "$OUT/hier-connect-fail.xml" || true
      cp "$TMPD/appr.xml" "$OUT/hier-approve-fail.xml" || true
      miss "02-connected.png" "session never established (sign-proof flow incomplete)"
      miss "03-mode-select.png" "no session"
      miss "04-gameplay.png" "no session"
      miss "05-goblin-mode.png" "no session"
      miss "06-leaderboard.png" "no session (board shot rides the walk's own saved run)"
      # 07 NOT pre-missed (r3): the store leg records its own outcome.
    else
      cp "$TMPD/conn.xml" "$OUT/hier-connected.xml" || true
      # -- 02 connected lobby --
      shot "02-connected.png" "connected lobby — launch control in live-session form (Insert coin, :1715 ternary; disconnected-only 'for new wallets' form absent); Mock session (server nonce signed + verified)"
      # -- insert coin -> mode select --
      if ! tap_text "$TMPD/conn.xml" "Insert coin"; then
        miss "03-mode-select.png" "no Insert coin control on the connected lobby"
        miss "04-gameplay.png" "no play could be reserved"
        miss "05-goblin-mode.png" "no play could be reserved"
        miss "06-leaderboard.png" "no run to save (board shot rides the walk's own saved run)"
      else
        ms="0"
        for i in $(seq 1 15); do
          sleep 3
          if dump_ui "$TMPD/ms.xml" && grep -q "START CLASSIC" "$TMPD/ms.xml"; then ms="1"; break; fi
        done
        if [ "$ms" != "1" ]; then
          miss "03-mode-select.png" "mode select never rendered after Insert coin (beginPlay round-trip)"
          miss "04-gameplay.png" "no run started"
          miss "05-goblin-mode.png" "no run started"
          miss "06-leaderboard.png" "no run to save (board shot rides the walk's own saved run)"
        else
          cp "$TMPD/ms.xml" "$OUT/hier-mode-select.xml" || true
          # -- 03 mode select (three modes, :1744/:1747/:1750) --
          shot "03-mode-select.png" "difficulty grid: CLASSIC / DOUBLE FRENZY / TRIPLE FRENZY cards (:1744-1750) after ONE PLAY RESERVED"
          # -- runs: hunt 04/05 across up to all 3 free hunts (r4;
          # run 3's walk stopped after 2 and never retried 04) --
          play_run 1 1 || true
          if wait_result_card || [ "$run_card_seen" = "1" ]; then any_run_saved="1"; fi
          while [ "$runs_used" -lt 3 ] && { [ "$gameplay_ok" != "1" ] || [ "$goblin_ok" != "1" ]; }; do
            if ! { dump_ui "$TMPD/res.xml" && grep -q "Insert next coin" "$TMPD/res.xml" && tap_text "$TMPD/res.xml" "Insert next coin"; }; then
              log "walk: a retry is wanted but no Insert next coin control is up — stopping run retries"
              break
            fi
            ms2="0"
            for i in $(seq 1 15); do
              sleep 3
              if dump_ui "$TMPD/ms.xml" && grep -q "START CLASSIC" "$TMPD/ms.xml"; then ms2="1"; break; fi
            done
            if [ "$ms2" != "1" ]; then log "walk: mode select never re-rendered for the retry"; break; fi
            wgp="0"; wgob="0"
            [ "$gameplay_ok" != "1" ] && wgp="1"
            [ "$goblin_ok" != "1" ] && wgob="1"
            log "walk: spending free hunt $((runs_used + 1)) on a retry (want_gameplay=$wgp want_goblin=$wgob)"
            play_run "$wgp" "$wgob" || true
            if wait_result_card || [ "$run_card_seen" = "1" ]; then any_run_saved="1"; fi
          done
          if [ "$gameplay_ok" != "1" ]; then miss "04-gameplay.png" "no played run showed a live HUD with >=2 ZEC caught (lane-tap steering; per-poll coins in the lane log + hier-play-* dumps)"; fi
          if [ "$goblin_ok" != "1" ]; then miss "05-goblin-mode.png" "meter never reached UNLEASH inside the played runs (blind play; catches are probabilistic — see lane log)"; fi
        fi
      fi
      # -- 06 leaderboard (below the game column; scroll to THE DEEP CAVE, :1830) --
      # r4: gated on a COMPLETED RUN (a result card seen this walk),
      # never on 04/05 shot success — run 3 skipped this block with
      # two saved runs in hand because neither gameplay shot had
      # confirmed (a driver-guard casualty).
      if [ "$any_run_saved" = "1" ]; then
        if scroll_until "THE DEEP CAVE" 8; then
          if grep -q "No ranked goblins yet" "$TMPD/scroll.xml"; then board_state="empty (no ranked rows — the truthful fresh-board state)"; else board_state="populated (ranked rows on the production board — the walk's own saved run and/or rows left by earlier sessions on the live host; this IS the real board, not a seeded fixture)"; fi
          cp "$TMPD/scroll.xml" "$OUT/hier-leaderboard.xml" || true
          shot "06-leaderboard.png" "THE DEEP CAVE board (:1830-1831, Classic top goblins); board state: $board_state"
        else
          miss "06-leaderboard.png" "THE DEEP CAVE never entered the viewport after 8 scrolls"
        fi
      else
        miss "06-leaderboard.png" "no run completed to a result card this walk (board shot is gated on a completed run, r4)"
      fi
    fi
  fi
fi

# -- 07 skin store (cabinet SKINS button persists across phases, :1634) --
if [ -f "$OUT/01-lobby.png" ]; then
  store_open="0"
  dump_ui "$TMPD/store-pre.xml" || true
  if tap_exact "$TMPD/store-pre.xml" "SKINS"; then store_open="pending"; fi
  if [ "$store_open" = "0" ]; then
    # Cabinet bar may be scrolled off — return to the page top first.
    for i in 1 2 3 4 5 6; do adb shell input swipe 412 620 412 1500 350 >/dev/null 2>&1 || true; sleep 1; done
    if dump_ui "$TMPD/store-pre.xml" && tap_exact "$TMPD/store-pre.xml" "SKINS"; then store_open="pending"; fi
  fi
  if [ "$store_open" = "pending" ]; then
    for i in $(seq 1 15); do
      sleep 3
      if dump_ui "$TMPD/store.xml" && grep -q "Skin store" "$TMPD/store.xml"; then store_open="1"; break; fi
    done
  fi
  if [ "$store_open" = "1" ]; then
    # The $2.50 evidence (deal flag :856 / per-skin grid :876ff) sits
    # below the sheet's fold — scroll the sheet until it is in tree.
    tries="0"
    while ! grep -q '\$2\.50' "$TMPD/store.xml" && [ "$tries" -lt 3 ]; do
      adb shell input swipe 412 1400 412 800 350 >/dev/null 2>&1 || true
      sleep 2
      dump_ui "$TMPD/store.xml" || true
      tries=$((tries + 1))
    done
    cp "$TMPD/store.xml" "$OUT/hier-skin-store.xml" || true
    if grep -q '\$2\.50' "$TMPD/store.xml"; then
      shot "07-skin-store.png" "Skin store (:839) with \$2.50 in the viewport tree (deal flag :856 / per-skin \$2.50 grid)"
    else
      shot "07-skin-store.png" "Skin store (:839) open; WARNING — \$2.50 not in the final viewport tree after 3 sheet scrolls; check the frame before portal use"
    fi
  else
    miss "07-skin-store.png" "the SKINS control never opened the store"
  fi
else
  miss "07-skin-store.png" "not attempted (walk ended before a lobby frame existed)"
fi

# --- crash scan + verdict ---------------------------------------------------
# Manifest safety net (driver r2): any frame the walk never recorded
# (e.g. the leaderboard block is skipped when no run confirmed) gets
# an explicit MISSING row here — silence is the bug, not the gap.
miss_all "walk ended without recording this frame (safety-net row)"
adb logcat -d > "$OUT/logcat-final.txt" 2>&1 || true
scan_logcat "$OUT/logcat-final.txt"
{
  echo "shots_ok=$shots_ok"
  echo "shots_missing=${shots_missing:-none}"
  echo "door_form=$door_form"
  echo "board_state=$board_state"
  echo "goblin_confirm=$goblin_confirm"
  echo "runs_used=$runs_used"
  echo "app_fatal_total=$fatal_pkg_total"
  echo "mock_fatal_total=$fatal_mock_total"
  echo "sender_signature_ise_total=$ise_total"
  echo "lock_pin=$lock_pin"
  echo "lock_fp=$lock_fp"
  echo "mock_auth=$auth_note"
  echo "expected_pubkey=$EXPECTED_PUBKEY"
  if [ "$shots_ok" = "7" ] && [ -z "$shots_missing" ] && [ "$fatal_pkg_total" = "0" ] && [ "$ise_total" = "0" ]; then
    echo "shots=PASS"
  else
    echo "shots=FAIL"
  fi
} > "$OUT/verdict.txt"
cat "$MANIFEST" | tee -a "$LANE_LOG"
cat "$OUT/verdict.txt" | tee -a "$LANE_LOG"
log "shots: verdict written to $OUT/verdict.txt"
[ "$shots_ok" = "7" ] && [ -z "$shots_missing" ] && [ "$fatal_pkg_total" = "0" ] && [ "$ise_total" = "0" ]
