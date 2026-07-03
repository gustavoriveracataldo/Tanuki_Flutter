import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/ui/player_screen.dart';

void main() {
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
    expect(remoteServerLabel('custom'), 'custom');
  });
}
