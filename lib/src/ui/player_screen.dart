import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

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
import '../services/aniskip_service.dart';
import '../services/playback_backend.dart';
import '../services/window_fullscreen_controller.dart';
import 'toonami_theme.dart';
import 'trailer_queue_screen.dart';

const _remotePlaybackUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';
const _remoteVideoFrameWatchdogDelay = Duration(seconds: 45);
const _remoteVideoFramePlaybackGrace = Duration(seconds: 35);
const _animeAv1PlaybackErrorFallbackDelay = Duration(seconds: 45);
const _playerOverlayAutoHideDelay = Duration(seconds: 5);
const _playerRemoteBackHoldExitDelay = Duration(milliseconds: 700);
const _playerDialogReopenSuppressDelay = Duration(milliseconds: 650);
const _remoteSeekJumpThreshold = Duration(seconds: 45);
const _remoteSeekStallDelay = Duration(seconds: 11);
const _remoteOpeningRecoveryMaxAttempts = 1;
const _desktopVlcAudioRecoveryMaxAttempts = 10;
const _stableRemoteAv1VlcCacheMs = 20000;
const _stableRemoteAv1InitialBufferWarmup = Duration(seconds: 10);
const _jkanimeInitialSeekWarmup = Duration(seconds: 2);
const _stableRemoteAv1StartupBufferTarget = Duration(seconds: 10);
const _stableRemoteAv1StartupBufferMaxWait = Duration(seconds: 25);
const _stableRemoteAv1AutomaticFallbackSuppressAfter = Duration(minutes: 2);
const _playbackFrameJankThreshold = Duration(milliseconds: 120);
const _playbackRenderJankThreshold = Duration(milliseconds: 80);
const _playbackMonitorReportThrottle = Duration(seconds: 2);
const _androidExoListenerGapThreshold = Duration(milliseconds: 1200);
const _androidExoListenerPositionAdvanceThreshold = Duration(milliseconds: 900);
const _playbackHeartbeatInterval = Duration(milliseconds: 500);
const _androidExoPositionStallThreshold = Duration(milliseconds: 1100);
const _androidExoPositionStallTolerance = Duration(milliseconds: 250);
const _playerProgressKeyboardSeekCommitDelay = Duration(seconds: 1);
const _animeSkipPromptLead = Duration(seconds: 1);
const _animeSkipSeekEndOffset = Duration(milliseconds: 500);
const _playerPointerOverlayRefreshInterval = Duration(milliseconds: 250);
const _mediaKitMaxVolume = 100.0;
const _normalizedMaxVolume = 1.0;
const _youtubeMaxVolume = 100;
const _mediaCapabilitiesChannel = MethodChannel('tanuki/media_capabilities');
const _playbackPowerChannel = MethodChannel('tanuki/playback_power');
int _nextDesktopVlcPlayerId = 1;
const _androidHardwareDecoderCodecs = 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1';
const _androidHardwareDecoderCodecsWithoutAv1 =
    'h264,hevc,mpeg4,mpeg2video,vp8,vp9';
Future<AndroidMediaCapabilities?>? _androidMediaCapabilitiesFuture;

enum PlayerLaunchMode {
  normal,
  detail,
  playlist,
  continueWatching,
  continueWatchingRoundRobin,
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

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  static final List<vlc.Player> _retiredRemoteVlcPlayers = <vlc.Player>[];
  static final Set<vlc.Player> _activeDesktopVlcPlayers = <vlc.Player>{};
  static bool _disposingRetiredVlc = false;

  Player? _player;
  VideoController? _videoController;
  vp.VideoPlayerController? _androidExoController;
  vlc.Player? _desktopVlcPlayer;
  String _desktopVlcSourcePath = '';
  List<RemoteCaptionCue> _desktopVlcSubtitleCues = const [];
  List<RemoteCaptionCue> _remoteSubtitleCues = const [];
  int _remoteSubtitleLoadTicket = 0;
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
  bool _androidExoDeferredResumeSeekHandled = false;
  bool _androidExoRebufferHoldActive = false;
  bool _desktopVlcCompletionHandled = false;
  bool _desktopVlcIsPlaying = false;
  bool _desktopVlcAudioFallbackHandled = false;
  bool _desktopVlcDeferredResumeSeekHandled = false;
  bool _desktopVlcRebufferHoldActive = false;
  Duration? _desktopVlcDeferredResumeSeekTarget;
  DateTime? _desktopVlcDeferredResumeSeekReadyAt;
  bool _handlingAndroidExoError = false;
  bool _simklScrobbleActive = false;
  bool _remoteResumeRefined = false;
  bool _subtitlesEnabled = true;
  bool _handlingPlaybackError = false;
  bool _playerOverlaysVisible = true;
  bool _playerControlsFocused = false;
  bool _playerBuffering = false;
  bool _playerVolumeSliderVisible = false;
  bool _suppressNextPlayerActivationKeyUp = false;
  double _subtitleTimingOffsetSeconds = 0.0;
  double _subtitleFontScale = 1.0;
  double _playerVolume = 1.0;
  double _playerVolumeBeforeMute = 1.0;
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
  final FocusNode _playerVolumeButtonFocusNode =
      FocusNode(debugLabel: 'playerVolumeButton');
  final FocusNode _playerFullscreenButtonFocusNode =
      FocusNode(debugLabel: 'playerFullscreenButton');
  final FocusNode _playerBottomPlayFocusNode =
      FocusNode(debugLabel: 'playerBottomPlay');
  final FocusNode _playerBottomProgressFocusNode =
      FocusNode(debugLabel: 'playerBottomProgress');
  final FocusNode _animeSkipButtonFocusNode =
      FocusNode(debugLabel: 'animeSkipButton');
  late VideoScaleMode _videoScaleMode;
  RemoteDirectStream? _currentResolvedStream;
  RemoteProvider? _automaticResolvingProvider;
  String _selectedRemoteSubtitleTrackKey = '';
  final Map<RemoteProvider, Set<String>> _remoteServerOptionCache =
      <RemoteProvider, Set<String>>{};
  final Set<RemoteProvider> _failedRemoteProviders = <RemoteProvider>{};
  final Set<String> _failedRemoteServers = <String>{};
  RemoteProvider? _serverFallbackProvider;
  DateTime _lastPlaybackSave = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPositionChangeAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPlayerOverlayPointerRefresh =
      DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;
  int _lastPositionDebugBucket = -1;
  int _lastBufferDebugBucket = -1;
  DateTime _lastAndroidExoRebuild = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, DateTime> _nativeLogLastPrintedAt = <String, DateTime>{};
  double _lastSimklScrobbleProgress = -1;
  bool _simklPlaybackPositionReady = false;
  bool _pendingSimklStartAfterPositionReady = false;
  bool _simklStartRetryScheduled = false;
  bool _simklStartDurationRetryUsed = false;
  Timer? _simklPauseDebounceTimer;
  Timer? _remoteVideoFrameWatchdogTimer;
  Timer? _remoteOpeningRecoveryTimer;
  Timer? _deferredAnimeAv1PlaybackErrorTimer;
  Timer? _playerOverlayHideTimer;
  Timer? _animeAv1SeekRecoveryTimer;
  Timer? _youtubeWebStateTimer;
  Timer? _upcomingCardStartTimer;
  Timer? _upcomingCardSequenceTimer;
  Timer? _playerRemoteBackHoldTimer;
  Timer? _playbackHeartbeatTimer;
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
  StreamSubscription<double>? _desktopVlcBufferingProgressSubscription;
  bool _remotePlaybackAccepted = false;
  bool _remoteVideoFrameReady = false;
  bool _remoteVideoFrameFallbackHandled = false;
  bool _openedNativeYoutubePlayer = false;
  bool _youtubeWebPlaying = false;
  bool _youtubeWebEnded = false;
  bool _playerDialogOpen = false;
  bool _playerRemoteBackKeyDown = false;
  bool _playerRemoteBackLongPressTriggered = false;
  Duration _youtubeWebPosition = Duration.zero;
  Duration _youtubeWebDuration = Duration.zero;
  DateTime _suppressPlayerDialogOpenUntil =
      DateTime.fromMillisecondsSinceEpoch(0);
  int? _remoteVideoWidth;
  int? _remoteVideoHeight;
  int _remoteOpeningRecoveryAttempts = 0;
  int _openEpisodeTicket = 0;
  bool _leavingPlayer = false;
  bool _episodeTransitionInProgress = false;
  bool _remoteReloadInProgress = false;
  bool _currentEntryCommitted = false;
  bool _loadingAnimeSkipIntervals = false;
  bool _animeSkipLoadCompleted = false;
  Duration _animeSkipLoadedDuration = Duration.zero;
  String _deferredAnimeAv1PlaybackError = '';
  String _currentPlaybackPath = '';
  int _animeSkipLoadTicket = 0;
  List<AniSkipInterval> _animeSkipIntervals = const [];
  AniSkipInterval? _activeAnimeSkipInterval;
  final Set<String> _dismissedAnimeSkipIntervals = <String>{};
  final Set<String> _usedAnimeSkipIntervals = <String>{};
  _UpcomingCardPhase _upcomingCardPhase = _UpcomingCardPhase.none;
  bool _startUpcomingCardsShown = false;
  bool _endUpcomingCardsShown = false;
  int _upcomingCardTicket = 0;
  DateTime _lastPlaybackMonitorReportAt =
      DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastAndroidExoValueAt;
  Duration? _lastAndroidExoValuePosition;
  DateTime? _lastAndroidExoHeartbeatAt;
  Duration? _lastAndroidExoHeartbeatPosition;
  AndroidMediaCapabilities? _androidMediaCapabilities;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addTimingsCallback(_handlePlaybackFrameTimings);
    _playbackHeartbeatTimer = Timer.periodic(
      _playbackHeartbeatInterval,
      (_) => _monitorPlaybackHeartbeat(),
    );
    unawaited(_setPlaybackWakelock(enabled: true));
    _videoScaleMode =
        widget.controller.videoScaleModeForEpisode(widget.episode);
    _loadAndroidUiCapabilities();
    if (!_usesAndroidExoPlayer &&
        !_usesDesktopVlcPlayer &&
        PlaybackBackend.mediaKitAvailable) {
      _player = Player();
      unawaited(_player!.setVolume(_playerVolume * _mediaKitMaxVolume));
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

  void _loadAndroidUiCapabilities() {
    if (!Platform.isAndroid) {
      return;
    }
    unawaited(loadAndroidMediaCapabilities().then((capabilities) {
      if (!mounted || capabilities == null) {
        return;
      }
      setState(() {
        _androidMediaCapabilities = capabilities;
      });
    }));
  }

  double get _playerDialogScale {
    return shouldUseAndroidPhoneUi(_androidMediaCapabilities) ? 1.5 : 1.0;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.removeTimingsCallback(_handlePlaybackFrameTimings);
    _schedulePlaybackFinalizationAfterDispose();
    _simklPauseDebounceTimer?.cancel();
    _playerOverlayHideTimer?.cancel();
    _animeAv1SeekRecoveryTimer?.cancel();
    _youtubeWebStateTimer?.cancel();
    _remoteOpeningRecoveryTimer?.cancel();
    _upcomingCardStartTimer?.cancel();
    _upcomingCardSequenceTimer?.cancel();
    _playerRemoteBackHoldTimer?.cancel();
    _playbackHeartbeatTimer?.cancel();
    _playerControlsRootFocusNode.dispose();
    _playerBackButtonFocusNode.dispose();
    _playerPreviousButtonFocusNode.dispose();
    _playerNextButtonFocusNode.dispose();
    _playerSubtitlesButtonFocusNode.dispose();
    _playerFitButtonFocusNode.dispose();
    _playerSettingsButtonFocusNode.dispose();
    _playerEpisodesButtonFocusNode.dispose();
    _playerVolumeButtonFocusNode.dispose();
    _playerFullscreenButtonFocusNode.dispose();
    _playerBottomPlayFocusNode.dispose();
    _playerBottomProgressFocusNode.dispose();
    _animeSkipButtonFocusNode.dispose();
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
    final desktopVlcBufferingProgressSubscription =
        _desktopVlcBufferingProgressSubscription;
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
    if (desktopVlcBufferingProgressSubscription != null) {
      unawaited(desktopVlcBufferingProgressSubscription.cancel());
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_setPlaybackWakelock(enabled: true));
    }
  }

  bool get _usesAndroidExoPlayer =>
      Platform.isAndroid && widget.episode.isRemote;

  bool get _usesDesktopVlcPlayer =>
      (Platform.isLinux || Platform.isWindows) && widget.episode.isRemote;

  bool get _showsDesktopVolumeControl => Platform.isLinux || Platform.isWindows;

  bool get _showsPlayerFullscreenControl => !Platform.isAndroid;

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
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _playbackPowerChannel.invokeMethod<bool>(
        'setPlaybackKeepScreenOn',
        {'enabled': enabled},
      );
    } catch (error) {
      debugPrint(
        'PlayerScreen: native keep-screen-on failed '
        'enabled=$enabled error=$error',
      );
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

  void _handlePlaybackFrameTimings(List<ui.FrameTiming> timings) {
    if (!_playbackMonitorActive) {
      return;
    }
    for (final timing in timings) {
      if (!shouldReportPlaybackFrameJank(
        totalSpan: timing.totalSpan,
        buildDuration: timing.buildDuration,
        rasterDuration: timing.rasterDuration,
      )) {
        continue;
      }
      _reportPlaybackMonitorIssue(
        'frame-jank',
        'total=${timing.totalSpan.inMilliseconds}ms '
            'build=${timing.buildDuration.inMilliseconds}ms '
            'raster=${timing.rasterDuration.inMilliseconds}ms',
      );
    }
  }

  bool get _playbackMonitorActive {
    if (!_openedMedia || _leavingPlayer) {
      return false;
    }
    final android = _androidExoController;
    if (android != null) {
      final value = android.value;
      return value.isInitialized && value.isPlaying && !value.isBuffering;
    }
    final player = _player;
    if (player != null) {
      return player.state.playing && !player.state.buffering;
    }
    if (_desktopVlcPlayer != null) {
      return _desktopVlcIsPlaying && !_playerBuffering;
    }
    return _youtubeWebPlaying;
  }

  void _reportPlaybackMonitorIssue(String kind, String details) {
    final now = DateTime.now();
    if (now.difference(_lastPlaybackMonitorReportAt) <
        _playbackMonitorReportThrottle) {
      return;
    }
    _lastPlaybackMonitorReportAt = now;
    final message = '$kind ${_playbackMonitorContext()} $details';
    _debugPlayerEvent('PlaybackMonitor: $message');
    assert(() {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: PlaybackMonitorException(message),
          stack: StackTrace.current,
          library: 'Tanuki player monitor',
          context: ErrorDescription('while monitoring video playback'),
        ),
      );
      return true;
    }());
  }

  String _playbackMonitorContext() {
    final stream = _currentResolvedStream;
    final provider =
        stream?.provider?.id ?? widget.episode.provider?.id ?? 'unknown';
    final kind = stream?.playbackKind ?? 'unknown';
    final server = stream?.server.trim() ?? '';
    return 'provider=$provider kind=$kind '
        'server=${server.isEmpty ? 'none' : server} '
        'pos=${_formatPlaybackTime(_lastPosition)} '
        'duration=${_formatPlaybackTime(_lastDuration)}';
  }

  void _monitorPlaybackHeartbeat() {
    final android = _androidExoController;
    if (android == null) {
      _resetAndroidExoHeartbeat();
      return;
    }
    final value = android.value;
    if (!_openedMedia ||
        !value.isInitialized ||
        !value.isPlaying ||
        value.isBuffering) {
      _resetAndroidExoHeartbeat();
      return;
    }

    final now = DateTime.now();
    final previousAt = _lastAndroidExoHeartbeatAt;
    final previousPosition = _lastAndroidExoHeartbeatPosition;
    _lastAndroidExoHeartbeatAt = now;
    _lastAndroidExoHeartbeatPosition = value.position;
    if (previousAt == null || previousPosition == null) {
      return;
    }

    final wallGap = now.difference(previousAt);
    final positionDelta = value.position - previousPosition;
    if (!shouldReportAndroidExoPositionStall(
      wallGap: wallGap,
      positionDelta: positionDelta,
    )) {
      return;
    }
    _reportPlaybackMonitorIssue(
      'exo-position-stall',
      'wall=${wallGap.inMilliseconds}ms '
          'positionDelta=${positionDelta.inMilliseconds}ms '
          'buffered=${value.buffered.length}',
    );
  }

  void _resetAndroidExoHeartbeat() {
    _lastAndroidExoHeartbeatAt = null;
    _lastAndroidExoHeartbeatPosition = null;
  }

  Future<AndroidMediaCapabilities?>
      _logAndroidMediaCapabilitiesIfNeeded() async {
    if (!Platform.isAndroid) {
      return null;
    }
    final capabilities = await loadAndroidMediaCapabilities();
    if (capabilities == null) {
      _debugPlayerEvent('Android media capabilities unavailable');
      return null;
    }
    if (mounted && _androidMediaCapabilities != capabilities) {
      setState(() {
        _androidMediaCapabilities = capabilities;
      });
    }
    _debugPlayerEvent(
      'Android media capabilities ${capabilities.summaryLabel}',
    );
    if (_isAnimeAv1ZillaHlsPlayback &&
        !capabilities.hasHardwareAv1Decoder &&
        capabilities.av1Decoders.isNotEmpty) {
      _debugPlayerEvent(
        'PlaybackMonitor: android-av1-software-risk '
        '${_playbackMonitorContext()} ${capabilities.av1DecoderLabel}',
      );
    }
    return capabilities;
  }

  bool get _isAnimeAv1ZillaHlsPlayback {
    final stream = _currentResolvedStream;
    if (stream == null || stream.provider != RemoteProvider.animeAv1) {
      return false;
    }
    final playbackUrl = stream.playbackUrl.toLowerCase();
    final upstreamUrl =
        stream.httpHeaders['X-Tanuki-Upstream-Url']?.toLowerCase().trim() ?? '';
    return stream.playbackKind.toLowerCase() == 'hls' &&
        (playbackUrl.contains('player.zilla-networks.com') ||
            upstreamUrl.contains('player.zilla-networks.com'));
  }

  void _commitCurrentEntryAfterOpen() {
    if (_currentEntryCommitted) {
      return;
    }
    _currentEntryCommitted = true;
    unawaited(widget.controller.setCurrentEntry(widget.episode));
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
    _cancelRemoteVideoFrameWatchdog();
    _resetUpcomingCards();
    _resetAnimeSkip();
    await _disposeYoutubeWebPlayer();
    var path = widget.episode.filePath.trim();
    _currentResolvedStream = null;
    _remoteSubtitleLoadTicket += 1;
    _desktopVlcSubtitleCues = const [];
    _remoteSubtitleCues = const [];
    _lastDesktopSubtitleCueIndex = -2;
    _openedNativeYoutubePlayer = false;
    _remotePlaybackAccepted = false;
    _desktopVlcIsPlaying = false;
    _resetSimklScrobbleSession();
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
        _rememberRemoteServerOptions(resolved);
        _reconcileRemoteSubtitleSelection(resolved);
        unawaited(widget.controller.rememberResolvedPlaybackForEpisode(
          widget.episode,
          resolved,
        ));
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
      await player.setVolume(_playerVolume * _mediaKitMaxVolume);
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
      _markSimklPlaybackPositionReady(
        playing: player.state.playing,
        buffering: player.state.buffering,
      );
      _attachPlaybackErrorFallback(player);
      _attachRemoteVideoFrameWatchdog(player);
      _scheduleRemoteOpeningRecovery(resumePosition ?? startPosition);
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
      _commitCurrentEntryAfterOpen();
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
      unawaited(previous.dispose());
    }
    _androidExoController = null;
    _androidExoCompletionHandled = false;
    _androidExoDeferredResumeSeekHandled = false;
    _androidExoRebufferHoldActive = false;
    _handlingAndroidExoError = false;
    _lastAndroidExoValueAt = null;
    _lastAndroidExoValuePosition = null;
    _resetAndroidExoHeartbeat();
    final mediaCapabilities = await _logAndroidMediaCapabilitiesIfNeeded();

    final headers = _remoteMediaHeaders(path) ?? const <String, String>{};
    final playbackKind = _currentResolvedStream?.playbackKind.toLowerCase();
    final lowerPath = path.toLowerCase();
    final formatHint = playbackKind == 'hls' ||
            lowerPath.contains('.m3u8') ||
            lowerPath.contains('/m3u8/')
        ? vp.VideoFormat.hls
        : playbackKind == 'dash' || lowerPath.contains('.mpd')
            ? vp.VideoFormat.dash
            : playbackKind == 'mp4' || lowerPath.contains('.mp4')
                ? vp.VideoFormat.other
                : null;
    final controller = vp.VideoPlayerController.networkUrl(
      Uri.parse(path),
      formatHint: formatHint,
      httpHeaders: headers,
      viewType: androidVideoViewTypeForCapabilities(
        mediaCapabilities,
        mode: widget.controller.state.androidVideoViewMode,
      ),
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
      'view=${controller.viewType.name} '
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
      final deferResumeSeek = resumePosition != null &&
          resumePosition > const Duration(seconds: 2) &&
          shouldDeferAndroidExoInitialSeek(_currentResolvedStream);
      final openStart = deferResumeSeek ? Duration.zero : resumePosition;
      await controller.setVolume(_normalizedMaxVolume);
      await controller.seekTo(openStart ?? Duration.zero);
      _lastPosition = openStart ?? Duration.zero;
      _lastDuration = controller.value.duration;
      _lastPositionChangeAt = DateTime.now();
      _markSimklPlaybackPositionReady(
        playing: controller.value.isPlaying,
        buffering: controller.value.isBuffering,
      );
      await _applyAndroidExoSubtitleTrack();
      await _preloadAndroidExoStableStartupBuffer(controller);
      _debugPlayerEvent('ExoPlayer play start');
      await controller.play();
      _scheduleAndroidExoDeferredResumeSeek(controller, resumePosition);
      _debugPlayerEvent('ExoPlayer play requested');
      _remotePlaybackAccepted = true;
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
      _commitCurrentEntryAfterOpen();
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

  Future<void> _preloadAndroidExoStableStartupBuffer(
    vp.VideoPlayerController controller,
  ) async {
    if (!shouldUseStableRemoteAv1PlaybackProfile(_currentResolvedStream)) {
      return;
    }
    _setPlayerBuffering(true);
    if (mounted) {
      setState(() {
        _status = 'Precargando buffer...';
      });
    }
    final startedAt = DateTime.now();
    var sawBufferedRange = controller.value.buffered.isNotEmpty;
    var bufferedAhead = bufferedAheadForPosition(
      position: controller.value.position,
      ranges: controller.value.buffered,
    );
    _debugPlayerEvent(
      'ExoPlayer startup buffer wait target='
      '${_stableRemoteAv1StartupBufferTarget.inSeconds}s',
    );
    while (mounted && _androidExoController == controller) {
      final value = controller.value;
      sawBufferedRange = sawBufferedRange || value.buffered.isNotEmpty;
      bufferedAhead = bufferedAheadForPosition(
        position: value.position,
        ranges: value.buffered,
      );
      final elapsed = DateTime.now().difference(startedAt);
      if (bufferedAhead >= _stableRemoteAv1StartupBufferTarget ||
          (!sawBufferedRange &&
              elapsed >= _stableRemoteAv1StartupBufferTarget) ||
          elapsed >= _stableRemoteAv1StartupBufferMaxWait) {
        _debugPlayerEvent(
          'ExoPlayer startup buffer ready ahead='
          '${_formatPlaybackTime(bufferedAhead)} elapsed='
          '${elapsed.inSeconds}s sawRanges=$sawBufferedRange',
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _openDesktopVlcPlayer(
    String path, {
    Duration? resumeOverride,
  }) async {
    await _disposeDesktopVlcPlayer(delayForBiliBili: true);
    _desktopVlcCompletionHandled = false;
    _desktopVlcDeferredResumeSeekHandled = false;
    _desktopVlcDeferredResumeSeekTarget = null;
    _desktopVlcDeferredResumeSeekReadyAt = null;
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
    final userAgent =
        (headers['User-Agent'] ?? _remotePlaybackUserAgent).trim();
    final audioSlave = _desktopVlcAudioSlave();
    final vlcArguments = desktopVlcCommandlineArguments(
      stream: _currentResolvedStream,
      audioSlave: audioSlave,
      referer: referer,
      userAgent: userAgent,
    );
    final player = vlc.Player(
      id: _nextDesktopVlcPlayerId++,
      commandlineArguments: vlcArguments,
    );
    _desktopVlcPlayer = player;
    _activeDesktopVlcPlayers.add(player);
    _desktopVlcSourcePath = path;
    player.setUserAgent(userAgent);
    player.setVolume(_playerVolume);
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
      _maybeSendDeferredSimklStart();
      _maybeRetryDesktopVlcMissingVideoFrame(player, _lastPosition);
      if (_lastDuration > Duration.zero || _lastPosition > Duration.zero) {
        _setPlayerBuffering(false);
      }
      _maybeScheduleUpcomingCards(_lastPosition);
      _maybeUpdateAnimeSkipPrompt(_lastPosition);
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
          _desktopVlcCompletionHandled = true;
          _debugPlayerEvent(
            'ignored early VLC completion position='
            '${_formatPlaybackTime(_lastPosition)} duration='
            '${_formatPlaybackTime(_lastDuration)} expected='
            '${_formatPlaybackTime(_expectedRemoteDuration)}',
          );
          if (widget.episode.isRemote && _lastPosition <= Duration.zero) {
            unawaited(
              _retryRemoteFallback('VLC termino antes de iniciar'),
            );
          }
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
    _desktopVlcBufferingProgressSubscription =
        player.bufferingProgressStream.listen((progress) {
      if (_desktopVlcPlayer != player) {
        return;
      }
      _maybeHoldDesktopVlcRebuffer(player, progress);
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
      final hasDimensions = dimensions.width > 0 && dimensions.height > 0;
      if (hasDimensions) {
        _remoteVideoWidth = dimensions.width;
        _remoteVideoHeight = dimensions.height;
        if (_shouldWatchRemoteVideoFrame()) {
          _markRemoteVideoFrameReady();
        }
        _setPlayerBuffering(false);
        _maybeRunDesktopVlcDeferredResumeSeek(player);
      }
      setState(() {});
    });

    _lastPosition = openStart;
    _lastDuration = Duration.zero;
    _lastPositionChangeAt = DateTime.now();
    _markSimklPlaybackPositionReady(playing: _desktopVlcIsPlaying);
    _debugPlayerEvent(
      'VLC open url=${_debugMediaLabel(path)} '
      'playbackUrl=${_debugMediaLabel(playbackPath)} '
      'audioSlave=${audioSlave.isEmpty ? 'none' : _debugMediaLabel(audioSlave)} '
      'start=${_formatPlaybackTime(_lastPosition)} '
      'headers=${_debugHeadersLabel(headers)} '
      'args=${vlcArguments.join(' ')}',
    );
    try {
      player.open(
        _desktopVlcMedia(playbackPath, startTime: openStart),
        autoStart: true,
      );
      await _preloadDesktopVlcStableStartupBuffer(player);
      _scheduleDesktopVlcDeferredResumeSeek(player, resumePosition);
      _scheduleDesktopVlcAudioRecovery(player);
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
      _commitCurrentEntryAfterOpen();
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

  Future<void> _preloadDesktopVlcStableStartupBuffer(vlc.Player player) async {
    if (!shouldUseStableRemoteAv1PlaybackProfile(_currentResolvedStream)) {
      return;
    }
    _setPlayerBuffering(true);
    if (mounted) {
      setState(() {
        _status = 'Precargando buffer...';
      });
    }
    var lastProgress = player.bufferingProgress;
    var lastLoggedBucket = -1;
    final progressSubscription =
        player.bufferingProgressStream.listen((progress) {
      lastProgress = progress;
      final bucket = progress ~/ 20;
      if (bucket != lastLoggedBucket) {
        lastLoggedBucket = bucket;
        _debugPlayerEvent(
          'VLC startup buffering progress=${progress.toStringAsFixed(0)}%',
        );
      }
    });
    try {
      player.pause();
      _debugPlayerEvent(
        'VLC startup buffer hold target='
        '${_stableRemoteAv1StartupBufferTarget.inSeconds}s',
      );
      final startedAt = DateTime.now();
      while (mounted &&
          _desktopVlcPlayer == player &&
          DateTime.now().difference(startedAt) <
              _stableRemoteAv1StartupBufferTarget) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!mounted || _desktopVlcPlayer != player) {
        return;
      }
      _debugPlayerEvent(
        'VLC startup buffer ready progress='
        '${lastProgress.toStringAsFixed(0)}%',
      );
      player.play();
    } finally {
      unawaited(progressSubscription.cancel());
    }
  }

  void _maybeHoldDesktopVlcRebuffer(
    vlc.Player player,
    double bufferingProgress,
  ) {
    if (!shouldHoldStableRemoteAv1Rebuffer(
      stream: _currentResolvedStream,
      openedMedia: _openedMedia,
      isBuffering: bufferingProgress < 100,
      isPlaying: _desktopVlcIsPlaying,
      position: _lastPosition,
      holdActive: _desktopVlcRebufferHoldActive,
    )) {
      return;
    }
    unawaited(_holdDesktopVlcRebuffer(player, bufferingProgress));
  }

  Future<void> _holdDesktopVlcRebuffer(
    vlc.Player player,
    double bufferingProgress,
  ) async {
    _desktopVlcRebufferHoldActive = true;
    _setPlayerBuffering(true);
    if (mounted) {
      setState(() {
        _status = 'Recargando buffer...';
      });
    }
    try {
      _debugPlayerEvent(
        'VLC rebuffer hold target='
        '${_stableRemoteAv1StartupBufferTarget.inSeconds}s '
        'progress=${bufferingProgress.toStringAsFixed(0)}%',
      );
      player.pause();
      final startedAt = DateTime.now();
      while (mounted &&
          _desktopVlcPlayer == player &&
          DateTime.now().difference(startedAt) <
              _stableRemoteAv1StartupBufferTarget) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!mounted || _desktopVlcPlayer != player) {
        return;
      }
      _debugPlayerEvent('VLC rebuffer hold ready');
      player.play();
    } finally {
      _desktopVlcRebufferHoldActive = false;
    }
  }

  Duration _desktopVlcOpenStartPosition(Duration? resumePosition) {
    final start = resumePosition ?? Duration.zero;
    if (_currentResolvedStream?.provider == RemoteProvider.bilibili) {
      return Duration.zero;
    }
    if (shouldDeferDesktopVlcInitialSeek(_currentResolvedStream)) {
      return Duration.zero;
    }
    return start;
  }

  void _scheduleDesktopVlcDeferredResumeSeek(
    vlc.Player player,
    Duration? resumePosition,
  ) {
    if (_desktopVlcDeferredResumeSeekHandled ||
        resumePosition == null ||
        resumePosition <= const Duration(seconds: 2) ||
        !shouldDeferDesktopVlcInitialSeek(_currentResolvedStream)) {
      return;
    }
    _desktopVlcDeferredResumeSeekTarget = resumePosition;
    final warmup = deferredResumeSeekWarmup(_currentResolvedStream);
    _desktopVlcDeferredResumeSeekReadyAt = DateTime.now().add(warmup);
    _debugPlayerEvent(
      'VLC deferred resume seek warming target='
      '${_formatPlaybackTime(resumePosition)} warmup=${warmup.inSeconds}s',
    );
    _maybeRunDesktopVlcDeferredResumeSeek(player);
    _watchDesktopVlcDeferredResumeSeek(player);
  }

  void _maybeRunDesktopVlcDeferredResumeSeek(vlc.Player player) {
    final target = _desktopVlcDeferredResumeSeekTarget;
    final readyAt = _desktopVlcDeferredResumeSeekReadyAt;
    final warmingUp = readyAt != null && DateTime.now().isBefore(readyAt);
    if (_desktopVlcDeferredResumeSeekHandled ||
        target == null ||
        !mounted ||
        _desktopVlcPlayer != player ||
        !shouldRunDesktopVlcDeferredResumeSeek(
          stream: _currentResolvedStream,
          hasVideoFrame: _hasRemoteVideoFrame,
          warmingUp: warmingUp,
        )) {
      return;
    }
    _desktopVlcDeferredResumeSeekHandled = true;
    _desktopVlcDeferredResumeSeekTarget = null;
    _desktopVlcDeferredResumeSeekReadyAt = null;
    try {
      _debugPlayerEvent(
        'VLC deferred resume seek target=${_formatPlaybackTime(target)}',
      );
      player.seek(target);
      _lastPosition = target;
      _lastPositionChangeAt = DateTime.now();
    } catch (error) {
      _debugPlayerEvent('VLC deferred resume seek ignored error: $error');
    }
  }

  void _watchDesktopVlcDeferredResumeSeek(
    vlc.Player player, [
    int attempt = 1,
  ]) {
    unawaited(Future<void>.delayed(const Duration(milliseconds: 700), () {
      final target = _desktopVlcDeferredResumeSeekTarget;
      if (_desktopVlcDeferredResumeSeekHandled ||
          target == null ||
          !mounted ||
          _desktopVlcPlayer != player) {
        return;
      }
      final readyAt = _desktopVlcDeferredResumeSeekReadyAt;
      final warmingUp = readyAt != null && DateTime.now().isBefore(readyAt);
      if (shouldRunDesktopVlcDeferredResumeSeek(
        stream: _currentResolvedStream,
        hasVideoFrame: _hasRemoteVideoFrame,
        warmingUp: warmingUp,
      )) {
        _maybeRunDesktopVlcDeferredResumeSeek(player);
        return;
      }
      if (attempt >= 45) {
        _desktopVlcDeferredResumeSeekHandled = true;
        _desktopVlcDeferredResumeSeekTarget = null;
        _desktopVlcDeferredResumeSeekReadyAt = null;
        _debugPlayerEvent(
          'VLC deferred resume seek skipped target='
          '${_formatPlaybackTime(target)} videoFrame=$_hasRemoteVideoFrame',
        );
        final stream = _currentResolvedStream;
        final provider = stream?.provider;
        if (!_hasRemoteVideoFrame &&
            provider != null &&
            _supportsRemoteServerFallback(provider) &&
            shouldDeferRemoteHlsInitialSeek(stream)) {
          unawaited(_retryRemoteServerFallback(
            provider,
            'no entrego video antes del seek inicial',
          ));
        }
        return;
      }
      if (attempt == 1 || attempt % 4 == 0) {
        _debugPlayerEvent(
          'VLC deferred resume seek still warming attempt=$attempt target='
          '${_formatPlaybackTime(target)} videoFrame=$_hasRemoteVideoFrame',
        );
      }
      _watchDesktopVlcDeferredResumeSeek(player, attempt + 1);
    }));
  }

  void _scheduleDesktopVlcAudioRecovery(vlc.Player player, [int attempt = 1]) {
    unawaited(Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (!mounted || _desktopVlcPlayer != player) return;
      try {
        player.setVolume(_playerVolume);
        final trackCount = player.audioTrackCount;
        _debugPlayerEvent(
          'VLC audio recovery attempt=$attempt tracks=$trackCount',
        );
        if (trackCount > 0) {
          // VLC auto-selects audio. Track ids are not guaranteed to match
          // positions, so forcing id 1 can silence some servers after reload.
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
      _desktopVlcBufferingProgressSubscription,
    ];
    _desktopVlcPositionSubscription = null;
    _desktopVlcPlaybackSubscription = null;
    _desktopVlcErrorSubscription = null;
    _desktopVlcDimensionsSubscription = null;
    _desktopVlcBufferingProgressSubscription = null;
    final wasBiliBili = treatAsBiliBili ||
        _currentResolvedStream?.provider == RemoteProvider.bilibili;
    final retiredSourcePath = _desktopVlcSourcePath;
    _desktopVlcSourcePath = '';
    _desktopVlcIsPlaying = false;
    _desktopVlcDeferredResumeSeekHandled = false;
    _desktopVlcDeferredResumeSeekTarget = null;
    _desktopVlcDeferredResumeSeekReadyAt = null;
    _desktopVlcRebufferHoldActive = false;
    final playbackUri = Uri.tryParse(retiredSourcePath);
    final wasLoopbackProxy = playbackUri != null &&
        (playbackUri.host == '127.0.0.1' || playbackUri.host == 'localhost');
    final wasRemoteNetwork = playbackUri != null &&
        (playbackUri.scheme == 'http' || playbackUri.scheme == 'https');
    final player = _desktopVlcPlayer;
    _desktopVlcPlayer = null;
    for (final subscription in subscriptions) {
      await subscription?.cancel();
    }
    if (player != null) {
      _activeDesktopVlcPlayers.remove(player);
      if (delayForBiliBili &&
          widget.episode.isRemote &&
          (wasBiliBili || wasLoopbackProxy || wasRemoteNetwork)) {
        // libVLC can still be reading a remote stream or local proxy while
        // buffering. Native stop/dispose can block Flutter's UI thread.
        // Stopping or disposing that native player synchronously is what can
        // freeze Linux when the user changes source or leaves the screen.
        _debugPlayerEvent(
          'VLC native dispose deferred '
          'bilibili=$wasBiliBili loopback=$wasLoopbackProxy '
          'network=$wasRemoteNetwork',
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
        _currentResolvedStream?.playbackKind.trim().toLowerCase() !=
            'webview' ||
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
    _markSimklPlaybackPositionReady(playing: _youtubeWebPlaying);
    _setPlayerBuffering(true);
    if (mounted) {
      setState(() {
        _openedMedia = true;
        _error = '';
        _status = startPosition > Duration.zero
            ? 'YouTube reanudado en ${_formatPlaybackTime(startPosition)}'
            : 'Reproduciendo YouTube';
      });
      _commitCurrentEntryAfterOpen();
    }
    await controller.loadHtmlString(
      _youtubeSeriesWebPlayerHtml(
        videoId: videoId,
        startPosition: startPosition,
        title: widget.episode.displayName,
        sourceLabel: _sourceStatus().label,
        desktopControls: _usesDesktopYoutubeWebControls,
        initialVolume: _playerVolume,
      ),
      baseUrl: 'https://www.youtube-nocookie.com',
    );
    if (!mounted || openTicket != _openEpisodeTicket) {
      return true;
    }
    _startYoutubeWebStateTimer();
    _remotePlaybackAccepted = true;
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
    _syncSimklPlaybackState(
      _youtubeWebPlaying,
      buffering: state == 'buffering',
    );
    if (_youtubeWebPosition != previous) {
      _lastPositionChangeAt = DateTime.now();
    }
    _maybeScheduleUpcomingCards(_youtubeWebPosition);
    _maybeUpdateAnimeSkipPrompt(_youtubeWebPosition);
    _persistPlaybackThrottled();
    if (mounted) {
      setState(() {});
    }
  }

  void _handleYoutubeWebCommand(String command) {
    _showPlayerOverlays();
    switch (command) {
      case 'back':
        _exitPlayer();
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

  void _setPlayerVolumeSliderVisible(bool visible) {
    if (!_showsDesktopVolumeControl) {
      return;
    }
    if (_playerVolumeSliderVisible == visible) {
      return;
    }
    setState(() {
      _playerVolumeSliderVisible = visible;
      _playerOverlaysVisible = true;
    });
    _schedulePlayerOverlayHide();
  }

  void _togglePlayerMute() {
    if (!_showsDesktopVolumeControl) {
      return;
    }
    _playerVolumeButtonFocusNode.requestFocus();
    if (_playerVolume > 0.01) {
      _playerVolumeBeforeMute = _playerVolume;
      _setPlayerVolume(0);
    } else {
      final restored = _playerVolumeBeforeMute > 0.01
          ? _playerVolumeBeforeMute
          : _normalizedMaxVolume;
      _setPlayerVolume(restored);
    }
  }

  void _setPlayerVolume(double value) {
    final next = value.clamp(0.0, 1.0).toDouble();
    if ((_playerVolume - next).abs() < 0.001) {
      return;
    }
    if (next > 0.01) {
      _playerVolumeBeforeMute = next;
    }
    setState(() {
      _playerVolume = next;
      _status = 'Volumen ${(next * 100).round()}%';
      _playerOverlaysVisible = true;
    });
    unawaited(_applyPlayerVolume());
    _schedulePlayerOverlayHide();
  }

  Future<void> _applyPlayerVolume() async {
    final mediaKitPlayer = _player;
    if (mediaKitPlayer != null) {
      try {
        await mediaKitPlayer.setVolume(_playerVolume * _mediaKitMaxVolume);
      } catch (error) {
        _debugPlayerEvent('media_kit volume ignored error: $error');
      }
    }
    final vlcPlayer = _desktopVlcPlayer;
    if (vlcPlayer != null) {
      try {
        vlcPlayer.setVolume(_playerVolume);
      } catch (error) {
        _debugPlayerEvent('VLC volume ignored error: $error');
      }
    }
    final youtubeController = _youtubeWebController;
    if (youtubeController != null && _usesDesktopYoutubeWebControls) {
      final volume = (_playerVolume * _youtubeMaxVolume).round();
      try {
        await youtubeController.runJavaScript(
          'try { tanukiSetVolume($volume); } catch (e) {}',
        );
      } catch (error) {
        _debugPlayerEvent('YouTube volume ignored error: $error');
      }
    }
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
    _monitorAndroidExoValue(value);
    _setPlayerBuffering(value.isBuffering);
    final previous = _lastPosition;
    _lastPosition = value.position;
    _lastDuration = value.duration;
    _maybeRefineRemoteResume(value.duration);
    if (value.position != previous) {
      _lastPositionChangeAt = DateTime.now();
      _remotePlaybackAccepted = true;
    }
    _syncSimklPlaybackState(value.isPlaying, buffering: value.isBuffering);
    _maybeSendDeferredSimklStart();
    _maybeHoldAndroidExoRebuffer(controller, value);
    _maybeScheduleUpcomingCards(value.position);
    _maybeUpdateAnimeSkipPrompt(value.position);
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
        shouldRebuildAndroidExoProgress(
          overlaysVisible: _playerOverlaysVisible,
          controlsFocused: _playerControlsFocused,
          dialogOpen: _playerDialogOpen,
          subtitlesEnabled: _subtitlesEnabled,
          captionText: _activeRemoteSubtitleCaption.isNotEmpty
              ? _activeRemoteSubtitleCaption
              : value.caption.text,
        ) &&
        now.difference(_lastAndroidExoRebuild) >=
            const Duration(milliseconds: 250)) {
      _lastAndroidExoRebuild = now;
      setState(() {});
    }
  }

  void _monitorAndroidExoValue(vp.VideoPlayerValue value) {
    final now = DateTime.now();
    final previousAt = _lastAndroidExoValueAt;
    final previousPosition = _lastAndroidExoValuePosition;
    _lastAndroidExoValueAt = now;
    _lastAndroidExoValuePosition = value.position;
    if (!_openedMedia ||
        !value.isPlaying ||
        value.isBuffering ||
        previousAt == null ||
        previousPosition == null) {
      return;
    }
    final wallGap = now.difference(previousAt);
    final positionDelta = value.position - previousPosition;
    if (!shouldReportAndroidExoListenerGap(
      wallGap: wallGap,
      positionDelta: positionDelta,
    )) {
      return;
    }
    _reportPlaybackMonitorIssue(
      'exo-listener-gap',
      'wall=${wallGap.inMilliseconds}ms '
          'positionDelta=${positionDelta.inMilliseconds}ms '
          'buffered=${value.buffered.length}',
    );
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

  void _scheduleAndroidExoDeferredResumeSeek(
    vp.VideoPlayerController controller,
    Duration? resumePosition,
  ) {
    if (_androidExoDeferredResumeSeekHandled ||
        resumePosition == null ||
        resumePosition <= const Duration(seconds: 2) ||
        !shouldDeferAndroidExoInitialSeek(_currentResolvedStream)) {
      return;
    }
    final warmup = deferredResumeSeekWarmup(_currentResolvedStream);
    _debugPlayerEvent(
      'ExoPlayer deferred resume seek warming target='
      '${_formatPlaybackTime(resumePosition)} warmup=${warmup.inSeconds}s',
    );
    unawaited(Future<void>.delayed(warmup, () {
      if (_androidExoDeferredResumeSeekHandled ||
          !mounted ||
          _androidExoController != controller ||
          !controller.value.isInitialized) {
        return;
      }
      _androidExoDeferredResumeSeekHandled = true;
      _debugPlayerEvent(
        'ExoPlayer deferred resume seek target='
        '${_formatPlaybackTime(resumePosition)}',
      );
      unawaited(_seekAndroidExoPlayer(resumePosition));
    }));
  }

  void _maybeHoldAndroidExoRebuffer(
    vp.VideoPlayerController controller,
    vp.VideoPlayerValue value,
  ) {
    if (!shouldHoldStableRemoteAv1Rebuffer(
      stream: _currentResolvedStream,
      openedMedia: _openedMedia,
      isBuffering: value.isBuffering,
      isPlaying: value.isPlaying,
      position: value.position,
      holdActive: _androidExoRebufferHoldActive,
    )) {
      return;
    }
    unawaited(_holdAndroidExoRebuffer(controller));
  }

  Future<void> _holdAndroidExoRebuffer(
    vp.VideoPlayerController controller,
  ) async {
    _androidExoRebufferHoldActive = true;
    _setPlayerBuffering(true);
    if (mounted) {
      setState(() {
        _status = 'Recargando buffer...';
      });
    }
    try {
      _debugPlayerEvent(
        'ExoPlayer rebuffer hold target='
        '${_stableRemoteAv1StartupBufferTarget.inSeconds}s',
      );
      await controller.pause();
      final startedAt = DateTime.now();
      var sawBufferedRange = controller.value.buffered.isNotEmpty;
      var bufferedAhead = bufferedAheadForPosition(
        position: controller.value.position,
        ranges: controller.value.buffered,
      );
      while (mounted && _androidExoController == controller) {
        final value = controller.value;
        sawBufferedRange = sawBufferedRange || value.buffered.isNotEmpty;
        bufferedAhead = bufferedAheadForPosition(
          position: value.position,
          ranges: value.buffered,
        );
        final elapsed = DateTime.now().difference(startedAt);
        if (bufferedAhead >= _stableRemoteAv1StartupBufferTarget ||
            (!sawBufferedRange &&
                elapsed >= _stableRemoteAv1StartupBufferTarget) ||
            elapsed >= _stableRemoteAv1StartupBufferMaxWait) {
          _debugPlayerEvent(
            'ExoPlayer rebuffer hold ready ahead='
            '${_formatPlaybackTime(bufferedAhead)} elapsed='
            '${elapsed.inSeconds}s sawRanges=$sawBufferedRange',
          );
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!mounted ||
          _androidExoController != controller ||
          !controller.value.isInitialized) {
        return;
      }
      await controller.play();
    } finally {
      _androidExoRebufferHoldActive = false;
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
    return _bestKnownPlaybackDuration;
  }

  Duration get _expectedRemoteDuration {
    final raw =
        _currentResolvedStream?.httpHeaders['X-Tanuki-Duration-Seconds'] ?? '';
    final seconds = int.tryParse(raw.trim()) ?? 0;
    return seconds > 0 ? Duration(seconds: seconds) : Duration.zero;
  }

  Duration get _bestKnownPlaybackDuration {
    final candidates = <Duration>[
      _lastDuration,
      _expectedRemoteDuration,
      _storedPlaybackDuration,
      _episodeLabelDuration,
    ];
    return candidates.reduce(
      (best, current) => current > best ? current : best,
    );
  }

  Duration get _animeSkipLookupDuration {
    if (_lastDuration > Duration.zero) {
      return _lastDuration;
    }
    if (_expectedRemoteDuration > Duration.zero) {
      return _expectedRemoteDuration;
    }
    if (_storedPlaybackDuration > Duration.zero) {
      return _storedPlaybackDuration;
    }
    return _episodeLabelDuration;
  }

  Duration get _storedPlaybackDuration {
    final record = widget.controller.playbackForEpisode(widget.episode);
    final durationMs = record?.durationMs ?? 0;
    return durationMs > 0 ? Duration(milliseconds: durationMs) : Duration.zero;
  }

  Duration get _episodeLabelDuration {
    final label = widget.episode.durationLabel.trim().toLowerCase();
    if (label.isEmpty) {
      return Duration.zero;
    }
    var minutes = 0;
    var seconds = 0;
    for (final match in RegExp(r'(\d+)\s*(h|hr|hrs|hora|horas|min|m|sec|s)')
        .allMatches(label)) {
      final value = int.tryParse(match.group(1) ?? '') ?? 0;
      final unit = match.group(2) ?? '';
      if (unit.startsWith('h')) {
        minutes += value * 60;
      } else if (unit.startsWith('s')) {
        seconds += value;
      } else {
        minutes += value;
      }
    }
    if (minutes <= 0 && seconds <= 0) {
      final value =
          int.tryParse(RegExp(r'\d+').firstMatch(label)?.group(0) ?? '');
      if (value != null && value > 0) {
        minutes = value;
      }
    }
    return minutes > 0 || seconds > 0
        ? Duration(minutes: minutes, seconds: seconds)
        : Duration.zero;
  }

  Future<void> _applyAndroidExoSubtitleTrack() async {
    final controller = _androidExoController;
    if (controller == null) {
      return;
    }
    if (!_subtitlesEnabled) {
      await controller.setClosedCaptionFile(null);
      if (mounted) {
        setState(() => _remoteSubtitleCues = const []);
      }
      return;
    }
    _reconcileRemoteSubtitleSelection(_currentResolvedStream);
    final track = selectRemoteSubtitleTrack(
      _currentResolvedStream,
      selectedKey: _selectedRemoteSubtitleTrackKey,
    );
    if (track == null) {
      await controller.setClosedCaptionFile(null);
      if (mounted) {
        setState(() => _remoteSubtitleCues = const []);
      }
      return;
    }
    _selectedRemoteSubtitleTrackKey = remoteSubtitleTrackKey(track);
    await controller.setClosedCaptionFile(null);
    await _loadRemoteSubtitleCuesForSelectedTrack(source: 'android subtitle');
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
    if (_shouldSuppressStableRemoteAv1AutomaticFallback()) {
      _debugPlayerEvent(
        'fallback suppressed for established AnimeAV1 HLS '
        'reason="${_debugShortText(reason)}" '
        'position=${_formatPlaybackTime(_lastPosition)}',
      );
      _setPlayerBuffering(true);
      if (mounted) {
        setState(() {
          _error = '';
          _status = 'Recuperando AnimeAV1 HLS...';
        });
      }
      return true;
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
    if (_shouldSuppressStableRemoteAv1AutomaticFallback()) {
      _debugPlayerEvent(
        'server fallback suppressed for established AnimeAV1 HLS '
        'reason="${_debugShortText(reason)}" '
        'position=${_formatPlaybackTime(_lastPosition)}',
      );
      _setPlayerBuffering(true);
      if (mounted) {
        setState(() {
          _error = '';
          _status = 'Recuperando AnimeAV1 HLS...';
        });
      }
      return true;
    }
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
    if (!_shouldWatchRemoteVideoFrame()) {
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
      _syncSimklPlaybackState(playing, buffering: _playerBuffering);
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
        !_shouldWatchRemoteVideoFrame()) {
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
    unawaited(_retryRemoteFallback(_missingVideoFallbackReason()));
  }

  void _armRemoteVideoFrameWatchdog(Player player) {
    if (_remoteVideoFrameReady ||
        _remoteVideoFrameFallbackHandled ||
        !_shouldWatchRemoteVideoFrame()) {
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
            !_shouldWatchRemoteVideoFrame()) {
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
          _retryRemoteFallback(_missingVideoFallbackReason()),
        );
      },
    );
  }

  bool get _hasRemoteVideoFrame {
    return _remoteVideoFrameReady ||
        ((_remoteVideoWidth ?? 0) > 0 && (_remoteVideoHeight ?? 0) > 0);
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
    if (_shouldWatchRemoteVideoFrame() && !_hasRemoteVideoFrame) {
      return false;
    }
    return _remotePlaybackAccepted ||
        _remoteVideoFrameReady ||
        _hasRemoteVideoFrame;
  }

  bool _shouldSuppressStableRemoteAv1AutomaticFallback() {
    return shouldSuppressStableRemoteAv1AutomaticFallback(
      stream: _currentResolvedStream,
      position: _lastPosition,
      remotePlaybackAccepted: _remotePlaybackAccepted,
      hasVideoFrame: _hasRemoteVideoFrame,
    );
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
            !_shouldWatchRemoteVideoFrame() ||
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

  bool _shouldWatchRemoteVideoFrame() {
    final provider =
        _currentResolvedStream?.provider ?? widget.episode.provider;
    return shouldWatchRemoteVideoFrame(provider, _currentResolvedStream);
  }

  String _missingVideoFallbackReason() {
    final provider =
        _currentResolvedStream?.provider ?? widget.episode.provider;
    if (provider == RemoteProvider.aniPm) {
      return '${remoteServerLabel(_currentResolvedStream?.server ?? '')} '
          'reprodujo audio pero no video';
    }
    return 'AnimeAV1 reprodujo audio pero no video';
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
      unawaited(_pauseSimklScrobble());
      final androidExoController = _androidExoController;
      if (androidExoController != null) {
        androidExoController.removeListener(_handleAndroidExoValue);
        _androidExoController = null;
        unawaited(androidExoController.dispose());
      }
      unawaited(_disposeDesktopVlcPlayer(
        delayForBiliBili: true,
        treatAsBiliBili: wasBiliBili,
      ));
      unawaited(_player?.stop());
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
      _maybeSendDeferredSimklStart();
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
      _maybeUpdateAnimeSkipPrompt(position);
      _persistPlaybackThrottled();
      if (mounted && _remoteSubtitleCues.isNotEmpty) {
        setState(() {});
      }
    });
    _durationSubscription = player.stream.duration.listen((duration) {
      _lastDuration = duration;
      _maybeRefineRemoteResume(duration);
      _maybeSendDeferredSimklStart();
      _debugPlayerEvent(
        'duration=${_formatPlaybackTime(duration)} ${_debugPlayerState(player)}',
      );
      _maybeScheduleUpcomingCards(_lastPosition);
      _maybeUpdateAnimeSkipPrompt(_lastPosition);
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
    unawaited(_persistPlayback(notify: false));
  }

  Future<void> _persistPlayback({
    bool force = false,
    bool completed = false,
    bool notify = true,
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
      notify: notify,
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

  void _resetSimklScrobbleSession() {
    _simklPauseDebounceTimer?.cancel();
    _simklPauseDebounceTimer = null;
    _simklScrobbleActive = false;
    _lastSimklScrobbleProgress = -1;
    _simklPlaybackPositionReady = false;
    _pendingSimklStartAfterPositionReady = false;
    _simklStartRetryScheduled = false;
    _simklStartDurationRetryUsed = false;
  }

  void _markSimklPlaybackPositionReady({
    required bool playing,
    bool buffering = false,
  }) {
    _simklPlaybackPositionReady = true;
    final shouldStart = _pendingSimklStartAfterPositionReady || playing;
    _pendingSimklStartAfterPositionReady = false;
    if (shouldStart) {
      _syncSimklPlaybackState(true, buffering: buffering);
    }
  }

  void _startSimklScrobble() {
    if (_simklScrobbleActive) {
      final progress = _simklProgressPercentForCurrentPosition();
      if (_lastSimklScrobbleProgress <= 2 && progress > 5) {
        unawaited(_sendSimklScrobble('start', force: true));
      }
      return;
    }
    _simklScrobbleActive = true;
    _lastSimklScrobbleProgress = -1;
    unawaited(_sendSimklScrobble('start', force: true));
  }

  void _syncSimklPlaybackState(bool playing, {bool buffering = false}) {
    _simklPauseDebounceTimer?.cancel();
    _simklPauseDebounceTimer = null;
    if (playing) {
      if (!_simklPlaybackPositionReady) {
        _pendingSimklStartAfterPositionReady = true;
        return;
      }
      _startSimklScrobble();
      return;
    }
    if (buffering || !_simklScrobbleActive || _completionCommitted) {
      return;
    }
    _simklPauseDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _simklPauseDebounceTimer = null;
      if (mounted && !_completionCommitted) {
        unawaited(_pauseSimklScrobble());
      }
    });
  }

  void _maybeSendDeferredSimklStart() {
    if (!_simklScrobbleActive ||
        _completionCommitted ||
        _lastSimklScrobbleProgress >= 0 ||
        _bestKnownPlaybackDuration <= Duration.zero ||
        _simklPositionForAction('start') <= Duration.zero) {
      return;
    }
    unawaited(_sendSimklScrobble('start', force: true));
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
    final normalizedAction = action.trim().toLowerCase();
    var durationForScrobble = _bestKnownPlaybackDuration;
    var positionForScrobble = completed
        ? durationForScrobble
        : _simklPositionForAction(normalizedAction);
    if (normalizedAction == 'start' &&
        positionForScrobble > Duration.zero &&
        durationForScrobble <= Duration.zero) {
      if (_simklStartDurationRetryUsed || _simklStartRetryScheduled) {
        return;
      }
      _simklStartDurationRetryUsed = true;
      _simklStartRetryScheduled = true;
      Timer(const Duration(milliseconds: 1500), () {
        _simklStartRetryScheduled = false;
        if (mounted && _simklScrobbleActive && !_completionCommitted) {
          unawaited(_sendSimklScrobble('start', force: true));
        }
      });
      return;
    }
    final progress = completed
        ? 100.0
        : durationForScrobble > Duration.zero
            ? (positionForScrobble.inMilliseconds /
                    durationForScrobble.inMilliseconds *
                    100)
                .clamp(0, 100)
                .toDouble()
            : 0.0;
    if (!force && (progress - _lastSimklScrobbleProgress).abs() < 1) {
      return;
    }
    final sent = await widget.controller.sendSimklScrobble(
      widget.episode,
      position: positionForScrobble,
      duration: durationForScrobble,
      action: normalizedAction,
    );
    if (sent) {
      _lastSimklScrobbleProgress = progress;
    }
  }

  double _simklProgressPercentForCurrentPosition() {
    final durationForScrobble = _bestKnownPlaybackDuration;
    if (durationForScrobble <= Duration.zero) {
      return 0;
    }
    return (_simklPositionForAction('start').inMilliseconds /
            durationForScrobble.inMilliseconds *
            100)
        .clamp(0, 100)
        .toDouble();
  }

  Duration _simklPositionForAction(String action) {
    if (action == 'start') {
      final resume = widget.controller.resumePositionForEpisode(widget.episode);
      if (resume != null && resume > _lastPosition) {
        return resume;
      }
    }
    return _lastPosition;
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

  void _resetAnimeSkip() {
    _animeSkipLoadTicket += 1;
    _loadingAnimeSkipIntervals = false;
    _animeSkipLoadCompleted = false;
    _animeSkipIntervals = const [];
    _activeAnimeSkipInterval = null;
    _animeSkipLoadedDuration = Duration.zero;
    _dismissedAnimeSkipIntervals.clear();
    _usedAnimeSkipIntervals.clear();
  }

  void _maybeLoadAnimeSkipIntervals(Duration duration) {
    if (_loadingAnimeSkipIntervals || duration <= Duration.zero) {
      return;
    }
    if (_animeSkipLoadCompleted) {
      final sameDuration = _animeSkipLoadedDuration > Duration.zero &&
          _durationDistance(_animeSkipLoadedDuration, duration) <=
              const Duration(seconds: 8);
      if (_animeSkipIntervals.isNotEmpty || sameDuration) {
        return;
      }
    }
    final ticket = ++_animeSkipLoadTicket;
    _loadingAnimeSkipIntervals = true;
    unawaited(() async {
      try {
        final intervals = await widget.controller.fetchAnimeSkipTimesForEpisode(
          widget.episode,
          duration: duration,
        );
        if (!mounted || ticket != _animeSkipLoadTicket) {
          return;
        }
        _animeSkipIntervals = intervals;
        _animeSkipLoadCompleted = true;
        _animeSkipLoadedDuration = duration;
        _debugPlayerEvent('AniSkip intervals=${intervals.length}');
        _maybeUpdateAnimeSkipPrompt(_lastPosition);
      } catch (error) {
        if (mounted && ticket == _animeSkipLoadTicket) {
          _animeSkipLoadCompleted = true;
          _animeSkipLoadedDuration = duration;
          _debugPlayerEvent('AniSkip failed: $error');
        }
      } finally {
        if (mounted && ticket == _animeSkipLoadTicket) {
          _loadingAnimeSkipIntervals = false;
        }
      }
    }());
  }

  void _maybeUpdateAnimeSkipPrompt(Duration position) {
    final duration = _animeSkipLookupDuration;
    _maybeLoadAnimeSkipIntervals(duration);
    final autoSkip = _activeAutoSkippableAnimeSkipInterval(position);
    if (autoSkip != null) {
      unawaited(_skipAnimeSegment(autoSkip));
      return;
    }
    final next = _activePromptableAnimeSkipInterval(position);
    if (next?.stableKey == _activeAnimeSkipInterval?.stableKey) {
      return;
    }
    if (!mounted) {
      _activeAnimeSkipInterval = next;
      return;
    }
    setState(() {
      _activeAnimeSkipInterval = next;
      if (next != null) {
        _playerControlsFocused = false;
      }
    });
    if (next != null) {
      _debugPlayerEvent(
        'AniSkip prompt ${next.type.id} '
        '${_formatPlaybackTime(next.start)}-${_formatPlaybackTime(next.end)} '
        'at=${_formatPlaybackTime(position)}',
      );
      _playerOverlayHideTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _activeAnimeSkipInterval?.stableKey == next.stableKey &&
            _animeSkipButtonFocusNode.canRequestFocus) {
          _animeSkipButtonFocusNode.requestFocus();
        }
      });
    } else if (_animeSkipButtonFocusNode.hasFocus) {
      _playerControlsRootFocusNode.requestFocus();
    }
  }

  AniSkipInterval? _activePromptableAnimeSkipInterval(Duration position) {
    if (_animeSkipIntervals.isEmpty) {
      return null;
    }
    for (final interval in _animeSkipIntervals) {
      if (!_isPromptableAnimeSkipType(interval.type) ||
          _isAutoSkippableAnimeSkipType(interval.type) ||
          _dismissedAnimeSkipIntervals.contains(interval.stableKey) ||
          _usedAnimeSkipIntervals.contains(interval.stableKey)) {
        continue;
      }
      final promptStart = interval.start > _animeSkipPromptLead
          ? interval.start - _animeSkipPromptLead
          : Duration.zero;
      if (position >= promptStart && position < interval.end) {
        return interval;
      }
    }
    return null;
  }

  AniSkipInterval? _activeAutoSkippableAnimeSkipInterval(Duration position) {
    if (_animeSkipIntervals.isEmpty) {
      return null;
    }
    for (final interval in _animeSkipIntervals) {
      if (!_isAutoSkippableAnimeSkipType(interval.type) ||
          _usedAnimeSkipIntervals.contains(interval.stableKey)) {
        continue;
      }
      if (position >= interval.start && position < interval.end) {
        return interval;
      }
    }
    return null;
  }

  bool _isAutoSkippableAnimeSkipType(AnimeSkipSegmentType type) {
    final state = widget.controller.state;
    return switch (type) {
      AnimeSkipSegmentType.opening => state.skipOpeningSegments,
      AnimeSkipSegmentType.ending => state.skipEndingSegments,
      AnimeSkipSegmentType.mixedOpening => state.skipMixedOpeningSegments,
      AnimeSkipSegmentType.mixedEnding => state.skipMixedEndingSegments,
      AnimeSkipSegmentType.recap => state.skipRecapSegments,
    };
  }

  bool _isPromptableAnimeSkipType(AnimeSkipSegmentType type) {
    return type == AnimeSkipSegmentType.opening ||
        type == AnimeSkipSegmentType.ending;
  }

  String _animeSkipPromptLabel(AnimeSkipSegmentType type) {
    return switch (type) {
      AnimeSkipSegmentType.opening => 'Saltar opening',
      AnimeSkipSegmentType.ending => 'Saltar ending',
      _ => 'Saltar',
    };
  }

  Future<void> _skipActiveAnimeSegment() async {
    final interval = _activeAnimeSkipInterval;
    if (interval == null) {
      return;
    }
    await _skipAnimeSegment(interval);
  }

  Future<void> _skipAnimeSegment(AniSkipInterval interval) async {
    _usedAnimeSkipIntervals.add(interval.stableKey);
    if (mounted) {
      setState(() {
        if (_activeAnimeSkipInterval?.stableKey == interval.stableKey) {
          _activeAnimeSkipInterval = null;
        }
      });
    }
    _playerControlsRootFocusNode.requestFocus();
    final target = interval.end > _animeSkipSeekEndOffset
        ? interval.end - _animeSkipSeekEndOffset
        : Duration.zero;
    _debugPlayerEvent(
      'AniSkip skip ${interval.type.id} to=${_formatPlaybackTime(target)}',
    );
    await _seekPlaybackForAnimeSkip(target);
  }

  void _dismissActiveAnimeSkip() {
    final interval = _activeAnimeSkipInterval;
    if (interval == null) {
      return;
    }
    _dismissedAnimeSkipIntervals.add(interval.stableKey);
    if (mounted) {
      setState(() {
        _activeAnimeSkipInterval = null;
      });
    }
    _debugPlayerEvent('AniSkip dismissed ${interval.type.id}');
    _playerControlsRootFocusNode.requestFocus();
  }

  Future<void> _seekPlaybackForAnimeSkip(Duration target) async {
    final clamped = target < Duration.zero ? Duration.zero : target;
    final android = _androidExoController;
    if (android != null && android.value.isInitialized) {
      await android.seekTo(clamped);
      _androidExoCompletionHandled = false;
    } else if (_youtubeWebController != null) {
      final seconds = max(0, clamped.inMilliseconds / 1000).toStringAsFixed(3);
      await _youtubeWebController!
          .runJavaScript('try { tanukiSeekTo($seconds); } catch (e) {}');
      _youtubeWebPosition = clamped;
      _youtubeWebEnded = false;
    } else if (_desktopVlcPlayer != null) {
      if (_currentResolvedStream?.provider == RemoteProvider.bilibili) {
        return;
      }
      _desktopVlcPlayer!.seek(clamped);
      _desktopVlcCompletionHandled = false;
    } else if (_player != null) {
      await _seekPrecisely(_player!, clamped);
    }
    _lastPosition = clamped;
    _lastPositionChangeAt = DateTime.now();
    unawaited(_persistPlayback(force: true));
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
      PlayerLaunchMode.continueWatchingRoundRobin =>
        _continueWatchingEntriesAfterCurrent(
          limit: 2,
          preferSameSeries: false,
        ),
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
    bool preferSameSeries = true,
  }) {
    final sameSeriesEntries = preferSameSeries
        ? _seriesEntriesAfterCurrent(limit: limit)
        : const <EpisodeItem>[];
    if (preferSameSeries && sameSeriesEntries.isNotEmpty) {
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
      if (!_canShowUpcomingEpisode(episode)) {
        continue;
      }
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
    if (!_episodeHasPlaybackRoute(episode)) {
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
    final playerControlScale =
        shouldUseAndroidPhoneUi(_androidMediaCapabilities) ? 2.0 : 1.0;
    final bottomControlInset = 14.0 * playerControlScale;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _playerControlsRootFocusNode,
        autofocus: true,
        onKeyEvent: _handlePlayerRootKey,
        child: Listener(
          onPointerMove: (_) => _showPlayerOverlays(throttled: true),
          onPointerHover: (_) => _showPlayerOverlays(throttled: true),
          child: Stack(
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: _openedMedia &&
                          _androidExoController?.value.isInitialized == true
                      ? _AndroidExoVideoSurface(
                          controller: _androidExoController!,
                          fit: _boxFitForVideoScaleMode(_videoScaleMode),
                          subtitlesEnabled:
                              _subtitlesEnabled && _remoteSubtitleCues.isEmpty,
                        )
                      : _openedMedia && _youtubeWebController != null
                          ? _YoutubeWebVideoSurface(
                              controller: _youtubeWebController!,
                            )
                          : _openedMedia && _desktopVlcPlayer != null
                              ? vlc.Video(
                                  player: _desktopVlcPlayer!,
                                  fit:
                                      _boxFitForVideoScaleMode(_videoScaleMode),
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
                                          visible: _subtitlesEnabled &&
                                              _remoteSubtitleCues.isEmpty,
                                        ),
                                      ),
                                    )
                                  : _PlayerFallback(
                                      episode: episode,
                                      error: _error,
                                    ),
                ),
              ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _togglePlayerOverlaysFromPointer,
                ),
              ),
              if (_openedMedia && _activeRemoteSubtitleCaption.isNotEmpty)
                Positioned(
                  left: 32,
                  right: 32,
                  bottom: 72,
                  child: IgnorePointer(
                    child: Text(
                      _activeRemoteSubtitleCaption,
                      textAlign: TextAlign.center,
                      style: _subtitleOverlayTextStyle,
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
              Positioned(
                left: 48,
                bottom: 96,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  reverseDuration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: child,
                    );
                  },
                  child: _activeAnimeSkipInterval == null
                      ? const SizedBox.shrink(
                          key: ValueKey('anime-skip-none'),
                        )
                      : _AnimeSkipPrompt(
                          key: ValueKey(
                            'anime-skip-${_activeAnimeSkipInterval!.stableKey}',
                          ),
                          label: _animeSkipPromptLabel(
                            _activeAnimeSkipInterval!.type,
                          ),
                          focusNode: _animeSkipButtonFocusNode,
                          onPressed: () => unawaited(_skipActiveAnimeSegment()),
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
                      child: RepaintBoundary(
                        child: _PlayerTopBar(
                          episode: episode,
                          status: sourceStatus.label,
                          statusIcon: sourceStatus.icon,
                          statusColor: sourceStatus.color,
                          onBack: _exitPlayer,
                          onPrevious: _playPrevious,
                          onNext: _playNext,
                          onSettings: _showPlayerSettingsDialog,
                          onEpisodes: () => unawaited(_showEpisodeListPanel()),
                          onToggleVolume: _togglePlayerMute,
                          onVolumeHoverChanged: _setPlayerVolumeSliderVisible,
                          onVolumeChanged: _setPlayerVolume,
                          onFullscreen: () =>
                              unawaited(_toggleFullscreenMode()),
                          onControlFocusChanged: _setPlayerControlsFocused,
                          showVolumeControl: _showsDesktopVolumeControl,
                          showVolumeSlider: _playerVolumeSliderVisible,
                          volume: _playerVolume,
                          showFullscreenControl: _showsPlayerFullscreenControl,
                          backButtonFocusNode: _playerBackButtonFocusNode,
                          previousButtonFocusNode:
                              _playerPreviousButtonFocusNode,
                          nextButtonFocusNode: _playerNextButtonFocusNode,
                          settingsButtonFocusNode:
                              _playerSettingsButtonFocusNode,
                          episodesButtonFocusNode:
                              _playerEpisodesButtonFocusNode,
                          volumeButtonFocusNode: _playerVolumeButtonFocusNode,
                          fullscreenButtonFocusNode:
                              _playerFullscreenButtonFocusNode,
                          controlScale: playerControlScale,
                        ),
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
                  left: bottomControlInset,
                  right: bottomControlInset,
                  bottom: 10 * playerControlScale,
                  child: IgnorePointer(
                    ignoring: !_playerOverlaysVisible,
                    child: AnimatedOpacity(
                      opacity: _playerOverlaysVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: RepaintBoundary(
                        child: _AndroidExoControls(
                          controller: _androidExoController!,
                          onTogglePlayback: _toggleAndroidExoPlayback,
                          onSeek: _seekAndroidExoPlayer,
                          formatTime: _formatPlaybackTime,
                          onFocusChanged: _setPlayerControlsFocused,
                          playButtonFocusNode: _playerBottomPlayFocusNode,
                          progressFocusNode: _playerBottomProgressFocusNode,
                          controlScale: playerControlScale,
                        ),
                      ),
                    ),
                  ),
                ),
              if (_openedMedia &&
                  _youtubeWebController != null &&
                  !useDesktopYoutubeWebControls)
                Positioned(
                  left: bottomControlInset,
                  right: bottomControlInset,
                  bottom: 10 * playerControlScale,
                  child: IgnorePointer(
                    ignoring: !_playerOverlaysVisible,
                    child: AnimatedOpacity(
                      opacity: _playerOverlaysVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: RepaintBoundary(
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
                          controlScale: playerControlScale,
                        ),
                      ),
                    ),
                  ),
                ),
              if (_openedMedia && _desktopVlcPlayer != null)
                Positioned(
                  left: bottomControlInset,
                  right: bottomControlInset,
                  bottom: 10 * playerControlScale,
                  child: IgnorePointer(
                    ignoring: !_playerOverlaysVisible,
                    child: AnimatedOpacity(
                      opacity: _playerOverlaysVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: RepaintBoundary(
                        child: _DesktopVlcControls(
                          player: _desktopVlcPlayer!,
                          onTogglePlayback: _toggleDesktopVlcPlayback,
                          onSeek: _seekDesktopVlcPlayer,
                          formatTime: _formatPlaybackTime,
                          onFocusChanged: _setPlayerControlsFocused,
                          playButtonFocusNode: _playerBottomPlayFocusNode,
                          progressFocusNode: _playerBottomProgressFocusNode,
                          controlScale: playerControlScale,
                        ),
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

  void _showPlayerOverlays({bool throttled = false}) {
    if (!mounted) {
      return;
    }
    final now = DateTime.now();
    if (throttled &&
        _playerOverlaysVisible &&
        now.difference(_lastPlayerOverlayPointerRefresh) <
            _playerPointerOverlayRefreshInterval) {
      return;
    }
    _lastPlayerOverlayPointerRefresh = now;
    if (!_playerOverlaysVisible) {
      setState(() {
        _playerOverlaysVisible = true;
      });
    }
    _schedulePlayerOverlayHide();
  }

  void _togglePlayerOverlaysFromPointer() {
    if (!mounted || !_openedMedia) {
      _showPlayerOverlays();
      return;
    }
    final nextVisible = !_playerOverlaysVisible;
    setState(() {
      _playerOverlaysVisible = nextVisible;
      if (!nextVisible) {
        _playerControlsFocused = false;
      }
    });
    if (nextVisible) {
      _schedulePlayerOverlayHide();
    } else {
      _playerOverlayHideTimer?.cancel();
      _playerControlsRootFocusNode.requestFocus();
    }
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
    final key = event.logicalKey;
    if (event is KeyUpEvent && _isPlayerActivationKey(key)) {
      if (_suppressNextPlayerActivationKeyUp) {
        _suppressNextPlayerActivationKeyUp = false;
        return KeyEventResult.handled;
      }
      if (_activeAnimeSkipInterval != null) {
        unawaited(_skipActiveAnimeSegment());
        return KeyEventResult.handled;
      }
      if (_activateFocusedPlayerControl()) {
        _showPlayerOverlays();
        return KeyEventResult.handled;
      }
      _showPlayerOverlays();
      return KeyEventResult.handled;
    }
    if (_activeAnimeSkipInterval != null && _isPlayerBackKey(key)) {
      if (event is KeyDownEvent) {
        _dismissActiveAnimeSkip();
      }
      return KeyEventResult.handled;
    }
    if (_isPlayerBackKey(key)) {
      return _handlePlayerBackKey(event);
    }
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (_activeAnimeSkipInterval != null) {
      if (_isPlayerActivationKey(key)) {
        return KeyEventResult.handled;
      }
    }
    if (_isPlayerActivationKey(key)) {
      if (_hasFocusedPlayerControl) {
        return KeyEventResult.handled;
      }
      _showPlayerOverlays();
      _requestPlayerControlFocus(preferBottom: true);
      _suppressNextPlayerActivationKeyUp = true;
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
        key == LogicalKeyboardKey.arrowRight;
    if (isNavigationKey) {
      _showPlayerOverlays();
      if (!_hasFocusedPlayerControl) {
        _requestPlayerControlFocus(
          preferBottom: key == LogicalKeyboardKey.arrowDown,
        );
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handlePlayerBackKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (_playerRemoteBackKeyDown) {
        return KeyEventResult.handled;
      }
      _playerRemoteBackKeyDown = true;
      _playerRemoteBackLongPressTriggered = false;
      _playerRemoteBackHoldTimer?.cancel();
      _playerRemoteBackHoldTimer = Timer(
        _playerRemoteBackHoldExitDelay,
        _triggerPlayerRemoteBackLongPressExit,
      );
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (event is! KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    _playerRemoteBackKeyDown = false;
    _playerRemoteBackHoldTimer?.cancel();
    _playerRemoteBackHoldTimer = null;
    if (_playerRemoteBackLongPressTriggered) {
      _playerRemoteBackLongPressTriggered = false;
      return KeyEventResult.handled;
    }
    final nextVisible = !_playerOverlaysVisible;
    if (mounted) {
      setState(() {
        _playerControlsFocused = nextVisible;
        _playerOverlaysVisible = nextVisible;
      });
    }
    if (nextVisible) {
      _requestPlayerControlFocus();
      _schedulePlayerOverlayHide();
    } else {
      _playerControlsRootFocusNode.requestFocus();
      _playerOverlayHideTimer?.cancel();
    }
    return KeyEventResult.handled;
  }

  void _triggerPlayerRemoteBackLongPressExit() {
    if (!mounted || !_playerRemoteBackKeyDown || _leavingPlayer) {
      return;
    }
    _playerRemoteBackLongPressTriggered = true;
    _exitPlayer();
  }

  bool _isPlayerBackKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape;
  }

  bool _isPlayerActivationKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA;
  }

  bool get _hasFocusedPlayerControl {
    return _playerBackButtonFocusNode.hasFocus ||
        _playerPreviousButtonFocusNode.hasFocus ||
        _playerNextButtonFocusNode.hasFocus ||
        _playerSubtitlesButtonFocusNode.hasFocus ||
        _playerFitButtonFocusNode.hasFocus ||
        _playerSettingsButtonFocusNode.hasFocus ||
        _playerEpisodesButtonFocusNode.hasFocus ||
        _playerVolumeButtonFocusNode.hasFocus ||
        _playerFullscreenButtonFocusNode.hasFocus ||
        _playerBottomPlayFocusNode.hasFocus ||
        _playerBottomProgressFocusNode.hasFocus ||
        _animeSkipButtonFocusNode.hasFocus;
  }

  bool _activateFocusedPlayerControl() {
    if (_playerBackButtonFocusNode.hasFocus) {
      _exitPlayer();
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
    if (_playerVolumeButtonFocusNode.hasFocus) {
      _togglePlayerMute();
      return true;
    }
    if (_playerFullscreenButtonFocusNode.hasFocus) {
      unawaited(_toggleFullscreenMode());
      return true;
    }
    if (_playerBottomPlayFocusNode.hasFocus ||
        _playerBottomProgressFocusNode.hasFocus) {
      _toggleCurrentPlayback();
      return true;
    }
    return false;
  }

  void _toggleCurrentPlayback() {
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
  }

  void _exitPlayer() {
    if (_leavingPlayer || !mounted) {
      return;
    }
    _leavingPlayer = true;
    _episodeTransitionInProgress = true;
    ++_openEpisodeTicket;
    _cancelRemoteVideoFrameWatchdog();
    _cancelDeferredAnimeAv1PlaybackError();
    _playerOverlayHideTimer?.cancel();
    unawaited(_pauseSimklScrobble());
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop();
    });
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
      if (_showsDesktopVolumeControl) _playerVolumeButtonFocusNode,
      if (_showsPlayerFullscreenControl) _playerFullscreenButtonFocusNode,
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
    if (!Platform.isAndroid) {
      return;
    }
    final codecs = androidHardwareDecoderCodecs(disableAv1: false);
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
        Platform.isAndroid && _shouldWatchRemoteVideoFrame();
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
        !_shouldWatchRemoteVideoFrame()) {
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
          !_shouldWatchRemoteVideoFrame()) {
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
        _commitCurrentEntryAfterOpen();
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
    await _loadRemoteSubtitleCuesForSelectedTrack(source: 'desktop subtitle');
  }

  Future<void> _loadRemoteSubtitleCuesForSelectedTrack({
    required String source,
  }) async {
    final loadTicket = ++_remoteSubtitleLoadTicket;
    _debugPlayerEvent(
      '$source load requested enabled=$_subtitlesEnabled '
      'tracks=${_currentResolvedStream?.subtitleTracks.length ?? 0} '
      'selected=${_selectedRemoteSubtitleTrackKey.isEmpty ? "default" : _selectedRemoteSubtitleTrackKey}',
    );
    if (!_subtitlesEnabled) {
      if (mounted) {
        setState(() {
          _remoteSubtitleCues = const [];
          _desktopVlcSubtitleCues = const [];
        });
      }
      return;
    }
    _reconcileRemoteSubtitleSelection(_currentResolvedStream);
    final track = selectRemoteSubtitleTrack(
      _currentResolvedStream,
      selectedKey: _selectedRemoteSubtitleTrackKey,
    );
    if (track == null) {
      _debugPlayerEvent('$source: no selected track');
      if (mounted) {
        setState(() {
          _remoteSubtitleCues = const [];
          _desktopVlcSubtitleCues = const [];
        });
      }
      return;
    }
    final trackKey = remoteSubtitleTrackKey(track);
    try {
      _debugPlayerEvent(
        '$source download start '
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
        '$source download HTTP ${response.statusCode} '
        'bytes=${response.bodyBytes.length} cues=${cues.length} '
        'first=${cues.isEmpty ? "none" : _formatPlaybackTime(cues.first.start)} '
        'last=${cues.isEmpty ? "none" : _formatPlaybackTime(cues.last.end)}',
      );
      if (!mounted ||
          loadTicket != _remoteSubtitleLoadTicket ||
          trackKey != _selectedRemoteSubtitleTrackKey) {
        _debugPlayerEvent('$source download discarded stale result');
        return;
      }
      setState(() {
        _remoteSubtitleCues = cues;
        _desktopVlcSubtitleCues = cues;
        _lastDesktopSubtitleCueIndex = -2;
        _status = cues.isEmpty
            ? 'El archivo de subtitulos esta vacio'
            : 'Subtitulos: ${remoteSubtitleTrackLabel(track)}';
      });
    } catch (error) {
      if (!mounted || loadTicket != _remoteSubtitleLoadTicket) return;
      setState(() {
        _remoteSubtitleCues = const [];
        _desktopVlcSubtitleCues = const [];
        _status = 'No se pudo cargar subtitulos';
      });
      _debugPlayerEvent('$source load failed: $error');
    }
  }

  String get _activeRemoteSubtitleCaption {
    if (!_subtitlesEnabled) return '';
    final cues = _remoteSubtitleCues.isNotEmpty
        ? _remoteSubtitleCues
        : _desktopVlcSubtitleCues;
    if (cues.isEmpty) return '';
    final offset = Duration(
      milliseconds: (_subtitleTimingOffsetSeconds * 1000).round(),
    );
    final adjustedPosition = _lastPosition - offset;
    for (final cue in cues) {
      if (adjustedPosition >= cue.start && adjustedPosition < cue.end) {
        return cue.text;
      }
    }
    return '';
  }

  TextStyle get _subtitleOverlayTextStyle {
    return TextStyle(
      color: Colors.white,
      fontSize: 22 * _subtitleFontScale,
      height: 1.25,
      fontWeight: FontWeight.w700,
      shadows: const [
        Shadow(color: Colors.black, blurRadius: 4),
        Shadow(
          color: Colors.black,
          blurRadius: 2,
          offset: Offset(2, 2),
        ),
      ],
    );
  }

  void _logDesktopSubtitleCueAtPosition() {
    final cues = _remoteSubtitleCues.isNotEmpty
        ? _remoteSubtitleCues
        : _desktopVlcSubtitleCues;
    if (cues.isEmpty) return;
    final offset = Duration(
      milliseconds: (_subtitleTimingOffsetSeconds * 1000).round(),
    );
    final adjustedPosition = _lastPosition - offset;
    final index = cues.indexWhere(
      (cue) => adjustedPosition >= cue.start && adjustedPosition < cue.end,
    );
    if (index == _lastDesktopSubtitleCueIndex) return;
    _lastDesktopSubtitleCueIndex = index;
    if (index >= 0) {
      final cue = cues[index];
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
        if (mounted) {
          setState(() => _remoteSubtitleCues = const []);
        }
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
        if (mounted) {
          setState(() => _remoteSubtitleCues = const []);
        }
        return;
      }
      _selectedRemoteSubtitleTrackKey = remoteSubtitleTrackKey(track);
      _debugPlayerEvent(
        'subtitle selected ${remoteSubtitleTrackLabel(track)} '
        'url=${_debugMediaLabel(track.url)}',
      );
      await player.setSubtitleTrack(SubtitleTrack.no());
      await _loadRemoteSubtitleCuesForSelectedTrack(
          source: 'media_kit subtitle');
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
    final tracks = preferredRemoteSubtitleTracks(
      _currentResolvedStream?.subtitleTracks ?? const <RemoteSubtitleTrack>[],
    );
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

  Future<void> _showSubtitleAdjustDialog() async {
    _showPlayerOverlays();
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0xAA000000),
      builder: (context) {
        return _PlayerDialogScale(
          scale: _playerDialogScale,
          child: StatefulBuilder(
            builder: (context, setDialogState) {
              void updateTiming(double delta) {
                final next = ((_subtitleTimingOffsetSeconds + delta) * 10)
                        .roundToDouble() /
                    10;
                setState(() {
                  _subtitleTimingOffsetSeconds = next;
                  _lastDesktopSubtitleCueIndex = -2;
                });
                setDialogState(() {});
              }

              void updateFontScale(double delta) {
                final next =
                    (_subtitleFontScale + delta).clamp(0.6, 2.4).toDouble();
                setState(() => _subtitleFontScale = next);
                setDialogState(() {});
              }

              return Dialog(
                backgroundColor: TanukiColors.panelSolid,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: TanukiColors.panelStroke),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.tune, color: TanukiColors.orange),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Ajustar subtitulos',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Cerrar',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        const _PlayerDialogSectionTitle('Timing'),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            _SubtitleAdjustButton(
                              icon: Icons.remove,
                              tooltip: 'Retrasar 0.1',
                              onPressed: () => updateTiming(-0.1),
                            ),
                            Expanded(
                              child: Text(
                                _subtitleTimingOffsetSeconds.toStringAsFixed(1),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w900,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                            _SubtitleAdjustButton(
                              icon: Icons.add,
                              tooltip: 'Adelantar 0.1',
                              onPressed: () => updateTiming(0.1),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        const _PlayerDialogSectionTitle('Tamano'),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            _SubtitleAdjustButton(
                              icon: Icons.text_decrease,
                              tooltip: 'Disminuir fuente',
                              onPressed: () => updateFontScale(-0.1),
                            ),
                            Expanded(
                              child: Text(
                                '${(_subtitleFontScale * 100).round()}%',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            _SubtitleAdjustButton(
                              icon: Icons.text_increase,
                              tooltip: 'Agrandar fuente',
                              onPressed: () => updateFontScale(0.1),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Center(
                          child: _SubtitleAdjustButton(
                            icon: _isCurrentPlaybackPlaying()
                                ? Icons.pause
                                : Icons.play_arrow,
                            tooltip: _isCurrentPlaybackPlaying()
                                ? 'Pausar'
                                : 'Reproducir',
                            onPressed: () {
                              _toggleCurrentPlayback();
                              if (mounted) {
                                setState(() {});
                                setDialogState(() {});
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  bool _isCurrentPlaybackPlaying() {
    final android = _androidExoController;
    if (android != null && android.value.isInitialized) {
      return android.value.isPlaying;
    }
    final vlcPlayer = _desktopVlcPlayer;
    if (vlcPlayer != null) {
      return _desktopVlcIsPlaying;
    }
    final youtubeController = _youtubeWebController;
    if (youtubeController != null && _usesDesktopYoutubeWebControls) {
      return _youtubeWebPlaying;
    }
    final mediaKit = _player;
    if (mediaKit != null) {
      return mediaKit.state.playing;
    }
    return false;
  }

  Future<void> _cycleVideoScaleMode() async {
    await _setVideoScaleMode(_videoScaleMode.next);
  }

  String _currentSubtitleSelectionLabel() {
    if (!_subtitlesEnabled) {
      return 'Seleccionado: desactivados';
    }
    final track = selectRemoteSubtitleTrack(
      _currentResolvedStream,
      selectedKey: _selectedRemoteSubtitleTrackKey,
    );
    if (track == null) {
      return 'Seleccionado: automatico';
    }
    return 'Seleccionado: ${remoteSubtitleTrackCompactLabel(track)}';
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
    final next = !WindowFullscreenController.isFullscreen;
    try {
      _debugPlayerEvent('desktop fullscreen request enabled=$next');
      await WindowFullscreenController.setFullscreen(next);
      _debugPlayerEvent('desktop fullscreen request accepted enabled=$next');
    } catch (error) {
      _debugPlayerEvent('desktop fullscreen ignored error: $error');
      setState(() {
        _status = 'No se pudo cambiar pantalla completa';
      });
      _showPlayerOverlays();
      return;
    }
    setState(() {
      _status = next ? 'Pantalla completa' : 'Pantalla normal';
    });
    _showPlayerOverlays();
  }

  bool get _canOpenPlayerDialog {
    return !_playerDialogOpen &&
        !_leavingPlayer &&
        DateTime.now().isAfter(_suppressPlayerDialogOpenUntil);
  }

  void _suppressPlayerDialogReopen() {
    if (!mounted) {
      return;
    }
    _suppressPlayerDialogOpenUntil =
        DateTime.now().add(_playerDialogReopenSuppressDelay);
    _suppressNextPlayerActivationKeyUp = true;
    _playerControlsRootFocusNode.requestFocus();
  }

  Future<void> _showEpisodeListPanel() async {
    if (!_canOpenPlayerDialog) {
      return;
    }
    _playerDialogOpen = true;
    _showPlayerOverlays();
    final series = widget.controller.findSeriesForEpisode(widget.episode);
    if (series == null || series.episodes.isEmpty) {
      _playerDialogOpen = false;
      return;
    }
    EpisodeItem? selected;
    try {
      selected = await showDialog<EpisodeItem>(
        context: context,
        barrierColor: const Color(0xAA000000),
        builder: (context) => _PlayerDialogScale(
          scale: _playerDialogScale,
          child: _PlayerEpisodeListDialog(
            series: series,
            current: widget.episode,
            controller: widget.controller,
          ),
        ),
      );
    } finally {
      _playerDialogOpen = false;
      _suppressPlayerDialogReopen();
    }
    final selectedEpisode = selected;
    if (selectedEpisode == null ||
        !mounted ||
        _isSameEpisode(selectedEpisode, widget.episode)) {
      return;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          controller: widget.controller,
          episode: selectedEpisode,
          launchMode: widget.launchMode,
        ),
      ),
    );
  }

  Future<void> _showPlayerSettingsDialog() async {
    if (!_canOpenPlayerDialog) {
      return;
    }
    _playerDialogOpen = true;
    _showPlayerOverlays();
    var preference =
        widget.controller.playbackPreferenceForEpisode(widget.episode);
    final sourceOptionFocusNodes = <RemoteProvider, FocusNode>{
      for (final provider in RemoteProvider.values)
        provider: FocusNode(
          debugLabel: 'player-settings-${provider.id}-first-option',
        ),
    };
    final sourceServerFocusNodes = <RemoteProvider, FocusNode>{
      RemoteProvider.justAnime: FocusNode(
        debugLabel: 'player-settings-justanime-first-server',
      ),
      RemoteProvider.aniPm: FocusNode(
        debugLabel: 'player-settings-anipm-first-server',
      ),
    };
    try {
      await showDialog<void>(
        context: context,
        barrierColor: const Color(0xAA000000),
        builder: (dialogContext) {
          var tab = 0;
          return _PlayerDialogScale(
            scale: _playerDialogScale,
            child: StatefulBuilder(
              builder: (context, setDialogState) {
                final dialogScale = _PlayerDialogScale.of(context);
                final mediaSize = MediaQuery.sizeOf(context);
                final availableDialogWidth = (mediaSize.width - 56)
                    .clamp(240.0, double.infinity)
                    .toDouble();
                final dialogWidth = (430 * dialogScale)
                    .clamp(240.0, availableDialogWidth)
                    .toDouble();
                final maxDialogHeight = mediaSize.height * 0.88;
                final selectedProvider = widget.controller
                    .playbackProviderForEpisode(widget.episode);
                final activeProvider = selectedProvider ??
                    _currentResolvedStream?.provider ??
                    widget.episode.provider;
                final animeAv1Mode =
                    animeAv1PlaybackModeFromId(preference.animeAv1Mode);
                final jkAnimeServer = _currentResolvedStream?.provider ==
                            RemoteProvider.jkAnime &&
                        _currentResolvedStream?.server.trim().isNotEmpty == true
                    ? jkAnimeServerPreferenceFromId(
                        _currentResolvedStream!.server)
                    : jkAnimeServerPreferenceFromId(preference.jkAnimeServer);
                final latAnimeServer = _currentResolvedStream?.provider ==
                            RemoteProvider.latAnime &&
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
                    : justAnimeServerPreferenceFromId(
                        preference.justAnimeServer);
                final aniPmMode = aniPmPlaybackModeFromId(preference.aniPmMode);
                final aniPmServer = preference.aniPmServer.trim().toLowerCase();
                final facebookMode =
                    facebookPlaybackModeFromId(preference.facebookMode);
                final facebookOption =
                    facebookPlaybackOptionFromId(preference.facebookOption);
                final youtubeMode =
                    youtubePlaybackModeFromId(preference.youtubeMode);
                final youtubeOption =
                    youtubePlaybackOptionFromId(preference.youtubeOption);

                Future<void> savePreference(
                    Future<void> Function() save) async {
                  final wasBiliBili = _currentResolvedStream?.provider ==
                      RemoteProvider.bilibili;
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
                    }
                    await _reloadRemoteSource();
                  }
                }

                bool providerHasFocusableSourceOptions(
                  RemoteProvider provider,
                ) {
                  return switch (provider) {
                    RemoteProvider.animeAv1 ||
                    RemoteProvider.jkAnime ||
                    RemoteProvider.latAnime ||
                    RemoteProvider.justAnime ||
                    RemoteProvider.aniPm ||
                    RemoteProvider.facebook ||
                    RemoteProvider.youtube =>
                      true,
                    _ => false,
                  };
                }

                FocusNode? firstSourceOptionFocusNode(
                  RemoteProvider provider,
                  int index,
                ) {
                  return index == 0 ? sourceOptionFocusNodes[provider] : null;
                }

                FocusNode? firstSourceServerFocusNode(
                  RemoteProvider provider,
                  int index,
                ) {
                  return index == 0 ? sourceServerFocusNodes[provider] : null;
                }

                void focusPlayerDialogNode(FocusNode? node) {
                  if (node == null) {
                    return;
                  }
                  node.requestFocus();
                  final optionContext = node.context;
                  if (optionContext == null) {
                    return;
                  }
                  Scrollable.ensureVisible(
                    optionContext,
                    alignment: 0.5,
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOutCubic,
                  );
                }

                void focusFirstSourceOption(RemoteProvider provider) {
                  focusPlayerDialogNode(sourceOptionFocusNodes[provider]);
                }

                void focusFirstSourceServer(RemoteProvider provider) {
                  focusPlayerDialogNode(sourceServerFocusNodes[provider]);
                }

                Widget sourceOptions(RemoteProvider? provider) {
                  if (provider == RemoteProvider.animeAv1) {
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry
                            in AnimeAv1PlaybackMode.values.asMap().entries)
                          _PlayerDialogRadioButton(
                            focusNode: firstSourceOptionFocusNode(
                                RemoteProvider.animeAv1, entry.key),
                            label: entry.value.dialogLabel,
                            active: animeAv1Mode == entry.value,
                            onPressed: () => unawaited(
                              savePreference(
                                () =>
                                    widget.controller.setAnimeAv1ModeForEpisode(
                                  widget.episode,
                                  entry.value,
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
                        for (final entry in availableServers.asMap().entries)
                          _PlayerDialogRadioButton(
                            focusNode: firstSourceOptionFocusNode(
                                RemoteProvider.jkAnime, entry.key),
                            label: entry.value.label,
                            active: jkAnimeServer == entry.value,
                            onPressed: () => unawaited(
                              savePreference(
                                () => widget.controller
                                    .setJkAnimeServerForEpisode(
                                  widget.episode,
                                  entry.value,
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
                        for (final entry
                            in LatAnimeServerPreference.values.asMap().entries)
                          _PlayerDialogRadioButton(
                            focusNode: firstSourceOptionFocusNode(
                                RemoteProvider.latAnime, entry.key),
                            label: entry.value.label,
                            active: latAnimeServer == entry.value,
                            onPressed: () => unawaited(
                              savePreference(
                                () => widget.controller
                                    .setLatAnimeServerForEpisode(
                                  widget.episode,
                                  entry.value,
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
                            for (final entry
                                in JustAnimePlaybackMode.values.asMap().entries)
                              _PlayerDialogRadioButton(
                                focusNode: firstSourceOptionFocusNode(
                                    RemoteProvider.justAnime, entry.key),
                                label: entry.value.buttonLabel,
                                active: justAnimeMode == entry.value,
                                onArrowDown: () => focusFirstSourceServer(
                                  RemoteProvider.justAnime,
                                ),
                                onPressed: () => unawaited(savePreference(
                                  () => widget.controller
                                      .setJustAnimeModeForEpisode(
                                          widget.episode, entry.value),
                                )),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const _PlayerDialogSectionTitle('Servidor'),
                        const SizedBox(height: 8),
                        _PlayerDialogScrollableRadioColumn(
                          children: [
                            for (final entry in JustAnimeServerPreference.values
                                .asMap()
                                .entries)
                              _PlayerDialogRadioButton(
                                focusNode: firstSourceServerFocusNode(
                                  RemoteProvider.justAnime,
                                  entry.key,
                                ),
                                label: entry.value.label,
                                active: justAnimeServer == entry.value,
                                onPressed: () => unawaited(savePreference(
                                  () => widget.controller
                                      .setJustAnimeServerForEpisode(
                                    widget.episode,
                                    entry.value,
                                  ),
                                )),
                              ),
                          ],
                        ),
                      ],
                    );
                  }
                  if (provider == RemoteProvider.aniPm) {
                    final resolvedServers =
                        _remoteServerOptionsFor(RemoteProvider.aniPm).toList();
                    resolvedServers.sort(compareAniPmServerMenuOrder);
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
                            for (final entry
                                in AniPmPlaybackMode.values.asMap().entries)
                              _PlayerDialogRadioButton(
                                focusNode: firstSourceOptionFocusNode(
                                    RemoteProvider.aniPm, entry.key),
                                label: entry.value.buttonLabel,
                                active: aniPmMode == entry.value,
                                onArrowDown: () => focusFirstSourceServer(
                                  RemoteProvider.aniPm,
                                ),
                                onPressed: () => unawaited(savePreference(
                                  () => widget.controller
                                      .setAniPmModeForEpisode(
                                          widget.episode, entry.value),
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
                              focusNode: firstSourceServerFocusNode(
                                RemoteProvider.aniPm,
                                0,
                              ),
                              label: 'Automatico',
                              active: aniPmServer.isEmpty,
                              onPressed: () => unawaited(savePreference(
                                () => widget.controller
                                    .setAniPmServerForEpisode(
                                        widget.episode, ''),
                              )),
                            ),
                            for (final server in servers)
                              _PlayerDialogRadioButton(
                                label: remoteServerLabel(server),
                                active: aniPmServer == server,
                                onPressed: () => unawaited(savePreference(
                                  () => widget.controller
                                      .setAniPmServerForEpisode(
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
                            for (final entry
                                in FacebookPlaybackMode.values.asMap().entries)
                              _PlayerDialogRadioButton(
                                focusNode: firstSourceOptionFocusNode(
                                    RemoteProvider.facebook, entry.key),
                                label: entry.value.dialogLabel,
                                active: facebookMode == entry.value,
                                onPressed: () => unawaited(
                                  savePreference(
                                    () => widget.controller
                                        .setFacebookModeForEpisode(
                                      widget.episode,
                                      entry.value,
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
                            for (final entry
                                in YoutubePlaybackMode.values.asMap().entries)
                              _PlayerDialogRadioButton(
                                focusNode: firstSourceOptionFocusNode(
                                    RemoteProvider.youtube, entry.key),
                                label: entry.value.buttonLabel,
                                active: youtubeMode == entry.value,
                                onPressed: () => unawaited(
                                  savePreference(
                                    () => widget.controller
                                        .setYoutubeModeForEpisode(
                                      widget.episode,
                                      entry.value,
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
                    width: dialogWidth,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: maxDialogHeight),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(14 * dialogScale),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.tune,
                                  color: TanukiColors.orange,
                                  size: 24 * dialogScale,
                                ),
                                SizedBox(width: 10 * dialogScale),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Player Settings',
                                        style: TextStyle(
                                          color: TanukiColors.text,
                                          fontSize: 14 * dialogScale,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      Text(
                                        'Ajusta player y fuentes',
                                        style: TextStyle(
                                          color: TanukiColors.muted,
                                          fontSize: 12 * dialogScale,
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
                                    onPressed: () =>
                                        setDialogState(() => tab = 0),
                                  ),
                                ),
                                Expanded(
                                  child: _PlayerSettingsTabButton(
                                    icon: Icons.cloud,
                                    label: 'Fuentes',
                                    active: tab == 1,
                                    onPressed: () =>
                                        setDialogState(() => tab = 1),
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
                                        active: _videoScaleMode ==
                                            VideoScaleMode.fit,
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
                                        active: _videoScaleMode ==
                                            VideoScaleMode.stretch,
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
                                  const SizedBox(height: 8),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: _PlayerDialogButton(
                                      label: _currentSubtitleSelectionLabel(),
                                      active: false,
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                        Future<void>.delayed(
                                          const Duration(milliseconds: 120),
                                          _showSubtitleTrackDialog,
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: _PlayerDialogButton(
                                      label: 'Ajustar',
                                      active: false,
                                      onPressed: () {
                                        Navigator.of(dialogContext).pop();
                                        Future<void>.delayed(
                                          const Duration(milliseconds: 120),
                                          _showSubtitleAdjustDialog,
                                        );
                                      },
                                    ),
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
                                      onArrowDown: activeProvider == provider &&
                                              providerHasFocusableSourceOptions(
                                                provider,
                                              )
                                          ? () =>
                                              focusFirstSourceOption(provider)
                                          : null,
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
                                        padding:
                                            const EdgeInsets.only(left: 10),
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
                  ),
                );
              },
            ),
          );
        },
      );
    } finally {
      for (final node in sourceOptionFocusNodes.values) {
        node.dispose();
      }
      for (final node in sourceServerFocusNodes.values) {
        node.dispose();
      }
      _playerDialogOpen = false;
      _suppressPlayerDialogReopen();
    }
  }

  List<JkAnimeServerPreference> _availableJkAnimeServers() {
    final discovered = _remoteServerOptionsFor(RemoteProvider.jkAnime);
    if (discovered.isEmpty) {
      return JkAnimeServerPreference.values;
    }
    final servers = JkAnimeServerPreference.values
        .where((server) => discovered.contains(server.id))
        .toList(growable: false);
    return servers.isEmpty ? JkAnimeServerPreference.values : servers;
  }

  void _rememberRemoteServerOptions(RemoteDirectStream stream) {
    final provider = stream.provider;
    if (provider == null) {
      return;
    }
    final servers = <String>{
      ...stream.availableModes.map((server) => server.trim().toLowerCase()),
      ...stream.availableServers.map((server) => server.trim().toLowerCase()),
      if (stream.server.trim().isNotEmpty) stream.server.trim().toLowerCase(),
    }..removeWhere((server) => server.isEmpty);
    if (servers.isEmpty) {
      return;
    }
    _remoteServerOptionCache.update(
      provider,
      (existing) => <String>{...existing, ...servers},
      ifAbsent: () => servers,
    );
  }

  Set<String> _remoteServerOptionsFor(RemoteProvider provider) {
    final servers = <String>{
      ...?_remoteServerOptionCache[provider],
    };
    final stream = _currentResolvedStream;
    if (stream?.provider == provider) {
      servers
        ..addAll(
            stream!.availableModes.map((server) => server.trim().toLowerCase()))
        ..addAll(stream.availableServers
            .map((server) => server.trim().toLowerCase()));
      final selected = stream.server.trim().toLowerCase();
      if (selected.isNotEmpty) {
        servers.add(selected);
      }
    }
    servers.removeWhere((server) => server.isEmpty);
    return servers;
  }

  Future<void> _playPrevious() async {
    final replacement = _adjacentEpisode(-1);
    if (replacement == null) {
      return;
    }
    await _replaceWithEpisode(replacement);
  }

  Future<void> _playNext() async {
    if (_episodeTransitionInProgress || _leavingPlayer) {
      return;
    }
    final seriesNext = _seriesEntriesAfterCurrent(limit: 1);
    final replacement = widget.launchMode == PlayerLaunchMode.playlist ||
            widget.launchMode == PlayerLaunchMode.detail
        ? _adjacentEpisode(1)
        : widget.launchMode == PlayerLaunchMode.continueWatchingRoundRobin ||
                seriesNext.isEmpty
            ? null
            : seriesNext.first;
    if (replacement == null ||
        (widget.launchMode == PlayerLaunchMode.detail &&
            _episodeAirsInFuture(replacement.airDateIso))) {
      if (widget.launchMode == PlayerLaunchMode.detail) {
        _exitPlayer();
        return;
      }
      final entries = widget.launchMode == PlayerLaunchMode.playlist
          ? _playlistEntriesAfterCurrent(limit: 1)
          : widget.launchMode == PlayerLaunchMode.continueWatching ||
                  widget.launchMode ==
                      PlayerLaunchMode.continueWatchingRoundRobin
              ? _continueWatchingEntriesAfterCurrent(
                  limit: 1,
                  preferSameSeries: widget.launchMode !=
                      PlayerLaunchMode.continueWatchingRoundRobin,
                )
              : const <EpisodeItem>[];
      if (entries.isEmpty) {
        if (widget.launchMode == PlayerLaunchMode.continueWatching ||
            widget.launchMode == PlayerLaunchMode.continueWatchingRoundRobin) {
          _exitPlayer();
        }
        return;
      }
      await _replaceWithEpisode(entries.first);
      return;
    }
    await _replaceWithEpisode(replacement);
  }

  Future<void> _replaceWithEpisode(EpisodeItem episode) async {
    if (_episodeTransitionInProgress || _leavingPlayer || !mounted) {
      return;
    }
    _episodeTransitionInProgress = true;
    ++_openEpisodeTicket;
    _cancelRemoteVideoFrameWatchdog();
    _cancelDeferredAnimeAv1PlaybackError();
    _playerOverlayHideTimer?.cancel();
    final EpisodeItem nextEpisode;
    try {
      nextEpisode = await _prepareEpisodeForPlayback(episode);
    } catch (error) {
      _episodeTransitionInProgress = false;
      if (mounted) {
        setState(() {
          _status = 'No se pudo preparar el episodio';
          _error = '$error';
        });
      }
      return;
    }
    if (!mounted || _leavingPlayer) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          controller: widget.controller,
          episode: nextEpisode,
          launchMode: widget.launchMode,
        ),
      ),
    );
  }

  Future<EpisodeItem> _prepareEpisodeForPlayback(EpisodeItem episode) async {
    final series = widget.controller.findSeriesForEpisode(episode);
    if (series == null) {
      return episode;
    }
    final current = _matchingEpisodeInSeries(series, episode);
    if (_episodeHasPlaybackRoute(current)) {
      _refreshSeriesVisualsInBackground(series);
      return current;
    }
    final refreshed =
        await widget.controller.refreshRemoteSeriesVisuals(series);
    return _matchingEpisodeInSeries(refreshed, episode);
  }

  bool _episodeHasPlaybackRoute(EpisodeItem episode) {
    if (episode.filePath.trim().isNotEmpty) {
      return true;
    }
    if (!episode.isRemote) {
      return false;
    }
    return episode.watchUrl.trim().isNotEmpty ||
        episode.slug.trim().isNotEmpty ||
        episode.provider != null;
  }

  void _refreshSeriesVisualsInBackground(SeriesItem series) {
    unawaited(() async {
      try {
        await widget.controller.refreshRemoteSeriesVisuals(series);
      } catch (error) {
        _debugPlayerEvent('background visual refresh ignored: $error');
      }
    }());
  }

  EpisodeItem _matchingEpisodeInSeries(SeriesItem series, EpisodeItem episode) {
    for (final candidate in series.episodes) {
      if (episode.episodeNumber > 0 &&
          candidate.episodeNumber == episode.episodeNumber) {
        return candidate;
      }
    }
    for (final candidate in series.episodes) {
      if (candidate.episodeIndex == episode.episodeIndex) {
        return candidate;
      }
    }
    return episode;
  }

  EpisodeItem? _adjacentEpisode(int offset) {
    final series = widget.controller.findSeriesForEpisode(widget.episode);
    if (series == null) {
      return null;
    }
    final episodes = [...series.episodes]..sort(
        (left, right) => left.episodeIndex.compareTo(right.episodeIndex),
      );
    final currentIndex = episodes.indexWhere(
      (entry) => _isSameEpisode(entry, widget.episode),
    );
    if (currentIndex < 0) {
      return null;
    }
    final index = currentIndex + offset;
    if (index < 0 || index >= episodes.length) {
      return null;
    }
    return episodes[index];
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
  required double initialVolume,
}) {
  final jsVideoId = jsonEncode(videoId);
  final jsTitle = jsonEncode(title.trim().isEmpty ? 'Episodio' : title.trim());
  final jsSourceLabel = jsonEncode(
    sourceLabel.trim().isEmpty ? 'YouTube' : sourceLabel.trim(),
  );
  final jsDesktopControls = desktopControls ? 'true' : 'false';
  final startSeconds = max(0, startPosition.inSeconds);
  final initialYoutubeVolume =
      (initialVolume.clamp(0.0, 1.0) * _youtubeMaxVolume).round();
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
    #volumePanel {
      width: 0;
      height: 42px;
      overflow: hidden;
      transition: width 160ms ease;
    }
    body.volume-open #volumePanel {
      width: 148px;
    }
    #volumeSlider {
      width: 140px;
      height: 42px;
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
    <button id="volume" class="icon-button" title="Volumen" aria-label="Volumen">
      <svg id="volumeIcon" viewBox="0 0 24 24"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05A4.5 4.5 0 0 0 16.5 12z"></path></svg>
    </button>
    <div id="volumePanel">
      <input id="volumeSlider" type="range" min="0" max="100" step="1" value="$initialYoutubeVolume" aria-label="Volumen">
    </div>
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
    const volumeIcon = document.getElementById('volumeIcon');
    const volumeSlider = document.getElementById('volumeSlider');
    const progress = document.getElementById('progress');
    const timeLabel = document.getElementById('time');
    let currentVolume = $initialYoutubeVolume;
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
      volumeIcon.innerHTML = currentVolume <= 0
        ? '<path d="M16.5 12 21 16.5 19.5 18 15 13.5 10.5 18 9 16.5 13.5 12 9 7.5 10.5 6 15 10.5 19.5 6 21 7.5 16.5 12zM3 9v6h4l5 5V4L7 9H3z"></path>'
        : currentVolume < 55
          ? '<path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05A4.5 4.5 0 0 0 16.5 12z"></path>'
          : '<path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05A4.5 4.5 0 0 0 16.5 12zm2.5 0a7 7 0 0 1-4 6.32v-2.23a5 5 0 0 0 0-9.18V5.68A7 7 0 0 1 19 12z"></path>';
    }
    function tanukiSetVolume(value) {
      currentVolume = Math.max(0, Math.min(100, Math.round(Number(value) || 0)));
      volumeSlider.value = String(currentVolume);
      try { if (player) player.setVolume(currentVolume); } catch (error) {}
      try {
        if (player && currentVolume > 0) player.unMute();
        if (player && currentVolume <= 0) player.mute();
      } catch (error) {}
      renderChrome();
    }
    function playWhenReady() {
      if (!player) return;
      try { player.unMute(); } catch (error) {}
      try { player.setVolume(currentVolume); } catch (error) {}
      [0, 250, 900, 1800].forEach(function(delay) {
        window.setTimeout(function() {
          try { player.unMute(); } catch (error) {}
          try { player.setVolume(currentVolume); } catch (error) {}
          try { player.playVideo(); } catch (error) {}
        }, delay);
      });
    }
    function tanukiPlay() {
      try { if (player) player.unMute(); } catch (error) {}
      try { if (player) player.setVolume(currentVolume); } catch (error) {}
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
      document.getElementById('volume').addEventListener('click', function() {
        document.body.classList.toggle('volume-open');
      });
      volumeSlider.addEventListener('input', function() {
        tanukiSetVolume(Number(volumeSlider.value) || 0);
      });
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
      document.addEventListener('keydown', function(event) {
        if (event.key === 'F11') {
          event.preventDefault();
          event.stopPropagation();
          postCommand('fullscreen');
        }
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
            try { player.setVolume(currentVolume); } catch (error) {}
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
    final scale = _PlayerDialogScale.of(context);
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        color: TanukiColors.amber,
        fontSize: 12 * scale,
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
    required this.controlScale,
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
  final double controlScale;
  final FocusNode? playButtonFocusNode;
  final FocusNode? progressFocusNode;

  @override
  State<_YoutubeWebControls> createState() => _YoutubeWebControlsState();
}

class _YoutubeWebControlsState extends State<_YoutubeWebControls> {
  double? _dragPositionMs;
  Timer? _keyboardSeekTimer;
  Duration? _pendingKeyboardSeek;
  LogicalKeyboardKey? _keyboardSeekKey;
  int _keyboardSeekRepeatCount = 0;

  KeyEventResult _handleProgressKey(
      Duration position, Duration duration, FocusNode node, KeyEvent event) {
    if (!isPlayerProgressSeekKeyEvent(event)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (!isPlayerProgressSeekKey(key)) {
      return KeyEventResult.ignored;
    }
    final direction = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
    final continuingSeek =
        _pendingKeyboardSeek != null && _keyboardSeekKey == key;
    if (!continuingSeek) {
      _keyboardSeekKey = key;
      _keyboardSeekRepeatCount = 0;
    } else {
      _keyboardSeekRepeatCount += 1;
    }
    final step = playerProgressKeyboardSeekStep(
      repeatCount: _keyboardSeekRepeatCount,
    );
    final basePosition = _pendingKeyboardSeek ??
        (_dragPositionMs == null
            ? position
            : Duration(milliseconds: _dragPositionMs!.round()));
    final target = basePosition + step * direction;
    final clamped = clampPlayerProgressSeekTarget(
      target,
      duration,
    );
    setState(() {
      _dragPositionMs = clamped.inMilliseconds.toDouble();
    });
    _scheduleKeyboardSeek(clamped);
    return KeyEventResult.handled;
  }

  void _scheduleKeyboardSeek(Duration target) {
    _pendingKeyboardSeek = target;
    _keyboardSeekTimer?.cancel();
    _keyboardSeekTimer = Timer(_playerProgressKeyboardSeekCommitDelay, () {
      final pending = _pendingKeyboardSeek;
      _pendingKeyboardSeek = null;
      _keyboardSeekKey = null;
      _keyboardSeekRepeatCount = 0;
      if (pending == null) {
        return;
      }
      unawaited(widget.onSeek(pending).whenComplete(() {
        if (mounted && _pendingKeyboardSeek == null) {
          setState(() {
            _dragPositionMs = null;
          });
        }
      }));
    });
  }

  @override
  void dispose() {
    _keyboardSeekTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.duration.inMilliseconds.clamp(1, 1 << 53);
    final currentMs = _dragPositionMs ??
        widget.position.inMilliseconds.clamp(0, durationMs).toDouble();
    final scale = widget.controlScale;
    final timeTextStyle = TextStyle(
      color: TanukiColors.text,
      fontSize: 14 * scale,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final durationTextStyle = timeTextStyle.copyWith(
      color: TanukiColors.muted,
    );
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Focus(
        onFocusChange: widget.onFocusChanged,
        child: SizedBox(
          height: 56 * scale,
          child: Row(
            children: [
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: _PlayerIconButton(
                  icon: widget.isPlaying ? Icons.pause : Icons.play_arrow,
                  focusNode: widget.playButtonFocusNode,
                  tooltip: widget.isPlaying ? 'Pausar' : 'Reproducir',
                  onPressed: () => unawaited(widget.onTogglePlayback()),
                  onFocusChanged: widget.onFocusChanged,
                  controlScale: scale,
                ),
              ),
              SizedBox(
                width: 72 * scale,
                child: Text(
                  widget.formatTime(
                    Duration(milliseconds: currentMs.round()),
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: timeTextStyle,
                ),
              ),
              Expanded(
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: _PlayerProgressFocusFrame(
                    focusNode: widget.progressFocusNode,
                    onFocusChanged: widget.onFocusChanged,
                    onKeyEvent: (node, event) => _handleProgressKey(
                      Duration(milliseconds: currentMs.round()),
                      widget.duration,
                      node,
                      event,
                    ),
                    builder: (progressFocused) => SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: TanukiColors.orange,
                        inactiveTrackColor: const Color(0x668A939E),
                        thumbColor: Colors.white,
                        overlayColor: progressFocused
                            ? const Color(0x55F0B760)
                            : const Color(0x33F0B760),
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius:
                              (progressFocused ? 14 : 6) * scale,
                        ),
                        overlayShape: RoundSliderOverlayShape(
                          overlayRadius: (progressFocused ? 26 : 13) * scale,
                        ),
                        trackHeight: 2 * scale,
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
                          _keyboardSeekTimer?.cancel();
                          _pendingKeyboardSeek = null;
                          _keyboardSeekKey = null;
                          _keyboardSeekRepeatCount = 0;
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
                width: 72 * scale,
                child: Text(
                  widget.formatTime(widget.duration),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: durationTextStyle,
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

class _SubtitleAdjustButton extends StatelessWidget {
  const _SubtitleAdjustButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 58,
        height: 52,
        child: FilledButton(
          style: ButtonStyle(
            padding: WidgetStateProperty.all(EdgeInsets.zero),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return TanukiColors.orangeHot;
              }
              if (states.contains(WidgetState.pressed)) {
                return TanukiColors.orange;
              }
              return TanukiColors.orange.withValues(alpha: .78);
            }),
            foregroundColor: WidgetStateProperty.all(Colors.black),
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return const BorderSide(color: Colors.white, width: 3);
              }
              return BorderSide(
                color: Colors.black.withValues(alpha: .24),
                width: 1,
              );
            }),
            elevation: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.focused) ? 12 : 3;
            }),
            shadowColor: WidgetStateProperty.all(
              TanukiColors.orangeHot.withValues(alpha: .65),
            ),
            shape: WidgetStateProperty.all(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          onPressed: onPressed,
          child: Icon(icon, size: 26),
        ),
      ),
    );
  }
}

class _AnimeSkipPrompt extends StatelessWidget {
  const _AnimeSkipPrompt({
    super.key,
    required this.label,
    required this.focusNode,
    required this.onPressed,
  });

  final String label;
  final FocusNode focusNode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Focus(
        focusNode: focusNode,
        child: Builder(
          builder: (context) {
            final focused = Focus.of(context).hasFocus;
            return AnimatedScale(
              scale: focused ? 1.06 : 1,
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOutCubic,
              child: FilledButton.icon(
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  backgroundColor:
                      TanukiColors.orange.withValues(alpha: focused ? .88 : .7),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: Colors.black.withValues(alpha: focused ? .42 : .2),
                      width: focused ? 2 : 1,
                    ),
                  ),
                  elevation: focused ? 8 : 2,
                ),
                icon: const Icon(Icons.skip_next, size: 20),
                label: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            );
          },
        ),
      ),
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
    required this.controlScale,
    this.playButtonFocusNode,
    this.progressFocusNode,
  });

  final vp.VideoPlayerController controller;
  final Future<void> Function() onTogglePlayback;
  final Future<void> Function(Duration target) onSeek;
  final String Function(Duration duration) formatTime;
  final ValueChanged<bool> onFocusChanged;
  final double controlScale;
  final FocusNode? playButtonFocusNode;
  final FocusNode? progressFocusNode;

  @override
  State<_AndroidExoControls> createState() => _AndroidExoControlsState();
}

class _AndroidExoControlsState extends State<_AndroidExoControls> {
  double? _dragPositionMs;
  Timer? _keyboardSeekTimer;
  Duration? _pendingKeyboardSeek;
  LogicalKeyboardKey? _keyboardSeekKey;
  int _keyboardSeekRepeatCount = 0;

  KeyEventResult _handleProgressKey(
      Duration position, Duration duration, FocusNode node, KeyEvent event) {
    if (!isPlayerProgressSeekKeyEvent(event)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (!isPlayerProgressSeekKey(key)) {
      return KeyEventResult.ignored;
    }
    final direction = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
    final continuingSeek =
        _pendingKeyboardSeek != null && _keyboardSeekKey == key;
    if (!continuingSeek) {
      _keyboardSeekKey = key;
      _keyboardSeekRepeatCount = 0;
    } else {
      _keyboardSeekRepeatCount += 1;
    }
    final step = playerProgressKeyboardSeekStep(
      repeatCount: _keyboardSeekRepeatCount,
    );
    final basePosition = _pendingKeyboardSeek ??
        (_dragPositionMs == null
            ? position
            : Duration(milliseconds: _dragPositionMs!.round()));
    final target = basePosition + step * direction;
    final clamped = clampPlayerProgressSeekTarget(
      target,
      duration,
    );
    setState(() {
      _dragPositionMs = clamped.inMilliseconds.toDouble();
    });
    _scheduleKeyboardSeek(clamped);
    return KeyEventResult.handled;
  }

  void _scheduleKeyboardSeek(Duration target) {
    _pendingKeyboardSeek = target;
    _keyboardSeekTimer?.cancel();
    _keyboardSeekTimer = Timer(_playerProgressKeyboardSeekCommitDelay, () {
      final pending = _pendingKeyboardSeek;
      _pendingKeyboardSeek = null;
      _keyboardSeekKey = null;
      _keyboardSeekRepeatCount = 0;
      if (pending == null) {
        return;
      }
      unawaited(widget.onSeek(pending).whenComplete(() {
        if (mounted && _pendingKeyboardSeek == null) {
          setState(() {
            _dragPositionMs = null;
          });
        }
      }));
    });
  }

  @override
  void dispose() {
    _keyboardSeekTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.controller.value;
    final durationMs = value.duration.inMilliseconds.clamp(1, 1 << 53);
    final currentMs = _dragPositionMs ??
        value.position.inMilliseconds.clamp(0, durationMs).toDouble();
    final scale = widget.controlScale;
    final timeTextStyle = TextStyle(
      color: TanukiColors.text,
      fontSize: 14 * scale,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final durationTextStyle = timeTextStyle.copyWith(
      color: TanukiColors.muted,
    );
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Focus(
        onFocusChange: widget.onFocusChanged,
        child: SizedBox(
          height: 56 * scale,
          child: Row(
            children: [
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: _PlayerIconButton(
                  icon: value.isPlaying ? Icons.pause : Icons.play_arrow,
                  focusNode: widget.playButtonFocusNode,
                  tooltip: value.isPlaying ? 'Pausar' : 'Reproducir',
                  onPressed: () => unawaited(widget.onTogglePlayback()),
                  onFocusChanged: widget.onFocusChanged,
                  controlScale: scale,
                ),
              ),
              SizedBox(
                width: 72 * scale,
                child: Text(
                  widget.formatTime(
                    Duration(milliseconds: currentMs.round()),
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: timeTextStyle,
                ),
              ),
              Expanded(
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: _PlayerProgressFocusFrame(
                    focusNode: widget.progressFocusNode,
                    onFocusChanged: widget.onFocusChanged,
                    onKeyEvent: (node, event) => _handleProgressKey(
                      Duration(milliseconds: currentMs.round()),
                      value.duration,
                      node,
                      event,
                    ),
                    builder: (progressFocused) => SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: TanukiColors.orange,
                        inactiveTrackColor: const Color(0x668A939E),
                        thumbColor: Colors.white,
                        overlayColor: progressFocused
                            ? const Color(0x55F0B760)
                            : const Color(0x33F0B760),
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius:
                              (progressFocused ? 14 : 6) * scale,
                        ),
                        overlayShape: RoundSliderOverlayShape(
                          overlayRadius: (progressFocused ? 26 : 13) * scale,
                        ),
                        trackHeight: 2 * scale,
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
                          _keyboardSeekTimer?.cancel();
                          _pendingKeyboardSeek = null;
                          _keyboardSeekKey = null;
                          _keyboardSeekRepeatCount = 0;
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
                width: 72 * scale,
                child: Text(
                  widget.formatTime(value.duration),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: durationTextStyle,
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
    required this.controlScale,
    this.playButtonFocusNode,
    this.progressFocusNode,
  });

  final vlc.Player player;
  final Future<void> Function() onTogglePlayback;
  final Future<void> Function(Duration target) onSeek;
  final String Function(Duration duration) formatTime;
  final ValueChanged<bool> onFocusChanged;
  final double controlScale;
  final FocusNode? playButtonFocusNode;
  final FocusNode? progressFocusNode;

  @override
  State<_DesktopVlcControls> createState() => _DesktopVlcControlsState();
}

class _DesktopVlcControlsState extends State<_DesktopVlcControls> {
  StreamSubscription<vlc.PositionState>? _positionSubscription;
  StreamSubscription<vlc.PlaybackState>? _playbackSubscription;
  double? _dragPositionMs;
  Timer? _keyboardSeekTimer;
  Duration? _pendingKeyboardSeek;
  LogicalKeyboardKey? _keyboardSeekKey;
  int _keyboardSeekRepeatCount = 0;
  DateTime _lastUiRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  KeyEventResult _handleProgressKey(
      Duration position, Duration duration, FocusNode node, KeyEvent event) {
    if (!isPlayerProgressSeekKeyEvent(event)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (!isPlayerProgressSeekKey(key)) {
      return KeyEventResult.ignored;
    }
    final direction = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
    final continuingSeek =
        _pendingKeyboardSeek != null && _keyboardSeekKey == key;
    if (!continuingSeek) {
      _keyboardSeekKey = key;
      _keyboardSeekRepeatCount = 0;
    } else {
      _keyboardSeekRepeatCount += 1;
    }
    final step = playerProgressKeyboardSeekStep(
      repeatCount: _keyboardSeekRepeatCount,
    );
    final basePosition = _pendingKeyboardSeek ??
        (_dragPositionMs == null
            ? position
            : Duration(milliseconds: _dragPositionMs!.round()));
    final target = basePosition + step * direction;
    final clamped = clampPlayerProgressSeekTarget(
      target,
      duration,
    );
    setState(() {
      _dragPositionMs = clamped.inMilliseconds.toDouble();
    });
    _scheduleKeyboardSeek(clamped);
    return KeyEventResult.handled;
  }

  void _scheduleKeyboardSeek(Duration target) {
    _pendingKeyboardSeek = target;
    _keyboardSeekTimer?.cancel();
    _keyboardSeekTimer = Timer(_playerProgressKeyboardSeekCommitDelay, () {
      final pending = _pendingKeyboardSeek;
      _pendingKeyboardSeek = null;
      _keyboardSeekKey = null;
      _keyboardSeekRepeatCount = 0;
      if (pending == null) {
        return;
      }
      unawaited(widget.onSeek(pending).whenComplete(() {
        if (mounted && _pendingKeyboardSeek == null) {
          setState(() {
            _dragPositionMs = null;
          });
        }
      }));
    });
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
      if (!mounted || _dragPositionMs != null) {
        return;
      }
      final now = DateTime.now();
      if (now.difference(_lastUiRefresh) < const Duration(milliseconds: 250)) {
        return;
      }
      _lastUiRefresh = now;
      setState(() {});
    });
    _playbackSubscription = widget.player.playbackStream.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _keyboardSeekTimer?.cancel();
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
    final scale = widget.controlScale;
    final timeTextStyle = TextStyle(
      color: TanukiColors.text,
      fontSize: 14 * scale,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final durationTextStyle = timeTextStyle.copyWith(
      color: TanukiColors.muted,
    );
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Focus(
        onFocusChange: widget.onFocusChanged,
        child: SizedBox(
          height: 56 * scale,
          child: Row(
            children: [
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: _PlayerIconButton(
                  icon: isPlaying ? Icons.pause : Icons.play_arrow,
                  focusNode: widget.playButtonFocusNode,
                  tooltip: isPlaying ? 'Pausar' : 'Reproducir',
                  onPressed: () => unawaited(widget.onTogglePlayback()),
                  onFocusChanged: widget.onFocusChanged,
                  controlScale: scale,
                ),
              ),
              SizedBox(
                width: 72 * scale,
                child: Text(
                  widget.formatTime(
                    Duration(milliseconds: currentMs.round()),
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: timeTextStyle,
                ),
              ),
              Expanded(
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(2),
                  child: _PlayerProgressFocusFrame(
                    focusNode: widget.progressFocusNode,
                    onFocusChanged: widget.onFocusChanged,
                    onKeyEvent: (node, event) => _handleProgressKey(
                      Duration(milliseconds: currentMs.round()),
                      duration,
                      node,
                      event,
                    ),
                    builder: (progressFocused) => SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: TanukiColors.orange,
                        inactiveTrackColor: const Color(0x668A939E),
                        thumbColor: Colors.white,
                        overlayColor: progressFocused
                            ? const Color(0x55F0B760)
                            : const Color(0x33F0B760),
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius:
                              (progressFocused ? 14 : 6) * scale,
                        ),
                        overlayShape: RoundSliderOverlayShape(
                          overlayRadius: (progressFocused ? 26 : 13) * scale,
                        ),
                        trackHeight: 2 * scale,
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
                          _keyboardSeekTimer?.cancel();
                          _pendingKeyboardSeek = null;
                          _keyboardSeekKey = null;
                          _keyboardSeekRepeatCount = 0;
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
                width: 72 * scale,
                child: Text(
                  widget.formatTime(duration),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: durationTextStyle,
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
    final scale = _PlayerDialogScale.of(context);
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 17 * scale),
      label: Text(
        label,
        style: TextStyle(fontSize: 14 * scale, fontWeight: FontWeight.w800),
      ),
      style: TextButton.styleFrom(
        foregroundColor: active ? TanukiColors.orange : TanukiColors.muted,
        backgroundColor: active ? const Color(0x332A170B) : Colors.transparent,
        padding: EdgeInsets.symmetric(
          horizontal: 12 * scale,
          vertical: 8 * scale,
        ),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6 * scale)),
      ),
    );
  }
}

class _PlayerDialogScale extends InheritedWidget {
  const _PlayerDialogScale({
    required this.scale,
    required super.child,
  });

  final double scale;

  static double of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<_PlayerDialogScale>()
            ?.scale ??
        1.0;
  }

  @override
  bool updateShouldNotify(_PlayerDialogScale oldWidget) {
    return scale != oldWidget.scale;
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
    final scale = _PlayerDialogScale.of(context);
    final mediaSize = MediaQuery.sizeOf(context);
    final availableDialogWidth =
        (mediaSize.width - 56).clamp(240.0, double.infinity).toDouble();
    final dialogWidth =
        (430 * scale).clamp(240.0, availableDialogWidth).toDouble();
    final dialogHeight = mediaSize.height * 0.72;
    return Dialog(
      alignment: Alignment.centerRight,
      insetPadding: const EdgeInsets.only(right: 28),
      backgroundColor: const Color(0xF2131518),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0x44F28C28)),
      ),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                14 * scale,
                12 * scale,
                8 * scale,
                10 * scale,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.view_list,
                    color: TanukiColors.orange,
                    size: 24 * scale,
                  ),
                  SizedBox(width: 10 * scale),
                  Expanded(
                    child: Text(
                      series.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: TanukiColors.text,
                        fontSize: 14 * scale,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, size: 24 * scale),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.all(12 * scale),
                itemCount: series.episodes.length,
                itemBuilder: (context, index) {
                  final episode = series.episodes[index];
                  final active = episode.episodeIndex == current.episodeIndex;
                  final playback = controller.playbackForEpisode(episode);
                  final progress = playback == null || playback.durationMs <= 0
                      ? 0.0
                      : playback.positionMs / playback.durationMs;
                  final futureEpisode =
                      _episodeAirsInFuture(episode.airDateIso);
                  final enabled =
                      !futureEpisode && _dialogEpisodeHasPlaybackRoute(episode);
                  return _PlayerEpisodeListCard(
                    episode: episode,
                    active: active,
                    enabled: enabled,
                    progress: progress,
                    scheduleLabel:
                        futureEpisode ? _episodeScheduleLabel(episode) : '',
                    onTap: enabled
                        ? () => Navigator.of(context).pop(episode)
                        : null,
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

class _PlayerEpisodeListCard extends StatelessWidget {
  const _PlayerEpisodeListCard({
    required this.episode,
    required this.active,
    required this.enabled,
    required this.progress,
    required this.scheduleLabel,
    required this.onTap,
  });

  final EpisodeItem episode;
  final bool active;
  final bool enabled;
  final double progress;
  final String scheduleLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scale = _PlayerDialogScale.of(context);
    final episodeTitle = episode.displayName.trim();
    final title = episodeTitle.isEmpty
        ? 'Episodio ${episode.episodeNumber}'
        : '${episode.episodeNumber}. $episodeTitle';
    return Padding(
      padding: EdgeInsets.only(bottom: 10 * scale),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.48,
          child: Container(
            height: 108 * scale,
            decoration: BoxDecoration(
              color: active ? const Color(0x552A170B) : const Color(0x331C2229),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active ? TanukiColors.orange : const Color(0x22FFFFFF),
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(8),
                  ),
                  child: SizedBox(
                    width: 192 * scale,
                    height: 108 * scale,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (episode.imageUrl.isNotEmpty)
                          Image.network(
                            episode.imageUrl,
                            fit: BoxFit.cover,
                            cacheWidth: 520,
                            frameBuilder: (context, child, frame, wasSync) {
                              if (wasSync || frame != null) {
                                return child;
                              }
                              return AnimatedOpacity(
                                opacity: frame == null ? 0 : 1,
                                duration: const Duration(milliseconds: 220),
                                child: child,
                              );
                            },
                            errorBuilder: (_, __, ___) =>
                                _PlayerEpisodeImageFallback(
                              episodeNumber: episode.episodeNumber,
                            ),
                          )
                        else
                          _PlayerEpisodeImageFallback(
                            episodeNumber: episode.episodeNumber,
                          ),
                        if (active)
                          Positioned(
                            left: 8 * scale,
                            top: 8 * scale,
                            child: Icon(
                              Icons.play_circle_fill,
                              color: TanukiColors.orange,
                              size: 24 * scale,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      10 * scale,
                      10 * scale,
                      10 * scale,
                      8 * scale,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Episodio ${episode.episodeNumber}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: TanukiColors.orange,
                                  fontSize: 11 * scale,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            if (scheduleLabel.isNotEmpty) ...[
                              SizedBox(width: 6 * scale),
                              _PlayerEpisodeScheduleChip(text: scheduleLabel),
                            ],
                          ],
                        ),
                        SizedBox(height: 5 * scale),
                        SizedBox(
                          height: 34 * scale,
                          child: _AutoScrollingSingleLineText(
                            text: title,
                            style: TextStyle(
                              color: TanukiColors.text,
                              fontSize: 13 * scale,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const Spacer(),
                        LinearProgressIndicator(
                          minHeight: 3 * scale,
                          value: progress.clamp(0, 1),
                          backgroundColor: const Color(0x334A5663),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            TanukiColors.orange,
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
      ),
    );
  }
}

class _PlayerEpisodeScheduleChip extends StatelessWidget {
  const _PlayerEpisodeScheduleChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scale = _PlayerDialogScale.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7 * scale, vertical: 3 * scale),
      decoration: BoxDecoration(
        color: const Color(0x332A170B),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x88F28C28)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: TanukiColors.orange,
          fontSize: 9 * scale,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _PlayerEpisodeImageFallback extends StatelessWidget {
  const _PlayerEpisodeImageFallback({required this.episodeNumber});

  final int episodeNumber;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TanukiColors.backgroundAlt,
      alignment: Alignment.center,
      child: Text(
        '$episodeNumber',
        style: const TextStyle(
          color: TanukiColors.muted,
          fontSize: 24,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _AutoScrollingSingleLineText extends StatefulWidget {
  const _AutoScrollingSingleLineText({
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  State<_AutoScrollingSingleLineText> createState() =>
      _AutoScrollingSingleLineTextState();
}

class _AutoScrollingSingleLineTextState
    extends State<_AutoScrollingSingleLineText> {
  final ScrollController _controller = ScrollController();
  int _scrollRun = 0;
  double _lastWidth = -1;

  @override
  void didUpdateWidget(covariant _AutoScrollingSingleLineText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _scrollRun += 1;
      _lastWidth = -1;
      if (_controller.hasClients) {
        _controller.jumpTo(0);
      }
    }
  }

  @override
  void dispose() {
    _scrollRun += 1;
    _controller.dispose();
    super.dispose();
  }

  void _maybeStartAutoScroll(double maxWidth) {
    if ((_lastWidth - maxWidth).abs() < 1) {
      return;
    }
    _lastWidth = maxWidth;
    final textDirection = Directionality.of(context);
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: textDirection,
    )..layout();
    final overflow = painter.width - maxWidth;
    _scrollRun += 1;
    final run = _scrollRun;
    if (overflow <= 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) {
          _controller.jumpTo(0);
        }
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runAutoScroll(run);
    });
  }

  Future<void> _runAutoScroll(int run) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    while (mounted && run == _scrollRun && _controller.hasClients) {
      final maxExtent = _controller.position.maxScrollExtent;
      if (maxExtent <= 1) {
        return;
      }
      final durationMs = (maxExtent * 42).clamp(1800, 7000).round();
      await _controller.animateTo(
        maxExtent,
        duration: Duration(milliseconds: durationMs),
        curve: Curves.linear,
      );
      if (!mounted || run != _scrollRun || !_controller.hasClients) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted || run != _scrollRun || !_controller.hasClients) {
        return;
      }
      _controller.jumpTo(0);
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _maybeStartAutoScroll(constraints.maxWidth);
        return ClipRect(
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                style: widget.style,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlayerDialogButton extends StatelessWidget {
  const _PlayerDialogButton({
    required this.label,
    required this.active,
    required this.onPressed,
    this.onArrowDown,
  });

  final String label;
  final bool active;
  final VoidCallback onPressed;
  final VoidCallback? onArrowDown;

  @override
  Widget build(BuildContext context) {
    final scale = _PlayerDialogScale.of(context);
    final button = SizedBox(
      height: 40 * scale,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: 12 * scale),
          backgroundColor:
              active ? TanukiColors.orange : const Color(0x33141D28),
          foregroundColor: active ? Colors.black : TanukiColors.text,
          side: BorderSide(
            color: active ? TanukiColors.orangeHot : TanukiColors.panelStroke,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8 * scale),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12 * scale),
        ),
      ),
    );
    final downAction = onArrowDown;
    if (downAction == null) {
      return button;
    }
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown):
            _PlayerDialogFocusSourceOptionsIntent(),
      },
      child: Actions(
        actions: {
          _PlayerDialogFocusSourceOptionsIntent:
              CallbackAction<_PlayerDialogFocusSourceOptionsIntent>(
            onInvoke: (_) {
              downAction();
              return null;
            },
          ),
        },
        child: button,
      ),
    );
  }
}

class _PlayerDialogFocusSourceOptionsIntent extends Intent {
  const _PlayerDialogFocusSourceOptionsIntent();
}

class _PlayerDialogRadioButton extends StatelessWidget {
  const _PlayerDialogRadioButton({
    required this.label,
    required this.active,
    required this.onPressed,
    this.focusNode,
    this.onArrowDown,
  });

  final String label;
  final bool active;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final VoidCallback? onArrowDown;

  @override
  Widget build(BuildContext context) {
    final scale = _PlayerDialogScale.of(context);
    final button = OutlinedButton(
      focusNode: focusNode,
      onPressed: onPressed,
      onFocusChange: (focused) {
        if (!focused) return;
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
        );
      },
      style: ButtonStyle(
        minimumSize: WidgetStateProperty.all(Size(0, 40 * scale)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStateProperty.all(
          EdgeInsets.symmetric(horizontal: 8 * scale),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return const Color(0x333CA7FF);
          }
          return active ? const Color(0x332A170B) : Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (active || states.contains(WidgetState.focused)) {
            return TanukiColors.text;
          }
          return const Color(0xFFD8E1EB);
        }),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return BorderSide(
              color: TanukiColors.orangeHot,
              width: 2 * scale,
            );
          }
          return BorderSide(
            color: active ? TanukiColors.orange : Colors.transparent,
            width: 1 * scale,
          );
        }),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8 * scale),
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            active ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 17 * scale,
            color: active ? TanukiColors.orange : TanukiColors.muted,
          ),
          SizedBox(width: 7 * scale),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12 * scale,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    final downAction = onArrowDown;
    if (downAction == null) {
      return button;
    }
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown):
            _PlayerDialogFocusSourceOptionsIntent(),
      },
      child: Actions(
        actions: {
          _PlayerDialogFocusSourceOptionsIntent:
              CallbackAction<_PlayerDialogFocusSourceOptionsIntent>(
            onInvoke: (_) {
              downAction();
              return null;
            },
          ),
        },
        child: button,
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
    final scale = _PlayerDialogScale.of(context);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
        SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
      },
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: 178 * scale),
          child: Scrollbar(
            controller: _controller,
            thumbVisibility: widget.children.length > 4,
            interactive: false,
            child: SingleChildScrollView(
              controller: _controller,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var index = 0;
                      index < widget.children.length;
                      index += 1)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom:
                            index == widget.children.length - 1 ? 0 : 6 * scale,
                      ),
                      child: widget.children[index],
                    ),
                ],
              ),
            ),
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
    required this.onToggleVolume,
    required this.onVolumeHoverChanged,
    required this.onVolumeChanged,
    required this.onFullscreen,
    required this.onControlFocusChanged,
    required this.showVolumeControl,
    required this.showVolumeSlider,
    required this.volume,
    required this.showFullscreenControl,
    required this.controlScale,
    this.backButtonFocusNode,
    this.previousButtonFocusNode,
    this.nextButtonFocusNode,
    this.settingsButtonFocusNode,
    this.episodesButtonFocusNode,
    this.volumeButtonFocusNode,
    this.fullscreenButtonFocusNode,
  });

  final EpisodeItem episode;
  final FocusNode? backButtonFocusNode;
  final FocusNode? previousButtonFocusNode;
  final FocusNode? nextButtonFocusNode;
  final FocusNode? settingsButtonFocusNode;
  final FocusNode? episodesButtonFocusNode;
  final FocusNode? volumeButtonFocusNode;
  final FocusNode? fullscreenButtonFocusNode;
  final String status;
  final IconData statusIcon;
  final Color statusColor;
  final VoidCallback onBack;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onSettings;
  final VoidCallback onEpisodes;
  final VoidCallback onToggleVolume;
  final ValueChanged<bool> onVolumeHoverChanged;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onFullscreen;
  final ValueChanged<bool> onControlFocusChanged;
  final bool showVolumeControl;
  final bool showVolumeSlider;
  final double volume;
  final bool showFullscreenControl;
  final double controlScale;

  @override
  Widget build(BuildContext context) {
    final scale = controlScale;
    final textScale = 1 + ((scale - 1) * 0.45);
    final volumeIcon = volume <= 0.01
        ? Icons.volume_off
        : volume < 0.55
            ? Icons.volume_down
            : Icons.volume_up;
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Container(
        color: const Color(0x96000000),
        padding: EdgeInsets.all(12 * scale),
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
                controlScale: scale,
              ),
            ),
            SizedBox(width: 10 * scale),
            FocusTraversalOrder(
              order: const NumericFocusOrder(2),
              child: _PlayerIconButton(
                icon: Icons.skip_previous,
                tooltip: 'Capitulo anterior',
                focusNode: previousButtonFocusNode,
                onPressed: onPrevious,
                onFocusChanged: onControlFocusChanged,
                controlScale: scale,
              ),
            ),
            SizedBox(width: 10 * scale),
            FocusTraversalOrder(
              order: const NumericFocusOrder(3),
              child: _PlayerIconButton(
                icon: Icons.skip_next,
                tooltip: 'Capitulo siguiente',
                focusNode: nextButtonFocusNode,
                onPressed: onNext,
                onFocusChanged: onControlFocusChanged,
                controlScale: scale,
              ),
            ),
            SizedBox(width: 12 * scale),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${episode.seriesName} - Episodio ${episode.episodeNumber}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontSize: 16 * textScale,
                        ),
                  ),
                  SizedBox(height: 4 * textScale),
                  Row(
                    children: [
                      Icon(statusIcon,
                          size: 15 * textScale, color: statusColor),
                      SizedBox(width: 5 * textScale),
                      Expanded(
                        child: Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: statusColor,
                                    fontSize: 14 * textScale,
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: 12 * scale),
            FocusTraversalOrder(
              order: const NumericFocusOrder(4),
              child: _PlayerIconButton(
                icon: Icons.view_list,
                tooltip: 'Episodios',
                focusNode: episodesButtonFocusNode,
                onPressed: onEpisodes,
                onFocusChanged: onControlFocusChanged,
                controlScale: scale,
              ),
            ),
            SizedBox(width: 10 * scale),
            FocusTraversalOrder(
              order: const NumericFocusOrder(5),
              child: _PlayerIconButton(
                icon: Icons.settings,
                tooltip: 'Ajustes',
                focusNode: settingsButtonFocusNode,
                onPressed: onSettings,
                onFocusChanged: onControlFocusChanged,
                controlScale: scale,
              ),
            ),
            if (showVolumeControl) ...[
              SizedBox(width: 10 * scale),
              FocusTraversalOrder(
                order: const NumericFocusOrder(6),
                child: MouseRegion(
                  onEnter: (_) => onVolumeHoverChanged(true),
                  onExit: (_) => onVolumeHoverChanged(false),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PlayerIconButton(
                        icon: volumeIcon,
                        tooltip: volume <= 0.01 ? 'Desmutear' : 'Mutear',
                        focusNode: volumeButtonFocusNode,
                        onPressed: onToggleVolume,
                        onFocusChanged: (focused) {
                          onControlFocusChanged(focused);
                          if (focused) {
                            onVolumeHoverChanged(true);
                          }
                        },
                        controlScale: scale,
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        width: showVolumeSlider ? 152 * scale : 0,
                        height: 44 * scale,
                        clipBehavior: Clip.hardEdge,
                        decoration: const BoxDecoration(),
                        child: showVolumeSlider
                            ? Focus(
                                canRequestFocus: false,
                                descendantsAreFocusable: false,
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 3,
                                    thumbShape: RoundSliderThumbShape(
                                      enabledThumbRadius: 7 * scale,
                                    ),
                                    overlayShape: RoundSliderOverlayShape(
                                      overlayRadius: 13 * scale,
                                    ),
                                    activeTrackColor: TanukiColors.orange,
                                    inactiveTrackColor: Colors.white24,
                                    thumbColor: Colors.white,
                                  ),
                                  child: Slider(
                                    min: 0,
                                    max: 1,
                                    value: volume.clamp(0.0, 1.0).toDouble(),
                                    onChanged: onVolumeChanged,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (showFullscreenControl) ...[
              SizedBox(width: 10 * scale),
              FocusTraversalOrder(
                order: const NumericFocusOrder(7),
                child: _PlayerIconButton(
                  icon: Icons.fullscreen,
                  tooltip: 'Pantalla completa',
                  focusNode: fullscreenButtonFocusNode,
                  onPressed: onFullscreen,
                  onFocusChanged: onControlFocusChanged,
                  controlScale: scale,
                ),
              ),
            ],
          ],
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

class _PlayerProgressFocusFrame extends StatefulWidget {
  const _PlayerProgressFocusFrame({
    required this.focusNode,
    required this.onFocusChanged,
    required this.onKeyEvent,
    required this.builder,
  });

  final FocusNode? focusNode;
  final ValueChanged<bool> onFocusChanged;
  final FocusOnKeyEventCallback onKeyEvent;
  final Widget Function(bool focused) builder;

  @override
  State<_PlayerProgressFocusFrame> createState() =>
      _PlayerProgressFocusFrameState();
}

class _PlayerProgressFocusFrameState extends State<_PlayerProgressFocusFrame> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_handleFocusNodeChanged);
    _focused = widget.focusNode?.hasFocus ?? false;
  }

  @override
  void didUpdateWidget(_PlayerProgressFocusFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_handleFocusNodeChanged);
      widget.focusNode?.addListener(_handleFocusNodeChanged);
      _focused = widget.focusNode?.hasFocus ?? false;
    }
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_handleFocusNodeChanged);
    super.dispose();
  }

  void _handleFocusNodeChanged() {
    final focused = widget.focusNode?.hasFocus ?? false;
    if (_focused == focused) {
      return;
    }
    setState(() => _focused = focused);
    widget.onFocusChanged(focused);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (focused) {
        if (widget.focusNode != null || _focused == focused) {
          return;
        }
        setState(() => _focused = focused);
        widget.onFocusChanged(focused);
      },
      onKeyEvent: widget.onKeyEvent,
      child: widget.builder(_focused),
    );
  }
}

class _PlayerIconButton extends StatefulWidget {
  const _PlayerIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.onFocusChanged,
    this.controlScale = 1,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final ValueChanged<bool> onFocusChanged;
  final double controlScale;
  final FocusNode? focusNode;

  @override
  State<_PlayerIconButton> createState() => _PlayerIconButtonState();
}

class _PlayerIconButtonState extends State<_PlayerIconButton> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_handleFocusNodeChanged);
    _focused = widget.focusNode?.hasFocus ?? false;
  }

  @override
  void didUpdateWidget(_PlayerIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_handleFocusNodeChanged);
      widget.focusNode?.addListener(_handleFocusNodeChanged);
      _focused = widget.focusNode?.hasFocus ?? false;
    }
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_handleFocusNodeChanged);
    super.dispose();
  }

  void _handleFocusNodeChanged() {
    final focused = widget.focusNode?.hasFocus ?? false;
    if (_focused == focused) {
      return;
    }
    setState(() => _focused = focused);
    widget.onFocusChanged(focused);
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.controlScale;
    return Tooltip(
      message: widget.tooltip,
      child: Focus(
        onFocusChange: (focused) {
          if (widget.focusNode != null || _focused == focused) {
            return;
          }
          setState(() => _focused = focused);
          widget.onFocusChanged(focused);
        },
        child: SizedBox(
          width: 50 * scale,
          height: 50 * scale,
          child: Center(
            child: AnimatedScale(
              scale: _focused ? 1.14 : 1,
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: _focused
                      ? const [
                          BoxShadow(
                            color: Color(0x5524384C),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : const [],
                ),
                child: IconButton(
                  focusNode: widget.focusNode,
                  onPressed: widget.onPressed,
                  icon: Icon(widget.icon, size: 24 * scale),
                  style: ButtonStyle(
                    fixedSize:
                        WidgetStateProperty.all(Size(44 * scale, 44 * scale)),
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      if (_focused || states.contains(WidgetState.focused)) {
                        return const Color(0x4424384C);
                      }
                      return Colors.transparent;
                    }),
                    foregroundColor: WidgetStateProperty.all(Colors.white),
                    side: WidgetStateProperty.all(BorderSide.none),
                    shape: WidgetStateProperty.all(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6 * scale),
                      ),
                    ),
                  ),
                ),
              ),
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
  final source = '${stream.playbackUrl} ${stream.pageUrl}'.trim().toLowerCase();
  final server = stream.server.trim().toLowerCase();
  if (stream.playbackKind.toLowerCase() == 'hls') {
    return source.contains('player.zilla-networks.com') ||
        source.contains('zilla-networks.com');
  }
  if (stream.playbackKind.toLowerCase() == 'mp4') {
    return server == 'mp4upload' || source.contains('mp4upload.com');
  }
  return false;
}

bool shouldWatchAniPmHeliosVideoFrame(
  RemoteProvider? provider,
  RemoteDirectStream? stream,
) {
  if (provider != RemoteProvider.aniPm || stream == null) {
    return false;
  }
  return stream.server.trim().toLowerCase().startsWith('helios-') &&
      stream.playbackKind.toLowerCase() == 'hls';
}

bool shouldWatchRemoteVideoFrame(
  RemoteProvider? provider,
  RemoteDirectStream? stream,
) {
  return shouldWatchAnimeAv1VideoFrame(provider, stream) ||
      shouldWatchAniPmHeliosVideoFrame(provider, stream);
}

bool shouldUseStableRemoteAv1PlaybackProfile(RemoteDirectStream? stream) {
  if (stream == null || stream.provider != RemoteProvider.animeAv1) {
    return false;
  }
  final source = '${stream.playbackUrl} ${stream.pageUrl} ${stream.server} '
          '${stream.httpHeaders['X-Tanuki-Upstream-Url'] ?? ''}'
      .toLowerCase();
  final kind = stream.playbackKind.toLowerCase();
  if (kind == 'hls') {
    return source.contains('player.zilla-networks.com') ||
        source.contains('zilla-networks.com');
  }
  return kind == 'mp4' &&
      (source.contains('mp4upload') || source.contains('127.0.0.1'));
}

bool shouldSuppressStableRemoteAv1AutomaticFallback({
  required RemoteDirectStream? stream,
  required Duration position,
  required bool remotePlaybackAccepted,
  required bool hasVideoFrame,
}) {
  if (stream == null ||
      stream.provider != RemoteProvider.animeAv1 ||
      stream.playbackKind.toLowerCase() != 'hls' ||
      !shouldUseStableRemoteAv1PlaybackProfile(stream)) {
    return false;
  }
  if (position < _stableRemoteAv1AutomaticFallbackSuppressAfter) {
    return false;
  }
  return remotePlaybackAccepted || hasVideoFrame;
}

bool shouldDeferRemoteHlsInitialSeek(RemoteDirectStream? stream) {
  if (stream == null || stream.playbackKind.toLowerCase() != 'hls') {
    return false;
  }
  return stream.provider == RemoteProvider.aniPm || isJkAnimeHls(stream);
}

bool isJkAnimeHls(RemoteDirectStream? stream) {
  return stream != null &&
      stream.provider == RemoteProvider.jkAnime &&
      stream.playbackKind.toLowerCase() == 'hls';
}

bool shouldDeferDesktopVlcInitialSeek(RemoteDirectStream? stream) {
  return shouldUseStableRemoteAv1PlaybackProfile(stream) ||
      shouldDeferRemoteHlsInitialSeek(stream);
}

bool shouldRunDesktopVlcDeferredResumeSeek({
  required RemoteDirectStream? stream,
  required bool hasVideoFrame,
  required bool warmingUp,
}) {
  if (warmingUp) {
    return false;
  }
  if (hasVideoFrame) {
    return true;
  }
  return shouldUseStableRemoteAv1PlaybackProfile(stream);
}

bool shouldReportPlaybackFrameJank({
  required Duration totalSpan,
  required Duration buildDuration,
  required Duration rasterDuration,
}) {
  return totalSpan >= _playbackFrameJankThreshold ||
      buildDuration >= _playbackRenderJankThreshold ||
      rasterDuration >= _playbackRenderJankThreshold;
}

bool shouldReportAndroidExoListenerGap({
  required Duration wallGap,
  required Duration positionDelta,
}) {
  return wallGap >= _androidExoListenerGapThreshold &&
      positionDelta >= _androidExoListenerPositionAdvanceThreshold;
}

bool shouldReportAndroidExoPositionStall({
  required Duration wallGap,
  required Duration positionDelta,
}) {
  return wallGap >= _androidExoPositionStallThreshold &&
      positionDelta <= _androidExoPositionStallTolerance;
}

bool shouldRebuildAndroidExoProgress({
  required bool overlaysVisible,
  required bool controlsFocused,
  required bool dialogOpen,
  required bool subtitlesEnabled,
  required String captionText,
}) {
  return overlaysVisible ||
      controlsFocused ||
      dialogOpen ||
      (subtitlesEnabled && captionText.trim().isNotEmpty);
}

bool isPlayerProgressSeekKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight;
}

bool isPlayerProgressSeekKeyEvent(KeyEvent event) {
  return event is KeyDownEvent || event is KeyRepeatEvent;
}

Duration playerProgressKeyboardSeekStep({required int repeatCount}) {
  if (repeatCount <= 0) {
    return const Duration(seconds: 10);
  }
  if (repeatCount < 5) {
    return const Duration(seconds: 20);
  }
  return const Duration(seconds: 30);
}

Duration clampPlayerProgressSeekTarget(Duration target, Duration duration) {
  final maxPositionMs = max(0, duration.inMilliseconds);
  return Duration(
    milliseconds: target.inMilliseconds.clamp(0, maxPositionMs).toInt(),
  );
}

vp.VideoViewType androidVideoViewTypeForCapabilities(
  AndroidMediaCapabilities? capabilities, {
  AndroidVideoViewMode mode = AndroidVideoViewMode.automatic,
}) {
  if (mode == AndroidVideoViewMode.texture) {
    return vp.VideoViewType.textureView;
  }
  if (mode == AndroidVideoViewMode.surface) {
    return vp.VideoViewType.platformView;
  }
  return vp.VideoViewType.platformView;
}

bool shouldUseAndroidPhoneUi(AndroidMediaCapabilities? capabilities) {
  if (capabilities == null) {
    return false;
  }
  return capabilities.isPhone &&
      !capabilities.isTelevision &&
      !capabilities.isFireTv &&
      !capabilities.isTablet;
}

Future<AndroidMediaCapabilities?> loadAndroidMediaCapabilities({
  MethodChannel channel = _mediaCapabilitiesChannel,
}) {
  if (!Platform.isAndroid) {
    return Future<AndroidMediaCapabilities?>.value();
  }
  return _androidMediaCapabilitiesFuture ??= () async {
    try {
      final data = await channel.invokeMethod<Object?>(
        'androidMediaCapabilities',
      );
      return AndroidMediaCapabilities.fromChannelData(data);
    } catch (error) {
      debugPrint('PlayerScreen: Android media capabilities failed: $error');
      return null;
    }
  }();
}

class AndroidMediaCapabilities {
  const AndroidMediaCapabilities({
    required this.sdkInt,
    required this.manufacturer,
    required this.model,
    required this.device,
    required this.isTelevision,
    required this.isFireTv,
    required this.isTablet,
    required this.isPhone,
    required this.deviceClass,
    required this.hasHardwareAv1Decoder,
    required this.av1Decoders,
    required this.videoDecoders,
  });

  final int sdkInt;
  final String manufacturer;
  final String model;
  final String device;
  final bool isTelevision;
  final bool isFireTv;
  final bool isTablet;
  final bool isPhone;
  final String deviceClass;
  final bool hasHardwareAv1Decoder;
  final List<AndroidCodecDecoder> av1Decoders;
  final Map<String, List<AndroidCodecDecoder>> videoDecoders;

  String get summaryLabel {
    return 'sdk=$sdkInt device="$manufacturer $model/$device" '
        'class=$deviceClass tv=$isTelevision fireTv=$isFireTv '
        'tablet=$isTablet phone=$isPhone '
        'hardwareAv1=$hasHardwareAv1Decoder $videoDecoderSummaryLabel';
  }

  String get deviceClassLabel {
    return switch (deviceClass) {
      'fire-tv' => 'Fire TV',
      'android-tv' => 'Android TV',
      'tablet' => 'tablet',
      'phone' => 'celular',
      _ when isFireTv => 'Fire TV',
      _ when isTelevision => 'Android TV',
      _ when isTablet => 'tablet',
      _ when isPhone => 'celular',
      _ => 'desconocido',
    };
  }

  String get av1DecoderLabel {
    if (av1Decoders.isEmpty) {
      return 'av1Decoders=none';
    }
    return 'av1Decoders=['
        '${av1Decoders.map((decoder) => decoder.summaryLabel).join('; ')}'
        ']';
  }

  String get videoDecoderSummaryLabel {
    if (videoDecoders.isEmpty) {
      return av1DecoderLabel;
    }
    return 'decoders={'
        '${videoDecoders.entries.map((entry) {
      final label = entry.value.isEmpty
          ? 'none'
          : entry.value.map((decoder) => decoder.summaryLabel).join('; ');
      return '${entry.key}=[$label]';
    }).join(', ')}'
        '}';
  }

  static AndroidMediaCapabilities? fromChannelData(Object? data) {
    if (data is! Map) {
      return null;
    }
    final decoders = <AndroidCodecDecoder>[];
    final videoDecoders = <String, List<AndroidCodecDecoder>>{};
    final rawDecoders = data['av1Decoders'];
    if (rawDecoders is Iterable) {
      for (final rawDecoder in rawDecoders) {
        final decoder = AndroidCodecDecoder.fromChannelData(rawDecoder);
        if (decoder != null) {
          decoders.add(decoder);
        }
      }
    }
    final rawVideoDecoders = data['videoDecoders'];
    if (rawVideoDecoders is Map) {
      for (final entry in rawVideoDecoders.entries) {
        final key = _readString(entry.key);
        final value = entry.value;
        if (key.isEmpty || value is! Iterable) {
          continue;
        }
        final parsed = <AndroidCodecDecoder>[];
        for (final rawDecoder in value) {
          final decoder = AndroidCodecDecoder.fromChannelData(rawDecoder);
          if (decoder != null) {
            parsed.add(decoder);
          }
        }
        videoDecoders[key] = List.unmodifiable(parsed);
      }
    }
    return AndroidMediaCapabilities(
      sdkInt: _readInt(data['sdkInt']),
      manufacturer: _readString(data['manufacturer']),
      model: _readString(data['model']),
      device: _readString(data['device']),
      isTelevision: data['isTelevision'] == true,
      isFireTv: data['isFireTv'] == true,
      isTablet: data['isTablet'] == true,
      isPhone: data['isPhone'] == true,
      deviceClass: _readString(data['deviceClass']),
      hasHardwareAv1Decoder: data['hasHardwareAv1Decoder'] == true,
      av1Decoders: List.unmodifiable(decoders),
      videoDecoders: Map.unmodifiable(videoDecoders),
    );
  }
}

class AndroidCodecDecoder {
  const AndroidCodecDecoder({
    required this.name,
    required this.hardwareAccelerated,
    required this.softwareOnly,
    required this.vendor,
  });

  final String name;
  final bool hardwareAccelerated;
  final bool softwareOnly;
  final bool? vendor;

  String get summaryLabel {
    return '$name hw=$hardwareAccelerated sw=$softwareOnly '
        'vendor=${vendor ?? 'unknown'}';
  }

  static AndroidCodecDecoder? fromChannelData(Object? data) {
    if (data is! Map) {
      return null;
    }
    final name = _readString(data['name']);
    if (name.isEmpty) {
      return null;
    }
    return AndroidCodecDecoder(
      name: name,
      hardwareAccelerated: data['hardwareAccelerated'] == true,
      softwareOnly: data['softwareOnly'] == true,
      vendor: data['vendor'] is bool ? data['vendor'] as bool : null,
    );
  }
}

int _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse('$value') ?? 0;
}

String _readString(Object? value) {
  return value is String ? value.trim() : '';
}

Duration deferredResumeSeekWarmup(RemoteDirectStream? stream) {
  if (shouldUseStableRemoteAv1PlaybackProfile(stream)) {
    return Duration.zero;
  }
  if (isJkAnimeHls(stream)) {
    return _jkanimeInitialSeekWarmup;
  }
  return _stableRemoteAv1InitialBufferWarmup;
}

class PlaybackMonitorException implements Exception {
  const PlaybackMonitorException(this.message);

  final String message;

  @override
  String toString() => 'PlaybackMonitorException: $message';
}

bool shouldDeferAndroidExoInitialSeek(RemoteDirectStream? stream) {
  return shouldUseStableRemoteAv1PlaybackProfile(stream) ||
      shouldDeferRemoteHlsInitialSeek(stream);
}

Duration bufferedAheadForPosition({
  required Duration position,
  required List<vp.DurationRange> ranges,
}) {
  var bufferedEnd = position;
  for (final range in ranges) {
    if (range.start <= position && range.end > bufferedEnd) {
      bufferedEnd = range.end;
    }
  }
  final ahead = bufferedEnd - position;
  return ahead.isNegative ? Duration.zero : ahead;
}

bool shouldHoldStableRemoteAv1Rebuffer({
  required RemoteDirectStream? stream,
  required bool openedMedia,
  required bool isBuffering,
  required bool isPlaying,
  required Duration position,
  required bool holdActive,
}) {
  return openedMedia &&
      !holdActive &&
      isBuffering &&
      isPlaying &&
      position >= _stableRemoteAv1StartupBufferTarget &&
      shouldUseStableRemoteAv1PlaybackProfile(stream);
}

List<String> desktopVlcCommandlineArguments({
  required RemoteDirectStream? stream,
  required String audioSlave,
  required String referer,
  required String userAgent,
}) {
  final stableAv1 = shouldUseStableRemoteAv1PlaybackProfile(stream);
  final args = <String>[
    '--network-caching=${stableAv1 ? _stableRemoteAv1VlcCacheMs : 3000}',
    '--live-caching=${stableAv1 ? _stableRemoteAv1VlcCacheMs : 3000}',
    if (stableAv1) '--file-caching=$_stableRemoteAv1VlcCacheMs',
    '--http-reconnect',
    '--adaptive-logic=highest',
    if (stableAv1) ...[
      '--clock-jitter=0',
      '--clock-synchro=0',
      '--no-drop-late-frames',
      '--no-skip-frames',
    ],
    if (audioSlave.isNotEmpty) '--input-slave=$audioSlave',
    if (referer.isNotEmpty) '--http-referrer=$referer',
    if (userAgent.trim().isNotEmpty) '--http-user-agent=${userAgent.trim()}',
  ];
  return args;
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
  final tracks = preferredRemoteSubtitleTracks(
    stream?.subtitleTracks ?? const <RemoteSubtitleTrack>[],
  );
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
  return tracks.first;
}

List<RemoteSubtitleTrack> preferredRemoteSubtitleTracks(
  List<RemoteSubtitleTrack> tracks,
) {
  final ordered = [...tracks];
  ordered.sort((left, right) {
    final score = _remoteSubtitlePreferenceScore(right)
        .compareTo(_remoteSubtitlePreferenceScore(left));
    if (score != 0) return score;
    return remoteSubtitleTrackLabel(left)
        .toLowerCase()
        .compareTo(remoteSubtitleTrackLabel(right).toLowerCase());
  });
  return ordered;
}

int _remoteSubtitlePreferenceScore(RemoteSubtitleTrack track) {
  final text = '${track.label} ${track.language}'.toLowerCase();
  var score = track.isDefault ? 100 : 0;
  if (_looksLikeLatinAmericanSpanish(text)) {
    score += 4000;
  } else if (_looksLikeSpanish(text)) {
    score += 3000;
  } else if (_looksLikeEnglish(text)) {
    score += 2000;
  }
  return score;
}

bool _looksLikeLatinAmericanSpanish(String text) {
  final normalized = _normalizeSubtitleLanguageText(text);
  return _looksLikeSpanish(normalized) &&
      (normalized.contains('latin american') ||
          normalized.contains('latin america') ||
          normalized.contains('latino') ||
          normalized.contains('latam') ||
          normalized.contains('es-419') ||
          normalized.contains('es 419'));
}

bool _looksLikeSpanish(String text) {
  final normalized = _normalizeSubtitleLanguageText(text);
  return normalized.contains('spanish') ||
      normalized.contains('espanol') ||
      normalized.contains('castellano') ||
      RegExp(r'(^|[^a-z])es($|[^a-z])').hasMatch(normalized);
}

bool _looksLikeEnglish(String text) {
  final normalized = _normalizeSubtitleLanguageText(text);
  return normalized.contains('english') ||
      RegExp(r'(^|[^a-z])en(g)?($|[^a-z])').hasMatch(normalized);
}

String _normalizeSubtitleLanguageText(String value) {
  return value
      .toLowerCase()
      .replaceAll('á', 'a')
      .replaceAll('é', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ñ', 'n')
      .replaceAll(RegExp(r'[_\[\]\(\)]+'), ' ');
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

String remoteSubtitleTrackCompactLabel(RemoteSubtitleTrack track) {
  final label = track.label.trim().isEmpty ? 'Subtitulos' : track.label.trim();
  if (track.language.trim().isEmpty ||
      track.language.trim().toLowerCase() == label.toLowerCase()) {
    return label;
  }
  return remoteSubtitleTrackLabel(track);
}

int compareAniPmServerMenuOrder(String left, String right) {
  final score = _aniPmServerMenuOrderScore(left)
      .compareTo(_aniPmServerMenuOrderScore(right));
  if (score != 0) return score;
  return remoteServerLabel(left)
      .toLowerCase()
      .compareTo(remoteServerLabel(right).toLowerCase());
}

int _aniPmServerMenuOrderScore(String server) {
  final normalized = server.trim().toLowerCase();
  final parts = normalized.split('-');
  final family =
      normalized == 'ani-pm' || parts.isEmpty ? normalized : parts.first;
  return switch (family) {
    'ani-pm' => 0,
    'helios' => 10,
    'zephyr' => 20,
    'drift' => 30,
    'pulse' => 40,
    'lyra' => 50,
    'halo' => 60,
    'comet' => 70,
    'onyx' => 80,
    'quasar' => 90,
    'astra' => 100,
    'orion' => 110,
    _ => 1000,
  };
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
    'ani-pm' => 'Ani.pm Direct',
    'helios' => 'Helios',
    'zephyr' => 'Zephyr',
    'drift' => 'Drift',
    'astra' => 'Astra',
    'onyx' => 'Onyx',
    'quasar' => 'Quasar',
    'bilibili-1' => 'BiliBili 1',
    'bilibili-2' => 'BiliBili 2',
    'youtube-sub-1' => 'SUB Opcion 1',
    'youtube-sub-2' => 'SUB Opcion 2',
    'youtube-dub-1' => 'DUB Opcion 1',
    'youtube-dub-2' => 'DUB Opcion 2',
    String value
        when RegExp(
                r'^(nova|pulse|halo|orion|lyra|helios|zephyr|drift|astra|onyx|quasar|comet)(?:-[a-z0-9]+)+$')
            .hasMatch(value) =>
      value
          .split('-')
          .map((part) => part.length == 1
              ? part
              : part == 'hd'
                  ? 'HD'
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
    this.fit,
    this.cacheWidth,
  });

  final String imageUrl;
  final BoxFit? fit;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      imageUrl,
      fit: fit,
      cacheWidth: cacheWidth,
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
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration:
              glassDecoration(color: const Color(0xD010161D), radius: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (episode.imageUrl.isNotEmpty)
                  _FadeInNetworkImage(
                    imageUrl: episode.imageUrl,
                    fit: BoxFit.cover,
                    cacheWidth: 640,
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
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 4)
                            ],
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
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 4)
                            ],
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
  final airDate = _parseEpisodeAirDate(airDateIso);
  if (airDate == null) {
    return false;
  }
  return airDate.isAfter(_todayDate());
}

bool _dialogEpisodeHasPlaybackRoute(EpisodeItem episode) {
  if (episode.filePath.trim().isNotEmpty) {
    return true;
  }
  if (!episode.isRemote) {
    return false;
  }
  return episode.watchUrl.trim().isNotEmpty ||
      episode.slug.trim().isNotEmpty ||
      episode.provider != null;
}

String _episodeScheduleLabel(EpisodeItem episode) {
  final airDate = _parseEpisodeAirDate(episode.airDateIso);
  if (airDate == null) {
    return '';
  }
  final today = _todayDate();
  final daysUntil = airDate.difference(today).inDays;
  final label = switch (daysUntil) {
    0 => 'Hoy',
    1 => 'Manana',
    >= 2 && <= 7 => _weekdayLabel(airDate.weekday),
    _ => '${airDate.day} ${_monthLabel(airDate.month)}',
  };
  return 'Estreno $label';
}

DateTime? _parseEpisodeAirDate(String airDateIso) {
  final normalized = airDateIso.trim();
  if (normalized.isEmpty) {
    return null;
  }
  final source =
      normalized.length >= 10 ? normalized.substring(0, 10) : normalized;
  final parsed = DateTime.tryParse(source);
  if (parsed == null) {
    return null;
  }
  return DateTime(parsed.year, parsed.month, parsed.day);
}

DateTime _todayDate() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

String _weekdayLabel(int weekday) {
  return switch (weekday) {
    DateTime.monday => 'Lunes',
    DateTime.tuesday => 'Martes',
    DateTime.wednesday => 'Miercoles',
    DateTime.thursday => 'Jueves',
    DateTime.friday => 'Viernes',
    DateTime.saturday => 'Sabado',
    _ => 'Domingo',
  };
}

String _monthLabel(int month) {
  return switch (month) {
    DateTime.january => 'Ene',
    DateTime.february => 'Feb',
    DateTime.march => 'Mar',
    DateTime.april => 'Abr',
    DateTime.may => 'May',
    DateTime.june => 'Jun',
    DateTime.july => 'Jul',
    DateTime.august => 'Ago',
    DateTime.september => 'Sep',
    DateTime.october => 'Oct',
    DateTime.november => 'Nov',
    _ => 'Dic',
  };
}
