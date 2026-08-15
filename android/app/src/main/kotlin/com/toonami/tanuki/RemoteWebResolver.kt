package com.toonami.tanuki

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
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
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class RemoteWebResolver(private val activity: Activity) {
    private val handler = Handler(Looper.getMainLooper())

    @SuppressLint("SetJavaScriptEnabled")
    fun resolve(args: Map<String, Any?>, result: MethodChannel.Result) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { resolve(args, result) }
            return
        }

        val provider = readString(args["provider"])
        val pageUrl = readString(args["pageUrl"])
        if (pageUrl.isBlank()) {
            Log.w(logTag, "resolveRemoteStream ignored: empty pageUrl")
            result.success(null)
            return
        }

        val referer = readString(args["referer"])
        val preferredServer = normalizeServer(readString(args["preferredServer"]))
        val excludedServers = readStringSet(args["excludedServers"])
            .map(::normalizeServer)
            .filter { it.isNotBlank() }
            .toSet()
        val timeoutMs = readLong(args["timeoutMs"]).coerceIn(8_000L, 45_000L)
        Log.d(
            logTag,
            "resolveRemoteStream start provider=$provider page=${shortUrl(pageUrl)} " +
                "referer=${shortUrl(referer)} preferredServer=$preferredServer " +
                "excluded=$excludedServers timeoutMs=$timeoutMs",
        )
        val currentPage = AtomicReference(pageUrl)
        val completed = AtomicBoolean(false)
        val userAgent = defaultUserAgent()
        var pendingCandidate: Map<String, Any?>? = null
        var pendingCandidateScore = Int.MIN_VALUE
        var pendingCandidateRunnable: Runnable? = null
        var lastAttemptedServer = ""
        val subtitleTracks = mutableListOf<Map<String, Any?>>()
        val subtitleTrackKeys = mutableSetOf<String>()

        val webView = try {
            WebView(activity)
        } catch (error: Throwable) {
            Log.w(logTag, "resolveRemoteStream failed creating WebView", error)
            result.success(null)
            return
        }

        lateinit var timeoutRunnable: Runnable

        fun cleanup() {
            runCatching { webView.stopLoading() }
            runCatching { webView.loadUrl("about:blank") }
            runCatching { webView.onPause() }
            runCatching { webView.pauseTimers() }
            runCatching { (webView.parent as? ViewGroup)?.removeView(webView) }
            runCatching { webView.destroy() }
        }

        fun finish(payload: Map<String, Any?>?) {
            if (!completed.compareAndSet(false, true)) {
                return
            }
            if (payload == null) {
                Log.d(logTag, "resolveRemoteStream finish: null")
            } else {
                Log.d(
                    logTag,
                    "resolveRemoteStream finish: kind=${payload["playbackKind"]} " +
                        "server=${payload["server"]} url=${shortUrl(readString(payload["playbackUrl"]))} " +
                        "page=${shortUrl(readString(payload["pageUrl"]))}",
                )
            }
            handler.removeCallbacks(timeoutRunnable)
            pendingCandidateRunnable?.let(handler::removeCallbacks)
            pendingCandidateRunnable = null
            pendingCandidate = null
            cleanup()
            result.success(payload)
        }

        fun schedulePendingCandidate() {
            pendingCandidateRunnable?.let(handler::removeCallbacks)
            val runnable = Runnable {
                finish(pendingCandidate)
            }
            pendingCandidateRunnable = runnable
            handler.postDelayed(runnable, candidateSettleDelayMs(provider))
        }

        fun addSubtitleTrack(
            rawUrl: String,
            rawLabel: String = "",
            rawLanguage: String = "",
            rawMimeType: String = "",
            rawKind: String = "",
            rawPageUrl: String = "",
            isDefault: Boolean = false,
        ) {
            val page = rawPageUrl.trim().ifBlank { currentPage.get() }.ifBlank { pageUrl }
            val subtitleUrl = resolveUrlMaybeRelative(rawUrl, page)
            if (subtitleUrl.isBlank() || isPlaybackLikeUrl(subtitleUrl)) {
                return
            }
            val mimeType = inferSubtitleMimeType(subtitleUrl, rawMimeType, rawKind)
            if (mimeType.isBlank()) {
                return
            }
            val label = rawLabel.trim().ifBlank { subtitleLabelFromUrl(subtitleUrl) }
            val language = normalizeSubtitleLanguage(rawLanguage, label)
            val key = "${subtitleUrl.lowercase(Locale.ROOT)}|${language.lowercase(Locale.ROOT)}|${label.lowercase(Locale.ROOT)}"
            if (!subtitleTrackKeys.add(key)) {
                return
            }
            subtitleTracks += mapOf(
                "url" to subtitleUrl,
                "label" to label.ifBlank { "Subtitulos" },
                "language" to language,
                "mimeType" to mimeType,
                "isDefault" to isDefault,
            )
            pendingCandidate?.let { current ->
                pendingCandidate = current + ("subtitleTracks" to subtitleTracks.toList())
                schedulePendingCandidate()
            }
            Log.d(
                logTag,
                "subtitle-track detected label=${label.ifBlank { "Subtitulos" }} " +
                    "language=$language url=${shortUrl(subtitleUrl)}",
            )
        }

        fun completeCandidate(rawUrl: String, rawKind: String = "", rawPageUrl: String = "", rawServer: String = "") {
            val page = rawPageUrl.trim().ifBlank { currentPage.get() }.ifBlank { pageUrl }
            val normalizedUrl = resolveUrlMaybeRelative(rawUrl, page)
            if (normalizedUrl.isBlank()) {
                return
            }
            val playbackUrl = normalizeZillaPlayUrl(normalizedUrl).ifBlank { normalizedUrl }
            val playbackKind = inferPlaybackKind(playbackUrl, rawKind)
            if (playbackKind.isBlank()) {
                Log.d(logTag, "candidate ignored: unsupported url=${shortUrl(playbackUrl)}")
                return
            }
            val server = normalizeServer(rawServer).ifBlank {
                normalizeServer(normalizedUrl).ifBlank { normalizeServer(page) }
            }
            if (server.isNotBlank() && excludedServers.contains(server)) {
                Log.d(logTag, "candidate ignored: excluded server=$server url=${shortUrl(playbackUrl)}")
                return
            }
            if (server.isNotBlank()) {
                lastAttemptedServer = server
            }
            val headers = buildPlaybackHeaders(
                playbackUrl = playbackUrl,
                referer = page,
                fallbackReferer = referer.ifBlank { pageUrl },
                userAgent = userAgent,
            )
            val payload = mapOf(
                "playbackUrl" to playbackUrl,
                "playbackKind" to playbackKind,
                "pageUrl" to page,
                "selectedMode" to "android-webview",
                "server" to server,
                "httpHeaders" to headers,
                "subtitleTracks" to subtitleTracks.toList(),
            )
            val score = candidateScore(
                provider = provider,
                playbackKind = playbackKind,
                server = server,
                preferredServer = preferredServer,
            )
            if (score < pendingCandidateScore && pendingCandidate != null) {
                Log.d(
                    logTag,
                    "candidate ignored: lower score=$score current=$pendingCandidateScore " +
                        "server=$server kind=$playbackKind url=${shortUrl(playbackUrl)}",
                )
                return
            }
            Log.d(
                logTag,
                "candidate accepted: score=$score kind=$playbackKind server=$server " +
                    "url=${shortUrl(playbackUrl)} page=${shortUrl(page)} headers=${headers.keys}",
            )
            pendingCandidate = payload
            pendingCandidateScore = score
            schedulePendingCandidate()
        }

        timeoutRunnable = Runnable {
            val failedServer = normalizeServer(lastAttemptedServer)
            Log.w(
                logTag,
                "resolveRemoteStream timeout page=${shortUrl(currentPage.get().ifBlank { pageUrl })} " +
                    "lastServer=$failedServer",
            )
            if (failedServer.isBlank()) {
                finish(null)
            } else {
                finish(
                    mapOf(
                        "playbackUrl" to "",
                        "playbackKind" to "",
                        "pageUrl" to currentPage.get().ifBlank { pageUrl },
                        "selectedMode" to "android-webview-timeout",
                        "server" to failedServer,
                        "failedServer" to failedServer,
                    ),
                )
            }
        }

        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)

        webView.layoutParams = FrameLayout.LayoutParams(1, 1)
        webView.visibility = View.INVISIBLE
        webView.setBackgroundColor(Color.BLACK)
        with(webView.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            loadWithOverviewMode = true
            useWideViewPort = true
            cacheMode = WebSettings.LOAD_DEFAULT
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            userAgentString = userAgent
        }

        webView.addJavascriptInterface(
            object {
                @JavascriptInterface
                fun onProbe(payload: String?) {
                    val text = payload?.trim().orEmpty()
                    if (text.isBlank()) {
                        return
                    }
                    handler.post {
                        if (completed.get()) {
                            return@post
                        }
                        val json = runCatching { JSONObject(text) }.getOrNull() ?: return@post
                        when (json.optString("type").trim()) {
                            "playback-candidate" -> completeCandidate(
                                rawUrl = json.optString("url"),
                                rawKind = json.optString("kind"),
                                rawPageUrl = json.optString("pageUrl"),
                                rawServer = json.optString("server"),
                            )
                            "subtitle-track" -> addSubtitleTrack(
                                rawUrl = json.optString("url"),
                                rawLabel = json.optString("label"),
                                rawLanguage = json.optString("language"),
                                rawMimeType = json.optString("mimeType"),
                                rawKind = json.optString("kind"),
                                rawPageUrl = json.optString("pageUrl"),
                                isDefault = json.optBoolean("isDefault"),
                            )
                            "host-attempt" -> {
                                val server = normalizeServer(json.optString("server"))
                                    .ifBlank { normalizeServer(json.optString("url")) }
                                if (server.isNotBlank()) {
                                    lastAttemptedServer = server
                                }
                            }
                        }
                    }
                }
            },
            "AndroidResolver",
        )

        fun injectAutomation() {
            if (completed.get()) {
                return
            }
            runCatching {
                webView.evaluateJavascript(
                    buildResolverScript(provider, preferredServer, excludedServers),
                    null,
                )
            }
        }

        webView.webChromeClient = object : WebChromeClient() {}
        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                currentPage.set(url?.trim().orEmpty().ifBlank { currentPage.get() })
                Log.d(logTag, "WebView page started ${shortUrl(currentPage.get())}")
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                currentPage.set(url?.trim().orEmpty().ifBlank { currentPage.get() })
                Log.d(logTag, "WebView page finished ${shortUrl(currentPage.get())}")
                injectAutomation()
                handler.postDelayed({ injectAutomation() }, 900L)
                handler.postDelayed({ injectAutomation() }, 2_200L)
            }

            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): android.webkit.WebResourceResponse? {
                val url = request?.url?.toString().orEmpty()
                if (url.isNotBlank() && isSubtitleLikeUrl(url)) {
                    Log.d(logTag, "intercept subtitle ${shortUrl(url)}")
                    handler.post {
                        addSubtitleTrack(
                            rawUrl = url,
                            rawMimeType = request?.requestHeaders?.get("Content-Type").orEmpty(),
                            rawKind = if (
                                url.contains("caption", ignoreCase = true) ||
                                url.contains("subtitle", ignoreCase = true)
                            ) {
                                "captions"
                            } else {
                                ""
                            },
                            rawPageUrl = currentPage.get(),
                        )
                    }
                }
                if (url.isNotBlank() && isPlaybackLikeUrl(url)) {
                    Log.d(logTag, "intercept playback ${shortUrl(url)}")
                    handler.post {
                        completeCandidate(
                            rawUrl = url,
                            rawKind = "",
                            rawPageUrl = currentPage.get(),
                        )
                    }
                }
                return super.shouldInterceptRequest(view, request)
            }
        }

        activity.addContentView(webView, FrameLayout.LayoutParams(1, 1))
        handler.postDelayed(timeoutRunnable, timeoutMs)

        val headers = linkedMapOf<String, String>()
        val normalizedReferer = referer.ifBlank { originFor(pageUrl) }
        if (normalizedReferer.isNotBlank()) {
            headers["Referer"] = normalizedReferer
            originFor(normalizedReferer).takeIf { it.isNotBlank() }?.let { headers["Origin"] = it }
        }

        webView.onResume()
        webView.resumeTimers()
        if (headers.isEmpty()) {
            Log.d(logTag, "WebView loadUrl ${shortUrl(pageUrl)}")
            webView.loadUrl(pageUrl)
        } else {
            Log.d(logTag, "WebView loadUrl ${shortUrl(pageUrl)} headers=${headers.keys}")
            webView.loadUrl(pageUrl, headers)
        }
    }

    private fun buildResolverScript(provider: String, preferredServer: String, excludedServers: Set<String>): String {
        val providerPayload = JSONObject.quote(provider)
        val preferredPayload = JSONObject.quote(preferredServer)
        val excludedPayload = JSONArray().apply {
            excludedServers.forEach { server -> put(server) }
        }.toString()
        return """
            (() => {
              const provider = $providerPayload;
              const preferredServer = $preferredPayload;
              const excludedServerValues = $excludedPayload;
              const clean = (value) => String(value || '').replace(/\s+/g, ' ').trim();
              const normalize = (value) => clean(value).toLowerCase()
                .normalize('NFD')
                .replace(/[\u0300-\u036f]/g, '')
                .replace(/[^a-z0-9]+/g, ' ')
                .replace(/\s+/g, ' ')
                .trim();
              function normalizeServer(value) {
                const text = normalize(value);
                if (!text) return '';
                if (text.includes('mixdrop') || text.includes('mix drop')) return 'mixdrop';
                if (text.includes('dood') || text.includes('dsvplay')) return 'doodstream';
                if (text.includes('streamtape') || text.includes('stape')) return 'streamtape';
                if (text.includes('streamwish') || text.includes('sfastwish') || text.includes('flaswish') || /\bwish\b/.test(text)) return 'streamwish';
                if (text.includes('vidhide') || text.includes('vid hide')) return 'vidhide';
                if (text.includes('yourupload') || text.includes('your upload')) return 'yourupload';
                if (text.includes('uqload')) return 'uqload';
                if (text.includes('mp4upload') || text.includes('mp4 upload')) return 'mp4upload';
                if (text.includes('hqq') || text.includes('netu')) return 'netu';
                if (text.includes('desu')) return 'desu';
                if (text.includes('magi')) return 'magi';
                if (text.includes('desuka')) return 'desuka';
                if (text.includes('mega')) return 'mega';
                if (/\bbonk\b/.test(text)) return 'bonk';
                if (/\bbee\b/.test(text)) return 'bee';
                if (/\bally\b/.test(text)) return 'ally';
                if (/\bkiwi\b/.test(text)) return 'kiwi';
                if (/\bmoo\b/.test(text)) return 'moo';
                if (/\bnun\b/.test(text)) return 'nun';
                if (/\bbun\b/.test(text)) return 'bun';
                if (/\btwin\b/.test(text)) return 'twin';
                if (/\bcog\b/.test(text)) return 'cog';
                if (/\bhop\b/.test(text)) return 'hop';
                if (/\bpewe\b/.test(text)) return 'pewe';
                if (/\btelli\b/.test(text)) return 'telli';
                return '';
              }
              const excludedServers = new Set(excludedServerValues.map((value) => normalizeServer(value)).filter(Boolean));
              const unique = (items) => [...new Set((items || []).filter(Boolean))];
              const toAbsoluteUrl = (value, baseUrl = location.href) => {
                const raw = String(value || '').trim();
                if (!raw || raw.startsWith('blob:') || raw.startsWith('data:') || raw === '#') return '';
                if (raw.startsWith('//')) return location.protocol + raw;
                try { return new URL(raw, baseUrl).toString(); } catch (_) { return ''; }
              };
              const isPlaybackLikeUrl = (value) => {
                const text = String(value || '').toLowerCase();
                return /\.(m3u8|mpd|mp4)(\?|${'$'})/i.test(text) ||
                  /\/m3u8\//i.test(text) ||
                  /streamtape\.com\/get_video/i.test(text) ||
                  (/hqq\.tv/i.test(text) && /stream=1/i.test(text));
              };
              const zillaHlsUrl = (value) => {
                const absolute = toAbsoluteUrl(value);
                const match = absolute.match(/player\.zilla-networks\.com\/play\/([a-f0-9]{32})/i);
                return match ? `https://player.zilla-networks.com/m3u8/${'$'}{match[1]}` : '';
              };
              const toPlayableUrl = (value) => {
                const zilla = zillaHlsUrl(value);
                return zilla || toAbsoluteUrl(value);
              };
              const supportedHostPattern = /streamwish|sfastwish|flaswish|mixdrop|dood|dsvplay|yourupload|uqload|mp4upload|streamtape|vidhide|hqq|netu|mega|desu|magi|desuka|bonk|bee|ally|kiwi|moo|nun|bun|twin|cog|hop|pewe|telli/i;
              const isExcludedHost = (url) => {
                const server = normalizeServer(url);
                return server && excludedServers.has(server);
              };
              const emitPlaybackCandidate = (url, source = 'probe', kind = '') => {
                const absolute = toPlayableUrl(url);
                if (!absolute || !isPlaybackLikeUrl(absolute) || isExcludedHost(absolute)) return false;
                const server = normalizeServer(absolute) || normalizeServer(location.href);
                sendProbe({
                  type: 'playback-candidate',
                  url: absolute,
                  source,
                  kind,
                  pageUrl: location.href,
                  server
                });
                return true;
              };
              const sendProbe = (payload) => {
                try {
                  if (window.AndroidResolver && typeof window.AndroidResolver.onProbe === 'function') {
                    window.AndroidResolver.onProbe(JSON.stringify(payload));
                  }
                } catch (_) {}
              };
              const emitHostAttempt = (url, server = '') => {
                const normalizedServer = normalizeServer(server) || normalizeServer(url);
                if (!normalizedServer || excludedServers.has(normalizedServer)) return false;
                sendProbe({
                  type: 'host-attempt',
                  url: String(url || ''),
                  server: normalizedServer,
                  pageUrl: location.href
                });
                return true;
              };
              const extractHttpUrls = (text, baseUrl = location.href) => {
                const html = String(text || '').replace(/\\\//g, '/');
                const matches = html.match(/(?:https?:\/\/|\/\/)[^"'\s<>]+/ig) || [];
                return unique(matches.map((value) => toAbsoluteUrl(value, baseUrl)).filter(Boolean));
              };
              const extractDirectUrls = (text, baseUrl = location.href) =>
                extractHttpUrls(text, baseUrl)
                  .map((value) => toPlayableUrl(value))
                  .filter((value) => isPlaybackLikeUrl(value));
              const isSubtitleLikeUrl = (value) => {
                const text = String(value || '').toLowerCase();
                return /\.(vtt|srt|ass|ssa|ttml|dfxp)(\?|${'$'})/i.test(text) ||
                  /caption|subtitle|\/subs?\//i.test(text);
              };
              const emitSubtitleTrack = (track, baseUrl = location.href) => {
                const rawUrl = track?.url || track?.src || track?.file || track?.trackUrl || track?.trackFile || '';
                const url = toAbsoluteUrl(rawUrl, baseUrl);
                if (!url || !isSubtitleLikeUrl(url)) return false;
                sendProbe({
                  type: 'subtitle-track',
                  url,
                  label: clean(track?.label || track?.name || track?.title || ''),
                  language: clean(track?.srclang || track?.language || track?.lang || ''),
                  mimeType: clean(track?.type || track?.mimeType || ''),
                  kind: clean(track?.kind || (/(caption|subtitle)/i.test(url) ? 'captions' : '')),
                  isDefault: Boolean(track?.default || track?.isDefault),
                  pageUrl: location.href
                });
                return true;
              };
              const emitSubtitleTracksFromText = (text, baseUrl = location.href) => {
                const html = String(text || '').replace(/\\\//g, '/');
                const matches = html.match(/(?:https?:\/\/|\/\/)[^"'\s<>]+?\.(?:vtt|srt|ass|ssa|ttml|dfxp)(?:\?[^"'\s<>]*)?/ig) || [];
                let emitted = false;
                unique(matches).forEach((url) => {
                  emitted = emitSubtitleTrack({ url }, baseUrl) || emitted;
                });
                return emitted;
              };
              const extractPlaybackUrlsFromValue = (value) => {
                const urls = [];
                const seen = new WeakSet();
                const visit = (item, baseUrl = location.href) => {
                  if (!item) return;
                  if (typeof item === 'string') {
                    urls.push(...extractDirectUrls(item, baseUrl));
                    return;
                  }
                  if (Array.isArray(item)) {
                    item.forEach((entry) => visit(entry, baseUrl));
                    return;
                  }
                  if (typeof item !== 'object') return;
                  if (seen.has(item)) return;
                  seen.add(item);
                  [
                    'file',
                    'src',
                    'url',
                    'currentSrc',
                    'playbackUrl',
                    'playback_url',
                    'manifest',
                    'playlist',
                    'sources',
                    'source'
                  ].forEach((key) => {
                    try { visit(item[key], baseUrl); } catch (_) {}
                  });
                };
                visit(value);
                return unique(urls);
              };
              const extractSubtitleTracksFromValue = (value, baseUrl = location.href) => {
                const seen = new WeakSet();
                const visit = (item) => {
                  if (!item) return;
                  if (typeof item === 'string') {
                    emitSubtitleTracksFromText(item, baseUrl);
                    return;
                  }
                  if (Array.isArray(item)) {
                    item.forEach(visit);
                    return;
                  }
                  if (typeof item !== 'object') return;
                  if (seen.has(item)) return;
                  seen.add(item);
                  emitSubtitleTrack(item, baseUrl);
                  [
                    'tracks',
                    'captions',
                    'subtitles',
                    'captionTracks',
                    'subtitleTracks',
                    'trackElements',
                    'textTracks'
                  ].forEach((key) => {
                    try { visit(item[key]); } catch (_) {}
                  });
                };
                visit(value);
              };
              const emitSubtitleTracksFromDom = () => {
                let emitted = false;
                document.querySelectorAll('track[src], [data-subtitle], [data-subtitles], [data-caption], [data-captions]').forEach((node) => {
                  const url = node.getAttribute?.('src') ||
                    node.getAttribute?.('data-subtitle') ||
                    node.getAttribute?.('data-subtitles') ||
                    node.getAttribute?.('data-caption') ||
                    node.getAttribute?.('data-captions') ||
                    '';
                  emitted = emitSubtitleTrack({
                    url,
                    label: node.getAttribute?.('label') || node.getAttribute?.('title') || '',
                    language: node.getAttribute?.('srclang') || node.getAttribute?.('lang') || '',
                    kind: node.getAttribute?.('kind') || '',
                    type: node.getAttribute?.('type') || '',
                    default: node.hasAttribute?.('default')
                  }) || emitted;
                });
                const html = String(document.documentElement?.outerHTML || '');
                return emitSubtitleTracksFromText(html, location.href) || emitted;
              };
              const extractHostUrls = (text, baseUrl = location.href) =>
                extractHttpUrls(text, baseUrl).filter((value) => supportedHostPattern.test(value) && !isExcludedHost(value));
              const hostScore = (url) => {
                const server = normalizeServer(url);
                let score = 100;
                if (server && server === preferredServer) score += 1000;
                if (provider === 'latanime') {
                  if (server === 'uqload') score += 700;
                  if (server === 'yourupload') score += 650;
                  if (server === 'doodstream') score += 600;
                  if (server === 'mp4upload') score += 550;
                  if (server === 'streamtape') score += 320;
                  if (server === 'netu') score += 300;
                  return score;
                }
                if (provider === 'animeav1') {
                  if (server === 'mp4upload') score += 760;
                  if (server === 'streamwish') score += 500;
                  if (server === 'mixdrop') score += 430;
                  if (server === 'doodstream') score += 390;
                  if (server === 'streamtape') score += 320;
                  if (server === 'netu') score += 300;
                  if (server === 'uqload') score += 180;
                  if (server === 'yourupload') score += 170;
                  return score;
                }
                if (server === 'streamwish') score += provider === 'jkanime' ? 500 : 180;
                if (server === 'mixdrop') score += 430;
                if (server === 'doodstream') score += 390;
                if (server === 'desu') score += 360;
                if (server === 'vidhide') score += 340;
                if (server === 'uqload') score += 180;
                if (server === 'yourupload') score += 170;
                if (server === 'mp4upload') score += 160;
                if (server === 'streamtape') score += 320;
                if (server === 'netu') score += 300;
                return score;
              };
              const navigateToHost = (urls) => {
                const target = unique(urls)
                  .filter((url) => url && !isExcludedHost(url))
                  .sort((left, right) => hostScore(right) - hostScore(left))[0] || '';
                if (!target) return false;
                const current = String(location.href || '').replace(/\/$/, '').toLowerCase();
                const next = target.replace(/\/$/, '').toLowerCase();
                if (current === next || window.__tanukiResolverNavigation === next) return false;
                window.__tanukiResolverNavigation = next;
                emitHostAttempt(target);
                try { location.href = target; return true; } catch (_) { return false; }
              };
              const inspectPayload = (text, baseUrl = location.href, source = 'probe') => {
                const direct = extractDirectUrls(text, baseUrl).find((url) => !isExcludedHost(url)) || '';
                if (direct && emitPlaybackCandidate(direct, source)) return true;
                return navigateToHost(extractHostUrls(text, baseUrl));
              };
              const installNetworkHooks = () => {
                if (window.__tanukiResolverHooksInstalled) return;
                window.__tanukiResolverHooksInstalled = true;
                const originalFetch = window.fetch;
                if (typeof originalFetch === 'function') {
                  window.fetch = function(...args) {
                    const requestUrl = toAbsoluteUrl(typeof args[0] === 'string' ? args[0] : args[0]?.url || '', location.href);
                    if (isPlaybackLikeUrl(requestUrl)) emitPlaybackCandidate(requestUrl, 'network');
                    const next = originalFetch.apply(this, args);
                    Promise.resolve(next).then((response) => {
                      try {
                        const responseUrl = response?.url || requestUrl || location.href;
                        if (isSubtitleLikeUrl(responseUrl)) emitSubtitleTrack({ url: responseUrl }, responseUrl);
                        if (isPlaybackLikeUrl(responseUrl)) emitPlaybackCandidate(responseUrl, 'network');
                        response.clone().text().then((body) => {
                          emitSubtitleTracksFromText(body, responseUrl);
                          inspectPayload(body, responseUrl, 'network');
                        }).catch(() => {});
                      } catch (_) {}
                    }).catch(() => {});
                    return next;
                  };
                }
                const originalOpen = XMLHttpRequest.prototype.open;
                const originalSend = XMLHttpRequest.prototype.send;
                XMLHttpRequest.prototype.open = function(method, url) {
                  this.__tanukiResolverUrl = toAbsoluteUrl(url, location.href);
                  return originalOpen.apply(this, arguments);
                };
                XMLHttpRequest.prototype.send = function() {
                  this.addEventListener('load', function() {
                    try {
                      const requestUrl = String(this.__tanukiResolverUrl || this.responseURL || '');
                      if (isSubtitleLikeUrl(requestUrl)) emitSubtitleTrack({ url: requestUrl }, requestUrl);
                      if (isPlaybackLikeUrl(requestUrl)) emitPlaybackCandidate(requestUrl, 'network');
                      emitSubtitleTracksFromText(String(this.responseText || ''), this.responseURL || requestUrl || location.href);
                      inspectPayload(String(this.responseText || ''), this.responseURL || requestUrl || location.href, 'network');
                    } catch (_) {}
                  });
                  return originalSend.apply(this, arguments);
                };
              };
              const emitVideoTagCandidate = () => {
                const video = document.querySelector('video');
                const candidates = [
                  video?.currentSrc,
                  video?.src,
                  ...[...document.querySelectorAll('video source[src], audio source[src]')].map((node) => node.getAttribute('src') || '')
                ];
                const best = candidates.map((value) => toAbsoluteUrl(value)).find((value) => isPlaybackLikeUrl(value));
                return best ? emitPlaybackCandidate(best, 'probe') : false;
              };
              const emitJwPlayerCandidate = () => {
                try {
                  if (typeof window.jwplayer !== 'function') return false;
                  const players = [];
                  [undefined, 'player', 'vplayer'].forEach((id) => {
                    try {
                      const player = id ? window.jwplayer(id) : window.jwplayer();
                      if (player && !players.includes(player)) players.push(player);
                    } catch (_) {}
                  });
                  const candidates = [];
                  players.forEach((player) => {
                    try {
                      const item = player?.getPlaylistItem?.();
                      extractSubtitleTracksFromValue(item);
                      candidates.push(...extractPlaybackUrlsFromValue(item));
                    } catch (_) {}
                    try {
                      const config = player?.getConfig?.();
                      extractSubtitleTracksFromValue(config);
                      candidates.push(...extractPlaybackUrlsFromValue(config));
                    } catch (_) {}
                    try {
                      const playlist = player?.getPlaylist?.();
                      extractSubtitleTracksFromValue(playlist);
                      candidates.push(...extractPlaybackUrlsFromValue(playlist));
                    } catch (_) {}
                  });
                  const best = unique(candidates).find((value) => isPlaybackLikeUrl(value) && !isExcludedHost(value)) || '';
                  if (best) return emitPlaybackCandidate(best, 'jwplayer');
                  return inspectPayload(JSON.stringify(candidates), location.href, 'jwplayer');
                } catch (_) {
                  return false;
                }
              };
              const emitStructuredPlayerCandidate = () => {
                const candidates = [];
                const collect = (value) => {
                  extractSubtitleTracksFromValue(value);
                  candidates.push(...extractPlaybackUrlsFromValue(value));
                };
                try {
                  if (window.dsplayer) {
                    collect(window.dsplayer);
                    try { collect(window.dsplayer.currentSource?.()); } catch (_) {}
                    try { collect(window.dsplayer.currentSources?.()); } catch (_) {}
                    try { collect(window.dsplayer.src?.()); } catch (_) {}
                  }
                } catch (_) {}
                try {
                  if (window.olplayer) {
                    collect(window.olplayer);
                    try { collect(window.olplayer.currentSource?.()); } catch (_) {}
                    try { collect(window.olplayer.currentSources?.()); } catch (_) {}
                    try { collect(window.olplayer.src?.()); } catch (_) {}
                  }
                } catch (_) {}
                try {
                  if (typeof window.videojs === 'function' && typeof window.videojs.getPlayers === 'function') {
                    Object.values(window.videojs.getPlayers() || {}).forEach((player) => {
                      collect(player);
                      try { collect(player.currentSource?.()); } catch (_) {}
                      try { collect(player.currentSources?.()); } catch (_) {}
                      try { collect(player.src?.()); } catch (_) {}
                    });
                  }
                } catch (_) {}
                const best = unique(candidates).find((value) => isPlaybackLikeUrl(value) && !isExcludedHost(value)) || '';
                return best ? emitPlaybackCandidate(best, 'structured-player') : false;
              };
              const clickLikelyPlayer = () => {
                [
                  '.jw-display-icon-container',
                  '.jw-icon-playback',
                  '.plyr__control',
                  '.vjs-big-play-button',
                  'button[aria-label*="play" i]',
                  'button[title*="play" i]',
                  '.play-btn',
                  '.play'
                ].some((selector) => {
                  const node = document.querySelector(selector);
                  if (!node) return false;
                  try { node.click(); return true; } catch (_) { return false; }
                });
                const video = document.querySelector('video');
                try { video?.play?.().catch(() => {}); } catch (_) {}
              };
              const clickPreferredServer = () => {
                const nodes = [
                  ...document.querySelectorAll('button, a, [role=button], .servers, .btn-show, .play-video, [data-player], [data-url], [data-video], [data-src], [data-iframe]')
                ];
                const candidates = nodes
                  .map((node) => {
                    const text = clean(node.textContent || node.getAttribute('title') || node.getAttribute('aria-label') || '');
                    const attrs = ['data-player', 'data-url', 'data-video', 'data-src', 'data-iframe', 'href', 'src']
                      .map((name) => node.getAttribute?.(name) || '')
                      .filter(Boolean);
                    const server = normalizeServer(text + ' ' + attrs.join(' '));
                    return { node, server, attrs };
                  })
                  .filter((item) => item.server && !excludedServers.has(item.server))
                  .sort((left, right) => {
                    const leftScore = Math.max(hostScore(left.server), ...left.attrs.map((value) => hostScore(value)));
                    const rightScore = Math.max(hostScore(right.server), ...right.attrs.map((value) => hostScore(value)));
                    return rightScore - leftScore;
                  });
                const target = candidates[0];
                if (!target) return false;
                const directAttr = target.attrs.map((value) => toAbsoluteUrl(value)).find((value) => supportedHostPattern.test(value));
                emitHostAttempt(directAttr || target.attrs.join(' ') || target.server, target.server);
                try {
                  if (target.node.dataset?.tanukiResolverClicked === '1') return false;
                  target.node.dataset.tanukiResolverClicked = '1';
                } catch (_) {}
                if (directAttr) return navigateToHost([directAttr]);
                try { target.node.click(); return true; } catch (_) { return false; }
              };
              const collectHostAttributes = () => {
                const attrs = [];
                document.querySelectorAll('iframe[src], embed[src], source[src], a[href], [data-player], [data-url], [data-video], [data-src], [data-iframe]').forEach((node) => {
                  ['src', 'href', 'data-player', 'data-url', 'data-video', 'data-src', 'data-iframe'].forEach((name) => {
                    const value = node.getAttribute?.(name) || '';
                    if (value) attrs.push(toAbsoluteUrl(value));
                  });
                });
                return unique(attrs).filter((value) => supportedHostPattern.test(value) && !isExcludedHost(value));
              };
              const run = () => {
                installNetworkHooks();
                emitSubtitleTracksFromDom();
                if (clickPreferredServer() && provider === 'animeav1') return true;
                clickLikelyPlayer();
                if (emitVideoTagCandidate() || emitJwPlayerCandidate() || emitStructuredPlayerCandidate()) return true;
                const html = String(document.documentElement?.outerHTML || '');
                if (inspectPayload(html, location.href)) return true;
                return navigateToHost(collectHostAttributes());
              };
              if (run()) return true;
              let tries = 0;
              const timer = setInterval(() => {
                tries += 1;
                if (run() || tries > 34) clearInterval(timer);
              }, 650);
              return true;
            })();
        """.trimIndent()
    }

    private fun buildPlaybackHeaders(
        playbackUrl: String,
        referer: String,
        fallbackReferer: String,
        userAgent: String,
    ): LinkedHashMap<String, String> {
        val headers = linkedMapOf<String, String>()
        headers["User-Agent"] = userAgent
        val resolvedReferer = referer.ifBlank { fallbackReferer }
        if (resolvedReferer.isNotBlank()) {
            headers["Referer"] = resolvedReferer
            originFor(resolvedReferer).takeIf { it.isNotBlank() }?.let { headers["Origin"] = it }
        }
        val cookie = CookieManager.getInstance().getCookie(playbackUrl)
            ?: CookieManager.getInstance().getCookie(resolvedReferer)
            ?: CookieManager.getInstance().getCookie(fallbackReferer)
        if (!cookie.isNullOrBlank()) {
            headers["Cookie"] = cookie
        }
        return headers
    }

    private fun defaultUserAgent(): String {
        return runCatching { WebSettings.getDefaultUserAgent(activity) }
            .getOrElse { defaultRemoteUserAgent }
            .ifBlank { defaultRemoteUserAgent }
    }

    private fun readString(value: Any?): String {
        return value?.toString()?.trim().orEmpty()
    }

    private fun readLong(value: Any?): Long {
        return when (value) {
            is Number -> value.toLong()
            else -> value?.toString()?.trim()?.toLongOrNull() ?: 25_000L
        }
    }

    private fun readStringSet(value: Any?): Set<String> {
        return when (value) {
            is Iterable<*> -> value.map(::readString).filter { it.isNotBlank() }.toSet()
            is Array<*> -> value.map(::readString).filter { it.isNotBlank() }.toSet()
            else -> emptySet()
        }
    }

    private fun resolveUrlMaybeRelative(value: String, baseUrl: String): String {
        val raw = value.trim()
        if (raw.isBlank() || raw.startsWith("blob:", ignoreCase = true) || raw.startsWith("data:", ignoreCase = true)) {
            return ""
        }
        if (raw.startsWith("//")) {
            val scheme = runCatching { URI(baseUrl).scheme }.getOrNull().orEmpty().ifBlank { "https" }
            return "$scheme:$raw"
        }
        return runCatching { URI(baseUrl).resolve(raw).toString() }.getOrDefault(raw)
    }

    private fun inferPlaybackKind(url: String, overrideKind: String = ""): String {
        val normalizedOverride = overrideKind.trim().lowercase(Locale.ROOT)
        if (normalizedOverride in setOf("hls", "dash", "mp4")) {
            return normalizedOverride
        }
        val lower = url.lowercase(Locale.ROOT)
        return when {
            hasMediaPathExtension(lower, "m3u8") || "/m3u8/" in lower -> "hls"
            hasMediaPathExtension(lower, "mpd") -> "dash"
            hasMediaPathExtension(lower, "mp4") ||
                "streamtape.com/get_video" in lower ||
                ("hqq.tv" in lower && "stream=1" in lower) -> "mp4"
            else -> ""
        }
    }

    private fun hasMediaPathExtension(url: String, extension: String): Boolean {
        val path = runCatching { Uri.parse(url).path.orEmpty() }
            .getOrDefault(url)
            .lowercase(Locale.ROOT)
        return path.endsWith(".$extension")
    }

    private fun normalizeZillaPlayUrl(url: String): String {
        val match = Regex(
            """player\.zilla-networks\.com/play/([a-f0-9]{32})""",
            RegexOption.IGNORE_CASE,
        ).find(url) ?: return ""
        return "https://player.zilla-networks.com/m3u8/${match.groupValues[1]}"
    }

    private fun isPlaybackLikeUrl(url: String): Boolean {
        return inferPlaybackKind(normalizeZillaPlayUrl(url).ifBlank { url }).isNotBlank()
    }

    private fun isSubtitleLikeUrl(url: String): Boolean {
        val lower = url.lowercase(Locale.ROOT)
        return inferSubtitleMimeType(url, "", "").isNotBlank() ||
            "caption" in lower ||
            "subtitle" in lower ||
            "/sub/" in lower ||
            "/subs/" in lower ||
            "/captions/" in lower
    }

    private fun inferSubtitleMimeType(url: String, rawType: String, rawKind: String): String {
        val normalizedType = rawType.trim().lowercase(Locale.ROOT)
        val normalizedUrl = url.trim().lowercase(Locale.ROOT)
        return when {
            "vtt" in normalizedType || ".vtt" in normalizedUrl -> "text/vtt"
            "subrip" in normalizedType || "srt" in normalizedType || ".srt" in normalizedUrl -> "application/x-subrip"
            "ttml" in normalizedType ||
                "dfxp" in normalizedType ||
                ".ttml" in normalizedUrl ||
                ".dfxp" in normalizedUrl -> "application/ttml+xml"
            "ssa" in normalizedType ||
                "ass" in normalizedType ||
                ".ssa" in normalizedUrl ||
                ".ass" in normalizedUrl -> "text/x-ssa"
            rawKind.equals("captions", ignoreCase = true) ||
                rawKind.equals("subtitles", ignoreCase = true) ||
                rawKind.equals("subtitle", ignoreCase = true) -> "text/vtt"
            else -> ""
        }
    }

    private fun subtitleLabelFromUrl(url: String): String {
        return runCatching {
            val uri = Uri.parse(url)
            uri.getQueryParameter("label")?.trim()?.takeIf { it.isNotBlank() }
                ?: uri.getQueryParameter("name")?.trim()?.takeIf { it.isNotBlank() }
                ?: uri.lastPathSegment
                    ?.substringBefore('?')
                    ?.substringAfterLast('/')
                    ?.substringBeforeLast('.')
                    ?.replace('-', ' ')
                    ?.replace('_', ' ')
                    ?.trim()
                    ?.takeIf { it.isNotBlank() }
        }.getOrNull().orEmpty().ifBlank { "Subtitulos" }
    }

    private fun normalizeSubtitleLanguage(rawLanguage: String, label: String): String {
        val normalized = rawLanguage.trim().lowercase(Locale.ROOT)
        if (normalized.isNotBlank()) {
            return when {
                normalized == "eng" -> "en"
                normalized == "spa" -> "es"
                normalized.startsWith("en") -> "en"
                normalized.startsWith("es") -> "es"
                else -> normalized
            }
        }
        val normalizedLabel = label.trim().lowercase(Locale.ROOT)
        return when {
            "english" in normalizedLabel || normalizedLabel == "en" -> "en"
            "spanish" in normalizedLabel ||
                "espanol" in normalizedLabel ||
                "espa\u00f1ol" in normalizedLabel ||
                normalizedLabel == "es" -> "es"
            else -> ""
        }
    }

    private fun candidateSettleDelayMs(provider: String): Long {
        return when (provider.trim().lowercase(Locale.ROOT)) {
            "latanime" -> latAnimeResolverCandidateSettleDelayMs
            else -> defaultCandidateSettleDelayMs
        }
    }

    private fun candidateScore(
        provider: String,
        playbackKind: String,
        server: String,
        preferredServer: String,
    ): Int {
        var score = when (playbackKind.trim().lowercase(Locale.ROOT)) {
            "hls" -> 300
            "dash" -> 250
            "mp4" -> 200
            else -> 0
        }
        val normalizedServer = normalizeServer(server)
        if (normalizedServer.isNotBlank() && normalizedServer == normalizeServer(preferredServer)) {
            score += 1_000
        }
        if (provider.trim().lowercase(Locale.ROOT) == "latanime") {
            score += when (normalizedServer) {
                "uqload" -> 700
                "yourupload" -> 650
                "doodstream" -> 600
                "mp4upload" -> 550
                "streamtape" -> 320
                "netu" -> 300
                else -> 0
            }
        } else {
            score += when (normalizedServer) {
                "streamwish" -> 500
                "mixdrop" -> 430
                "doodstream" -> 390
                "desu" -> 360
                "vidhide" -> 340
                "streamtape" -> 320
                "netu" -> 300
                "uqload" -> 180
                "yourupload" -> 170
                "mp4upload" -> 160
                else -> 0
            }
        }
        return score
    }

    private fun normalizeServer(value: String): String {
        val lower = value.lowercase(Locale.ROOT)
        return when {
            "mixdrop" in lower || "mix drop" in lower -> "mixdrop"
            "dood" in lower || "dsvplay" in lower -> "doodstream"
            "streamtape" in lower || "stape" in lower -> "streamtape"
            "streamwish" in lower || "sfastwish" in lower || "flaswish" in lower || "wish" in lower -> "streamwish"
            "vidhide" in lower || "vid hide" in lower -> "vidhide"
            "yourupload" in lower || "your upload" in lower -> "yourupload"
            "uqload" in lower -> "uqload"
            "mp4upload" in lower || "mp4 upload" in lower -> "mp4upload"
            "hqq" in lower || "netu" in lower -> "netu"
            "desu" in lower -> "desu"
            "magi" in lower -> "magi"
            "desuka" in lower -> "desuka"
            "mega" in lower -> "mega"
            Regex("""\bbonk\b""").containsMatchIn(lower) -> "bonk"
            Regex("""\bbee\b""").containsMatchIn(lower) -> "bee"
            Regex("""\bally\b""").containsMatchIn(lower) -> "ally"
            Regex("""\bkiwi\b""").containsMatchIn(lower) -> "kiwi"
            Regex("""\bmoo\b""").containsMatchIn(lower) -> "moo"
            Regex("""\bnun\b""").containsMatchIn(lower) -> "nun"
            Regex("""\bbun\b""").containsMatchIn(lower) -> "bun"
            Regex("""\btwin\b""").containsMatchIn(lower) -> "twin"
            Regex("""\bcog\b""").containsMatchIn(lower) -> "cog"
            Regex("""\bhop\b""").containsMatchIn(lower) -> "hop"
            Regex("""\bpewe\b""").containsMatchIn(lower) -> "pewe"
            Regex("""\btelli\b""").containsMatchIn(lower) -> "telli"
            else -> ""
        }
    }

    private fun originFor(url: String): String {
        return try {
            val uri = Uri.parse(url)
            val scheme = uri.scheme.orEmpty()
            val authority = uri.authority.orEmpty()
            if (scheme.isBlank() || authority.isBlank()) "" else "$scheme://$authority"
        } catch (_: Throwable) {
            ""
        }
    }

    private fun shortUrl(url: String): String {
        val normalized = url.trim()
        if (normalized.length <= 180) {
            return normalized
        }
        return normalized.take(120) + "..." + normalized.takeLast(36)
    }

    private companion object {
        private const val logTag = "TanukiRemoteResolver"
        private const val defaultRemoteUserAgent =
            "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Mobile Safari/537.36"
        private const val defaultCandidateSettleDelayMs = 420L
        private const val latAnimeResolverCandidateSettleDelayMs = 1_050L
    }
}
