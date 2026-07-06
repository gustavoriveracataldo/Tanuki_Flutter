import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart' as vp;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../services/playback_backend.dart';
import 'toonami_theme.dart';

const _trailerUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';

class TrailerQueueEntry {
  const TrailerQueueEntry({
    required this.title,
    required this.trailerUrl,
  });

  final String title;
  final String trailerUrl;
}

class TrailerQueueScreen extends StatefulWidget {
  const TrailerQueueScreen({
    super.key,
    required this.title,
    required this.entries,
  });

  final String title;
  final List<TrailerQueueEntry> entries;

  @override
  State<TrailerQueueScreen> createState() => _TrailerQueueScreenState();
}

class _TrailerQueueScreenState extends State<TrailerQueueScreen> {
  int _index = 0;
  String _status = 'Preparando trailer...';
  String _error = '';
  Player? _player;
  VideoController? _videoController;
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
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    try {
      PlaybackBackend.ensureInitialized();
    } catch (error) {
      _status = 'Reproductor embebido no disponible.';
      _error = error.toString();
    }
    if (PlaybackBackend.mediaKitAvailable) {
      final player = Player();
      _player = player;
      _videoController = VideoController(player);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_openCurrentTrailer());
      }
    });
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
    final uri = Uri.tryParse(entry.trailerUrl);
    if (uri == null || !uri.hasScheme) {
      setState(() {
        _status = 'URL de trailer no valida.';
        _error = entry.trailerUrl;
      });
      return;
    }
    final youtubeId = _extractYouTubeVideoId(entry.trailerUrl);
    final player = _player;
    final videoController = _videoController;
    if (_canUseWebTrailer && youtubeId.isEmpty) {
      await _openCurrentTrailerInWebView(entry, ticket);
      return;
    }
    setState(() {
      _openedInApp = false;
      _opening = true;
      _usingWebView = false;
      _usingFallbackVideo = false;
      _webViewController = null;
      _error = '';
      _status = 'Cargando trailer en la app...';
    });
    await _disposeFallbackVideoController();
    try {
      final playableUrl = await _resolvePlayableTrailerUrl(entry.trailerUrl)
          .timeout(const Duration(seconds: 16));
      if (!mounted || ticket != _openTicket) {
        return;
      }
      final openedWithFallback =
          await _openWithFallbackVideoPlayer(playableUrl, ticket);
      if (openedWithFallback || !mounted || ticket != _openTicket) {
        return;
      }
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
        if (player != null) {
          await player.stop();
        }
      } catch (_) {}
      if (!mounted || ticket != _openTicket) {
        return;
      }
      setState(() {
        _status = 'Probando trailer web...';
      });
      if (_canUseWebTrailer) {
        await _openCurrentTrailerInWebView(entry, ticket);
        return;
      }
      setState(() {
        _openedInApp = false;
        _opening = false;
        _usingWebView = false;
        _usingFallbackVideo = false;
        _status = 'No se pudo reproducir en app.';
        _error = error.toString();
      });
    }
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
    TrailerQueueEntry entry,
    int ticket,
  ) async {
    await _disposeFallbackVideoController();
    final uri = Uri.parse(entry.trailerUrl);
    final controller = WebViewController()
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
    final androidController = controller.platform;
    if (androidController is AndroidWebViewController) {
      await androidController.setMediaPlaybackRequiresUserGesture(false);
      await androidController.setUserAgent(_trailerUserAgent);
    }
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
    final youtubeId = _extractYouTubeVideoId(entry.trailerUrl);
    final vimeoId = _extractVimeoVideoId(uri);
    try {
      if (youtubeId.isNotEmpty) {
        await controller.loadHtmlString(
          _buildYouTubeEmbedHtml(youtubeId),
          baseUrl: 'https://www.youtube.com',
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
        _status = 'No se pudo reproducir en app.';
        _error = error.toString();
      });
    }
  }

  Future<String> _resolvePlayableTrailerUrl(String trailerUrl) async {
    final videoId = yt.VideoId.parseVideoId(trailerUrl);
    if (videoId == null) {
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

  Future<void> _openExternalTrailer() async {
    final entry = _current;
    final uri = entry == null ? null : Uri.tryParse(entry.trailerUrl);
    if (uri == null || !uri.hasScheme) {
      setState(() {
        _status = 'URL de trailer no valida.';
      });
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) {
      return;
    }
    setState(() {
      _status = opened ? 'Trailer externo' : 'No se pudo abrir el trailer.';
    });
  }

  @override
  void dispose() {
    _openTicket += 1;
    final player = _player;
    final fallbackVideo = _fallbackVideoController;
    final youtube = _youtube;
    _player = null;
    _videoController = null;
    _fallbackVideoController = null;
    _webViewController = null;
    _youtube = null;
    if (player != null) {
      unawaited(player.dispose());
    }
    if (fallbackVideo != null) {
      unawaited(fallbackVideo.dispose());
    }
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
                  aspectRatio:
                      _fallbackVideoController!.value.aspectRatio > 0
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
                            onPressed: _openExternalTrailer,
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Abrir externo'),
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
                    onPressed: () => Navigator.of(context).pop(),
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
                    icon: Icons.open_in_new,
                    tooltip: 'Abrir externo',
                    onPressed: _openExternalTrailer,
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
  return yt.VideoId.parseVideoId(trailerUrl) ?? '';
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

String _buildYouTubeEmbedHtml(String videoId) {
  final safeId = _escapeHtmlAttribute(videoId);
  return _buildTrailerEmbedHtml(
    'https://www.youtube.com/embed/$safeId'
    '?autoplay=1&controls=1&rel=0&modestbranding=1&playsinline=1'
    '&origin=https%3A%2F%2Fwww.youtube.com',
  );
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
