package com.toonami.tanuki

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val deepLinksChannelName = "tanuki/deep_links"
    private val remoteWebResolverChannelName = "tanuki/remote_web_resolver"
    private var deepLinksChannel: MethodChannel? = null
    private var remoteWebResolver: RemoteWebResolver? = null
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deepLinksChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deepLinksChannelName)
        deepLinksChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialLink" -> {
                    val link = pendingLink ?: intent?.dataString
                    pendingLink = null
                    result.success(link)
                }
                else -> result.notImplemented()
            }
        }
        remoteWebResolver = RemoteWebResolver(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            remoteWebResolverChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "resolveRemoteStream" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = call.arguments as? Map<String, Any?>
                    remoteWebResolver?.resolve(args.orEmpty(), result) ?: result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        dispatchDeepLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        dispatchDeepLink(intent)
    }

    private fun dispatchDeepLink(intent: Intent?) {
        val link = intent?.dataString ?: return
        pendingLink = link
        deepLinksChannel?.invokeMethod("link", link)
    }
}
