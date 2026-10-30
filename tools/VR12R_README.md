# vr12r cell — the KFC-008 retry-leg runtime instrument

**What it grades.** After a wallet approval is abandoned mid-sheet
and the app resolves the interruption (KFC-008 elements 1–2), can
the user tap the connect control **once** and actually get
connected — new wallet sheet, approval, session — **in the same
process**? That is HAUNT's vr12r leg, ported to Zert. It exists
because HAUNT's v0.1.17 runtime verdict disproved the JVM-level
evidence for this leg: the operative failure mechanism is the
wallet's single-task intent handler swallowing the retry's
association intent while the zombie sheet is still in flight — a
layer below any clientlib boundary a JVM fake can model. Only a
runtime cell against the real Mock MWA Wallet grades it.

**Lineage.** VOIDRUNNER's vendor recipe (REPORT_V107) → HAUNT's
§2.2 verdict lane (`tools/verify-v0113-wallet.sh`, driver r5/r6,
`.github/actions/wallet-suite`) → this port. Same pinned Mock MWA
Wallet (`solana-mobile/mock-mwa-wallet` @
`d444aff0c72dadd0f5c442ea2bc3559b62916e01`, package
`com.solana.mwallet`), same KVM lane, same PIN-lock discipline
(PIN 1234), same crash-scan rule. The mock is built from source on
every run with an imported **throwaway** key (repo secret
`MOCK_WALLET_PRIVATE_KEY`; pubkey anchor
`FnAA1CURUQevWmasFAjEMXWLGbq9dnEqSysg8Ho9Z2nH`, never funded,
devnet/test identity only).

## The cell (driver: `tools/verify-vr12r.sh`)

1. PIN-lock the AVD; enroll fingerprint best-effort; install the
   mock; open it and **Authenticate** (15-min window; the driver
   re-authenticates when the window is >8 min old). The driver
   asserts the mock's main screen shows `EXPECTED_PUBKEY`.
2. Install the target APK. Launch Zert; the lobby is the hosted
   client in the shell's WebView (needs network — GHA provides it).
3. Tap **Connect wallet** → the mock authorize sheet must present
   within 45 s.
4. **Abandon**: HOME, then return to the **Zert** task via recents
   without approving. Zert's `MainActivity.onResume` fires the
   foreground reconciler.
5. **Resolution** (r4: wire-graded): the reconciler's claim must
   DELIVER. Since v0.1.7 the claim settles the gen-1 JS request at
   claim time and logs `claim-delivery requestId=… gen=…` (tag
   `ZertGoblinWallet`); that marker landing inside the post-resume
   grace window (allowance 25 s: 3 s grace + the battery's
   3.0–3.2 s delivery anchor + skew margin) proves the step. If
   the zombie unwinds before the claim can fire, resolution is
   recorded as delivered-via-unwind (`resolution_path=unwind`,
   claim sub-criterion not exercised) and the leg proceeds.
   Absent both within 40 s → `fail_step=resolution-delivery`. The
   DOM trajectory is still dumped per poll as evidence; it never
   gates (the deployed lobby renders no in-flight state, so a DOM
   poll cannot discriminate a claim from a client-side reset —
   VR12R_CELL_V016 §3).
6. **Retry**: tap the connect control **once**, then an approval
   loop (HAUNT r6 form): approve every sheet the retry produces —
   the authorize sheet, then Zert's sign-proof sheet (its session
   flow signs a server nonce immediately after connect) — for up
   to **150 s** from the tap (r4 budget; derivation below).
7. **PASS** requires, all in one process (app pid identical at
   start and end; the driver never force-stops the app): the
   in-window claim-delivery (or the recorded unwind path) **and**
   a fresh association scenario on the wire after the tap
   (`retry-scenario`) **and** — on the claim path, where the
   claim arms the refire loop — ≥1 loop attempt line
   (`retry-attempt`) **and** a sheet presented after the tap
   **and** ≥1 approval **and** the session state reached inside
   the budget. Any FAIL names its step (`lobby`, `first-sheet`,
   `resolution-delivery`, `retry-scenario`, `retry-attempt`,
   `retry-sheet`, `retry-approval`, `retry-connect`, `process`,
   `crash-scan`, …).

Windows, stated once: sheet waits 45 s (HAUNT parity); resolution
40 s (the reconciler's own grace is 3 s; the claim allowance
inside it is 25 s); retry budget **150 s** from the retry tap —
r4 derives it from the loop's own arithmetic (3 attempts × 35 s
slots + 2 × 0.5 s refire gaps = 106 s worst case, plus ~44 s for
two approvals and the session flow), superseding r3's 110 s HAUNT
parity figure, which could bind against a working loop on
attempt 3. The association itself is expected to establish in
the ~30 s class; `verdict.txt` carries the per-attempt topology
(scenario epochs, attempt lines, zombie-death offset, which
attempt's sheet landed) so a reader can grade timing separately.
On v0.1.5's shape (no refire loop — the retry's single re-fired
intent is the whole attempt), a swallowed intent presents as:
possibly the zombie sheet surfacing and being approved to no
effect, then no Connected inside the budget
(`fail_step=retry-connect` or `retry-sheet`).

## The second leg — vr12s (reconciler scoping)

Added 2026-10-30 on main's relay (HAUNT v0.1.18 verdict). The
reconciler in the v0.1.16 shape arms at foreground time with no
background-time generation snapshot and no retry-generation
exemption, so a **legitimate** connect started in the foreground
that spans a later background→resume cycle can be claimed and
resolved as if abandoned. The leg: fresh state (`pm clear`; pid
continuity is asserted within the leg) → tap Connect → sheet in
flight → HOME → return to **Zert** while the sheet is still
unanswered → observe the FULL 14 s grace window (r4: **wire
markers, no early break** — claimed = an in-window
`claim-delivery` marker, which can only target the spanning
connect as the sole live bridge request, or the spanning
scenario's wire signature breaking; DOM polls are filed as
evidence only) → surface the wallet task (am start on the
singleTask sheet activity, stack move-task, recents tap — in
that order) → approve authorize + sign → consumption signature
on the wire + Connected within 60 s. **PASS requires both**:
never claimed AND completed on its own terms, same process.
Claim and consumption failures are distinct steps
(`reconciler-claim` vs `completion-consumption`/`completion`).
Verdict lines are the `leg_vr12s_*` keys in `verdict.txt`.

Run history note (driver r3): r1's resolution gate demanded the
access-message form and stopped before the retry; r2 recorded the
trajectory but its session detector required `Disconnect wallet`
in the dump — that button is below the fold and absent from the
viewport tree, so r2's run (41034285910) actually **completed**
the retry (both sheets approved, session reached) yet reported
`unknown`. r3's detector reads the live client's real connected
markers (`WALLET CONNECTED` banner / `Insert coin…` launch
button), the approval loop is wall-clock bounded and
foreground-directed, and the vr12s leg runs in the same suite.

Run history note (driver r4): the v0.1.6 run (41039724494)
proved the DOM detector cannot grade these legs on this client
at all — vr12s's "claimed at 0 s" was temporally impossible and
its own logcat showed the spanning connect completing unclaimed;
vr12r's resolution phase could not discriminate a shell claim
from a client-side attempt reset. r4 moves every grade to wire
markers (see below), keeps DOM for driving the cell and for the
final Connected criterion only, spans the full vr12s grace
window with no early break, raises the retry budget to 150 s
from the loop's arithmetic, and adds the claim-delivery
resolution gate the v0.1.7 bridge-settlement strike makes
observable. The r4 marker helpers were validated offline against
the v0.1.6 run's filed logcat before dispatch (consumption
signature, zombie-death epoch, and scenario epochs reproduce
that run's hand-read wire facts exactly, and the vr12s grace
query returns no false wire-break on its window).

## Observation surfaces — and their limits

- **Wire markers (primary since r4).** A continuous
  `adb logcat -v epoch` stream (`logcat-stream.txt` in the
  evidence) is queried at every decision point, so ring-buffer
  rotation no longer bounds the record. Scenario creation
  (`LocalAssociationScenario: Creating local association
  scenario`, app pid) = an attempt fired; the loop's attempt
  lines and the bridge's `claim-delivery` lines (tag
  `ZertGoblinWallet`) = the shell's own account of refires and
  claim settlements; mock-side authorize completion + app-side
  JSON-RPC receipt + app-initiated websocket close on a
  different tid within ~1–3 s = consumption; a scenario
  disconnect with no receipt in the preceding seconds, or the
  mock-side `authorization request declined`, = an unreceipted
  (zombie) death.
- **Hierarchy dumps** (uiautomator) drive the cell (taps, sheet
  presence via foreground package + controls) and carry the one
  remaining DOM grade: the session state — the lobby banner
  `WALLET CONNECTED` with the launch button reading
  `Insert coin…` (the DOM `Disconnect wallet` button is below
  the fold and not in the viewport accessibility tree — its
  presence is accepted as an alternative marker only). Every
  other DOM poll is filed evidence, never a gate.
- **The pubkey is never rendered by Zert's client.** The session
  grade is nonetheless key-bound: a session exists only after the
  MWA connect returned the mock key's pubkey, the mock signed the
  game server's nonce, and the server verified that ed25519
  signature against the address. The mock-side anchor is step 1's
  pubkey assertion on the mock's own screen.
- **Foreground package + sheet controls** for sheet presence
  (fg = `com.solana.mwallet` + Connect/Approve/Cancel in dump).
- **logcat windows**: any AndroidRuntime FATAL (either package)
  or an ActivityResultSender-signature IllegalStateException
  poisons the verdict (`crash-scan`), per HAUNT's scan rule.
- A sheet appearing after the retry tap is graded as *presented*;
  r4 attributes it to an attempt by timing (the latest scenario
  created before the sheet was first observed), but the driver
  cannot prove the attribution internally — a resurfaced zombie
  sheet would wear the same timing. The loop therefore approves
  whatever appears and the verdict rests on the terminal state
  plus the attempt/scenario accounting, the same posture as
  HAUNT's r6 driver.

**Scope.** The verdict binds to the Mock MWA Wallet's intent
handling: its `MobileWalletAdapterActivity` is `singleTask` in a
dedicated host task with **no `onNewIntent` override**, so a
second association intent arriving while a sheet is in flight is
dropped on the floor of the existing instance — the mock
therefore *can* reproduce the swallowing class. The Seed Vault
Wallet's handler may differ; a PASS or FAIL here grades the Mock
surface, exactly as main specified the instrument.

## Running it

**CI (the evidence route):**

```
gh workflow run zert-vr12r.yml -R raaruofficial/zert-goblin \
  -f apk_artifact_id=<artifact id holding the target release APK> \
  -f expected_sha256=<sha256 of that APK> \
  -f api_level=35
```

Defaults point at the sealed v0.1.7 artefact (12972776870 /
`f5543401…6d9`). Evidence lands as the `zert-vr12r-api<level>`
artifact of the run: `verdict.txt`, the timestamped lane log,
the continuous logcat stream, hierarchy dumps + screenshots at
every decision point, and scanned logcat windows.

**Locally** (driver only — needs a booted emulator/device on adb
with KVM or hardware acceleration to mean anything; this VM's
TCG-only emulation is not evidence):

```
ZERT_APK=/path/to/app-release.apk \
MOCK_APK=/path/to/mock-app-debug.apk \
EXPECTED_PUBKEY=FnAA1CURUQevWmasFAjEMXWLGbq9dnEqSysg8Ho9Z2nH \
VR12R_OUT=/tmp/vr12r-evidence \
bash tools/verify-vr12r.sh
```

**Mock APK by hand** (same as the CI action): clone
`solana-mobile/mock-mwa-wallet` @ `d444aff0…`, write
`local.properties` with `privateKey=<base58 32-byte seed>`,
`walletName=ZertTestWallet`, `sdk.dir=…`, then
`./gradlew :app:assembleDebug`.
