package com.toonami.tanuki

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

class TrailerPlayerActivity : Activity() {
    private data class QueueEntry(
        val title: String,
        val trailerUrl: String,
        val videoId: String,
        val detailUrl: String,
    )

    private val handler = Handler(Looper.getMainLooper())
    private val hideOverlayRunnable = Runnable { overlay.visibility = View.GONE }
    private val entries = mutableListOf<QueueEntry>()

    private lateinit var root: FrameLayout
    private lateinit var webView: WebView
    private lateinit var overlay: LinearLayout
    private lateinit var titleText: TextView
    private lateinit var statusText: TextView
    private lateinit var previousButton: ImageButton
    private lateinit var nextButton: ImageButton

    private var queueTitle = ""
    private var index = 0
    private var sessionId = ""
    private var endedSessionId = ""
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))

        queueTitle = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        entries += parseEntries(intent.getStringExtra(EXTRA_ENTRIES).orEmpty())
        if (entries.isEmpty()) {
            finish()
            return
        }

        root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }
        webView = buildWebView()
        overlay = buildOverlay()

        root.addView(
            webView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        root.addView(
            overlay,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            ),
        )
        setContentView(root)
        loadCurrentTrailer()
    }

    @SuppressLint("SetJavaScriptEnabled", "ClickableViewAccessibility")
    private fun buildWebView(): WebView {
        CookieManager.getInstance().setAcceptCookie(true)
        return WebView(this).apply {
            setBackgroundColor(Color.BLACK)
            keepScreenOn = true
            setOnTouchListener { _, _ ->
                showOverlay()
                false
            }
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                javaScriptCanOpenWindowsAutomatically = true
                mediaPlaybackRequiresUserGesture = false
                loadWithOverviewMode = true
                useWideViewPort = true
                cacheMode = WebSettings.LOAD_DEFAULT
                mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                userAgentString = TRAILER_USER_AGENT
            }
            addJavascriptInterface(TrailerBridge(), "AndroidTrailerPlayer")
            webChromeClient = object : WebChromeClient() {
                override fun onShowCustomView(
                    view: View?,
                    callback: CustomViewCallback?,
                ) {
                    if (view == null) {
                        callback?.onCustomViewHidden()
                        return
                    }
                    if (customView != null) {
                        callback?.onCustomViewHidden()
                        return
                    }
                    customView = view
                    customViewCallback = callback
                    webView.visibility = View.GONE
                    this@TrailerPlayerActivity.overlay.visibility = View.GONE
                    root.addView(
                        view,
                        FrameLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        ),
                    )
                }

                override fun onHideCustomView() {
                    hideCustomView()
                }
            }
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView?,
                    request: WebResourceRequest?,
                ): Boolean {
                    val host = request?.url?.host?.lowercase(Locale.ROOT).orEmpty()
                    return host.isNotBlank() &&
                        !host.endsWith("youtube.com") &&
                        !host.endsWith("youtube-nocookie.com") &&
                        !host.endsWith("googlevideo.com") &&
                        !host.endsWith("ytimg.com") &&
                        !host.endsWith("google.com") &&
                        !host.endsWith("gstatic.com")
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    updateStatus("Cargando reproductor...")
                }
            }
        }
    }

    private fun buildOverlay(): LinearLayout {
        val padding = dp(12)
        titleText = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
            maxLines = 1
        }
        statusText = TextView(this).apply {
            setTextColor(0xFFC6D1DE.toInt())
            textSize = 12f
            maxLines = 1
        }
        previousButton = overlayButton(
            R.drawable.ic_skip_previous_24,
            "Trailer anterior",
        ) { move(-1) }
        nextButton = overlayButton(
            R.drawable.ic_skip_next_24,
            "Trailer siguiente",
        ) { move(1) }
        val textColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(
                titleText,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
            addView(
                statusText,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(0x96000000.toInt())
            setPadding(padding, padding, padding, padding)
            addView(
                overlayButton(
                    R.drawable.ic_arrow_back_24,
                    "Volver",
                ) { finish() },
            )
            addView(spacer(10))
            addView(previousButton)
            addView(spacer(10))
            addView(nextButton)
            addView(
                textColumn,
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                    .apply { leftMargin = dp(12) },
            )
            addView(
                overlayButton(
                    R.drawable.ic_info_outline_24,
                    "Ver detalle",
                ) { openDetail() },
            )
        }
    }

    private fun overlayButton(iconRes: Int, description: String, onClick: () -> Unit): ImageButton {
        return ImageButton(this).apply {
            contentDescription = description
            setImageResource(iconRes)
            imageTintList = ColorStateList.valueOf(Color.WHITE)
            background = playerButtonBackground()
            scaleType = ImageView.ScaleType.CENTER
            isFocusable = true
            minimumWidth = dp(44)
            minimumHeight = dp(44)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            layoutParams = LinearLayout.LayoutParams(dp(44), dp(44))
            setOnClickListener {
                showOverlay()
                onClick()
            }
        }
    }

    private fun spacer(width: Int): View {
        return View(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(width), 1)
        }
    }

    private fun playerButtonBackground(): StateListDrawable {
        val focused = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(0xAA24384C.toInt())
            setStroke(dp(3), 0xFFFF8A2A.toInt())
        }
        val normal = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(0x66141D28)
        }
        return StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_focused), focused)
            addState(intArrayOf(android.R.attr.state_pressed), focused)
            addState(intArrayOf(), normal)
        }
    }

    private fun loadCurrentTrailer() {
        hideCustomView()
        handler.removeCallbacks(hideOverlayRunnable)
        endedSessionId = ""
        sessionId = "youtube-${System.nanoTime()}-$index"
        val entry = entries[index]
        titleText.text = entry.title.ifBlank { queueTitle.ifBlank { "Trailer" } }
        updateStatus("Cargando ${index + 1}/${entries.size}")
        updateNavigationButtons()
        overlay.visibility = View.VISIBLE
        runCatching { webView.stopLoading() }
        webView.loadDataWithBaseURL(
            "https://www.youtube-nocookie.com",
            buildYouTubeHtml(entry.videoId, sessionId),
            "text/html",
            "UTF-8",
            null,
        )
    }

    private fun move(delta: Int) {
        val next = (index + delta).coerceIn(0, entries.lastIndex)
        if (next == index) {
            showOverlay()
            return
        }
        index = next
        loadCurrentTrailer()
    }

    private fun playNextAfterEnded(session: String?) {
        if (session != sessionId || endedSessionId == sessionId) {
            return
        }
        endedSessionId = sessionId
        if (index < entries.lastIndex) {
            updateStatus("Siguiente trailer...")
            handler.postDelayed({
                if (!isFinishing && endedSessionId == sessionId) {
                    index += 1
                    loadCurrentTrailer()
                }
            }, 650L)
        } else {
            updateStatus("Cola terminada")
            showOverlay()
        }
    }

    private fun handlePlaybackError(session: String?, source: String?) {
        if (session != sessionId || endedSessionId == sessionId) {
            return
        }
        updateStatus("Error de YouTube${source?.takeIf { it.isNotBlank() }?.let { " $it" } ?: ""}")
        if (index < entries.lastIndex) {
            endedSessionId = sessionId
            handler.postDelayed({
                if (!isFinishing && endedSessionId == sessionId) {
                    index += 1
                    loadCurrentTrailer()
                }
            }, 1_200L)
        } else {
            showOverlay()
        }
    }

    private fun updateStatus(value: String) {
        statusText.text = "${index + 1}/${entries.size} | $value"
    }

    private fun updateNavigationButtons() {
        previousButton.isEnabled = index > 0
        previousButton.alpha = if (index > 0) 1f else 0.35f
        nextButton.isEnabled = index < entries.lastIndex
        nextButton.alpha = if (index < entries.lastIndex) 1f else 0.35f
    }

    private fun showOverlay() {
        overlay.visibility = View.VISIBLE
        handler.removeCallbacks(hideOverlayRunnable)
        handler.postDelayed(hideOverlayRunnable, 3_500L)
    }

    private fun hideCustomView() {
        val current = customView ?: return
        runCatching { root.removeView(current) }
        customView = null
        customViewCallback?.onCustomViewHidden()
        customViewCallback = null
        webView.visibility = View.VISIBLE
    }

    private fun openDetail() {
        val url = entries.getOrNull(index)?.detailUrl?.takeIf { it.isNotBlank() } ?: return
        runCatching {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .putExtra(MainActivity.EXTRA_INTERNAL_DEEP_LINK, url)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
            finish()
        }
    }

    override fun onBackPressed() {
        if (customView != null) {
            hideCustomView()
            return
        }
        super.onBackPressed()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        hideCustomView()
        runCatching { webView.stopLoading() }
        runCatching { webView.loadUrl("about:blank") }
        runCatching { webView.onPause() }
        runCatching { webView.pauseTimers() }
        runCatching { webView.destroy() }
        super.onDestroy()
    }

    private inner class TrailerBridge {
        @JavascriptInterface
        fun onReady(session: String?) {
            handler.post {
                if (session == sessionId && !isFinishing) {
                    updateStatus("Reproduciendo")
                    showOverlay()
                }
            }
        }

        @JavascriptInterface
        fun onEnded(session: String?) {
            handler.post {
                if (!isFinishing) {
                    playNextAfterEnded(session)
                }
            }
        }

        @JavascriptInterface
        fun onError(session: String?, source: String?) {
            handler.post {
                if (!isFinishing) {
                    handlePlaybackError(session, source)
                }
            }
        }
    }

    private fun buildYouTubeHtml(videoId: String, session: String): String {
        val safeVideoId = JSONObject.quote(videoId)
        val safeSession = JSONObject.quote(session)
        return """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
              <meta name="referrer" content="strict-origin-when-cross-origin">
              <style>
                html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #000; }
                #player { position: fixed; inset: 0; width: 100%; height: 100%; background: #000; }
                iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; background: #000; }
              </style>
              <script src="https://www.youtube.com/iframe_api" referrerpolicy="strict-origin-when-cross-origin"></script>
            </head>
            <body>
              <div id="player"></div>
              <script>
                const sessionId = $safeSession;
                let player = null;
                let endedSent = false;
                function notifyReady() {
                  try {
                    if (window.AndroidTrailerPlayer && AndroidTrailerPlayer.onReady) {
                      AndroidTrailerPlayer.onReady(sessionId);
                    }
                  } catch (error) {}
                }
                function notifyEnded() {
                  if (endedSent) return;
                  endedSent = true;
                  try {
                    if (window.AndroidTrailerPlayer && AndroidTrailerPlayer.onEnded) {
                      AndroidTrailerPlayer.onEnded(sessionId);
                    }
                  } catch (error) {}
                }
                function notifyError(source) {
                  try {
                    if (window.AndroidTrailerPlayer && AndroidTrailerPlayer.onError) {
                      AndroidTrailerPlayer.onError(sessionId, String(source || 'youtube'));
                    }
                  } catch (error) {}
                }
                function onYouTubeIframeAPIReady() {
                  player = new YT.Player('player', {
                    host: 'https://www.youtube-nocookie.com',
                    width: '100%',
                    height: '100%',
                    videoId: $safeVideoId,
                    playerVars: {
                      autoplay: 1,
                      controls: 1,
                      fs: 1,
                      rel: 0,
                      modestbranding: 1,
                      playsinline: 1,
                      iv_load_policy: 3,
                      origin: 'https://www.youtube-nocookie.com'
                    },
                    events: {
                      onReady: function(event) {
                        try { event.target.playVideo(); } catch (error) {}
                        notifyReady();
                      },
                      onStateChange: function(event) {
                        if (event.data === YT.PlayerState.ENDED) {
                          notifyEnded();
                        }
                      },
                      onError: function(event) {
                        notifyError(event && event.data ? event.data : 'youtube');
                      }
                    }
                  });
                  try {
                    const iframe = player.getIframe();
                    if (iframe) {
                      iframe.allow = 'autoplay; encrypted-media; fullscreen; picture-in-picture';
                      iframe.allowFullscreen = true;
                      iframe.referrerPolicy = 'strict-origin-when-cross-origin';
                    }
                  } catch (error) {}
                  setInterval(function() {
                    try {
                      if (!player || endedSent) return;
                      const duration = Number(player.getDuration && player.getDuration()) || 0;
                      const current = Number(player.getCurrentTime && player.getCurrentTime()) || 0;
                      const state = Number(player.getPlayerState && player.getPlayerState());
                      if (
                        duration > 2 &&
                        current > 1 &&
                        duration - current <= 1.1 &&
                        current / duration > 0.86 &&
                        (state === YT.PlayerState.PLAYING || state === YT.PlayerState.PAUSED || state === YT.PlayerState.BUFFERING)
                      ) {
                        notifyEnded();
                      }
                    } catch (error) {}
                  }, 1000);
                }
              </script>
            </body>
            </html>
        """.trimIndent()
    }

    private fun parseEntries(rawJson: String): List<QueueEntry> {
        val array = runCatching { JSONArray(rawJson) }.getOrNull() ?: return emptyList()
        val parsed = mutableListOf<QueueEntry>()
        for (i in 0 until array.length()) {
            val json = array.optJSONObject(i) ?: continue
            val title = json.optString("title").trim()
            val url = normalizeTrailerUrl(json.optString("trailerUrl"))
            val detailUrl = json.optString("detailUrl").trim()
            val videoId = extractYouTubeVideoId(url)
            if (url.isNotBlank() && videoId.isNotBlank()) {
                parsed += QueueEntry(
                    title = title,
                    trailerUrl = url,
                    videoId = videoId,
                    detailUrl = detailUrl,
                )
            }
        }
        return parsed
    }

    private fun normalizeTrailerUrl(value: String): String {
        val videoId = extractYouTubeVideoId(value)
        if (videoId.isBlank()) {
            return value.trim()
        }
        return "https://www.youtube.com/watch?v=$videoId"
    }

    private fun extractYouTubeVideoId(value: String): String {
        val uri = runCatching { Uri.parse(value.trim()) }.getOrNull() ?: return ""
        val host = uri.host?.lowercase(Locale.ROOT).orEmpty()
        val isYouTube = host == "youtube.com" ||
            host.endsWith(".youtube.com") ||
            host == "youtube-nocookie.com" ||
            host.endsWith(".youtube-nocookie.com") ||
            host == "youtu.be" ||
            host.endsWith(".youtu.be")
        if (!isYouTube) {
            return ""
        }
        val queryId = uri.getQueryParameter("v")
        if (isYouTubeVideoId(queryId)) {
            return queryId.orEmpty()
        }
        val segments = uri.pathSegments.orEmpty()
        if ((host == "youtu.be" || host.endsWith(".youtu.be")) && segments.isNotEmpty()) {
            val first = segments.first()
            if (isYouTubeVideoId(first)) {
                return first
            }
        }
        for (i in 0 until segments.lastIndex) {
            val marker = segments[i].lowercase(Locale.ROOT)
            val candidate = segments[i + 1]
            if ((marker == "embed" || marker == "shorts" || marker == "live") &&
                isYouTubeVideoId(candidate)
            ) {
                return candidate
            }
        }
        return ""
    }

    private fun isYouTubeVideoId(value: String?): Boolean {
        return value != null && Regex("^[0-9A-Za-z_-]{11}$").matches(value)
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    companion object {
        private const val EXTRA_TITLE = "com.toonami.tanuki.extra.TRAILER_TITLE"
        private const val EXTRA_ENTRIES = "com.toonami.tanuki.extra.TRAILER_ENTRIES"
        private const val TRAILER_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 12; Android TV) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"

        fun createIntent(context: Context, title: String, entriesJson: String): Intent {
            return Intent(context, TrailerPlayerActivity::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_ENTRIES, entriesJson)
        }
    }
}
