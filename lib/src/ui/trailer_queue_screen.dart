import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart' as vp;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_win_floating/webview_plugin.dart' as desktop_webview;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../services/playback_backend.dart';
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
  Player? _player;
  VideoController? _videoController;
  StreamSubscription<bool>? _playerCompletedSubscription;
  vp.VideoPlayerController? _fallbackVideoController;
  WebViewController? _webViewController;
  yt.YoutubeExplode? _youtube;
  bool _openedInApp = false;
  bool _opening = false;
  bool _usingWebView = false;
  bool _usingFallbackVideo = false;
  int _openTicket = 0;

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
      _status = 'Probando trailer web...';
    });
    return false;
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
    if (shouldOpenTrailerInWebViewFirst(
      trailerUrl,
      platform: defaultTargetPlatform,
      isWeb: kIsWeb,
    )) {
      await _openCurrentTrailerInWebView(trailerUrl, ticket);
      return;
    }
    if (_canUseWebTrailer &&
        youtubeId.isEmpty &&
        !isYouTubeTrailerUrl(trailerUrl)) {
      await _openCurrentTrailerInWebView(trailerUrl, ticket);
      return;
    }
    final previousWebViewController = _webViewController;
    setState(() {
      _openedInApp = false;
      _opening = true;
      _usingWebView = false;
      _usingFallbackVideo = false;
      _webViewController = null;
      _error = '';
      _status = 'Cargando trailer en la app...';
    });
    _disposeDesktopWebViewController(previousWebViewController);
    await _disposeFallbackVideoController();
    try {
      final playableUrl = await _resolvePlayableTrailerUrl(trailerUrl)
          .timeout(const Duration(seconds: 16));
      if (!mounted || ticket != _openTicket) {
        return;
      }
      if (canUseFallbackTrailerVideoPlayer(
        platform: defaultTargetPlatform,
        isWeb: kIsWeb,
      )) {
        final openedWithFallback =
            await _openWithFallbackVideoPlayer(playableUrl, ticket);
        if (openedWithFallback || !mounted || ticket != _openTicket) {
          return;
        }
      } else if (mounted && ticket == _openTicket) {
        setState(() {
          _status = 'Probando media_kit...';
        });
      }
      if (!await _ensureMediaKitTrailerBackend()) {
        throw StateError(PlaybackBackend.initializationError.isNotEmpty
            ? PlaybackBackend.initializationError
            : 'media_kit no esta disponible.');
      }
      final player = _player;
      final videoController = _videoController;
      if (player == null || videoController == null) {
        throw StateError(PlaybackBackend.initializationError.isNotEmpty
            ? PlaybackBackend.initializationError
            : 'media_kit no esta disponible.');
      }
      await _openWithMediaKit(player, videoController, playableUrl, ticket);
    } catch (error) {
      if (!mounted || ticket != _openTicket) {
        return;
      }
      try {
        final player = _player;
        if (player != null) {
          await player.stop();
        }
      } catch (_) {}
      if (!mounted || ticket != _openTicket) {
        return;
      }
      debugPrint('TrailerQueueScreen: native trailer playback failed: $error');
      if (shouldFallbackTrailerToWebView(
        trailerUrl,
        platform: defaultTargetPlatform,
        isWeb: kIsWeb,
      )) {
        setState(() {
          _status = 'Probando trailer web...';
        });
        await _openCurrentTrailerInWebView(trailerUrl, ticket);
        return;
      }
      setState(() {
        _openedInApp = false;
        _opening = false;
        _usingWebView = false;
        _usingFallbackVideo = false;
        _status = 'No se pudo reproducir en app.';
        _error = _trailerPlaybackFailureMessage(trailerUrl, error);
      });
    }
  }

  Future<bool> _ensureMediaKitTrailerBackend() async {
    if (_player != null && _videoController != null) {
      return true;
    }
    try {
      PlaybackBackend.ensureInitialized();
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'Reproductor embebido no disponible.';
          _error = error.toString();
        });
      }
      return false;
    }
    if (!PlaybackBackend.mediaKitAvailable) {
      return false;
    }
    final player = Player();
    _player = player;
    _videoController = VideoController(player);
    _playerCompletedSubscription = player.stream.completed.listen((completed) {
      if (completed && mounted) {
        _handleTrailerEnded();
      }
    });
    return true;
  }

  Future<bool> _openWithFallbackVideoPlayer(
    String playableUrl,
    int ticket,
  ) async {
    vp.VideoPlayerController? controller;
    try {
      setState(() {
        _status = 'Probando reproductor alternativo...';
      });
      controller = vp.VideoPlayerController.networkUrl(
        Uri.parse(playableUrl),
        httpHeaders: _trailerPlaybackHeaders(playableUrl),
      );
      await controller.initialize().timeout(const Duration(seconds: 14));
      var handledCompletion = false;
      controller.addListener(() {
        if (handledCompletion || !mounted || ticket != _openTicket) {
          return;
        }
        final value = controller!.value;
        if (!value.isInitialized || value.duration <= Duration.zero) {
          return;
        }
        final remaining = value.duration - value.position;
        if (remaining <= const Duration(milliseconds: 700)) {
          handledCompletion = true;
          _handleTrailerEnded();
        }
      });
      await controller.play().timeout(const Duration(seconds: 6));
      if (!mounted || ticket != _openTicket) {
        await controller.dispose();
        return true;
      }
      setState(() {
        _fallbackVideoController = controller;
        _openedInApp = true;
        _opening = false;
        _usingFallbackVideo = true;
        _usingWebView = false;
        _status = 'Trailer en reproductor alternativo';
      });
      return true;
    } catch (_) {
      try {
        await controller?.dispose();
      } catch (_) {}
      if (mounted && ticket == _openTicket) {
        setState(() {
          _status = 'Probando media_kit...';
        });
      }
      return false;
    }
  }

  Future<void> _openWithMediaKit(
    Player player,
    VideoController videoController,
    String playableUrl,
    int ticket,
  ) async {
    await videoController.platform.future;
    await player.stop();
    if (!mounted || ticket != _openTicket) {
      return;
    }
    await player
        .open(
          Media(
            playableUrl,
            httpHeaders: _trailerPlaybackHeaders(playableUrl),
          ),
          play: true,
        )
        .timeout(const Duration(seconds: 12));
    if (!mounted || ticket != _openTicket) {
      return;
    }
    setState(() {
      _openedInApp = true;
      _opening = false;
      _usingWebView = false;
      _usingFallbackVideo = false;
      _status = 'Trailer en media_kit';
    });
  }

  Future<void> _openCurrentTrailerInWebView(
    String trailerUrl,
    int ticket,
  ) async {
    await _disposeFallbackVideoController();
    final previousWebViewController = _webViewController;
    _disposeDesktopWebViewController(previousWebViewController);
    final uri = Uri.parse(trailerUrl);
    final isDesktopWebView = canUseFloatingDesktopTrailerWebView(
      platform: defaultTargetPlatform,
      isWeb: kIsWeb,
    );
    final controller = _createTrailerWebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted || ticket != _openTicket) {
              return;
            }
            setState(() {
              _openedInApp = true;
              _opening = true;
              _usingWebView = true;
              _usingFallbackVideo = false;
              _status = 'Cargando trailer web...';
            });
          },
          onPageFinished: (_) {
            if (!mounted || ticket != _openTicket) {
              return;
            }
            setState(() {
              _openedInApp = true;
              _opening = false;
              _usingWebView = true;
              _usingFallbackVideo = false;
              _status = 'Trailer web en app';
            });
          },
          onWebResourceError: (error) {
            final isMainFrame = error.isForMainFrame ?? true;
            if (!isMainFrame || !mounted || ticket != _openTicket) {
              return;
            }
            setState(() {
              _openedInApp = false;
              _opening = false;
              _usingWebView = false;
              _usingFallbackVideo = false;
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
    } else if (platformController
        is desktop_webview.WindowsPlatformWebViewController) {
      await controller.setUserAgent(_trailerUserAgent);
      await platformController.controller.enableZoom(false);
      await platformController.controller.setVisibility(true);
    }
    await controller.addJavaScriptChannel(
      'TanukiTrailerPlayer',
      onMessageReceived: (message) {
        debugPrint('TrailerQueueScreen: YouTube event ${message.message}');
        if (!mounted || ticket != _openTicket) {
          return;
        }
        final Object? decoded;
        try {
          decoded = jsonDecode(message.message);
        } catch (_) {
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
            _usingFallbackVideo = false;
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
      _usingFallbackVideo = false;
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
          isDesktopWebView
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

  Future<String> _resolvePlayableTrailerUrl(String trailerUrl) async {
    final videoId = _extractYouTubeVideoId(trailerUrl);
    if (videoId.isEmpty) {
      if (isYouTubeTrailerUrl(trailerUrl)) {
        throw StateError('No pude detectar el ID del trailer de YouTube.');
      }
      return trailerUrl;
    }
    if (mounted) {
      setState(() {
        _status = 'Resolviendo trailer de YouTube...';
      });
    }
    final youtube = _youtube ??= yt.YoutubeExplode();
    final manifest = await youtube.videos.streams.getManifest(
      videoId,
      ytClients: [
        yt.YoutubeApiClient.androidSdkless,
        yt.YoutubeApiClient.ios,
        yt.YoutubeApiClient.safari,
        yt.YoutubeApiClient.tv,
        yt.YoutubeApiClient.mweb,
      ],
    );
    final hlsMuxed = manifest.hls.whereType<yt.HlsMuxedStreamInfo>().toList()
      ..sort((left, right) => right.bitrate.compareTo(left.bitrate));
    if (hlsMuxed.isNotEmpty) {
      return hlsMuxed.first.url.toString();
    }
    if (manifest.muxed.isNotEmpty) {
      final muxed = manifest.muxed.toList()
        ..sort((left, right) => right.bitrate.compareTo(left.bitrate));
      return muxed.first.url.toString();
    }
    if (manifest.hls.isNotEmpty) {
      final hls = manifest.hls.toList()
        ..sort((left, right) => right.bitrate.compareTo(left.bitrate));
      return hls.first.url.toString();
    }
    throw StateError('YouTube no entrego un stream reproducible.');
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

  Future<void> _disposeFallbackVideoController() async {
    final controller = _fallbackVideoController;
    _fallbackVideoController = null;
    _usingFallbackVideo = false;
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (_) {}
    }
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
    await _hideDesktopWebViewController(_webViewController);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(resolvedDetailUrl);
  }

  @override
  void dispose() {
    _openTicket += 1;
    final player = _player;
    final playerCompletedSubscription = _playerCompletedSubscription;
    final fallbackVideo = _fallbackVideoController;
    final webViewController = _webViewController;
    final youtube = _youtube;
    _player = null;
    _videoController = null;
    _playerCompletedSubscription = null;
    _fallbackVideoController = null;
    _webViewController = null;
    _youtube = null;
    if (player != null) {
      unawaited(player.dispose());
    }
    if (playerCompletedSubscription != null) {
      unawaited(playerCompletedSubscription.cancel());
    }
    if (fallbackVideo != null) {
      unawaited(fallbackVideo.dispose());
    }
    _disposeDesktopWebViewController(webViewController);
    youtube?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final title = current?.title.trim().isNotEmpty == true
        ? current!.title.trim()
        : widget.title;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_usingWebView && _webViewController != null)
            Positioned.fill(
                child: WebViewWidget(controller: _webViewController!))
          else if (_usingFallbackVideo && _fallbackVideoController != null)
            Positioned.fill(
              child: Center(
                child: AspectRatio(
                  aspectRatio: _fallbackVideoController!.value.aspectRatio > 0
                      ? _fallbackVideoController!.value.aspectRatio
                      : 16 / 9,
                  child: vp.VideoPlayer(_fallbackVideoController!),
                ),
              ),
            )
          else if (_videoController != null)
            Positioned.fill(
              child: Video(
                controller: _videoController!,
                fit: BoxFit.contain,
              ),
            ),
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
            child: Container(
              color: const Color(0x96000000),
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  _TrailerIconButton(
                    icon: Icons.arrow_back,
                    tooltip: 'Volver',
                    onPressed: () => unawaited(_closeTrailerQueue()),
                  ),
                  const SizedBox(width: 10),
                  _TrailerIconButton(
                    icon: Icons.skip_previous,
                    tooltip: 'Trailer anterior',
                    onPressed: _index <= 0 ? null : () => _move(-1),
                  ),
                  const SizedBox(width: 10),
                  _TrailerIconButton(
                    icon: Icons.skip_next,
                    tooltip: 'Trailer siguiente',
                    onPressed: _index >= widget.entries.length - 1
                        ? null
                        : () => _move(1),
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
                  _TrailerIconButton(
                    icon: Icons.refresh,
                    tooltip: 'Reintentar en app',
                    onPressed: _opening ? null : _openCurrentTrailer,
                  ),
                  const SizedBox(width: 10),
                  _TrailerIconButton(
                    icon: Icons.info_outline,
                    tooltip: 'Ver detalle',
                    onPressed: () => unawaited(_openTrailerDetail()),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _trailerPlaybackFailureMessage(String trailerUrl, Object error) {
  if (isYouTubeTrailerUrl(trailerUrl)) {
    return 'YouTube no entrego un stream reproducible para este trailer. '
        'Prueba Ver detalle.';
  }
  return error.toString();
}

Map<String, String> _trailerPlaybackHeaders(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.host.contains('googlevideo.com')) {
    return const {};
  }
  return const {
    'User-Agent': _trailerUserAgent,
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
  };
}

String _extractYouTubeVideoId(String trailerUrl) {
  final parsed = yt.VideoId.parseVideoId(trailerUrl);
  if (parsed != null) {
    return parsed;
  }
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

bool shouldOpenTrailerInWebViewFirst(
  String trailerUrl, {
  required TargetPlatform platform,
  bool isWeb = kIsWeb,
}) {
  return canUseEmbeddedTrailerWebView(platform: platform, isWeb: isWeb) &&
      isYouTubeTrailerUrl(trailerUrl) &&
      _extractYouTubeVideoId(trailerUrl).isNotEmpty;
}

bool shouldFallbackTrailerToWebView(
  String trailerUrl, {
  required TargetPlatform platform,
  bool isWeb = kIsWeb,
}) {
  return canUseEmbeddedTrailerWebView(platform: platform, isWeb: isWeb);
}

bool canUseFallbackTrailerVideoPlayer({
  required TargetPlatform platform,
  bool isWeb = kIsWeb,
}) {
  return !isWeb && platform != TargetPlatform.linux;
}

bool canUseFloatingDesktopTrailerWebView({
  required TargetPlatform platform,
  bool isWeb = kIsWeb,
}) {
  return !isWeb && platform == TargetPlatform.windows;
}

WebViewController _createTrailerWebViewController() {
  if (canUseFloatingDesktopTrailerWebView(
    platform: defaultTargetPlatform,
    isWeb: kIsWeb,
  )) {
    return WebViewController.fromPlatformCreationParams(
      const desktop_webview.WindowsWebViewControllerCreationParams(
        suspendDuringDeactive: false,
      ),
    );
  }
  return WebViewController();
}

Future<void> _hideDesktopWebViewController(
  WebViewController? controller,
) async {
  final platformController = controller?.platform;
  if (platformController is desktop_webview.WindowsPlatformWebViewController) {
    try {
      await platformController.controller.setVisibility(false);
    } catch (_) {}
  }
}

void _disposeDesktopWebViewController(WebViewController? controller) {
  final platformController = controller?.platform;
  if (platformController is desktop_webview.WindowsPlatformWebViewController) {
    unawaited(platformController.controller.dispose());
  }
}

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
    function notify(type, detail) {
      try {
        if (window.TanukiTrailerPlayer && TanukiTrailerPlayer.postMessage) {
          TanukiTrailerPlayer.postMessage(JSON.stringify({
            type: type,
            detail: detail || '',
            sessionId: sessionId
          }));
        }
      } catch (error) {}
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

    const titleEl = document.getElementById('title');
    const statusEl = document.getElementById('status');
    const previousButton = document.getElementById('previous');
    const nextButton = document.getElementById('next');

    function notify(type, detail) {
      try {
        if (window.TanukiTrailerPlayer && TanukiTrailerPlayer.postMessage) {
          TanukiTrailerPlayer.postMessage(JSON.stringify({
            type: type,
            detail: detail || '',
            sessionId: sessionId
          }));
        }
      } catch (error) {}
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
    function handleEnded() {
      if (index < entries.length - 1) {
        index += 1;
        loadCurrent();
      } else {
        notify('ended');
      }
    }
    document.getElementById('back').addEventListener('click', function() {
      notify('close');
    });
    previousButton.addEventListener('click', function() {
      move(-1);
    });
    nextButton.addEventListener('click', function() {
      move(1);
    });
    document.getElementById('detail').addEventListener('click', function() {
      const entry = currentEntry();
      notify('detail', entry ? entry.detailUrl : '');
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
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
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
