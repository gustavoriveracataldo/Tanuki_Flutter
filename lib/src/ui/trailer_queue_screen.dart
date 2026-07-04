import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../services/playback_backend.dart';
import 'toonami_theme.dart';

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
  WebViewController? _webViewController;
  yt.YoutubeExplode? _youtube;
  bool _openedInApp = false;
  bool _opening = false;
  bool _usingWebView = false;
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
    if (player == null || videoController == null) {
      if (_canUseWebTrailer) {
        await _openCurrentTrailerInWebView(entry, ticket);
        return;
      }
      setState(() {
        _openedInApp = false;
        _opening = false;
        _usingWebView = false;
        _status = 'Reproductor embebido no disponible.';
        _error = PlaybackBackend.initializationError.isNotEmpty
            ? PlaybackBackend.initializationError
            : 'No se pudo iniciar media_kit.';
      });
      return;
    }
    setState(() {
      _openedInApp = false;
      _opening = true;
      _usingWebView = false;
      _webViewController = null;
      _error = '';
      _status = 'Cargando trailer en la app...';
    });
    try {
      await videoController.platform.future;
      await player.stop();
      if (!mounted || ticket != _openTicket) {
        return;
      }
      final playableUrl = await _resolvePlayableTrailerUrl(entry.trailerUrl)
          .timeout(const Duration(seconds: 16));
      if (!mounted || ticket != _openTicket) {
        return;
      }
      await player
          .open(Media(playableUrl), play: true)
          .timeout(const Duration(seconds: 12));
      if (!mounted || ticket != _openTicket) {
        return;
      }
      setState(() {
        _openedInApp = true;
        _opening = false;
        _usingWebView = false;
        _status = 'Trailer en app';
      });
    } catch (error) {
      if (!mounted || ticket != _openTicket) {
        return;
      }
      try {
        await player.stop();
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
        _status = 'No se pudo reproducir en app.';
        _error = error.toString();
      });
    }
  }

  Future<void> _openCurrentTrailerInWebView(
    TrailerQueueEntry entry,
    int ticket,
  ) async {
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
              _status = 'No se pudo reproducir en app.';
              _error = error.description;
            });
          },
        ),
      );
    final androidController = controller.platform;
    if (androidController is AndroidWebViewController) {
      await androidController.setMediaPlaybackRequiresUserGesture(false);
    }
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
    final youtubeId = _extractYouTubeVideoId(entry.trailerUrl);
    final vimeoId = _extractVimeoVideoId(uri);
    try {
      if (youtubeId.isNotEmpty) {
        await controller.loadHtmlString(
          _buildYouTubeEmbedHtml(youtubeId),
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
      ytClients: [yt.YoutubeApiClient.androidSdkless, yt.YoutubeApiClient.ios],
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
    final youtube = _youtube;
    _player = null;
    _videoController = null;
    _webViewController = null;
    _youtube = null;
    if (player != null) {
      unawaited(player.dispose());
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
    'https://www.youtube-nocookie.com/embed/$safeId'
    '?autoplay=1&controls=1&rel=0&modestbranding=1&playsinline=1',
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
