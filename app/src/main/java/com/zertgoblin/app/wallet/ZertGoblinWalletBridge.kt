package com.zertgoblin.app.wallet

import android.app.Activity
import android.util.Base64
import android.webkit.JavascriptInterface
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
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
 */
class ZertGoblinWalletBridge(
    private val activity: Activity,
    private val walletManager: WalletManager,
    private val sender: ActivityResultSender,
    private val evaluateJs: (script: String) -> Unit
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

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
            scope.launch { resolveOk(requestId, JSONObject().put("publicKey", existing)) }
            return ack(requestId)
        }
        return connectWallet(requestId)
    }

    /** Start the native MWA connect flow. Resolves `{ publicKey }`. */
    @JavascriptInterface
    fun connectWallet(requestId: String): String {
        scope.launch {
            walletManager.connect(sender).fold(
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
        scope.launch {
            walletManager.signMessage(sender, message).fold(
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
                    walletManager.signAndSendTransactions(sender, listOf(bytes)).fold(
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
        val payload = JSONObject().put("ok", true).put("data", data).toString()
        postResolve(requestId, payload)
    }

    private fun resolveErr(requestId: String, error: String) {
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
