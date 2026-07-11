import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'toonami_theme.dart';

const _trailerUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';

const _nativeTrailerPlayerChannel = MethodChannel('tanuki/trailer_player');

class TrailerQueueEntry {
  const TrailerQueueEntry({
    required this.title,
    required this.trailerUrl,
    this.seriesKey = '',
    this.providerId = '',
    this.slug = '',
    this.watchUrl = '',
    this.seriesUrl = '',
    this.catalogId = 0,
  });

  final String title;
  final String trailerUrl;
  final String seriesKey;
  final String providerId;
  final String slug;
  final String watchUrl;
  final String seriesUrl;
  final int catalogId;
}

class TrailerQueueScreen extends StatefulWidget {
  const TrailerQueueScreen({
    super.key,
    required this.title,
    required this.entries,
    this.onDetailLink,
  });

  final String title;
  final List<TrailerQueueEntry> entries;
  final ValueChanged<String>? onDetailLink;

  @override
  State<TrailerQueueScreen> createState() => _TrailerQueueScreenState();
}

class _TrailerQueueScreenState extends State<TrailerQueueScreen> {
  int _index = 0;
  String _status = 'Preparando trailer...';
  String _error = '';
  WebViewController? _webViewController;
  bool _openedInApp = false;
  bool _opening = false;
  bool _usingWebView = false;
  int _openTicket = 0;
  final FocusNode _trailerRootFocusNode = FocusNode(debugLabel: 'trailerRoot');
  final FocusNode _trailerBackFocusNode = FocusNode(debugLabel: 'trailerBack');

  TrailerQueueEntry? get _current {
    if (widget.entries.isEmpty ||
        _index < 0 ||
        _index >= widget.entries.length) {
      return null;
    }
    return widget.entries[_index];
  }

  bool get _canUseWebTrailer {
    return canUseEmbeddedTrailerWebView(
      platform: defaultTargetPlatform,
      isWeb: kIsWeb,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_openInitialTrailer());
      }
    });
  }

  Future<void> _openInitialTrailer() async {
    if (await _openNativeTrailerQueueIfPreferred()) {
      return;
    }
    await _openCurrentTrailer();
  }

  Future<bool> _openNativeTrailerQueueIfPreferred() async {
    if (!shouldOpenNativeYouTubeTrailerQueue(
      widget.entries,
      platform: defaultTargetPlatform,
      isWeb: kIsWeb,
    )) {
      return false;
    }
    setState(() {
      _opening = true;
      _status = 'Abriendo reproductor nativo...';
      _error = '';
    });
    final opened = await openNativeYouTubeTrailerQueue(
      title: widget.title,
      entries: widget.entries,
    );
    if (!mounted) {
      return opened;
    }
    if (opened) {
      Navigator.of(context).maybePop();
      return true;
    }
    setState(() {
      _opening = false;
      _status = 'Reproductor nativo no disponible.';
      _error = 'No se pudo iniciar el reproductor de trailers de Android.';
    });
    return true;
  }

  Future<void> _openCurrentTrailer() async {
    final entry = _current;
    final ticket = ++_openTicket;
    if (entry == null) {
      setState(() {
        _status = 'No hay trailer disponible.';
      });
      return;
    }
    final trailerUrl = normalizeTrailerUrl(entry.trailerUrl);
    final uri = Uri.tryParse(trailerUrl);
    if (uri == null || !uri.hasScheme) {
      setState(() {
        _status = 'URL de trailer no valida.';
        _error = trailerUrl;
      });
      return;
    }
    final youtubeId = _extractYouTubeVideoId(trailerUrl);
    debugPrint(
      'TrailerQueueScreen: opening trailer platform=$defaultTargetPlatform '
      'youtubeId=${youtubeId.isEmpty ? '<none>' : youtubeId} '
      'url=$trailerUrl',
    );
    if (_canUseWebTrailer) {
      await _openCurrentTrailerInWebView(trailerUrl, ticket);
      return;
    }
    setState(() {
      _openedInApp = false;
      _opening = false;
      _usingWebView = false;
      _status = 'Reproductor de trailers no disponible.';
      _error = 'Esta plataforma no ofrece un WebView compatible.';
    });
  }

  Future<void> _openCurrentTrailerInWebView(
    String trailerUrl,
    int ticket,
  ) async {
    final previousWebViewController = _webViewController;
    await _stopTrailerWebViewController(previousWebViewController);
    _disposeDesktopWebViewController(previousWebViewController);
    final uri = Uri.parse(trailerUrl);
    final controller = _createTrailerWebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            debugPrint('TrailerQueueScreen: WebView page started');
            if (!mounted || ticket != _openTicket) {
              return;
            }
            setState(() {
              _openedInApp = true;
              _opening = true;
              _usingWebView = true;
              _status = 'Cargando trailer web...';
            });
          },
          onPageFinished: (_) {
            debugPrint('TrailerQueueScreen: WebView page finished');
            if (!mounted || ticket != _openTicket) {
              return;
            }
            setState(() {
              _openedInApp = true;
              _opening = false;
              _usingWebView = true;
              _status = 'Trailer web en app';
            });
          },
          onWebResourceError: (error) {
            final isMainFrame = error.isForMainFrame ?? true;
            debugPrint(
              'TrailerQueueScreen: WebView resource error '
              'main=$isMainFrame code=${error.errorCode} '
              'url=${error.url ?? '<unknown>'} ${error.description}',
            );
            if (!isMainFrame || !mounted || ticket != _openTicket) {
              return;
            }
            setState(() {
              _openedInApp = false;
              _opening = false;
              _usingWebView = false;
              _status = 'No se pudo reproducir en app.';
              _error = error.description;
            });
          },
        ),
      );
    final platformController = controller.platform;
    if (platformController is AndroidWebViewController) {
      await platformController.setMediaPlaybackRequiresUserGesture(false);
      await platformController
          .setMixedContentMode(MixedContentMode.alwaysAllow);
      await platformController.setUseWideViewPort(true);
      await platformController.setUserAgent(_trailerUserAgent);
    } else if (canUseFloatingDesktopTrailerWebView(
      platform: defaultTargetPlatform,
      isWeb: kIsWeb,
    )) {
      await controller.setUserAgent(_trailerUserAgent);
    }
    await controller.addJavaScriptChannel(
      'TanukiTrailerPlayer',
      onMessageReceived: (message) {
        debugPrint('TrailerQueueScreen: YouTube event ${message.message}');
        if (!mounted || ticket != _openTicket) {
          return;
        }
        Object? decoded;
        try {
          decoded = jsonDecode(message.message);
          if (decoded is String) {
            decoded = jsonDecode(decoded);
          }
        } catch (_) {
          debugPrint(
            'TrailerQueueScreen: ignored malformed YouTube event '
            '${message.message}',
          );
          return;
        }
        if (decoded is! Map) {
          return;
        }
        final type = decoded['type'];
        if (type == 'ready') {
          setState(() {
            _openedInApp = true;
            _opening = false;
            _usingWebView = true;
            _status = 'Trailer web en app';
          });
        } else if (type == 'index') {
          _setCurrentTrailerIndexFromWebView(decoded['detail']);
        } else if (type == 'close') {
          unawaited(_closeTrailerQueue());
        } else if (type == 'detail') {
          final detail = decoded['detail'];
          unawaited(_openTrailerDetail(
            detail is String && detail.trim().isNotEmpty ? detail : null,
          ));
        } else if (type == 'error') {
          final detail = decoded['detail'];
          setState(() {
            _opening = false;
            _status = 'Error del reproductor de YouTube.';
            _error = 'YouTube error ${detail ?? ''}'.trim();
          });
        } else if (type == 'ended') {
          _handleTrailerEnded();
        }
      },
    );
    if (!mounted || ticket != _openTicket) {
      return;
    }
    setState(() {
      _webViewController = controller;
      _usingWebView = true;
      _openedInApp = true;
      _opening = true;
      _error = '';
      _status = 'Cargando trailer web...';
    });
    final youtubeId = _extractYouTubeVideoId(trailerUrl);
    final vimeoId = _extractVimeoVideoId(uri);
    try {
      if (youtubeId.isNotEmpty) {
        debugPrint(
          'TrailerQueueScreen: loading YouTube IFrame API WebView '
          'videoId=$youtubeId baseUrl=https://www.youtube-nocookie.com',
        );
        await controller.loadHtmlString(
          canUseFloatingDesktopTrailerWebView(
                    platform: defaultTargetPlatform,
                    isWeb: kIsWeb,
                  ) &&
                  widget.entries.length > 1
              ? desktopYouTubeTrailerQueueHtml(
                  title: widget.title,
                  entries: widget.entries,
                  initialIndex: _index,
                )
              : youtubeWebTrailerEmbedHtml(youtubeId),
          baseUrl: 'https://www.youtube-nocookie.com',
        );
      } else if (vimeoId.isNotEmpty) {
        await controller.loadHtmlString(
          _buildVimeoEmbedHtml(vimeoId),
          baseUrl: 'https://player.vimeo.com',
        );
      } else {
        await controller.loadRequest(uri);
      }
    } catch (error) {
      if (!mounted || ticket != _openTicket) {
        return;
      }
      setState(() {
        _openedInApp = false;
        _opening = false;
        _usingWebView = false;
        _webViewController = null;
        _status = 'No se pudo reproducir en app.';
        _error = error.toString();
      });
      _disposeDesktopWebViewController(controller);
    }
  }

  void _move(int delta) {
    if (widget.entries.isEmpty) {
      return;
    }
    setState(() {
      _index = (_index + delta).clamp(0, widget.entries.length - 1).toInt();
    });
    unawaited(_openCurrentTrailer());
  }

  void _handleTrailerEnded() {
    if (_index < widget.entries.length - 1) {
      _move(1);
      return;
    }
    setState(() {
      _status = 'Cola terminada';
    });
  }

  void _setCurrentTrailerIndexFromWebView(Object? rawIndex) {
    final parsed = rawIndex is int ? rawIndex : int.tryParse('$rawIndex');
    if (parsed == null || widget.entries.isEmpty) {
      return;
    }
    final nextIndex = parsed.clamp(0, widget.entries.length - 1).toInt();
    if (nextIndex == _index) {
      return;
    }
    setState(() {
      _index = nextIndex;
      _status = 'Trailer web en app';
    });
  }

  Future<void> _closeTrailerQueue() async {
    await _stopTrailerWebViewController(_webViewController);
    await _hideDesktopWebViewController(_webViewController);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _openTrailerDetail([String? detailUrl]) async {
    final entry = _current;
    final resolvedDetailUrl = detailUrl ??
        (entry == null ? null : trailerDetailUri(entry).toString());
    if (resolvedDetailUrl == null || resolvedDetailUrl.trim().isEmpty) {
      return;
    }
    await _stopTrailerWebViewController(_webViewController);
    await _hideDesktopWebViewController(_webViewController);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(resolvedDetailUrl);
  }

  @override
  void dispose() {
    _openTicket += 1;
    final webViewController = _webViewController;
    _webViewController = null;
    unawaited(_stopTrailerWebViewController(webViewController));
    _disposeDesktopWebViewController(webViewController);
    _trailerRootFocusNode.dispose();
    _trailerBackFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleTrailerRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      unawaited(_closeTrailerQueue());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (_index > 0) {
        _move(-1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      if (_index < widget.entries.length - 1) {
        _move(1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _trailerBackFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (!_trailerBackFocusNode.hasFocus) {
        _trailerBackFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final title = current?.title.trim().isNotEmpty == true
        ? current!.title.trim()
        : widget.title;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _trailerRootFocusNode,
        autofocus: true,
        onKeyEvent: _handleTrailerRootKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_usingWebView && _webViewController != null)
              Positioned.fill(
                  child: WebViewWidget(controller: _webViewController!)),
            if (!_openedInApp || _opening)
              const Positioned.fill(
                child: ColoredBox(color: Colors.black),
              ),
            if (!_openedInApp || _opening)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          'assets/images/tanuki_brand_logo.png',
                          height: 76,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: TanukiColors.muted,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (_error.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: TanukiColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              onPressed: _opening ? null : _openCurrentTrailer,
                              icon: Icon(_opening
                                  ? Icons.hourglass_top
                                  : Icons.play_arrow),
                              label: Text(
                                _opening ? 'Cargando...' : 'Reintentar en app',
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => unawaited(_openTrailerDetail()),
                              icon: const Icon(Icons.info_outline),
                              label: const Text('Ver detalle'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.topCenter,
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Container(
                  color: const Color(0x96000000),
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(1),
                        child: _TrailerIconButton(
                          icon: Icons.arrow_back,
                          tooltip: 'Volver',
                          focusNode: _trailerBackFocusNode,
                          onPressed: () => unawaited(_closeTrailerQueue()),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(2),
                        child: _TrailerIconButton(
                          icon: Icons.skip_previous,
                          tooltip: 'Trailer anterior',
                          onPressed: _index <= 0 ? null : () => _move(-1),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(3),
                        child: _TrailerIconButton(
                          icon: Icons.skip_next,
                          tooltip: 'Trailer siguiente',
                          onPressed: _index >= widget.entries.length - 1
                              ? null
                              : () => _move(1),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_index + 1}/${widget.entries.length} | $_status',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(4),
                        child: _TrailerIconButton(
                          icon: Icons.refresh,
                          tooltip: 'Reintentar en app',
                          onPressed: _opening ? null : _openCurrentTrailer,
                        ),
                      ),
                      const SizedBox(width: 10),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(5),
                        child: _TrailerIconButton(
                          icon: Icons.info_outline,
                          tooltip: 'Ver detalle',
                          onPressed: () => unawaited(_openTrailerDetail()),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _extractYouTubeVideoId(String trailerUrl) {
  final uri = Uri.tryParse(trailerUrl.trim());
  if (uri == null || !isYouTubeTrailerUrl(trailerUrl)) {
    return '';
  }
  final queryVideoId = uri.queryParameters['v'];
  if (_isValidYouTubeVideoId(queryVideoId)) {
    return queryVideoId!;
  }
  final segments = uri.pathSegments;
  if (_isYouTubeShortHost(uri.host) && segments.isNotEmpty) {
    final id = segments.first;
    if (_isValidYouTubeVideoId(id)) {
      return id;
    }
  }
  for (var index = 0; index < segments.length - 1; index += 1) {
    final marker = segments[index].toLowerCase();
    if (marker == 'embed' || marker == 'shorts' || marker == 'live') {
      final id = segments[index + 1];
      if (_isValidYouTubeVideoId(id)) {
        return id;
      }
    }
  }
  return '';
}

bool isYouTubeTrailerUrl(String trailerUrl) {
  final uri = Uri.tryParse(trailerUrl.trim());
  if (uri == null) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return _isYouTubeShortHost(host) ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host == 'youtube-nocookie.com' ||
      host.endsWith('.youtube-nocookie.com');
}

String normalizeTrailerUrl(String trailerUrl) {
  final videoId = _extractYouTubeVideoId(trailerUrl);
  if (videoId.isNotEmpty) {
    return Uri.https('www.youtube.com', '/watch', {'v': videoId}).toString();
  }
  return trailerUrl.trim();
}

bool _isYouTubeShortHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'youtu.be' || normalized.endsWith('.youtu.be');
}

bool _isValidYouTubeVideoId(String? value) {
  return value != null && RegExp(r'^[0-9A-Za-z_-]{11}$').hasMatch(value);
}

bool canUseEmbeddedTrailerWebView({
  required TargetPlatform platform,
  bool isWeb = kIsWeb,
}) {
  if (isWeb) {
    return false;
  }
  return platform == TargetPlatform.android ||
      platform == TargetPlatform.iOS ||
      platform == TargetPlatform.linux ||
      platform == TargetPlatform.windows;
}

bool canUseNativeYouTubeTrailerPlayer({
  required TargetPlatform platform,
  bool isWeb = kIsWeb,
}) {
  return !isWeb && platform == TargetPlatform.android;
}

bool shouldOpenNativeYouTubeTrailerQueue(
  List<TrailerQueueEntry> entries, {
  required TargetPlatform platform,
  bool isWeb = kIsWeb,
}) {
  if (!canUseNativeYouTubeTrailerPlayer(platform: platform, isWeb: isWeb)) {
    return false;
  }
  final playable =
      entries.where((entry) => entry.trailerUrl.trim().isNotEmpty).toList();
  return playable.isNotEmpty &&
      playable.every((entry) =>
          _extractYouTubeVideoId(normalizeTrailerUrl(entry.trailerUrl))
              .isNotEmpty);
}

Future<bool> openNativeYouTubeTrailerQueue({
  required String title,
  required List<TrailerQueueEntry> entries,
}) async {
  try {
    final opened = await _nativeTrailerPlayerChannel.invokeMethod<bool>(
      'openTrailerQueue',
      {
        'title': title,
        'entries': entries
            .map(
              (entry) => {
                'title': entry.title,
                'trailerUrl': normalizeTrailerUrl(entry.trailerUrl),
                'detailUrl': trailerDetailUri(entry).toString(),
                'seriesKey': entry.seriesKey.trim(),
                'provider': entry.providerId.trim(),
                'slug': entry.slug.trim(),
                'watchUrl': entry.watchUrl.trim(),
                'seriesUrl': entry.seriesUrl.trim(),
                'catalogId': entry.catalogId,
              },
            )
            .toList(),
      },
    );
    return opened == true;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (error) {
    debugPrint('TrailerQueueScreen: native trailer player failed: $error');
    return false;
  }
}

Uri trailerDetailUri(TrailerQueueEntry entry) {
  final query = <String, String>{
    'title': entry.title.trim(),
    'trailerUrl': normalizeTrailerUrl(entry.trailerUrl),
  };
  void add(String key, String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      query[key] = trimmed;
    }
  }

  add('seriesKey', entry.seriesKey);
  add('provider', entry.providerId);
  add('slug', entry.slug);
  add('watchUrl', entry.watchUrl);
  add('seriesUrl', entry.seriesUrl);
  if (entry.catalogId > 0) {
    query['catalogId'] = entry.catalogId.toString();
  }
  return Uri(
    scheme: 'tanuki',
    host: 'series',
    path: '/detail',
    queryParameters: query,
  );
}

bool canUseFloatingDesktopTrailerWebView({
  required TargetPlatform platform,
  bool isWeb = kIsWeb,
}) {
  return !isWeb &&
      (platform == TargetPlatform.linux || platform == TargetPlatform.windows);
}

WebViewController _createTrailerWebViewController() {
  return WebViewController();
}

Future<void> _hideDesktopWebViewController(
  WebViewController? controller,
) async {}

Future<void> _stopTrailerWebViewController(
    WebViewController? controller) async {
  if (controller == null) {
    return;
  }
  try {
    await controller.runJavaScript('''
      try {
        if (window.player && window.player.stopVideo) {
          window.player.stopVideo();
        }
      } catch (error) {}
      try {
        document.querySelectorAll('video').forEach(function(video) {
          try {
            video.pause();
            video.removeAttribute('src');
            video.load();
          } catch (error) {}
        });
      } catch (error) {}
    ''');
  } catch (_) {}
  try {
    await controller.loadHtmlString(
      '<!doctype html><html><body style="margin:0;background:#000"></body></html>',
      baseUrl: 'about:blank',
    );
  } catch (_) {}
}

void _disposeDesktopWebViewController(WebViewController? controller) {}

String youtubeWebTrailerEmbedHtml(String videoId) {
  final jsVideoId = jsonEncode(videoId);
  final jsSessionId = jsonEncode(
    'youtube-${DateTime.now().microsecondsSinceEpoch}',
  );
  return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
  <meta name="referrer" content="strict-origin-when-cross-origin">
  <style>
    html, body {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #000;
    }
    #player {
      position: fixed;
      inset: 0;
      width: 100%;
      height: 100%;
      background: #000;
    }
    iframe {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      border: 0;
      background: #000;
    }
  </style>
  <script src="https://www.youtube.com/iframe_api" referrerpolicy="strict-origin-when-cross-origin"></script>
</head>
<body>
  <div id="player"></div>
  <script>
    const sessionId = $jsSessionId;
    const pendingNotifications = [];
    function flushNotifications() {
      for (let i = 0; i < pendingNotifications.length;) {
        const message = pendingNotifications[i];
        let sent = false;
        try {
          if (window.TanukiTrailerPlayer && TanukiTrailerPlayer.postMessage) {
            TanukiTrailerPlayer.postMessage(message);
            sent = true;
          } else if (typeof window.TanukiTrailerPlayer === 'function') {
            window.TanukiTrailerPlayer(message, '');
            sent = true;
          }
        } catch (error) {}
        if (sent) {
          pendingNotifications.splice(i, 1);
        } else {
          i += 1;
        }
      }
    }
    window.__tanukiFlushNotifications = flushNotifications;
    function notify(type, detail) {
      pendingNotifications.push(JSON.stringify({
        type: type,
        detail: detail || '',
        sessionId: sessionId
      }));
      flushNotifications();
      window.setTimeout(flushNotifications, 250);
      window.setTimeout(flushNotifications, 1000);
    }
    function playWhenReady(player) {
      const delays = [0, 250, 900, 1800];
      delays.forEach(function(delay) {
        window.setTimeout(function() {
          try { player.playVideo(); } catch (error) {}
        }, delay);
      });
    }
    function onYouTubeIframeAPIReady() {
      const player = new YT.Player('player', {
        host: 'https://www.youtube-nocookie.com',
        width: '100%',
        height: '100%',
        videoId: $jsVideoId,
        playerVars: {
          autoplay: 1,
          controls: 1,
          fs: 1,
          rel: 0,
          modestbranding: 1,
          playsinline: 1,
          iv_load_policy: 3,
          enablejsapi: 1,
          origin: 'https://www.youtube-nocookie.com'
        },
        events: {
          onReady: function(event) {
            window.player = event.target;
            playWhenReady(event.target);
            notify('ready');
          },
          onStateChange: function(event) {
            if (event.data === YT.PlayerState.ENDED) {
              notify('ended');
            }
          },
          onError: function(event) {
            notify('error', String(event && event.data ? event.data : 'youtube'));
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
    }
  </script>
</body>
</html>
''';
}

String desktopYouTubeTrailerQueueHtml({
  required String title,
  required List<TrailerQueueEntry> entries,
  required int initialIndex,
}) {
  final payloadEntries = <Map<String, Object>>[];
  var initialQueueIndex = 0;
  for (var entryIndex = 0; entryIndex < entries.length; entryIndex += 1) {
    final entry = entries[entryIndex];
    final videoId = _extractYouTubeVideoId(normalizeTrailerUrl(
      entry.trailerUrl,
    ));
    if (videoId.isEmpty) {
      continue;
    }
    if (entryIndex == initialIndex) {
      initialQueueIndex = payloadEntries.length;
    }
    payloadEntries.add({
      'entryIndex': entryIndex,
      'title': entry.title.trim().isEmpty ? title : entry.title.trim(),
      'videoId': videoId,
      'detailUrl': trailerDetailUri(entry).toString(),
    });
  }
  final clampedInitialIndex = payloadEntries.isEmpty
      ? 0
      : initialQueueIndex.clamp(0, payloadEntries.length - 1).toInt();
  final payload = jsonEncode({
    'title': title,
    'initialIndex': clampedInitialIndex,
    'entries': payloadEntries,
  });
  final jsSessionId = jsonEncode(
    'desktop-youtube-${DateTime.now().microsecondsSinceEpoch}',
  );
  return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
  <meta name="referrer" content="strict-origin-when-cross-origin">
  <style>
    * { box-sizing: border-box; }
    html, body {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #000;
      color: #fff;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    #player, #player iframe {
      position: fixed;
      inset: 0;
      width: 100%;
      height: 100%;
      border: 0;
      background: #000;
    }
    #overlay {
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      min-height: 68px;
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 12px;
      background: rgba(0, 0, 0, 0.59);
      z-index: 3;
    }
    .icon-button {
      width: 44px;
      height: 44px;
      flex: 0 0 44px;
      border: 0;
      border-radius: 50%;
      background: rgba(20, 29, 40, 0.4);
      color: #fff;
      display: inline-grid;
      place-items: center;
      padding: 0;
      cursor: pointer;
    }
    .icon-button:disabled {
      opacity: 0.35;
      cursor: default;
    }
	    .icon-button:focus-visible {
	      outline: 3px solid #ff8a2a;
	      background: rgba(36, 56, 76, 0.67);
	    }
	    .icon-button:focus {
	      outline: 3px solid #ff8a2a;
	      background: rgba(36, 56, 76, 0.67);
	    }
    .icon-button svg {
      width: 24px;
      height: 24px;
      fill: currentColor;
    }
    #text {
      min-width: 0;
      flex: 1 1 auto;
      padding-left: 2px;
    }
    #title {
      font-size: 16px;
      font-weight: 700;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    #status {
      margin-top: 4px;
      color: rgba(226, 232, 240, 0.78);
      font-size: 14px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
  </style>
  <script src="https://www.youtube.com/iframe_api" referrerpolicy="strict-origin-when-cross-origin"></script>
</head>
<body>
  <div id="player"></div>
  <div id="overlay">
    <button id="back" class="icon-button" title="Volver" aria-label="Volver">
      <svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.42-1.41L7.83 13H20v-2z"></path></svg>
    </button>
    <button id="previous" class="icon-button" title="Trailer anterior" aria-label="Trailer anterior">
      <svg viewBox="0 0 24 24"><path d="M6 6h2v12H6V6zm3.5 6L18 18V6l-8.5 6z"></path></svg>
    </button>
    <button id="next" class="icon-button" title="Trailer siguiente" aria-label="Trailer siguiente">
      <svg viewBox="0 0 24 24"><path d="M6 18l8.5-6L6 6v12zM16 6h2v12h-2V6z"></path></svg>
    </button>
    <div id="text">
      <div id="title"></div>
      <div id="status"></div>
    </div>
    <button id="detail" class="icon-button" title="Ver detalle" aria-label="Ver detalle">
      <svg viewBox="0 0 24 24"><path d="M11 17h2v-6h-2v6zm1-15C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm-1-10h2V8h-2v2z"></path></svg>
    </button>
  </div>
  <script>
    const payload = $payload;
    const sessionId = $jsSessionId;
    const entries = Array.isArray(payload.entries) ? payload.entries : [];
    let index = Math.max(0, Math.min(Number(payload.initialIndex) || 0, Math.max(entries.length - 1, 0)));
    let player = null;
    const pendingNotifications = [];

	    const titleEl = document.getElementById('title');
	    const statusEl = document.getElementById('status');
	    const backButton = document.getElementById('back');
	    const previousButton = document.getElementById('previous');
	    const nextButton = document.getElementById('next');
	    const detailButton = document.getElementById('detail');
	    const focusableButtons = [backButton, previousButton, nextButton, detailButton];

    function flushNotifications() {
      for (let i = 0; i < pendingNotifications.length;) {
        const message = pendingNotifications[i];
        let sent = false;
        try {
          if (window.TanukiTrailerPlayer && TanukiTrailerPlayer.postMessage) {
            TanukiTrailerPlayer.postMessage(message);
            sent = true;
          } else if (typeof window.TanukiTrailerPlayer === 'function') {
            window.TanukiTrailerPlayer(message, '');
            sent = true;
          }
        } catch (error) {}
        if (sent) {
          pendingNotifications.splice(i, 1);
        } else {
          i += 1;
        }
      }
    }
    window.__tanukiFlushNotifications = flushNotifications;
    function notify(type, detail) {
      pendingNotifications.push(JSON.stringify({
        type: type,
        detail: detail || '',
        sessionId: sessionId
      }));
      flushNotifications();
      window.setTimeout(flushNotifications, 250);
      window.setTimeout(flushNotifications, 1000);
    }
    function currentEntry() {
      return entries[index] || null;
    }
    function updateUi() {
      const entry = currentEntry();
      titleEl.textContent = entry ? entry.title : payload.title || 'Trailers';
      statusEl.textContent = entries.length > 0
        ? String(index + 1) + '/' + String(entries.length) + ' | Trailer web en app'
        : 'No hay trailer disponible';
      previousButton.disabled = index <= 0;
      nextButton.disabled = index >= entries.length - 1;
      if (entry && typeof entry.entryIndex === 'number') {
        notify('index', entry.entryIndex);
      }
    }
    function playWhenReady(target) {
      try { target.unMute(); } catch (error) {}
      [0, 250, 900, 1800].forEach(function(delay) {
        window.setTimeout(function() {
          try { target.playVideo(); } catch (error) {}
        }, delay);
      });
      window.setTimeout(function() {
        try {
          if (target.getPlayerState && target.getPlayerState() !== YT.PlayerState.PLAYING) {
            target.mute();
            target.playVideo();
            window.setTimeout(function() {
              try { target.unMute(); } catch (error) {}
            }, 900);
          }
        } catch (error) {}
      }, 2200);
    }
    function configureIframe() {
      try {
        const iframe = player.getIframe();
        if (iframe) {
          iframe.allow = 'autoplay; encrypted-media; fullscreen; picture-in-picture';
          iframe.allowFullscreen = true;
          iframe.referrerPolicy = 'strict-origin-when-cross-origin';
        }
      } catch (error) {}
    }
    function loadCurrent() {
      const entry = currentEntry();
      updateUi();
      if (!entry || !player) {
        return;
      }
      try {
        player.loadVideoById(entry.videoId);
        playWhenReady(player);
      } catch (error) {
        notify('error', String(error || 'youtube'));
      }
    }
	    function move(delta) {
	      if (entries.length === 0) {
	        return;
	      }
      const nextIndex = Math.max(0, Math.min(index + delta, entries.length - 1));
      if (nextIndex === index) {
        return;
      }
	      index = nextIndex;
	      loadCurrent();
	    }
	    function firstEnabledButton() {
	      for (const button of focusableButtons) {
	        if (button && !button.disabled) {
	          return button;
	        }
	      }
	      return null;
	    }
	    function moveFocus(delta) {
	      const enabled = focusableButtons.filter(function(button) {
	        return button && !button.disabled;
	      });
	      if (enabled.length === 0) {
	        return;
	      }
	      const activeIndex = enabled.indexOf(document.activeElement);
	      const baseIndex = activeIndex < 0 ? 0 : activeIndex;
	      const nextIndex = Math.max(0, Math.min(baseIndex + delta, enabled.length - 1));
	      enabled[nextIndex].focus();
	    }
    function handleEnded() {
      if (index < entries.length - 1) {
        index += 1;
        loadCurrent();
      } else {
        notify('ended');
      }
    }
	    backButton.addEventListener('click', function() {
	      notify('close');
	    });
    previousButton.addEventListener('click', function() {
      move(-1);
    });
    nextButton.addEventListener('click', function() {
      move(1);
    });
	    detailButton.addEventListener('click', function() {
	      const entry = currentEntry();
	      notify('detail', entry ? entry.detailUrl : '');
	    });
	    document.addEventListener('keydown', function(event) {
	      const key = event.key;
	      if (key === 'Escape' || key === 'BrowserBack' || key === 'Backspace') {
	        event.preventDefault();
	        notify('close');
	        return;
	      }
	      if (key === 'ArrowLeft') {
	        event.preventDefault();
	        if (document.activeElement && document.activeElement.classList.contains('icon-button')) {
	          moveFocus(-1);
	        } else {
	          move(-1);
	        }
	        return;
	      }
	      if (key === 'ArrowRight') {
	        event.preventDefault();
	        if (document.activeElement && document.activeElement.classList.contains('icon-button')) {
	          moveFocus(1);
	        } else {
	          move(1);
	        }
	        return;
	      }
	      if (key === 'ArrowUp' || key === 'ArrowDown') {
	        event.preventDefault();
	        const button = firstEnabledButton();
	        if (button) {
	          button.focus();
	        }
	        return;
	      }
	      if (key === 'Enter' || key === ' ') {
	        if (document.activeElement && document.activeElement.classList.contains('icon-button')) {
	          event.preventDefault();
	          document.activeElement.click();
	        }
	      }
	    });
    function onYouTubeIframeAPIReady() {
      const entry = currentEntry();
      updateUi();
      if (!entry) {
        notify('error', 'empty');
        return;
      }
      player = new YT.Player('player', {
        host: 'https://www.youtube-nocookie.com',
        width: '100%',
        height: '100%',
        videoId: entry.videoId,
        playerVars: {
          autoplay: 1,
          controls: 1,
          fs: 1,
          rel: 0,
          modestbranding: 1,
          playsinline: 1,
          iv_load_policy: 3,
          enablejsapi: 1,
          origin: 'https://www.youtube-nocookie.com'
        },
        events: {
          onReady: function(event) {
            player = event.target;
            window.player = player;
            configureIframe();
            playWhenReady(player);
            notify('ready');
          },
          onStateChange: function(event) {
            if (event.data === YT.PlayerState.ENDED) {
              handleEnded();
            }
          },
          onError: function(event) {
            notify('error', String(event && event.data ? event.data : 'youtube'));
          }
        }
      });
      configureIframe();
    }
  </script>
</body>
</html>
''';
}

String _extractVimeoVideoId(Uri uri) {
  final host = uri.host.toLowerCase();
  if (!host.contains('vimeo.com')) {
    return '';
  }
  for (final segment in uri.pathSegments.reversed) {
    if (RegExp(r'^\d+$').hasMatch(segment)) {
      return segment;
    }
  }
  return '';
}

String _buildVimeoEmbedHtml(String videoId) {
  final safeId = _escapeHtmlAttribute(videoId);
  return _buildTrailerEmbedHtml(
    'https://player.vimeo.com/video/$safeId'
    '?autoplay=1&title=0&byline=0&portrait=0&playsinline=1',
  );
}

String _buildTrailerEmbedHtml(String src) {
  final safeSrc = _escapeHtmlAttribute(src);
  return '''
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    html, body { margin: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
    iframe { position: fixed; inset: 0; width: 100%; height: 100%; border: 0; background: #000; }
  </style>
</head>
<body>
  <iframe
    src="$safeSrc"
    allow="autoplay; encrypted-media; fullscreen; picture-in-picture"
    allowfullscreen>
  </iframe>
</body>
</html>
''';
}

String _escapeHtmlAttribute(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

class _TrailerIconButton extends StatelessWidget {
  const _TrailerIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        focusNode: focusNode,
        onPressed: onPressed,
        icon: Icon(icon),
        style: IconButton.styleFrom(
          fixedSize: const Size(44, 44),
          backgroundColor: const Color(0x66141D28),
          foregroundColor: Colors.white,
          disabledForegroundColor: const Color(0x66FFFFFF),
          shape: const CircleBorder(),
        ),
      ),
    );
  }
}
