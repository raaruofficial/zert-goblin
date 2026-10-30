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
 */
class WalletManager {

    private val walletAdapter = MobileWalletAdapter(
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
     * The connected wallet's Base58 pubkey, from session truth —
     * never derived from the (presentation-only) UI state.
     */
    val publicKeyBase58: String?
        get() = sessionPubkey

    val isConnected: Boolean
        get() = _uiState.value is WalletUiState.Connected

    /** Get/set the MWA auth token so it can be persisted across restarts. */
    var persistedAuthToken: String?
        get() = walletAdapter.authToken
        set(value) {
            walletAdapter.authToken = value
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

    /**
     * Runs one wallet operation under the KFC-008 backstop:
     *
     * - a hard timeout ([TRANSACT_TIMEOUT_MS]): clientlib's transact
     *   carries no timeout, so a wallet that walks away mid-approval
     *   would hold the caller in Working indefinitely;
     * - cancellability by [onForeground]: if the operation is
     *   cancelled there, the await below surfaces it and it is
     *   converted to [WalletOperationAbandonedException].
     *
     * Both failure modes are thrown as ordinary exceptions and land
     * in the callers' existing failure handling — a stranded
     * operation always resolves its caller (the bridge promise
     * included) with a failure the user can retry, never a hang.
     */
    private suspend fun <T> runWalletOperation(block: suspend () -> T): T {
        val deferred = operationScope.async { block() }
        pendingOperation = deferred
        pendingOperationSinceMs = SystemClock.elapsedRealtime()
        try {
            return withTimeoutOrNull(TRANSACT_TIMEOUT_MS) { deferred.await() }
                ?: run {
                    deferred.cancel()
                    throw WalletOperationTimeoutException()
                }
        } catch (e: CancellationException) {
            // The deferred was cancelled (foreground reconciliation).
            // The awaiting coroutine itself is intact — the deferred's
            // cancellation is not the caller's — so converting it to
            // an abandonment failure is sound.
            deferred.cancel()
            throw WalletOperationAbandonedException()
        } finally {
            if (pendingOperation === deferred) {
                pendingOperation = null
                pendingOperationSinceMs = 0L
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
     * operation is cancelled. Its caller resolves as an abandonment
     * failure and restores the UI from session truth — Connected
     * when the session is live, the error surface (with the client's
     * retry) otherwise. Nothing is left sitting in Working.
     */
    fun onForeground() {
        val deferred = pendingOperation ?: return
        if (pendingOperationSinceMs == 0L) return
        reconcileScope.launch {
            delay(FOREGROUND_RECONCILE_GRACE_MS)
            if (pendingOperation === deferred &&
                _uiState.value is WalletUiState.Working
            ) {
                deferred.cancel()
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
            _uiState.value = WalletUiState.Working
            val result = runCatching {
                runWalletOperation { walletAdapter.connect(sender) }
            }.getOrElse { e ->
                return@withContext fail(e.message ?: "Connection failed", e)
            }
            when (result) {
                is TransactionResult.Success -> {
                    val pubkeyBytes = result.authResult.accounts.firstOrNull()?.publicKey
                    if (pubkeyBytes == null) {
                        fail("Wallet returned no accounts")
                    } else {
                        val base58 = Base58.encode(pubkeyBytes)
                        // KFC-007: capture session truth into the
                        // stored field at connect time. Every later
                        // restore reads this field, never the UI state.
                        sessionPubkey = base58
                        _uiState.value = WalletUiState.Connected(base58)
                        Result.success(base58)
                    }
                }
                is TransactionResult.NoWalletFound ->
                    fail("No MWA-compatible wallet found on this device")
                is TransactionResult.Failure ->
                    fail(result.e.message ?: "Wallet connection failed", result.e)
            }
        }

    /**
     * Ask the wallet to sign an arbitrary message (the game client's
     * wallet-session proof and .skr label link both ride this).
     * Returns the Base58 signature.
     */
    suspend fun signMessage(sender: ActivityResultSender, message: String): Result<String> =
        withContext(Dispatchers.IO) {
            _uiState.value = WalletUiState.Working
            val result = runCatching {
                runWalletOperation {
                    walletAdapter.transact(sender) { authResult ->
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
        _uiState.value = WalletUiState.Working
        val result = runCatching {
            runWalletOperation {
                walletAdapter.transact(sender) {
                    signAndSendTransactions(serializedTransactions.toTypedArray())
                }
            }
        }.getOrElse { e ->
            restoreConnectedState()
            return@withContext Result.failure(e)
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
        _uiState.value = WalletUiState.Disconnected
    }

    private fun fail(message: String, cause: Throwable? = null): Result<String> {
        _uiState.value = WalletUiState.Error(message)
        return Result.failure(cause ?: IllegalStateException(message))
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
    }
}

/** KFC-008: the wallet did not answer within the backstop window. */
private class WalletOperationTimeoutException :
    Exception("The wallet did not respond — the request timed out. Try again.")

/** KFC-008: the pending wallet operation was cancelled as abandoned
 *  by the foreground reconciliation. */
private class WalletOperationAbandonedException :
    Exception("The wallet request was abandoned before it finished. Try again.")
