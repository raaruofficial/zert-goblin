# Zert Goblin — Android shell

A thin WebView shell for the hosted Zert Goblin game, on the estate
pattern (cf. VOIDRUNNER / Paper Moon): the game renders in a WebView,
the wallet is native — Solana Mobile Wallet Adapter against the
Seeker's Seed Vault wallet.

- **Loads:** `GameConfig.GAME_URL` — the hosted game (Bun host bundle
  on the DO spare droplet behind Caddy). Deploy state and the ruled
  hostname live in `GameConfig.kt` and in
  `~/workspace/zert-goblin/package/PACKAGE_STATUS.md`.
- **Wallet bridge:** native interface `window.ZertGoblinWalletNative`
  (estate requestId/resolve convention) wrapped by a document-start
  injected shim into the Promise surface the game client speaks,
  `window.ZertGoblinWallet` — `getPublicKey()`, `signMessage()`,
  `signTransaction()` (client/src/payments.ts).
- **Payment guard (UMBRA C-5, shell half):** before any transaction
  reaches the wallet, `PaymentGuard` decodes it and asserts the
  program set, the destination (the game's receiving wallet / its
  USDC account), and the encoded transfer amount against the shell's
  own constants. Mismatches refuse the handoff; the wallet never
  sees them.
- **Package:** `com.zertgoblin.app` (applicationId + namespace in
  `app/build.gradle.kts` — the package-name decision is that one
  line).

## Builds

Local Gradle does not run on the estate VM (dead daemon, estate
record) — builds run in GitHub Actions (`.github/workflows/android.yml`):

- push to `main` / PR → unsigned debug APK artifact
- tag `v*` → signed release APK artifact

## Signing

Release signing comes only from repo secrets, filled from the estate
signing programme (values piped, never printed):

| Secret | Source |
|---|---|
| `KEYSTORE_BASE64` | base64 of `~/workspace/signing-programme/incoming/zert-goblin-release.jks` |
| `KEYSTORE_PASSWORD` | the programme password (shared estate value) |
| `KEY_ALIAS` | `zertgoblin` |
| `KEY_PASSWORD` | the programme password |

Keystore fingerprint anchor: `~/workspace/signing-programme/FINGERPRINTS.md`
(ZERT GOBLIN entry). The keystore itself is never committed (see
`.gitignore`).

## Website

`docs/` is the publisher website (GitHub Pages): the landing page plus
the hosted Privacy Policy and Terms of Service the store listing
links. The legal pages are rendered from the submission-kit drafts in
`~/workspace/zert-goblin/package/kit/` — edit there, re-render, commit.
