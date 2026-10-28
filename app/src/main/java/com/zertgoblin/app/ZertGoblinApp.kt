package com.zertgoblin.app

import android.app.Application
import com.zertgoblin.app.wallet.WalletManager

/**
 * Application holder for app-scoped singletons.
 * The [WalletManager] lives here so the wallet session survives
 * configuration changes.
 */
class ZertGoblinApp : Application() {
    val walletManager: WalletManager by lazy { WalletManager() }
}
