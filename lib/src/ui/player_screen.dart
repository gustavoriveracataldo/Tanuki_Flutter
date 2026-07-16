import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_vlc/dart_vlc.dart' as vlc;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart' as vp;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../app_controller.dart';
import '../models.dart';
import '../services/playback_backend.dart';
import 'toonami_theme.dart';
import 'trailer_queue_screen.dart';

const _remotePlaybackUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';
const _remoteVideoFrameWatchdogDelay = Duration(seconds: 45);
const _remoteVideoFramePlaybackGrace = Duration(seconds: 35);
const _animeAv1PlaybackErrorFallbackDelay = Duration(seconds: 45);
const _playerOverlayAutoHideDelay = Duration(seconds: 5);
const _remoteSeekJumpThreshold = Duration(seconds: 45);
const _remoteSeekStallDelay = Duration(seconds: 11);
const _remoteOpeningRecoveryMaxAttempts = 1;
const _desktopVlcAudioRecoveryMaxAttempts = 10;
const _mediaKitMaxVolume = 100.0;
const _normalizedMaxVolume = 1.0;
const _youtubeMaxVolume = 100;
int _nextDesktopVlcPlayerId = 1;
const _androidHardwareDecoderCodecs = 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1';
const _androidHardwareDecoderCodecsWithoutAv1 =
    'h264,hevc,mpeg4,mpeg2video,vp8,vp9';

enum PlayerLaunchMode {
  normal,
  detail,
  playlist,
  continueWatching,
}

enum _UpcomingCardPhase {
  none,
  next,
  later,
}

class _ContinueWatchingCandidate {
  const _ContinueWatchingCandidate({
    required this.series,
    required this.episode,
    required this.progress,
  });

  final SeriesItem series;
  final EpisodeItem episode;
  final double progress;
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
  static final List<vlc.Player> _retiredRemoteVlcPlayers = <vlc.Player>[];
  static final Set<vlc.Player> _activeDesktopVlcPlayers = <vlc.Player>{};
  static bool _disposingRetiredVlc = false;

  Player? _player;
  VideoController? _videoController;
  vp.VideoPlayerController? _androidExoController;
  vlc.Player? _desktopVlcPlayer;
  String _desktopVlcSourcePath = '';
  List<RemoteCaptionCue> _desktopVlcSubtitleCues = const [];
  int _desktopSubtitleLoadTicket = 0;
  int _lastDesktopSubtitleCueIndex = -2;
  WebViewController? _youtubeWebController;
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
  bool _desktopVlcIsPlaying = false;
  bool _desktopVlcAudioFallbackHandled = false;
  bool _handlingAndroidExoError = false;
  bool _simklScrobbleActive = false;
  bool _remoteResumeRefined = false;
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
  RemoteProvider? _automaticResolvingProvider;
  String _selectedRemoteSubtitleTrackKey = '';
  final Set<RemoteProvider> _failedRemoteProviders = <RemoteProvider>{};
  final Set<String> _failedRemoteServers = <String>{};
  RemoteProvider? _serverFallbackProvider;
  DateTime _lastPlaybackSave = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPositionChangeAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;
  int _lastPositionDebugBucket = -1;
  int _lastBufferDebugBucket = -1;
  DateTime _lastAndroidExoRebuild = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, DateTime> _nativeLogLastPrintedAt = <String, DateTime>{};
  double _lastSimklScrobbleProgress = -1;
  Timer? _simklPauseDebounceTimer;
  Timer? _remoteVideoFrameWatchdogTimer;
  Timer? _remoteOpeningRecoveryTimer;
  Timer? _deferredAnimeAv1PlaybackErrorTimer;
  Timer? _playerOverlayHideTimer;
  Timer? _animeAv1SeekRecoveryTimer;
  Timer? _youtubeWebStateTimer;
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
  bool _openedNativeYoutubePlayer = false;
  bool _youtubeWebPlaying = false;
  bool _youtubeWebEnded = false;
  Duration _youtubeWebPosition = Duration.zero;
  Duration _youtubeWebDuration = Duration.zero;
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
      unawaited(_player!.setVolume(_mediaKitMaxVolume));
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
    _desktopSubtitleLoadTicket += 1;
    _schedulePlaybackFinalizationAfterDispose();
    _simklPauseDebounceTimer?.cancel();
    _playerOverlayHideTimer?.cancel();
    _animeAv1SeekRecoveryTimer?.cancel();
    _youtubeWebStateTimer?.cancel();
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
    unawaited(_disposeYoutubeWebPlayer());
    unawaited(_disposeDesktopVlcPlayer(delayForBiliBili: true));
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

  void _schedulePlaybackFinalizationAfterDispose() {
    final position = _lastPosition;
    final duration = _lastDuration;
    if (position <= Duration.zero && duration <= Duration.zero) {
      return;
    }
    final controller = widget.controller;
    final episode = widget.episode;
    Timer.run(() async {
      await controller.saveEpisodePlayback(
        episode,
        position: position,
        duration: duration,
      );
      if (duration > Duration.zero) {
        final completed = _meetsPlaybackCompletionThreshold(position, duration);
        await controller.sendSimklScrobble(
          episode,
          position: completed ? duration : position,
          duration: duration,
          action: completed ? 'stop' : 'pause',
        );
      }
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
    await _disposeYoutubeWebPlayer();
    var path = widget.episode.filePath.trim();
    _currentResolvedStream = null;
    _desktopSubtitleLoadTicket += 1;
    _desktopVlcSubtitleCues = const [];
    _lastDesktopSubtitleCueIndex = -2;
    _openedNativeYoutubePlayer = false;
    _remotePlaybackAccepted = false;
    _desktopVlcIsPlaying = false;
    _desktopVlcAudioFallbackHandled = false;
    _remoteOpeningRecoveryAttempts = 0;
    _playerOverlaysVisible = true;
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _lastPositionChangeAt = DateTime.now();
    _lastPositionDebugBucket = -1;
    _lastBufferDebugBucket = -1;
    if (path.isEmpty && !widget.episode.isRemote) {
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
        onProviderAttempt: (provider) {
          if (!mounted || openTicket != _openEpisodeTicket) return;
          setState(() => _automaticResolvingProvider = provider);
        },
      );
      if (!mounted || openTicket != _openEpisodeTicket) {
        _debugPlayerEvent('open discarded stale remote resolve');
        return;
      }
      _automaticResolvingProvider = null;
      if (resolved != null && resolved.playbackUrl.isNotEmpty) {
        _currentResolvedStream = resolved;
        _reconcileRemoteSubtitleSelection(resolved);
        await widget.controller.rememberResolvedPlaybackForEpisode(
          widget.episode,
          resolved,
        );
        if (!mounted || openTicket != _openEpisodeTicket) return;
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

    final pathLooksDirect = _looksLikeDirectVideo(path);
    final isResolvedRemotePlayback = _isCurrentResolvedPlaybackPath(path);
    if (widget.episode.isRemote &&
        !pathLooksDirect &&
        !isResolvedRemotePlayback) {
      _debugPlayerEvent(
        'open rejected unresolved remote path path=${_debugMediaLabel(path)}',
      );
      setState(() {
        _error =
            'Esta entrada remota necesita resolver web antes de entregar HLS, DASH o MP4.';
        _status = 'Resolver remoto pendiente';
      });
      return;
    }

    _currentPlaybackPath = path;
    _debugPlayerEvent(
      'open playback path ready resolved=$isResolvedRemotePlayback '
      'direct=$pathLooksDirect mounted=$mounted ticket=$openTicket/'
      '$_openEpisodeTicket usesVideoPlayer=$_usesAndroidExoPlayer '
      'usesDesktopVlc=$_usesDesktopVlcPlayer path=${_debugMediaLabel(path)}',
    );
    if (!mounted || openTicket != _openEpisodeTicket) {
      _debugPlayerEvent('open discarded stale playback path');
      return;
    }
    if (await _openYoutubeSeriesWebPlayerIfNeeded(path, openTicket)) {
      return;
    }
    if (_usesAndroidExoPlayer) {
      _debugPlayerEvent('open routing to video_player backend');
      await _openAndroidExoPlayer(path);
      return;
    }
    if (_usesDesktopVlcPlayer) {
      _debugPlayerEvent('open routing to desktop VLC backend');
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
      await player.setVolume(_mediaKitMaxVolume);
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
      unawaited(_loadDesktopVlcSubtitleCues());
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
    _debugPlayerEvent(
      'ExoPlayer prepare path=${_debugMediaLabel(path)} '
      'provider=${_currentResolvedStream?.provider?.id ?? 'none'} '
      'kind=${_currentResolvedStream?.playbackKind ?? 'unknown'}',
    );
    final previous = _androidExoController;
    if (previous != null) {
      _debugPlayerEvent('ExoPlayer dispose previous controller');
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
      _debugPlayerEvent('ExoPlayer initialize start');
      await controller.initialize().timeout(const Duration(seconds: 30));
      _debugPlayerEvent(
        'ExoPlayer initialize ok duration='
        '${_formatPlaybackTime(controller.value.duration)} '
        'size=${controller.value.size.width.toStringAsFixed(0)}x'
        '${controller.value.size.height.toStringAsFixed(0)}',
      );
      final resumePosition =
          widget.controller.resumePositionForEpisode(widget.episode);
      await controller.setVolume(_normalizedMaxVolume);
      await controller.seekTo(resumePosition ?? Duration.zero);
      _lastPosition = resumePosition ?? Duration.zero;
      _lastDuration = controller.value.duration;
      _lastPositionChangeAt = DateTime.now();
      await _applyAndroidExoSubtitleTrack();
      _debugPlayerEvent('ExoPlayer play start');
      await controller.play();
      _debugPlayerEvent('ExoPlayer play requested');
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

  Future<void> _openDesktopVlcPlayer(
    String path, {
    Duration? resumeOverride,
  }) async {
    await _disposeDesktopVlcPlayer(delayForBiliBili: true);
    _desktopVlcCompletionHandled = false;
    _setPlayerBuffering(true);

    final resumePosition = resumeOverride ??
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
        // Remote HLS segments sometimes arrive with PCR/PTS jitter above one
        // second. A three-second buffer gives libVLC enough margin without
        // disabling clock synchronization (which could desync A/V).
        '--network-caching=3000',
        '--live-caching=3000',
        '--http-reconnect',
        '--adaptive-logic=highest',
        if (audioSlave.isNotEmpty) '--input-slave=$audioSlave',
        if (referer.isNotEmpty) '--http-referrer=$referer',
      ],
    );
    _desktopVlcPlayer = player;
    _activeDesktopVlcPlayers.add(player);
    _desktopVlcSourcePath = path;
    player.setUserAgent(headers['User-Agent'] ?? _remotePlaybackUserAgent);
    player.setVolume(_normalizedMaxVolume);
    _desktopVlcPositionSubscription = player.positionStream.listen((state) {
      if (_desktopVlcPlayer != player) {
        return;
      }
      final previous = _lastPosition;
      _lastPosition = state.position ?? Duration.zero;
      _lastDuration = state.duration ?? Duration.zero;
      _maybeRefineRemoteResume(_lastDuration);
      _logDesktopSubtitleCueAtPosition();
      if (_lastPosition != previous) {
        _lastPositionChangeAt = DateTime.now();
        _remotePlaybackAccepted = true;
      }
      _maybeRetryDesktopVlcMissingVideoFrame(player, _lastPosition);
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
      _desktopVlcIsPlaying = state.isPlaying;
      _syncSimklPlaybackState(state.isPlaying);
      if (state.isPlaying) {
        _maybeRetryDesktopVlcMissingVideoFrame(player, _lastPosition);
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
      unawaited(
        _handleRemotePlaybackError(
          'VLC: $error',
          forceImmediate: true,
        ),
      );
    });
    _desktopVlcDimensionsSubscription =
        player.videoDimensionsStream.listen((dimensions) {
      if (!mounted || _desktopVlcPlayer != player) {
        return;
      }
      _remoteVideoWidth = dimensions.width;
      _remoteVideoHeight = dimensions.height;
      if (dimensions.width > 0 && dimensions.height > 0) {
        if (_shouldWatchAnimeAv1VideoFrame()) {
          _markRemoteVideoFrameReady();
        }
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
      _scheduleDesktopVlcAudioRecovery(player);
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
      unawaited(_loadDesktopVlcSubtitleCues());
      _scheduleOpeningUpcomingCards();
      _schedulePlayerOverlayHide();
    } catch (error) {
      await _disposeDesktopVlcPlayer(delayForBiliBili: true);
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

  void _scheduleDesktopVlcAudioRecovery(vlc.Player player, [int attempt = 1]) {
    unawaited(Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (!mounted || _desktopVlcPlayer != player) return;
      try {
        player.setVolume(_normalizedMaxVolume);
        final trackCount = player.audioTrackCount;
        _debugPlayerEvent(
          'VLC audio recovery attempt=$attempt tracks=$trackCount',
        );
        if (trackCount > 0) {
          player.setAudioTrack(1);
          _debugPlayerEvent('VLC audio recovery selected track=1');
          return;
        }
        if (shouldRetryMissingAudioTrack(
          isRemote: widget.episode.isRemote,
          hasVideoFrame:
              (_remoteVideoWidth ?? 0) > 0 && (_remoteVideoHeight ?? 0) > 0,
          audioTrackCount: trackCount,
          attempt: attempt,
          maxAttempts: _desktopVlcAudioRecoveryMaxAttempts,
        )) {
          _retryDesktopVlcMissingAudioTrack();
          return;
        }
      } catch (error) {
        _debugPlayerEvent('VLC audio recovery ignored error: $error');
      }
      // HLS often exposes its AAC elementary stream only after VLC has parsed
      // the first transport-stream segments. Keep trying instead of treating
      // the initial zero as a stream without audio.
      if (attempt < _desktopVlcAudioRecoveryMaxAttempts) {
        _scheduleDesktopVlcAudioRecovery(player, attempt + 1);
      }
    }));
  }

  void _retryDesktopVlcMissingAudioTrack() {
    if (_desktopVlcAudioFallbackHandled) {
      return;
    }
    final provider =
        _currentResolvedStream?.provider ?? widget.episode.provider;
    if (provider == null || !_supportsRemoteServerFallback(provider)) {
      return;
    }
    _desktopVlcAudioFallbackHandled = true;
    _debugPlayerEvent(
      'desktop VLC missing audio fallback '
      'provider=${provider.id} server=${_currentResolvedStream?.server ?? ''}',
    );
    unawaited(
      _retryRemoteServerFallback(
        provider,
        'VLC no detecto pista de audio',
      ),
    );
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

  Future<void> _disposeDesktopVlcPlayer({
    bool delayForBiliBili = false,
    bool treatAsBiliBili = false,
  }) async {
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
    final wasBiliBili = treatAsBiliBili ||
        _currentResolvedStream?.provider == RemoteProvider.bilibili;
    final retiredSourcePath = _desktopVlcSourcePath;
    _desktopVlcSourcePath = '';
    _desktopVlcIsPlaying = false;
    final playbackUri = Uri.tryParse(retiredSourcePath);
    final wasLoopbackProxy = playbackUri != null &&
        (playbackUri.host == '127.0.0.1' || playbackUri.host == 'localhost');
    for (final subscription in subscriptions) {
      await subscription?.cancel();
    }
    final player = _desktopVlcPlayer;
    _desktopVlcPlayer = null;
    if (player != null) {
      _activeDesktopVlcPlayers.remove(player);
      if (delayForBiliBili && widget.episode.isRemote) {
        // libVLC can still be reading a remote stream or local proxy while
        // buffering. Native stop/dispose can block Flutter's UI thread.
        // Stopping or disposing that native player synchronously is what can
        // freeze Linux when the user changes source or leaves the screen.
        _debugPlayerEvent(
          'VLC native dispose deferred '
          'bilibili=$wasBiliBili loopback=$wasLoopbackProxy',
        );
        try {
          player.setVolume(0);
          player.pause();
        } catch (_) {}
        if (wasLoopbackProxy) {
          widget.controller.retireRemotePlaybackProxy(retiredSourcePath);
        }
        _retiredRemoteVlcPlayers.add(player);
        _scheduleRetiredVlcDispose(player);
        _setPlayerBuffering(false);
        return;
      }
      try {
        player.stop();
      } catch (_) {}
      try {
        player.dispose();
      } catch (error) {
        _debugPlayerEvent('VLC dispose ignored error: $error');
      }
    }
    _setPlayerBuffering(false);
  }

  void _scheduleRetiredVlcDispose(vlc.Player player) {
    unawaited(Future<void>.delayed(const Duration(seconds: 3), () {
      if (_activeDesktopVlcPlayers.isNotEmpty ||
          _disposingRetiredVlc ||
          _remoteReloadInProgress) {
        _debugPlayerEvent(
          'VLC deferred native dispose waiting '
          'active=${_activeDesktopVlcPlayers.length} '
          'disposing=$_disposingRetiredVlc reload=$_remoteReloadInProgress',
        );
        _scheduleRetiredVlcDispose(player);
        return;
      }
      _debugPlayerEvent('VLC deferred native dispose start');
      _disposingRetiredVlc = true;
      try {
        player.dispose();
      } catch (_) {}
      unawaited(Future<void>.delayed(const Duration(seconds: 1), () {
        _retiredRemoteVlcPlayers.remove(player);
        _disposingRetiredVlc = false;
        _debugPlayerEvent('VLC deferred native dispose finished');
      }));
    }));
  }

  Future<bool> _openYoutubeSeriesWebPlayerIfNeeded(
    String path,
    int openTicket,
  ) async {
    if (_currentResolvedStream?.provider != RemoteProvider.youtube ||
        _openedNativeYoutubePlayer) {
      return false;
    }
    final videoId = youtubeVideoIdFromUrl(
      _currentResolvedStream?.pageUrl.trim().isNotEmpty == true
          ? _currentResolvedStream!.pageUrl
          : path,
    );
    if (videoId.isEmpty) {
      return false;
    }
    _openedNativeYoutubePlayer = true;
    _debugPlayerEvent('open routing YouTube to series WebView id=$videoId');
    final resumePosition =
        widget.controller.resumePositionForEpisode(widget.episode);
    final startPosition = initialMediaStartPosition(
          resumePosition: resumePosition,
          canStartAtPosition: true,
        ) ??
        Duration.zero;
    final controller = WebViewController();
    if (controller.platform is AndroidWebViewController) {
      await (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(Colors.black);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onWebResourceError: (error) {
          _debugPlayerEvent(
            'YouTube WebView resource error ${error.errorCode}: '
            '${error.description}',
          );
        },
      ),
    );
    await controller.addJavaScriptChannel(
      'TanukiSeriesYoutube',
      onMessageReceived: (message) {
        _handleYoutubeWebMessage(message.message);
      },
    );
    _youtubeWebController = controller;
    _youtubeWebPlaying = false;
    _youtubeWebEnded = false;
    _youtubeWebPosition = startPosition;
    _youtubeWebDuration = _expectedRemoteDuration;
    _lastPosition = startPosition;
    _lastDuration = _youtubeWebDuration;
    _lastPositionChangeAt = DateTime.now();
    _setPlayerBuffering(true);
    if (mounted) {
      setState(() {
        _openedMedia = true;
        _error = '';
        _status = startPosition > Duration.zero
            ? 'YouTube reanudado en ${_formatPlaybackTime(startPosition)}'
            : 'Reproduciendo YouTube';
      });
    }
    await controller.loadHtmlString(
      _youtubeSeriesWebPlayerHtml(
        videoId: videoId,
        startPosition: startPosition,
        title: widget.episode.displayName,
        sourceLabel: _sourceStatus().label,
        desktopControls: _usesDesktopYoutubeWebControls,
      ),
      baseUrl: 'https://www.youtube-nocookie.com',
    );
    if (!mounted || openTicket != _openEpisodeTicket) {
      return true;
    }
    _startYoutubeWebStateTimer();
    _remotePlaybackAccepted = true;
    _startSimklScrobble();
    _scheduleOpeningUpcomingCards();
    _schedulePlayerOverlayHide();
    return true;
  }

  Future<void> _disposeYoutubeWebPlayer() async {
    _youtubeWebStateTimer?.cancel();
    _youtubeWebStateTimer = null;
    final controller = _youtubeWebController;
    _youtubeWebController = null;
    _youtubeWebPlaying = false;
    _youtubeWebEnded = false;
    _youtubeWebPosition = Duration.zero;
    _youtubeWebDuration = Duration.zero;
    if (controller == null) {
      return;
    }
    try {
      await controller.runJavaScript('try { tanukiPause(); } catch (e) {}');
      await controller.loadHtmlString(
        '<!doctype html><html><body style="margin:0;background:#000"></body></html>',
        baseUrl: 'about:blank',
      );
    } catch (_) {}
  }

  void _startYoutubeWebStateTimer() {
    _youtubeWebStateTimer?.cancel();
    _youtubeWebStateTimer =
        Timer.periodic(const Duration(milliseconds: 750), (_) {
      final controller = _youtubeWebController;
      if (!mounted || controller == null) {
        return;
      }
      unawaited(
        controller.runJavaScript('try { tanukiNotifyState(); } catch (e) {}'),
      );
    });
  }

  void _handleYoutubeWebMessage(String payload) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (error) {
      _debugPlayerEvent('YouTube WebView ignored message: $error');
      return;
    }
    if (decoded is! Map) {
      return;
    }
    final message = decoded;
    final type = '${message['type'] ?? ''}';
    if (type == 'command') {
      _handleYoutubeWebCommand('${message['command'] ?? ''}');
      return;
    }
    if (type == 'ready') {
      _setPlayerBuffering(false);
      return;
    }
    if (type == 'buffering') {
      _setPlayerBuffering(true);
      return;
    }
    if (type == 'error') {
      if (mounted) {
        setState(() {
          _status = 'Error de YouTube';
          _error =
              'YouTube no pudo reproducir este video (${message['detail'] ?? 'error'}).';
        });
      }
      _setPlayerBuffering(false);
      return;
    }
    if (type == 'ended') {
      _youtubeWebEnded = true;
      _youtubeWebPlaying = false;
      _setPlayerBuffering(false);
      if (!_completionCommitted && _shouldAcceptPlaybackCompletion()) {
        unawaited(_commitPlaybackCompletion());
        if (mounted) {
          unawaited(_playNext());
        }
      }
      return;
    }
    if (type != 'state') {
      return;
    }
    final positionSeconds = _readYoutubeWebSeconds(message['position']);
    final durationSeconds = _readYoutubeWebSeconds(message['duration']);
    final state = '${message['state'] ?? ''}';
    final previous = _youtubeWebPosition;
    _youtubeWebPosition =
        Duration(milliseconds: (positionSeconds * 1000).round());
    if (durationSeconds > 0) {
      _youtubeWebDuration =
          Duration(milliseconds: (durationSeconds * 1000).round());
    }
    _youtubeWebPlaying = state == 'playing';
    _youtubeWebEnded = state == 'ended';
    _lastPosition = _youtubeWebPosition;
    _lastDuration = _youtubeWebDuration;
    _syncSimklPlaybackState(_youtubeWebPlaying);
    if (_youtubeWebPosition != previous) {
      _lastPositionChangeAt = DateTime.now();
    }
    _maybeScheduleUpcomingCards(_youtubeWebPosition);
    _persistPlaybackThrottled();
    if (mounted) {
      setState(() {});
    }
  }

  void _handleYoutubeWebCommand(String command) {
    _showPlayerOverlays();
    switch (command) {
      case 'back':
        Navigator.of(context).maybePop();
        return;
      case 'previous':
        unawaited(_playPrevious());
        return;
      case 'next':
        unawaited(_playNext());
        return;
      case 'settings':
        unawaited(_showPlayerSettingsDialog());
        return;
      case 'episodes':
        unawaited(_showEpisodeListPanel());
        return;
      case 'fullscreen':
        unawaited(_toggleFullscreenMode());
        return;
      default:
        return;
    }
  }

  double _readYoutubeWebSeconds(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse('$value') ?? 0;
  }

  bool get _usesDesktopYoutubeWebControls {
    if (_currentResolvedStream?.provider != RemoteProvider.youtube) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  Future<void> _toggleYoutubeWebPlayback() async {
    final controller = _youtubeWebController;
    if (controller == null) {
      return;
    }
    if (_youtubeWebEnded) {
      await _seekYoutubeWebPlayer(Duration.zero);
      _youtubeWebEnded = false;
    }
    await controller.runJavaScript('try { tanukiToggle(); } catch (e) {}');
    _showPlayerOverlays();
  }

  Future<void> _seekYoutubeWebPlayer(Duration target) async {
    final controller = _youtubeWebController;
    if (controller == null) {
      return;
    }
    final seconds = max(0, target.inMilliseconds / 1000).toStringAsFixed(3);
    await controller
        .runJavaScript('try { tanukiSeekTo($seconds); } catch (e) {}');
    _youtubeWebPosition = target;
    _lastPosition = target;
    _lastPositionChangeAt = DateTime.now();
    _youtubeWebEnded = false;
    unawaited(_persistPlayback(force: true));
    _showPlayerOverlays();
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
    _syncSimklPlaybackState(value.isPlaying);
    final previous = _lastPosition;
    _lastPosition = value.position;
    _lastDuration = value.duration;
    _maybeRefineRemoteResume(value.duration);
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

  void _maybeRefineRemoteResume(Duration duration) {
    if (_remoteResumeRefined || duration <= Duration.zero) {
      return;
    }
    final target = widget.controller.refinedRemoteResumePositionForEpisode(
      widget.episode,
      duration,
    );
    if (target == null) {
      return;
    }
    _remoteResumeRefined = true;
    if ((target - _lastPosition).abs() < const Duration(seconds: 8)) {
      return;
    }
    _debugPlayerEvent(
      'refining SIMKL resume to ${_formatPlaybackTime(target)} '
      'using actual duration ${_formatPlaybackTime(duration)}',
    );
    if (_usesDesktopVlcPlayer) {
      unawaited(_seekDesktopVlcPlayer(target));
    } else if (_usesAndroidExoPlayer) {
      unawaited(_seekAndroidExoPlayer(target));
    } else if (_youtubeWebController != null) {
      unawaited(_seekYoutubeWebPlayer(target));
    } else if (_player != null) {
      unawaited(_seekPrecisely(_player!, target));
    }
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
      _syncSimklPlaybackState(playing);
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

  void _maybeRetryDesktopVlcMissingVideoFrame(
    vlc.Player player,
    Duration position,
  ) {
    if (!mounted ||
        _desktopVlcPlayer != player ||
        _remoteVideoFrameFallbackHandled ||
        !_shouldWatchAnimeAv1VideoFrame()) {
      return;
    }
    if (!shouldRetryMissingVideoFrame(
      isPlaying: _desktopVlcIsPlaying,
      isBuffering: _playerBuffering,
      position: position,
      width: _remoteVideoWidth,
      height: _remoteVideoHeight,
    )) {
      return;
    }
    _debugPlayerEvent(
      'desktop VLC missing video fallback position='
      '${_formatPlaybackTime(position)} ${_remoteVideoWidth ?? 0}x'
      '${_remoteVideoHeight ?? 0}',
    );
    _remoteVideoFrameFallbackHandled = true;
    unawaited(_retryRemoteFallback('AnimeAV1 reprodujo audio pero no video'));
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
        provider == RemoteProvider.latAnime ||
        provider == RemoteProvider.justAnime ||
        provider == RemoteProvider.aniPm;
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
    if (uri.host.endsWith('calm-koi.workers.dev')) {
      headers['Referer'] = 'https://www.justanime.to/';
      headers['Origin'] = 'https://www.justanime.to';
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
    final wasBiliBili =
        _currentResolvedStream?.provider == RemoteProvider.bilibili;
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
      await _disposeDesktopVlcPlayer(
        delayForBiliBili: true,
        treatAsBiliBili: wasBiliBili,
      );
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
      _maybeRefineRemoteResume(duration);
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
    _simklPauseDebounceTimer?.cancel();
    _completionCommitted = true;
    await _persistPlayback(force: true, completed: true);
    await _stopSimklScrobble();
  }

  void _startSimklScrobble() {
    if (_simklScrobbleActive) {
      if (_lastSimklScrobbleProgress < 0 && _lastDuration > Duration.zero) {
        unawaited(_sendSimklScrobble('start', force: true));
      }
      return;
    }
    _simklScrobbleActive = true;
    _lastSimklScrobbleProgress = -1;
    unawaited(_sendSimklScrobble('start', force: true));
  }

  void _syncSimklPlaybackState(bool playing) {
    _simklPauseDebounceTimer?.cancel();
    _simklPauseDebounceTimer = null;
    if (playing) {
      _startSimklScrobble();
      return;
    }
    if (!_simklScrobbleActive || _completionCommitted) {
      return;
    }
    _simklPauseDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _simklPauseDebounceTimer = null;
      if (mounted && !_completionCommitted) {
        unawaited(_pauseSimklScrobble());
      }
    });
  }

  Future<void> _pauseSimklScrobble() async {
    if (!_simklScrobbleActive) {
      return;
    }
    final completed =
        _meetsPlaybackCompletionThreshold(_lastPosition, _lastDuration);
    await _sendSimklScrobble(
      completed ? 'stop' : 'pause',
      force: true,
      completed: completed,
    );
    _simklScrobbleActive = false;
  }

  Future<void> _stopSimklScrobble() async {
    if (!_simklScrobbleActive) {
      return;
    }
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
    final sent = await widget.controller.sendSimklScrobble(
      widget.episode,
      position: completed ? _lastDuration : _lastPosition,
      duration: _lastDuration,
      action: action,
    );
    if (sent) {
      _lastSimklScrobbleProgress = progress;
    }
  }

  bool _meetsPlaybackCompletionThreshold(
    Duration position,
    Duration duration,
  ) {
    if (duration <= Duration.zero) {
      return false;
    }
    return position.inMilliseconds * 100 >=
        duration.inMilliseconds *
            EpisodePlaybackRecord.completionThresholdPercent;
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
    final attemptingProvider =
        stream == null ? _automaticResolvingProvider : null;
    final provider = stream?.provider ??
        attemptingProvider ??
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
      RemoteProvider.justAnime => stream?.server.trim().isNotEmpty == true
          ? '${justAnimePlaybackModeFromId(stream!.selectedMode).buttonLabel} / ${remoteServerLabel(stream.server)}'
          : widget.controller
              .justAnimeModeForEpisode(widget.episode)
              .buttonLabel,
      RemoteProvider.aniPm => stream?.server.trim().isNotEmpty == true
          ? '${aniPmPlaybackModeFromId(stream!.selectedMode).buttonLabel} / ${remoteServerLabel(stream.server)}'
          : widget.controller.aniPmModeForEpisode(widget.episode).buttonLabel,
      RemoteProvider.facebook =>
        widget.controller.facebookModeForEpisode(widget.episode).buttonLabel,
      RemoteProvider.internetArchive => stream?.server.trim().isNotEmpty == true
          ? remoteServerLabel(stream!.server)
          : 'Directo',
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
    if (attemptingProvider != null) {
      return 'Intentando: $label';
    }
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
      RemoteProvider.justAnime,
      RemoteProvider.aniPm,
      RemoteProvider.internetArchive,
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
        !_upcomingCardsEnabled ||
        _upcomingEntriesAfterCurrent().isEmpty) {
      return;
    }
    final ticket = _upcomingCardTicket;
    _upcomingCardStartTimer?.cancel();
    _upcomingCardStartTimer = Timer(const Duration(seconds: 30), () {
      _upcomingCardStartTimer = null;
      if (!mounted ||
          ticket != _upcomingCardTicket ||
          _startUpcomingCardsShown ||
          !_upcomingCardsEnabled ||
          _upcomingEntriesAfterCurrent().isEmpty) {
        return;
      }
      _startUpcomingCardsShown = true;
      _runUpcomingCardSequence();
    });
  }

  void _maybeScheduleUpcomingCards(Duration position) {
    if (!_upcomingCardsEnabled ||
        position < Duration.zero ||
        _upcomingCardPhase != _UpcomingCardPhase.none ||
        _upcomingCardSequenceTimer != null) {
      return;
    }
    if (_upcomingEntriesAfterCurrent().isEmpty) {
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
      if (_upcomingEntriesAfterCurrent().length < 2) {
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

  bool get _upcomingCardsEnabled {
    return widget.launchMode == PlayerLaunchMode.playlist
        ? widget.controller.state.showPlaylistUpcomingCards
        : widget.controller.state.showSeriesUpcomingCards;
  }

  List<EpisodeItem> _upcomingEntriesAfterCurrent() {
    return switch (widget.launchMode) {
      PlayerLaunchMode.playlist => _playlistEntriesAfterCurrent(limit: 2),
      PlayerLaunchMode.continueWatching =>
        _continueWatchingEntriesAfterCurrent(limit: 2),
      _ => _seriesEntriesAfterCurrent(limit: 2),
    };
  }

  List<EpisodeItem> _playlistEntriesAfterCurrent({required int limit}) {
    return widget.controller
        .buildNextEntries(limit: limit + 2)
        .where((entry) => !_isSameEpisode(entry, widget.episode))
        .take(limit)
        .toList(growable: false);
  }

  List<EpisodeItem> _continueWatchingEntriesAfterCurrent({
    required int limit,
  }) {
    final sameSeriesEntries = _seriesEntriesAfterCurrent(limit: limit);
    if (sameSeriesEntries.isNotEmpty) {
      return sameSeriesEntries;
    }

    final currentSeries = widget.controller.findSeriesForEpisode(
      widget.episode,
    );
    final currentKey =
        currentSeries?.stableKey ?? _seriesKeyFor(widget.episode);
    final entries = <_ContinueWatchingCandidate>[];
    final profile = widget.controller.state.profile;
    for (final series in widget.controller.library) {
      if (series.stableKey == currentKey) {
        continue;
      }
      if (profile.completedSeries.contains(series.stableKey) ||
          profile.abandonedSeries.contains(series.stableKey)) {
        continue;
      }
      final watched = widget.controller.watchedCountFor(series);
      final partialEpisode = _partialPlaybackEpisode(series);
      final shouldInclude = profile.watchingSeries.contains(series.stableKey) ||
          partialEpisode != null ||
          watched > 0;
      if (!shouldInclude) {
        continue;
      }
      final episode = _continueWatchingEpisodeForSeries(series);
      if (episode == null) {
        continue;
      }
      final progress = _continueWatchingProgress(series, episode);
      entries.add(
        _ContinueWatchingCandidate(
          series: series,
          episode: episode,
          progress: progress,
        ),
      );
    }
    entries.sort((left, right) {
      final progressCompare = right.progress.compareTo(left.progress);
      if (progressCompare != 0) {
        return progressCompare;
      }
      return left.series.name.toLowerCase().compareTo(
            right.series.name.toLowerCase(),
          );
    });
    return entries
        .map((entry) => entry.episode)
        .take(limit)
        .toList(growable: false);
  }

  List<EpisodeItem> _seriesEntriesAfterCurrent({required int limit}) {
    final series = widget.controller.findSeriesForEpisode(widget.episode);
    if (series == null || series.episodes.isEmpty) {
      return const [];
    }
    final episodes = [...series.episodes]..sort(
        (left, right) => left.episodeIndex.compareTo(right.episodeIndex),
      );
    final currentIndex = episodes.indexWhere(
      (entry) => _isSameEpisode(entry, widget.episode),
    );
    if (currentIndex < 0) {
      return const [];
    }
    return episodes
        .skip(currentIndex + 1)
        .where(_canShowUpcomingEpisode)
        .take(limit)
        .toList(growable: false);
  }

  EpisodeItem? _continueWatchingEpisodeForSeries(SeriesItem series) {
    final partial = _partialPlaybackEpisode(series);
    if (partial != null) {
      return partial;
    }
    final episodes = [...series.episodes]..sort(
        (left, right) => left.episodeIndex.compareTo(right.episodeIndex),
      );
    if (episodes.isEmpty) {
      return null;
    }
    final watched = widget.controller.watchedCountFor(series);
    if (watched >= episodes.length) {
      return null;
    }
    for (final episode in episodes.skip(watched)) {
      if (_canShowUpcomingEpisode(episode)) {
        return episode;
      }
    }
    return null;
  }

  EpisodeItem? _partialPlaybackEpisode(SeriesItem series) {
    final episodes = [...series.episodes]..sort(
        (left, right) => left.episodeIndex.compareTo(right.episodeIndex),
      );
    for (final episode in episodes) {
      final playback = widget.controller.playbackForEpisode(episode);
      if (playback != null &&
          !playback.completed &&
          playback.positionMs > 1000) {
        return episode;
      }
    }
    return null;
  }

  double _continueWatchingProgress(SeriesItem series, EpisodeItem episode) {
    final playback = widget.controller.playbackForEpisode(episode);
    if (playback?.completed == true) {
      return 1;
    }
    if (playback != null && playback.durationMs > 0) {
      return (playback.positionMs / playback.durationMs).clamp(0, 1).toDouble();
    }
    final total =
        series.episodeCount > 0 ? series.episodeCount : series.episodes.length;
    if (total <= 0) {
      return playback != null && playback.positionMs > 1000 ? 0.08 : 0;
    }
    return (widget.controller.watchedCountFor(series) / total)
        .clamp(0, 1)
        .toDouble();
  }

  bool _canShowUpcomingEpisode(EpisodeItem episode) {
    if (_episodeAirsInFuture(episode.airDateIso)) {
      return false;
    }
    final tag = episode.episodeTag.trim().toLowerCase();
    if (widget.controller.state.skipFillerEpisodes && tag == 'filler') {
      return false;
    }
    if (widget.controller.state.skipMixedEpisodes && tag == 'mixed') {
      return false;
    }
    return true;
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
    final nextEntries = _upcomingEntriesAfterCurrent();
    final visibleUpcomingCard = _visibleUpcomingCardEpisode(nextEntries);
    final sourceStatus = _sourceStatus();
    final useDesktopYoutubeWebControls = _openedMedia &&
        _youtubeWebController != null &&
        _usesDesktopYoutubeWebControls;
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
                    : _openedMedia && _youtubeWebController != null
                        ? _YoutubeWebVideoSurface(
                            controller: _youtubeWebController!,
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
                                      fit: _boxFitForVideoScaleMode(
                                          _videoScaleMode),
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
              if (_openedMedia &&
                  _desktopVlcPlayer != null &&
                  _activeDesktopVlcCaption.isNotEmpty)
                Positioned(
                  left: 32,
                  right: 32,
                  bottom: 72,
                  child: IgnorePointer(
                    child: Text(
                      _activeDesktopVlcCaption,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        shadows: [
                          Shadow(color: Colors.black, blurRadius: 4),
                          Shadow(
                            color: Colors.black,
                            blurRadius: 2,
                            offset: Offset(2, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_openedMedia &&
                  _playerBuffering &&
                  !useDesktopYoutubeWebControls)
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
              if (!useDesktopYoutubeWebControls)
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
                        onSettings: _showPlayerSettingsDialog,
                        onEpisodes: () => unawaited(_showEpisodeListPanel()),
                        onFullscreen: () => unawaited(_toggleFullscreenMode()),
                        onControlFocusChanged: _setPlayerControlsFocused,
                        backButtonFocusNode: _playerBackButtonFocusNode,
                        previousButtonFocusNode: _playerPreviousButtonFocusNode,
                        nextButtonFocusNode: _playerNextButtonFocusNode,
                        settingsButtonFocusNode: _playerSettingsButtonFocusNode,
                        episodesButtonFocusNode: _playerEpisodesButtonFocusNode,
                        fullscreenButtonFocusNode:
                            _playerFullscreenButtonFocusNode,
                      ),
                    ),
                  ),
                ),
              if (_upcomingCardsEnabled)
                Positioned(
                  right: 46,
                  bottom: 72,
                  child: IgnorePointer(
                    ignoring: true,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      reverseDuration: const Duration(milliseconds: 260),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: visibleUpcomingCard == null
                          ? const SizedBox(
                              key: ValueKey('upcoming-none'),
                              width: 300,
                              height: 170,
                            )
                          : KeyedSubtree(
                              key: ValueKey(
                                'upcoming-${_upcomingCardPhase.name}-'
                                '${_seriesKeyFor(visibleUpcomingCard)}-'
                                '${visibleUpcomingCard.episodeNumber}',
                              ),
                              child: _UpcomingCard(
                                label: _visibleUpcomingCardLabel(),
                                labelColor: _visibleUpcomingCardColor(),
                                episode: visibleUpcomingCard,
                              ),
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
              if (_openedMedia &&
                  _youtubeWebController != null &&
                  !useDesktopYoutubeWebControls)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 10,
                  child: IgnorePointer(
                    ignoring: !_playerOverlaysVisible,
                    child: AnimatedOpacity(
                      opacity: _playerOverlaysVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: _YoutubeWebControls(
                        isPlaying: _youtubeWebPlaying,
                        position: _youtubeWebPosition,
                        duration: _youtubeWebDuration,
                        onTogglePlayback: _toggleYoutubeWebPlayback,
                        onSeek: _seekYoutubeWebPlayer,
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
      } else if (_youtubeWebController != null) {
        unawaited(_toggleYoutubeWebPlayback());
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
      await _loadDesktopVlcSubtitleCues();
      return;
    }
    final player = _player;
    if (player == null || !_openedMedia) {
      return;
    }
    await _applyRemoteSubtitleTrack(player);
  }

  Future<void> _loadDesktopVlcSubtitleCues() async {
    final loadTicket = ++_desktopSubtitleLoadTicket;
    _debugPlayerEvent(
      'desktop subtitle load requested enabled=$_subtitlesEnabled '
      'tracks=${_currentResolvedStream?.subtitleTracks.length ?? 0} '
      'selected=${_selectedRemoteSubtitleTrackKey.isEmpty ? "default" : _selectedRemoteSubtitleTrackKey}',
    );
    if (!_subtitlesEnabled) {
      if (mounted) setState(() => _desktopVlcSubtitleCues = const []);
      return;
    }
    _reconcileRemoteSubtitleSelection(_currentResolvedStream);
    final track = selectRemoteSubtitleTrack(
      _currentResolvedStream,
      selectedKey: _selectedRemoteSubtitleTrackKey,
    );
    if (track == null) {
      _debugPlayerEvent('desktop subtitle: no selected track');
      if (mounted) setState(() => _desktopVlcSubtitleCues = const []);
      return;
    }
    final trackKey = remoteSubtitleTrackKey(track);
    try {
      _debugPlayerEvent(
        'desktop subtitle download start '
        'track="${remoteSubtitleTrackLabel(track)}" '
        'url=${_debugMediaLabel(track.url)} '
        'headers=${_debugHeadersLabel(_remoteMediaHeaders(track.url) ?? const {})}',
      );
      final response = await http.get(
        Uri.parse(track.url),
        headers: _remoteMediaHeaders(track.url),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Subtitle HTTP ${response.statusCode}');
      }
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final cues = parseRemoteCaptionCues(body);
      _debugPlayerEvent(
        'desktop subtitle download HTTP ${response.statusCode} '
        'bytes=${response.bodyBytes.length} cues=${cues.length} '
        'first=${cues.isEmpty ? "none" : _formatPlaybackTime(cues.first.start)} '
        'last=${cues.isEmpty ? "none" : _formatPlaybackTime(cues.last.end)}',
      );
      if (!mounted ||
          loadTicket != _desktopSubtitleLoadTicket ||
          trackKey != _selectedRemoteSubtitleTrackKey) {
        _debugPlayerEvent('desktop subtitle download discarded stale result');
        return;
      }
      setState(() {
        _desktopVlcSubtitleCues = cues;
        _lastDesktopSubtitleCueIndex = -2;
        _status = cues.isEmpty
            ? 'El archivo de subtitulos esta vacio'
            : 'Subtitulos: ${remoteSubtitleTrackLabel(track)}';
      });
    } catch (error) {
      if (!mounted || loadTicket != _desktopSubtitleLoadTicket) return;
      setState(() {
        _desktopVlcSubtitleCues = const [];
        _status = 'No se pudo cargar subtitulos';
      });
      _debugPlayerEvent('desktop subtitle load failed: $error');
    }
  }

  String get _activeDesktopVlcCaption {
    if (!_subtitlesEnabled || _desktopVlcSubtitleCues.isEmpty) return '';
    for (final cue in _desktopVlcSubtitleCues) {
      if (_lastPosition >= cue.start && _lastPosition < cue.end) {
        return cue.text;
      }
    }
    return '';
  }

  void _logDesktopSubtitleCueAtPosition() {
    if (_desktopVlcSubtitleCues.isEmpty) return;
    final index = _desktopVlcSubtitleCues.indexWhere(
      (cue) => _lastPosition >= cue.start && _lastPosition < cue.end,
    );
    if (index == _lastDesktopSubtitleCueIndex) return;
    _lastDesktopSubtitleCueIndex = index;
    if (index >= 0) {
      final cue = _desktopVlcSubtitleCues[index];
      _debugPlayerEvent(
        'desktop subtitle visible cue=$index '
        'at=${_formatPlaybackTime(_lastPosition)} '
        'range=${_formatPlaybackTime(cue.start)}-${_formatPlaybackTime(cue.end)} '
        'text="${cue.text.replaceAll('\n', ' / ')}"',
      );
    }
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

  Future<void> _showSubtitleTrackDialog() async {
    final tracks =
        _currentResolvedStream?.subtitleTracks ?? const <RemoteSubtitleTrack>[];
    if (tracks.isEmpty) {
      if (mounted) {
        setState(() {
          _status = 'Esta fuente no ofrece subtitulos';
        });
      }
      return;
    }
    _showPlayerOverlays();
    final selected = await showDialog<String>(
      context: context,
      barrierColor: const Color(0xAA000000),
      builder: (context) => SimpleDialog(
        backgroundColor: TanukiColors.panelSolid,
        title: const Text('Subtitulos disponibles'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, '__off__'),
            child: Row(
              children: [
                Icon(
                  !_subtitlesEnabled
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: TanukiColors.orange,
                ),
                const SizedBox(width: 10),
                const Text('Desactivados'),
              ],
            ),
          ),
          for (final track in tracks)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, remoteSubtitleTrackKey(track)),
              child: Row(
                children: [
                  Icon(
                    _subtitlesEnabled &&
                            _selectedRemoteSubtitleTrackKey ==
                                remoteSubtitleTrackKey(track)
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: TanukiColors.orange,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(remoteSubtitleTrackLabel(track))),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    _debugPlayerEvent(
        'subtitle dialog selected key=$selected tracks=${tracks.length}');
    setState(() {
      _subtitlesEnabled = selected != '__off__';
      if (_subtitlesEnabled) _selectedRemoteSubtitleTrackKey = selected;
      _status = _subtitlesEnabled
          ? 'Subtitulos: ${remoteSubtitleTrackLabel(tracks.firstWhere(
              (track) => remoteSubtitleTrackKey(track) == selected,
            ))}'
          : 'Subtitulos desactivados';
    });
    await _applyRemoteSubtitleTrackIfReady();
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
            final latAnimeServer =
                _currentResolvedStream?.provider == RemoteProvider.latAnime &&
                        _currentResolvedStream?.server.trim().isNotEmpty == true
                    ? latAnimeServerPreferenceFromId(
                        _currentResolvedStream!.server,
                      )
                    : latAnimeServerPreferenceFromId(preference.latAnimeServer);
            final justAnimeMode =
                justAnimePlaybackModeFromId(preference.justAnimeMode);
            final justAnimeServer = _currentResolvedStream?.provider ==
                        RemoteProvider.justAnime &&
                    _currentResolvedStream?.server.trim().isNotEmpty == true
                ? justAnimeServerPreferenceFromId(
                    _currentResolvedStream!.server)
                : justAnimeServerPreferenceFromId(preference.justAnimeServer);
            final aniPmMode = aniPmPlaybackModeFromId(preference.aniPmMode);
            final aniPmServer =
                _currentResolvedStream?.provider == RemoteProvider.aniPm &&
                        _currentResolvedStream?.server.trim().isNotEmpty == true
                    ? _currentResolvedStream!.server.trim().toLowerCase()
                    : preference.aniPmServer.trim().toLowerCase();
            final facebookMode =
                facebookPlaybackModeFromId(preference.facebookMode);
            final facebookOption =
                facebookPlaybackOptionFromId(preference.facebookOption);
            final youtubeMode =
                youtubePlaybackModeFromId(preference.youtubeMode);
            final youtubeOption =
                youtubePlaybackOptionFromId(preference.youtubeOption);

            Future<void> savePreference(Future<void> Function() save) async {
              final wasBiliBili =
                  _currentResolvedStream?.provider == RemoteProvider.bilibili;
              await save();
              if (!mounted || !dialogContext.mounted) {
                return;
              }
              setDialogState(() {
                preference = widget.controller
                    .playbackPreferenceForEpisode(widget.episode);
              });
              if (widget.episode.isRemote) {
                if (wasBiliBili) {
                  await _disposeDesktopVlcPlayer(
                    delayForBiliBili: true,
                    treatAsBiliBili: true,
                  );
                  await Future<void>.delayed(
                    const Duration(milliseconds: 120),
                  );
                }
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
                      _PlayerDialogRadioButton(
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
                final availableServers = _availableJkAnimeServers();
                return _PlayerDialogScrollableRadioColumn(
                  children: [
                    for (final server in availableServers)
                      _PlayerDialogRadioButton(
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
              if (provider == RemoteProvider.latAnime) {
                return _PlayerDialogScrollableRadioColumn(
                  children: [
                    for (final server in LatAnimeServerPreference.values)
                      _PlayerDialogRadioButton(
                        label: server.label,
                        active: latAnimeServer == server,
                        onPressed: () => unawaited(
                          savePreference(
                            () => widget.controller.setLatAnimeServerForEpisode(
                              widget.episode,
                              server,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              }
              if (provider == RemoteProvider.justAnime) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _PlayerDialogSectionTitle('Audio'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final mode in JustAnimePlaybackMode.values)
                          _PlayerDialogRadioButton(
                            label: mode.buttonLabel,
                            active: justAnimeMode == mode,
                            onPressed: () => unawaited(savePreference(
                              () => widget.controller
                                  .setJustAnimeModeForEpisode(
                                      widget.episode, mode),
                            )),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const _PlayerDialogSectionTitle('Servidor'),
                    const SizedBox(height: 8),
                    _PlayerDialogScrollableRadioColumn(
                      children: [
                        for (final server in JustAnimeServerPreference.values)
                          _PlayerDialogRadioButton(
                            label: server.label,
                            active: justAnimeServer == server,
                            onPressed: () => unawaited(savePreference(
                              () => widget.controller
                                  .setJustAnimeServerForEpisode(
                                widget.episode,
                                server,
                              ),
                            )),
                          ),
                      ],
                    ),
                  ],
                );
              }
              if (provider == RemoteProvider.aniPm) {
                final resolvedServers = <String>[
                  if (_currentResolvedStream?.provider == RemoteProvider.aniPm)
                    ..._currentResolvedStream!.availableModes,
                ];
                resolvedServers.sort((left, right) => remoteServerLabel(left)
                    .compareTo(remoteServerLabel(right)));
                final servers = <String>{
                  if (aniPmServer.isNotEmpty) aniPmServer,
                  ...resolvedServers,
                }.toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _PlayerDialogSectionTitle('Audio'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final mode in AniPmPlaybackMode.values)
                          _PlayerDialogRadioButton(
                            label: mode.buttonLabel,
                            active: aniPmMode == mode,
                            onPressed: () => unawaited(savePreference(
                              () => widget.controller
                                  .setAniPmModeForEpisode(widget.episode, mode),
                            )),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const _PlayerDialogSectionTitle('Servidor'),
                    const SizedBox(height: 8),
                    _PlayerDialogScrollableRadioColumn(
                      children: [
                        _PlayerDialogRadioButton(
                          label: 'Automatico',
                          active: aniPmServer.isEmpty,
                          onPressed: () => unawaited(savePreference(
                            () => widget.controller
                                .setAniPmServerForEpisode(widget.episode, ''),
                          )),
                        ),
                        for (final server in servers)
                          _PlayerDialogRadioButton(
                            label: remoteServerLabel(server),
                            active: aniPmServer == server,
                            onPressed: () => unawaited(savePreference(
                              () => widget.controller.setAniPmServerForEpisode(
                                  widget.episode, server),
                            )),
                          ),
                      ],
                    ),
                    if (resolvedServers.isEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Los servidores disponibles apareceran al resolver el episodio.',
                        style: TextStyle(color: TanukiColors.muted),
                      ),
                    ],
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
                          _PlayerDialogRadioButton(
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
                          _PlayerDialogRadioButton(
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
              if (provider == RemoteProvider.internetArchive) {
                return const Text(
                  'Internet Archive usa el archivo de video encontrado automaticamente.',
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
                          _PlayerDialogRadioButton(
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
                          _PlayerDialogRadioButton(
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
              RemoteProvider.justAnime,
              RemoteProvider.aniPm,
              RemoteProvider.internetArchive,
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
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _PlayerDialogSectionTitle('Pantalla'),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _PlayerDialogRadioButton(
                                  label: 'Fit',
                                  active: _videoScaleMode == VideoScaleMode.fit,
                                  onPressed: () => unawaited(
                                    _setVideoScaleMode(VideoScaleMode.fit)
                                        .then((_) {
                                      if (dialogContext.mounted) {
                                        setDialogState(() {});
                                      }
                                    }),
                                  ),
                                ),
                                _PlayerDialogRadioButton(
                                  label: 'Stretch',
                                  active:
                                      _videoScaleMode == VideoScaleMode.stretch,
                                  onPressed: () => unawaited(
                                    _setVideoScaleMode(
                                      VideoScaleMode.stretch,
                                    ).then((_) {
                                      if (dialogContext.mounted) {
                                        setDialogState(() {});
                                      }
                                    }),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            const _PlayerDialogSectionTitle('Subtitulos'),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _PlayerDialogRadioButton(
                                  label: 'Desactivados',
                                  active: !_subtitlesEnabled,
                                  onPressed: () {
                                    setState(() {
                                      _subtitlesEnabled = false;
                                      _status = 'Subtitulos desactivados';
                                    });
                                    unawaited(
                                      _applyRemoteSubtitleTrackIfReady(),
                                    );
                                    setDialogState(() {});
                                  },
                                ),
                                _PlayerDialogRadioButton(
                                  label: _subtitlesEnabled
                                      ? 'Activados'
                                      : 'Activar',
                                  active: _subtitlesEnabled,
                                  onPressed: () {
                                    Navigator.of(dialogContext).pop();
                                    Future<void>.delayed(
                                      const Duration(milliseconds: 120),
                                      _showSubtitleTrackDialog,
                                    );
                                  },
                                ),
                              ],
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
                RemoteProvider.justAnime,
                RemoteProvider.aniPm,
                RemoteProvider.internetArchive,
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
                    for (final server in _availableJkAnimeServers())
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

  List<JkAnimeServerPreference> _availableJkAnimeServers() {
    final discovered =
        _currentResolvedStream?.provider == RemoteProvider.jkAnime
            ? _currentResolvedStream?.availableServers ?? const <String>{}
            : const <String>{};
    if (discovered.isEmpty) {
      return JkAnimeServerPreference.values;
    }
    final servers = JkAnimeServerPreference.values
        .where((server) => discovered.contains(server.id))
        .toList(growable: false);
    return servers.isEmpty ? JkAnimeServerPreference.values : servers;
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
      RemoteProvider.justAnime => 'JustAnime',
      RemoteProvider.aniPm => 'ani.pm',
      RemoteProvider.internetArchive => 'Internet Archive',
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
    final seriesNext = _seriesEntriesAfterCurrent(limit: 1);
    final replacement = widget.launchMode == PlayerLaunchMode.playlist ||
            widget.launchMode == PlayerLaunchMode.detail
        ? _adjacentEpisode(1)
        : seriesNext.isEmpty
            ? null
            : seriesNext.first;
    if (replacement == null) {
      if (widget.launchMode == PlayerLaunchMode.detail) {
        Navigator.of(context).maybePop();
        return;
      }
      final entries = widget.launchMode == PlayerLaunchMode.playlist
          ? _playlistEntriesAfterCurrent(limit: 1)
          : widget.launchMode == PlayerLaunchMode.continueWatching
              ? _continueWatchingEntriesAfterCurrent(limit: 1)
              : const <EpisodeItem>[];
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

  bool _isCurrentResolvedPlaybackPath(String value) {
    final playbackUrl = _currentResolvedStream?.playbackUrl.trim();
    return playbackUrl != null &&
        playbackUrl.isNotEmpty &&
        playbackUrl == value;
  }

  BoxFit _boxFitForVideoScaleMode(VideoScaleMode mode) {
    return switch (mode) {
      VideoScaleMode.stretch => BoxFit.fill,
      _ => BoxFit.contain,
    };
  }
}

String _youtubeSeriesWebPlayerHtml({
  required String videoId,
  required Duration startPosition,
  required String title,
  required String sourceLabel,
  required bool desktopControls,
}) {
  final jsVideoId = jsonEncode(videoId);
  final jsTitle = jsonEncode(title.trim().isEmpty ? 'Episodio' : title.trim());
  final jsSourceLabel = jsonEncode(
    sourceLabel.trim().isEmpty ? 'YouTube' : sourceLabel.trim(),
  );
  final jsDesktopControls = desktopControls ? 'true' : 'false';
  final startSeconds = max(0, startPosition.inSeconds);
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
    .chrome {
      position: fixed;
      left: 0;
      right: 0;
      z-index: 3;
      color: #fff;
      pointer-events: auto;
    }
    body:not(.desktop-controls) .chrome {
      display: none;
    }
    #topbar {
      top: 0;
      min-height: 64px;
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 10px 14px;
      background: linear-gradient(180deg, rgba(0,0,0,0.72), rgba(0,0,0,0));
    }
    #bottombar {
      bottom: 0;
      display: grid;
      grid-template-columns: auto 1fr auto;
      align-items: center;
      gap: 12px;
      padding: 0 16px 14px;
      background: linear-gradient(0deg, rgba(0,0,0,0.76), rgba(0,0,0,0));
    }
    .icon-button {
      width: 42px;
      height: 42px;
      flex: 0 0 42px;
      border: 0;
      border-radius: 50%;
      background: rgba(15, 23, 32, 0.52);
      color: #fff;
      display: inline-grid;
      place-items: center;
      padding: 0;
      cursor: pointer;
    }
    .icon-button:hover,
    .icon-button:focus {
      outline: 0;
      background: rgba(255, 138, 42, 0.24);
    }
    .icon-button svg {
      width: 23px;
      height: 23px;
      fill: currentColor;
    }
    #text {
      min-width: 0;
      flex: 1 1 auto;
      padding-left: 2px;
    }
    #title {
      font-size: 16px;
      line-height: 20px;
      font-weight: 800;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    #source {
      margin-top: 2px;
      color: #ff8a2a;
      font-size: 13px;
      font-weight: 800;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    #play {
      background: transparent;
    }
    #time {
      min-width: 112px;
      color: rgba(226, 232, 240, 0.84);
      font-size: 13px;
      font-weight: 700;
      text-align: right;
      font-variant-numeric: tabular-nums;
    }
    #progress {
      width: 100%;
      accent-color: #ff8a2a;
      cursor: pointer;
    }
    #loading {
      position: fixed;
      inset: 0;
      z-index: 2;
      display: grid;
      place-items: center;
      pointer-events: none;
      color: rgba(226, 232, 240, 0.82);
      font-size: 14px;
      font-weight: 800;
    }
    body.playing #loading,
    body.paused #loading,
    body.ended #loading {
      display: none;
    }
    #spinner {
      width: 42px;
      height: 42px;
      border-radius: 50%;
      border: 4px solid rgba(255, 138, 42, 0.18);
      border-top-color: #ff8a2a;
      animation: spin 0.9s linear infinite;
      margin: 0 auto 14px;
    }
    @keyframes spin {
      to { transform: rotate(360deg); }
    }
  </style>
  <script src="https://www.youtube.com/iframe_api" referrerpolicy="strict-origin-when-cross-origin"></script>
</head>
<body>
  <div id="player"></div>
  <div id="loading">
    <div>
      <div id="spinner"></div>
      <div>Cargando video...</div>
    </div>
  </div>
  <div id="topbar" class="chrome">
    <button id="back" class="icon-button" title="Volver" aria-label="Volver">
      <svg viewBox="0 0 24 24"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.42-1.41L7.83 13H20v-2z"></path></svg>
    </button>
    <button id="previous" class="icon-button" title="Capitulo anterior" aria-label="Capitulo anterior">
      <svg viewBox="0 0 24 24"><path d="M6 6h2v12H6V6zm3.5 6L18 18V6l-8.5 6z"></path></svg>
    </button>
    <button id="next" class="icon-button" title="Capitulo siguiente" aria-label="Capitulo siguiente">
      <svg viewBox="0 0 24 24"><path d="M6 18l8.5-6L6 6v12zM16 6h2v12h-2V6z"></path></svg>
    </button>
    <div id="text">
      <div id="title"></div>
      <div id="source"></div>
    </div>
    <button id="episodes" class="icon-button" title="Episodios" aria-label="Episodios">
      <svg viewBox="0 0 24 24"><path d="M4 5h16v2H4V5zm0 6h16v2H4v-2zm0 6h16v2H4v-2z"></path></svg>
    </button>
    <button id="settings" class="icon-button" title="Configuracion" aria-label="Configuracion">
      <svg viewBox="0 0 24 24"><path d="M19.43 12.98c.04-.32.07-.65.07-.98s-.02-.66-.07-.98l2.11-1.65-2-3.46-2.49 1a7.28 7.28 0 0 0-1.69-.98L15 3h-4l-.36 2.93c-.6.23-1.16.56-1.69.98l-2.49-1-2 3.46 2.11 1.65c-.04.32-.07.65-.07.98s.02.66.07.98l-2.11 1.65 2 3.46 2.49-1c.52.4 1.09.73 1.69.98L11 21h4l.36-2.93c.6-.23 1.16-.56 1.69-.98l2.49 1 2-3.46-2.11-1.65zM13 15.5A3.5 3.5 0 1 1 13 8a3.5 3.5 0 0 1 0 7.5z"></path></svg>
    </button>
    <button id="fullscreen" class="icon-button" title="Pantalla completa" aria-label="Pantalla completa">
      <svg viewBox="0 0 24 24"><path d="M5 5h6v2H7v4H5V5zm12 2h-4V5h6v6h-2V7zM7 13v4h4v2H5v-6h2zm12 0v6h-6v-2h4v-4h2z"></path></svg>
    </button>
  </div>
  <div id="bottombar" class="chrome">
    <button id="play" class="icon-button" title="Play/Pausa" aria-label="Play/Pausa">
      <svg id="playIcon" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"></path></svg>
    </button>
    <input id="progress" type="range" min="0" max="1" step="0.01" value="0" aria-label="Progreso">
    <div id="time">0:00 / 0:00</div>
  </div>
  <script>
    let player = null;
    let ready = false;
    const desktopControls = $jsDesktopControls;
    const titleText = $jsTitle;
    const sourceText = $jsSourceLabel;
    const playIcon = document.getElementById('playIcon');
    const progress = document.getElementById('progress');
    const timeLabel = document.getElementById('time');
    document.body.classList.toggle('desktop-controls', desktopControls);
    document.getElementById('title').textContent = titleText;
    document.getElementById('source').textContent = sourceText;
    function post(type, extra) {
      const message = Object.assign({
        type: type,
        state: stateLabel(),
        position: currentTime(),
        duration: duration()
      }, extra || {});
      try {
        TanukiSeriesYoutube.postMessage(JSON.stringify(message));
      } catch (error) {}
    }
    function postCommand(command) {
      post('command', { command: command });
    }
    function currentTime() {
      try { return player && player.getCurrentTime ? player.getCurrentTime() || 0 : 0; }
      catch (error) { return 0; }
    }
    function duration() {
      try { return player && player.getDuration ? player.getDuration() || 0 : 0; }
      catch (error) { return 0; }
    }
    function stateLabel() {
      try {
        if (!player || !player.getPlayerState) return 'idle';
        const state = player.getPlayerState();
        if (state === YT.PlayerState.PLAYING) return 'playing';
        if (state === YT.PlayerState.PAUSED) return 'paused';
        if (state === YT.PlayerState.BUFFERING) return 'buffering';
        if (state === YT.PlayerState.ENDED) return 'ended';
        if (state === YT.PlayerState.CUED) return 'cued';
        return 'idle';
      } catch (error) {
        return 'idle';
      }
    }
    function formatTime(seconds) {
      seconds = Math.max(0, Math.floor(Number(seconds) || 0));
      const h = Math.floor(seconds / 3600);
      const m = Math.floor((seconds % 3600) / 60);
      const s = seconds % 60;
      if (h > 0) {
        return h + ':' + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
      }
      return m + ':' + String(s).padStart(2, '0');
    }
    function renderChrome() {
      const state = stateLabel();
      document.body.classList.remove('playing', 'paused', 'ended', 'buffering', 'idle');
      document.body.classList.add(state);
      const pos = currentTime();
      const dur = duration();
      progress.max = dur > 0 ? String(dur) : '1';
      progress.value = dur > 0 ? String(Math.min(pos, dur)) : '0';
      timeLabel.textContent = formatTime(pos) + ' / ' + formatTime(dur);
      playIcon.innerHTML = state === 'playing'
        ? '<path d="M6 5h4v14H6V5zm8 0h4v14h-4V5z"></path>'
        : '<path d="M8 5v14l11-7z"></path>';
    }
    function playWhenReady() {
      if (!player) return;
      try { player.unMute(); } catch (error) {}
      try { player.setVolume($_youtubeMaxVolume); } catch (error) {}
      [0, 250, 900, 1800].forEach(function(delay) {
        window.setTimeout(function() {
          try { player.unMute(); } catch (error) {}
          try { player.setVolume($_youtubeMaxVolume); } catch (error) {}
          try { player.playVideo(); } catch (error) {}
        }, delay);
      });
    }
    function tanukiPlay() {
      try { if (player) player.unMute(); } catch (error) {}
      try { if (player) player.setVolume($_youtubeMaxVolume); } catch (error) {}
      try { if (player) player.playVideo(); } catch (error) {}
      window.setTimeout(tanukiNotifyState, 100);
    }
    function tanukiPause() {
      try { if (player) player.pauseVideo(); } catch (error) {}
      window.setTimeout(tanukiNotifyState, 100);
    }
    function tanukiToggle() {
      if (stateLabel() === 'playing') {
        tanukiPause();
      } else {
        tanukiPlay();
      }
    }
    function tanukiSeekTo(seconds) {
      try {
        if (player) {
          player.seekTo(Math.max(0, Number(seconds) || 0), true);
          player.playVideo();
        }
      } catch (error) {}
      window.setTimeout(tanukiNotifyState, 100);
      window.setTimeout(tanukiNotifyState, 900);
    }
    function tanukiNotifyState() {
      renderChrome();
      post('state');
    }
    function bindControls() {
      document.getElementById('back').addEventListener('click', function() { postCommand('back'); });
      document.getElementById('previous').addEventListener('click', function() { postCommand('previous'); });
      document.getElementById('next').addEventListener('click', function() { postCommand('next'); });
      document.getElementById('episodes').addEventListener('click', function() { postCommand('episodes'); });
      document.getElementById('settings').addEventListener('click', function() { postCommand('settings'); });
      document.getElementById('fullscreen').addEventListener('click', function() {
        try {
          const root = document.documentElement;
          if (!document.fullscreenElement && root.requestFullscreen) {
            root.requestFullscreen();
          } else if (document.exitFullscreen) {
            document.exitFullscreen();
          }
        } catch (error) {}
        postCommand('fullscreen');
      });
      document.getElementById('play').addEventListener('click', tanukiToggle);
      progress.addEventListener('input', function() {
        tanukiSeekTo(Number(progress.value) || 0);
      });
    }
    bindControls();
    function onYouTubeIframeAPIReady() {
      player = new YT.Player('player', {
        host: 'https://www.youtube-nocookie.com',
        width: '100%',
        height: '100%',
        videoId: $jsVideoId,
        playerVars: {
          autoplay: 1,
          controls: 0,
          disablekb: 1,
          fs: 0,
          rel: 0,
          modestbranding: 1,
          playsinline: 1,
          iv_load_policy: 3,
          enablejsapi: 1,
          start: $startSeconds,
          origin: 'https://www.youtube-nocookie.com'
        },
        events: {
          onReady: function(event) {
            player = event.target;
            ready = true;
            try { player.unMute(); } catch (error) {}
            try { player.setVolume($_youtubeMaxVolume); } catch (error) {}
            try {
              const iframe = player.getIframe();
              if (iframe) {
                iframe.allow = 'autoplay; encrypted-media; fullscreen; picture-in-picture';
                iframe.allowFullscreen = true;
                iframe.referrerPolicy = 'strict-origin-when-cross-origin';
              }
            } catch (error) {}
            renderChrome();
            post('ready');
            playWhenReady();
            window.setInterval(tanukiNotifyState, 750);
          },
          onStateChange: function(event) {
            renderChrome();
            if (event.data === YT.PlayerState.BUFFERING) {
              post('buffering');
            } else if (event.data === YT.PlayerState.ENDED) {
              post('ended');
            } else {
              post('state');
            }
          },
          onError: function(event) {
            post('error', { detail: String(event && event.data ? event.data : 'youtube') });
          }
        }
      });
    }
  </script>
</body>
</html>
''';
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

class _YoutubeWebVideoSurface extends StatelessWidget {
  const _YoutubeWebVideoSurface({
    required this.controller,
  });

  final WebViewController controller;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: WebViewWidget(controller: controller),
    );
  }
}

class _YoutubeWebControls extends StatefulWidget {
  const _YoutubeWebControls({
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.formatTime,
    required this.onFocusChanged,
    this.playButtonFocusNode,
    this.progressFocusNode,
  });

  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final Future<void> Function() onTogglePlayback;
  final Future<void> Function(Duration target) onSeek;
  final String Function(Duration duration) formatTime;
  final ValueChanged<bool> onFocusChanged;
  final FocusNode? playButtonFocusNode;
  final FocusNode? progressFocusNode;

  @override
  State<_YoutubeWebControls> createState() => _YoutubeWebControlsState();
}

class _YoutubeWebControlsState extends State<_YoutubeWebControls> {
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
          .clamp(0, max(1, duration.inMilliseconds))
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
    final durationMs = widget.duration.inMilliseconds.clamp(1, 1 << 53);
    final currentMs = _dragPositionMs ??
        widget.position.inMilliseconds.clamp(0, durationMs).toDouble();
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
                  tooltip: widget.isPlaying ? 'Pausar' : 'Reproducir',
                  onPressed: () => unawaited(widget.onTogglePlayback()),
                  icon: Icon(
                    widget.isPlaying ? Icons.pause : Icons.play_arrow,
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
                      widget.duration,
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
                              Duration(milliseconds: position.round()),
                            ),
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
                  widget.formatTime(widget.duration),
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

class _PlayerDialogRadioButton extends StatelessWidget {
  const _PlayerDialogRadioButton({
    required this.label,
    required this.active,
    required this.onPressed,
  });

  final String label;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  active ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 17,
                  color: active ? TanukiColors.orange : TanukiColors.muted,
                ),
                const SizedBox(width: 7),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? TanukiColors.text : const Color(0xFFD8E1EB),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerDialogScrollableRadioColumn extends StatefulWidget {
  const _PlayerDialogScrollableRadioColumn({
    required this.children,
  });

  final List<Widget> children;

  @override
  State<_PlayerDialogScrollableRadioColumn> createState() =>
      _PlayerDialogScrollableRadioColumnState();
}

class _PlayerDialogScrollableRadioColumnState
    extends State<_PlayerDialogScrollableRadioColumn> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 178),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: widget.children.length > 4,
        child: SingleChildScrollView(
          controller: _controller,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < widget.children.length; index += 1)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: index == widget.children.length - 1 ? 0 : 6,
                  ),
                  child: widget.children[index],
                ),
            ],
          ),
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
    required this.onSettings,
    required this.onEpisodes,
    required this.onFullscreen,
    required this.onControlFocusChanged,
    this.backButtonFocusNode,
    this.previousButtonFocusNode,
    this.nextButtonFocusNode,
    this.settingsButtonFocusNode,
    this.episodesButtonFocusNode,
    this.fullscreenButtonFocusNode,
  });

  final EpisodeItem episode;
  final FocusNode? backButtonFocusNode;
  final FocusNode? previousButtonFocusNode;
  final FocusNode? nextButtonFocusNode;
  final FocusNode? settingsButtonFocusNode;
  final FocusNode? episodesButtonFocusNode;
  final FocusNode? fullscreenButtonFocusNode;
  final String status;
  final IconData statusIcon;
  final Color statusColor;
  final VoidCallback onBack;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
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

bool shouldRetryMissingAudioTrack({
  required bool isRemote,
  required bool hasVideoFrame,
  required int audioTrackCount,
  required int attempt,
  required int maxAttempts,
}) {
  if (!isRemote || !hasVideoFrame || audioTrackCount > 0) {
    return false;
  }
  return attempt >= maxAttempts;
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

class RemoteCaptionCue {
  const RemoteCaptionCue({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;
}

List<RemoteCaptionCue> parseRemoteCaptionCues(String payload) {
  final normalized = payload
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'^\uFEFF'), '');
  final cues = <RemoteCaptionCue>[];
  if (normalized.contains('[Script Info]') ||
      normalized.contains('\nDialogue:')) {
    for (final rawLine in normalized.split('\n')) {
      final line = rawLine.trim();
      if (!line.startsWith('Dialogue:')) continue;
      final fields = line.substring('Dialogue:'.length).split(',');
      if (fields.length < 10) continue;
      final start = _parseRemoteCaptionTimestamp(fields[1]);
      final end = _parseRemoteCaptionTimestamp(fields[2]);
      if (start == null || end == null || end <= start) continue;
      final text = fields
          .skip(9)
          .join(',')
          .replaceAll(RegExp(r'\{[^}]*\}'), '')
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\h', ' ')
          .trim();
      if (text.isNotEmpty) {
        cues.add(RemoteCaptionCue(start: start, end: end, text: text));
      }
    }
    return cues;
  }
  for (final block in normalized.split(RegExp(r'\n{2,}'))) {
    final lines = block.split('\n').map((line) => line.trim()).toList();
    final timingIndex = lines.indexWhere((line) => line.contains('-->'));
    if (timingIndex < 0 || timingIndex + 1 >= lines.length) continue;
    final timing = lines[timingIndex].split('-->');
    if (timing.length != 2) continue;
    final start = _parseRemoteCaptionTimestamp(timing[0]);
    final end = _parseRemoteCaptionTimestamp(
      timing[1].trim().split(RegExp(r'\s+')).first,
    );
    if (start == null || end == null || end <= start) continue;
    final text = lines
        .skip(timingIndex + 1)
        .where((line) => line.isNotEmpty)
        .join('\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .trim();
    if (text.isNotEmpty) {
      cues.add(RemoteCaptionCue(start: start, end: end, text: text));
    }
  }
  return cues;
}

Duration? _parseRemoteCaptionTimestamp(String value) {
  final match = RegExp(r'(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})')
      .firstMatch(value.trim());
  if (match == null) return null;
  final fraction = match.group(4) ?? '0';
  final milliseconds = int.tryParse(fraction.padRight(3, '0')) ?? 0;
  return Duration(
    hours: int.tryParse(match.group(1) ?? '0') ?? 0,
    minutes: int.tryParse(match.group(2) ?? '0') ?? 0,
    seconds: int.tryParse(match.group(3) ?? '0') ?? 0,
    milliseconds: milliseconds,
  );
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
    'neko' => 'Neko',
    'gigi' => 'Gigi',
    'stape' => 'Stape',
    'netu' => 'Netu',
    'archive-direct' => 'Directo',
    'bilibili-1' => 'BiliBili 1',
    'bilibili-2' => 'BiliBili 2',
    'youtube-sub-1' => 'SUB Opcion 1',
    'youtube-sub-2' => 'SUB Opcion 2',
    'youtube-dub-1' => 'DUB Opcion 1',
    'youtube-dub-2' => 'DUB Opcion 2',
    String value
        when RegExp(r'^(nova|pulse|halo|orion|lyra)-\d+$').hasMatch(value) =>
      value
          .split('-')
          .map((part) => part.length == 1
              ? part
              : '${part.substring(0, 1).toUpperCase()}${part.substring(1)}')
          .join(' '),
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
    final episodeTitle = episode.displayName.trim();
    final baseEpisodeLabel = 'Episodio ${episode.episodeNumber}';
    final episodeLabel =
        episodeTitle.isEmpty || episodeTitle == baseEpisodeLabel
            ? baseEpisodeLabel
            : '$baseEpisodeLabel - $episodeTitle';
    return SizedBox(
      width: 300,
      height: 170,
      child: DecoratedBox(
        decoration: glassDecoration(color: const Color(0xD010161D), radius: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (episode.imageUrl.isNotEmpty)
                _FadeInNetworkImage(
                  imageUrl: episode.imageUrl,
                  fit: BoxFit.cover,
                )
              else
                Image.asset(
                  'assets/images/tanuki_tv_banner.png',
                  fit: BoxFit.cover,
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x33000000),
                      Color(0x10000000),
                      Color(0xE010161D),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 10,
                left: 10,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: labelColor.withValues(alpha: 0.24),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: labelColor.withValues(alpha: 0.55),
                    ),
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: labelColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 34, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        episode.seriesName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: TanukiColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        episodeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFCFD9E3),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                        ),
                      ),
                    ],
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

String _seriesKeyFor(EpisodeItem episode) {
  final explicit = episode.seriesStateKey.trim();
  return explicit.isNotEmpty
      ? explicit
      : normalizeSeriesKey(episode.seriesName);
}

bool _episodeAirsInFuture(String airDateIso) {
  final normalized = airDateIso.trim();
  if (normalized.isEmpty) {
    return false;
  }
  final source =
      normalized.length >= 10 ? normalized.substring(0, 10) : normalized;
  final parsed = DateTime.tryParse(source);
  if (parsed == null) {
    return false;
  }
  final airDate = DateTime(parsed.year, parsed.month, parsed.day);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return airDate.isAfter(today);
}
