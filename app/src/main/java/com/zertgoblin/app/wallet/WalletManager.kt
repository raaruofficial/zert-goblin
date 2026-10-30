package com.zertgoblin.app.wallet

import android.net.Uri
import android.os.SystemClock
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import com.solana.mobilewalletadapter.clientlib.ConnectionIdentity
import com.solana.mobilewalletadapter.clientlib.MobileWalletAdapter
import com.solana.mobilewalletadapter.clientlib.TransactionResult
import com.zertgoblin.app.util.Base58
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicInteger

/**
 * UI-facing wallet state.
 */
sealed interface WalletUiState {
    data object Disconnected : WalletUiState
    data object Working : WalletUiState
    data class Connected(val publicKeyBase58: String) : WalletUiState
    data class Error(val message: String) : WalletUiState
}

/**
 * Owns the Solana Mobile Wallet Adapter session.
 *
 * Uses the official `mobile-wallet-adapter-clientlib-ktx` (MWA 2.0):
 * - [MobileWalletAdapter.connect] for the connect/session flow
 * - [MobileWalletAdapter.transact] + `signMessagesDetached` for message signing
 * - [MobileWalletAdapter.transact] + `signAndSendTransactions` for payments
 *
 * Nothing here ever touches a private key — signing happens inside
 * the Seeker's Seed Vault wallet through Mobile Wallet Adapter.
 *
 * Session truth lives in [sessionPubkey], a stored field captured at
 * connect and cleared at disconnect (KFC-007): the UI state is
 * presentation only, and no restore path ever derives the session
 * from it. Every wallet operation runs under the KFC-008 backstop
 * (see [runWalletOperation]): clientlib's transact carries no
 * timeout of its own, so an abandoned approval would otherwise sit
 * in Working forever.
 *
 * v0.1.4 KFC-008 CORRECTION (HAUNT v0.1.16, commit 40582dc — its
 * §2.2 runtime verdict on v0.1.15, REPORT_V0115_WALLET, cell vr12
 * FAIL): the v0.1.3 reconciliation cancelled the pending Deferred
 * and let the state resolution happen behind `deferred.await()` in
 * the caller's coroutine. clientlib's connect/transact suspension
 * is NON-COOPERATIVE: cancelling the Deferred does not wake the
 * awaiter while the underlying call is parked, so the app sat in
 * Working past the grace window (the 120 s backstop still worked —
 * it fires on the awaiting caller — but two minutes is not a
 * foreground cure). The reconciler now resolves the UI state
 * DIRECTLY from session truth after the grace window,
 * generation-claimed (see [claimResolution]) so neither a wrapper's
 * late resolution nor a zombie operation's late writes/delivery
 * can overwrite it; the Deferred cancellation remains, as hygiene
 * only. The 120 s backstop is unchanged.
 *
 * v0.1.5 KFC-008 THIRD ELEMENT (the retry layer): HAUNT's pre-fire
 * check on its sealed v0.1.16 found a third layer beneath vr12 —
 * after an abandonment resolves and the user taps TRY AGAIN in the
 * same process, the retry's wallet association never binds: the
 * retry runs on the SAME long-lived adapter instance whose only
 * established MWA scenario is the abandoned (zombie) one, so its
 * result is generation-suppressed and the new association dies
 * (30+ s ECONNREFUSED); only a fresh process recovers. Zert's
 * v0.1.4 instance carried the identical precondition (one
 * immutable adapter, one construction site). The adapter is now
 * recreatable (see [resetWalletAdapter]): every interruption
 * resolution — the reconciler's claim, the backstop's claim, the
 * caller-abandonment claim — discards the interrupted operation's
 * adapter instance WITHOUT disconnect (the zombie scenario and
 * its local association server die with it) and installs a fresh
 * one, so an in-process retry associates against a clean
 * instance. Session continuity rides the manager-held
 * [sessionAuthToken] field, never the discarded instance (HAUNT's
 * v0.1.17 reset shape, implemented from main's specification —
 * HAUNT's own strike had not landed when this one was cut).
 */
class WalletManager {

    /**
     * v0.1.5: the adapter instance lives in a recreatable holder.
     * Pre-v0.1.5 this was a single immutable `val` constructed once
     * for the process lifetime — the structural precondition of the
     * KFC-008 retry-layer defect (see the class header): an
     * abandoned operation's MWA scenario stayed the only
     * established one in the instance, and an in-process retry
     * could never bind a new association. Interruption resolutions
     * now discard the instance and install a fresh one
     * ([resetWalletAdapter]). The ConnectionIdentity is identical
     * for every instance — same parameters, rebuilt by the factory.
     * @Volatile: written by whichever thread resolves an
     * interruption, read by operation threads.
     */
    @Volatile
    private var walletAdapter: MobileWalletAdapter = createWalletAdapter()

    /** Build a fresh adapter with this shell's ConnectionIdentity. */
    private fun createWalletAdapter(): MobileWalletAdapter =
        MobileWalletAdapter(
            connectionIdentity = ConnectionIdentity(
                identityUri = Uri.parse("https://raaruofficial.github.io/zert-goblin/"),
                iconUri = Uri.parse("favicon.ico"), // resolves against identityUri
                identityName = "Zert Goblin"
            )
        )

    private val _uiState = MutableStateFlow<WalletUiState>(WalletUiState.Disconnected)
    val uiState: StateFlow<WalletUiState> = _uiState.asStateFlow()

    /**
     * Session truth (KFC-007): the pubkey captured at connect time.
     * Set only on a successful connect, cleared only at disconnect.
     * Deliberately independent of [_uiState]: a transact overwrites
     * the UI state with Working, so any value derived from the UI
     * state at restore time reads the overwrite, not the session.
     */
    @Volatile
    private var sessionPubkey: String? = null

    /**
     * Session truth, second half (v0.1.5): the MWA auth token
     * captured from the serving adapter instance at successful
     * connect (and mirrored by the [persistedAuthToken] setter, so
     * an imported token is captured too). An adapter reset
     * ([resetWalletAdapter]) restores the fresh instance's token
     * from THIS field and never reads the discarded instance: for a
     * sign/pay interruption this is the live session's token, so
     * the session survives the swap; for a connect interruption in
     * the abandonment case it is null, because no connect ever
     * completed and no capture ever happened. Cleared at disconnect
     * with [sessionPubkey].
     */
    @Volatile
    private var sessionAuthToken: String? = null

    /**
     * The connected wallet's Base58 pubkey, from session truth —
     * never derived from the (presentation-only) UI state.
     */
    val publicKeyBase58: String?
        get() = sessionPubkey

    val isConnected: Boolean
        get() = _uiState.value is WalletUiState.Connected

    /**
     * Get/set the MWA auth token so it can be persisted across
     * restarts. v0.1.5: both directions operate on the CURRENT
     * adapter instance (a reset may have replaced it since the
     * token was captured), and the setter also mirrors the value
     * into [sessionAuthToken], keeping the captured-token field
     * consistent with the instance: a token imported here survives
     * a later adapter reset exactly as a connect-captured one does,
     * and a get after a reset returns the current instance's token.
     */
    var persistedAuthToken: String?
        get() = walletAdapter.authToken
        set(value) {
            walletAdapter.authToken = value
            sessionAuthToken = value
        }

    // -- KFC-008 backstop machinery ------------------------------------

    /** Wallet operations run as deferreds on this scope so a stranded
     *  one can be cancelled from outside the caller's coroutine (the
     *  foreground reconciliation below); the caller only ever awaits. */
    private val operationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val reconcileScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** The currently in-flight wallet operation, if any. Written by
     *  whichever thread runs the operation, read/cancelled from the
     *  main thread by [onForeground] — hence @Volatile. */
    @Volatile
    private var pendingOperation: Deferred<*>? = null

    @Volatile
    private var pendingOperationSinceMs: Long = 0L

    /** Which kind of operation is in flight — the reconciler's
     *  direct resolution differs by kind (connect → Error;
     *  sign/pay → restore from session truth). */
    private enum class PendingOperationKind { CONNECT, SIGN, PAY }

    @Volatile
    private var pendingKind: PendingOperationKind? = null

    /**
     * v0.1.4: operation generation + resolution claim (ported from
     * HAUNT v0.1.16). Every operation takes the next generation;
     * exactly one party — the wrapper on an interrupted path, or
     * the foreground reconciler — may claim a generation's state
     * resolution ([claimResolution]). A claimed (or superseded)
     * generation's late writes and late result delivery are
     * suppressed: the state has already been resolved by whoever
     * claimed it, and the caller parked behind clientlib's
     * non-cooperative suspension may not overwrite it when it
     * finally wakes.
     */
    private val generationCounter = AtomicInteger(0)

    @Volatile
    private var pendingGeneration: Int = 0

    @Volatile
    private var resolvedGeneration: Int = 0

    private val resolutionLock = Any()

    /** Claim generation [gen]'s state resolution. True exactly once per gen. */
    private fun claimResolution(gen: Int): Boolean = synchronized(resolutionLock) {
        if (resolvedGeneration == gen) false else {
            resolvedGeneration = gen
            true
        }
    }

    /**
     * True once generation [gen] has been resolved by someone else
     * (the reconciler's claim) or superseded by a newer operation:
     * the operation's late state writes and late success delivery
     * must be suppressed.
     */
    private fun isStaleGeneration(gen: Int): Boolean =
        resolvedGeneration == gen || pendingGeneration != gen

    /**
     * v0.1.4: resolve the UI state DIRECTLY for an interrupted
     * operation of [kind] — the write the reconciler performs
     * itself, never delegated to the parked caller (see the class
     * header). Connect has no session to restore to, so it lands
     * on the Error surface with [errorMessage]; sign/pay restore
     * from the stored session field (KFC-007).
     */
    private fun resolveInterruptedState(kind: PendingOperationKind, errorMessage: String) {
        when (kind) {
            PendingOperationKind.CONNECT ->
                _uiState.value = WalletUiState.Error(errorMessage)
            PendingOperationKind.SIGN, PendingOperationKind.PAY ->
                restoreConnectedState()
        }
    }

    /**
     * v0.1.5 KFC-008 third element: discard the interrupted
     * operation's adapter instance and install a fresh one. Called
     * from exactly the interruption-resolution points — wherever a
     * generation is claimed by anyone other than normal completion
     * (the reconciler's claim in [onForeground], the backstop's
     * claim and the caller-abandonment claim in
     * [runWalletOperation]) — and from nowhere else, so the reset
     * fires exactly once per claimed generation: whoever claims,
     * resets.
     *
     * The discarded instance is dropped WITHOUT calling disconnect
     * on it: its MWA scenario is the zombie the user just abandoned
     * — politely closing it is neither required nor desired; the
     * scenario and its local association server die with the
     * instance. The fresh instance's auth token is set from the
     * manager-held [sessionAuthToken] ONLY: after a sign/pay
     * interruption that is the live session's captured token, so
     * the session survives the swap (KFC-007 semantics); after a
     * connect interruption nothing is imported from whatever the
     * zombie instance may silently hold — in the abandonment case
     * the field is null, because no connect ever completed. Normal
     * completions never reach this function.
     */
    private fun resetWalletAdapter() {
        val fresh = createWalletAdapter()
        fresh.authToken = sessionAuthToken
        walletAdapter = fresh
    }

    /**
     * Runs one wallet operation under the KFC-008 backstop:
     *
     * - a hard timeout ([TRANSACT_TIMEOUT_MS]): clientlib's transact
     *   carries no timeout, so a wallet that walks away mid-approval
     *   would hold the caller in Working indefinitely. The timeout
     *   fires on THIS awaiting coroutine, so it bounds even a
     *   non-cooperatively parked operation; the wrapper claims the
     *   generation, resolves the state itself, and throws
     *   [WalletOperationTimeoutException] — the caller still
     *   receives its ordinary retryable failure (its own state
     *   writes are then generation-suppressed, see [failIfCurrent]);
     * - cancellation of the operation (the foreground reconciler's
     *   hygiene cancel, or this caller being cancelled): converted
     *   to [WalletOperationAbandonedException] when the REQUEST was
     *   cancelled — the awaiting coroutine itself is intact, the
     *   deferred's cancellation is not the caller's. When the
     *   CALLER was cancelled, the state is still resolved directly
     *   (the UI is never stranded in Working) and the cancellation
     *   propagates.
     *
     * v0.1.4: every interrupted path here CLAIMS the generation
     * before resolving ([claimResolution]) and resolves the state
     * directly ([resolveInterruptedState]) — resolution never
     * depends on waking a caller parked behind clientlib's
     * non-cooperative suspension. If the reconciler already claimed
     * this generation, the wrapper only delivers the failure; it
     * writes nothing.
     *
     * v0.1.5: a successful claim here also resets the wallet
     * adapter ([resetWalletAdapter]). The claim is the exact point
     * where this operation's association becomes a zombie; the
     * retry layer must not inherit it.
     */
    private suspend fun <T> runWalletOperation(
        kind: PendingOperationKind,
        gen: Int,
        block: suspend () -> T
    ): T {
        val deferred = operationScope.async { block() }
        pendingOperation = deferred
        pendingOperationSinceMs = SystemClock.elapsedRealtime()
        pendingKind = kind
        pendingGeneration = gen
        try {
            return withTimeoutOrNull(TRANSACT_TIMEOUT_MS) { deferred.await() }
                ?: run {
                    deferred.cancel()
                    if (claimResolution(gen)) {
                        resolveInterruptedState(kind, TIMEOUT_MESSAGE)
                        resetWalletAdapter()
                        throw WalletOperationTimeoutException()
                    }
                    // The reconciler already resolved this generation.
                    throw WalletOperationAbandonedException()
                }
        } catch (e: CancellationException) {
            // Distinguish BEFORE cancelling: was the REQUEST
            // cancelled underneath this await (reconciliation), or
            // was this CALLER cancelled (its scope went away)?
            val requestWasCancelled = deferred.isCancelled
            deferred.cancel()
            if (claimResolution(gen)) {
                resolveInterruptedState(kind, ABANDONED_MESSAGE)
                resetWalletAdapter()
            }
            if (requestWasCancelled) throw WalletOperationAbandonedException()
            throw e
        } finally {
            if (pendingOperation === deferred) {
                pendingOperation = null
                pendingOperationSinceMs = 0L
                pendingKind = null
            }
        }
    }

    /**
     * Foreground reconciliation (KFC-008), called from
     * MainActivity.onResume. If a wallet operation is still pending
     * after a foreground return, the wallet handoff was abandoned
     * (the user left the approval sheet and came back without it
     * resolving — the VR-12 choreography): after a short grace for a
     * just-delivered result to finish landing, the stranded
     * operation is judged abandoned.
     *
     * v0.1.4 (HAUNT v0.1.16 shape): the reconciler resolves the UI
     * state DIRECTLY from session truth — connect → the Error
     * surface (with the client's retry), sign/pay → restore from
     * the stored session field — claiming the operation's
     * generation first, so the parked caller's late resolution and
     * any zombie writes are suppressed when it eventually wakes
     * (at the latest, at the 120 s backstop). v0.1.3 cancelled the
     * Deferred and let resolution flow through the caller's await;
     * HAUNT's runtime verdict (vr12) proved that never wakes a
     * caller parked in clientlib's non-cooperative suspension.
     * The Deferred is still cancelled afterwards — hygiene, never
     * the mechanism. Nothing is left sitting in Working.
     *
     * v0.1.5: the claim also resets the wallet adapter
     * ([resetWalletAdapter]), so the user's in-process retry
     * (the Error surface's TRY AGAIN) associates against a fresh
     * instance — not the abandoned operation's zombie scenario,
     * which HAUNT's pre-fire check showed can never bind a retry
     * (the KFC-008 retry layer).
     */
    fun onForeground() {
        val deferred = pendingOperation ?: return
        if (pendingOperationSinceMs == 0L) return
        val gen = pendingGeneration
        val kind = pendingKind ?: return
        reconcileScope.launch {
            delay(FOREGROUND_RECONCILE_GRACE_MS)
            // Identity check: act only on the very operation that
            // was pending at foreground time, and only if it is
            // still stranded in Working.
            if (pendingOperation !== deferred || pendingGeneration != gen) return@launch
            if (_uiState.value !is WalletUiState.Working) return@launch
            if (claimResolution(gen)) {
                resolveInterruptedState(kind, ABANDONED_MESSAGE)
                resetWalletAdapter()
            }
            deferred.cancel()
            if (pendingOperation === deferred && pendingGeneration == gen) {
                pendingOperation = null
                pendingOperationSinceMs = 0L
                pendingKind = null
            }
        }
    }

    /**
     * Connect to a wallet. Launches the MWA association intent via
     * [sender] (the ActivityResultSender created once by MainActivity
     * in onCreate). Returns the wallet's Base58 public key on success.
     */
    suspend fun connect(sender: ActivityResultSender): Result<String> =
        withContext(Dispatchers.IO) {
            val gen = generationCounter.incrementAndGet()
            // v0.1.5: an operation runs against the adapter instance
            // current at ITS start. An interruption reset replaces
            // the holder for the NEXT operation; it never swaps the
            // instance under a live (or zombie-parked) one.
            val adapter = walletAdapter
            _uiState.value = WalletUiState.Working
            val result = runCatching {
                runWalletOperation(PendingOperationKind.CONNECT, gen) {
                    adapter.connect(sender)
                }
            }.getOrElse { e ->
                return@withContext failIfCurrent(gen, e.message ?: "Connection failed", e)
            }
            // v0.1.4 zombie suppression: this caller may have been
            // parked behind clientlib long after the reconciler (or
            // the wrapper's own interrupted path) already resolved
            // this generation — then its late result delivers
            // nothing and writes nothing.
            if (isStaleGeneration(gen)) {
                return@withContext Result.failure(WalletOperationAbandonedException())
            }
            when (result) {
                is TransactionResult.Success -> {
                    val pubkeyBytes = result.authResult.accounts.firstOrNull()?.publicKey
                    if (pubkeyBytes == null) {
                        failIfCurrent(gen, "Wallet returned no accounts")
                    } else {
                        val base58 = Base58.encode(pubkeyBytes)
                        // KFC-007: capture session truth into the
                        // stored field at connect time. Every later
                        // restore reads this field, never the UI state.
                        sessionPubkey = base58
                        // v0.1.5: capture the auth token from the
                        // serving instance into its stored field at
                        // the same moment. An adapter reset restores
                        // the session from this field — the discarded
                        // instance is never read.
                        sessionAuthToken = adapter.authToken
                        _uiState.value = WalletUiState.Connected(base58)
                        Result.success(base58)
                    }
                }
                is TransactionResult.NoWalletFound ->
                    failIfCurrent(gen, "No MWA-compatible wallet found on this device")
                is TransactionResult.Failure ->
                    failIfCurrent(gen, result.e.message ?: "Wallet connection failed", result.e)
            }
        }

    /**
     * Ask the wallet to sign an arbitrary message (the game client's
     * wallet-session proof and .skr label link both ride this).
     * Returns the Base58 signature.
     */
    suspend fun signMessage(sender: ActivityResultSender, message: String): Result<String> =
        withContext(Dispatchers.IO) {
            val gen = generationCounter.incrementAndGet()
            // v0.1.5: instance affinity, as in connect.
            val adapter = walletAdapter
            _uiState.value = WalletUiState.Working
            val result = runCatching {
                runWalletOperation(PendingOperationKind.SIGN, gen) {
                    adapter.transact(sender) { authResult ->
                        val account = authResult.accounts.first().publicKey
                        signMessagesDetached(
                            arrayOf(message.toByteArray(Charsets.UTF_8)),
                            arrayOf(account)
                        )
                    }
                }
            }.getOrElse { e ->
                restoreConnectedState()
                return@withContext Result.failure(e)
            }
            // v0.1.4 zombie suppression: a caller parked behind
            // clientlib past its generation's resolution delivers
            // nothing (see connect).
            if (isStaleGeneration(gen)) {
                return@withContext Result.failure(WalletOperationAbandonedException())
            }
            when (result) {
                is TransactionResult.Success -> {
                    val sig = result.payload?.messages
                        ?.firstOrNull()?.signatures?.firstOrNull()
                    restoreConnectedState()
                    if (sig != null) Result.success(Base58.encode(sig))
                    else Result.failure(IllegalStateException("Wallet returned an empty signature"))
                }
                is TransactionResult.NoWalletFound -> {
                    restoreConnectedState()
                    Result.failure(IllegalStateException("No MWA-compatible wallet found on this device"))
                }
                is TransactionResult.Failure -> {
                    restoreConnectedState()
                    Result.failure(result.e)
                }
            }
        }

    /**
     * Sign and send serialized legacy transactions via MWA 2.0
     * `signAndSendTransactions`. Returns the Base58 signatures.
     *
     * Callers MUST run PaymentGuard over the bytes first (the bridge
     * does): this method sends whatever it is handed.
     */
    suspend fun signAndSendTransactions(
        sender: ActivityResultSender,
        serializedTransactions: List<ByteArray>
    ): Result<List<String>> = withContext(Dispatchers.IO) {
        val gen = generationCounter.incrementAndGet()
        // v0.1.5: instance affinity, as in connect.
        val adapter = walletAdapter
        _uiState.value = WalletUiState.Working
        val result = runCatching {
            runWalletOperation(PendingOperationKind.PAY, gen) {
                adapter.transact(sender) {
                    signAndSendTransactions(serializedTransactions.toTypedArray())
                }
            }
        }.getOrElse { e ->
            restoreConnectedState()
            return@withContext Result.failure(e)
        }
        // v0.1.4 zombie suppression: a caller parked behind
        // clientlib past its generation's resolution delivers
        // nothing (see connect).
        if (isStaleGeneration(gen)) {
            return@withContext Result.failure(WalletOperationAbandonedException())
        }
        when (result) {
            is TransactionResult.Success -> {
                val signatures = result.payload?.signatures
                    ?.map { Base58.encode(it) }
                restoreConnectedState()
                if (!signatures.isNullOrEmpty()) Result.success(signatures)
                else Result.failure(IllegalStateException("Wallet returned no signatures"))
            }
            is TransactionResult.NoWalletFound -> {
                restoreConnectedState()
                Result.failure(IllegalStateException("No MWA-compatible wallet found on this device"))
            }
            is TransactionResult.Failure -> {
                restoreConnectedState()
                Result.failure(result.e)
            }
        }
    }

    /** Revoke the session; the next connect shows the approval dialog again. */
    suspend fun disconnect(sender: ActivityResultSender) {
        runCatching { walletAdapter.disconnect(sender) }
        // KFC-007: session truth dies with the session.
        sessionPubkey = null
        // v0.1.5: the captured token is the other half of session
        // truth; it dies here too. The adapter instance is NOT
        // recreated on this path: disconnect closes its scenario
        // politely through the adapter itself, so there is no
        // zombie to discard — resets belong to interruption
        // resolutions only, and recreating here would change
        // nothing observable beyond instance identity.
        sessionAuthToken = null
        _uiState.value = WalletUiState.Disconnected
    }

    private fun fail(message: String, cause: Throwable? = null): Result<String> {
        _uiState.value = WalletUiState.Error(message)
        return Result.failure(cause ?: IllegalStateException(message))
    }

    /**
     * v0.1.4: [fail], generation-guarded (ported from HAUNT
     * v0.1.16) — a connect whose generation has been resolved (the
     * reconciler or the wrapper's interrupted path already wrote
     * the state) or superseded by a newer operation returns its
     * failure WITHOUT writing the Error state over the state that
     * replaced it.
     */
    private fun failIfCurrent(gen: Int, message: String, cause: Throwable? = null): Result<String> {
        return if (isStaleGeneration(gen)) {
            Result.failure(cause ?: IllegalStateException(message))
        } else {
            fail(message, cause)
        }
    }

    /**
     * Restore the post-transact UI state from session truth
     * (KFC-007). The pre-cure form read [publicKeyBase58] back when
     * that getter derived from the UI state — which the transact
     * paths had already overwritten with Working — so every restore
     * landed on Disconnected although the MWA session was still
     * valid. The stored field is the only source now.
     */
    private fun restoreConnectedState() {
        val pk = sessionPubkey
        _uiState.value = if (pk != null) WalletUiState.Connected(pk) else WalletUiState.Disconnected
    }

    companion object {
        /** KFC-008 backstop: no wallet operation may sit in Working
         *  longer than this (clientlib transact carries no timeout). */
        const val TRANSACT_TIMEOUT_MS: Long = 120_000L

        /** Grace after a foreground return before a still-Working
         *  operation is judged abandoned. A completed wallet
         *  interaction delivers its result before onResume and the
         *  IO-side completion lands well inside this window; only a
         *  genuinely stranded operation is still Working after it. */
        const val FOREGROUND_RECONCILE_GRACE_MS: Long = 3_000L

        /** Error-state text when the backstop resolves an operation
         *  directly (v0.1.4); identical to
         *  [WalletOperationTimeoutException]'s message, so the state
         *  and the delivered failure read the same. */
        private const val TIMEOUT_MESSAGE =
            "The wallet did not respond — the request timed out. Try again."

        /** Error-state text when an abandoned operation is resolved
         *  directly (v0.1.4); identical to
         *  [WalletOperationAbandonedException]'s message. */
        private const val ABANDONED_MESSAGE =
            "The wallet request was abandoned before it finished. Try again."
    }
}

/** KFC-008: the wallet did not answer within the backstop window. */
private class WalletOperationTimeoutException :
    Exception("The wallet did not respond — the request timed out. Try again.")

/** KFC-008: the pending wallet operation was cancelled as abandoned
 *  by the foreground reconciliation. */
private class WalletOperationAbandonedException :
    Exception("The wallet request was abandoned before it finished. Try again.")
