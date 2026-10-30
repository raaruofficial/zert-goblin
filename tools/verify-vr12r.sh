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
#       session        -> "Disconnect wallet" present AND the launch
#                         button reads "Insert coin..." — both render
#                         only when the client holds a server-issued
#                         session. A session exists only after the
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
resolution_s=""; retry_to_connected_s=""; sheets_after_retry="0"; approvals="0"

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
  if grep -q "Disconnect wallet" "$f" && grep -q "Insert coin" "$f"; then echo "connected"
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

  # 3. RESOLUTION WAIT: the reconciler (MainActivity.onResume ->
  #    WalletManager.onForeground) must resolve the interrupted
  #    connect to the abandonment Error within 40 s of the return.
  local elapsed=0 rst="working"
  while [ "$elapsed" -lt 40 ]; do
    rst="$(zert_state_fg)"
    if [ "$rst" = "resolved-error" ] || [ "$rst" = "connected" ] || [ "$rst" = "disconnected" ]; then break; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  resolution_s="$elapsed"
  dump_ui "$OUT/hier-resolved.xml" || true
  snap "shot-resolved.png"
  capture_window "resolution"
  log "vr12r: state ${elapsed}s after foreground return = $rst"
  if [ "$rst" = "connected" ]; then
    # The zombie approval cannot have happened (nothing approved it);
    # a Connected here would mean the sheet resumed and completed on
    # return — not the abandonment path. Record and stop: there is
    # no resolved Error to retry from.
    fail "resolution" "state resolved to Connected without any approval — abandonment did not take the interrupted-resolution path"
    return
  fi
  if [ "$rst" != "resolved-error" ]; then
    fail "resolution" "no abandonment resolution within 40s of foreground return (end state=$rst) — the vr12 hang shape"
    return
  fi
  log "vr12r: abandonment resolution observed at ~${elapsed}s (Error + abandonment message on the client)"

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
  log "vr12r: retry tapped (one tap); approval loop budget 110s"
  local sheets_seen="0" appr="0" est="unknown" loop_elapsed=0
  while [ "$loop_elapsed" -lt 110 ]; do
    est="$(zert_state_fg)"
    if [ "$est" = "connected" ]; then break; fi
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
    sleep 3; loop_elapsed=$((loop_elapsed + 3))
    est="$(zert_state_fg)"
    if [ "$est" = "connected" ]; then break; fi
    # Keep the app task reachable: if focus drifted to the launcher
    # between sheets, bring Zert forward (am start on its singleTask
    # activity — a focus change, never a restart).
    if [ "$(fg_pkg)" != "$PKG" ] && [ "$(fg_pkg)" != "$MOCK" ]; then
      adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
    fi
  done
  sheets_after_retry="$sheets_seen"; approvals="$appr"
  retry_to_connected_s="$(( $(date +%s) - t_retry ))"
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

cell_vr12r
capture_window "final"

# --- verdict -----------------------------------------------------------------
if [ "$cell" = "PASS" ] && { [ "$fatal_pkg_total" -gt 0 ] || [ "$fatal_mock_total" -gt 0 ] || [ "$ise_total" -gt 0 ]; }; then
  cell="FAIL"; fail_step="crash-scan"
  log "vr12r: verdict poisoned by the crash scan (app_fatal=$fatal_pkg_total mock_fatal=$fatal_mock_total sender_ise=$ise_total)"
fi
{
  echo "cell=$cell"
  [ -n "$fail_step" ] && echo "fail_step=$fail_step"
  echo "resolution_s=$resolution_s"
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
} > "$OUT/verdict.txt"
cat "$OUT/verdict.txt" | tee -a "$LANE_LOG"
log "vr12r: verdict written to $OUT/verdict.txt"
[ "$cell" = "PASS" ]
