package com.zertgoblin.app

import android.annotation.SuppressLint
import android.os.Bundle
import androidx.activity.ComponentActivity
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import com.zertgoblin.app.game.GameConfig
import com.zertgoblin.app.wallet.ZertGoblinWalletBridge

/**
 * The shell's only Activity: a full-screen WebView over the hosted
 * game, with the wallet bridge attached. Everything game-shaped is
 * the hosted client's; everything wallet-shaped is native (Mobile
 * Wallet Adapter against the Seeker's Seed Vault wallet).
 */
class MainActivity : ComponentActivity() {

    /**
     * The Activity's single MWA sender, created first thing in
     * onCreate — before the bridge exists (Paper Moon v0.2.5 lesson:
     * an ActivityResultSender constructed at-or-after STARTED throws
     * IllegalStateException when its launcher registers; the bridge
     * only ever *uses* this one).
     */
    private lateinit var sender: ActivityResultSender
    private lateinit var webView: WebView
    private var errorPageShown = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        sender = ActivityResultSender(this)
        val app = application as ZertGoblinApp

        webView = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.loadWithOverviewMode = true
            settings.useWideViewPort = true
            // The game is a self-contained web app; no local file or
            // content access is ever needed.
            settings.allowFileAccess = false
            settings.allowContentAccess = false

            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView?, url: String?) {
                    super.onPageFinished(view, url)
                    // Fallback shim injection (the shim is idempotent):
                    // covers WebViews without document-start support.
                    view?.evaluateJavascript(ZertGoblinWalletBridge.SHIM_JS, null)
                }

                override fun shouldOverrideUrlLoading(
                    view: WebView?,
                    request: WebResourceRequest?
                ): Boolean {
                    // Keep web navigation inside the WebView; never
                    // hand http(s) off to a browser. Non-web schemes
                    // are refused outright.
                    val scheme = request?.url?.scheme ?: return true
                    return scheme != "https" && scheme != "http"
                }

                override fun onReceivedError(
                    view: WebView?,
                    request: WebResourceRequest?,
                    error: WebResourceError?
                ) {
                    super.onReceivedError(view, request, error)
                    if (request?.isForMainFrame == true && !errorPageShown) {
                        errorPageShown = true
                        view?.loadDataWithBaseURL(
                            GameConfig.GAME_URL,
                            ERROR_HTML,
                            "text/html",
                            "utf-8",
                            null
                        )
                    }
                }
            }

            val bridge = ZertGoblinWalletBridge(
                activity = this@MainActivity,
                walletManager = app.walletManager,
                sender = sender,
                evaluateJs = { js -> runOnUiThread { evaluateJavascript(js, null) } }
            )
            addJavascriptInterface(bridge, GameConfig.BRIDGE_NATIVE_NAME)

            // Define window.ZertGoblinWallet before any page script runs.
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                WebViewCompat.addDocumentStartJavaScript(
                    this,
                    ZertGoblinWalletBridge.SHIM_JS,
                    setOf("*")
                )
            }

            loadUrl(GameConfig.GAME_URL)
        }
        setContentView(webView)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
        } else {
            @Suppress("DEPRECATION")
            super.onBackPressed()
        }
    }

    override fun onPause() {
        if (::webView.isInitialized) webView.onPause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        if (::webView.isInitialized) webView.onResume()
    }

    override fun onDestroy() {
        if (::webView.isInitialized) webView.destroy()
        super.onDestroy()
    }

    private companion object {
        /** Shown when the hosted game cannot be reached (e.g. no
         *  network, or the host not yet deployed). Honest, minimal,
         *  and reloadable by relaunching the app. */
        const val ERROR_HTML: String = """<!doctype html>
            <html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              body { background:#050807; color:#d8e6dc; font-family:sans-serif;
                     display:flex; align-items:center; justify-content:center;
                     min-height:100vh; margin:0; text-align:center; }
              main { padding:2rem; max-width:26rem; }
              h1 { color:#7dd87d; font-size:1.3rem; }
              p { line-height:1.5; }
            </style></head><body><main>
              <h1>The cave is unreachable</h1>
              <p>Zert Goblin could not load the game. Check your connection
                 and relaunch the app. Your plays, credits, and skins live
                 on your wallet and are safe.</p>
            </main></body></html>"""
    }
}
