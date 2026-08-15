package com.toonami.tanuki

import android.content.Intent
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val deepLinksChannelName = "tanuki/deep_links"
    private val remoteWebResolverChannelName = "tanuki/remote_web_resolver"
    private val trailerPlayerChannelName = "tanuki/trailer_player"
    private val mediaCapabilitiesChannelName = "tanuki/media_capabilities"
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            trailerPlayerChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openTrailerQueue" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = call.arguments as? Map<String, Any?>
                    val title = readString(args?.get("title"))
                    @Suppress("UNCHECKED_CAST")
                    val entries = args?.get("entries") as? List<Map<String, Any?>>
                    val entriesJson = trailerEntriesJson(entries.orEmpty())
                    if (entriesJson.length() == 0) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    startActivity(
                        TrailerPlayerActivity.createIntent(
                            this,
                            title,
                            entriesJson.toString(),
                        ),
                    )
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            mediaCapabilitiesChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "androidMediaCapabilities" -> result.success(androidMediaCapabilities())
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
        val link = intent?.getStringExtra(EXTRA_INTERNAL_DEEP_LINK)?.takeIf { it.isNotBlank() }
            ?: intent?.dataString
            ?: return
        intent?.removeExtra(EXTRA_INTERNAL_DEEP_LINK)
        pendingLink = link
        deepLinksChannel?.invokeMethod("link", link)
    }

    private fun trailerEntriesJson(entries: List<Map<String, Any?>>): JSONArray {
        val array = JSONArray()
        entries.forEach { entry ->
            val title = readString(entry["title"])
            val trailerUrl = readString(entry["trailerUrl"])
            val detailUrl = readString(entry["detailUrl"])
            if (trailerUrl.isNotBlank()) {
                array.put(
                    JSONObject()
                        .put("title", title)
                        .put("trailerUrl", trailerUrl)
                        .put("detailUrl", detailUrl),
                )
            }
        }
        return array
    }

    private fun readString(value: Any?): String {
        return (value as? String)?.trim().orEmpty()
    }

    private fun androidMediaCapabilities(): Map<String, Any?> {
        val av1Decoders = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            .filter { codec ->
                !codec.isEncoder &&
                    codec.supportedTypes.any { type -> type.equals(AV1_MIME_TYPE, ignoreCase = true) }
            }
            .map { codec -> codecInfoMap(codec) }
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "hasHardwareAv1Decoder" to av1Decoders.any { it["hardwareAccelerated"] == true },
            "av1Decoders" to av1Decoders,
        )
    }

    private fun codecInfoMap(codec: MediaCodecInfo): Map<String, Any?> {
        val softwareOnly = isSoftwareOnly(codec)
        val hardwareAccelerated = isHardwareAccelerated(codec, softwareOnly)
        return mapOf(
            "name" to codec.name,
            "hardwareAccelerated" to hardwareAccelerated,
            "softwareOnly" to softwareOnly,
            "vendor" to isVendor(codec),
        )
    }

    private fun isHardwareAccelerated(codec: MediaCodecInfo, softwareOnly: Boolean): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return codec.isHardwareAccelerated
        }
        return !softwareOnly && !codec.name.lowercase().startsWith("omx.google.")
    }

    private fun isSoftwareOnly(codec: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return codec.isSoftwareOnly
        }
        val name = codec.name.lowercase()
        return name.startsWith("omx.google.") ||
            name.startsWith("c2.android.") ||
            name.startsWith("c2.google.") ||
            ".sw." in name ||
            "software" in name
    }

    private fun isVendor(codec: MediaCodecInfo): Boolean? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return codec.isVendor
        }
        return null
    }

    companion object {
        private const val AV1_MIME_TYPE = "video/av01"
        const val EXTRA_INTERNAL_DEEP_LINK = "com.toonami.tanuki.extra.INTERNAL_DEEP_LINK"
    }
}
