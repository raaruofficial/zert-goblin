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
#   4. RESOLUTION (r4: wire-graded): the reconciler's claim must
#      DELIVER — since v0.1.7 the claim posts a `claim-delivery
#      requestId=... gen=...` Log.d line (tag ZertGoblinWallet) and
#      settles the gen-1 JS request with the ABANDONED failure
#      inside the post-resume grace window. That marker — not any
#      DOM form — proves resolution. If the zombie unwinds before
#      the claim can fire (the wallet removes the claim's object),
#      resolution is recorded as delivered-via-unwind and the leg
#      proceeds; the claim sub-criterion is then "not exercised",
#      stated in the verdict. Absent both -> FAIL
#      step=resolution-delivery, distinct from any loop failure.
#   5. RETRY: tap the connect control ONCE. Approval loop (HAUNT r6
#      form, 150 s budget — derivation in the r4 notes below):
#      whenever a Mock sheet is up, approve it (Connect on the
#      authorize sheet, Approve on the sign-proof sheet — Zert's
#      session flow signs a server nonce right after connect, so a
#      cured retry produces TWO sheets).
#   6. PASS only if, in the SAME process (pid continuity asserted):
#      the claim-delivery for gen-1 landed in the grace window (or
#      the unwind path is recorded); the retry tap produced a fresh
#      association scenario on the wire; on the claim path — where
#      the claim raises lastRequestInterrupted — the refire loop
#      logged at least one attempt line (on the unwind path the
#      loop is not armed by design and the retry is graded on the
#      single-attempt bar); a sheet presented after the retry tap;
#      at least one approval completed; and Zert reaches its
#      session state (DOM Connected — the one DOM criterion kept)
#      within 150 s of the retry tap.
#
# OBSERVATION SURFACES (what the grades rest on, r4):
#   - WIRE MARKERS (primary since r4): a continuous logcat stream
#     (`adb logcat -v epoch`) is captured to logcat-stream.txt for
#     the whole run and queried at every decision point, so ring-
#     buffer rotation no longer bounds the evidence. Markers:
#       scenario created  -> "LocalAssociationScenario: Creating
#                            local association scenario" (app pid):
#                            an association attempt actually fired;
#                            one per connect attempt (incl. refires)
#                            and per sign operation.
#       session ready     -> "LocalAssociationScenario: Session
#                            established, scenario ready for use".
#       loop attempt      -> "ZertGoblinWallet: connect attempt
#                            N/3 outcome=... elapsedMs=...
#                            slow=... definitive=..." — the refire
#                            loop's own per-attempt account.
#       claim delivery    -> "ZertGoblinWallet: claim-delivery
#                            requestId=... gen=..." — the v0.1.7
#                            bridge settlement firing at claim time.
#       authorize done    -> mock-side "BaseScenario: Authorize
#                            request completed successfully".
#       consumption       -> app-side "JsonRpc20Client: JSON-RPC
#                            2.0 message received" followed within
#                            ~1-3 s by "MobileWalletAdapterWebSocket:
#                            close" on a DIFFERENT tid than the
#                            receive (the app consuming the result
#                            and tearing the scenario down). The
#                            zombie-death contrast: a scenario
#                            disconnect with NO receipt in the
#                            preceding seconds, plus the mock-side
#                            "authorization request declined".
#       scenario teardown -> "LocalAssociationScenario:
#                            Disconnected during normal operation".
#   - uiautomator hierarchy dumps: used to DRIVE the cell (taps,
#     sheet presence via foreground package + sheet controls) and
#     for the final Connected criterion ONLY (the lobby banner
#     "WALLET CONNECTED" / "Insert coin..." launch button — a
#     session exists only after the MWA connect returned the mock
#     key's pubkey AND the mock signed the server nonce AND the
#     game server verified the ed25519 signature, so the session
#     state is bound to the mock's pubkey even though the client
#     never renders the pubkey string itself; the DOM "Disconnect
#     wallet" button below the fold is accepted as an alternative
#     marker with "Insert coin"). DOM state at every other poll is
#     filed as evidence and NEVER gates (see the r4 notes).
#     The mock-side anchor: the mock main screen shows the imported
#     key's address; the driver asserts it equals EXPECTED_PUBKEY.
#   - logcat windows: any AndroidRuntime FATAL for either package,
#     or an ActivityResultSender-signature IllegalStateException,
#     poisons the verdict (HAUNT scan rule; unchanged).
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
#
# Driver r4 (this revision) — DETECTOR REDESIGN, per
# VR12R_CELL_V016.md SS6 follow-up 2 and the v0.1.7 strike record.
# The v0.1.6 run proved the DOM detector cannot grade these legs
# on this client: the deployed lobby renders NO in-flight state
# (its only "Connecting..." string lives in the PurchaseSheet), so
# a "disconnected" poll is consistent with no attempt, an attempt
# in flight, and an attempt resolved alike; r3's vr12s poll also
# broke on its first (uninformative) read and never observed the
# grace window. Itemized changes vs r3:
#   (1) Continuous logcat stream in epoch format for the whole
#       run; all grading queries run against the stream file.
#   (2) vr12r resolution is graded on the claim-delivery wire
#       marker for gen-1 inside the post-resume grace window
#       (allowance 25 s from resume: the reconciler grace is 3 s,
#       battery #6 measured the delivery at 3.0-3.2 s; the rest is
#       clock-skew/render margin) — a build whose claim never
#       delivers fails step=resolution-delivery HERE. The DOM
#       trajectory is still dumped per poll as evidence.
#       Unwind-before-claim is recorded as resolution_path=unwind
#       (claim sub-criterion not exercised), never silently
#       upgraded to a claim grade.
#   (3) Retry budget 110 s -> 150 s, derived from the loop's own
#       arithmetic: worst case 3 attempts x 35 s slots + 2 x 0.5 s
#       refire gaps = 106 s, plus ~44 s for approvals and the
#       session flow. A PASS on attempt 3 is therefore inside the
#       budget by construction, and a FAIL is not excused by it.
#   (4) Retry grading adds wire criteria — a fresh scenario after
#       the tap (step=retry-scenario) and >=1 loop attempt line
#       after the tap (step=retry-attempt) — and extracts the
#       per-attempt topology into the verdict: scenario epochs,
#       attempt-line epochs/classifications, the zombie-death
#       epoch, and which attempt's sheet landed (attributed by
#       timing: the latest scenario created before the first
#       post-retry sheet was observed).
#   (5) vr12s: the post-resume poll spans the FULL grace window
#       (14 s) with NO early break. Claimed = a claim-delivery
#       marker inside the window (the spanning connect is the
#       only live bridge request, so any in-window claim-delivery
#       targets it) or its wire signature breaking (spanning
#       scenario disconnects with no preceding receipt). DOM
#       polls are evidence only. Never-claimed is thus a positive
#       wire observation across the whole window, not a DOM
#       absence.
#   (6) vr12s completion is graded on the consumption signature
#       (authorize-completed mock-side + app-side receipt +
#       app-initiated close on a different tid within 3 s) plus
#       the DOM Connected criterion. Claim-prong and
#       consumption-prong failures are DISTINCT steps
#       (reconciler-claim vs completion-consumption/completion),
#       never blurred.
#
# Driver r5 (this revision) — INSTRUMENT FIX. The first r4 run
# (CI 41047924177, against v0.1.7) graded BOTH legs on an empty
# marker set: `adb logcat -v epoch` right-pads the epoch field
# with leading spaces, and r4's line regex anchored the epoch at
# column 0, so no stream line ever parsed. The run's FAILs
# (resolution-delivery; completion-consumption 0/0/0) are
# instrument artifacts — the filed stream, re-parsed offline
# with the corrected pattern, shows the leg-1 claim-delivery at
# the grace and the leg-2 consumption signature complete (see
# VR12R_CELL_V017.md, which records the run's re-grade). r4's
# offline helper validation used a synthetic stream whose
# converter emitted unpadded epochs, which is why it passed:
# r5's helpers were re-validated against the REAL padded stream
# from CI 41047924177. Changes vs r4: the line regex tolerates
# leading whitespace in all three marker helpers (mq,
# zombie_death_epoch, consumption_after); the driver logs its
# own t_abandon / t_resume epochs so post-hoc offset recovery
# does not depend on lane-log seconds. No grading-semantics
# change.
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
# vr12r r4 wire-marker verdict state
resolution_path=""        # claim | unwind | none
claim_gen=""; claim_delivery_offset_s=""; claim_exercised=""
zombie_death_offset_s=""  # relative to the retry tap (negative = died before it)
retry_scenarios="0"; retry_attempts="0"; retry_budget_s="150"; sheet_attempt=""
# vr12s (scoping leg) verdict state
s_cell="NOT-RUN"; s_fail_step=""; s_claimed=""; s_claimed_at_s=""; s_completed=""; s_pid_start=""; s_pid_end=""
# vr12s r4 wire-marker verdict state
s_claim_form=""           # claim-delivery | wire-break | ""
s_consumption=""          # authorize/receipt/close booleans, e.g. 1/1/1
s_sign_sheets="0"

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

# --- r4: continuous logcat stream + wire-marker queries -----------------
# The stream is the primary grading record: `adb logcat -v epoch`
# runs for the whole cell (both legs) into $STREAM, so ring-buffer
# rotation (~2 min on this emulator image) cannot eat marker lines.
# The capture_window dumps above remain the crash-scan surface.
STREAM="$OUT/logcat-stream.txt"
STREAM_PID=""
start_stream() {
  : > "$STREAM"
  adb logcat -c >/dev/null 2>&1 || true
  adb logcat -v epoch > "$STREAM" 2>/dev/null &
  STREAM_PID=$!
  log "stream: logcat -v epoch streaming to $STREAM (pid $STREAM_PID)"
}
stop_stream() {
  if [ -n "$STREAM_PID" ]; then kill "$STREAM_PID" >/dev/null 2>&1 || true; STREAM_PID=""; fi
}

# mq — marker query over the stream file.
#   mq count <regex> <after_epoch> [pid]     -> integer count
#   mq first <regex> <after_epoch> [pid]     -> "epoch tid" of first match (empty if none)
#   mq epochs <regex> <after_epoch> [pid]    -> space-separated epochs of every match
#   mq lines <regex> <after_epoch> [pid]     -> the matching raw lines
# Epoch lines look like: "1761876341.587  5269  5467 V Tag: message".
# Non-matching lines (buffer banners etc.) are skipped. The regex is
# matched against the "Tag: message" tail; pid (field 2) is an exact
# filter when given.
mq() {
  python3 - "$STREAM" "$@" <<'PY'
import re, sys
path, mode, pattern, after = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
pid = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None
rx = re.compile(pattern)
line_rx = re.compile(r"^\s*(\d+\.\d+)\s+(\d+)\s+(\d+)\s+[VDIWEA] (.*)$")
hits = []
try:
    fh = open(path, encoding="utf-8", errors="ignore")
except OSError:
    fh = []
for ln in fh:
    m = line_rx.match(ln)
    if not m:
        continue
    epoch, lpid, tid, tail = float(m.group(1)), m.group(2), m.group(3), m.group(4)
    if epoch < after:
        continue
    if pid is not None and lpid != pid:
        continue
    if rx.search(tail):
        hits.append((epoch, tid, ln.rstrip("\n")))
if mode == "count":
    print(len(hits))
elif mode == "first":
    if hits:
        print(f"{hits[0][0]:.3f} {hits[0][1]}")
elif mode == "epochs":
    print(" ".join(f"{h[0]:.3f}" for h in hits))
elif mode == "lines":
    for h in hits:
        print(h[2])
PY
}

# zombie_death_epoch <after_epoch> <app_pid> [appside] — the gen-1
# (or spanning) scenario's death WITHOUT consumption: first of
# (a) the mock-side "authorization request declined" line,
# (b) an app-side scenario disconnect whose preceding 3 s hold no
# app-side JSON-RPC receipt. With the "appside" scope, branch (a)
# is skipped: a decline line cannot be attributed to a specific
# scenario from its text alone, so vr12s (where a previous leg's
# zombie could decline late) grades only on its own process's
# disconnects. Prints the epoch (empty if still alive).
zombie_death_epoch() {
  python3 - "$STREAM" "$1" "$2" "${3:-}" <<'PY'
import re, sys
path, after, pid = sys.argv[1], float(sys.argv[2]), sys.argv[3]
appside = len(sys.argv) > 4 and sys.argv[4] == "appside"
line_rx = re.compile(r"^\s*(\d+\.\d+)\s+(\d+)\s+(\d+)\s+[VDIWEA] (.*)$")
decline = None
receipts = []
disconnects = []
try:
    fh = open(path, encoding="utf-8", errors="ignore")
except OSError:
    fh = []
for ln in fh:
    m = line_rx.match(ln)
    if not m:
        continue
    epoch, lpid, tail = float(m.group(1)), m.group(2), m.group(4)
    if epoch < after:
        continue
    if "authorization request declined" in tail and decline is None:
        decline = epoch
    if lpid == pid and "JsonRpc20Client: JSON-RPC 2.0 message received" in tail:
        receipts.append(epoch)
    if lpid == pid and "LocalAssociationScenario: Disconnected" in tail:
        disconnects.append(epoch)
cands = []
if decline is not None and not appside:
    cands.append(decline)
for d in disconnects:
    if not any(0 <= d - r <= 3.0 for r in receipts):
        cands.append(d)
        break
print(f"{min(cands):.3f}" if cands else "")
PY
}

# consumption_after <after_epoch> <app_pid> — the consumption
# signature following an approval: mock-side authorize completion,
# then an app-side JSON-RPC receipt, then an app-initiated websocket
# close on a DIFFERENT tid within 3 s of the receipt. Prints
# "authz receipt close receipt_epoch close_epoch" with 0/1 flags
# (epochs 0 when absent).
consumption_after() {
  python3 - "$STREAM" "$1" "$2" <<'PY'
import re, sys
path, after, pid = sys.argv[1], float(sys.argv[2]), sys.argv[3]
line_rx = re.compile(r"^\s*(\d+\.\d+)\s+(\d+)\s+(\d+)\s+[VDIWEA] (.*)$")
authz = 0
receipt = None  # (epoch, tid)
close = None
try:
    fh = open(path, encoding="utf-8", errors="ignore")
except OSError:
    fh = []
for ln in fh:
    m = line_rx.match(ln)
    if not m:
        continue
    epoch, lpid, tid, tail = float(m.group(1)), m.group(2), m.group(3), m.group(4)
    if epoch < after:
        continue
    if "Authorize request completed successfully" in tail:
        authz = 1
    if lpid == pid and receipt is None and "JsonRpc20Client: JSON-RPC 2.0 message received" in tail:
        receipt = (epoch, tid)
        continue
    if (lpid == pid and receipt is not None and close is None
            and re.search(r"MobileWalletAdapterWebSocket: close\s*$", tail)
            and tid != receipt[1] and 0 <= epoch - receipt[0] <= 3.0):
        close = epoch
r_e = f"{receipt[0]:.3f}" if receipt else "0"
c_e = f"{close:.3f}" if close else "0"
print(f"{authz} {1 if receipt else 0} {1 if close else 0} {r_e} {c_e}")
PY
}

host_now() { date +%s.%N; }

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
  #    r4: the gen-1 scenario's wire birth is recorded first — the
  #    claim-delivery and zombie queries below are anchored to it.
  local t_connect; t_connect="$(host_now)"
  local gen1; gen1="$(mq first 'LocalAssociationScenario: Creating local association scenario' 0 "$app_pid_start")"
  log "vr12r: gen-1 scenario on the wire: ${gen1:-none} (connect tap ~$t_connect)"
  local t_abandon; t_abandon="$(host_now)"
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
  # t_resume: the return action has landed; onForeground (and the
  # reconciler's 3 s grace) runs from here. Marker offsets are
  # measured against this epoch; marker SEARCHES anchor 2 s
  # earlier to absorb any host/device clock skew.
  local t_resume; t_resume="$(host_now)"
  local t_resume_anchor; t_resume_anchor="$(python3 -c "print(f'{$t_resume - 2:.3f}')")"
  log "vr12r: epochs — gen1=${gen1:-none} t_abandon=$t_abandon t_resume=$t_resume"
  sleep 2
  local t_return; t_return="$(date +%s)"
  snap "shot-returned.png"

  # 3. RESOLUTION WAIT (r4 — WIRE-GRADED): the reconciler's claim
  #    must DELIVER. The proof is the claim-delivery marker for the
  #    gen-1 generation landing inside the post-resume grace window
  #    (allowance 25 s from t_resume; grace 3 s + battery anchor
  #    3.0-3.2 s + skew margin). DOM dumps are filed per poll as
  #    evidence and never gate — on this client a "disconnected"
  #    poll is consistent with no attempt, an in-flight attempt,
  #    and a resolved attempt alike (VR12R_CELL_V016 SS3).
  #    If the zombie unwinds before the claim can fire (mock-side
  #    decline / scenario disconnect with no preceding receipt),
  #    the wallet removed the claim's object: resolution is
  #    recorded as delivered-via-unwind, the claim sub-criterion is
  #    marked NOT exercised, and the leg proceeds — the retry
  #    still grades the loop. Absent both within 40 s of the
  #    resume -> FAIL step=resolution-delivery: the claim never
  #    delivered, distinct from any loop failure.
  local elapsed=0 rst="unknown" saw_fg="0" claim_hit="" unwind_hit="" late_claim=""
  while [ "$elapsed" -lt 40 ]; do
    if [ "$(fg_pkg)" = "$PKG" ]; then
      saw_fg="1"
      if dump_ui "$TMPD/poll.xml"; then
        cp "$TMPD/poll.xml" "$OUT/hier-poll-${elapsed}s.xml" || true
        rst="$(zert_state "$TMPD/poll.xml")"
      fi
    fi
    claim_hit="$(mq first 'ZertGoblinWallet: claim-delivery requestId=' "$t_resume_anchor" )"
    if [ -n "$claim_hit" ]; then
      local claim_epoch="${claim_hit%% *}"
      claim_delivery_offset_s="$(python3 -c "print(f'{$claim_epoch - $t_resume:.1f}')")"
      claim_gen="$(mq lines 'ZertGoblinWallet: claim-delivery requestId=' "$t_resume_anchor" | head -n 1 | sed -n 's/.* gen=\([0-9]*\).*/\1/p')"
      if python3 -c "exit(0 if $claim_delivery_offset_s <= 25 else 1)"; then
        resolution_path="claim"; claim_exercised="1"
      else
        # A claim-delivery exists but landed outside the grace
        # allowance — recorded as such; it is not an in-window
        # delivery and does not prove this step.
        log "vr12r: claim-delivery landed LATE (offset ${claim_delivery_offset_s}s > 25s allowance, gen=$claim_gen)"
        late_claim="$claim_delivery_offset_s"
        claim_hit=""
      fi
    fi
    if [ -z "$claim_hit" ]; then
      unwind_hit="$(zombie_death_epoch "$t_abandon" "$app_pid_start")"
      if [ -n "$unwind_hit" ]; then
        resolution_path="unwind"; claim_exercised="0"
      fi
    fi
    log "vr12r: resolution poll ${elapsed}s: dom=$rst claim=${claim_hit:-none} unwind=${unwind_hit:-none} (fg=$(fg_pkg))"
    if [ -n "$claim_hit" ] || [ -n "$unwind_hit" ]; then break; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  resolution_s="${claim_delivery_offset_s:-$elapsed}"
  resolution_form="$rst"
  dump_ui "$OUT/hier-resolved.xml" || true
  snap "shot-resolved.png"
  capture_window "resolution"
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
  if [ "$resolution_path" = "claim" ]; then
    log "vr12r: resolution PROVEN on the wire — claim-delivery gen=$claim_gen at +${claim_delivery_offset_s}s after resume (grace window)"
    mq lines 'ZertGoblinWallet: claim-delivery requestId=' "$t_resume_anchor" | head -n 2 | tee -a "$LANE_LOG" || true
  elif [ "$resolution_path" = "unwind" ]; then
    log "vr12r: resolution delivered via UNWIND at epoch $unwind_hit (zombie died before the claim could fire) — claim sub-criterion NOT exercised this run"
  else
    fail "resolution-delivery" "no in-window claim-delivery for gen-1 within 40s of the resume and no zombie-unwind signature — the reconciler's claim never delivered in its grace window (dom end state=$rst${late_claim:+, late claim at +${late_claim}s})"
    return
  fi
  log "vr12r: abandonment resolved (path=$resolution_path, dom form=$rst) — proceeding to the retry leg"

  # 4. RETRY (r4): ONE tap on the recovery control, then the r6
  #    approval loop. Approve every sheet the retry produces
  #    (authorize, then Zert's sign-proof sheet); Connected must
  #    arrive in-process within the 150 s budget. The budget is
  #    derived from the loop's own arithmetic (KFC008_SHAPE2_
  #    STRIKE): 3 attempts x 35 s slots + 2 x 0.5 s refire gaps =
  #    106 s worst case, + ~44 s for two approvals and the session
  #    flow. A PASS on attempt 3 is inside budget by construction.
  dump_ui "$TMPD/retry-pre.xml" || true
  if ! tap_text "$TMPD/retry-pre.xml" "Connect wallet"; then
    fail "retry-tap" "no connect control on the resolved screen"
    return
  fi
  local t_retry_f; t_retry_f="$(host_now)"
  local t_retry; t_retry="$(date +%s)"
  log "vr12r: retry tapped (one tap) at epoch $t_retry_f; approval loop budget ${retry_budget_s}s (r4: 106s loop worst case + approval margin)"
  # r3 discipline kept: the loop is wall-clock bounded and
  # foreground-directed — dump only for the package that is
  # actually foreground, bound by date, not by iteration count.
  # r4 adds the first-sheet epoch for attempt attribution.
  local sheets_seen="0" appr="0" est="unknown" loop_elapsed=0 fg="" t_first_sheet=""
  while [ "$loop_elapsed" -lt "$retry_budget_s" ]; do
    fg="$(fg_pkg)"
    if [ "$fg" = "$MOCK" ]; then
      if dump_ui "$TMPD/retry-cur.xml" && sheet_present "$TMPD/retry-cur.xml"; then
        sheets_seen=$((sheets_seen + 1))
        if [ -z "$t_first_sheet" ]; then t_first_sheet="$(host_now)"; fi
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
  retry_to_connected_s="$(( $(date +%s) - t_retry ))"
  dump_ui "$OUT/hier-final.xml" || true
  snap "shot-final.png"
  app_pid_end="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')"

  # r4 wire accounting for the retry phase (from the stream):
  # every scenario created after the tap (connect attempts incl.
  # refires, then the sign-proof scenario), every loop attempt
  # line, the zombie's death, and which attempt's sheet landed.
  local scen_epochs attempt_lines zdeath
  scen_epochs="$(mq epochs 'LocalAssociationScenario: Creating local association scenario' "$t_retry_f" "$app_pid_start")"
  retry_scenarios="$(mq count 'LocalAssociationScenario: Creating local association scenario' "$t_retry_f" "$app_pid_start")"
  attempt_lines="$(mq lines 'ZertGoblinWallet: connect attempt ' "$t_retry_f")"
  retry_attempts="$(mq count 'ZertGoblinWallet: connect attempt ' "$t_retry_f")"
  zdeath="$(zombie_death_epoch "$t_abandon" "$app_pid_start")"
  if [ -n "$zdeath" ]; then
    zombie_death_offset_s="$(python3 -c "print(f'{$zdeath - $t_retry_f:.1f}')")"
  fi
  if [ -n "$t_first_sheet" ] && [ -n "$scen_epochs" ]; then
    sheet_attempt="$(python3 -c "
epochs=[float(x) for x in '$scen_epochs'.split()]
n=sum(1 for e in epochs if e <= $t_first_sheet)
print(n if n else '')")"
  fi
  log "vr12r: wire topology after the retry tap: scenarios=$retry_scenarios (epochs: ${scen_epochs:-none})"
  log "vr12r: loop attempt lines=$retry_attempts; zombie death epoch=${zdeath:-alive} (offset vs retry tap: ${zombie_death_offset_s:-n/a}s); sheet landed on attempt=${sheet_attempt:-unknown}"
  if [ -n "$attempt_lines" ]; then printf '%s\n' "$attempt_lines" | tee -a "$LANE_LOG" || true; fi
  log "vr12r: end state=$est after ${loop_elapsed}s loop (sheets=$sheets_seen approvals=$appr; pid start=$app_pid_start end=$app_pid_end)"

  if [ "$app_pid_start" != "$app_pid_end" ] || [ -z "$app_pid_end" ]; then
    fail "process" "app pid changed across the cell ($app_pid_start -> $app_pid_end) — not an in-process recovery"
    return
  fi
  if [ "$retry_scenarios" -lt 1 ]; then
    fail "retry-scenario" "the retry tap produced NO fresh association scenario on the wire within ${retry_budget_s}s — the tap never became a connect (sheets=$sheets_seen, end state=$est)"
    return
  fi
  # The attempt-line criterion binds ONLY on the claim path: a
  # reconciler claim raises lastRequestInterrupted (WalletManager),
  # so the retry connect MUST run the loop and log its attempts.
  # On the unwind path nothing raised the flag (the deferred
  # completed on its own; no claim, no interrupted wrapper exit),
  # so the retry is a plain single-attempt connect by design —
  # grading it on scenario + sheet + approval + Connected (the
  # pre-loop bar) and recording the attempt count as information.
  if [ "$resolution_path" = "claim" ] && [ "$retry_attempts" -lt 1 ]; then
    fail "retry-attempt" "resolution came via a claim (loop armed) and a scenario fired after the retry tap, but the refire loop logged no attempt line — the loop did not run this connect (scenarios=$retry_scenarios, end state=$est)"
    return
  fi
  if [ "$resolution_path" = "unwind" ]; then
    log "vr12r: unwind path — loop not armed by design; retry graded on the single-attempt bar (attempt lines=$retry_attempts, informational)"
  fi
  if [ "$sheets_seen" -lt 1 ]; then
    fail "retry-sheet" "no wallet sheet presented after the retry tap within ${retry_budget_s}s (scenarios=$retry_scenarios attempts=$retry_attempts, end state=$est)"
    return
  fi
  if [ "$appr" -lt 1 ]; then
    fail "retry-approval" "a sheet presented but no approval could be completed (end state=$est)"
    return
  fi
  if [ "$est" != "connected" ]; then
    fail "retry-connect" "retry did not reach Connected in-process within ${retry_budget_s}s (sheets=$sheets_seen approvals=$appr scenarios=$retry_scenarios attempts=$retry_attempts, end state=$est) — the vr12r failure shape"
    return
  fi
  cell="PASS"
  log "vr12r: PASS — retry completed in-process: $sheets_seen sheet(s), $appr approval(s), Connected ${retry_to_connected_s}s after the retry tap; resolution path=$resolution_path, scenarios=$retry_scenarios, loop attempts=$retry_attempts, sheet on attempt=${sheet_attempt:-unknown}"
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
# HOME -> return to ZERT (the spanning resume) -> observe the FULL
# 14 s grace window on WIRE markers (r4; no early break, DOM filed
# as evidence only): claimed = an in-window claim-delivery marker
# or the spanning scenario's wire signature breaking -> bring the
# wallet task forward -> approve authorize + sign -> consumption
# signature on the wire + Connected within 60 s. PASS requires
# BOTH: never claimed AND completed on its own terms, same
# process. Claim and consumption failures are distinct steps.
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
  local t0; t0="$(host_now)"
  if ! tap_text "$TMPD/s-pre.xml" "Connect wallet"; then s_cell="FAIL"; s_fail_step="connect-tap"; log "vr12s: FAIL step=connect-tap"; return; fi
  log "vr12s: connect tapped (foreground start); waiting for the authorize sheet"
  if ! wait_sheet "$OUT/hier-s-sheet1.xml" 45; then s_cell="FAIL"; s_fail_step="first-sheet"; log "vr12s: FAIL step=first-sheet — no authorize sheet within 45s"; return; fi
  snap "shot-s-sheet1.png"
  local span_scen; span_scen="$(mq first 'LocalAssociationScenario: Creating local association scenario' "$t0" "$s_pid_start")"
  log "vr12s: spanning scenario on the wire: ${span_scen:-none}"
  log "vr12s: authorize sheet in flight — backgrounding WITHOUT answering (the request stays legitimately in flight)"
  adb shell input keyevent 3 >/dev/null 2>&1 || true
  sleep 3
  snap "shot-s-backgrounded.png"
  # The spanning resume: bring Zert forward while the sheet is
  # still unanswered in the wallet task.
  adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
  local t_resume_f; t_resume_f="$(host_now)"
  local t_resume_anchor; t_resume_anchor="$(python3 -c "print(f'{$t_resume_f - 2:.3f}')")"
  local t_resume; t_resume="$(date +%s)"
  log "vr12s: epochs — t0=$t0 spanning=${span_scen:-none} t_resume=$t_resume_f"
  # r4 GRACE WINDOW — WIRE-GRADED, FULL WINDOW, NO EARLY BREAK
  # (r3's poll broke on its first DOM read — a reading that is
  # temporally incapable of being a claim, since the reconciler
  # fires at the earliest ~resume+6s, and DOM-confounded besides;
  # VR12R_CELL_V016 SS2/SS3). The poll now runs the FULL 14 s
  # across the 3 s grace and grades on wire markers only:
  #   claimed = a claim-delivery marker inside the window (the
  #     spanning connect is the only live bridge request, so any
  #     in-window claim-delivery targets it), OR the spanning
  #     scenario's wire signature breaking (disconnect with no
  #     preceding receipt / wallet-side decline).
  #   never-claimed = neither marker across the whole window AND
  #     the scenario still live at window end — a positive wire
  #     observation, not a DOM absence.
  # DOM state is dumped per poll as evidence and never gates.
  log "vr12s: Zert resumed with the connect still in flight; observing the FULL 14s grace window on wire markers (no early break)"
  local elapsed=0 pst="unknown"
  s_claimed="0"; s_claimed_at_s=""; s_claim_form=""
  while [ "$elapsed" -lt 14 ]; do
    if [ "$(fg_pkg)" = "$PKG" ] && dump_ui "$TMPD/s-poll.xml"; then
      cp "$TMPD/s-poll.xml" "$OUT/hier-s-poll-${elapsed}s.xml" || true
      pst="$(zert_state "$TMPD/s-poll.xml")"
    else
      pst="not-fg"
    fi
    local claim_now break_now
    claim_now="$(mq first 'ZertGoblinWallet: claim-delivery requestId=' "$t_resume_anchor")"
    break_now="$(zombie_death_epoch "$t_resume_anchor" "$s_pid_start" appside)"
    if [ "$s_claimed" != "1" ] && [ -n "$claim_now" ]; then
      s_claimed="1"; s_claim_form="claim-delivery"
      s_claimed_at_s="$(python3 -c "print(f'{${claim_now%% *} - $t_resume_f:.1f}')")"
      log "vr12s: CLAIM-DELIVERY marker inside the grace window at +${s_claimed_at_s}s post-resume — the spanning connect was claimed"
      mq lines 'ZertGoblinWallet: claim-delivery requestId=' "$t_resume_anchor" | head -n 2 | tee -a "$LANE_LOG" || true
    elif [ "$s_claimed" != "1" ] && [ -n "$break_now" ]; then
      s_claimed="1"; s_claim_form="wire-break"
      s_claimed_at_s="$(python3 -c "print(f'{$break_now - $t_resume_f:.1f}')")"
      log "vr12s: WIRE SIGNATURE BROKE inside the grace window at +${s_claimed_at_s}s post-resume — the spanning scenario died unreceipted"
    fi
    log "vr12s: grace poll ${elapsed}s: dom=$pst claimed=$s_claimed form=${s_claim_form:-none} (fg=$(fg_pkg))"
    sleep 2; elapsed=$(( $(date +%s) - t_resume ))
  done
  dump_ui "$OUT/hier-s-after-grace.xml" || true
  snap "shot-s-after-grace.png"
  capture_window "s-grace"
  if [ "$s_claimed" != "1" ]; then
    log "vr12s: grace window closed — NO claim marker and the spanning scenario's wire signature intact across the full window (never-claimed is a positive wire observation)"
  fi
  # Completion on its own terms: surface the still-unanswered sheet
  # and approve it (authorize, then Zert's sign-proof sheet).
  if ! bring_mock_forward; then
    s_completed="0"
    if [ "$s_claimed" = "1" ]; then s_cell="FAIL"; s_fail_step="reconciler-claim";
    else s_cell="FAIL"; s_fail_step="wallet-forward"; fi
    log "vr12s: FAIL step=$s_fail_step — sheet could not be surfaced for approval (claimed=$s_claimed form=${s_claim_form:-none})"
    return
  fi
  cp "$TMPD/mock-fwd.xml" "$OUT/hier-s-sheet-live.xml" || true
  snap "shot-s-sheet-live.png"
  local t_appr_f; t_appr_f="$(host_now)"
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
  # r4 consumption accounting (wire): did the shell consume the
  # approved authorize? authorize-completed (mock) + app-side
  # receipt + app-initiated close on a different tid within 3 s.
  local cons; cons="$(consumption_after "$t_appr_f" "$s_pid_start")"
  local c_authz c_receipt c_close c_r_epoch c_c_epoch
  read -r c_authz c_receipt c_close c_r_epoch c_c_epoch <<< "$cons"
  s_consumption="$c_authz/$c_receipt/$c_close"
  s_sign_sheets="$s_sheets"
  log "vr12s: consumption signature after approval: authorize-completed=$c_authz receipt=$c_receipt app-close=$c_close (receipt epoch=$c_r_epoch, close epoch=$c_c_epoch)"
  log "vr12s: completion end state=$est2 (sheets=$s_sheets approvals=$s_appr; claimed=$s_claimed form=${s_claim_form:-none} at=${s_claimed_at_s:-none}s; pid $s_pid_start -> $s_pid_end)"
  if [ "$est2" = "connected" ]; then s_completed="1"; else s_completed="0"; fi
  if [ "$s_pid_start" != "$s_pid_end" ] || [ -z "$s_pid_end" ]; then
    s_cell="FAIL"; s_fail_step="process"; log "vr12s: FAIL step=process — pid changed ($s_pid_start -> $s_pid_end)"; return
  fi
  if [ "$s_claimed" = "1" ]; then
    s_cell="FAIL"; s_fail_step="reconciler-claim"
    log "vr12s: FAIL step=reconciler-claim — the spanning resume's reconciler resolved a legitimate in-flight connect at +${s_claimed_at_s}s post-resume (form=$s_claim_form, grace 3s); completion_after_claim=$s_completed"
    return
  fi
  if [ "$s_completed" != "1" ]; then
    # Keep the prongs distinct: a consumption failure (the wire
    # signature incomplete — the paused-WebView delivery question)
    # is NOT a completion failure of the client's session flow,
    # and neither is a claim. Name exactly which markers were
    # present and which were absent.
    if [ "$s_consumption" != "1/1/1" ]; then
      s_cell="FAIL"; s_fail_step="completion-consumption"
      log "vr12s: FAIL step=completion-consumption — never claimed, approved, but the consumption signature is INCOMPLETE ($s_consumption = authorize/receipt/app-close): the connect's wire completion did not fully land in the client (end state=$est2). Prong kept distinct from reconciler-claim and from completion."
    else
      s_cell="FAIL"; s_fail_step="completion"
      log "vr12s: FAIL step=completion — never claimed and the wire consumption signature is COMPLETE (1/1/1), but the client's session flow never reached Connected in 60s (end state=$est2, sheets=$s_sheets approvals=$s_appr)"
    fi
    return
  fi
  s_cell="PASS"
  log "vr12s: PASS — the in-flight connect survived the spanning resume unclaimed (full grace window, wire-observed) and completed on its own terms (consumption=$s_consumption)"
}

start_stream
cell_vr12r
capture_window "final"
cell_vr12s
capture_window "s-final"
stop_stream

# --- verdict -----------------------------------------------------------------
if [ "$cell" = "PASS" ] && { [ "$fatal_pkg_total" -gt 0 ] || [ "$fatal_mock_total" -gt 0 ] || [ "$ise_total" -gt 0 ]; }; then
  cell="FAIL"; fail_step="crash-scan"
  log "vr12r: verdict poisoned by the crash scan (app_fatal=$fatal_pkg_total mock_fatal=$fatal_mock_total sender_ise=$ise_total)"
fi
{
  echo "cell=$cell"
  [ -n "$fail_step" ] && echo "fail_step=$fail_step"
  echo "driver=r5"
  echo "resolution_s=$resolution_s"
  echo "resolution_form=$resolution_form"
  echo "resolution_path=$resolution_path"
  echo "claim_gen=$claim_gen"
  echo "claim_delivery_offset_s=$claim_delivery_offset_s"
  echo "claim_exercised=$claim_exercised"
  echo "retry_budget_s=$retry_budget_s"
  echo "retry_scenarios=$retry_scenarios"
  echo "retry_attempts=$retry_attempts"
  echo "retry_sheet_attempt=$sheet_attempt"
  echo "zombie_death_offset_s=$zombie_death_offset_s"
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
  echo "leg_vr12s_claim_form=$s_claim_form"
  echo "leg_vr12s_consumption=$s_consumption"
  echo "leg_vr12s_sheets=$s_sign_sheets"
  echo "leg_vr12s_completed=$s_completed"
  echo "leg_vr12s_pid_start=$s_pid_start"
  echo "leg_vr12s_pid_end=$s_pid_end"
} > "$OUT/verdict.txt"
cat "$OUT/verdict.txt" | tee -a "$LANE_LOG"
log "vr12r: verdict written to $OUT/verdict.txt"
[ "$cell" = "PASS" ] && [ "$s_cell" = "PASS" ]
