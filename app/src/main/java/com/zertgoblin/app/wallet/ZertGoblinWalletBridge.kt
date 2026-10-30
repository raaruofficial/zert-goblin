package com.zertgoblin.app.wallet

import android.app.Activity
import android.util.Base64
import android.util.Log
import android.webkit.JavascriptInterface
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * The seam between the game (running in the WebView) and the native
 * Solana wallet. Exposed to JavaScript in two layers:
 *
 *  - the native interface, `window.ZertGoblinWalletNative` — this
 *    class. Estate calling convention: call with a unique requestId,
 *    get an ack back, receive the async result via
 *    `window.__zertGoblinWalletResolve(requestId, resultJson)`.
 *  - the injected shim ([SHIM_JS], document-start) wraps the native
 *    interface into the Promise surface the game client actually
 *    speaks — `window.ZertGoblinWallet` with
 *    `getPublicKey(): Promise<string|null>`,
 *    `signMessage(message): Promise<base58 signature>`, and
 *    `signTransaction(base64): Promise<base58 signature>`
 *    (client/src/payments.ts, ShellWalletBridge type).
 *
 * [sender] is the Activity's single MWA ActivityResultSender, created
 * by MainActivity in onCreate and injected — never constructed here.
 * (Paper Moon v0.2.5 lesson: a sender constructed after the Activity
 * is STARTED throws; the bridge is assembled after that point.)
 *
 * Every `@JavascriptInterface` method runs on a WebView background
 * thread; results are posted back via [evaluateJs]. Nothing here ever
 * touches a private key — signing happens inside the Seeker's Seed
 * Vault wallet through Mobile Wallet Adapter.
 *
 * v0.1.7 — exactly-one settlement + claim delivery
 * (BRIDGE_SETTLEMENT_AUDIT.md §4). Every async request is registered
 * in [settlements] at launch and bound to its WalletManager
 * operation generation the moment the manager assigns it
 * (`onOperationStarted`). [resolveOk], [resolveErr] and the
 * claim-delivery all race through the entry's single
 * [AtomicBoolean] gate, so exactly one `__zertGoblinWalletResolve`
 * is ever posted per requestId. When the foreground reconciler
 * claims a generation, [WalletManager.onOperationClaimed] fires and
 * the bridge immediately settles the matching in-flight request
 * with the identical abandoned failure the caller would eventually
 * have received when the parked wallet call unwound — delivered at
 * claim time instead of zombie time. (Before this cure, a claim
 * resolved the operation's STATE directly but produced no result
 * for the awaiting caller, so the JS promise sat pending until
 * zombie unwind or the 120 s backstop; the vr12r cell's retry tap
 * fell inside that window and never reached the manager at all.)
 * The late fold result after a claim-delivery is suppressed here,
 * bridge-side; the shim's unknown-id ignore remains as the second
 * line of defense. The bridge scope stays a standalone
 * [SupervisorJob] — deliberately NOT parented to the Activity: the
 * audit flags caller cancellation of a bridge coroutine as the one
 * path that could strand a promise, and keeping the scope
 * unparented keeps that path structurally unreachable.
 */
class ZertGoblinWalletBridge(
    private val activity: Activity,
    private val walletManager: WalletManager,
    private val sender: ActivityResultSender,
    private val evaluateJs: (script: String) -> Unit
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // ------------------------------------------------------------------
    // v0.1.7: exactly-one settlement registry + claim delivery
    // ------------------------------------------------------------------

    /**
     * One in-flight async request's settlement state. [settled] is
     * the single gate every delivery path races through;
     * [generation] is the WalletManager operation generation this
     * request is bound to (0 = not bound to a manager operation —
     * the getPublicKeyAsync session fast path, and signTransaction
     * before its guard verdict). Claim notifications match on the
     * generation, so an unbound entry can never be claim-delivered.
     */
    private class Settlement {
        val settled = AtomicBoolean(false)

        @Volatile
        var generation: Int = 0
    }

    private val settlements = ConcurrentHashMap<String, Settlement>()

    /**
     * The claim hook this bridge registers on the (app-scoped)
     * manager. Held in a property so [release] can clear exactly
     * this bridge's registration — never a successor bridge's.
     */
    private val claimHook: (Int) -> Unit = { gen -> deliverClaim(gen) }

    init {
        walletManager.onOperationClaimed = claimHook
    }

    /**
     * Clear this bridge's claim hook. Called from
     * MainActivity.onDestroy: the manager is app-scoped and
     * outlives bridges, and a claim delivered through a stale hook
     * would post into a destroyed WebView. The identity check
     * keeps a successor bridge's registration intact when an old
     * bridge is destroyed after the new one registered.
     */
    fun release() {
        if (walletManager.onOperationClaimed === claimHook) {
            walletManager.onOperationClaimed = null
        }
    }

    /** Register [requestId] as in-flight. Called at every async
     *  method's launch, before any settlement can be attempted. */
    private fun beginSettlement(requestId: String) {
        settlements[requestId] = Settlement()
    }

    /** Bind [requestId] to its manager operation generation (the
     *  manager's `onOperationStarted`, fired at generation
     *  assignment — before the operation can become pending, hence
     *  before any claim can target it). */
    private fun bindGeneration(requestId: String, gen: Int) {
        settlements[requestId]?.generation = gen
    }

    /**
     * The exactly-one gate: wins [requestId]'s settled flag.
     * Returns true exactly once per request — for whichever of
     * resolveOk / resolveErr / claim-delivery arrives first;
     * every later attempt is suppressed. The entry STAYS in the
     * map as a tombstone after settling: the late fold result
     * that follows a claim-delivery must find the flag already
     * won, or it would post a second time and lean on the shim's
     * unknown-id ignore — the audit's design suppresses it here,
     * bridge-side, and keeps the shim as the second line only.
     * (The map therefore holds one small entry per requestId for
     * the bridge's lifetime; requestIds are unique per call by
     * the shim's construction and wallet calls are user-paced, so
     * the bound is the session's call count.) A request with no
     * entry at all (a path that never registered) settles as
     * before, unguarded.
     */
    private fun claimSettlement(requestId: String): Boolean {
        val entry = settlements[requestId] ?: return true
        return entry.settled.compareAndSet(false, true)
    }

    /**
     * The claim delivery: the reconciler has claimed [gen]'s
     * resolution, so settle that generation's in-flight request
     * NOW with the identical abandoned failure its caller would
     * eventually have received at zombie unwind — the same value,
     * at claim time instead of zombie time. Runs on the
     * reconciler's Main-thread launch; [postResolve] hands the
     * script to the UI thread as every delivery does.
     */
    private fun deliverClaim(gen: Int) {
        if (gen == 0) return
        for ((requestId, entry) in settlements) {
            if (entry.generation != gen) continue
            if (claimSettlement(requestId)) {
                Log.d(
                    CLAIM_LOG_TAG,
                    "claim-delivery requestId=$requestId gen=$gen " +
                        "(abandoned failure delivered at claim time)"
                )
                val payload = JSONObject()
                    .put("ok", false)
                    .put("error", WalletManager.ABANDONED_MESSAGE)
                    .toString()
                postResolve(requestId, payload)
            }
        }
    }

    // ------------------------------------------------------------------
    // Synchronous getters (safe to call any time)
    // ------------------------------------------------------------------

    /** Bridge protocol version. The shim can feature-detect on this. */
    @JavascriptInterface
    fun getVersion(): String = "1"

    @JavascriptInterface
    fun isConnected(): Boolean = walletManager.isConnected

    /** Base58 wallet address, or "" when not connected. */
    @JavascriptInterface
    fun getPublicKey(): String = walletManager.publicKeyBase58 ?: ""

    // ------------------------------------------------------------------
    // Async operations (ack immediately, resolve via __zertGoblinWalletResolve)
    // ------------------------------------------------------------------

    /**
     * Resolve the wallet address the game should build for. Connects
     * first when no session exists yet (the client's session flow
     * reads the address, then asks for a nonce signature).
     * Resolves with `{ ok: true, data: { publicKey } }`.
     */
    @JavascriptInterface
    fun getPublicKeyAsync(requestId: String): String {
        val existing = walletManager.publicKeyBase58
        if (existing != null) {
            // Fast path: no manager operation, no generation — the
            // entry is never claim-deliverable and settles here.
            beginSettlement(requestId)
            scope.launch { resolveOk(requestId, JSONObject().put("publicKey", existing)) }
            return ack(requestId)
        }
        return connectWallet(requestId)
    }

    /** Start the native MWA connect flow. Resolves `{ publicKey }`. */
    @JavascriptInterface
    fun connectWallet(requestId: String): String {
        beginSettlement(requestId)
        scope.launch {
            walletManager.connect(sender) { gen -> bindGeneration(requestId, gen) }.fold(
                onSuccess = { pubkey ->
                    resolveOk(requestId, JSONObject().put("publicKey", pubkey))
                },
                onFailure = { e ->
                    resolveErr(requestId, e.message ?: "connect failed")
                }
            )
        }
        return ack(requestId)
    }

    /**
     * Ask the wallet to sign a message (the server-issued session
     * proof / .skr label proof). Resolves `{ signature }` (Base58) —
     * the exact value the game client forwards to the server, which
     * verifies it against the wallet's ed25519 key.
     */
    @JavascriptInterface
    fun signMessage(requestId: String, message: String): String {
        beginSettlement(requestId)
        scope.launch {
            walletManager.signMessage(sender, message) { gen -> bindGeneration(requestId, gen) }.fold(
                onSuccess = { sig ->
                    resolveOk(requestId, JSONObject().put("signature", sig))
                },
                onFailure = { e ->
                    resolveErr(requestId, e.message ?: "sign failed")
                }
            )
        }
        return ack(requestId)
    }

    /**
     * Sign and send a serialized payment transaction.
     *
     * UMBRA C-5, shell half: [PaymentGuard] decodes the bytes and
     * asserts the program set, the destination (receiving wallet /
     * its USDC account), and the encoded transfer amount against the
     * shell's own constants BEFORE the transaction is handed to the
     * wallet. A mismatch refuses the handoff —
     * `shell_assertion_failed: <detail>` — and MWA never sees the
     * transaction. Resolves `{ signature }` (Base58) on success,
     * which is what the game client submits to the server's verify
     * action.
     */
    @JavascriptInterface
    fun signTransaction(requestId: String, transactionBase64: String): String {
        beginSettlement(requestId)
        scope.launch {
            when (val verdict = PaymentGuard.assertPayment(transactionBase64, walletManager.publicKeyBase58)) {
                is PaymentGuard.Verdict.Refuse ->
                    resolveErr(requestId, "shell_assertion_failed: ${verdict.detail}")
                PaymentGuard.Verdict.Ok -> {
                    val bytes = try {
                        Base64.decode(transactionBase64, Base64.NO_WRAP)
                    } catch (e: Exception) {
                        resolveErr(requestId, "shell_assertion_failed: transaction is not valid base64")
                        return@launch
                    }
                    walletManager.signAndSendTransactions(sender, listOf(bytes)) { gen ->
                        bindGeneration(requestId, gen)
                    }.fold(
                        onSuccess = { signatures ->
                            val sig = signatures.firstOrNull()
                            if (sig != null) resolveOk(requestId, JSONObject().put("signature", sig))
                            else resolveErr(requestId, "wallet returned no signature")
                        },
                        onFailure = { e ->
                            resolveErr(requestId, e.message ?: "sign and send failed")
                        }
                    )
                }
            }
        }
        return ack(requestId)
    }

    // ------------------------------------------------------------------
    // Plumbing
    // ------------------------------------------------------------------

    private fun ack(requestId: String): String =
        JSONObject()
            .put("accepted", true)
            .put("requestId", requestId)
            .toString()

    private fun resolveOk(requestId: String, data: JSONObject) {
        // v0.1.7: exactly-one gate — a claim may already have
        // delivered this request's settlement (see [deliverClaim]).
        if (!claimSettlement(requestId)) return
        val payload = JSONObject().put("ok", true).put("data", data).toString()
        postResolve(requestId, payload)
    }

    private fun resolveErr(requestId: String, error: String) {
        // v0.1.7: exactly-one gate, as in [resolveOk].
        if (!claimSettlement(requestId)) return
        val payload = JSONObject().put("ok", false).put("error", error).toString()
        postResolve(requestId, payload)
    }

    private fun postResolve(requestId: String, resultJson: String) {
        // JSONObject.quote handles escaping; the page parses the string back.
        val script =
            "window.__zertGoblinWalletResolve && " +
                "window.__zertGoblinWalletResolve(${JSONObject.quote(requestId)}, ${JSONObject.quote(resultJson)});"
        evaluateJs(script)
    }

    companion object {
        /** v0.1.7: claim-delivery observability — the same tag the
         *  WalletManager refire loop logs under, so one logcat
         *  filter shows the claim, the delivery and the retry's
         *  attempts as one account (the runtime cell's wire
         *  markers). */
        private const val CLAIM_LOG_TAG = "ZertGoblinWallet"

        /**
         * The injected Promise shim. Document-start injected by
         * MainActivity (and re-injected on page finish as a fallback;
         * the `__shellShim` guard makes it idempotent). It defines
         * exactly the surface client/src/payments.ts consumes:
         * `signTransaction` resolves the plain Base58 signature
         * string, `signMessage` resolves the plain Base58 signature
         * string, `getPublicKey` resolves the address (connecting if
         * needed), and `publicKey` is maintained as a synchronous
         * property once known.
         */
        val SHIM_JS: String = """
            (function () {
              if (window.ZertGoblinWallet && window.ZertGoblinWallet.__shellShim) return;
              var nativeBridge = window.ZertGoblinWalletNative;
              if (!nativeBridge) return;
              var seq = 0;
              var pending = {};
              window.__zertGoblinWalletResolve = function (requestId, resultJson) {
                var entry = pending[requestId];
                if (!entry) return;
                delete pending[requestId];
                var result;
                try { result = JSON.parse(resultJson); } catch (e) {
                  entry.reject(new Error("The wallet bridge returned an unreadable result."));
                  return;
                }
                if (result && result.ok) {
                  var data = result.data || {};
                  if (data.publicKey) { bridge.publicKey = data.publicKey; }
                  entry.resolve(data);
                } else {
                  entry.reject(new Error((result && result.error) || "The wallet request failed."));
                }
              };
              function call(method, args) {
                return new Promise(function (resolve, reject) {
                  var requestId = "zert-" + (++seq) + "-" + Date.now();
                  pending[requestId] = { resolve: resolve, reject: reject };
                  try {
                    nativeBridge[method].apply(nativeBridge, [requestId].concat(args || []));
                  } catch (e) {
                    delete pending[requestId];
                    reject(e);
                  }
                });
              }
              var bridge = {
                __shellShim: true,
                publicKey: null,
                getPublicKey: function () {
                  return call("getPublicKeyAsync", []).then(function (data) {
                    return data && data.publicKey ? data.publicKey : null;
                  });
                },
                connect: function () { return call("connectWallet", []); },
                signMessage: function (message) {
                  return call("signMessage", [message]).then(function (data) {
                    return data && data.signature ? data.signature : data;
                  });
                },
                signTransaction: function (serializedBase64) {
                  return call("signTransaction", [serializedBase64]).then(function (data) {
                    return data && data.signature ? data.signature : data;
                  });
                }
              };
              try {
                var existing = nativeBridge.getPublicKey();
                if (existing) bridge.publicKey = existing;
              } catch (e) { /* not connected yet */ }
              window.ZertGoblinWallet = bridge;
            })();
        """.trimIndent()
    }
}
