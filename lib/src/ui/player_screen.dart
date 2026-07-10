import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart' as vp;

import '../app_controller.dart';
import '../models.dart';
import '../services/playback_backend.dart';
import '../services/remote_hls_proxy.dart';
import 'toonami_theme.dart';

const _remotePlaybackUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';
const _remoteVideoFrameWatchdogDelay = Duration(seconds: 45);
const _remoteVideoFramePlaybackGrace = Duration(seconds: 35);
const _animeAv1PlaybackErrorFallbackDelay = Duration(seconds: 45);
const _playerOverlayAutoHideDelay = Duration(seconds: 5);
const _remoteSeekJumpThreshold = Duration(seconds: 45);
const _remoteSeekStallDelay = Duration(seconds: 11);
const _remoteOpeningRecoveryMaxAttempts = 1;
const _androidHardwareDecoderCodecs = 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1';
const _androidHardwareDecoderCodecsWithoutAv1 =
    'h264,hevc,mpeg4,mpeg2video,vp8,vp9';

enum _UpcomingCardPhase {
  none,
  next,
  later,
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.controller,
    required this.episode,
  });

  final AppController controller;
  final EpisodeItem episode;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  Player? _player;
  VideoController? _videoController;
  vp.VideoPlayerController? _androidExoController;
  RemoteHlsProxy? _remoteHlsProxy;
  String _status = 'Preparando reproductor...';
  String _error = '';
  bool _openedMedia = false;
  bool _completionCommitted = false;
  bool _androidExoCompletionHandled = false;
  bool _handlingAndroidExoError = false;
  bool _simklScrobbleActive = false;
  bool _subtitlesEnabled = true;
  bool _handlingPlaybackError = false;
  bool _playerOverlaysVisible = true;
  bool _playerControlsFocused = false;
  final FocusNode _playerControlsRootFocusNode =
      FocusNode(debugLabel: 'playerControlsRoot');
  final FocusNode _playerBackButtonFocusNode =
      FocusNode(debugLabel: 'playerBackButton');
  late VideoScaleMode _videoScaleMode;
  RemoteDirectStream? _currentResolvedStream;
  String _selectedRemoteSubtitleTrackKey = '';
  final Set<RemoteProvider> _failedRemoteProviders = <RemoteProvider>{};
  final Set<String> _failedRemoteServers = <String>{};
  RemoteProvider? _serverFallbackProvider;
  DateTime _lastPlaybackSave = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPositionChangeAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastLargePositionJumpAt;
  Duration _positionBeforeLastLargeJump = Duration.zero;
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;
  int _lastPositionDebugBucket = -1;
  int _lastBufferDebugBucket = -1;
  DateTime _lastAndroidExoRebuild = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, DateTime> _nativeLogLastPrintedAt = <String, DateTime>{};
  double _lastSimklScrobbleProgress = -1;
  Timer? _simklScrobbleTimer;
  Timer? _remoteVideoFrameWatchdogTimer;
  Timer? _remoteOpeningRecoveryTimer;
  Timer? _deferredAnimeAv1PlaybackErrorTimer;
  Timer? _playerOverlayHideTimer;
  Timer? _animeAv1SeekRecoveryTimer;
  Timer? _upcomingCardStartTimer;
  Timer? _upcomingCardSequenceTimer;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<String>? _playbackErrorSubscription;
  StreamSubscription<int?>? _videoWidthSubscription;
  StreamSubscription<int?>? _videoHeightSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<Duration>? _bufferSubscription;
  StreamSubscription<Track>? _trackSubscription;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<VideoParams>? _videoParamsSubscription;
  StreamSubscription<PlayerLog>? _nativeLogSubscription;
  bool _remotePlaybackAccepted = false;
  bool _remoteVideoFrameReady = false;
  bool _remoteVideoFrameFallbackHandled = false;
  int? _remoteVideoWidth;
  int? _remoteVideoHeight;
  int _remoteOpeningRecoveryAttempts = 0;
  String _deferredAnimeAv1PlaybackError = '';
  String _currentPlaybackPath = '';
  _UpcomingCardPhase _upcomingCardPhase = _UpcomingCardPhase.none;
  bool _startUpcomingCardsShown = false;
  bool _endUpcomingCardsShown = false;
  int _upcomingCardTicket = 0;

  @override
  void initState() {
    super.initState();
    _videoScaleMode =
        widget.controller.videoScaleModeForEpisode(widget.episode);
    if (!_usesAndroidExoPlayer && PlaybackBackend.mediaKitAvailable) {
      _player = Player();
      _videoController = VideoController(
        _player!,
        configuration: VideoControllerConfiguration(
          androidAttachSurfaceAfterVideoParameters:
              Platform.isAndroid ? false : null,
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_openEpisode());
    });
  }

  @override
  void dispose() {
    unawaited(_pauseSimklScrobble());
    _schedulePlaybackPersistAfterDispose();
    _simklScrobbleTimer?.cancel();
    _playerOverlayHideTimer?.cancel();
    _animeAv1SeekRecoveryTimer?.cancel();
    _remoteOpeningRecoveryTimer?.cancel();
    _upcomingCardStartTimer?.cancel();
    _upcomingCardSequenceTimer?.cancel();
    _playerControlsRootFocusNode.dispose();
    _playerBackButtonFocusNode.dispose();
    _cancelRemoteVideoFrameWatchdog();
    _cancelDeferredAnimeAv1PlaybackError();
    final positionSubscription = _positionSubscription;
    final durationSubscription = _durationSubscription;
    final completedSubscription = _completedSubscription;
    final playbackErrorSubscription = _playbackErrorSubscription;
    final bufferSubscription = _bufferSubscription;
    final trackSubscription = _trackSubscription;
    final tracksSubscription = _tracksSubscription;
    final videoParamsSubscription = _videoParamsSubscription;
    final nativeLogSubscription = _nativeLogSubscription;
    if (positionSubscription != null) {
      unawaited(positionSubscription.cancel());
    }
    if (durationSubscription != null) {
      unawaited(durationSubscription.cancel());
    }
    if (completedSubscription != null) {
      unawaited(completedSubscription.cancel());
    }
    if (playbackErrorSubscription != null) {
      unawaited(playbackErrorSubscription.cancel());
    }
    if (bufferSubscription != null) {
      unawaited(bufferSubscription.cancel());
    }
    if (trackSubscription != null) {
      unawaited(trackSubscription.cancel());
    }
    if (tracksSubscription != null) {
      unawaited(tracksSubscription.cancel());
    }
    if (videoParamsSubscription != null) {
      unawaited(videoParamsSubscription.cancel());
    }
    if (nativeLogSubscription != null) {
      unawaited(nativeLogSubscription.cancel());
    }
    _player?.dispose();
    final androidExoController = _androidExoController;
    if (androidExoController != null) {
      androidExoController.removeListener(_handleAndroidExoValue);
      unawaited(androidExoController.dispose());
    }
    unawaited(_remoteHlsProxy?.dispose());
    super.dispose();
  }

  bool get _usesAndroidExoPlayer =>
      Platform.isAndroid && widget.episode.isRemote;

  void _schedulePlaybackPersistAfterDispose() {
    final position = _lastPosition;
    final duration = _lastDuration;
    if (position <= Duration.zero && duration <= Duration.zero) {
      return;
    }
    final controller = widget.controller;
    final episode = widget.episode;
    Timer.run(() {
      unawaited(
        controller.saveEpisodePlayback(
          episode,
          position: position,
          duration: duration,
        ),
      );
    });
  }

  void _debugPlayerEvent(String message) {
    assert(() {
      debugPrint('PlayerScreen: $message');
      return true;
    }());
  }

  String _debugMediaLabel(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return value;
    }
    final path = uri.path;
    final compactPath = path.length > 48 ? '${path.substring(0, 48)}...' : path;
    return '${uri.scheme}://${uri.host}$compactPath';
  }

  String _debugHeadersLabel(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) {
      return '{}';
    }
    return '{${headers.entries.map((entry) {
      final name = entry.key;
      if (name.toLowerCase() == 'user-agent') {
        return '$name=<${entry.value.length} chars>';
      }
      return '$name=${_debugMediaLabel(entry.value)}';
    }).join(', ')}}';
  }

  String _debugShortText(String value, [int limit = 260]) {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.length <= limit) {
      return normalized;
    }
    return '${normalized.substring(0, limit)}...';
  }

  String _debugPlayerState(Player player) {
    final state = player.state;
    return 'playing=${state.playing} buffering=${state.buffering} '
        'position=${_formatPlaybackTime(state.position)} '
        'duration=${_formatPlaybackTime(state.duration)} '
        'size=${state.width ?? 0}x${state.height ?? 0}';
  }

  String _debugTrackLabel(dynamic track) {
    final id = '${track.id}'.trim();
    final codec = '${track.codec ?? ''}'.trim();
    final decoder = '${track.decoder ?? ''}'.trim();
    final title = '${track.title ?? ''}'.trim();
    final language = '${track.language ?? ''}'.trim();
    final size = track is VideoTrack && (track.w != null || track.h != null)
        ? ' ${track.w ?? 0}x${track.h ?? 0}'
        : '';
    return [
      if (id.isNotEmpty) 'id=$id',
      if (codec.isNotEmpty) 'codec=$codec',
      if (decoder.isNotEmpty) 'decoder=$decoder',
      if (title.isNotEmpty) 'title=$title',
      if (language.isNotEmpty) 'lang=$language',
      if (size.isNotEmpty) size.trim(),
    ].join(' ');
  }

  bool _shouldLogNativePlayerMessage(PlayerLog log) {
    final level = log.level.toLowerCase();
    if (level.contains('fatal') ||
        level.contains('error') ||
        level.contains('warn')) {
      return true;
    }
    final text = log.text.toLowerCase();
    return text.contains('http') ||
        text.contains('hls') ||
        text.contains('codec') ||
        text.contains('decoder') ||
        text.contains('video') ||
        text.contains('audio') ||
        text.contains('buffer') ||
        text.contains('seek') ||
        text.contains('timeout') ||
        text.contains('failed');
  }

  Future<void> _openEpisode() async {
    _debugPlayerEvent(
      'open start remote=${widget.episode.isRemote} '
      'episode="${widget.episode.displayName}"',
    );
    await widget.controller.setCurrentEntry(widget.episode);
    await _remoteHlsProxy?.dispose();
    _remoteHlsProxy = null;
    _cancelRemoteVideoFrameWatchdog();
    _resetUpcomingCards();
    var path = widget.episode.filePath.trim();
    _currentResolvedStream = null;
    _remotePlaybackAccepted = false;
    _remoteOpeningRecoveryAttempts = 0;
    _playerOverlaysVisible = true;
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _lastPositionChangeAt = DateTime.now();
    _lastPositionDebugBucket = -1;
    _lastBufferDebugBucket = -1;
    if (path.isEmpty) {
      setState(() {
        _error = 'El episodio no tiene una ruta reproducible.';
        _status = 'Sin ruta';
      });
      return;
    }

    if (widget.episode.isRemote && !_looksLikeDirectVideo(path)) {
      setState(() {
        _status = 'Resolviendo fuente remota...';
        _error = '';
      });
      final resolved = await widget.controller.resolveRemoteDirectStream(
        widget.episode,
        excludedProviders: _failedRemoteProviders,
        excludedRemoteServers: _failedRemoteServers,
        excludedRemoteServersProvider: _serverFallbackProvider,
      );
      if (resolved != null && resolved.playbackUrl.isNotEmpty) {
        _currentResolvedStream = resolved;
        _reconcileRemoteSubtitleSelection(resolved);
        path = resolved.playbackUrl;
        _debugPlayerEvent(
          'resolved provider=${resolved.provider?.id ?? 'unknown'} '
          'mode=${resolved.selectedMode} kind=${resolved.playbackKind} '
          'server=${resolved.server} url=${_debugMediaLabel(path)}',
        );
        if (mounted) {
          setState(() {
            _status =
                'Stream ${resolved.playbackKind.toUpperCase()} (${resolved.selectedMode})';
          });
        }
      } else if (resolved != null &&
          resolved.playbackUrl.isEmpty &&
          await _retryRemoteServerResolveMiss(resolved)) {
        return;
      } else {
        if (!mounted) {
          return;
        }
        if (_failedRemoteServers.isNotEmpty &&
            _serverFallbackProvider != null &&
            _failedRemoteProviders.add(_serverFallbackProvider!)) {
          _failedRemoteServers.clear();
          _serverFallbackProvider = null;
          setState(() {
            _status = 'Probando otra fuente remota...';
            _error = '';
          });
          await _openEpisode();
          return;
        }
        if (await _retryRemoteProviderResolveMiss()) {
          return;
        }
        if (_failedRemoteProviders.isNotEmpty) {
          setState(() {
            _error =
                'No encontre otra fuente remota directa para este episodio.';
            _status = 'Sin fuente alternativa';
          });
          return;
        }
        setState(() {
          _error =
              'No encontre un stream directo HLS, DASH o MP4 para este episodio.';
          _status = 'Resolver remoto pendiente';
        });
        return;
      }
    }

    if (widget.episode.isRemote && !_looksLikeDirectVideo(path)) {
      setState(() {
        _error =
            'Esta entrada remota necesita resolver web antes de entregar HLS, DASH o MP4.';
        _status = 'Resolver remoto pendiente';
      });
      return;
    }

    if (_usesAndroidExoPlayer) {
      await _openAndroidExoPlayer(path);
      return;
    }

    final player = _player;
    final videoController = _videoController;
    if (player == null || videoController == null) {
      if (Platform.isLinux) {
        await _openLinuxExternal(path, reason: _linuxFallbackReason());
      } else if (mounted) {
        setState(() {
          _error = 'No se pudo iniciar el reproductor embebido.';
          _status = 'Error de reproduccion';
        });
      }
      return;
    }

    try {
      await videoController.platform.future;
      await _configureAndroidHardwareDecoding(player);
      _attachPlaybackTracking(player);
      final resumePosition =
          widget.controller.resumePositionForEpisode(widget.episode);
      final startPosition = initialMediaStartPosition(
        resumePosition: resumePosition,
        canStartAtPosition: _shouldUseStartPositionForPath(path),
      );
      final mediaHeaders = _remoteMediaHeaders(path);
      if (shouldProxyZillaHls(path)) {
        final proxy = RemoteHlsProxy();
        _remoteHlsProxy = proxy;
        path = await proxy.start(path, headers: mediaHeaders);
        _debugPlayerEvent('using local HLS compatibility proxy');
      }
      _currentPlaybackPath = path;
      _debugPlayerEvent(
        'player.open url=${_debugMediaLabel(path)} '
        'resume=${resumePosition == null ? 'none' : _formatPlaybackTime(resumePosition)} '
        'start=${startPosition == null ? 'none' : _formatPlaybackTime(startPosition)} '
        'headers=${_debugHeadersLabel(mediaHeaders)}',
      );
      await _openPlayerMedia(
        player,
        path: path,
        headers: mediaHeaders,
        start: startPosition,
      );
      _debugPlayerEvent('player.open returned ${_debugPlayerState(player)}');
      unawaited(_applyRemoteSubtitleTrack(player));
      if (resumePosition != null && !_shouldUseStartPositionForPath(path)) {
        await player.seek(resumePosition);
        _lastPosition = resumePosition;
        _lastPositionChangeAt = DateTime.now();
      } else {
        _lastPosition = startPosition ?? Duration.zero;
        _lastPositionChangeAt = DateTime.now();
      }
      _attachPlaybackErrorFallback(player);
      _attachRemoteVideoFrameWatchdog(player);
      _scheduleRemoteOpeningRecovery(resumePosition ?? startPosition);
      _startSimklScrobble();
      if (!mounted) {
        return;
      }
      setState(() {
        _openedMedia = true;
        _status = resumePosition == null
            ? widget.episode.isRemote
                ? 'Reproduciendo'
                : 'Reproduccion local'
            : 'Reanudado en ${_formatPlaybackTime(resumePosition)}';
      });
      _scheduleOpeningUpcomingCards();
      _schedulePlayerOverlayHide();
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (await _retryRemoteFallback('$error')) {
        return;
      }
      if (Platform.isLinux) {
        await _openLinuxExternal(
          path,
          reason:
              'No se pudo iniciar video embebido en Linux. Use el reproductor predeterminado del sistema.',
        );
        return;
      }
      setState(() {
        _error = 'No se pudo abrir el video: $error';
        _status = 'Error de reproduccion';
      });
    }
  }

  Future<void> _openAndroidExoPlayer(String path) async {
    final previous = _androidExoController;
    if (previous != null) {
      previous.removeListener(_handleAndroidExoValue);
      await previous.dispose();
    }
    _androidExoController = null;
    _androidExoCompletionHandled = false;
    _handlingAndroidExoError = false;

    final headers = _remoteMediaHeaders(path) ?? const <String, String>{};
    final formatHint =
        (_currentResolvedStream?.playbackKind.toLowerCase() == 'hls' ||
                path.toLowerCase().contains('.m3u8') ||
                path.toLowerCase().contains('/m3u8/'))
            ? vp.VideoFormat.hls
            : null;
    final controller = vp.VideoPlayerController.networkUrl(
      Uri.parse(path),
      formatHint: formatHint,
      httpHeaders: headers,
      videoPlayerOptions: vp.VideoPlayerOptions(
        mixWithOthers: false,
        allowBackgroundPlayback: false,
      ),
    );
    _androidExoController = controller;
    controller.addListener(_handleAndroidExoValue);
    _debugPlayerEvent(
      'ExoPlayer open url=${_debugMediaLabel(path)} '
      'format=${formatHint?.name ?? 'auto'} '
      'headers=${_debugHeadersLabel(headers)}',
    );

    try {
      await controller.initialize().timeout(const Duration(seconds: 30));
      final resumePosition =
          widget.controller.resumePositionForEpisode(widget.episode);
      await controller.seekTo(resumePosition ?? Duration.zero);
      _lastPosition = resumePosition ?? Duration.zero;
      _lastDuration = controller.value.duration;
      _lastPositionChangeAt = DateTime.now();
      await _applyAndroidExoSubtitleTrack();
      await controller.play();
      _remotePlaybackAccepted = true;
      _startSimklScrobble();
      if (!mounted || _androidExoController != controller) {
        return;
      }
      setState(() {
        _openedMedia = true;
        _error = '';
        _status = resumePosition == null
            ? 'Reproduciendo con ExoPlayer'
            : 'Reanudado en ${_formatPlaybackTime(resumePosition)}';
      });
      _scheduleOpeningUpcomingCards();
      _schedulePlayerOverlayHide();
    } catch (error) {
      controller.removeListener(_handleAndroidExoValue);
      await controller.dispose();
      if (_androidExoController == controller) {
        _androidExoController = null;
      }
      if (!mounted) {
        return;
      }
      if (await _retryRemoteFallback('ExoPlayer: $error')) {
        return;
      }
      setState(() {
        _error = 'No se pudo abrir el video con ExoPlayer: $error';
        _status = 'Error de reproduccion';
      });
    }
  }

  void _handleAndroidExoValue() {
    final controller = _androidExoController;
    if (controller == null) {
      return;
    }
    final value = controller.value;
    if (value.hasError && _openedMedia && !_handlingAndroidExoError) {
      _handlingAndroidExoError = true;
      unawaited(_handleAndroidExoError(value.errorDescription ?? 'Error'));
      return;
    }
    if (!value.isInitialized) {
      return;
    }
    final previous = _lastPosition;
    _lastPosition = value.position;
    _lastDuration = value.duration;
    if (value.position != previous) {
      _lastPositionChangeAt = DateTime.now();
      _remotePlaybackAccepted = true;
    }
    _maybeScheduleUpcomingCards(value.position);
    _persistPlaybackThrottled();

    if (value.isCompleted && !_androidExoCompletionHandled) {
      _androidExoCompletionHandled = true;
      unawaited(_commitPlaybackCompletion());
      if (mounted) {
        unawaited(_playNext());
      }
    }

    final now = DateTime.now();
    if (mounted &&
        now.difference(_lastAndroidExoRebuild) >=
            const Duration(milliseconds: 250)) {
      _lastAndroidExoRebuild = now;
      setState(() {});
    }
  }

  Future<void> _handleAndroidExoError(String error) async {
    _debugPlayerEvent('ExoPlayer error: $error');
    try {
      final retrying = await _retryRemoteFallback(error);
      if (!retrying && mounted) {
        setState(() {
          _error = 'No se pudo reproducir el video remoto: $error';
          _status = 'Error de reproduccion';
        });
      }
    } finally {
      _handlingAndroidExoError = false;
    }
  }

  Future<void> _toggleAndroidExoPlayback() async {
    final controller = _androidExoController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      if (controller.value.isCompleted) {
        await controller.seekTo(Duration.zero);
        _androidExoCompletionHandled = false;
      }
      await controller.play();
    }
    _showPlayerOverlays();
  }

  Future<void> _seekAndroidExoPlayer(Duration target) async {
    final controller = _androidExoController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    await controller.seekTo(target);
    _lastPosition = target;
    _lastPositionChangeAt = DateTime.now();
    _androidExoCompletionHandled = false;
    unawaited(_persistPlayback(force: true));
    _showPlayerOverlays();
  }

  Future<void> _applyAndroidExoSubtitleTrack() async {
    final controller = _androidExoController;
    if (controller == null) {
      return;
    }
    if (!_subtitlesEnabled) {
      await controller.setClosedCaptionFile(null);
      return;
    }
    _reconcileRemoteSubtitleSelection(_currentResolvedStream);
    final track = selectRemoteSubtitleTrack(
      _currentResolvedStream,
      selectedKey: _selectedRemoteSubtitleTrackKey,
    );
    if (track == null) {
      await controller.setClosedCaptionFile(null);
      return;
    }
    _selectedRemoteSubtitleTrackKey = remoteSubtitleTrackKey(track);
    await controller.setClosedCaptionFile(_loadAndroidExoCaption(track));
  }

  Future<vp.ClosedCaptionFile> _loadAndroidExoCaption(
    RemoteSubtitleTrack track,
  ) async {
    final response = await http.get(
      Uri.parse(track.url),
      headers: _remoteMediaHeaders(track.url),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Subtitle HTTP ${response.statusCode}',
        uri: Uri.parse(track.url),
      );
    }
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (track.url.toLowerCase().contains('.vtt') ||
        body.trimLeft().startsWith('WEBVTT')) {
      return vp.WebVTTCaptionFile(body);
    }
    return vp.SubRipCaptionFile(body);
  }

  void _attachPlaybackErrorFallback(Player player) {
    final playbackErrorSubscription = _playbackErrorSubscription;
    if (playbackErrorSubscription != null) {
      unawaited(playbackErrorSubscription.cancel());
    }
    if (!widget.episode.isRemote) {
      _playbackErrorSubscription = null;
      return;
    }
    _playbackErrorSubscription = player.stream.error.listen((error) {
      final trimmed = error.trim();
      if (trimmed.isEmpty) {
        return;
      }
      _debugPlayerEvent(
        'player error "$trimmed" ${_debugPlayerState(player)}',
      );
      unawaited(_handleRemotePlaybackError(trimmed));
    });
  }

  Future<void> _handleRemotePlaybackError(
    String error, {
    bool forceImmediate = false,
  }) async {
    _debugPlayerEvent(
      'handle remote error force=$forceImmediate error="$error"',
    );
    if (_handlingPlaybackError || !mounted || !widget.episode.isRemote) {
      return;
    }
    if (_shouldKeepCurrentRemoteSource()) {
      setState(() {
        _error = '';
        _status = 'Reproduciendo';
      });
      return;
    }
    if (!forceImmediate && _deferAnimeAv1PlaybackError(error)) {
      return;
    }
    _handlingPlaybackError = true;
    try {
      final retrying = await _retryRemoteFallback(error);
      if (!retrying && mounted) {
        setState(() {
          _error = 'No se pudo reproducir el video remoto: $error';
          _status = 'Error de reproduccion';
        });
      }
    } finally {
      _handlingPlaybackError = false;
    }
  }

  Future<bool> _retryRemoteFallback(String reason) async {
    _debugPlayerEvent(
      'retry remote fallback requested reason="${_debugShortText(reason)}" '
      'streamProvider=${_currentResolvedStream?.provider?.id ?? 'none'} '
      'episodeProvider=${widget.episode.provider?.id ?? 'none'} '
      'failedProviders=${_failedRemoteProviders.map((p) => p.id).join(',')} '
      'failedServers=${_failedRemoteServers.join(',')}',
    );
    if (!mounted || !widget.episode.isRemote) {
      return false;
    }
    if (_shouldKeepCurrentRemoteSource()) {
      _debugPlayerEvent('fallback skipped because current source is accepted');
      return false;
    }
    _cancelDeferredAnimeAv1PlaybackError();
    final provider =
        _currentResolvedStream?.provider ?? widget.episode.provider;
    if (provider != null &&
        await _retryRemoteServerFallback(provider, reason)) {
      _debugPlayerEvent(
          'fallback will retry another server for ${provider.id}');
      return true;
    }
    if (provider == null ||
        provider == RemoteProvider.animeKai ||
        provider == RemoteProvider.animeFlv ||
        provider == RemoteProvider.catalog ||
        !_failedRemoteProviders.add(provider)) {
      _debugPlayerEvent(
        'fallback stopped provider=${provider?.id ?? 'none'}',
      );
      return false;
    }

    _cancelRemoteVideoFrameWatchdog();
    final playbackErrorSubscription = _playbackErrorSubscription;
    if (playbackErrorSubscription != null) {
      await playbackErrorSubscription.cancel();
      _playbackErrorSubscription = null;
    }
    await _pauseSimklScrobble();
    await _player?.stop();
    _openedMedia = false;
    _completionCommitted = false;
    if (!mounted) {
      return false;
    }
    final detail = reason.trim().isEmpty ? '' : ': ${reason.trim()}';
    setState(() {
      _error = '';
      _status = '${provider.label} fallo$detail. Probando otra fuente...';
    });
    await _openEpisode();
    return true;
  }

  Future<bool> _retryRemoteServerResolveMiss(RemoteDirectStream stream) async {
    _debugPlayerEvent(
      'server resolve miss provider=${stream.provider?.id ?? 'none'} '
      'server=${stream.server} modes=${stream.availableModes.join(',')}',
    );
    if (!mounted || !widget.episode.isRemote) {
      return false;
    }
    final provider = stream.provider ?? widget.episode.provider;
    final server = stream.server.trim();
    if (provider == null ||
        !_supportsRemoteServerFallback(provider) ||
        server.isEmpty ||
        !_failedRemoteServers.add(server)) {
      return false;
    }

    _serverFallbackProvider = provider;
    setState(() {
      _error = '';
      _status =
          '${provider.label} no resolvio ${remoteServerLabel(server)}. Probando otro servidor...';
    });
    await _openEpisode();
    return true;
  }

  Future<bool> _retryRemoteProviderResolveMiss() async {
    if (!mounted || !widget.episode.isRemote) {
      return false;
    }
    final provider = remoteProviderToExcludeAfterResolveMiss(
      episode: widget.episode,
      playbackProvider: widget.controller.playbackProviderForEpisode(
        widget.episode,
      ),
      failedProviders: _failedRemoteProviders,
    );
    if (provider == null || !_failedRemoteProviders.add(provider)) {
      _debugPlayerEvent('provider resolve miss has no next provider');
      return false;
    }
    _debugPlayerEvent('provider resolve miss excludes ${provider.id}');

    _failedRemoteServers.clear();
    _serverFallbackProvider = null;
    setState(() {
      _error = '';
      _status = '${provider.label} no entrego stream directo. '
          'Probando otra fuente...';
    });
    await _openEpisode();
    return true;
  }

  Future<bool> _retryRemoteServerFallback(
    RemoteProvider provider,
    String reason,
  ) async {
    _cancelDeferredAnimeAv1PlaybackError();
    final server = _currentResolvedStream?.server.trim() ?? '';
    _debugPlayerEvent(
      'server fallback check provider=${provider.id} server=$server '
      'reason="${_debugShortText(reason)}"',
    );
    if (!_supportsRemoteServerFallback(provider) ||
        server.isEmpty ||
        !_failedRemoteServers.add(server)) {
      _debugPlayerEvent('server fallback unavailable');
      return false;
    }

    _serverFallbackProvider = provider;
    _cancelRemoteVideoFrameWatchdog();
    final playbackErrorSubscription = _playbackErrorSubscription;
    if (playbackErrorSubscription != null) {
      await playbackErrorSubscription.cancel();
      _playbackErrorSubscription = null;
    }
    await _pauseSimklScrobble();
    await _player?.stop();
    _openedMedia = false;
    _completionCommitted = false;
    if (!mounted) {
      return false;
    }
    final detail = reason.trim().isEmpty ? '' : ': ${reason.trim()}';
    setState(() {
      _error = '';
      _status =
          'Fallo ${remoteServerLabel(server)}$detail. Probando otro servidor...';
    });
    await _openEpisode();
    return true;
  }

  void _attachRemoteVideoFrameWatchdog(Player player) {
    _cancelRemoteVideoFrameWatchdog();
    if (!_shouldWatchAnimeAv1VideoFrame()) {
      return;
    }
    _remoteVideoWidth = player.state.width;
    _remoteVideoHeight = player.state.height;
    if (_hasRemoteVideoFrame) {
      _markRemoteVideoFrameReady();
      return;
    }

    _videoWidthSubscription = player.stream.width.listen((width) {
      _remoteVideoWidth = width;
      _debugPlayerEvent('width=$width ${_debugPlayerState(player)}');
      if (_hasRemoteVideoFrame) {
        _markRemoteVideoFrameReady();
      }
    });
    _videoHeightSubscription = player.stream.height.listen((height) {
      _remoteVideoHeight = height;
      _debugPlayerEvent('height=$height ${_debugPlayerState(player)}');
      if (_hasRemoteVideoFrame) {
        _markRemoteVideoFrameReady();
      }
    });
    _playingSubscription = player.stream.playing.listen((playing) {
      _debugPlayerEvent('playing=$playing ${_debugPlayerState(player)}');
      if (playing) {
        _armRemoteVideoFrameWatchdog(player);
      } else {
        _remoteVideoFrameWatchdogTimer?.cancel();
        _remoteVideoFrameWatchdogTimer = null;
      }
    });
    _bufferingSubscription = player.stream.buffering.listen((buffering) {
      _debugPlayerEvent('buffering=$buffering ${_debugPlayerState(player)}');
    });
    if (player.state.playing) {
      _armRemoteVideoFrameWatchdog(player);
    }
  }

  void _armRemoteVideoFrameWatchdog(Player player) {
    if (_remoteVideoFrameReady ||
        _remoteVideoFrameFallbackHandled ||
        !_shouldWatchAnimeAv1VideoFrame()) {
      return;
    }
    if (_shouldKeepCurrentRemoteSource()) {
      return;
    }
    _remoteVideoFrameWatchdogTimer?.cancel();
    _remoteVideoFrameWatchdogTimer = Timer(
      _remoteVideoFrameWatchdogDelay,
      () {
        if (!mounted ||
            _remoteVideoFrameReady ||
            _remoteVideoFrameFallbackHandled ||
            !_shouldWatchAnimeAv1VideoFrame()) {
          return;
        }
        if (_hasRemoteVideoFrame) {
          _markRemoteVideoFrameReady();
          return;
        }
        final currentPlayer = _player;
        if (currentPlayer != player || currentPlayer == null) {
          return;
        }
        if (!shouldRetryMissingVideoFrame(
          isPlaying: currentPlayer.state.playing,
          isBuffering: currentPlayer.state.buffering,
          position: currentPlayer.state.position,
          width: _remoteVideoWidth,
          height: _remoteVideoHeight,
        )) {
          _armRemoteVideoFrameWatchdog(player);
          return;
        }
        _debugPlayerEvent(
          'missing video frame watchdog fallback ${_debugPlayerState(player)}',
        );
        _remoteVideoFrameFallbackHandled = true;
        unawaited(
          _retryRemoteFallback('AnimeAV1 reprodujo audio pero no video'),
        );
      },
    );
  }

  bool get _hasRemoteVideoFrame {
    return (_remoteVideoWidth ?? 0) > 0 && (_remoteVideoHeight ?? 0) > 0;
  }

  void _markRemoteVideoFrameReady() {
    _remoteVideoFrameReady = true;
    _remotePlaybackAccepted = true;
    _cancelDeferredAnimeAv1PlaybackError();
    _remoteVideoFrameWatchdogTimer?.cancel();
    _remoteVideoFrameWatchdogTimer = null;
    _remoteOpeningRecoveryTimer?.cancel();
    _remoteOpeningRecoveryTimer = null;
    _debugPlayerEvent(
      'video frame ready ${_remoteVideoWidth ?? 0}x${_remoteVideoHeight ?? 0}',
    );
  }

  bool _shouldKeepCurrentRemoteSource() {
    if (_shouldWatchAnimeAv1VideoFrame() && !_hasRemoteVideoFrame) {
      return false;
    }
    return _remotePlaybackAccepted ||
        _remoteVideoFrameReady ||
        _hasRemoteVideoFrame;
  }

  void _cancelRemoteVideoFrameWatchdog() {
    _remoteVideoFrameWatchdogTimer?.cancel();
    _remoteVideoFrameWatchdogTimer = null;
    _remoteOpeningRecoveryTimer?.cancel();
    _remoteOpeningRecoveryTimer = null;
    final videoWidthSubscription = _videoWidthSubscription;
    final videoHeightSubscription = _videoHeightSubscription;
    final playingSubscription = _playingSubscription;
    final bufferingSubscription = _bufferingSubscription;
    if (videoWidthSubscription != null) {
      unawaited(videoWidthSubscription.cancel());
      _videoWidthSubscription = null;
    }
    if (videoHeightSubscription != null) {
      unawaited(videoHeightSubscription.cancel());
      _videoHeightSubscription = null;
    }
    if (playingSubscription != null) {
      unawaited(playingSubscription.cancel());
      _playingSubscription = null;
    }
    if (bufferingSubscription != null) {
      unawaited(bufferingSubscription.cancel());
      _bufferingSubscription = null;
    }
    _remoteVideoFrameReady = false;
    _remoteVideoFrameFallbackHandled = false;
    _remoteVideoWidth = null;
    _remoteVideoHeight = null;
  }

  bool _deferAnimeAv1PlaybackError(String error) {
    final player = _player;
    if (player == null ||
        !shouldDeferAnimeAv1PlaybackError(
          provider: _currentResolvedStream?.provider ?? widget.episode.provider,
          stream: _currentResolvedStream,
          isPlaying: player.state.playing,
          isBuffering: player.state.buffering,
          position: player.state.position,
          width: _remoteVideoWidth,
          height: _remoteVideoHeight,
        )) {
      return false;
    }

    _deferredAnimeAv1PlaybackError = error;
    if (mounted) {
      setState(() {
        _error = '';
        _status = 'AnimeAV1 cargando stream...';
      });
    }
    if (_deferredAnimeAv1PlaybackErrorTimer != null) {
      return true;
    }
    _deferredAnimeAv1PlaybackErrorTimer = Timer(
      _animeAv1PlaybackErrorFallbackDelay,
      () {
        final pendingError = _deferredAnimeAv1PlaybackError;
        _deferredAnimeAv1PlaybackError = '';
        _deferredAnimeAv1PlaybackErrorTimer = null;
        final currentPlayer = _player;
        if (!mounted ||
            pendingError.trim().isEmpty ||
            currentPlayer == null ||
            !_shouldWatchAnimeAv1VideoFrame() ||
            !shouldRetryDeferredAnimeAv1PlaybackError(
              isPlaying: currentPlayer.state.playing,
              isBuffering: currentPlayer.state.buffering,
              position: currentPlayer.state.position,
              width: _remoteVideoWidth,
              height: _remoteVideoHeight,
            )) {
          return;
        }
        unawaited(_handleRemotePlaybackError(
          pendingError,
          forceImmediate: true,
        ));
      },
    );
    return true;
  }

  void _cancelDeferredAnimeAv1PlaybackError() {
    _deferredAnimeAv1PlaybackErrorTimer?.cancel();
    _deferredAnimeAv1PlaybackErrorTimer = null;
    _deferredAnimeAv1PlaybackError = '';
  }

  bool _shouldWatchAnimeAv1VideoFrame() {
    final provider =
        _currentResolvedStream?.provider ?? widget.episode.provider;
    return shouldWatchAnimeAv1VideoFrame(provider, _currentResolvedStream);
  }

  bool _supportsRemoteServerFallback(RemoteProvider provider) {
    return provider == RemoteProvider.jkAnime ||
        provider == RemoteProvider.latAnime;
  }

  Map<String, String>? _remoteMediaHeaders(String path) {
    final uri = Uri.tryParse(path);
    if (uri == null || !uri.hasScheme || uri.scheme == 'file') {
      return null;
    }
    final resolvedReferer = _currentResolvedStream?.pageUrl.trim() ?? '';
    final referer = resolvedReferer.isNotEmpty
        ? resolvedReferer
        : widget.episode.watchUrl.trim().isNotEmpty
            ? widget.episode.watchUrl.trim()
            : widget.episode.filePath.trim();
    final refererUri = Uri.tryParse(referer);
    final origin =
        refererUri != null && refererUri.hasScheme ? refererUri.origin : '';
    final headers = {
      'User-Agent': _remotePlaybackUserAgent,
      if (referer.isNotEmpty) 'Referer': referer,
      if (origin.isNotEmpty) 'Origin': origin,
    };
    for (final entry in _currentResolvedStream?.httpHeaders.entries ??
        const Iterable<MapEntry<String, String>>.empty()) {
      final name = entry.key.trim();
      final value = entry.value.trim();
      if (name.isNotEmpty && value.isNotEmpty) {
        headers[name] = value;
      }
    }
    return headers;
  }

  Future<void> _reloadRemoteSource() async {
    if (!widget.episode.isRemote) {
      return;
    }
    _debugPlayerEvent('manual reload remote source');
    _failedRemoteProviders.clear();
    _failedRemoteServers.clear();
    _serverFallbackProvider = null;
    _currentResolvedStream = null;
    _cancelDeferredAnimeAv1PlaybackError();
    _openedMedia = false;
    _remotePlaybackAccepted = false;
    _completionCommitted = false;
    await _pauseSimklScrobble();
    final androidExoController = _androidExoController;
    if (androidExoController != null) {
      androidExoController.removeListener(_handleAndroidExoValue);
      await androidExoController.dispose();
      _androidExoController = null;
    }
    await _player?.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _error = '';
      _status = 'Resolviendo fuente remota...';
    });
    await _openEpisode();
  }

  Future<void> _openLinuxExternal(String path, {required String reason}) async {
    setState(() {
      _status = 'Reproductor externo';
      _error = reason;
    });
    await widget.controller.markEpisodePlayed(widget.episode);
    final uri = Uri.tryParse(path);
    if (uri != null && uri.hasScheme && uri.scheme != 'file') {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
  }

  void _attachPlaybackTracking(Player player) {
    final positionSubscription = _positionSubscription;
    final durationSubscription = _durationSubscription;
    final completedSubscription = _completedSubscription;
    final bufferSubscription = _bufferSubscription;
    final trackSubscription = _trackSubscription;
    final tracksSubscription = _tracksSubscription;
    final videoParamsSubscription = _videoParamsSubscription;
    final nativeLogSubscription = _nativeLogSubscription;
    if (positionSubscription != null) {
      unawaited(positionSubscription.cancel());
    }
    if (durationSubscription != null) {
      unawaited(durationSubscription.cancel());
    }
    if (completedSubscription != null) {
      unawaited(completedSubscription.cancel());
    }
    if (bufferSubscription != null) {
      unawaited(bufferSubscription.cancel());
    }
    if (trackSubscription != null) {
      unawaited(trackSubscription.cancel());
    }
    if (tracksSubscription != null) {
      unawaited(tracksSubscription.cancel());
    }
    if (videoParamsSubscription != null) {
      unawaited(videoParamsSubscription.cancel());
    }
    if (nativeLogSubscription != null) {
      unawaited(nativeLogSubscription.cancel());
    }
    _positionSubscription = player.stream.position.listen((position) {
      final previous = _lastPosition;
      _lastPosition = position;
      _lastPositionChangeAt = DateTime.now();
      final bucket = position.inSeconds ~/ 30;
      if (position > Duration.zero && bucket != _lastPositionDebugBucket) {
        _lastPositionDebugBucket = bucket;
        _debugPlayerEvent('progress ${_debugPlayerState(player)}');
      }
      if (widget.episode.isRemote && position > Duration.zero) {
        _remotePlaybackAccepted = true;
      }
      if (widget.episode.isRemote &&
          previous > Duration.zero &&
          position > const Duration(seconds: 3) &&
          _durationDistance(previous, position) >= _remoteSeekJumpThreshold) {
        _lastLargePositionJumpAt = DateTime.now();
        _positionBeforeLastLargeJump = previous;
        _debugPlayerEvent(
          'position jump ${_formatPlaybackTime(previous)} -> '
          '${_formatPlaybackTime(position)}',
        );
        _scheduleRemoteSeekRecovery(position);
      }
      _maybeScheduleUpcomingCards(position);
      _persistPlaybackThrottled();
    });
    _durationSubscription = player.stream.duration.listen((duration) {
      _lastDuration = duration;
      _debugPlayerEvent(
        'duration=${_formatPlaybackTime(duration)} ${_debugPlayerState(player)}',
      );
      _maybeScheduleUpcomingCards(_lastPosition);
      _persistPlaybackThrottled();
    });
    _completedSubscription = player.stream.completed.listen((completed) {
      _debugPlayerEvent(
        'completed=$completed ${_debugPlayerState(player)}',
      );
      if (completed) {
        if (shouldIgnoreRemoteCompletionAfterJump(
          isRemote: widget.episode.isRemote,
          jumpAt: _lastLargePositionJumpAt,
          positionBeforeJump: _positionBeforeLastLargeJump,
          duration: _lastDuration,
          now: DateTime.now(),
        )) {
          _debugPlayerEvent('ignored completion after anomalous position jump');
          return;
        }
        unawaited(_commitPlaybackCompletion());
        if (mounted) {
          unawaited(_playNext());
        }
      }
    });
    _bufferSubscription = player.stream.buffer.listen((buffer) {
      final bucket = buffer.inSeconds ~/ 30;
      if (bucket == _lastBufferDebugBucket) {
        return;
      }
      _lastBufferDebugBucket = bucket;
      _debugPlayerEvent(
        'buffer=${_formatPlaybackTime(buffer)} ${_debugPlayerState(player)}',
      );
    });
    _trackSubscription = player.stream.track.listen((track) {
      _debugPlayerEvent(
        'selected tracks video=[${_debugTrackLabel(track.video)}] '
        'audio=[${_debugTrackLabel(track.audio)}] '
        'subtitle=[${_debugTrackLabel(track.subtitle)}]',
      );
    });
    _tracksSubscription = player.stream.tracks.listen((tracks) {
      _debugPlayerEvent(
        'available tracks video=${tracks.video.length} '
        'audio=${tracks.audio.length} subtitle=${tracks.subtitle.length} '
        'firstVideo=[${tracks.video.isEmpty ? '' : _debugTrackLabel(tracks.video.first)}]',
      );
    });
    _videoParamsSubscription = player.stream.videoParams.listen((params) {
      _debugPlayerEvent('video params $params ${_debugPlayerState(player)}');
    });
    _nativeLogSubscription = player.stream.log.listen((log) {
      if (!_shouldLogNativePlayerMessage(log)) {
        return;
      }
      final throttleKey = _nativeLogThrottleKey(log);
      final now = DateTime.now();
      final lastPrintedAt = _nativeLogLastPrintedAt[throttleKey];
      if (lastPrintedAt != null &&
          now.difference(lastPrintedAt) < const Duration(seconds: 5)) {
        return;
      }
      _nativeLogLastPrintedAt[throttleKey] = now;
      _debugPlayerEvent(
        'native ${log.level}/${log.prefix}: ${_debugShortText(log.text)}',
      );
    });
  }

  void _persistPlaybackThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastPlaybackSave).inSeconds < 10) {
      return;
    }
    _lastPlaybackSave = now;
    unawaited(_persistPlayback());
  }

  Future<void> _persistPlayback({
    bool force = false,
    bool completed = false,
  }) async {
    if (!_openedMedia && !force && !completed) {
      return;
    }
    if (!completed &&
        _lastPosition <= Duration.zero &&
        _lastDuration <= Duration.zero) {
      return;
    }
    await widget.controller.saveEpisodePlayback(
      widget.episode,
      position: _lastPosition,
      duration: _lastDuration,
      completed: completed,
    );
  }

  Future<void> _commitPlaybackCompletion() async {
    if (_completionCommitted) {
      return;
    }
    _completionCommitted = true;
    await _persistPlayback(force: true, completed: true);
    await _stopSimklScrobble();
  }

  void _startSimklScrobble() {
    if (_simklScrobbleActive) {
      return;
    }
    _simklScrobbleActive = true;
    _lastSimklScrobbleProgress = -1;
    unawaited(_sendSimklScrobble('start', force: true));
    _simklScrobbleTimer?.cancel();
    _simklScrobbleTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_sendSimklScrobble('start'));
    });
  }

  Future<void> _pauseSimklScrobble() async {
    if (!_simklScrobbleActive) {
      return;
    }
    _simklScrobbleTimer?.cancel();
    _simklScrobbleTimer = null;
    await _sendSimklScrobble('pause', force: true);
    _simklScrobbleActive = false;
  }

  Future<void> _stopSimklScrobble() async {
    if (!_simklScrobbleActive) {
      return;
    }
    _simklScrobbleTimer?.cancel();
    _simklScrobbleTimer = null;
    await _sendSimklScrobble('stop', force: true, completed: true);
    _simklScrobbleActive = false;
  }

  Future<void> _sendSimklScrobble(
    String action, {
    bool force = false,
    bool completed = false,
  }) async {
    if (_lastDuration <= Duration.zero) {
      return;
    }
    final progress = completed
        ? 100.0
        : (_lastPosition.inMilliseconds / _lastDuration.inMilliseconds * 100)
            .clamp(0, 100)
            .toDouble();
    if (!force && (progress - _lastSimklScrobbleProgress).abs() < 1) {
      return;
    }
    _lastSimklScrobbleProgress = progress;
    await widget.controller.sendSimklScrobble(
      widget.episode,
      position: completed ? _lastDuration : _lastPosition,
      duration: _lastDuration,
      action: action,
    );
  }

  String _formatPlaybackTime(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${duration.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Duration _durationDistance(Duration left, Duration right) {
    final diff = left.inMilliseconds - right.inMilliseconds;
    return Duration(milliseconds: diff < 0 ? -diff : diff);
  }

  String _linuxFallbackReason() {
    final details = PlaybackBackend.initializationError;
    if (details.isEmpty) {
      return 'Linux usa el reproductor predeterminado del sistema porque el backend embebido no esta disponible.';
    }
    return 'Linux usa el reproductor predeterminado del sistema porque no se pudo iniciar media_kit: $details';
  }

  _PlayerSourceStatus _sourceStatus() {
    final hasError = _error.trim().isNotEmpty ||
        _status.toLowerCase().contains('error') ||
        _status.toLowerCase().contains('fallo');
    final loading = !_openedMedia &&
        !hasError &&
        (_status.toLowerCase().contains('resolviendo') ||
            _status.toLowerCase().contains('probando') ||
            _status.toLowerCase().contains('cargando') ||
            _status.toLowerCase().contains('preparando'));
    final label =
        widget.episode.isRemote ? _remoteSourceLabel() : 'Local / Archivo';
    if (hasError) {
      return _PlayerSourceStatus(
        icon: Icons.error_outline,
        color: TanukiColors.danger,
        label: '$label / Error',
      );
    }
    if (loading) {
      return _PlayerSourceStatus(
        icon: Icons.sync,
        color: TanukiColors.amber,
        label: '$label / Cargando',
      );
    }
    return _PlayerSourceStatus(
      icon: _openedMedia ? Icons.play_arrow : Icons.sync,
      color: _openedMedia ? TanukiColors.cyan : TanukiColors.amber,
      label: label,
    );
  }

  String _remoteSourceLabel() {
    final stream = _currentResolvedStream;
    final provider = stream?.provider ??
        widget.controller.playbackProviderForEpisode(widget.episode) ??
        widget.episode.provider;
    if (provider == null || provider == RemoteProvider.catalog) {
      return 'Remoto / Automatico';
    }
    final detail = switch (provider) {
      RemoteProvider.animeAv1 => stream?.selectedMode.trim().isNotEmpty == true
          ? animeAv1PlaybackModeFromId(stream!.selectedMode).buttonLabel
          : widget.controller
              .animeAv1ModeForEpisode(widget.episode)
              .buttonLabel,
      RemoteProvider.jkAnime => stream?.server.trim().isNotEmpty == true
          ? remoteServerLabel(stream!.server)
          : widget.controller.jkAnimeServerForEpisode(widget.episode).label,
      RemoteProvider.latAnime => stream?.server.trim().isNotEmpty == true
          ? remoteServerLabel(stream!.server)
          : 'Servidor',
      RemoteProvider.facebook =>
        widget.controller.facebookModeForEpisode(widget.episode).buttonLabel,
      _ => '',
    };
    return detail.isEmpty ? provider.label : '${provider.label} / $detail';
  }

  void _resetUpcomingCards() {
    _upcomingCardTicket += 1;
    _upcomingCardStartTimer?.cancel();
    _upcomingCardStartTimer = null;
    _upcomingCardSequenceTimer?.cancel();
    _upcomingCardSequenceTimer = null;
    _upcomingCardPhase = _UpcomingCardPhase.none;
    _startUpcomingCardsShown = false;
    _endUpcomingCardsShown = false;
  }

  void _scheduleOpeningUpcomingCards() {
    if (_startUpcomingCardsShown ||
        !widget.controller.state.showPlaylistUpcomingCards ||
        _nextEntriesAfterCurrent().isEmpty) {
      return;
    }
    final ticket = _upcomingCardTicket;
    _upcomingCardStartTimer?.cancel();
    _upcomingCardStartTimer = Timer(const Duration(seconds: 30), () {
      _upcomingCardStartTimer = null;
      if (!mounted ||
          ticket != _upcomingCardTicket ||
          _startUpcomingCardsShown ||
          !widget.controller.state.showPlaylistUpcomingCards ||
          _nextEntriesAfterCurrent().isEmpty) {
        return;
      }
      _startUpcomingCardsShown = true;
      _runUpcomingCardSequence();
    });
  }

  void _maybeScheduleUpcomingCards(Duration position) {
    if (!widget.controller.state.showPlaylistUpcomingCards ||
        position < Duration.zero ||
        _upcomingCardPhase != _UpcomingCardPhase.none ||
        _upcomingCardSequenceTimer != null) {
      return;
    }
    if (_nextEntriesAfterCurrent().isEmpty) {
      return;
    }
    if (!_endUpcomingCardsShown &&
        _lastDuration > Duration.zero &&
        position >= const Duration(seconds: 30) &&
        _lastDuration - position <= const Duration(seconds: 30)) {
      _endUpcomingCardsShown = true;
      _runUpcomingCardSequence();
    }
  }

  void _runUpcomingCardSequence() {
    final ticket = ++_upcomingCardTicket;
    _upcomingCardStartTimer?.cancel();
    _upcomingCardStartTimer = null;
    _upcomingCardSequenceTimer?.cancel();
    _setUpcomingCardPhase(_UpcomingCardPhase.next);
    _upcomingCardSequenceTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || ticket != _upcomingCardTicket) {
        return;
      }
      if (_nextEntriesAfterCurrent().length < 2) {
        _upcomingCardSequenceTimer = null;
        _setUpcomingCardPhase(_UpcomingCardPhase.none);
        return;
      }
      _setUpcomingCardPhase(_UpcomingCardPhase.later);
      _upcomingCardSequenceTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted || ticket != _upcomingCardTicket) {
          return;
        }
        _upcomingCardSequenceTimer = null;
        _setUpcomingCardPhase(_UpcomingCardPhase.none);
      });
    });
  }

  void _setUpcomingCardPhase(_UpcomingCardPhase phase) {
    if (!mounted) {
      _upcomingCardPhase = phase;
      return;
    }
    if (_upcomingCardPhase == phase) {
      return;
    }
    setState(() {
      _upcomingCardPhase = phase;
    });
  }

  EpisodeItem? _visibleUpcomingCardEpisode(List<EpisodeItem> nextEntries) {
    return switch (_upcomingCardPhase) {
      _UpcomingCardPhase.next => nextEntries.isEmpty ? null : nextEntries.first,
      _UpcomingCardPhase.later =>
        nextEntries.length < 2 ? null : nextEntries[1],
      _ => null,
    };
  }

  List<EpisodeItem> _nextEntriesAfterCurrent() {
    return widget.controller
        .buildNextEntries(limit: 4)
        .where((entry) => !_isSameEpisode(entry, widget.episode))
        .take(2)
        .toList(growable: false);
  }

  bool _isSameEpisode(EpisodeItem left, EpisodeItem right) {
    final leftSeries = left.seriesStateKey.isNotEmpty
        ? left.seriesStateKey
        : normalizeSeriesKey(left.seriesName);
    final rightSeries = right.seriesStateKey.isNotEmpty
        ? right.seriesStateKey
        : normalizeSeriesKey(right.seriesName);
    return leftSeries == rightSeries &&
        left.episodeNumber == right.episodeNumber;
  }

  String _visibleUpcomingCardLabel() {
    return switch (_upcomingCardPhase) {
      _UpcomingCardPhase.later => 'Mas tarde',
      _ => 'A continuacion',
    };
  }

  Color _visibleUpcomingCardColor() {
    return switch (_upcomingCardPhase) {
      _UpcomingCardPhase.later => TanukiColors.cyan,
      _ => TanukiColors.amber,
    };
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final nextEntries = _nextEntriesAfterCurrent();
    final visibleUpcomingCard = _visibleUpcomingCardEpisode(nextEntries);
    final sourceStatus = _sourceStatus();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _playerControlsRootFocusNode,
        autofocus: true,
        onKeyEvent: _handlePlayerRootKey,
        child: Listener(
          onPointerDown: (_) => _showPlayerOverlays(),
          onPointerMove: (_) => _showPlayerOverlays(),
          onPointerHover: (_) => _showPlayerOverlays(),
          child: Stack(
            children: [
              Positioned.fill(
                child: _openedMedia &&
                        _androidExoController?.value.isInitialized == true
                    ? _AndroidExoVideoSurface(
                        controller: _androidExoController!,
                        fit: _boxFitForVideoScaleMode(_videoScaleMode),
                        subtitlesEnabled: _subtitlesEnabled,
                      )
                    : _openedMedia && _videoController != null
                        ? _TanukiVideoTheme(
                            child: Video(
                              controller: _videoController!,
                              fit: _boxFitForVideoScaleMode(_videoScaleMode),
                              subtitleViewConfiguration:
                                  SubtitleViewConfiguration(
                                visible: _subtitlesEnabled,
                              ),
                            ),
                          )
                        : _PlayerFallback(
                            episode: episode,
                            error: _error,
                          ),
              ),
              Positioned(
                left: 0,
                top: 0,
                right: 0,
                child: IgnorePointer(
                  ignoring: _openedMedia && !_playerOverlaysVisible,
                  child: AnimatedOpacity(
                    opacity: !_openedMedia || _playerOverlaysVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: _PlayerTopBar(
                      episode: episode,
                      status: sourceStatus.label,
                      statusIcon: sourceStatus.icon,
                      statusColor: sourceStatus.color,
                      onBack: () => Navigator.of(context).maybePop(),
                      onPrevious: _playPrevious,
                      onNext: _playNext,
                      subtitlesEnabled: _subtitlesEnabled,
                      videoScaleMode: _videoScaleMode,
                      onToggleSubtitles: _toggleSubtitles,
                      onToggleViewMode: _cycleVideoScaleMode,
                      onSettings: _showPlayerSettingsDialog,
                      onControlFocusChanged: _setPlayerControlsFocused,
                      backButtonFocusNode: _playerBackButtonFocusNode,
                    ),
                  ),
                ),
              ),
              if (widget.controller.state.showPlaylistUpcomingCards &&
                  visibleUpcomingCard != null)
                Positioned(
                  right: 18,
                  bottom: 24,
                  child: IgnorePointer(
                    ignoring: true,
                    child: AnimatedOpacity(
                      opacity: 1,
                      duration: const Duration(milliseconds: 220),
                      child: _UpcomingCard(
                        label: _visibleUpcomingCardLabel(),
                        labelColor: _visibleUpcomingCardColor(),
                        episode: visibleUpcomingCard,
                      ),
                    ),
                  ),
                ),
              if (_openedMedia &&
                  _androidExoController?.value.isInitialized == true)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 10,
                  child: IgnorePointer(
                    ignoring: !_playerOverlaysVisible,
                    child: AnimatedOpacity(
                      opacity: _playerOverlaysVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: _AndroidExoControls(
                        controller: _androidExoController!,
                        onTogglePlayback: _toggleAndroidExoPlayback,
                        onSeek: _seekAndroidExoPlayer,
                        formatTime: _formatPlaybackTime,
                        onFocusChanged: _setPlayerControlsFocused,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPlayerOverlays() {
    if (!mounted) {
      return;
    }
    if (!_playerOverlaysVisible) {
      setState(() {
        _playerOverlaysVisible = true;
      });
    }
    _schedulePlayerOverlayHide();
  }

  void _schedulePlayerOverlayHide() {
    _playerOverlayHideTimer?.cancel();
    if (!_openedMedia || _playerControlsFocused) {
      return;
    }
    _playerOverlayHideTimer = Timer(_playerOverlayAutoHideDelay, () {
      if (!mounted || !_openedMedia) {
        return;
      }
      setState(() {
        _playerOverlaysVisible = false;
      });
    });
  }

  void _setPlayerControlsFocused(bool focused) {
    if (!mounted) {
      return;
    }
    if (_playerControlsFocused != focused) {
      setState(() {
        _playerControlsFocused = focused;
        if (focused) {
          _playerOverlaysVisible = true;
        }
      });
    }
    if (focused) {
      _playerOverlayHideTimer?.cancel();
    } else {
      _schedulePlayerOverlayHide();
    }
  }

  KeyEventResult _handlePlayerRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isNavigationKey = key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA;
    if (isNavigationKey) {
      _showPlayerOverlays();
      if (!_playerControlsFocused) {
        _requestPlayerControlFocus();
      }
    }
    return KeyEventResult.ignored;
  }

  void _requestPlayerControlFocus() {
    if (!mounted) {
      return;
    }
    if (_playerBackButtonFocusNode.canRequestFocus) {
      _playerBackButtonFocusNode.requestFocus();
    }
  }

  bool _shouldUseStartPositionForPath(String path) {
    if (!widget.episode.isRemote) {
      return false;
    }
    final stream = _currentResolvedStream;
    if (stream != null && stream.playbackUrl.trim().isNotEmpty) {
      return true;
    }
    return _looksLikeDirectVideo(path);
  }

  Future<void> _configureAndroidHardwareDecoding(Player player) async {
    if (!Platform.isAndroid) {
      return;
    }
    final platform = player.platform;
    if (platform is! NativePlayer) {
      return;
    }
    final codecs = androidHardwareDecoderCodecs(
      disableAv1: _shouldWatchAnimeAv1VideoFrame(),
    );
    if (widget.episode.isRemote) {
      await platform.setProperty('cache-on-disk', 'no');
    }
    await platform.setProperty('rebase-start-time', 'yes');
    _debugPlayerEvent(
      'android hwdec-codecs=$codecs '
      'diskCache=${widget.episode.isRemote ? 'off' : 'default'}',
    );
    await platform.setProperty('hwdec-codecs', codecs);
  }

  Future<void> _openPlayerMedia(
    Player player, {
    required String path,
    required Map<String, String>? headers,
    required Duration? start,
  }) async {
    final stabilizeAndroidAv1 =
        Platform.isAndroid && _shouldWatchAnimeAv1VideoFrame();
    final videoReady = stabilizeAndroidAv1
        ? player.stream.videoParams
            .firstWhere(
              (params) =>
                  (params.dw ?? 0) > 0 &&
                  (params.dh ?? 0) > 0 &&
                  (params.pixelformat?.isNotEmpty ?? false),
            )
            .timeout(const Duration(seconds: 12))
        : null;
    await player.open(
      Media(path, httpHeaders: headers, start: start),
      play: !stabilizeAndroidAv1,
    );
    if (!stabilizeAndroidAv1) {
      return;
    }
    _debugPlayerEvent('waiting for Android AV1 video surface');
    try {
      await videoReady;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _seekPrecisely(player, start ?? Duration.zero);
      _debugPlayerEvent(
        'Android AV1 surface ready; seeked to '
        '${_formatPlaybackTime(start ?? Duration.zero)}',
      );
    } on TimeoutException {
      _debugPlayerEvent('Android AV1 video surface wait timed out');
    }
    await player.play();
    _debugPlayerEvent('Android AV1 playback started after surface setup');
  }

  Future<void> _seekPrecisely(Player player, Duration target) async {
    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.command([
        'seek',
        (target.inMilliseconds / 1000).toStringAsFixed(3),
        'absolute+exact',
      ]);
      return;
    }
    await player.seek(target);
  }

  String _nativeLogThrottleKey(PlayerLog log) {
    final text = log.text.toLowerCase();
    if (text.contains('obu_') ||
        text.contains('obu data') ||
        text.contains('temporal unit') ||
        text.contains('leb128') ||
        text.contains('out of range') ||
        text.contains('failed to read unit') ||
        text.contains('invalid obu')) {
      return '${log.prefix}:av1-parse';
    }
    return '${log.prefix}:${log.text.trim()}';
  }

  Duration _safeRemoteStartPosition(Duration position) {
    if (position <= const Duration(seconds: 2)) {
      return Duration.zero;
    }
    return position - const Duration(seconds: 2);
  }

  void _scheduleRemoteOpeningRecovery(Duration? target) {
    _remoteOpeningRecoveryTimer?.cancel();
    _remoteOpeningRecoveryTimer = null;
    if (target == null ||
        target <= Duration.zero ||
        !_shouldWatchAnimeAv1VideoFrame()) {
      return;
    }
    _debugPlayerEvent(
      'opening recovery armed target=${_formatPlaybackTime(target)}',
    );
    _remoteOpeningRecoveryTimer = Timer(_remoteSeekStallDelay, () {
      final player = _player;
      if (!mounted ||
          player == null ||
          !_openedMedia ||
          !widget.episode.isRemote ||
          !_shouldWatchAnimeAv1VideoFrame()) {
        return;
      }
      if (!shouldRecoverRemoteOpeningStall(
        isPlaying: player.state.playing,
        isBuffering: player.state.buffering,
        position: player.state.position,
        target: target,
        width: _remoteVideoWidth,
        height: _remoteVideoHeight,
      )) {
        _debugPlayerEvent(
          'opening recovery skipped ${_debugPlayerState(player)}',
        );
        return;
      }
      if (_remoteOpeningRecoveryAttempts >= _remoteOpeningRecoveryMaxAttempts) {
        _debugPlayerEvent(
          'opening recovery fallback after $_remoteOpeningRecoveryAttempts '
          'attempts ${_debugPlayerState(player)}',
        );
        unawaited(
          _retryRemoteFallback('AnimeAV1 no entrego video tras reanudar'),
        );
        return;
      }
      _remoteOpeningRecoveryAttempts += 1;
      _debugPlayerEvent(
        'opening recovery attempt $_remoteOpeningRecoveryAttempts '
        'target=${_formatPlaybackTime(target)} ${_debugPlayerState(player)}',
      );
      unawaited(_recoverRemoteSeek(target));
    });
  }

  void _scheduleRemoteSeekRecovery(Duration target) {
    _animeAv1SeekRecoveryTimer?.cancel();
    _remoteOpeningRecoveryAttempts = _remoteOpeningRecoveryMaxAttempts;
    _animeAv1SeekRecoveryTimer = Timer(_remoteSeekStallDelay, () {
      final player = _player;
      if (!mounted ||
          player == null ||
          !_openedMedia ||
          !widget.episode.isRemote) {
        return;
      }
      final stalled = DateTime.now().difference(_lastPositionChangeAt) >=
          _remoteSeekStallDelay;
      final nearTarget = _durationDistance(player.state.position, target) <=
          const Duration(seconds: 8);
      if (!stalled || !nearTarget) {
        return;
      }
      if (!player.state.buffering && !player.state.playing) {
        return;
      }
      _debugPlayerEvent(
        'seek recovery target=${_formatPlaybackTime(target)} '
        '${_debugPlayerState(player)}',
      );
      unawaited(_recoverRemoteSeek(target));
    });
    unawaited(_persistPlayback(force: true));
  }

  Future<void> _recoverRemoteSeek(Duration target) async {
    final player = _player;
    final path = _currentPlaybackPath.trim();
    if (player == null ||
        path.isEmpty ||
        !_shouldUseStartPositionForPath(path)) {
      return;
    }
    _remoteOpeningRecoveryTimer?.cancel();
    _remoteOpeningRecoveryTimer = null;
    if (mounted) {
      setState(() {
        _status = 'Recuperando stream...';
        _error = '';
      });
    }
    try {
      final start = _safeRemoteStartPosition(target);
      _debugPlayerEvent(
        'recover open url=${_debugMediaLabel(path)} '
        'target=${_formatPlaybackTime(target)} '
        'start=${_formatPlaybackTime(start)}',
      );
      await _openPlayerMedia(
        player,
        path: path,
        headers: _remoteMediaHeaders(path),
        start: start,
      );
      _lastPosition = start;
      _lastPositionChangeAt = DateTime.now();
      unawaited(_applyRemoteSubtitleTrack(player));
      _scheduleRemoteOpeningRecovery(target);
      if (mounted) {
        setState(() {
          _openedMedia = true;
          _status = 'Stream recuperado en ${_formatPlaybackTime(target)}';
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Stream sin respuesta tras seek';
        _error = error.toString();
      });
    }
  }

  Future<void> _applyRemoteSubtitleTrackIfReady() async {
    if (_usesAndroidExoPlayer) {
      await _applyAndroidExoSubtitleTrack();
      return;
    }
    final player = _player;
    if (player == null || !_openedMedia) {
      return;
    }
    await _applyRemoteSubtitleTrack(player);
  }

  Future<void> _applyRemoteSubtitleTrack(Player player) async {
    try {
      if (!_subtitlesEnabled) {
        _debugPlayerEvent('subtitle disabled: selecting no subtitle track');
        await player.setSubtitleTrack(SubtitleTrack.no());
        return;
      }
      _reconcileRemoteSubtitleSelection(_currentResolvedStream);
      final track = selectRemoteSubtitleTrack(
        _currentResolvedStream,
        selectedKey: _selectedRemoteSubtitleTrackKey,
      );
      if (track == null) {
        if (!widget.episode.isRemote) {
          _debugPlayerEvent('subtitle local auto track');
          await player.setSubtitleTrack(SubtitleTrack.auto());
        }
        _debugPlayerEvent('subtitle no remote track selected');
        return;
      }
      _selectedRemoteSubtitleTrackKey = remoteSubtitleTrackKey(track);
      _debugPlayerEvent(
        'subtitle selected ${remoteSubtitleTrackLabel(track)} '
        'url=${_debugMediaLabel(track.url)}',
      );
      await player.setSubtitleTrack(
        SubtitleTrack.uri(
          track.url,
          title: track.label.trim().isEmpty ? 'Subtitulos' : track.label.trim(),
          language:
              track.language.trim().isEmpty ? null : track.language.trim(),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'No se pudo cargar subtitulos';
      });
    }
  }

  void _reconcileRemoteSubtitleSelection(RemoteDirectStream? stream) {
    final tracks = stream?.subtitleTracks ?? const <RemoteSubtitleTrack>[];
    if (tracks.isEmpty) {
      _selectedRemoteSubtitleTrackKey = '';
      return;
    }
    final availableKeys = tracks.map(remoteSubtitleTrackKey).toSet();
    if (!availableKeys.contains(_selectedRemoteSubtitleTrackKey)) {
      final selectedTrack = selectRemoteSubtitleTrack(stream);
      _selectedRemoteSubtitleTrackKey =
          selectedTrack == null ? '' : remoteSubtitleTrackKey(selectedTrack);
    }
  }

  void _toggleSubtitles() {
    setState(() {
      _subtitlesEnabled = !_subtitlesEnabled;
      _status = _subtitlesEnabled
          ? 'Subtitulos activados'
          : 'Subtitulos desactivados';
    });
    unawaited(_applyRemoteSubtitleTrackIfReady());
  }

  Future<void> _cycleVideoScaleMode() async {
    await _setVideoScaleMode(_videoScaleMode.next);
  }

  Future<void> _setVideoScaleMode(VideoScaleMode mode) async {
    if (_videoScaleMode == mode) {
      return;
    }
    setState(() {
      _videoScaleMode = mode;
      _status = 'Vista del video: ${mode.dialogLabel}';
    });
    await widget.controller.setVideoScaleModeForEpisode(widget.episode, mode);
  }

  Future<void> _showPlayerSettingsDialog() async {
    _showPlayerOverlays();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        var preference =
            widget.controller.playbackPreferenceForEpisode(widget.episode);
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final normalizedSelectedProvider =
                widget.controller.playbackProviderForEpisode(widget.episode);
            final animeAv1Mode =
                animeAv1PlaybackModeFromId(preference.animeAv1Mode);
            final jkAnimeServer =
                jkAnimeServerPreferenceFromId(preference.jkAnimeServer);
            final facebookMode =
                facebookPlaybackModeFromId(preference.facebookMode);
            final facebookOption =
                facebookPlaybackOptionFromId(preference.facebookOption);
            final remoteSubtitleTracks =
                _currentResolvedStream?.subtitleTracks ??
                    const <RemoteSubtitleTrack>[];

            Future<void> savePreference(
              Future<void> Function() save, {
              bool reload = true,
            }) async {
              await save();
              if (!mounted || !dialogContext.mounted) {
                return;
              }
              setDialogState(() {
                preference = widget.controller
                    .playbackPreferenceForEpisode(widget.episode);
              });
              if (reload && widget.episode.isRemote) {
                await _reloadRemoteSource();
              }
            }

            final sourceButtons = <Widget>[
              _PlayerDialogButton(
                label: 'Automatico',
                active: preference.provider == null,
                onPressed: () => unawaited(
                  savePreference(
                    () => widget.controller
                        .setPlaybackProviderForEpisode(widget.episode, null),
                  ),
                ),
              ),
              for (final provider in [
                RemoteProvider.animeAv1,
                RemoteProvider.jkAnime,
                RemoteProvider.latAnime,
                if (widget.controller.canUsePlaybackProviderForEpisode(
                  widget.episode,
                  RemoteProvider.facebook,
                ))
                  RemoteProvider.facebook,
              ])
                _PlayerDialogButton(
                  label: provider.label,
                  active: preference.provider == provider,
                  onPressed: () => unawaited(
                    savePreference(
                      () => widget.controller.setPlaybackProviderForEpisode(
                        widget.episode,
                        provider,
                      ),
                    ),
                  ),
                ),
            ];

            final optionSections = <Widget>[
              const _PlayerDialogSectionTitle('Informacion'),
              const SizedBox(height: 10),
              Text(
                _sourcePreviewText(
                  normalizedSelectedProvider,
                  animeAv1Mode,
                  jkAnimeServer,
                  facebookMode,
                  facebookOption,
                ),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.35,
                      color: const Color(0xFFD8E1EB),
                    ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Switch(
                    value: _subtitlesEnabled,
                    onChanged: (value) {
                      setState(() {
                        _subtitlesEnabled = value;
                        _status = value
                            ? 'Subtitulos activados'
                            : 'Subtitulos desactivados';
                      });
                      unawaited(_applyRemoteSubtitleTrackIfReady());
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Subtitulos',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              if (remoteSubtitleTracks.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _PlayerDialogButton(
                      label: 'OFF',
                      active: !_subtitlesEnabled,
                      onPressed: () {
                        setState(() {
                          _subtitlesEnabled = false;
                          _status = 'Subtitulos desactivados';
                        });
                        unawaited(_applyRemoteSubtitleTrackIfReady());
                        setDialogState(() {});
                      },
                    ),
                    for (final track in remoteSubtitleTracks)
                      _PlayerDialogButton(
                        label: remoteSubtitleTrackLabel(track),
                        active: _subtitlesEnabled &&
                            _selectedRemoteSubtitleTrackKey ==
                                remoteSubtitleTrackKey(track),
                        onPressed: () {
                          setState(() {
                            _subtitlesEnabled = true;
                            _selectedRemoteSubtitleTrackKey =
                                remoteSubtitleTrackKey(track);
                            _status =
                                'Subtitulos: ${remoteSubtitleTrackLabel(track)}';
                          });
                          unawaited(_applyRemoteSubtitleTrackIfReady());
                          setDialogState(() {});
                        },
                      ),
                  ],
                ),
              ],
              if (normalizedSelectedProvider == RemoteProvider.animeAv1) ...[
                const SizedBox(height: 18),
                const _PlayerDialogSectionTitle('Modo'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mode in AnimeAv1PlaybackMode.values)
                      _PlayerDialogButton(
                        label: mode.dialogLabel,
                        active: animeAv1Mode == mode,
                        onPressed: () => unawaited(
                          savePreference(
                            () => widget.controller.setAnimeAv1ModeForEpisode(
                              widget.episode,
                              mode,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (normalizedSelectedProvider == RemoteProvider.jkAnime) ...[
                const SizedBox(height: 18),
                const _PlayerDialogSectionTitle('Servidor'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final server in JkAnimeServerPreference.values)
                      _PlayerDialogButton(
                        label: server.label,
                        active: jkAnimeServer == server,
                        onPressed: () => unawaited(
                          savePreference(
                            () => widget.controller.setJkAnimeServerForEpisode(
                              widget.episode,
                              server,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (normalizedSelectedProvider == RemoteProvider.facebook) ...[
                const SizedBox(height: 18),
                const _PlayerDialogSectionTitle('Modo'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mode in FacebookPlaybackMode.values)
                      _PlayerDialogButton(
                        label: mode.dialogLabel,
                        active: facebookMode == mode,
                        onPressed: () => unawaited(
                          savePreference(
                            () => widget.controller.setFacebookModeForEpisode(
                              widget.episode,
                              mode,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                const _PlayerDialogSectionTitle('Opcion'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in FacebookPlaybackOption.values)
                      _PlayerDialogButton(
                        label: option.label,
                        active: facebookOption == option,
                        onPressed: () => unawaited(
                          savePreference(
                            () => widget.controller.setFacebookOptionForEpisode(
                              widget.episode,
                              option,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ];

            return Dialog(
              backgroundColor: TanukiColors.panelSolid,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: TanukiColors.panelStroke),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 640;
                      final sourceColumn = SizedBox(
                        width: compact ? double.infinity : 188,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _PlayerDialogSectionTitle('Fuente'),
                            const SizedBox(height: 10),
                            ...sourceButtons.expand(
                              (button) => [
                                button,
                                const SizedBox(height: 8),
                              ],
                            ),
                          ],
                        ),
                      );
                      final optionColumn = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: optionSections,
                      );
                      if (compact) {
                        return SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              sourceColumn,
                              const SizedBox(height: 18),
                              optionColumn,
                            ],
                          ),
                        );
                      }
                      return IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            sourceColumn,
                            const SizedBox(width: 18),
                            Expanded(
                              child: SingleChildScrollView(
                                child: optionColumn,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _sourcePreviewText(
    RemoteProvider? provider,
    AnimeAv1PlaybackMode animeAv1Mode,
    JkAnimeServerPreference jkAnimeServer,
    FacebookPlaybackMode facebookMode,
    FacebookPlaybackOption facebookOption,
  ) {
    return switch (provider) {
      RemoteProvider.animeAv1 => 'AnimeAV1 - ${animeAv1Mode.dialogLabel}',
      RemoteProvider.jkAnime => 'JKAnime - ${jkAnimeServer.label}',
      RemoteProvider.latAnime => 'LatAnime',
      RemoteProvider.animeFlv => 'AnimeFLV',
      RemoteProvider.facebook =>
        'Facebook - ${facebookMode.dialogLabel}, ${facebookOption.label}',
      _ => 'Fuente automatica',
    };
  }

  Future<void> _playPrevious() async {
    final replacement = _adjacentEpisode(-1);
    if (replacement == null) {
      return;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          controller: widget.controller,
          episode: replacement,
        ),
      ),
    );
  }

  Future<void> _playNext() async {
    final replacement = _adjacentEpisode(1);
    if (replacement == null) {
      final entries = widget.controller.buildNextEntries(limit: 1);
      if (entries.isEmpty) {
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            controller: widget.controller,
            episode: entries.first,
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          controller: widget.controller,
          episode: replacement,
        ),
      ),
    );
  }

  EpisodeItem? _adjacentEpisode(int offset) {
    final series = widget.controller.findSeriesForEpisode(widget.episode);
    if (series == null) {
      return null;
    }
    final index = widget.episode.episodeIndex + offset;
    if (index < 0 || index >= series.episodes.length) {
      return null;
    }
    return series.episodes[index];
  }

  bool _looksLikeDirectVideo(String value) {
    return looksLikeDirectVideoPath(
      value,
      isRemote: widget.episode.isRemote,
    );
  }

  BoxFit _boxFitForVideoScaleMode(VideoScaleMode mode) {
    return switch (mode) {
      VideoScaleMode.stretch => BoxFit.fill,
      _ => BoxFit.contain,
    };
  }
}

class _PlayerDialogSectionTitle extends StatelessWidget {
  const _PlayerDialogSectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: TanukiColors.amber,
        fontSize: 12,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class _AndroidExoVideoSurface extends StatelessWidget {
  const _AndroidExoVideoSurface({
    required this.controller,
    required this.fit,
    required this.subtitlesEnabled,
  });

  final vp.VideoPlayerController controller;
  final BoxFit fit;
  final bool subtitlesEnabled;

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    final width = value.size.width > 0 ? value.size.width : 16.0;
    final height = value.size.height > 0 ? value.size.height : 9.0;
    final caption = subtitlesEnabled ? value.caption.text.trim() : '';
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: FittedBox(
            fit: fit,
            child: SizedBox(
              width: width,
              height: height,
              child: vp.VideoPlayer(controller),
            ),
          ),
        ),
        if (caption.isNotEmpty)
          Positioned(
            left: 24,
            right: 24,
            bottom: 78,
            child: Text(
              caption,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                shadows: [
                  Shadow(color: Colors.black, blurRadius: 4),
                  Shadow(color: Colors.black, offset: Offset(1, 1)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _AndroidExoControls extends StatefulWidget {
  const _AndroidExoControls({
    required this.controller,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.formatTime,
    required this.onFocusChanged,
  });

  final vp.VideoPlayerController controller;
  final Future<void> Function() onTogglePlayback;
  final Future<void> Function(Duration target) onSeek;
  final String Function(Duration duration) formatTime;
  final ValueChanged<bool> onFocusChanged;

  @override
  State<_AndroidExoControls> createState() => _AndroidExoControlsState();
}

class _AndroidExoControlsState extends State<_AndroidExoControls> {
  double? _dragPositionMs;

  @override
  Widget build(BuildContext context) {
    final value = widget.controller.value;
    final durationMs = value.duration.inMilliseconds.clamp(1, 1 << 53);
    final currentMs = _dragPositionMs ??
        value.position.inMilliseconds.clamp(0, durationMs).toDouble();
    return Focus(
      onFocusChange: widget.onFocusChanged,
      child: Container(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xD9101419),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: TanukiColors.panelStroke),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: value.isPlaying ? 'Pausar' : 'Reproducir',
              onPressed: () => unawaited(widget.onTogglePlayback()),
              icon: Icon(
                value.isPlaying ? Icons.pause : Icons.play_arrow,
                color: TanukiColors.text,
              ),
            ),
            SizedBox(
              width: 54,
              child: Text(
                widget.formatTime(
                  Duration(milliseconds: currentMs.round()),
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: TanukiColors.text,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: TanukiColors.orange,
                  inactiveTrackColor: const Color(0x665C6873),
                  thumbColor: TanukiColors.orangeHot,
                  overlayColor: const Color(0x33F0B760),
                  trackHeight: 4,
                ),
                child: Slider(
                  min: 0,
                  max: durationMs.toDouble(),
                  value: currentMs.clamp(0, durationMs.toDouble()),
                  onChanged: (position) {
                    setState(() {
                      _dragPositionMs = position;
                    });
                  },
                  onChangeEnd: (position) {
                    setState(() {
                      _dragPositionMs = null;
                    });
                    unawaited(
                      widget.onSeek(Duration(milliseconds: position.round())),
                    );
                  },
                ),
              ),
            ),
            SizedBox(
              width: 54,
              child: Text(
                widget.formatTime(value.duration),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: TanukiColors.muted,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TanukiVideoTheme extends StatelessWidget {
  const _TanukiVideoTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final normal = kDefaultMaterialVideoControlsThemeData.copyWith(
      controlsHoverDuration: _playerOverlayAutoHideDelay,
      seekBarPositionColor: TanukiColors.orange,
      seekBarThumbColor: TanukiColors.orangeHot,
      seekBarBufferColor: const Color(0x66F0B760),
      buttonBarButtonColor: TanukiColors.text,
    );
    final fullscreen =
        kDefaultMaterialVideoControlsThemeDataFullscreen.copyWith(
      controlsHoverDuration: _playerOverlayAutoHideDelay,
      seekBarPositionColor: TanukiColors.orange,
      seekBarThumbColor: TanukiColors.orangeHot,
      seekBarBufferColor: const Color(0x66F0B760),
      buttonBarButtonColor: TanukiColors.text,
    );
    return MaterialVideoControlsTheme(
      normal: normal,
      fullscreen: fullscreen,
      child: child,
    );
  }
}

class _PlayerDialogButton extends StatelessWidget {
  const _PlayerDialogButton({
    required this.label,
    required this.active,
    required this.onPressed,
  });

  final String label;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          backgroundColor:
              active ? TanukiColors.orange : const Color(0x33141D28),
          foregroundColor: active ? Colors.black : TanukiColors.text,
          side: BorderSide(
            color: active ? TanukiColors.orangeHot : TanukiColors.panelStroke,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
        ),
      ),
    );
  }
}

class _PlayerTopBar extends StatelessWidget {
  const _PlayerTopBar({
    required this.episode,
    required this.status,
    required this.statusIcon,
    required this.statusColor,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.subtitlesEnabled,
    required this.videoScaleMode,
    required this.onToggleSubtitles,
    required this.onToggleViewMode,
    required this.onSettings,
    required this.onControlFocusChanged,
    this.backButtonFocusNode,
  });

  final EpisodeItem episode;
  final FocusNode? backButtonFocusNode;
  final String status;
  final IconData statusIcon;
  final Color statusColor;
  final VoidCallback onBack;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool subtitlesEnabled;
  final VideoScaleMode videoScaleMode;
  final VoidCallback onToggleSubtitles;
  final VoidCallback onToggleViewMode;
  final VoidCallback onSettings;
  final ValueChanged<bool> onControlFocusChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0x96000000),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          _PlayerIconButton(
            icon: Icons.arrow_back,
            tooltip: 'Volver',
            focusNode: backButtonFocusNode,
            onPressed: onBack,
            onFocusChanged: onControlFocusChanged,
          ),
          const SizedBox(width: 10),
          _PlayerIconButton(
            icon: Icons.skip_previous,
            tooltip: 'Capitulo anterior',
            onPressed: onPrevious,
            onFocusChanged: onControlFocusChanged,
          ),
          const SizedBox(width: 10),
          _PlayerIconButton(
            icon: Icons.skip_next,
            tooltip: 'Capitulo siguiente',
            onPressed: onNext,
            onFocusChanged: onControlFocusChanged,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${episode.seriesName} - Episodio ${episode.episodeNumber}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(statusIcon, size: 15, color: statusColor),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: statusColor,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _PlayerCaptionButton(
            label: subtitlesEnabled ? 'SUB' : 'OFF',
            tooltip: subtitlesEnabled
                ? 'Desactivar subtitulos'
                : 'Activar subtitulos',
            active: subtitlesEnabled,
            onPressed: onToggleSubtitles,
            onFocusChanged: onControlFocusChanged,
          ),
          const SizedBox(width: 10),
          _PlayerCaptionButton(
            label: videoScaleMode.buttonLabel,
            tooltip: 'Vista del video',
            active: true,
            onPressed: onToggleViewMode,
            onFocusChanged: onControlFocusChanged,
          ),
          const SizedBox(width: 10),
          _PlayerIconButton(
            icon: Icons.settings,
            tooltip: 'Ajustes',
            onPressed: onSettings,
            onFocusChanged: onControlFocusChanged,
          ),
        ],
      ),
    );
  }
}

class _PlayerCaptionButton extends StatelessWidget {
  const _PlayerCaptionButton({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onPressed,
    required this.onFocusChanged,
    this.focusNode,
  });

  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;
  final ValueChanged<bool> onFocusChanged;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Focus(
        onFocusChange: onFocusChanged,
        child: SizedBox(
          width: 56,
          height: 44,
          child: OutlinedButton(
            focusNode: focusNode,
            onPressed: onPressed,
            style: ButtonStyle(
              padding: MaterialStateProperty.all(EdgeInsets.zero),
              backgroundColor: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.focused)) {
                  return const Color(0xAA24384C);
                }
                return active
                    ? const Color(0x66141D28)
                    : const Color(0x33141D28);
              }),
              side: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.focused)) {
                  return const BorderSide(
                    color: TanukiColors.orangeHot,
                    width: 3,
                  );
                }
                return BorderSide(
                  color:
                      active ? TanukiColors.orange : TanukiColors.panelStroke,
                );
              }),
              foregroundColor: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.focused)) {
                  return TanukiColors.text;
                }
                return null;
              }),
              shape: MaterialStateProperty.all(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
              ),
            ),
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerSourceStatus {
  const _PlayerSourceStatus({
    required this.icon,
    required this.color,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String label;
}

class _PlayerIconButton extends StatelessWidget {
  const _PlayerIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.onFocusChanged,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final ValueChanged<bool> onFocusChanged;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Focus(
        onFocusChange: onFocusChanged,
        child: IconButton(
          focusNode: focusNode,
          onPressed: onPressed,
          icon: Icon(icon),
          style: ButtonStyle(
            fixedSize: MaterialStateProperty.all(const Size(44, 44)),
            backgroundColor: MaterialStateProperty.resolveWith((states) {
              if (states.contains(MaterialState.focused)) {
                return const Color(0xAA24384C);
              }
              return const Color(0x66141D28);
            }),
            foregroundColor: MaterialStateProperty.all(Colors.white),
            side: MaterialStateProperty.resolveWith((states) {
              if (states.contains(MaterialState.focused)) {
                return const BorderSide(
                  color: TanukiColors.orangeHot,
                  width: 3,
                );
              }
              return BorderSide.none;
            }),
            shape: MaterialStateProperty.all(const CircleBorder()),
          ),
        ),
      ),
    );
  }
}

bool looksLikeDirectVideoPath(String value, {required bool isRemote}) {
  if (!isRemote) {
    return true;
  }
  final normalized = value.toLowerCase();
  if (_looksLikeFacebookMediaUrl(normalized)) {
    return _isLikelyFacebookProgressiveVideo(value);
  }
  const videoMarkers = [
    '.m3u8',
    '/m3u8/',
    '/hls',
    'master.txt',
    '.mpd',
    '.mp4',
    '.mkv',
    '.webm',
    '.mov',
    '.m4v',
    '.avi',
    '.wmv',
    '.ts',
    'streamtape.com/get_video',
  ];
  return videoMarkers.any(normalized.contains) ||
      (normalized.contains('hqq.tv') && normalized.contains('stream=1')) ||
      _isLikelyDoodStreamVideo(normalized);
}

RemoteProvider? remoteProviderToExcludeAfterResolveMiss({
  required EpisodeItem episode,
  required RemoteProvider? playbackProvider,
  required Set<RemoteProvider> failedProviders,
}) {
  if (!episode.isRemote) {
    return null;
  }
  for (final provider in [playbackProvider, episode.provider]) {
    if (provider == null ||
        provider == RemoteProvider.catalog ||
        provider == RemoteProvider.animeKai ||
        provider == RemoteProvider.animeFlv ||
        failedProviders.contains(provider)) {
      continue;
    }
    return provider;
  }
  return null;
}

bool shouldWatchAnimeAv1VideoFrame(
  RemoteProvider? provider,
  RemoteDirectStream? stream,
) {
  if (provider != RemoteProvider.animeAv1 || stream == null) {
    return false;
  }
  if (stream.playbackKind.toLowerCase() != 'hls') {
    return false;
  }
  final source = '${stream.playbackUrl} ${stream.pageUrl}'.trim().toLowerCase();
  return source.contains('player.zilla-networks.com') ||
      source.contains('zilla-networks.com');
}

Duration? initialMediaStartPosition({
  required Duration? resumePosition,
  required bool canStartAtPosition,
}) {
  if (resumePosition == null || resumePosition <= Duration.zero) {
    return Duration.zero;
  }
  if (!canStartAtPosition) {
    return null;
  }
  if (resumePosition <= const Duration(seconds: 2)) {
    return Duration.zero;
  }
  return resumePosition - const Duration(seconds: 2);
}

String androidHardwareDecoderCodecs({required bool disableAv1}) {
  return disableAv1
      ? _androidHardwareDecoderCodecsWithoutAv1
      : _androidHardwareDecoderCodecs;
}

bool shouldIgnoreRemoteCompletionAfterJump({
  required bool isRemote,
  required DateTime? jumpAt,
  required Duration positionBeforeJump,
  required Duration duration,
  required DateTime now,
}) {
  if (!isRemote || jumpAt == null || duration <= Duration.zero) {
    return false;
  }
  if (now.difference(jumpAt) > const Duration(seconds: 3)) {
    return false;
  }
  return duration - positionBeforeJump > const Duration(seconds: 30);
}

bool shouldRetryMissingVideoFrame({
  required bool isPlaying,
  required bool isBuffering,
  required Duration position,
  required int? width,
  required int? height,
}) {
  if (!isPlaying || isBuffering) {
    return false;
  }
  if ((width ?? 0) > 0 && (height ?? 0) > 0) {
    return false;
  }
  return position >= _remoteVideoFramePlaybackGrace;
}

bool shouldRecoverRemoteOpeningStall({
  required bool isPlaying,
  required bool isBuffering,
  required Duration position,
  required Duration target,
  required int? width,
  required int? height,
}) {
  if (target <= Duration.zero) {
    return false;
  }
  if ((width ?? 0) > 0 && (height ?? 0) > 0) {
    return false;
  }
  if (position <= const Duration(seconds: 2)) {
    return true;
  }
  final distance = position.inMilliseconds - target.inMilliseconds;
  final nearTarget = Duration(
        milliseconds: distance < 0 ? -distance : distance,
      ) <=
      const Duration(seconds: 10);
  return nearTarget && (isPlaying || isBuffering);
}

bool shouldDeferAnimeAv1PlaybackError({
  required RemoteProvider? provider,
  required RemoteDirectStream? stream,
  required bool isPlaying,
  required bool isBuffering,
  required Duration position,
  required int? width,
  required int? height,
}) {
  if (!shouldWatchAnimeAv1VideoFrame(provider, stream)) {
    return false;
  }
  if ((width ?? 0) > 0 && (height ?? 0) > 0) {
    return false;
  }
  return isPlaying ||
      isBuffering ||
      position < _animeAv1PlaybackErrorFallbackDelay;
}

bool shouldRetryDeferredAnimeAv1PlaybackError({
  required bool isPlaying,
  required bool isBuffering,
  required Duration position,
  required int? width,
  required int? height,
}) {
  if ((width ?? 0) > 0 && (height ?? 0) > 0) {
    return false;
  }
  if (isPlaying || isBuffering || position > Duration.zero) {
    return false;
  }
  return true;
}

RemoteSubtitleTrack? selectRemoteSubtitleTrack(
  RemoteDirectStream? stream, {
  String selectedKey = '',
}) {
  final tracks = stream?.subtitleTracks ?? const <RemoteSubtitleTrack>[];
  if (tracks.isEmpty) {
    return null;
  }
  final normalizedSelectedKey = selectedKey.trim();
  if (normalizedSelectedKey.isNotEmpty) {
    for (final track in tracks) {
      if (remoteSubtitleTrackKey(track) == normalizedSelectedKey) {
        return track;
      }
    }
  }
  return tracks.firstWhere(
    (track) => track.isDefault,
    orElse: () => tracks.first,
  );
}

String remoteSubtitleTrackKey(RemoteSubtitleTrack track) {
  return '${track.url.trim().toLowerCase()}|'
      '${track.language.trim().toLowerCase()}|'
      '${track.label.trim().toLowerCase()}';
}

String remoteSubtitleTrackLabel(RemoteSubtitleTrack track) {
  final label = track.label.trim().isEmpty ? 'Subtitulos' : track.label.trim();
  final language = track.language.trim();
  return language.isEmpty ? label : '$label [${language.toUpperCase()}]';
}

String remoteServerLabel(String server) {
  return switch (server.trim().toLowerCase()) {
    'streamwish' => 'StreamWish',
    'mixdrop' => 'MixDrop',
    'doodstream' => 'Doodstream',
    'vidhide' => 'VidHide',
    'desu' => 'Desu',
    'upcloud' => 'UpCloud',
    'vidstream' => 'Vidstream',
    'mp4upload' => 'MP4Upload',
    'yourupload' => 'YourUpload',
    'uqload' => 'Uqload',
    'stape' => 'Stape',
    'netu' => 'Netu',
    String value when value.isNotEmpty => value,
    _ => 'servidor',
  };
}

bool _isLikelyFacebookProgressiveVideo(String value) {
  if (!_looksLikeFacebookMediaUrl(value.toLowerCase())) {
    return false;
  }
  final efgTag = _decodeFacebookEfgTag(value).toLowerCase();
  if (efgTag.contains('audio')) {
    return false;
  }
  return efgTag.contains('xpv_progressive') || efgTag.contains('progressive');
}

bool _looksLikeFacebookMediaUrl(String value) {
  return value.contains('fbcdn.net') ||
      value.contains('video.xx.fbcdn.net') ||
      value.contains('facebook.com') && value.contains('/video');
}

String _decodeFacebookEfgTag(String value) {
  final uri = Uri.tryParse(value);
  final encoded = uri?.queryParameters['efg'] ?? '';
  if (encoded.isEmpty) {
    return '';
  }
  try {
    final normalized = base64.normalize(
      encoded.replaceAll('-', '+').replaceAll('_', '/'),
    );
    return utf8.decode(base64.decode(normalized));
  } catch (_) {
    return '';
  }
}

bool _isLikelyDoodStreamVideo(String value) {
  return value.contains('token=') &&
      value.contains('expiry=') &&
      (value.contains('cloudatacdn.com') ||
          value.contains('doodcdn') ||
          value.contains('myvidplay'));
}

class _PlayerFallback extends StatelessWidget {
  const _PlayerFallback({
    required this.episode,
    required this.error,
  });

  final EpisodeItem episode;
  final String error;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/images/tanuki_brand_logo.png',
                  height: 76, fit: BoxFit.contain),
              const SizedBox(height: 24),
              Text(
                episode.displayName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                error.isEmpty ? 'Cargando video...' : error,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpcomingCard extends StatelessWidget {
  const _UpcomingCard({
    required this.label,
    required this.labelColor,
    required this.episode,
  });

  final String label;
  final Color labelColor;
  final EpisodeItem episode;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      padding: const EdgeInsets.all(10),
      decoration: glassDecoration(color: const Color(0xC0141D28), radius: 8),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 64,
            decoration: BoxDecoration(
              color: TanukiColors.backgroundAlt,
              borderRadius: BorderRadius.circular(6),
            ),
            clipBehavior: Clip.antiAlias,
            child: episode.imageUrl.isNotEmpty
                ? Image.network(episode.imageUrl, fit: BoxFit.cover)
                : Image.asset('assets/images/tanuki_brand_icon.png',
                    fit: BoxFit.cover),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  color: labelColor.withValues(alpha: 0.22),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: labelColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  episode.seriesName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Episodio ${episode.episodeNumber}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
