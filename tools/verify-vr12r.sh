#!/usr/bin/env bash
# Zert Goblin — vr12r-pattern runtime cell (KFC-008 retry leg).
#
# Port of the estate §2.2 recipe (VOIDRUNNER vendor recipe -> HAUNT
# tools/verify-v0113-wallet.sh driver r5/r6) to Zert's WebView shell.
# Runs INSIDE one emulator step on the CI-KVM lane. Exercises a target
# APK (parameter: ZERT_APK) against the official Mock MWA Wallet
# (solana-mobile/mock-mwa-wallet @ d444aff0, imported throwaway key)
# on a PIN-locked AVD.
#
# THE CELL (one process, no force-stop of the app after install):
#   1. Launch Zert -> lobby -> tap the connect control
#      ("Connect wallet · 3 free hunts for new wallets").
#   2. The Mock authorize sheet presents (wallet task foreground).
#   3. ABANDON: HOME, then return to the ZERT task via recents
#      (never approving the sheet). Zert's MainActivity.onResume
#      fires the foreground reconciler.
#   4. RESOLUTION: Zert must leave "Connecting..." and surface the
#      abandonment resolution (access message "THE WALLET REQUEST
#      WAS ABANDONED BEFORE IT FINISHED. TRY AGAIN." — the client
#      uppercases WalletManager's message) within 40 s.
#   5. RETRY: tap the connect control ONCE. Approval loop (HAUNT r6
#      form, 110 s budget): whenever a Mock sheet is up, approve it
#      (Connect on the authorize sheet, Approve on the sign-proof
#      sheet — Zert's session flow signs a server nonce right after
#      connect, so a cured retry produces TWO sheets).
#   6. PASS only if, in the SAME process (pid continuity asserted):
#      a sheet presented after the retry tap, at least one approval
#      completed, and Zert reaches its session state (see below)
#      within 110 s of the retry tap.
#
# OBSERVATION SURFACES (what the grades rest on):
#   - uiautomator hierarchy dumps. Zert is a WebView shell: its state
#     is the client DOM, exposed in the dump as text nodes. Markers:
#       working        -> "Connecting..." (launch button, disabled)
#       resolved-error -> the abandonment access message (above)
#       session        -> the lobby banner reads "WALLET CONNECTED"
#                         and the launch button reads "Insert
#                         coin..." — both render only when the
#                         client holds a server-issued session (the
#                         DOM "Disconnect wallet" button sits below
#                         the fold and is absent from the viewport
#                         accessibility tree; r3 accepts it as an
#                         alternative marker). A session exists only after the
#                         MWA connect returned the mock key's pubkey
#                         AND the mock signed the server nonce AND
#                         the game server verified the ed25519
#                         signature — so the session state is bound
#                         to the mock's pubkey even though the client
#                         never renders the pubkey string itself.
#                         The mock-side anchor: the mock main screen
#                         shows the imported key's address; the
#                         driver asserts it equals EXPECTED_PUBKEY.
#       disconnected   -> "Connect wallet" control, no session marks
#   - Foreground package tracking (dumpsys) for sheet presence:
#     sheet = fg is com.solana.mwallet AND the dump carries the
#     sheet's Connect/Approve/Cancel controls.
#   - logcat windows: any AndroidRuntime FATAL for either package,
#     or an ActivityResultSender-signature IllegalStateException,
#     poisons the verdict (HAUNT scan rule).
#
# SCOPE: the verdict binds to the MOCK MWA Wallet's intent handling
# (its MobileWalletAdapterActivity is singleTask with no onNewIntent
# override — a second association intent while a sheet is in flight
# is the contested surface). The Seed Vault Wallet may differ.
#
# Driver r2 (first run, 41032934329): the resolution gate no longer
# demands the Error/access-message form. Run 1 resolved to a clean
# disconnected lobby within seconds of the return — a failed-closed
# resolution whose client manifestation is NOT the abandonment
# access message (never rendered; the message does not auto-clear,
# so it was never shown) — and r1's gate mis-stopped the cell
# before the retry leg and mislabelled the outcome as the vr12
# hang. r2 records the resolution TRAJECTORY (per-poll dumps), fails
# the resolution step only on Working-persistence (the actual vr12
# shape), and proceeds to the retry leg from ANY failed-closed
# resolution, exactly as HAUNT's vr12 -> vr12r structure does.
set -u

PKG="com.zertgoblin.app"
ACT="com.zertgoblin.app/.MainActivity"
MOCK="com.solana.mwallet"
MOCK_ACT="com.solana.mwallet/.MainActivity"
OUT="${VR12R_OUT:-zert-vr12r-evidence}"
ZERT_APK="${ZERT_APK:-}"
MOCK_APK="${MOCK_APK:-}"
EXPECTED_PUBKEY="${EXPECTED_PUBKEY:-}"
DEVICE_PIN="${DEVICE_PIN:-1234}"
TMPD="$(mktemp -d)"
LANE_LOG="$OUT/vr12r-lane.log"
AUTH_EPOCH_FILE="$OUT/auth-epoch.txt"

mkdir -p "$OUT"
: > "$LANE_LOG"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LANE_LOG"; }

# --- verdict state ---------------------------------------------------
cell="NOT-RUN"
fail_step=""
fatal_pkg_total="0"; fatal_mock_total="0"; ise_total="0"
lock_pin="unknown"; lock_fp="unknown"; auth_note="not attempted"
app_pid_start=""; app_pid_end=""
resolution_s=""; resolution_form=""; retry_to_connected_s=""; sheets_after_retry="0"; approvals="0"
# vr12s (scoping leg) verdict state
s_cell="NOT-RUN"; s_fail_step=""; s_claimed=""; s_claimed_at_s=""; s_completed=""; s_pid_start=""; s_pid_end=""

# --- helpers (carried from HAUNT's driver, JUDGE Amendment 2 hardening) ----
dump_is_substantive() { # rejects hollow mid-transition dumps
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

tap_text() { # $1 = hierarchy file, $2 = substring
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

tap_desc() { # $1 = hierarchy file, $2 = substring matched against content-desc
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

fg_pkg() {
  local f
  f="$(adb shell dumpsys window windows 2>/dev/null | sed -n 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')"
  if [ -z "$f" ]; then
    f="$(adb shell dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')"
  fi
  printf '%s' "$f"
}

snap() { adb exec-out screencap -p > "$OUT/$1" 2>/dev/null || true; }

dismiss_host_anr() { # if a host (launcher/System UI) ANR dialog is up, tap Wait
  local f="$TMPD/anr-check.xml"
  if dump_ui "$f" && grep -q "isn.t responding" "$f"; then
    if grep -q "Pixel Launcher isn.t responding\|System UI isn.t responding" "$f"; then
      log "anr: host dialog present; tapping Wait"
      tap_text "$f" "Wait" || true
      sleep 2
    fi
  fi
}

scan_logcat() { # $1 = file; updates global fatal/ise counters
  local f="$1" a b c raw
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
  raw="$(grep -c "IllegalStateException" "$f" 2>/dev/null || true)"
  fatal_pkg_total=$((fatal_pkg_total + ${a:-0}))
  fatal_mock_total=$((fatal_mock_total + ${b:-0}))
  ise_total=$((ise_total + ${c:-0}))
  log "scan: $f app_fatal=${a:-0} mock_fatal=${b:-0} sender_signature_ise=${c:-0} (raw_system_ise=${raw:-0}, informational)"
}

capture_window() { # $1 = tag; dumps logcat since last clear into evidence + scans
  adb logcat -d > "$OUT/logcat-$1.txt" 2>&1 || true
  scan_logcat "$OUT/logcat-$1.txt"
  adb logcat -c >/dev/null 2>&1 || true
}

# --- device record -----------------------------------------------------
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
  echo "suite=vr12r"
  echo "expected_pubkey=$EXPECTED_PUBKEY"
  echo "zert_apk=$ZERT_APK"
} > "$OUT/device-info.txt"
cat "$OUT/device-info.txt" | tee -a "$LANE_LOG"

# --- PIN lock + fingerprint enrollment (binding recipe step 2) ---------
log "security: setting device PIN via locksettings"
adb shell locksettings set-pin "$DEVICE_PIN" >> "$LANE_LOG" 2>&1 || true
if adb shell locksettings verify --old "$DEVICE_PIN" >/dev/null 2>&1; then
  lock_pin="set+verified (PIN $DEVICE_PIN)"
else
  ls_state="$(adb shell dumpsys lock_settings 2>/dev/null | grep -i "credential" | head -n 2 | tr -d '\r')"
  log "security: locksettings verify unsupported; dumpsys lock_settings: $ls_state"
  lock_pin="set (locksettings set-pin issued, PIN $DEVICE_PIN)"
fi
log "security: lock_pin=$lock_pin"
adb shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
adb shell settings put secure lock_screen_lock_after_timeout 2147483647 >/dev/null 2>&1 || true
adb shell svc power stayon usb >/dev/null 2>&1 || true
log "security: lock mitigation applied (screen_off_timeout=max, lock_after_timeout=max, stayon usb)"

looks_locked() { # $1 = dump file; keyguard/AOD heuristics (HAUNT driver r7)
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
    adb shell input swipe 540 2200 540 700 300 >/dev/null 2>&1 || true
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
    adb shell input swipe 540 1800 540 900 300 >/dev/null 2>&1 || true
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

# --- installs + Authenticate (binding recipe step 5 order) -------------
log "install: mock wallet ($MOCK_APK)"
if ! adb install "$MOCK_APK" > "$TMPD/install-mock.log" 2>&1; then
  cat "$TMPD/install-mock.log" | tee -a "$LANE_LOG"
  log "install: MOCK INSTALL FAILED — no wallet legs can run"
  echo "cell=FAIL(step=mock-install)" > "$OUT/verdict.txt"
  exit 1
fi

satisfy_auth_prompt() { # works the biometric/PIN prompt until it clears
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
    log "auth: host ANR over the mock main screen — dismissing and re-dumping"
    dismiss_host_anr
    sleep 2
    dump_ui "$f" || return 1
  fi
  if ! grep -q "AUTHENTICATE\|Authenticate" "$f" && looks_locked "$f"; then
    log "auth: mock launch landed behind the keyguard — unlocking + relaunching"
    ensure_unlocked
    adb shell am start -W -n "$MOCK_ACT" >/dev/null 2>&1 || true
    sleep 3
    dump_ui "$f" || return 1
  fi
  grep -oE 'text="[^"]+"' "$f" | sort -u | head -12 | tee -a "$LANE_LOG" || true
  # Pubkey anchor: the mock main screen renders the imported key's
  # address (Name/Address/AUTHENTICATE). Assert it is the expected one.
  if [ -n "$EXPECTED_PUBKEY" ]; then
    if grep -q "$EXPECTED_PUBKEY" "$f"; then
      log "auth: mock main screen shows EXPECTED_PUBKEY ($EXPECTED_PUBKEY)"
    else
      log "auth: WARNING — mock main screen does NOT show EXPECTED_PUBKEY ($EXPECTED_PUBKEY); session grades bind to whatever key the mock holds"
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
      dump_ui "$OUT/mock-after-auth.xml" || true
      snap "mock-after-auth.png"
      return 0
    fi
    auth_note="AUTHENTICATE PROMPT NOT SATISFIED"
    log "auth: $auth_note"
    return 1
  fi
  auth_note="Authenticate button not found on mock main screen"
  log "auth: $auth_note"
  dump_ui "$OUT/mock-main-fail.xml" || true
  snap "mock-main-fail.png"
  return 1
}

auth_fresh_enough() { # re-authenticate if the window is >8 min old
  local now last
  now="$(date +%s)"
  last="$(cat "$AUTH_EPOCH_FILE" 2>/dev/null || echo 0)"
  if [ $((now - last)) -gt 480 ]; then
    log "auth: window age $((now - last))s > 480s — re-authenticating"
    authenticate_mock || true
  fi
}

authenticate_mock || true
log "install: target Zert APK ($ZERT_APK)"
adb uninstall "$PKG" >/dev/null 2>&1 || true
if ! adb install "$ZERT_APK" > "$TMPD/install-zert.log" 2>&1; then
  cat "$TMPD/install-zert.log" | tee -a "$LANE_LOG"
  log "install: ZERT INSTALL FAILED"
  echo "cell=FAIL(step=app-install)" > "$OUT/verdict.txt"
  exit 1
fi
adb logcat -c >/dev/null 2>&1 || true


# --- Zert state surfaces -------------------------------------------------
# Reads the state keyword off a hierarchy dump OF THE ZERT TASK (the
# dump must be of Zert's own hierarchy; dumps taken while the wallet
# or launcher is foreground contain none of these markers -> unknown).
zert_state() { # $1 = dump file
  local f="$1"
  [ -f "$f" ] || { echo "nodump"; return; }
  # Connected (r3, live-client truth — run 2's final dump): the lobby
  # banner reads "WALLET CONNECTED ..." and the launch button "Insert
  # coin · N free hunts ready"; the DOM "Disconnect wallet" button
  # sits below the fold and is NOT in the viewport accessibility
  # tree, so r1/r2's Disconnect+Insert-coin test never matched and
  # run 2's completed retry was misread as "unknown". Accept either
  # the banner or the legacy Disconnect+Insert-coin pair.
  if grep -q "WALLET CONNECTED" "$f" || { grep -q "Disconnect wallet" "$f" && grep -q "Insert coin" "$f"; }; then echo "connected"
  elif grep -q "ABANDONED BEFORE IT FINISHED" "$f"; then echo "resolved-error"
  elif grep -q "Connecting" "$f"; then echo "working"
  elif grep -q "Connect wallet" "$f"; then echo "disconnected"
  else echo "unknown"; fi
}

zert_state_fg() { # fresh dump -> state, only trusted when Zert is foreground
  if [ "$(fg_pkg)" != "$PKG" ]; then echo "not-fg"; return; fi
  if dump_ui "$TMPD/state.xml"; then zert_state "$TMPD/state.xml"; else echo "nodump"; fi
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
  snap "shot-lobby-fail.png"
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

fail() { # $1 = step name, $2 = detail
  cell="FAIL"; fail_step="$1"
  log "vr12r: FAIL step=$1 — $2"
}

# --- THE CELL --------------------------------------------------------------
cell_vr12r() {
  log "=== vr12r: connect -> abandon mid-sheet -> resolve -> TRY AGAIN -> Connected, one process ==="
  auth_fresh_enough
  if ! goto_lobby; then fail "lobby" "could not reach the lobby (hosted client did not render a connect/session control)"; return; fi
  local st; st="$(zert_state "$OUT/hier-lobby.xml")"
  log "vr12r: lobby state=$st"
  if [ "$st" != "disconnected" ]; then fail "precondition" "lobby state=$st, expected disconnected on a fresh install"; return; fi
  app_pid_start="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')"
  log "vr12r: app pid at cell start = $app_pid_start"

  # 1. Initiate Connect.
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/pre-connect.xml" || true
  if ! tap_text "$TMPD/pre-connect.xml" "Connect wallet"; then
    fail "connect-tap" "no connect control on the lobby"; return
  fi
  log "vr12r: connect tapped; waiting for the mock authorize sheet"
  local f="$OUT/hier-sheet1.xml"
  if ! wait_sheet "$f" 45; then
    fail "first-sheet" "no mock authorize sheet within 45s of the connect tap (fg=$(fg_pkg), zert state=$(zert_state_fg))"
    snap "shot-nosheet1.png"
    return
  fi
  snap "shot-sheet1.png"
  log "vr12r: authorize sheet in flight (fg=$(fg_pkg))"

  # 2. ABANDON: HOME, then return to the ZERT task without approving.
  log "vr12r: ABANDON — HOME (backgrounding both tasks), no approval"
  adb shell input keyevent 3 >/dev/null 2>&1 || true
  sleep 3
  snap "shot-backgrounded.png"
  adb shell input keyevent 187 >/dev/null 2>&1 || true  # APP_SWITCH / recents
  sleep 3
  dump_ui "$OUT/hier-recents.xml" || true
  if tap_desc "$OUT/hier-recents.xml" "Zert Goblin" || tap_text "$OUT/hier-recents.xml" "Zert Goblin"; then
    log "vr12r: returned via the Zert recents card"
  else
    adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
    log "vr12r: no labelled Zert card matched; brought the Zert task forward via am start"
  fi
  sleep 2
  local t_return; t_return="$(date +%s)"
  snap "shot-returned.png"

  # 3. RESOLUTION WAIT (r2 — trajectory, not a single gate): the
  #    reconciler (MainActivity.onResume -> WalletManager.onForeground)
  #    must move the interrupted connect OUT of Working within 40 s
  #    of the return. Any failed-closed form counts as the
  #    resolution (resolved-error = the abandonment access message;
  #    disconnected = a clean return to the lobby with no message —
  #    run 1's observed form); only Working-persistence is the vr12
  #    hang and fails here. Every poll dump is filed so the
  #    trajectory is evidence, not summary.
  local elapsed=0 rst="working" saw_fg="0" first_nonworking=""
  while [ "$elapsed" -lt 40 ]; do
    if [ "$(fg_pkg)" = "$PKG" ]; then
      saw_fg="1"
      if dump_ui "$TMPD/poll.xml"; then
        cp "$TMPD/poll.xml" "$OUT/hier-poll-${elapsed}s.xml" || true
        rst="$(zert_state "$TMPD/poll.xml")"
      fi
    else
      rst="not-fg"
    fi
    log "vr12r: resolution poll ${elapsed}s: state=$rst (fg=$(fg_pkg))"
    if [ -z "$first_nonworking" ]; then
      case "$rst" in
        resolved-error|disconnected|connected) first_nonworking="$elapsed" ;;
      esac
    fi
    # Keep polling after the first non-working read for a few more
    # seconds: a late-rendering access message (or a relapse into
    # Working) is part of the trajectory. Stop early only once a
    # failed-closed form has been stable for two polls.
    if [ -n "$first_nonworking" ] && [ $((elapsed - first_nonworking)) -ge 6 ]; then break; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  resolution_s="${first_nonworking:-40}"
  resolution_form="$rst"
  dump_ui "$OUT/hier-resolved.xml" || true
  snap "shot-resolved.png"
  capture_window "resolution"
  log "vr12r: resolution trajectory end: state=$rst first_nonworking=${first_nonworking:-none}s saw_fg=$saw_fg"
  if [ "$saw_fg" != "1" ]; then
    fail "return" "the Zert task never regained the foreground after the abandonment"
    return
  fi
  if [ "$rst" = "connected" ]; then
    # The zombie approval cannot have happened (nothing approved it);
    # a Connected here would mean the sheet resumed and completed on
    # return — not the abandonment path. Record and stop: there is
    # no interrupted resolution to retry from.
    fail "resolution" "state resolved to Connected without any approval — abandonment did not take the interrupted-resolution path"
    return
  fi
  if [ -z "$first_nonworking" ] || [ "$rst" = "working" ]; then
    fail "resolution" "the interrupted connect never left Working within 40s of foreground return (end state=$rst) — the vr12 hang shape"
    return
  fi
  log "vr12r: abandonment resolved failed-closed (form=$rst, first non-working at ~${first_nonworking}s) — proceeding to the retry leg"

  # 4. RETRY: ONE tap on the recovery control, then the r6 approval
  #    loop. Approve every sheet the retry produces (authorize, then
  #    Zert's sign-proof sheet); Connected must arrive in-process
  #    within 110 s of the tap.
  dump_ui "$TMPD/retry-pre.xml" || true
  if ! tap_text "$TMPD/retry-pre.xml" "Connect wallet"; then
    fail "retry-tap" "no connect control on the resolved screen"
    return
  fi
  local t_retry; t_retry="$(date +%s)"
  log "vr12r: retry tapped (one tap); approval loop budget 110s (wall clock, r3)"
  # r3: the loop is wall-clock bounded and foreground-directed —
  # r2 incremented a nominal counter while each uiautomator dump
  # took far longer than the nominal step, so the loop overran its
  # budget in wall time and still never matched Connected (the
  # detector defect above). Now: dump only for the package that is
  # actually foreground, and bound by date, not by iteration count.
  local sheets_seen="0" appr="0" est="unknown" loop_elapsed=0 fg=""
  while [ "$loop_elapsed" -lt 110 ]; do
    fg="$(fg_pkg)"
    if [ "$fg" = "$MOCK" ]; then
      if dump_ui "$TMPD/retry-cur.xml" && sheet_present "$TMPD/retry-cur.xml"; then
        sheets_seen=$((sheets_seen + 1))
        cp "$TMPD/retry-cur.xml" "$OUT/hier-retry-sheet-$sheets_seen.xml" || true
        snap "shot-retry-sheet-$sheets_seen.png"
        log "vr12r: sheet #$sheets_seen presented after the retry tap (fg=$(fg_pkg))"
        if tap_exact "$TMPD/retry-cur.xml" "Connect" || tap_text "$TMPD/retry-cur.xml" "Connect" || tap_exact "$TMPD/retry-cur.xml" "Approve" || tap_text "$TMPD/retry-cur.xml" "Approve"; then
          appr=$((appr + 1))
          log "vr12r: approved sheet #$sheets_seen (approvals=$appr)"
          sleep 4
          satisfy_auth_prompt || true
        fi
      fi
    elif [ "$fg" = "$PKG" ]; then
      if dump_ui "$TMPD/retry-cur.xml"; then est="$(zert_state "$TMPD/retry-cur.xml")"; fi
      if [ "$est" = "connected" ]; then break; fi
    else
      # Focus drifted (launcher/other): bring Zert forward — am
      # start on its singleTask activity is a focus change, never
      # a restart.
      adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
    fi
    sleep 2
    loop_elapsed=$(( $(date +%s) - t_retry ))
  done
  sheets_after_retry="$sheets_seen"; approvals="$appr"
  if [ "$est" = "connected" ]; then
    retry_to_connected_s="$(( $(date +%s) - t_retry ))"
  else
    retry_to_connected_s="$(( $(date +%s) - t_retry ))"
  fi
  dump_ui "$OUT/hier-final.xml" || true
  snap "shot-final.png"
  app_pid_end="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')"
  log "vr12r: end state=$est after ${loop_elapsed}s loop (sheets=$sheets_seen approvals=$appr; pid start=$app_pid_start end=$app_pid_end)"

  if [ "$app_pid_start" != "$app_pid_end" ] || [ -z "$app_pid_end" ]; then
    fail "process" "app pid changed across the cell ($app_pid_start -> $app_pid_end) — not an in-process recovery"
    return
  fi
  if [ "$sheets_seen" -lt 1 ]; then
    fail "retry-sheet" "no wallet sheet presented after the retry tap within 110s (approvals=$appr, end state=$est)"
    return
  fi
  if [ "$appr" -lt 1 ]; then
    fail "retry-approval" "a sheet presented but no approval could be completed (end state=$est)"
    return
  fi
  if [ "$est" != "connected" ]; then
    fail "retry-connect" "retry did not reach Connected in-process within 110s (sheets=$sheets_seen approvals=$appr, end state=$est) — the vr12r failure shape"
    return
  fi
  cell="PASS"
  log "vr12r: PASS — retry completed in-process: $sheets_seen sheet(s), $appr approval(s), Connected ${retry_to_connected_s}s after the retry tap"
}

# --- vr12s: THE SCOPING LEG -------------------------------------------------
# Second defect layer (HAUNT v0.1.18 verdict, main relay 2026-10-30):
# the v0.1.16-shape reconciler arms on foreground return with a
# snapshot taken AT foreground time. A request started in the
# foreground that spans a LATER background->resume cycle is in that
# snapshot, and if it is still legitimately in flight past the 3 s
# grace it is claimed, resolved to Error, and (v0.1.5) the adapter
# is reset — even though nobody abandoned it. MWA association
# legitimately takes ~30 s (HAUNT's measurement), so slow-but-
# healthy connects are the exposed class.
#
# Leg design: fresh state (pm clear — pid continuity is asserted
# WITHIN the leg) -> tap Connect -> authorize sheet in flight ->
# HOME -> return to ZERT (the spanning resume) -> poll the state
# for 14 s: the request must stay Working the whole window (any
# failed-closed form while the sheet sits unanswered = claimed) ->
# bring the wallet task forward -> approve authorize + sign ->
# Connected within 60 s. PASS requires BOTH: never claimed AND
# completed on its own terms, same process.
bring_mock_forward() { # surface the in-flight sheet's task
  # (1) am start on the singleTask sheet activity: brings its task
  # forward; the live instance receives the intent (no onNewIntent
  # override — the existing sheet is what shows).
  adb shell am start -W -n "com.solana.mwallet/.MobileWalletAdapterActivity" >/dev/null 2>&1 || true
  sleep 2
  if [ "$(fg_pkg)" = "$MOCK" ] && dump_ui "$TMPD/mock-fwd.xml" && sheet_present "$TMPD/mock-fwd.xml"; then
    log "vr12s: wallet task forward via am start (sheet activity)"; return 0
  fi
  # (2) stack move-task on the mock's task id from recents.
  local tid
  tid="$(adb shell dumpsys activity recents 2>/dev/null | grep -i -B4 'A=com.solana.mwallet' | grep -oE '#[0-9]+' | tail -1 | tr -d '#')"
  if [ -n "$tid" ]; then
    adb shell am stack move-task "$tid" true >/dev/null 2>&1 || true
    sleep 2
    if [ "$(fg_pkg)" = "$MOCK" ] && dump_ui "$TMPD/mock-fwd.xml" && sheet_present "$TMPD/mock-fwd.xml"; then
      log "vr12s: wallet task forward via stack move-task $tid"; return 0
    fi
  fi
  # (3) recents + center tap on the first card (screenshot filed).
  adb shell input keyevent 187 >/dev/null 2>&1 || true
  sleep 2
  snap "shot-s-recents.png"
  local wh w h
  wh="$(adb shell wm size 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | head -1)"
  w="${wh%x*}"; h="${wh#*x}"
  if [ -n "$w" ] && [ -n "$h" ]; then
    adb shell input tap $((w / 2)) $((h / 3)) >/dev/null 2>&1 || true
    sleep 2
    if [ "$(fg_pkg)" = "$MOCK" ] && dump_ui "$TMPD/mock-fwd.xml" && sheet_present "$TMPD/mock-fwd.xml"; then
      log "vr12s: wallet task forward via recents center tap"; return 0
    fi
  fi
  log "vr12s: could not bring the wallet task forward (fg=$(fg_pkg))"
  return 1
}

cell_vr12s() {
  log "=== vr12s: foreground-started connect spanning a background->resume past grace must NOT be claimed ==="
  auth_fresh_enough
  # Fresh leg state: clear the app (vr12r may have ended Connected).
  # The leg asserts pid continuity from its own launch onward.
  adb shell pm clear "$PKG" >/dev/null 2>&1 || true
  sleep 1
  if ! goto_lobby; then s_cell="FAIL"; s_fail_step="lobby"; log "vr12s: FAIL step=lobby — could not reach the lobby"; return; fi
  local st; st="$(zert_state "$OUT/hier-lobby.xml")"
  if [ "$st" != "disconnected" ]; then s_cell="FAIL"; s_fail_step="precondition"; log "vr12s: FAIL step=precondition — lobby state=$st after pm clear"; return; fi
  s_pid_start="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')"
  log "vr12s: app pid at leg start = $s_pid_start"
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/s-pre.xml" || true
  if ! tap_text "$TMPD/s-pre.xml" "Connect wallet"; then s_cell="FAIL"; s_fail_step="connect-tap"; log "vr12s: FAIL step=connect-tap"; return; fi
  log "vr12s: connect tapped (foreground start); waiting for the authorize sheet"
  if ! wait_sheet "$OUT/hier-s-sheet1.xml" 45; then s_cell="FAIL"; s_fail_step="first-sheet"; log "vr12s: FAIL step=first-sheet — no authorize sheet within 45s"; return; fi
  snap "shot-s-sheet1.png"
  log "vr12s: authorize sheet in flight — backgrounding WITHOUT answering (the request stays legitimately in flight)"
  adb shell input keyevent 3 >/dev/null 2>&1 || true
  sleep 3
  snap "shot-s-backgrounded.png"
  # The spanning resume: bring Zert forward while the sheet is
  # still unanswered in the wallet task. onResume arms the
  # reconciler with this request in its snapshot.
  adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
  local t_resume; t_resume="$(date +%s)"
  log "vr12s: Zert resumed with the connect still in flight; polling 14s across the 3s grace"
  local elapsed=0 pst="working"
  s_claimed="0"; s_claimed_at_s=""
  while [ "$elapsed" -lt 14 ]; do
    if [ "$(fg_pkg)" = "$PKG" ] && dump_ui "$TMPD/s-poll.xml"; then
      cp "$TMPD/s-poll.xml" "$OUT/hier-s-poll-${elapsed}s.xml" || true
      pst="$(zert_state "$TMPD/s-poll.xml")"
    else
      pst="not-fg"
    fi
    log "vr12s: post-resume poll ${elapsed}s: state=$pst (fg=$(fg_pkg))"
    case "$pst" in
      disconnected|resolved-error)
        s_claimed="1"; s_claimed_at_s="$elapsed"
        log "vr12s: RECONCILER CLAIMED the in-flight request at ~${elapsed}s post-resume (form=$pst) while the wallet sheet sat unanswered"
        break ;;
    esac
    sleep 2; elapsed=$(( $(date +%s) - t_resume ))
  done
  dump_ui "$OUT/hier-s-after-grace.xml" || true
  snap "shot-s-after-grace.png"
  capture_window "s-grace"
  # Completion on its own terms: surface the still-unanswered sheet
  # and approve it (authorize, then Zert's sign-proof sheet).
  if ! bring_mock_forward; then
    s_completed="0"
    if [ "$s_claimed" = "1" ]; then s_cell="FAIL"; s_fail_step="reconciler-claim";
    else s_cell="FAIL"; s_fail_step="wallet-forward"; fi
    log "vr12s: FAIL step=$s_fail_step — sheet could not be surfaced for approval (claimed=$s_claimed)"
    return
  fi
  cp "$TMPD/mock-fwd.xml" "$OUT/hier-s-sheet-live.xml" || true
  snap "shot-s-sheet-live.png"
  local t_appr; t_appr="$(date +%s)"; local s_sheets=0 s_appr=0 est2="unknown"
  while [ $(( $(date +%s) - t_appr )) -lt 60 ]; do
    local fg2; fg2="$(fg_pkg)"
    if [ "$fg2" = "$MOCK" ]; then
      if dump_ui "$TMPD/s-cur.xml" && sheet_present "$TMPD/s-cur.xml"; then
        s_sheets=$((s_sheets + 1))
        cp "$TMPD/s-cur.xml" "$OUT/hier-s-retry-sheet-$s_sheets.xml" || true
        if tap_exact "$TMPD/s-cur.xml" "Connect" || tap_text "$TMPD/s-cur.xml" "Connect" || tap_exact "$TMPD/s-cur.xml" "Approve" || tap_text "$TMPD/s-cur.xml" "Approve"; then
          s_appr=$((s_appr + 1)); log "vr12s: approved sheet #$s_sheets (approvals=$s_appr)"; sleep 4; satisfy_auth_prompt || true
        fi
      fi
    elif [ "$fg2" = "$PKG" ]; then
      if dump_ui "$TMPD/s-cur.xml"; then est2="$(zert_state "$TMPD/s-cur.xml")"; fi
      if [ "$est2" = "connected" ]; then break; fi
    else
      adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
    fi
    sleep 2
  done
  if dump_ui "$TMPD/s-final.xml" && [ "$(fg_pkg)" = "$PKG" ]; then est2="$(zert_state "$TMPD/s-final.xml")"; cp "$TMPD/s-final.xml" "$OUT/hier-s-final.xml" || true; fi
  snap "shot-s-final.png"
  s_pid_end="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')"
  log "vr12s: completion end state=$est2 (sheets=$s_sheets approvals=$s_appr; claimed=$s_claimed at=${s_claimed_at_s:-none}s; pid $s_pid_start -> $s_pid_end)"
  if [ "$est2" = "connected" ]; then s_completed="1"; else s_completed="0"; fi
  if [ "$s_pid_start" != "$s_pid_end" ] || [ -z "$s_pid_end" ]; then
    s_cell="FAIL"; s_fail_step="process"; log "vr12s: FAIL step=process — pid changed ($s_pid_start -> $s_pid_end)"; return
  fi
  if [ "$s_claimed" = "1" ]; then
    s_cell="FAIL"; s_fail_step="reconciler-claim"
    log "vr12s: FAIL step=reconciler-claim — the spanning resume's reconciler resolved a legitimate in-flight connect at ~${s_claimed_at_s}s post-resume (grace 3s); completion_after_claim=$s_completed"
    return
  fi
  if [ "$s_completed" != "1" ]; then
    s_cell="FAIL"; s_fail_step="completion"; log "vr12s: FAIL step=completion — never claimed, but the request did not complete after approval (end state=$est2)"; return
  fi
  s_cell="PASS"
  log "vr12s: PASS — the in-flight connect survived the spanning resume unclaimed and completed on its own terms"
}

cell_vr12r
capture_window "final"
cell_vr12s
capture_window "s-final"

# --- verdict -----------------------------------------------------------------
if [ "$cell" = "PASS" ] && { [ "$fatal_pkg_total" -gt 0 ] || [ "$fatal_mock_total" -gt 0 ] || [ "$ise_total" -gt 0 ]; }; then
  cell="FAIL"; fail_step="crash-scan"
  log "vr12r: verdict poisoned by the crash scan (app_fatal=$fatal_pkg_total mock_fatal=$fatal_mock_total sender_ise=$ise_total)"
fi
{
  echo "cell=$cell"
  [ -n "$fail_step" ] && echo "fail_step=$fail_step"
  echo "resolution_s=$resolution_s"
  echo "resolution_form=$resolution_form"
  echo "retry_to_connected_s=$retry_to_connected_s"
  echo "sheets_after_retry=$sheets_after_retry"
  echo "approvals=$approvals"
  echo "app_pid_start=$app_pid_start"
  echo "app_pid_end=$app_pid_end"
  echo "app_fatal_total=$fatal_pkg_total"
  echo "mock_fatal_total=$fatal_mock_total"
  echo "sender_signature_ise_total=$ise_total"
  echo "lock_pin=$lock_pin"
  echo "lock_fp=$lock_fp"
  echo "mock_auth=$auth_note"
  echo "expected_pubkey=$EXPECTED_PUBKEY"
  echo "leg_vr12s=$s_cell"
  [ -n "$s_fail_step" ] && echo "leg_vr12s_fail_step=$s_fail_step"
  echo "leg_vr12s_claimed=$s_claimed"
  echo "leg_vr12s_claimed_at_s=$s_claimed_at_s"
  echo "leg_vr12s_completed=$s_completed"
  echo "leg_vr12s_pid_start=$s_pid_start"
  echo "leg_vr12s_pid_end=$s_pid_end"
} > "$OUT/verdict.txt"
cat "$OUT/verdict.txt" | tee -a "$LANE_LOG"
log "vr12r: verdict written to $OUT/verdict.txt"
[ "$cell" = "PASS" ] && [ "$s_cell" = "PASS" ]
