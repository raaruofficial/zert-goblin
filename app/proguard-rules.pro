# Zert Goblin release ProGuard rules.
# Keep the MWA clientlib and the JS bridge (called by name from the WebView).
-keep class com.solana.mobilewalletadapter.clientlib.** { *; }
-keepclassmembers class com.zertgoblin.app.wallet.ZertGoblinWalletBridge {
    public *;
}
# The Application class is referenced from the manifest by name.
-keep class com.zertgoblin.app.ZertGoblinApp { *; }
-keep class com.zertgoblin.app.MainActivity { *; }
