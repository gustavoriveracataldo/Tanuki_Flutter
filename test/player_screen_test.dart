import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/ui/player_screen.dart';
import 'package:video_player/video_player.dart' as vp;

void main() {
  test('parses WebVTT cues with spaces around the timestamp separator', () {
    final cues = parseRemoteCaptionCues('''WEBVTT

00:00:19.510 --> 00:00:22.930
<i>Solo en el silencio, la palabra.</i>
Solo en la oscuridad, la luz.
''');

    expect(cues, hasLength(1));
    expect(cues.single.start, const Duration(seconds: 19, milliseconds: 510));
    expect(cues.single.end, const Duration(seconds: 22, milliseconds: 930));
    expect(cues.single.text,
        'Solo en el silencio, la palabra.\nSolo en la oscuridad, la luz.');
  });

  const animeAv1ZillaStream = RemoteDirectStream(
    playbackUrl:
        'https://player.zilla-networks.com/m3u8/b340aa7e8c596a6c376adf1f44d8e2e1',
    playbackKind: 'hls',
    pageUrl:
        'https://player.zilla-networks.com/play/b340aa7e8c596a6c376adf1f44d8e2e1',
  );

  test('recognizes Zilla m3u8 path urls as direct remote video', () {
    expect(
      looksLikeDirectVideoPath(
        'https://player.zilla-networks.com/m3u8/b340aa7e8c596a6c376adf1f44d8e2e1',
        isRemote: true,
      ),
      isTrue,
    );
  });

  test('keeps provider pages as remote pages that need resolving', () {
    expect(
      looksLikeDirectVideoPath(
        'https://animeav1.com/media/hunter-x-hunter/1',
        isRemote: true,
      ),
      isFalse,
    );
  });

  test('recognizes Facebook progressive media urls as direct remote video', () {
    final efg = base64UrlEncode(utf8.encode('{"label":"xpv_progressive"}'))
        .replaceAll('=', '');

    expect(
      looksLikeDirectVideoPath(
        'https://video.xx.fbcdn.net/v/t42.1790-2/demo.mp4?efg=$efg&bytestart=0',
        isRemote: true,
      ),
      isTrue,
    );
  });

  test('rejects Facebook audio-only urls as direct remote video', () {
    final efg =
        base64UrlEncode(utf8.encode('{"label":"audio"}')).replaceAll('=', '');

    expect(
      looksLikeDirectVideoPath(
        'https://video.xx.fbcdn.net/v/t42.1790-2/audio.mp4?efg=$efg',
        isRemote: true,
      ),
      isFalse,
    );
  });

  test('recognizes Doodstream tokenized CDN urls as direct remote video', () {
    expect(
      looksLikeDirectVideoPath(
        'https://cloudatacdn.com/v/demo/abcdef1234?token=tok&expiry=999999',
        isRemote: true,
      ),
      isTrue,
    );
  });

  test('excludes active playback provider after remote resolve miss', () {
    const episode = EpisodeItem(
      seriesName: 'Demo',
      seriesStateKey: 'animeav1:demo',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Demo - Capitulo 1',
      relativePath: 'AnimeAV1 / Capitulo 1',
      filePath: 'https://animeav1.com/media/demo/1',
      sourceType: SourceType.remote,
      provider: RemoteProvider.animeAv1,
    );

    expect(
      remoteProviderToExcludeAfterResolveMiss(
        episode: episode,
        playbackProvider: RemoteProvider.animeAv1,
        failedProviders: const {},
      ),
      RemoteProvider.animeAv1,
    );
    expect(
      remoteProviderToExcludeAfterResolveMiss(
        episode: episode,
        playbackProvider: RemoteProvider.animeAv1,
        failedProviders: const {RemoteProvider.animeAv1},
      ),
      isNull,
    );
    expect(
      remoteProviderToExcludeAfterResolveMiss(
        episode: episode,
        playbackProvider: RemoteProvider.jkAnime,
        failedProviders: const {RemoteProvider.jkAnime},
      ),
      RemoteProvider.animeAv1,
    );
  });

  test('does not exclude catalog or disabled providers after resolve miss', () {
    const episode = EpisodeItem(
      seriesName: 'Demo',
      seriesStateKey: 'catalog:1',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Demo - Capitulo 1',
      relativePath: 'Catalogo / Capitulo 1',
      filePath: 'https://myanimelist.net/anime/1',
      sourceType: SourceType.remote,
      provider: RemoteProvider.catalog,
    );

    expect(
      remoteProviderToExcludeAfterResolveMiss(
        episode: episode,
        playbackProvider: RemoteProvider.catalog,
        failedProviders: const {},
      ),
      isNull,
    );
    expect(
      remoteProviderToExcludeAfterResolveMiss(
        episode: episode,
        playbackProvider: RemoteProvider.animeFlv,
        failedProviders: const {},
      ),
      isNull,
    );
  });

  test('watches AnimeAV1 Zilla HLS streams for missing video frames', () {
    expect(
      shouldWatchAnimeAv1VideoFrame(
        RemoteProvider.animeAv1,
        animeAv1ZillaStream,
      ),
      isTrue,
    );
  });

  test('watches AnimeAV1 MP4Upload AV1 streams for missing video frames', () {
    expect(
      shouldWatchAnimeAv1VideoFrame(
        RemoteProvider.animeAv1,
        const RemoteDirectStream(
          playbackUrl: 'http://127.0.0.1:44519/media',
          playbackKind: 'mp4',
          pageUrl: 'https://www.mp4upload.com/embed-demo.html',
          provider: RemoteProvider.animeAv1,
          server: 'mp4upload',
        ),
      ),
      isTrue,
    );
  });

  test('does not watch non AnimeAV1 streams for missing video frames', () {
    expect(
      shouldWatchAnimeAv1VideoFrame(
        RemoteProvider.jkAnime,
        const RemoteDirectStream(
          playbackUrl: 'https://cdn.example.test/demo.m3u8',
          playbackKind: 'hls',
          pageUrl: 'https://jkanime.net/demo/1/',
        ),
      ),
      isFalse,
    );
  });

  test('watches Ani.pm Helios HLS streams for missing video frames', () {
    expect(
      shouldWatchRemoteVideoFrame(
        RemoteProvider.aniPm,
        const RemoteDirectStream(
          playbackUrl: 'https://ani.pm/api/anime/src/hls?t=helios',
          playbackKind: 'hls',
          pageUrl: 'https://megaplay.buzz/stream/ani/6069/3/sub',
          provider: RemoteProvider.aniPm,
          server: 'helios-hd-1',
        ),
      ),
      isTrue,
    );
  });

  test('keeps established AnimeAV1 HLS instead of automatic provider fallback',
      () {
    expect(
      shouldSuppressStableRemoteAv1AutomaticFallback(
        stream: animeAv1ZillaStream.copyWith(provider: RemoteProvider.animeAv1),
        position: const Duration(minutes: 15),
        remotePlaybackAccepted: true,
        hasVideoFrame: true,
      ),
      isTrue,
    );
  });

  test('allows AnimeAV1 HLS fallback during startup', () {
    expect(
      shouldSuppressStableRemoteAv1AutomaticFallback(
        stream: animeAv1ZillaStream.copyWith(provider: RemoteProvider.animeAv1),
        position: const Duration(seconds: 45),
        remotePlaybackAccepted: true,
        hasVideoFrame: false,
      ),
      isFalse,
    );
  });

  test('does not suppress non AnimeAV1 provider fallback', () {
    expect(
      shouldSuppressStableRemoteAv1AutomaticFallback(
        stream: const RemoteDirectStream(
          playbackUrl: 'https://cdn.example.test/demo.m3u8',
          playbackKind: 'hls',
          pageUrl: 'https://jkanime.net/demo/1/',
          provider: RemoteProvider.jkAnime,
          server: 'magi',
        ),
        position: const Duration(minutes: 15),
        remotePlaybackAccepted: true,
        hasVideoFrame: true,
      ),
      isFalse,
    );
  });

  test('does not retry missing video frames before playback grace', () {
    expect(
      shouldRetryMissingVideoFrame(
        isPlaying: true,
        isBuffering: false,
        position: const Duration(seconds: 12),
        width: null,
        height: null,
      ),
      isFalse,
    );
  });

  test('does not retry missing video frames while buffering', () {
    expect(
      shouldRetryMissingVideoFrame(
        isPlaying: true,
        isBuffering: true,
        position: const Duration(seconds: 40),
        width: null,
        height: null,
      ),
      isFalse,
    );
  });

  test('retries only after playback advanced without video frames', () {
    expect(
      shouldRetryMissingVideoFrame(
        isPlaying: true,
        isBuffering: false,
        position: const Duration(seconds: 40),
        width: null,
        height: null,
      ),
      isTrue,
    );
  });

  test('does not retry when video dimensions are available', () {
    expect(
      shouldRetryMissingVideoFrame(
        isPlaying: true,
        isBuffering: false,
        position: const Duration(seconds: 40),
        width: 1920,
        height: 1080,
      ),
      isFalse,
    );
  });

  test('builds stable VLC profile for AnimeAV1 MP4Upload streams', () {
    const stream = RemoteDirectStream(
      playbackUrl: 'http://127.0.0.1:44519/media',
      playbackKind: 'mp4',
      pageUrl: 'https://www.mp4upload.com/embed-demo.html',
      provider: RemoteProvider.animeAv1,
      server: 'mp4upload',
    );
    final args = desktopVlcCommandlineArguments(
      stream: stream,
      audioSlave: '',
      referer: 'https://www.mp4upload.com/embed-demo.html',
      userAgent: 'Mozilla/5.0',
    );

    expect(shouldDeferDesktopVlcInitialSeek(stream), isTrue);
    expect(shouldDeferAndroidExoInitialSeek(stream), isTrue);
    expect(args, contains('--network-caching=20000'));
    expect(args, contains('--file-caching=20000'));
    expect(args, contains('--clock-jitter=0'));
    expect(args, contains('--clock-synchro=0'));
    expect(args, contains('--no-drop-late-frames'));
    expect(
      args,
      contains('--http-referrer=https://www.mp4upload.com/embed-demo.html'),
    );
    expect(args, contains('--http-user-agent=Mozilla/5.0'));
  });

  test('builds stable VLC profile for proxied AnimeAV1 Zilla HLS streams', () {
    const stream = RemoteDirectStream(
      playbackUrl: 'http://127.0.0.1:44519/playlist.m3u8',
      playbackKind: 'hls',
      pageUrl:
          'https://player.zilla-networks.com/play/6a91a9fceb2dc7ac9385520de35977b3',
      provider: RemoteProvider.animeAv1,
      httpHeaders: {
        'X-Tanuki-Upstream-Url':
            'https://player.zilla-networks.com/m3u8/6a91a9fceb2dc7ac9385520de35977b3',
      },
    );
    final args = desktopVlcCommandlineArguments(
      stream: stream,
      audioSlave: '',
      referer:
          'https://player.zilla-networks.com/play/6a91a9fceb2dc7ac9385520de35977b3',
      userAgent: 'Mozilla/5.0',
    );

    expect(
        shouldWatchAnimeAv1VideoFrame(RemoteProvider.animeAv1, stream), isTrue);
    expect(shouldDeferDesktopVlcInitialSeek(stream), isTrue);
    expect(shouldDeferAndroidExoInitialSeek(stream), isTrue);
    expect(args, contains('--network-caching=20000'));
    expect(args, contains('--file-caching=20000'));
    expect(args, contains('--clock-jitter=0'));
  });

  test('runs deferred resume for stable AnimeAV1 HLS after warmup', () {
    const stream = RemoteDirectStream(
      playbackUrl: 'http://127.0.0.1:44519/playlist.m3u8',
      playbackKind: 'hls',
      pageUrl:
          'https://player.zilla-networks.com/play/6a91a9fceb2dc7ac9385520de35977b3',
      provider: RemoteProvider.animeAv1,
      httpHeaders: {
        'X-Tanuki-Upstream-Url':
            'https://player.zilla-networks.com/m3u8/6a91a9fceb2dc7ac9385520de35977b3',
      },
    );

    expect(
      shouldRunDesktopVlcDeferredResumeSeek(
        stream: stream,
        hasVideoFrame: false,
        warmingUp: true,
      ),
      isFalse,
    );
    expect(
      shouldRunDesktopVlcDeferredResumeSeek(
        stream: stream,
        hasVideoFrame: false,
        warmingUp: false,
      ),
      isTrue,
    );
  });

  test('reports playback frame jank beyond monitor thresholds', () {
    expect(
      shouldReportPlaybackFrameJank(
        totalSpan: const Duration(milliseconds: 121),
        buildDuration: const Duration(milliseconds: 4),
        rasterDuration: const Duration(milliseconds: 8),
      ),
      isTrue,
    );
    expect(
      shouldReportPlaybackFrameJank(
        totalSpan: const Duration(milliseconds: 16),
        buildDuration: const Duration(milliseconds: 4),
        rasterDuration: const Duration(milliseconds: 81),
      ),
      isTrue,
    );
    expect(
      shouldReportPlaybackFrameJank(
        totalSpan: const Duration(milliseconds: 16),
        buildDuration: const Duration(milliseconds: 4),
        rasterDuration: const Duration(milliseconds: 8),
      ),
      isFalse,
    );
  });

  test('reports ExoPlayer listener gaps when playback clock advances', () {
    expect(
      shouldReportAndroidExoListenerGap(
        wallGap: const Duration(milliseconds: 1300),
        positionDelta: const Duration(milliseconds: 1000),
      ),
      isTrue,
    );
    expect(
      shouldReportAndroidExoListenerGap(
        wallGap: const Duration(milliseconds: 1300),
        positionDelta: const Duration(milliseconds: 100),
      ),
      isFalse,
    );
  });

  test('reports ExoPlayer heartbeat stalls when playback position stops', () {
    expect(
      shouldReportAndroidExoPositionStall(
        wallGap: const Duration(milliseconds: 1200),
        positionDelta: const Duration(milliseconds: 100),
      ),
      isTrue,
    );
    expect(
      shouldReportAndroidExoPositionStall(
        wallGap: const Duration(milliseconds: 1200),
        positionDelta: const Duration(milliseconds: 500),
      ),
      isFalse,
    );
  });

  test('parses Android AV1 hardware decoder capabilities', () {
    final capabilities = AndroidMediaCapabilities.fromChannelData({
      'sdkInt': 33,
      'manufacturer': 'Xiaomi',
      'model': '2201117TG',
      'device': 'spes',
      'isTelevision': false,
      'isFireTv': false,
      'isTablet': false,
      'isPhone': true,
      'deviceClass': 'phone',
      'hasHardwareAv1Decoder': false,
      'av1Decoders': [
        {
          'name': 'c2.android.av1-dav1d.decoder',
          'hardwareAccelerated': false,
          'softwareOnly': true,
          'vendor': false,
        },
      ],
      'videoDecoders': {
        'h264': [
          {
            'name': 'c2.qti.avc.decoder',
            'hardwareAccelerated': true,
            'softwareOnly': false,
            'vendor': true,
          },
        ],
        'av1': [
          {
            'name': 'c2.android.av1-dav1d.decoder',
            'hardwareAccelerated': false,
            'softwareOnly': true,
            'vendor': false,
          },
        ],
      },
    });

    expect(capabilities, isNotNull);
    expect(capabilities!.isTelevision, isFalse);
    expect(capabilities.isPhone, isTrue);
    expect(capabilities.deviceClassLabel, 'celular');
    expect(capabilities.hasHardwareAv1Decoder, isFalse);
    expect(capabilities.av1Decoders.single.softwareOnly, isTrue);
    expect(capabilities.summaryLabel, contains('hardwareAv1=false'));
    expect(capabilities.summaryLabel, contains('class=phone'));
    expect(capabilities.summaryLabel, contains('tv=false'));
    expect(capabilities.summaryLabel, contains('h264=[c2.qti.avc.decoder'));
    expect(capabilities.summaryLabel, contains('c2.android.av1-dav1d.decoder'));
  });

  test('uses platform video view for Android TV devices', () {
    const tvCapabilities = AndroidMediaCapabilities(
      sdkInt: 33,
      manufacturer: 'Amazon',
      model: 'AFTSS',
      device: 'sheldon',
      isTelevision: true,
      isFireTv: true,
      isTablet: false,
      isPhone: false,
      deviceClass: 'fire-tv',
      hasHardwareAv1Decoder: false,
      av1Decoders: [],
      videoDecoders: {},
    );
    const tabletCapabilities = AndroidMediaCapabilities(
      sdkInt: 33,
      manufacturer: 'Samsung',
      model: 'Galaxy Tab',
      device: 'gta',
      isTelevision: false,
      isFireTv: false,
      isTablet: true,
      isPhone: false,
      deviceClass: 'tablet',
      hasHardwareAv1Decoder: false,
      av1Decoders: [],
      videoDecoders: {},
    );
    const phoneCapabilities = AndroidMediaCapabilities(
      sdkInt: 33,
      manufacturer: 'Samsung',
      model: 'Redmi Note',
      device: 'redmi',
      isTelevision: false,
      isFireTv: false,
      isTablet: false,
      isPhone: true,
      deviceClass: 'phone',
      hasHardwareAv1Decoder: false,
      av1Decoders: [],
      videoDecoders: {},
    );

    expect(
      androidVideoViewTypeForCapabilities(tvCapabilities),
      vp.VideoViewType.platformView,
    );
    expect(
      androidVideoViewTypeForCapabilities(tabletCapabilities),
      vp.VideoViewType.platformView,
    );
    expect(
      androidVideoViewTypeForCapabilities(phoneCapabilities),
      vp.VideoViewType.platformView,
    );
    expect(
      androidVideoViewTypeForCapabilities(
        phoneCapabilities,
        mode: AndroidVideoViewMode.surface,
      ),
      vp.VideoViewType.platformView,
    );
    expect(
      androidVideoViewTypeForCapabilities(
        tvCapabilities,
        mode: AndroidVideoViewMode.texture,
      ),
      vp.VideoViewType.textureView,
    );

    expect(shouldUseAndroidPhoneUi(tvCapabilities), isFalse);
    expect(shouldUseAndroidPhoneUi(tabletCapabilities), isFalse);
    expect(shouldUseAndroidPhoneUi(phoneCapabilities), isTrue);
  });

  test('rebuilds Android Exo progress only for visible UI needs', () {
    expect(
      shouldRebuildAndroidExoProgress(
        overlaysVisible: false,
        controlsFocused: false,
        dialogOpen: false,
        subtitlesEnabled: true,
        captionText: '',
      ),
      isFalse,
    );
    expect(
      shouldRebuildAndroidExoProgress(
        overlaysVisible: true,
        controlsFocused: false,
        dialogOpen: false,
        subtitlesEnabled: false,
        captionText: '',
      ),
      isTrue,
    );
    expect(
      shouldRebuildAndroidExoProgress(
        overlaysVisible: false,
        controlsFocused: false,
        dialogOpen: false,
        subtitlesEnabled: true,
        captionText: 'caption',
      ),
      isTrue,
    );
  });

  test('uses small then larger keyboard seek steps for held progress keys', () {
    expect(
      playerProgressKeyboardSeekStep(repeatCount: 0),
      const Duration(seconds: 10),
    );
    expect(
      playerProgressKeyboardSeekStep(repeatCount: 1),
      const Duration(seconds: 20),
    );
    expect(
      playerProgressKeyboardSeekStep(repeatCount: 5),
      const Duration(seconds: 30),
    );
  });

  test('clamps keyboard seek targets inside playback duration', () {
    expect(
      clampPlayerProgressSeekTarget(
        const Duration(seconds: -10),
        const Duration(minutes: 2),
      ),
      Duration.zero,
    );
    expect(
      clampPlayerProgressSeekTarget(
        const Duration(minutes: 3),
        const Duration(minutes: 2),
      ),
      const Duration(minutes: 2),
    );
  });

  test('calculates buffered time ahead of the current position', () {
    final ahead = bufferedAheadForPosition(
      position: const Duration(seconds: 12),
      ranges: [
        vp.DurationRange(
          const Duration(seconds: 0),
          const Duration(seconds: 5),
        ),
        vp.DurationRange(
          const Duration(seconds: 10),
          const Duration(seconds: 25),
        ),
      ],
    );

    expect(ahead, const Duration(seconds: 13));
  });

  test('ignores buffered ranges that do not cover current position', () {
    final ahead = bufferedAheadForPosition(
      position: const Duration(seconds: 12),
      ranges: [
        vp.DurationRange(
          const Duration(seconds: 15),
          const Duration(seconds: 30),
        ),
      ],
    );

    expect(ahead, Duration.zero);
  });

  test('holds mid-play rebuffer for stable AnimeAV1 MP4Upload streams', () {
    const stream = RemoteDirectStream(
      playbackUrl: 'http://127.0.0.1:44519/media',
      playbackKind: 'mp4',
      pageUrl: 'https://www.mp4upload.com/embed-demo.html',
      provider: RemoteProvider.animeAv1,
      server: 'mp4upload',
    );

    expect(
      shouldHoldStableRemoteAv1Rebuffer(
        stream: stream,
        openedMedia: true,
        isBuffering: true,
        isPlaying: true,
        position: const Duration(seconds: 42),
        holdActive: false,
      ),
      isTrue,
    );
  });

  test('does not hold rebuffer before playback is established', () {
    const stream = RemoteDirectStream(
      playbackUrl: 'http://127.0.0.1:44519/media',
      playbackKind: 'mp4',
      pageUrl: 'https://www.mp4upload.com/embed-demo.html',
      provider: RemoteProvider.animeAv1,
      server: 'mp4upload',
    );

    expect(
      shouldHoldStableRemoteAv1Rebuffer(
        stream: stream,
        openedMedia: false,
        isBuffering: true,
        isPlaying: true,
        position: const Duration(seconds: 42),
        holdActive: false,
      ),
      isFalse,
    );
  });

  test('does not hold rebuffer for ordinary remote streams', () {
    expect(
      shouldHoldStableRemoteAv1Rebuffer(
        stream: const RemoteDirectStream(
          playbackUrl: 'https://cdn.example.test/demo.m3u8',
          playbackKind: 'hls',
          pageUrl: 'https://jkanime.net/demo/1/',
          provider: RemoteProvider.jkAnime,
        ),
        openedMedia: true,
        isBuffering: true,
        isPlaying: true,
        position: const Duration(seconds: 42),
        holdActive: false,
      ),
      isFalse,
    );
  });

  test('keeps default VLC profile for ordinary remote streams', () {
    final args = desktopVlcCommandlineArguments(
      stream: const RemoteDirectStream(
        playbackUrl: 'https://cdn.example.test/demo.m3u8',
        playbackKind: 'hls',
        pageUrl: 'https://jkanime.net/demo/1/',
        provider: RemoteProvider.jkAnime,
      ),
      audioSlave: '',
      referer: '',
      userAgent: 'Mozilla/5.0',
    );

    expect(args, contains('--network-caching=3000'));
    expect(args, isNot(contains('--file-caching=9000')));
    expect(args, isNot(contains('--clock-synchro=0')));
  });

  test('defers initial resume seek briefly for JKAnime Magi HLS streams', () {
    const stream = RemoteDirectStream(
      playbackUrl: 'https://nika.playmudos.com/demo.m3u8',
      playbackKind: 'hls',
      pageUrl: 'https://jkanime.net/jkplayer/umv?e=demo',
      provider: RemoteProvider.jkAnime,
      server: 'magi',
    );

    expect(shouldDeferRemoteHlsInitialSeek(stream), isTrue);
    expect(shouldDeferDesktopVlcInitialSeek(stream), isTrue);
    expect(shouldDeferAndroidExoInitialSeek(stream), isTrue);
    expect(deferredResumeSeekWarmup(stream), const Duration(seconds: 2));
  });

  test('defers initial resume seek briefly for JKAnime Desu HLS streams', () {
    const stream = RemoteDirectStream(
      playbackUrl: 'https://desu.example.test/demo.m3u8',
      playbackKind: 'hls',
      pageUrl: 'https://jkanime.net/jkplayer/desu?e=demo',
      provider: RemoteProvider.jkAnime,
      server: 'desu',
    );

    expect(shouldDeferRemoteHlsInitialSeek(stream), isTrue);
    expect(shouldDeferDesktopVlcInitialSeek(stream), isTrue);
    expect(shouldDeferAndroidExoInitialSeek(stream), isTrue);
    expect(deferredResumeSeekWarmup(stream), const Duration(seconds: 2));
  });

  test('defers initial resume seek for ani.pm HLS streams', () {
    const stream = RemoteDirectStream(
      playbackUrl: 'https://ani.pm/api/anime/src/hls?t=demo',
      playbackKind: 'hls',
      pageUrl: 'https://ani.pm/api/anime/src/hls?t=demo',
      provider: RemoteProvider.aniPm,
      server: 'comet-1',
    );

    expect(shouldDeferRemoteHlsInitialSeek(stream), isTrue);
    expect(shouldDeferDesktopVlcInitialSeek(stream), isTrue);
    expect(shouldDeferAndroidExoInitialSeek(stream), isTrue);
  });

  test('retries missing audio only after remote video is visible', () {
    expect(
      shouldRetryMissingAudioTrack(
        isRemote: true,
        hasVideoFrame: true,
        audioTrackCount: 0,
        attempt: 10,
        maxAttempts: 10,
      ),
      isTrue,
    );
    expect(
      shouldRetryMissingAudioTrack(
        isRemote: true,
        hasVideoFrame: false,
        audioTrackCount: 0,
        attempt: 10,
        maxAttempts: 10,
      ),
      isFalse,
    );
    expect(
      shouldRetryMissingAudioTrack(
        isRemote: true,
        hasVideoFrame: true,
        audioTrackCount: 1,
        attempt: 10,
        maxAttempts: 10,
      ),
      isFalse,
    );
  });

  test('recovers remote opening when resumed stream never advances', () {
    expect(
      shouldRecoverRemoteOpeningStall(
        isPlaying: false,
        isBuffering: true,
        position: Duration.zero,
        target: const Duration(minutes: 12),
        width: null,
        height: null,
      ),
      isTrue,
    );
  });

  test('starts new and completed episodes at zero', () {
    expect(
      initialMediaStartPosition(
        resumePosition: null,
        canStartAtPosition: true,
      ),
      Duration.zero,
    );
  });

  test('builds Android hardware decoder codec lists with optional AV1', () {
    final codecs = androidHardwareDecoderCodecs(disableAv1: true);

    expect(codecs.split(','), isNot(contains('av1')));
    expect(codecs.split(','), containsAll(<String>['h264', 'hevc', 'vp9']));
    expect(
      androidHardwareDecoderCodecs(disableAv1: false).split(','),
      contains('av1'),
    );
  });

  test('rejects early remote completion with full BiliBili duration', () {
    expect(
      shouldAcceptPlaybackCompletion(
        isRemote: true,
        position: const Duration(milliseconds: 500),
        duration: const Duration(minutes: 22, seconds: 55),
      ),
      isFalse,
    );
  });

  test('accepts remote completion only near the real end', () {
    expect(
      shouldAcceptPlaybackCompletion(
        isRemote: true,
        position: const Duration(minutes: 22, seconds: 30),
        duration: const Duration(minutes: 22, seconds: 55),
      ),
      isTrue,
    );
  });

  test('starts a remote resume slightly before saved progress', () {
    expect(
      initialMediaStartPosition(
        resumePosition: const Duration(minutes: 10),
        canStartAtPosition: true,
      ),
      const Duration(minutes: 9, seconds: 58),
    );
  });

  test('seeks local media after opening instead of using media start', () {
    expect(
      initialMediaStartPosition(
        resumePosition: const Duration(minutes: 10),
        canStartAtPosition: false,
      ),
      isNull,
    );
  });

  test('recovers remote opening when resumed stream stalls near target', () {
    expect(
      shouldRecoverRemoteOpeningStall(
        isPlaying: true,
        isBuffering: false,
        position: const Duration(minutes: 11, seconds: 55),
        target: const Duration(minutes: 12),
        width: null,
        height: null,
      ),
      isTrue,
    );
  });

  test('does not recover remote opening after video dimensions arrive', () {
    expect(
      shouldRecoverRemoteOpeningStall(
        isPlaying: true,
        isBuffering: false,
        position: const Duration(minutes: 12),
        target: const Duration(minutes: 12),
        width: 1920,
        height: 1080,
      ),
      isFalse,
    );
  });

  test('defers early AnimeAV1 playback errors before fallback', () {
    expect(
      shouldDeferAnimeAv1PlaybackError(
        provider: RemoteProvider.animeAv1,
        stream: animeAv1ZillaStream,
        isPlaying: false,
        isBuffering: false,
        position: const Duration(seconds: 12),
        width: null,
        height: null,
      ),
      isTrue,
    );
  });

  test('does not defer AnimeAV1 playback errors after video is visible', () {
    expect(
      shouldDeferAnimeAv1PlaybackError(
        provider: RemoteProvider.animeAv1,
        stream: animeAv1ZillaStream,
        isPlaying: true,
        isBuffering: false,
        position: const Duration(seconds: 50),
        width: 1920,
        height: 1080,
      ),
      isFalse,
    );
  });

  test('retries deferred AnimeAV1 errors only if playback never recovered', () {
    expect(
      shouldRetryDeferredAnimeAv1PlaybackError(
        isPlaying: false,
        isBuffering: false,
        position: Duration.zero,
        width: null,
        height: null,
      ),
      isTrue,
    );
    expect(
      shouldRetryDeferredAnimeAv1PlaybackError(
        isPlaying: true,
        isBuffering: false,
        position: const Duration(seconds: 50),
        width: null,
        height: null,
      ),
      isFalse,
    );
  });

  test('selects default remote subtitle track before fallback track', () {
    final stream = animeAv1ZillaStream.copyWith(
      subtitleTracks: const [
        RemoteSubtitleTrack(
          url: 'https://cdn.example.test/subs/alternate.vtt',
          label: 'Alterno',
          language: 'es',
          mimeType: 'text/vtt',
        ),
        RemoteSubtitleTrack(
          url: 'https://cdn.example.test/subs/default.vtt',
          label: 'Principal',
          language: 'es',
          mimeType: 'text/vtt',
          isDefault: true,
        ),
      ],
    );

    expect(
      selectRemoteSubtitleTrack(stream)?.url,
      'https://cdn.example.test/subs/default.vtt',
    );
  });

  test('prefers Latin American Spanish subtitles before Spanish and English',
      () {
    final stream = animeAv1ZillaStream.copyWith(
      subtitleTracks: const [
        RemoteSubtitleTrack(
          url: 'https://cdn.example.test/subs/en.vtt',
          label: 'English',
          language: 'english',
          isDefault: true,
        ),
        RemoteSubtitleTrack(
          url: 'https://cdn.example.test/subs/es.vtt',
          label: 'Spanish',
          language: 'spanish',
        ),
        RemoteSubtitleTrack(
          url: 'https://cdn.example.test/subs/es-419.vtt',
          label: 'Spanish (- Latin American)',
          language: 'spanish (- latin american)',
        ),
      ],
    );

    expect(
      selectRemoteSubtitleTrack(stream)?.url,
      'https://cdn.example.test/subs/es-419.vtt',
    );
    expect(
      preferredRemoteSubtitleTracks(stream.subtitleTracks)
          .map((track) => track.url),
      [
        'https://cdn.example.test/subs/es-419.vtt',
        'https://cdn.example.test/subs/es.vtt',
        'https://cdn.example.test/subs/en.vtt',
      ],
    );
  });

  test('selects requested remote subtitle track by stable key', () {
    const alternate = RemoteSubtitleTrack(
      url: 'https://cdn.example.test/subs/alternate.vtt',
      label: 'Alterno',
      language: 'es',
      mimeType: 'text/vtt',
    );
    final stream = animeAv1ZillaStream.copyWith(
      subtitleTracks: const [
        alternate,
        RemoteSubtitleTrack(
          url: 'https://cdn.example.test/subs/default.vtt',
          label: 'Principal',
          language: 'es',
          mimeType: 'text/vtt',
          isDefault: true,
        ),
      ],
    );

    expect(
      selectRemoteSubtitleTrack(
        stream,
        selectedKey: remoteSubtitleTrackKey(alternate),
      )?.url,
      alternate.url,
    );
    expect(remoteSubtitleTrackLabel(alternate), 'Alterno [ES]');
  });

  test('formats remote server labels for fallback status', () {
    expect(remoteServerLabel('streamwish'), 'StreamWish');
    expect(remoteServerLabel('mixdrop'), 'MixDrop');
    expect(remoteServerLabel('yourupload'), 'YourUpload');
    expect(remoteServerLabel('stape'), 'Stape');
    expect(remoteServerLabel('ani-pm'), 'Ani.pm Direct');
    expect(remoteServerLabel('helios-2'), 'Helios 2');
    expect(remoteServerLabel('helios-hd-1'), 'Helios HD 1');
    expect(remoteServerLabel('custom'), 'custom');
  });

  test('orders ani.pm servers like the provider menu', () {
    final servers = [
      'onyx-1',
      'lyra-4',
      'helios-hd-1',
      'ani-pm',
      'astra',
      'comet-1',
    ]..sort(compareAniPmServerMenuOrder);

    expect(servers, [
      'ani-pm',
      'helios-hd-1',
      'lyra-4',
      'comet-1',
      'onyx-1',
      'astra',
    ]);
  });
}
