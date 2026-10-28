package com.zertgoblin.app.game

/**
 * The shell's single configuration seam.
 *
 * The game itself is hosted (the Bun host bundle: static client +
 * `/actions` server). The shell is deliberately thin: it loads
 * [GAME_URL] in a WebView and provides the wallet bridge.
 */
object GameConfig {

    /**
     * The hosted game's public URL: the DO spare droplet
     * (137.184.143.128) behind Caddy, under its own sslip.io vhost so
     * it never collides with Ore Kingdom's bare-hostname route.
     *
     * DEPLOY DEPENDENCY (flagged 2026-10-27): the host bundle is
     * deploy-READY but NOT yet deployed — the droplet deploy is
     * blocked on this VM's SSH egress reset (see
     * `~/workspace/zert-goblin/package/PACKAGE_STATUS.md`). Until the
     * Caddy vhost `zert.137-184-143-128.sslip.io` exists, this URL
     * does not resolve to the game. This constant is the one place
     * the target changes if the ruled hostname ever moves.
     */
    const val GAME_URL: String = "https://zert.137-184-143-128.sslip.io"

    /**
     * Native bridge interface name (`window.ZertGoblinWalletNative`).
     * The injected shim wraps it into the Promise-based
     * `window.ZertGoblinWallet` surface the game client speaks
     * (client/src/payments.ts: signTransaction / signMessage /
     * getPublicKey, each resolving plain values).
     */
    const val BRIDGE_NATIVE_NAME: String = "ZertGoblinWalletNative"

    // ------------------------------------------------------------------
    // Payment guard constants (UMBRA C-5, shell half).
    //
    // These mirror the game module's own constants (space
    // server/src/actions.ts + client/src/payments.ts). The shell
    // refuses any wallet handoff whose transaction pays anyone else,
    // in any other way — see wallet/PaymentGuard.kt.
    // ------------------------------------------------------------------

    /** Receiving wallet: raaru.skr. Every payment in the game ends here. */
    const val RECEIVING_WALLET: String = "FRShnxX7vi64gtBoA6JPmH9MBuVqtheEQaxA1D17wKdP"

    /**
     * The receiving wallet's USDC associated token account — the
     * derived ATA of [RECEIVING_WALLET] x [USDC_MINT]. Cross-checked
     * two ways at packaging time: the client's own
     * findAssociatedTokenAddress() derivation, and the host RUNBOOK
     * deploy gate 4 (the account the house pre-creates).
     */
    const val RECEIVING_USDC_ATA: String = "46ycEzJp89Cz93LzvqqLpXBTgGVEQtuSrgqeRAnkJ9C5"

    const val USDC_MINT: String = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

    const val SYSTEM_PROGRAM: String = "11111111111111111111111111111111"
    const val TOKEN_PROGRAM: String = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    const val ATA_PROGRAM: String = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
}
