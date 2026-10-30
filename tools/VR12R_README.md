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
5. **Resolution**: within 40 s the client must leave `Connecting…`
   — any failed-closed form counts (the abandonment access message
   *THE WALLET REQUEST WAS ABANDONED BEFORE IT FINISHED. TRY
   AGAIN.*, or a clean return to the disconnected lobby with no
   message — the form run 1 actually produced; the driver records
   the per-poll trajectory and which form occurred). Only
   Working-persistence — the vr12 hang — fails this step; the
   retry leg proceeds from any failed-closed resolution.
6. **Retry**: tap the connect control **once**, then an approval
   loop (HAUNT r6 form): approve every sheet the retry produces —
   the authorize sheet, then Zert's sign-proof sheet (its session
   flow signs a server nonce immediately after connect) — for up
   to **110 s** from the tap.
7. **PASS** requires, all in one process (app pid identical at
   start and end; the driver never force-stops the app): a sheet
   presented after the retry tap **and** ≥1 approval **and** the
   session state reached inside the 110 s budget. Any FAIL names
   its step (`lobby`, `first-sheet`, `resolution`, `retry-sheet`,
   `retry-approval`, `retry-connect`, `process`, `crash-scan`, …).

Windows, stated once: sheet waits 45 s (HAUNT parity); resolution
40 s (the reconciler's own grace is 3 s; the rest is render +
poll margin); retry budget **110 s** from the retry tap (HAUNT r6
parity — the same budget HAUNT's vr12r verdicts were graded
against). The association itself is expected to establish in the
~30 s class; the lane log's timestamps (`retry_to_connected_s` in
`verdict.txt`) let a reader grade that separately. On v0.1.5's
shape (no refire loop — the retry's single re-fired intent is the
whole attempt), a swallowed intent presents as: possibly the
zombie sheet surfacing and being approved to no effect, then no
Connected inside the budget (`fail_step=retry-connect` or
`retry-sheet`).

## The second leg — vr12s (reconciler scoping)

Added 2026-10-30 on main's relay (HAUNT v0.1.18 verdict). The
reconciler in the v0.1.16 shape arms at foreground time with no
background-time generation snapshot and no retry-generation
exemption, so a **legitimate** connect started in the foreground
that spans a later background→resume cycle can be claimed and
resolved as if abandoned. The leg: fresh state (`pm clear`; pid
continuity is asserted within the leg) → tap Connect → sheet in
flight → HOME → return to **Zert** while the sheet is still
unanswered → poll 14 s across the 3 s grace (the request must
stay `Connecting…` the whole window; any failed-closed form =
claimed, with the post-resume second recorded) → surface the
wallet task (am start on the singleTask sheet activity, stack
move-task, recents tap — in that order) → approve authorize +
sign → Connected within 60 s. **PASS requires both**: never
claimed AND completed on its own terms, same process. Verdict
lines are the `leg_vr12s_*` keys in `verdict.txt`.

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

## Observation surfaces — and their limits

- **Hierarchy dumps** (uiautomator). Zert's state is its WebView
  DOM: `Connecting…` (working), the abandonment access message
  (resolved-error), and — for the session state — the lobby
  banner `WALLET CONNECTED` with the launch button reading
  `Insert coin…` (r3; the DOM `Disconnect wallet` button is
  below the fold and not in the viewport accessibility tree —
  its presence is accepted as an alternative marker only).
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
  the driver cannot attribute it internally to the retry's
  association vs the zombie's — the same limit HAUNT's r6 driver
  carries, and the reason the loop approves whatever appears and
  grades only the terminal state.

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

Defaults already point at the sealed v0.1.5 artefact
(12965581620 / `f7bc4705…4800`). Evidence lands as the
`zert-vr12r-api<level>` artifact of the run: `verdict.txt`, the
timestamped lane log, hierarchy dumps + screenshots at every
decision point, and scanned logcat windows.

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
