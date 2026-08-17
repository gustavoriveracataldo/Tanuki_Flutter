import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/services/remote_catalog_service.dart';

void main() {
  test('searches JustAnime and creates the complete episode list', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      expect(request.headers['origin'], 'https://www.justanime.to');
      return http.Response(
          jsonEncode({
            'results': [
              {
                'id': 670,
                'title': {'english': null, 'romaji': 'Lamune'},
                'cover': 'https://img.test/lamune.jpg',
                'episodes': 12,
                'type': 'TV',
                'year': 2005,
              }
            ]
          }),
          200);
    }));

    final results = await service.searchJustAnime('lamune', releaseYear: 2005);
    final series = results.single.toSeries(existingNames: const []);

    expect(results.single.provider, RemoteProvider.justAnime);
    expect(results.single.slug, '670');
    expect(series.episodes, hasLength(12));
    expect(series.episodes.last.episodeNumber, 12);
  });

  test('builds JustAnime URLs with provider slugs for accented titles',
      () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      expect(request.url.queryParameters['query'], 'pokemon 3');
      return http.Response(
          jsonEncode({
            'results': [
              {
                'id': 1118,
                'title': {
                  'english': 'Pok\u00e9mon 3: The Movie',
                  'romaji': 'Pocket Monsters: Kesshoutou no Teiou ENTEI',
                },
                'cover': 'https://img.test/pokemon-3.jpg',
                'episodes': 1,
                'type': 'MOVIE',
                'year': 2000,
              }
            ]
          }),
          200);
    }));

    final results =
        await service.searchJustAnime('pokemon 3', releaseYear: 2000);

    expect(results.single.seriesUrl,
        'https://www.justanime.to/anime/1118/pokmon-3-the-movie');
    expect(results.single.watchUrl,
        'https://www.justanime.to/anime/1118/pokmon-3-the-movie');
  });

  test('resolves Neko video and adds proxied Momo subtitles', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path.endsWith('/megaplay')) {
        return http.Response(
            jsonEncode({
              'sub': {
                'subtitles': [
                  {
                    'file': 'https://subs.test/spanish.vtt',
                    'label': 'Spanish',
                    'default': true,
                  }
                ]
              },
              'dub': null,
            }),
            200);
      }
      if (request.url.path.endsWith('/anineko/sub/hd1')) {
        return http.Response(
            jsonEncode({
              'sources': [
                {
                  'url': 'https://vivibebe.site/video/master.m3u8',
                  'quality': '720p',
                  'isM3U8': true,
                }
              ],
              'subtitles': [],
            }),
            200);
      }
      if (request.url.host == 'neko.justanime.to') {
        return http.Response(
          '#EXTM3U\n#EXTINF:10,\n'
          'https://neko.justanime.to/m3u8-proxy?url=segment\n',
          200,
          headers: {'content-type': 'application/vnd.apple.mpegurl'},
        );
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Lamune',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Episode 1',
      relativePath: 'Episode 1',
      filePath: 'https://www.justanime.to/anime/670/lamune',
      sourceType: SourceType.remote,
      provider: RemoteProvider.justAnime,
      slug: '670',
      watchUrl: 'https://www.justanime.to/anime/670/lamune',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
      preferredServer: 'neko',
    );

    expect(stream?.provider, RemoteProvider.justAnime);
    expect(stream?.server, 'neko');
    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, startsWith('http://127.0.0.1:'));
    final localManifest = await http.read(Uri.parse(stream!.playbackUrl));
    expect(localManifest, contains('http://127.0.0.1:'));
    expect(localManifest, isNot(contains('https://neko.justanime.to/')));
    expect(stream.subtitleTracks.single.label, 'Spanish');
    expect(stream.subtitleTracks.single.url,
        contains('momo.calm-koi.workers.dev/proxy'));
  });

  test('resolves Momo video through JustAnime proxy headers', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path.endsWith('/megaplay')) {
        return http.Response(
            jsonEncode({
              'sub': {
                'sources': [
                  {
                    'url': 'https://cdn.mewstream.buzz/anime/master.m3u8',
                    'quality': 'auto',
                    'isM3U8': true,
                  }
                ],
                'headers': {'Referer': 'https://megaplay.buzz/'},
                'subtitles': [
                  {
                    'file': 'https://subs.test/english.vtt',
                    'label': 'English',
                    'default': true,
                  }
                ],
              },
              'dub': null,
            }),
            200);
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Lamune',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Episode 1',
      relativePath: 'Episode 1',
      filePath: 'https://www.justanime.to/anime/670/lamune',
      sourceType: SourceType.remote,
      provider: RemoteProvider.justAnime,
      slug: '670',
      watchUrl: 'https://www.justanime.to/anime/670/lamune',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
      preferredServer: 'megaplay',
    );

    expect(stream?.provider, RemoteProvider.justAnime);
    expect(stream?.server, 'momo');
    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, startsWith('https://momo.justanime.to/proxy?'));
    final playbackUri = Uri.parse(stream!.playbackUrl);
    expect(playbackUri.queryParameters['url'],
        'https://cdn.mewstream.buzz/anime/master.m3u8');
    expect(jsonDecode(playbackUri.queryParameters['headers']!)['Referer'],
        'https://megaplay.buzz/');
    expect(stream.subtitleTracks.single.label, 'English');
    expect(stream.subtitleTracks.single.url,
        contains('momo.calm-koi.workers.dev/proxy'));
  });

  test('uses Gigi as the automatic JustAnime server', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path.endsWith('/animegg')) {
        return http.Response(
            jsonEncode({
              'sub': {
                'sources': [
                  {
                    'url': 'https://www.animegg.org/play/454570/video.mp4',
                    'quality': '360p',
                    'isM3U8': false,
                    'headers': {'Referer': 'https://www.animegg.org/'},
                  },
                  {
                    'url': 'https://www.animegg.org/play/454566/video.mp4',
                    'quality': '720p',
                    'isM3U8': false,
                    'headers': {'Referer': 'https://www.animegg.org/'},
                  }
                ],
                'tracks': [],
              },
              'dub': null,
            }),
            200);
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Lamune',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Episode 1',
      relativePath: 'Episode 1',
      filePath: 'https://www.justanime.to/anime/670/lamune',
      sourceType: SourceType.remote,
      provider: RemoteProvider.justAnime,
      slug: '670',
      watchUrl: 'https://www.justanime.to/anime/670/lamune',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
    );

    expect(stream?.server, 'gigi');
    expect(stream?.playbackKind, 'http');
    expect(stream?.playbackUrl, startsWith('http://127.0.0.1:'));
  });

  test('persists JustAnime audio and server preferences', () {
    const preference = SeriesPlaybackPreference(
      provider: RemoteProvider.justAnime,
      justAnimeMode: 'dub',
      justAnimeServer: 'gigi',
    );
    final restored = SeriesPlaybackPreference.fromJson(preference.toJson());

    expect(restored.provider, RemoteProvider.justAnime);
    expect(restored.justAnimeMode, 'dub');
    expect(restored.justAnimeServer, 'gigi');
  });
}
