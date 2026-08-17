import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/services/remote_catalog_service.dart';
import 'package:toonami_viernes_noche_flutter/src/ui/player_screen.dart';

void main() {
  test('searches ani.pm and preserves its ani/anime route', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      expect(request.url.path, '/api/anime/search');
      return http.Response(
        jsonEncode({
          'items': [
            {
              'id': 1516,
              'source': 'anilist',
              'title': 'Kirarin Revolution',
              'poster': 'https://img.test/kirarin.jpg',
              'year': 2006,
              'episodeCount': 153,
              'anilistId': '1516',
            },
            {
              'id': 7421,
              'source': 'anikoto',
              'title': 'Lamune',
              'year': 2005,
              'episodeCount': 12,
            },
          ],
        }),
        200,
      );
    }));

    final results = await service.searchAniPm('anime');

    expect(results.map((item) => item.slug), ['ani:1516', 'anime:7421']);
    expect(results.first.provider, RemoteProvider.aniPm);
    expect(results.first.toSeries(existingNames: const []).episodes,
        hasLength(153));
  });

  test('keeps ani.pm search results when provider year differs by one',
      () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      expect(request.url.path, '/api/anime/search');
      expect(request.url.queryParameters['q'], 'Delicious in Dungeon');
      return http.Response(
        jsonEncode({
          'items': [
            {
              'id': 6069,
              'source': 'anikoto',
              'title': 'Delicious in Dungeon',
              'native': 'Dungeon Meshi',
              'year': 2023,
              'episodeCount': 24,
              'anilistId': '153518',
            },
          ],
        }),
        200,
      );
    }));

    final results =
        await service.searchAniPm('Delicious in Dungeon', releaseYear: 2024);

    expect(results.single.slug, 'anime:6069');
    expect(results.single.catalogId, 153518);
  });

  test('resolves dynamic ani.pm server and its own subtitle track', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/ani/182317') {
        return http.Response(
          jsonEncode({
            'title': 'The Dangers in My Heart: The Movie',
            'year': 2026,
            'anilistId': '182317',
            'malId': '59985',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        expect(request.url.queryParameters['ep'], '1');
        expect(request.url.queryParameters['direct'], '1');
        expect(request.url.queryParameters['phase'], 'all');
        expect(request.url.queryParameters['channel'], 'all');
        return http.Response(
          jsonEncode({
            'sub': [
              {
                'provider': 'Lyra',
                'name': 'Lyra · 11',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=video',
                'priority': 108,
                'subtitle': 'soft',
                'tracks': [
                  {
                    'url': '/api/anime/src/vtt?t=sub',
                    'label': 'English',
                    'default': true,
                  }
                ],
              },
              {
                'provider': 'Nova',
                'name': 'Nova · 1',
                'kind': 'file',
                'url': '/api/anime/src/file?t=nova',
                'priority': 114,
              },
            ],
            'dub': [],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'The Dangers in My Heart: The Movie',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Episode 1',
      relativePath: 'Episode 1',
      filePath: 'https://ani.pm/ani/182317',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'ani:182317',
      watchUrl: 'https://ani.pm/ani/182317',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
      preferredServer: 'lyra-11',
    );

    expect(stream?.provider, RemoteProvider.aniPm);
    expect(stream?.server, 'lyra-11');
    expect(stream?.playbackKind, 'hls');
    expect(stream?.availableModes, containsAll(['lyra-11', 'nova-1']));
    expect(stream?.subtitleTracks.single.label, 'English');
    expect(stream?.subtitleTracks.single.url,
        'https://ani.pm/api/anime/src/vtt?t=sub');
  });

  test('prefers Lyra over Comet for automatic ani.pm selection', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/series/8860') {
        return http.Response(
          jsonEncode({
            'title': 'Trapped in a Dating Sim Season 2',
            'year': 2026,
            'anilistId': '159309',
            'malId': '54000',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        return http.Response(
          jsonEncode({
            'sub': [
              {
                'provider': 'Comet',
                'name': 'Comet · 1',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=comet',
                'priority': 40000,
                'subtitle': 'soft',
              },
              {
                'provider': 'Lyra',
                'name': 'Lyra · 6',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=lyra',
                'priority': 108,
                'subtitle': 'soft',
              },
            ],
            'dub': [],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Trapped in a Dating Sim Season 2',
      episodeIndex: 5,
      episodeNumber: 6,
      displayName: 'Episode 6',
      relativePath: 'Episode 6',
      filePath: 'https://ani.pm/anime/8860',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'anime:8860',
      watchUrl: 'https://ani.pm/anime/8860',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
    );

    expect(stream?.server, 'lyra-6');
    expect(stream?.playbackUrl, 'https://ani.pm/api/anime/src/hls?t=lyra');
  });

  test('prefers Ani.pm Direct HLS when the direct server is available',
      () async {
    var epDirectRequests = 0;
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/series/6069') {
        return http.Response(
          jsonEncode({
            'title': 'Delicious in Dungeon',
            'year': 2023,
            'anilistId': '153518',
            'malId': '52701',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        expect(request.url.queryParameters['direct'], '1');
        return http.Response(
          jsonEncode({
            'sub': [
              {
                'provider': 'Lyra',
                'name': 'Lyra · 4',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=lyra',
                'priority': 108,
                'subtitle': 'soft',
                'tracks': [
                  {
                    'src': '/api/anime/src/vtt?t=lyra-es',
                    'title': 'Spanish',
                    'srclang': 'es',
                  }
                ],
              },
              {
                'provider': 'Ani.pm',
                'name': 'Direct',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=direct',
                'priority': 108,
                'subtitle': 'soft',
                'tracks': [
                  {
                    'src': '/api/anime/src/vtt?t=direct-es-419',
                    'title': 'Spanish (- Latin American)',
                    'srclang': 'es-419',
                  }
                ],
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/ep-servers/6069/3') {
        return http.Response(
          jsonEncode({
            'servers': [
              {
                'id': 'helios-hd-token',
                'name': 'HD-1',
                'type': 'sub',
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/ep-direct') {
        epDirectRequests += 1;
        return http.Response('should not be used before Ani.pm Direct', 500);
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Dungeon Meshi',
      episodeIndex: 2,
      episodeNumber: 3,
      displayName: 'Episode 3',
      relativePath: 'Episode 3',
      filePath: 'https://ani.pm/anime/6069',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'anime:6069',
      watchUrl: 'https://ani.pm/anime/6069',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
    );

    expect(stream?.server, 'ani-pm');
    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, 'https://ani.pm/api/anime/src/hls?t=direct');
    expect(stream?.subtitleTracks.single.language, 'es-419');
    expect(epDirectRequests, 0);
  });

  test('uses Ani.pm Direct from playback bootstrap and keeps server inventory',
      () async {
    var legacyServerRequests = 0;
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/series/6069') {
        return http.Response(
          jsonEncode({
            'id': 6069,
            'source': 'anikoto',
            'title': 'Delicious in Dungeon',
            'year': 2024,
            'anilistId': '153518',
            'malId': '52701',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/playback-bootstrap/anikoto/6069') {
        expect(request.url.queryParameters['ep'], '3');
        expect(request.url.queryParameters['lang'], 'sub');
        return http.Response(
          jsonEncode({
            'helios': {
              'path': 'ani/153518/3/sub',
              'm3u8': '/api/anime/src/hls?t=bootstrap-direct',
              'tracks': [
                {
                  'url': '/api/anime/src/vtt?t=direct-es-419',
                  'label': 'Spanish (- Latin American)',
                  'language': 'es-419',
                }
              ],
            },
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        legacyServerRequests += 1;
        return http.Response(
          jsonEncode({
            'sub': [
              {
                'provider': 'Lyra',
                'name': 'Lyra · 4',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=lyra',
                'priority': 108,
                'subtitle': 'soft',
              },
              {
                'provider': 'Onyx',
                'name': 'Onyx · 1',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=onyx',
                'priority': 105,
              },
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Dungeon Meshi',
      episodeIndex: 2,
      episodeNumber: 3,
      displayName: 'Episode 3',
      relativePath: 'Episode 3',
      filePath: 'https://ani.pm/anime/6069',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'anime:6069',
      watchUrl: 'https://ani.pm/anime/6069',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
    );

    expect(stream?.server, 'ani-pm');
    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl,
        'https://ani.pm/api/anime/src/hls?t=bootstrap-direct');
    expect(stream?.pageUrl, 'https://megaplay.buzz/stream/ani/153518/3/sub');
    expect(stream?.subtitleTracks.single.language, 'es-419');
    expect(stream?.availableModes, containsAll(['ani-pm', 'lyra-4', 'onyx-1']));
    expect(legacyServerRequests, 1);
  });

  test('waits for late Ani.pm Direct from a partial inventory', () async {
    var serverRequests = 0;
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/series/6069') {
        return http.Response(
          jsonEncode({
            'id': 6069,
            'source': 'anikoto',
            'title': 'Delicious in Dungeon',
            'year': 2024,
            'anilistId': '153518',
            'malId': '52701',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        serverRequests += 1;
        if (serverRequests == 1) {
          return http.Response(
            jsonEncode({
              'partial': true,
              'retryAfterMs': 750,
              'sub': [
                {
                  'provider': 'Lyra',
                  'name': 'Lyra · 4',
                  'kind': 'hls',
                  'url': '/api/anime/src/hls?t=lyra',
                  'priority': 108,
                  'subtitle': 'soft',
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'partial': false,
            'sub': [
              {
                'provider': 'Ani.pm',
                'name': 'Direct',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=direct',
                'priority': 108,
                'subtitle': 'soft',
              },
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Dungeon Meshi',
      episodeIndex: 2,
      episodeNumber: 3,
      displayName: 'Episode 3',
      relativePath: 'Episode 3',
      filePath: 'https://ani.pm/anime/6069',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'anime:6069',
      watchUrl: 'https://ani.pm/anime/6069',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
    );

    expect(serverRequests, 2);
    expect(stream?.server, 'ani-pm');
    expect(stream?.playbackUrl, 'https://ani.pm/api/anime/src/hls?t=direct');
    expect(stream?.availableModes, containsAll(['lyra-4', 'ani-pm']));
  });

  test('adds Helios direct servers without automatic preference', () async {
    var epDirectRequests = 0;
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/series/6069') {
        return http.Response(
          jsonEncode({
            'id': 6069,
            'source': 'anikoto',
            'title': 'Delicious in Dungeon',
            'year': 2024,
            'anilistId': '153518',
            'malId': '52701',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        return http.Response(
          jsonEncode({
            'sub': [
              {
                'provider': 'Lyra',
                'name': 'Lyra · 4',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=lyra',
                'priority': 108,
                'subtitle': 'soft',
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/ep-servers/6069/3') {
        return http.Response(
          jsonEncode({
            'servers': [
              {
                'id': 'helios-hd-token',
                'name': 'HD-1',
                'type': 'sub',
              },
              {
                'id': 'helios-dub-token',
                'name': 'HD-1',
                'type': 'dub',
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/ep-direct') {
        epDirectRequests += 1;
        return http.Response('helios should not be opened automatically', 500);
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Dungeon Meshi',
      episodeIndex: 2,
      episodeNumber: 3,
      displayName: 'Episode 3',
      relativePath: 'Episode 3',
      filePath: 'https://ani.pm/anime/6069',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'anime:6069',
      watchUrl: 'https://ani.pm/anime/6069',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
    );

    expect(stream?.server, 'lyra-4');
    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, 'https://ani.pm/api/anime/src/hls?t=lyra');
    expect(stream?.availableModes, containsAll(['helios-hd-1', 'lyra-4']));
    expect(epDirectRequests, 0);
  });

  test('uses Helios direct server when explicitly selected', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/series/6069') {
        return http.Response(
          jsonEncode({
            'id': 6069,
            'source': 'anikoto',
            'title': 'Delicious in Dungeon',
            'year': 2024,
            'anilistId': '153518',
            'malId': '52701',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        return http.Response(
          jsonEncode({
            'sub': [
              {
                'provider': 'Lyra',
                'name': 'Lyra · 4',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=lyra',
                'priority': 108,
                'subtitle': 'soft',
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/ep-servers/6069/3') {
        return http.Response(
          jsonEncode({
            'servers': [
              {
                'id': 'helios-hd-token',
                'name': 'HD-1',
                'type': 'sub',
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/ep-direct') {
        expect(request.url.queryParameters['id'], 'helios-hd-token');
        expect(request.url.queryParameters['series'], '6069');
        expect(request.url.queryParameters['ep'], '3');
        expect(request.url.queryParameters['channel'], 'sub');
        return http.Response(
          jsonEncode({
            'm3u8': '/api/anime/src/hls?t=helios',
            'tracks': [
              {
                'url': '/api/anime/src/vtt?t=helios-es-419',
                'label': 'Spanish (- Latin American)',
                'language': 'es-419',
              }
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Dungeon Meshi',
      episodeIndex: 2,
      episodeNumber: 3,
      displayName: 'Episode 3',
      relativePath: 'Episode 3',
      filePath: 'https://ani.pm/anime/6069',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'anime:6069',
      watchUrl: 'https://ani.pm/anime/6069',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
      preferredServer: 'helios-hd-1',
    );

    expect(stream?.server, 'helios-hd-1');
    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, 'https://ani.pm/api/anime/src/hls?t=helios');
    expect(stream?.subtitleTracks.single.language, 'es-419');
  });

  test('does not let a saved Comet preference override Lyra', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/series/6069') {
        return http.Response(
          jsonEncode({
            'title': 'Delicious in Dungeon',
            'year': 2023,
            'anilistId': '153518',
            'malId': '52701',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        return http.Response(
          jsonEncode({
            'sub': [
              {
                'provider': 'Comet',
                'name': 'Comet · 1',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=comet',
                'priority': 9999,
              },
              {
                'provider': 'Lyra',
                'name': 'Lyra · 4',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=lyra',
                'priority': 108,
              },
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Dungeon Meshi',
      episodeIndex: 2,
      episodeNumber: 3,
      displayName: 'Episode 3',
      relativePath: 'Episode 3',
      filePath: 'https://ani.pm/anime/6069',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'anime:6069',
      watchUrl: 'https://ani.pm/anime/6069',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
      preferredServer: 'comet-1',
    );

    expect(stream?.server, 'lyra-4');
  });

  test('retries cold partial ani.pm server inventory', () async {
    var serverRequests = 0;
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/series/6069') {
        return http.Response(
          jsonEncode({
            'title': 'Delicious in Dungeon',
            'year': 2023,
            'anilistId': '153518',
            'malId': '52701',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        serverRequests += 1;
        if (serverRequests == 1) {
          return http.Response(
            jsonEncode({
              'sub': [],
              'dub': [],
              'phase': 'all',
              'inventory': 'cold',
              'partial': true,
              'retryAfterMs': 1,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'sub': [
              {
                'provider': 'Lyra',
                'name': 'Lyra · 1',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=lyra',
                'priority': 108,
              },
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Dungeon Meshi',
      episodeIndex: 2,
      episodeNumber: 3,
      displayName: 'Episode 3',
      relativePath: 'Episode 3',
      filePath: 'https://ani.pm/anime/6069',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'anime:6069',
      watchUrl: 'https://ani.pm/anime/6069',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
    );

    expect(serverRequests, 2);
    expect(stream?.server, 'lyra-1');
  });

  test('prefers ani.pm Lyra sources with extractable subtitles', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/series/6069') {
        return http.Response(
          jsonEncode({
            'title': 'Delicious in Dungeon',
            'year': 2023,
            'anilistId': '153518',
            'malId': '52701',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        return http.Response(
          jsonEncode({
            'sub': [
              {
                'provider': 'Lyra',
                'name': 'Lyra · 1',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=hard',
                'priority': 108,
                'subtitle': 'hard',
              },
              {
                'provider': 'Lyra',
                'name': 'Lyra · 4',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=soft',
                'priority': 108,
                'subtitle': 'soft',
                'tracks': [
                  {
                    'src': '/api/anime/src/vtt?t=es-419',
                    'title': 'Spanish (- Latin American)',
                    'srclang': 'es-419',
                  }
                ],
              },
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'Dungeon Meshi',
      episodeIndex: 2,
      episodeNumber: 3,
      displayName: 'Episode 3',
      relativePath: 'Episode 3',
      filePath: 'https://ani.pm/anime/6069',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'anime:6069',
      watchUrl: 'https://ani.pm/anime/6069',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
    );

    expect(stream?.server, 'lyra-4');
    expect(stream?.subtitleTracks.single.language, 'es-419');
    expect(stream?.subtitleTracks.single.url,
        'https://ani.pm/api/anime/src/vtt?t=es-419');
  });

  test('persists ani.pm audio and dynamic server preferences', () {
    const preference = SeriesPlaybackPreference(
      provider: RemoteProvider.aniPm,
      aniPmMode: 'dub',
      aniPmServer: 'pulse-2',
    );
    final restored = SeriesPlaybackPreference.fromJson(preference.toJson());

    expect(restored.provider, RemoteProvider.aniPm);
    expect(restored.aniPmMode, 'dub');
    expect(restored.aniPmServer, 'pulse-2');
  });

  test('parses Pulse ASS subtitles for the player overlay', () {
    final cues = parseRemoteCaptionCues('''
[Script Info]
Title: Example
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:01:02.34,0:01:05.60,Default,,0,0,0,,{\\i1}Hello\\Nworld
''');

    expect(cues, hasLength(1));
    expect(cues.single.start,
        const Duration(minutes: 1, seconds: 2, milliseconds: 340));
    expect(cues.single.end,
        const Duration(minutes: 1, seconds: 5, milliseconds: 600));
    expect(cues.single.text, 'Hello\nworld');
  });
}
