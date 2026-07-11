import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_vlc/dart_vlc.dart' as vlc;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart' as vp;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_controller.dart';
import '../models.dart';
import '../services/playback_backend.dart';
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
int _nextDesktopVlcPlayerId = 1;
const _androidHardwareDecoderCodecs = 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1';
const _androidHardwareDecoderCodecsWithoutAv1 =
    'h264,hevc,mpeg4,mpeg2video,vp8,vp9';

enum PlayerLaunchMode {
  normal,
  detail,
  continueWatching,
}

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
    this.launchMode = PlayerLaunchMode.normal,
  });

  final AppController controller;
  final EpisodeItem episode;
  final PlayerLaunchMode launchMode;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  Player? _player;
  VideoController? _videoController;
  vp.VideoPlayerController? _androidExoController;
  vlc.Player? _desktopVlcPlayer;
  StreamSubscription<vlc.PositionState>? _desktopVlcPositionSubscription;
  StreamSubscription<vlc.PlaybackState>? _desktopVlcPlaybackSubscription;
  StreamSubscription<String>? _desktopVlcErrorSubscription;
  StreamSubscription<vlc.VideoDimensions>? _desktopVlcDimensionsSubscription;
  String _status = 'Preparando reproductor...';
  String _error = '';
  bool _openedMedia = false;
  bool _completionCommitted = false;
  bool _androidExoCompletionHandled = false;
  bool _desktopVlcCompletionHandled = false;
  bool _handlingAndroidExoError = false;
  bool _simklScrobbleActive = false;
  bool _subtitlesEnabled = true;
  bool _handlingPlaybackError = false;
  bool _playerOverlaysVisible = true;
  bool _playerControlsFocused = false;
  bool _playerBuffering = false;
  bool _playerFullscreen = false;
  final FocusNode _playerControlsRootFocusNode =
      FocusNode(debugLabel: 'playerControlsRoot');
  final FocusNode _playerBackButtonFocusNode =
      FocusNode(debugLabel: 'playerBackButton');
  final FocusNode _playerPreviousButtonFocusNode =
      FocusNode(debugLabel: 'playerPreviousButton');
  final FocusNode _playerNextButtonFocusNode =
      FocusNode(debugLabel: 'playerNextButton');
  final FocusNode _playerSubtitlesButtonFocusNode =
      FocusNode(debugLabel: 'playerSubtitlesButton');
  final FocusNode _playerFitButtonFocusNode =
      FocusNode(debugLabel: 'playerFitButton');
  final FocusNode _playerSettingsButtonFocusNode =
      FocusNode(debugLabel: 'playerSettingsButton');
  final FocusNode _playerEpisodesButtonFocusNode =
      FocusNode(debugLabel: 'playerEpisodesButton');
  final FocusNode _playerFullscreenButtonFocusNode =
      FocusNode(debugLabel: 'playerFullscreenButton');
  final FocusNode _playerBottomPlayFocusNode =
      FocusNode(debugLabel: 'playerBottomPlay');
  final FocusNode _playerBottomProgressFocusNode =
      FocusNode(debugLabel: 'playerBottomProgress');
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
  DateTime? _lastPlayerBackKeyAt;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<String>? _playbackErrorSubscription;
  StreamSubscription<int?>? _videoWidthSubscription;
  StreamSubscription<int?>? _videoHeightSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<bool>? _playerBufferingSubscription;
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
  int _openEpisodeTicket = 0;
  bool _remoteReloadInProgress = false;
  String _deferredAnimeAv1PlaybackError = '';
  String _currentPlaybackPath = '';
  _UpcomingCardPhase _upcomingCardPhase = _UpcomingCardPhase.none;
  bool _startUpcomingCardsShown = false;
  bool _endUpcomingCardsShown = false;
  int _upcomingCardTicket = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_setPlaybackWakelock(enabled: true));
    _videoScaleMode =
        widget.controller.videoScaleModeForEpisode(widget.episode);
    if (!_usesAndroidExoPlayer &&
        !_usesDesktopVlcPlayer &&
        PlaybackBackend.mediaKitAvailable) {
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
    _playerPreviousButtonFocusNode.dispose();
    _playerNextButtonFocusNode.dispose();
    _playerSubtitlesButtonFocusNode.dispose();
    _playerFitButtonFocusNode.dispose();
    _playerSettingsButtonFocusNode.dispose();
    _playerEpisodesButtonFocusNode.dispose();
    _playerFullscreenButtonFocusNode.dispose();
    _playerBottomPlayFocusNode.dispose();
    _playerBottomProgressFocusNode.dispose();
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
    final playerBufferingSubscription = _playerBufferingSubscription;
    if (playerBufferingSubscription != null) {
      unawaited(playerBufferingSubscription.cancel());
    }
    unawaited(_setPlaybackWakelock(enabled: false));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    _player?.dispose();
    final androidExoController = _androidExoController;
    if (androidExoController != null) {
      androidExoController.removeListener(_handleAndroidExoValue);
      unawaited(androidExoController.dispose());
    }
    unawaited(_disposeDesktopVlcPlayer());
    super.dispose();
  }

  bool get _usesAndroidExoPlayer =>
      Platform.isAndroid && widget.episode.isRemote;

  bool get _usesDesktopVlcPlayer =>
      (Platform.isLinux || Platform.isWindows) && widget.episode.isRemote;

  Future<void> _setPlaybackWakelock({required bool enabled}) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (error) {
      debugPrint('PlayerScreen: wakelock failed enabled=$enabled error=$error');
    }
  }

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
    final openTicket = ++_openEpisodeTicket;
    _debugPlayerEvent(
      'open start remote=${widget.episode.isRemote} '
      'episode="${widget.episode.displayName}"',
    );
    await widget.controller.setCurrentEntry(widget.episode);
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
      if (!mounted || openTicket != _openEpisodeTicket) {
        _debugPlayerEvent('open discarded stale remote resolve');
        return;
      }
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

    _currentPlaybackPath = path;
    if (!mounted || openTicket != _openEpisodeTicket) {
      _debugPlayerEvent('open discarded stale playback path');
      return;
    }
    if (_usesAndroidExoPlayer) {
      await _openAndroidExoPlayer(path);
      return;
    }
    if (_usesDesktopVlcPlayer) {
      await _openDesktopVlcPlayer(path);
      return;
    }

    final player = _player;
    final videoController = _videoController;
    if (player == null || videoController == null) {
      if (mounted) {
        setState(() {
          final details = PlaybackBackend.initializationError;
          _error = details.isEmpty
              ? 'No se pudo iniciar media_kit.'
              : 'No se pudo iniciar media_kit: $details';
          _status = 'Error de reproduccion';
        });
      }
      return;
    }

    try {
      await videoController.platform.future;
      await _configurePlatformPlayback(player);
      _attachPlaybackTracking(player);
      final resumePosition =
          widget.controller.resumePositionForEpisode(widget.episode);
      final startPosition = initialMediaStartPosition(
        resumePosition: resumePosition,
        canStartAtPosition: _shouldUseStartPositionForPath(path),
      );
      final mediaHeaders = _remoteMediaHeaders(path);
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
    final playbackKind = _currentResolvedStream?.playbackKind.toLowerCase();
    final lowerPath = path.toLowerCase();
    final formatHint = playbackKind == 'hls' ||
            lowerPath.contains('.m3u8') ||
            lowerPath.contains('/m3u8/')
        ? vp.VideoFormat.hls
        : playbackKind == 'dash' || lowerPath.contains('.mpd')
            ? vp.VideoFormat.dash
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

  Future<void> _openDesktopVlcPlayer(String path) async {
    await _disposeDesktopVlcPlayer();
    _desktopVlcCompletionHandled = false;
    _setPlayerBuffering(true);

    final resumePosition =
        widget.controller.resumePositionForEpisode(widget.episode);
    final openStart = _desktopVlcOpenStartPosition(resumePosition);
    final urlStart =
        _desktopVlcUrlStartPosition(resumePosition, mediaStart: openStart);
    final playbackPath = _desktopVlcPlaybackPath(path, startPosition: urlStart);
    final headers =
        _remoteMediaHeaders(playbackPath) ?? const <String, String>{};
    final referer = headers['Referer']?.trim() ?? '';
    final audioSlave = _desktopVlcAudioSlave();
    final player = vlc.Player(
      id: _nextDesktopVlcPlayerId++,
      commandlineArguments: [
        '--network-caching=1500',
        '--adaptive-logic=highest',
        if (audioSlave.isNotEmpty) '--input-slave=$audioSlave',
        if (referer.isNotEmpty) '--http-referrer=$referer',
      ],
    );
    _desktopVlcPlayer = player;
    player.setUserAgent(headers['User-Agent'] ?? _remotePlaybackUserAgent);
    _desktopVlcPositionSubscription = player.positionStream.listen((state) {
      if (_desktopVlcPlayer != player) {
        return;
      }
      final previous = _lastPosition;
      _lastPosition = state.position ?? Duration.zero;
      _lastDuration = state.duration ?? Duration.zero;
      if (_lastPosition != previous) {
        _lastPositionChangeAt = DateTime.now();
        _remotePlaybackAccepted = true;
      }
      if (_lastDuration > Duration.zero || _lastPosition > Duration.zero) {
        _setPlayerBuffering(false);
      }
      _maybeScheduleUpcomingCards(_lastPosition);
      _persistPlaybackThrottled();
      if (mounted) {
        setState(() {});
      }
    });
    _desktopVlcPlaybackSubscription = player.playbackStream.listen((state) {
      if (_desktopVlcPlayer != player) {
        return;
      }
      if (state.isCompleted && !_desktopVlcCompletionHandled) {
        if (!_shouldAcceptPlaybackCompletion()) {
          _debugPlayerEvent(
            'ignored early VLC completion position='
            '${_formatPlaybackTime(_lastPosition)} duration='
            '${_formatPlaybackTime(_lastDuration)} expected='
            '${_formatPlaybackTime(_expectedRemoteDuration)}',
          );
          return;
        }
        _desktopVlcCompletionHandled = true;
        unawaited(_commitPlaybackCompletion());
        if (mounted) {
          unawaited(_playNext());
        }
      }
      if (mounted) {
        setState(() {});
      }
    });
    _desktopVlcErrorSubscription = player.errorStream.listen((error) {
      if (!mounted || _desktopVlcPlayer != player || error.trim().isEmpty) {
        return;
      }
      _debugPlayerEvent('VLC error: $error');
      _setPlayerBuffering(false);
      setState(() {
        _status = 'Error de reproduccion';
        _error = 'VLC no pudo reproducir el video: $error';
      });
    });
    _desktopVlcDimensionsSubscription =
        player.videoDimensionsStream.listen((dimensions) {
      if (!mounted || _desktopVlcPlayer != player) {
        return;
      }
      _remoteVideoWidth = dimensions.width;
      _remoteVideoHeight = dimensions.height;
      if (dimensions.width > 0 && dimensions.height > 0) {
        _setPlayerBuffering(false);
      }
      setState(() {});
    });

    _lastPosition = resumePosition ?? Duration.zero;
    _lastDuration = Duration.zero;
    _lastPositionChangeAt = DateTime.now();
    _debugPlayerEvent(
      'VLC open url=${_debugMediaLabel(path)} '
      'playbackUrl=${_debugMediaLabel(playbackPath)} '
      'audioSlave=${audioSlave.isEmpty ? 'none' : _debugMediaLabel(audioSlave)} '
      'start=${_formatPlaybackTime(_lastPosition)} '
      'headers=${_debugHeadersLabel(headers)}',
    );
    try {
      player.open(
        _desktopVlcMedia(playbackPath, startTime: openStart),
        autoStart: true,
      );
      _startSimklScrobble();
      if (!mounted || _desktopVlcPlayer != player) {
        return;
      }
      setState(() {
        _openedMedia = true;
        _error = '';
        _status = resumePosition == null
            ? 'Reproduciendo con VLC'
            : 'Reanudado en ${_formatPlaybackTime(resumePosition)}';
      });
      _scheduleOpeningUpcomingCards();
      _schedulePlayerOverlayHide();
    } catch (error) {
      await _disposeDesktopVlcPlayer();
      if (!mounted) {
        return;
      }
      setState(() {
        _playerBuffering = false;
        _status = 'Error de reproduccion';
        _error = 'No se pudo abrir el video con VLC: $error';
      });
    }
  }

  Duration _desktopVlcOpenStartPosition(Duration? resumePosition) {
    final start = resumePosition ?? Duration.zero;
    if (_currentResolvedStream?.provider == RemoteProvider.bilibili) {
      return Duration.zero;
    }
    return start;
  }

  Duration _desktopVlcUrlStartPosition(
    Duration? resumePosition, {
    required Duration mediaStart,
  }) {
    if (_currentResolvedStream?.provider == RemoteProvider.bilibili) {
      return resumePosition ?? Duration.zero;
    }
    return mediaStart;
  }

  String _desktopVlcPlaybackPath(
    String fallbackPath, {
    Duration startPosition = Duration.zero,
  }) {
    if (_currentResolvedStream?.provider == RemoteProvider.bilibili) {
      final hlsUrl =
          _currentResolvedStream?.httpHeaders['X-Tanuki-Vlc-Hls-Url']?.trim();
      if (hlsUrl != null && hlsUrl.isNotEmpty) {
        return _desktopVlcUrlWithStart(hlsUrl, startPosition);
      }
    }
    return fallbackPath;
  }

  String _desktopVlcUrlWithStart(String url, Duration startPosition) {
    if (startPosition <= Duration.zero) {
      return url;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return url;
    }
    final startSeconds = max(0, startPosition.inSeconds);
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      'start': '$startSeconds',
    }).toString();
  }

  String _desktopVlcAudioSlave() {
    return '';
  }

  vlc.Media _desktopVlcMedia(
    String playbackPath, {
    required Duration startTime,
  }) {
    if (_currentResolvedStream?.provider == RemoteProvider.bilibili &&
        !playbackPath.startsWith('http://') &&
        !playbackPath.startsWith('https://')) {
      return vlc.Media.file(File(playbackPath), startTime: startTime);
    }
    return vlc.Media.network(playbackPath, startTime: startTime);
  }

  Future<void> _disposeDesktopVlcPlayer() async {
    final subscriptions = <StreamSubscription<dynamic>?>[
      _desktopVlcPositionSubscription,
      _desktopVlcPlaybackSubscription,
      _desktopVlcErrorSubscription,
      _desktopVlcDimensionsSubscription,
    ];
    _desktopVlcPositionSubscription = null;
    _desktopVlcPlaybackSubscription = null;
    _desktopVlcErrorSubscription = null;
    _desktopVlcDimensionsSubscription = null;
    for (final subscription in subscriptions) {
      await subscription?.cancel();
    }
    final player = _desktopVlcPlayer;
    _desktopVlcPlayer = null;
    if (player != null) {
      try {
        player.stop();
      } catch (_) {}
      player.dispose();
    }
    _setPlayerBuffering(false);
  }

  Future<void> _toggleDesktopVlcPlayback() async {
    final player = _desktopVlcPlayer;
    if (player == null) {
      return;
    }
    if (player.playback.isCompleted) {
      player.seek(Duration.zero);
      _desktopVlcCompletionHandled = false;
      player.play();
    } else {
      player.playOrPause();
    }
    _showPlayerOverlays();
  }

  Future<void> _seekDesktopVlcPlayer(Duration target) async {
    final player = _desktopVlcPlayer;
    if (player == null) {
      return;
    }
    if (_currentResolvedStream?.provider == RemoteProvider.bilibili) {
      _debugPlayerEvent(
        'VLC BiliBili seek ignored target=${_formatPlaybackTime(target)}',
      );
      if (mounted) {
        setState(() {
          _status = 'BiliBili demora en cargar y al adelantar puede demorarse.';
        });
      }
      _showPlayerOverlays();
      return;
    }
    player.seek(target);
    _lastPosition = target;
    _lastPositionChangeAt = DateTime.now();
    _desktopVlcCompletionHandled = false;
    unawaited(_persistPlayback(force: true));
    _showPlayerOverlays();
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
    _setPlayerBuffering(value.isBuffering);
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
      if (!_shouldAcceptPlaybackCompletion()) {
        _debugPlayerEvent(
          'ignored early ExoPlayer completion position='
          '${_formatPlaybackTime(_lastPosition)} duration='
          '${_formatPlaybackTime(_lastDuration)} expected='
          '${_formatPlaybackTime(_expectedRemoteDuration)}',
        );
        return;
      }
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

  bool _shouldAcceptPlaybackCompletion() {
    return shouldAcceptPlaybackCompletion(
      isRemote: widget.episode.isRemote,
      position: _lastPosition,
      duration: _effectiveCompletionDuration,
    );
  }

  Duration get _effectiveCompletionDuration {
    final expected = _expectedRemoteDuration;
    if (expected > _lastDuration) {
      return expected;
    }
    return _lastDuration;
  }

  Duration get _expectedRemoteDuration {
    final raw =
        _currentResolvedStream?.httpHeaders['X-Tanuki-Duration-Seconds'] ?? '';
    final seconds = int.tryParse(raw.trim()) ?? 0;
    return seconds > 0 ? Duration(seconds: seconds) : Duration.zero;
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
      if (name.toLowerCase().startsWith('x-tanuki-')) {
        continue;
      }
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
    if (_remoteReloadInProgress) {
      _debugPlayerEvent(
          'manual reload skipped because another reload is active');
      return;
    }
    _remoteReloadInProgress = true;
    ++_openEpisodeTicket;
    _debugPlayerEvent('manual reload remote source');
    try {
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
      await _disposeDesktopVlcPlayer();
      await _player?.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '';
        _status = 'Resolviendo fuente remota...';
      });
      await _openEpisode();
    } finally {
      _remoteReloadInProgress = false;
    }
  }

  void _attachPlaybackTracking(Player player) {
    final positionSubscription = _positionSubscription;
    final durationSubscription = _durationSubscription;
    final completedSubscription = _completedSubscription;
    final bufferSubscription = _bufferSubscription;
    final playerBufferingSubscription = _playerBufferingSubscription;
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
    if (playerBufferingSubscription != null) {
      unawaited(playerBufferingSubscription.cancel());
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
        if (!_shouldAcceptPlaybackCompletion()) {
          _debugPlayerEvent(
            'ignored early completion position='
            '${_formatPlaybackTime(_lastPosition)} duration='
            '${_formatPlaybackTime(_lastDuration)} expected='
            '${_formatPlaybackTime(_expectedRemoteDuration)}',
          );
          return;
        }
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
    _playerBufferingSubscription = player.stream.buffering.listen((buffering) {
      _debugPlayerEvent('buffering=$buffering ${_debugPlayerState(player)}');
      _setPlayerBuffering(buffering);
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

  void _setPlayerBuffering(bool buffering) {
    if (_playerBuffering == buffering) {
      return;
    }
    if (!mounted) {
      _playerBuffering = buffering;
      return;
    }
    setState(() {
      _playerBuffering = buffering;
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
    final preferredProvider =
        widget.controller.playbackProviderForEpisode(widget.episode);
    final provider = stream?.provider ??
        preferredProvider ??
        _currentAutomaticProviderCandidate() ??
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
      RemoteProvider.bilibili => stream?.server.trim().isNotEmpty == true
          ? remoteServerLabel(stream!.server)
          : 'DASH',
      RemoteProvider.youtube => stream?.server.trim().isNotEmpty == true
          ? remoteServerLabel(stream!.server)
          : '${youtubePlaybackModeFromId(
              widget.controller
                  .playbackPreferenceForEpisode(widget.episode)
                  .youtubeMode,
            ).buttonLabel} ${youtubePlaybackOptionFromId(
              widget.controller
                  .playbackPreferenceForEpisode(widget.episode)
                  .youtubeOption,
            ).label}',
      _ => '',
    };
    final label =
        detail.isEmpty ? provider.label : '${provider.label} / $detail';
    if (preferredProvider == null && stream?.provider != null) {
      return 'Automatico: $label';
    }
    if (preferredProvider == null && stream == null) {
      return 'Automatico: intentando $label';
    }
    return label;
  }

  RemoteProvider? _currentAutomaticProviderCandidate() {
    final preferred =
        widget.controller.playbackProviderForEpisode(widget.episode);
    if (preferred != null) {
      return preferred;
    }
    for (final provider in [
      widget.episode.provider,
      RemoteProvider.animeAv1,
      RemoteProvider.jkAnime,
      RemoteProvider.latAnime,
      RemoteProvider.bilibili,
      RemoteProvider.youtube,
      RemoteProvider.facebook,
    ]) {
      if (provider == null ||
          provider == RemoteProvider.catalog ||
          provider == RemoteProvider.animeKai ||
          provider == RemoteProvider.animeFlv ||
          _failedRemoteProviders.contains(provider)) {
        continue;
      }
      if (!widget.controller.canUsePlaybackProviderForEpisode(
        widget.episode,
        provider,
      )) {
        continue;
      }
      return provider;
    }
    return null;
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
                    : _openedMedia && _desktopVlcPlayer != null
                        ? vlc.Video(
                            player: _desktopVlcPlayer!,
                            fit: _boxFitForVideoScaleMode(_videoScaleMode),
                            showControls: false,
                          )
                        : _openedMedia && _videoController != null
                            ? _TanukiVideoTheme(
                                child: Video(
                                  controller: _videoController!,
                                  fit:
                                      _boxFitForVideoScaleMode(_videoScaleMode),
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
              if (_openedMedia && _playerBuffering)
                Positioned.fill(
                  child: IgnorePointer(
                    child: _PlayerBufferingOverlay(
                      message: _currentResolvedStream?.provider ==
                              RemoteProvider.bilibili
                          ? 'BiliBili demora en cargar y al adelantar puede demorarse.'
                          : '',
                    ),
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
                      onEpisodes: () => unawaited(_showEpisodeListPanel()),
                      onFullscreen: () => unawaited(_toggleFullscreenMode()),
                      onControlFocusChanged: _setPlayerControlsFocused,
                      backButtonFocusNode: _playerBackButtonFocusNode,
                      previousButtonFocusNode: _playerPreviousButtonFocusNode,
                      nextButtonFocusNode: _playerNextButtonFocusNode,
                      subtitlesButtonFocusNode: _playerSubtitlesButtonFocusNode,
                      fitButtonFocusNode: _playerFitButtonFocusNode,
                      settingsButtonFocusNode: _playerSettingsButtonFocusNode,
                      episodesButtonFocusNode: _playerEpisodesButtonFocusNode,
                      fullscreenButtonFocusNode:
                          _playerFullscreenButtonFocusNode,
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
                        playButtonFocusNode: _playerBottomPlayFocusNode,
                        progressFocusNode: _playerBottomProgressFocusNode,
                      ),
                    ),
                  ),
                ),
              if (_openedMedia && _desktopVlcPlayer != null)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 10,
                  child: IgnorePointer(
                    ignoring: !_playerOverlaysVisible,
                    child: AnimatedOpacity(
                      opacity: _playerOverlaysVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: _DesktopVlcControls(
                        player: _desktopVlcPlayer!,
                        onTogglePlayback: _toggleDesktopVlcPlayback,
                        onSeek: _seekDesktopVlcPlayer,
                        formatTime: _formatPlaybackTime,
                        onFocusChanged: _setPlayerControlsFocused,
                        playButtonFocusNode: _playerBottomPlayFocusNode,
                        progressFocusNode: _playerBottomProgressFocusNode,
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
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      return _handlePlayerBackKey();
    }
    if (_isPlayerActivationKey(key) && _activateFocusedPlayerControl()) {
      _showPlayerOverlays();
      return KeyEventResult.handled;
    }
    if (_playerControlsFocused && key == LogicalKeyboardKey.arrowDown) {
      _showPlayerOverlays();
      _requestPlayerControlFocus(preferBottom: true);
      return KeyEventResult.handled;
    }
    if (_playerBottomPlayFocusNode.hasFocus &&
        key == LogicalKeyboardKey.arrowRight) {
      _showPlayerOverlays();
      _playerBottomProgressFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final movedTopFocus = _moveTopControlFocus(
        forward: key == LogicalKeyboardKey.arrowRight,
      );
      if (movedTopFocus) {
        _showPlayerOverlays();
        return KeyEventResult.handled;
      }
    }
    if (_playerControlsFocused &&
        key == LogicalKeyboardKey.arrowUp &&
        (_playerBottomPlayFocusNode.hasFocus ||
            _playerBottomProgressFocusNode.hasFocus)) {
      _showPlayerOverlays();
      _requestPlayerControlFocus();
      return KeyEventResult.handled;
    }
    final isNavigationKey = key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA;
    if (isNavigationKey) {
      _showPlayerOverlays();
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        return KeyEventResult.ignored;
      }
      if (!_playerControlsFocused) {
        _requestPlayerControlFocus(
          preferBottom: key == LogicalKeyboardKey.arrowDown,
        );
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handlePlayerBackKey() {
    final now = DateTime.now();
    final previous = _lastPlayerBackKeyAt;
    _lastPlayerBackKeyAt = now;
    if (previous != null &&
        now.difference(previous) <= const Duration(milliseconds: 850)) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    _playerControlsRootFocusNode.requestFocus();
    if (mounted) {
      setState(() {
        _playerControlsFocused = false;
        _playerOverlaysVisible = !_playerOverlaysVisible;
      });
    }
    if (_playerOverlaysVisible) {
      _schedulePlayerOverlayHide();
    } else {
      _playerOverlayHideTimer?.cancel();
    }
    return KeyEventResult.handled;
  }

  bool _isPlayerActivationKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA;
  }

  bool _activateFocusedPlayerControl() {
    if (_playerBackButtonFocusNode.hasFocus) {
      Navigator.of(context).maybePop();
      return true;
    }
    if (_playerPreviousButtonFocusNode.hasFocus) {
      unawaited(_playPrevious());
      return true;
    }
    if (_playerNextButtonFocusNode.hasFocus) {
      unawaited(_playNext());
      return true;
    }
    if (_playerSubtitlesButtonFocusNode.hasFocus) {
      _toggleSubtitles();
      return true;
    }
    if (_playerFitButtonFocusNode.hasFocus) {
      _cycleVideoScaleMode();
      return true;
    }
    if (_playerSettingsButtonFocusNode.hasFocus) {
      unawaited(_showPlayerSettingsDialog());
      return true;
    }
    if (_playerEpisodesButtonFocusNode.hasFocus) {
      unawaited(_showEpisodeListPanel());
      return true;
    }
    if (_playerFullscreenButtonFocusNode.hasFocus) {
      unawaited(_toggleFullscreenMode());
      return true;
    }
    if (_playerBottomPlayFocusNode.hasFocus) {
      if (_usesAndroidExoPlayer) {
        unawaited(_toggleAndroidExoPlayback());
      } else if (_usesDesktopVlcPlayer) {
        unawaited(_toggleDesktopVlcPlayback());
      } else {
        final player = _player;
        if (player != null) {
          unawaited(player.playOrPause());
        }
      }
      return true;
    }
    return false;
  }

  void _requestPlayerControlFocus({bool preferBottom = false}) {
    if (!mounted) {
      return;
    }
    if (preferBottom && _playerBottomPlayFocusNode.canRequestFocus) {
      _playerBottomPlayFocusNode.requestFocus();
      return;
    }
    if (_playerBackButtonFocusNode.canRequestFocus) {
      _playerBackButtonFocusNode.requestFocus();
    }
  }

  bool _moveTopControlFocus({required bool forward}) {
    final nodes = [
      _playerBackButtonFocusNode,
      _playerPreviousButtonFocusNode,
      _playerNextButtonFocusNode,
      _playerEpisodesButtonFocusNode,
      _playerSettingsButtonFocusNode,
      _playerFullscreenButtonFocusNode,
    ];
    final currentIndex = nodes.indexWhere((node) => node.hasFocus);
    if (currentIndex < 0) {
      return false;
    }
    final nextIndex = (currentIndex + (forward ? 1 : -1))
        .clamp(
          0,
          nodes.length - 1,
        )
        .toInt();
    if (nextIndex == currentIndex) {
      return true;
    }
    final target = nodes[nextIndex];
    if (target.canRequestFocus) {
      target.requestFocus();
      return true;
    }
    return false;
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

  Future<void> _configurePlatformPlayback(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) {
      return;
    }
    if ((Platform.isLinux || Platform.isWindows) && widget.episode.isRemote) {
      // HLS AV1 seeks should jump to the nearest keyframe. Precise seeks make
      // mpv decode the whole GOP and can appear frozen on software decoders.
      await platform.setProperty('cache', 'yes');
      await platform.setProperty('cache-on-disk', 'no');
      await platform.setProperty('cache-pause', 'yes');
      await platform.setProperty('cache-pause-initial', 'no');
      await platform.setProperty('demuxer-readahead-secs', '20');
      if (_shouldWatchAnimeAv1VideoFrame()) {
        await platform.setProperty('hwdec', 'no');
        await platform.setProperty('vd', 'lavc:libdav1d');
        await platform.setProperty('hr-seek', 'yes');
        await platform.setProperty('hr-seek-framedrop', 'yes');
        await platform.setProperty('hr-seek-demuxer-offset', '20');
      } else {
        await platform.setProperty('hwdec', 'auto-safe');
        await platform.setProperty('vd', 'lavc');
        await platform.setProperty('hr-seek', 'no');
      }
      _debugPlayerEvent(
        'desktop HLS fast seek configured '
        'decoder=${_shouldWatchAnimeAv1VideoFrame() ? 'libdav1d' : 'auto'}',
      );
      return;
    }
    if (!Platform.isAndroid) {
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
    if (Platform.isLinux || Platform.isWindows) {
      return;
    }
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
    if (Platform.isLinux || Platform.isWindows) {
      unawaited(_persistPlayback(force: true));
      return;
    }
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
    if (_usesDesktopVlcPlayer) {
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

  Future<void> _toggleFullscreenMode() async {
    final next = !_playerFullscreen;
    setState(() {
      _playerFullscreen = next;
      _status = next ? 'Pantalla completa' : 'Pantalla normal';
    });
    await SystemChrome.setEnabledSystemUIMode(
      next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    _showPlayerOverlays();
  }

  Future<void> _showEpisodeListPanel() async {
    _showPlayerOverlays();
    final series = widget.controller.findSeriesForEpisode(widget.episode);
    if (series == null || series.episodes.isEmpty) {
      return;
    }
    final selected = await showDialog<EpisodeItem>(
      context: context,
      barrierColor: const Color(0xAA000000),
      builder: (context) => _PlayerEpisodeListDialog(
        series: series,
        current: widget.episode,
        controller: widget.controller,
      ),
    );
    if (selected == null ||
        !mounted ||
        _isSameEpisode(selected, widget.episode)) {
      return;
    }
    await widget.controller.setCurrentEntry(selected);
    if (!mounted) {
      return;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          controller: widget.controller,
          episode: selected,
          launchMode: widget.launchMode,
        ),
      ),
    );
  }

  Future<void> _showPlayerSettingsDialog() async {
    _showPlayerOverlays();
    var preference =
        widget.controller.playbackPreferenceForEpisode(widget.episode);
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0xAA000000),
      builder: (dialogContext) {
        var tab = 0;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final selectedProvider =
                widget.controller.playbackProviderForEpisode(widget.episode);
            final activeProvider = selectedProvider ??
                _currentResolvedStream?.provider ??
                widget.episode.provider;
            final animeAv1Mode =
                animeAv1PlaybackModeFromId(preference.animeAv1Mode);
            final jkAnimeServer = _currentResolvedStream?.provider ==
                        RemoteProvider.jkAnime &&
                    _currentResolvedStream?.server.trim().isNotEmpty == true
                ? jkAnimeServerPreferenceFromId(_currentResolvedStream!.server)
                : jkAnimeServerPreferenceFromId(preference.jkAnimeServer);
            final facebookMode =
                facebookPlaybackModeFromId(preference.facebookMode);
            final facebookOption =
                facebookPlaybackOptionFromId(preference.facebookOption);
            final youtubeMode =
                youtubePlaybackModeFromId(preference.youtubeMode);
            final youtubeOption =
                youtubePlaybackOptionFromId(preference.youtubeOption);

            Future<void> savePreference(Future<void> Function() save) async {
              await save();
              if (!mounted || !dialogContext.mounted) {
                return;
              }
              setDialogState(() {
                preference = widget.controller
                    .playbackPreferenceForEpisode(widget.episode);
              });
              if (widget.episode.isRemote) {
                await _reloadRemoteSource();
              }
            }

            Widget sourceOptions(RemoteProvider? provider) {
              if (provider == RemoteProvider.animeAv1) {
                return Wrap(
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
                );
              }
              if (provider == RemoteProvider.jkAnime) {
                return Wrap(
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
                );
              }
              if (provider == RemoteProvider.facebook) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                                () =>
                                    widget.controller.setFacebookModeForEpisode(
                                  widget.episode,
                                  mode,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
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
                                () => widget.controller
                                    .setFacebookOptionForEpisode(
                                  widget.episode,
                                  option,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              }
              if (provider == RemoteProvider.bilibili) {
                return const Text(
                  'BiliBili usa las opciones encontradas automaticamente.',
                  style: TextStyle(color: TanukiColors.muted),
                );
              }
              if (provider == RemoteProvider.youtube) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final mode in YoutubePlaybackMode.values)
                          _PlayerDialogButton(
                            label: mode.buttonLabel,
                            active: youtubeMode == mode,
                            onPressed: () => unawaited(
                              savePreference(
                                () =>
                                    widget.controller.setYoutubeModeForEpisode(
                                  widget.episode,
                                  mode,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in YoutubePlaybackOption.values)
                          _PlayerDialogButton(
                            label: option.label,
                            active: youtubeOption == option,
                            onPressed: () => unawaited(
                              savePreference(
                                () => widget.controller
                                    .setYoutubeOptionForEpisode(
                                  widget.episode,
                                  option,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              }
              return const Text(
                'Esta fuente no tiene opciones adicionales.',
                style: TextStyle(color: TanukiColors.muted),
              );
            }

            final providers = [
              RemoteProvider.animeAv1,
              RemoteProvider.jkAnime,
              RemoteProvider.latAnime,
              RemoteProvider.bilibili,
              RemoteProvider.youtube,
              if (widget.controller.canUsePlaybackProviderForEpisode(
                widget.episode,
                RemoteProvider.facebook,
              ))
                RemoteProvider.facebook,
            ];

            return Dialog(
              alignment: Alignment.centerRight,
              insetPadding: const EdgeInsets.only(right: 28),
              backgroundColor: const Color(0xF2131518),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: Color(0x44F28C28)),
              ),
              child: SizedBox(
                width: 430,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.tune, color: TanukiColors.orange),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Player Settings',
                                  style: TextStyle(
                                    color: TanukiColors.text,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                Text(
                                  'Ajusta player y fuentes',
                                  style: TextStyle(
                                    color: TanukiColors.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const Divider(color: Color(0x22FFFFFF)),
                      Row(
                        children: [
                          Expanded(
                            child: _PlayerSettingsTabButton(
                              icon: Icons.aspect_ratio,
                              label: 'Player',
                              active: tab == 0,
                              onPressed: () => setDialogState(() => tab = 0),
                            ),
                          ),
                          Expanded(
                            child: _PlayerSettingsTabButton(
                              icon: Icons.cloud,
                              label: 'Fuentes',
                              active: tab == 1,
                              onPressed: () => setDialogState(() => tab = 1),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (tab == 0)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _PlayerDialogButton(
                              label: 'Fit',
                              active: _videoScaleMode == VideoScaleMode.fit,
                              onPressed: () => unawaited(
                                _setVideoScaleMode(VideoScaleMode.fit),
                              ),
                            ),
                            _PlayerDialogButton(
                              label: 'Stretch',
                              active: _videoScaleMode == VideoScaleMode.stretch,
                              onPressed: () => unawaited(
                                _setVideoScaleMode(VideoScaleMode.stretch),
                              ),
                            ),
                            _PlayerDialogButton(
                              label: 'Sub',
                              active: false,
                              onPressed: () {},
                            ),
                          ],
                        )
                      else
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _PlayerDialogButton(
                              label: 'Automatico',
                              active: selectedProvider == null,
                              onPressed: () => unawaited(
                                savePreference(
                                  () => widget.controller
                                      .setPlaybackProviderForEpisode(
                                    widget.episode,
                                    null,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            for (final provider in providers) ...[
                              _PlayerDialogButton(
                                label: provider.label,
                                active: selectedProvider == provider,
                                onPressed: () => unawaited(
                                  savePreference(
                                    () => widget.controller
                                        .setPlaybackProviderForEpisode(
                                      widget.episode,
                                      provider,
                                    ),
                                  ),
                                ),
                              ),
                              if (activeProvider == provider) ...[
                                const SizedBox(height: 8),
                                Padding(
                                  padding: const EdgeInsets.only(left: 10),
                                  child: sourceOptions(provider),
                                ),
                              ],
                              const SizedBox(height: 8),
                            ],
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    return;
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
                RemoteProvider.bilibili,
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
      RemoteProvider.bilibili => 'BiliBili - DASH',
      RemoteProvider.youtube => 'YouTube',
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
          launchMode: widget.launchMode,
        ),
      ),
    );
  }

  Future<void> _playNext() async {
    final replacement = _adjacentEpisode(1);
    if (replacement == null) {
      if (widget.launchMode == PlayerLaunchMode.detail) {
        Navigator.of(context).maybePop();
        return;
      }
      final entries = widget.controller.buildNextEntries(limit: 1);
      if (entries.isEmpty) {
        if (widget.launchMode == PlayerLaunchMode.continueWatching) {
          Navigator.of(context).maybePop();
        }
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            controller: widget.controller,
            episode: entries.first,
            launchMode: widget.launchMode,
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
          launchMode: widget.launchMode,
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

class _PlayerBufferingOverlay extends StatelessWidget {
  const _PlayerBufferingOverlay({
    this.message = '',
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xBB000000),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 42,
                height: 42,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: TanukiColors.orange,
                ),
              ),
              if (message.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
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
    this.playButtonFocusNode,
    this.progressFocusNode,
  });

  final vp.VideoPlayerController controller;
  final Future<void> Function() onTogglePlayback;
  final Future<void> Function(Duration target) onSeek;
  final String Function(Duration duration) formatTime;
  final ValueChanged<bool> onFocusChanged;
  final FocusNode? playButtonFocusNode;
  final FocusNode? progressFocusNode;

  @override
  State<_AndroidExoControls> createState() => _AndroidExoControlsState();
}

class _AndroidExoControlsState extends State<_AndroidExoControls> {
  double? _dragPositionMs;

  KeyEventResult _handleProgressKey(
      Duration position, Duration duration, FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final direction = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
    final target = position + Duration(seconds: 10 * direction);
    final clamped = Duration(
      milliseconds: target.inMilliseconds
          .clamp(
            0,
            duration.inMilliseconds,
          )
          .toInt(),
    );
    setState(() {
      _dragPositionMs = clamped.inMilliseconds.toDouble();
    });
    unawaited(widget.onSeek(clamped).whenComplete(() {
      if (mounted) {
        setState(() {
          _dragPositionMs = null;
        });
      }
    }));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.controller.value;
    final durationMs = value.duration.inMilliseconds.clamp(1, 1 << 53);
    final currentMs = _dragPositionMs ??
        value.position.inMilliseconds.clamp(0, durationMs).toDouble();
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Focus(
        onFocusChange: widget.onFocusChanged,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: IconButton(
                  focusNode: widget.playButtonFocusNode,
                  tooltip: value.isPlaying ? 'Pausar' : 'Reproducir',
                  onPressed: () => unawaited(widget.onTogglePlayback()),
                  icon: Icon(
                    value.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
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
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: Focus(
                    focusNode: widget.progressFocusNode,
                    onKeyEvent: (node, event) => _handleProgressKey(
                      Duration(milliseconds: currentMs.round()),
                      value.duration,
                      node,
                      event,
                    ),
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: TanukiColors.orange,
                        inactiveTrackColor: const Color(0x668A939E),
                        thumbColor: Colors.white,
                        overlayColor: const Color(0x33F0B760),
                        trackHeight: 2,
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
                            widget.onSeek(
                                Duration(milliseconds: position.round())),
                          );
                        },
                      ),
                    ),
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
      ),
    );
  }
}

class _DesktopVlcControls extends StatefulWidget {
  const _DesktopVlcControls({
    required this.player,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.formatTime,
    required this.onFocusChanged,
    this.playButtonFocusNode,
    this.progressFocusNode,
  });

  final vlc.Player player;
  final Future<void> Function() onTogglePlayback;
  final Future<void> Function(Duration target) onSeek;
  final String Function(Duration duration) formatTime;
  final ValueChanged<bool> onFocusChanged;
  final FocusNode? playButtonFocusNode;
  final FocusNode? progressFocusNode;

  @override
  State<_DesktopVlcControls> createState() => _DesktopVlcControlsState();
}

class _DesktopVlcControlsState extends State<_DesktopVlcControls> {
  StreamSubscription<vlc.PositionState>? _positionSubscription;
  StreamSubscription<vlc.PlaybackState>? _playbackSubscription;
  double? _dragPositionMs;

  KeyEventResult _handleProgressKey(
      Duration position, Duration duration, FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final direction = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
    final target = position + Duration(seconds: 10 * direction);
    final clamped = Duration(
      milliseconds: target.inMilliseconds
          .clamp(
            0,
            duration.inMilliseconds,
          )
          .toInt(),
    );
    setState(() {
      _dragPositionMs = clamped.inMilliseconds.toDouble();
    });
    unawaited(widget.onSeek(clamped).whenComplete(() {
      if (mounted) {
        setState(() {
          _dragPositionMs = null;
        });
      }
    }));
    return KeyEventResult.handled;
  }

  @override
  void initState() {
    super.initState();
    _listenToPlayer();
  }

  @override
  void didUpdateWidget(covariant _DesktopVlcControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      unawaited(_positionSubscription?.cancel());
      unawaited(_playbackSubscription?.cancel());
      _listenToPlayer();
    }
  }

  void _listenToPlayer() {
    _positionSubscription = widget.player.positionStream.listen((_) {
      if (mounted && _dragPositionMs == null) {
        setState(() {});
      }
    });
    _playbackSubscription = widget.player.playbackStream.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_playbackSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final position = widget.player.position.position ?? Duration.zero;
    final duration = widget.player.position.duration ?? Duration.zero;
    final durationMs = duration.inMilliseconds.clamp(1, 1 << 53);
    final currentMs = _dragPositionMs ??
        position.inMilliseconds.clamp(0, durationMs).toDouble();
    final isPlaying = widget.player.playback.isPlaying;
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Focus(
        onFocusChange: widget.onFocusChanged,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: IconButton(
                  focusNode: widget.playButtonFocusNode,
                  tooltip: isPlaying ? 'Pausar' : 'Reproducir',
                  onPressed: () => unawaited(widget.onTogglePlayback()),
                  icon: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
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
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: Focus(
                    focusNode: widget.progressFocusNode,
                    onKeyEvent: (node, event) => _handleProgressKey(
                      Duration(milliseconds: currentMs.round()),
                      duration,
                      node,
                      event,
                    ),
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: TanukiColors.orange,
                        inactiveTrackColor: const Color(0x668A939E),
                        thumbColor: Colors.white,
                        overlayColor: const Color(0x33F0B760),
                        trackHeight: 2,
                      ),
                      child: Slider(
                        min: 0,
                        max: durationMs.toDouble(),
                        value: currentMs.clamp(0, durationMs.toDouble()),
                        onChanged: (value) {
                          setState(() {
                            _dragPositionMs = value;
                          });
                        },
                        onChangeEnd: (value) {
                          setState(() {
                            _dragPositionMs = null;
                          });
                          unawaited(
                            widget
                                .onSeek(Duration(milliseconds: value.round())),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 54,
                child: Text(
                  widget.formatTime(duration),
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

class _PlayerSettingsTabButton extends StatelessWidget {
  const _PlayerSettingsTabButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: active ? TanukiColors.orange : TanukiColors.muted,
        backgroundColor: active ? const Color(0x332A170B) : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
  }
}

class _PlayerEpisodeListDialog extends StatelessWidget {
  const _PlayerEpisodeListDialog({
    required this.series,
    required this.current,
    required this.controller,
  });

  final SeriesItem series;
  final EpisodeItem current;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      alignment: Alignment.centerRight,
      insetPadding: const EdgeInsets.only(right: 28),
      backgroundColor: const Color(0xF2131518),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0x44F28C28)),
      ),
      child: SizedBox(
        width: 430,
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
              child: Row(
                children: [
                  const Icon(Icons.view_list, color: TanukiColors.orange),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      series.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: TanukiColors.text,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: series.episodes.length,
                itemBuilder: (context, index) {
                  final episode = series.episodes[index];
                  final active = episode.episodeIndex == current.episodeIndex;
                  final playback = controller.playbackForEpisode(episode);
                  final progress = playback == null || playback.durationMs <= 0
                      ? 0.0
                      : playback.positionMs / playback.durationMs;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => Navigator.of(context).pop(episode),
                      child: Container(
                        height: 76,
                        decoration: BoxDecoration(
                          color: active
                              ? const Color(0x552A170B)
                              : const Color(0x331C2229),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: active
                                ? TanukiColors.orange
                                : const Color(0x22FFFFFF),
                          ),
                        ),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: const BorderRadius.horizontal(
                                left: Radius.circular(8),
                              ),
                              child: SizedBox(
                                width: 112,
                                height: 76,
                                child: Image.network(
                                  episode.imageUrl,
                                  fit: BoxFit.cover,
                                  frameBuilder:
                                      (context, child, frame, wasSync) {
                                    if (wasSync || frame != null) {
                                      return child;
                                    }
                                    return AnimatedOpacity(
                                      opacity: frame == null ? 0 : 1,
                                      duration:
                                          const Duration(milliseconds: 220),
                                      child: child,
                                    );
                                  },
                                  errorBuilder: (_, __, ___) => Container(
                                    color: TanukiColors.backgroundAlt,
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${episode.episodeNumber}',
                                      style: const TextStyle(
                                        color: TanukiColors.muted,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${episode.episodeNumber}. ${episode.displayName}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: TanukiColors.text,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    LinearProgressIndicator(
                                      minHeight: 3,
                                      value: progress.clamp(0, 1),
                                      backgroundColor: const Color(0x334A5663),
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                        TanukiColors.orange,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (active)
                              const Padding(
                                padding: EdgeInsets.only(right: 10),
                                child: Icon(
                                  Icons.play_arrow,
                                  color: TanukiColors.orange,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
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
    required this.onEpisodes,
    required this.onFullscreen,
    required this.onControlFocusChanged,
    this.backButtonFocusNode,
    this.previousButtonFocusNode,
    this.nextButtonFocusNode,
    this.subtitlesButtonFocusNode,
    this.fitButtonFocusNode,
    this.settingsButtonFocusNode,
    this.episodesButtonFocusNode,
    this.fullscreenButtonFocusNode,
  });

  final EpisodeItem episode;
  final FocusNode? backButtonFocusNode;
  final FocusNode? previousButtonFocusNode;
  final FocusNode? nextButtonFocusNode;
  final FocusNode? subtitlesButtonFocusNode;
  final FocusNode? fitButtonFocusNode;
  final FocusNode? settingsButtonFocusNode;
  final FocusNode? episodesButtonFocusNode;
  final FocusNode? fullscreenButtonFocusNode;
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
  final VoidCallback onEpisodes;
  final VoidCallback onFullscreen;
  final ValueChanged<bool> onControlFocusChanged;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Container(
        color: const Color(0x96000000),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            FocusTraversalOrder(
              order: const NumericFocusOrder(1),
              child: _PlayerIconButton(
                icon: Icons.arrow_back,
                tooltip: 'Volver',
                focusNode: backButtonFocusNode,
                onPressed: onBack,
                onFocusChanged: onControlFocusChanged,
              ),
            ),
            const SizedBox(width: 10),
            FocusTraversalOrder(
              order: const NumericFocusOrder(2),
              child: _PlayerIconButton(
                icon: Icons.skip_previous,
                tooltip: 'Capitulo anterior',
                focusNode: previousButtonFocusNode,
                onPressed: onPrevious,
                onFocusChanged: onControlFocusChanged,
              ),
            ),
            const SizedBox(width: 10),
            FocusTraversalOrder(
              order: const NumericFocusOrder(3),
              child: _PlayerIconButton(
                icon: Icons.skip_next,
                tooltip: 'Capitulo siguiente',
                focusNode: nextButtonFocusNode,
                onPressed: onNext,
                onFocusChanged: onControlFocusChanged,
              ),
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
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
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
            FocusTraversalOrder(
              order: const NumericFocusOrder(4),
              child: _PlayerIconButton(
                icon: Icons.view_list,
                tooltip: 'Episodios',
                focusNode: episodesButtonFocusNode,
                onPressed: onEpisodes,
                onFocusChanged: onControlFocusChanged,
              ),
            ),
            const SizedBox(width: 10),
            FocusTraversalOrder(
              order: const NumericFocusOrder(5),
              child: _PlayerIconButton(
                icon: Icons.settings,
                tooltip: 'Ajustes',
                focusNode: settingsButtonFocusNode,
                onPressed: onSettings,
                onFocusChanged: onControlFocusChanged,
              ),
            ),
            const SizedBox(width: 10),
            FocusTraversalOrder(
              order: const NumericFocusOrder(6),
              child: _PlayerIconButton(
                icon: Icons.fullscreen,
                tooltip: 'Pantalla completa',
                focusNode: fullscreenButtonFocusNode,
                onPressed: onFullscreen,
                onFocusChanged: onControlFocusChanged,
              ),
            ),
          ],
        ),
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
                return const Color(0x3324384C);
              }
              return Colors.transparent;
            }),
            foregroundColor: MaterialStateProperty.all(Colors.white),
            side: MaterialStateProperty.all(BorderSide.none),
            shape: MaterialStateProperty.all(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
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

bool shouldAcceptPlaybackCompletion({
  required bool isRemote,
  required Duration position,
  required Duration duration,
}) {
  if (!isRemote) {
    return true;
  }
  if (duration < const Duration(minutes: 3)) {
    return false;
  }
  if (position < const Duration(minutes: 1)) {
    return false;
  }
  return duration - position <= const Duration(seconds: 35);
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
    'bilibili-1' => 'BiliBili 1',
    'bilibili-2' => 'BiliBili 2',
    'youtube-sub-1' => 'SUB Opcion 1',
    'youtube-sub-2' => 'SUB Opcion 2',
    'youtube-dub-1' => 'DUB Opcion 1',
    'youtube-dub-2' => 'DUB Opcion 2',
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

class _FadeInNetworkImage extends StatelessWidget {
  const _FadeInNetworkImage({
    required this.imageUrl,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.errorBuilder,
  });

  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      imageUrl,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      errorBuilder: errorBuilder,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) {
          return child;
        }
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: child,
        );
      },
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
                ? _FadeInNetworkImage(
                    imageUrl: episode.imageUrl,
                    fit: BoxFit.cover,
                  )
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
