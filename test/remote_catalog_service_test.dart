import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/services/remote_catalog_service.dart';
import 'package:toonami_viernes_noche_flutter/src/services/remote_web_resolver.dart';

void main() {
  test('fetches a supported random Jikan anime candidate', () async {
    var calls = 0;
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        calls += 1;
        expect(request.url.toString(), 'https://api.jikan.moe/v4/random/anime');
        final type = calls == 1 ? 'Music' : 'TV';
        return http.Response(
          '''
          {
            "data": {
              "mal_id": 123,
              "title": "Random Demo",
              "url": "https://myanimelist.net/anime/123",
              "type": "$type",
              "episodes": 12,
              "year": 2024,
              "images": {
                "jpg": {
                  "large_image_url": "https://cdn.example.test/poster.jpg"
                }
              },
              "trailer": {
                "youtube_id": "demo123"
              }
            }
          }
          ''',
          200,
          request: request,
        );
      }),
    );

    final candidate = await service.fetchCatalogRandomFallback();

    expect(calls, 2);
    expect(candidate?.provider, RemoteProvider.catalog);
    expect(candidate?.title, 'Random Demo');
    expect(candidate?.format, 'TV');
    expect(candidate?.episodeCount, 12);
    expect(candidate?.trailerUrl, 'https://www.youtube.com/watch?v=demo123');
  });

  test('normalizes Jikan youtube-nocookie trailer embeds', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://api.jikan.moe/v4/random/anime');
        return http.Response(
          '''
          {
            "data": {
              "mal_id": 123,
              "title": "Embed Demo",
              "url": "https://myanimelist.net/anime/123",
              "type": "TV",
              "episodes": 12,
              "images": {
                "jpg": {
                  "large_image_url": "https://cdn.example.test/poster.jpg"
                }
              },
              "trailer": {
                "embed_url": "https://www.youtube-nocookie.com/embed/ODxfIvSgWuo?enablejsapi=1&wmode=opaque&autoplay=1"
              }
            }
          }
          ''',
          200,
          request: request,
        );
      }),
    );

    final candidate = await service.fetchCatalogRandomFallback();

    expect(
      candidate?.trailerUrl,
      'https://www.youtube.com/watch?v=ODxfIvSgWuo',
    );
  });

  test('aggregate search skips disabled AnimeFLV provider', () async {
    final requestedHosts = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedHosts.add(request.url.host);
        expect(request.url.host, isNot('www4.animeflv.net'));
        if (request.url.host == 'api.jikan.moe') {
          return http.Response('{"data":[]}', 200, request: request);
        }
        return http.Response('', 200, request: request);
      }),
    );

    final results = await service.search('demo');

    expect(results, isEmpty);
    expect(requestedHosts, contains('animeav1.com'));
    expect(requestedHosts, contains('jkanime.net'));
    expect(requestedHosts, contains('latanime.org'));
    expect(requestedHosts, isNot(contains('www4.animeflv.net')));
  });

  test('fetches Jikan catalog recommendations as candidates', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        expect(request.url.toString(),
            'https://api.jikan.moe/v4/anime/123/recommendations');
        return http.Response(
          '''
          {
            "data": [
              {
                "entry": {
                  "mal_id": 456,
                  "title": "Related Demo",
                  "url": "https://myanimelist.net/anime/456",
                  "type": "TV",
                  "episodes": 24,
                  "year": 2025,
                  "images": {
                    "jpg": {
                      "large_image_url": "https://cdn.example.test/related.jpg"
                    }
                  }
                }
              }
            ]
          }
          ''',
          200,
          request: request,
        );
      }),
    );

    final results = await service.fetchCatalogRecommendations(123);

    expect(results, hasLength(1));
    expect(results.first.provider, RemoteProvider.catalog);
    expect(results.first.catalogId, 456);
    expect(results.first.title, 'Related Demo');
  });

  test('discovers Jikan catalog by season and type', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        expect(request.url.path, '/v4/seasons/2026/spring');
        expect(request.url.queryParameters['filter'], 'tv');
        expect(request.url.queryParameters['limit'], '25');
        return http.Response(
          '''
          {
            "data": [
              {
                "mal_id": 789,
                "title": "Spring Demo",
                "url": "https://myanimelist.net/anime/789",
                "type": "TV",
                "episodes": 12,
                "year": 2026,
                "aired": {"from": "2026-04-05T00:00:00+00:00"},
                "images": {"jpg": {"large_image_url": "https://cdn.example.test/spring.jpg"}}
              }
            ]
          }
          ''',
          200,
          request: request,
        );
      }),
    );

    final results = await service.discoverCatalogBySeason(
      season: 'spring',
      year: 2026,
      type: 'tv',
    );

    expect(results, hasLength(1));
    expect(results.first.title, 'Spring Demo');
    expect(results.first.airDateIso, '2026-04-05T00:00:00+00:00');
  });

  test('discovers Jikan catalog by year range', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        expect(request.url.path, '/v4/anime');
        expect(request.url.queryParameters['start_date'], '1990-01-01');
        expect(request.url.queryParameters['end_date'], '2000-12-31');
        expect(request.url.queryParameters['type'], 'movie');
        return http.Response(
          '''
          {
            "data": [
              {
                "mal_id": 987,
                "title": "Retro Movie",
                "url": "https://myanimelist.net/anime/987",
                "type": "Movie",
                "episodes": 1,
                "year": 1998,
                "aired": {"from": "1998-08-01T00:00:00+00:00"},
                "images": {"jpg": {"large_image_url": "https://cdn.example.test/retro.jpg"}}
              }
            ]
          }
          ''',
          200,
          request: request,
        );
      }),
    );

    final results = await service.discoverCatalogByYearRange(
      startYear: 1990,
      endYear: 2000,
      type: 'movie',
    );

    expect(results.single.releaseYear, 1998);
    expect(results.single.format, 'Movie');
  });

  test('enriches imported catalog series with TMDB and Fanart visuals',
      () async {
    final calls = <String>[];
    final service = RemoteCatalogService(
      tmdbApiKey: 'tmdb-key',
      fanartApiKey: 'fanart-key',
      client: MockClient((request) async {
        calls.add(request.url.toString());
        if (request.url.host == 'api.themoviedb.org') {
          expect(request.url.queryParameters['api_key'], 'tmdb-key');
        }
        if (request.url.host == 'webservice.fanart.tv') {
          expect(request.url.queryParameters['api_key'], 'fanart-key');
        }
        return switch (request.url.path) {
          '/3/search/tv' => http.Response(
              jsonEncode({
                'results': [
                  {
                    'id': 77,
                    'name': 'Demo Anime',
                    'original_name': 'Demo Anime JP',
                    'first_air_date': '2024-04-05',
                    'poster_path': '/search-poster.jpg',
                    'backdrop_path': '/search-backdrop.jpg',
                  }
                ],
              }),
              200,
              request: request,
            ),
          '/3/tv/77' => http.Response(
              jsonEncode({
                'id': 77,
                'name': 'Demo Anime',
                'original_name': 'Demo Anime JP',
                'overview': 'Descripcion TMDB',
                'poster_path': '/poster.jpg',
                'backdrop_path': '/backdrop.jpg',
                'content_ratings': {
                  'results': [
                    {'iso_3166_1': 'US', 'rating': 'TV-14'}
                  ],
                },
                'external_ids': {'tvdb_id': 1234},
                'seasons': [
                  {
                    'season_number': 1,
                    'episode_count': 1,
                    'air_date': '2024-04-05'
                  }
                ],
                'aggregate_credits': {
                  'cast': [
                    {
                      'name': 'Actor Demo',
                      'roles': [
                        {'character': 'Heroe Demo'}
                      ]
                    }
                  ],
                },
                'videos': {
                  'results': [
                    {
                      'site': 'YouTube',
                      'key': 'trail123',
                      'type': 'Trailer',
                      'official': true,
                      'iso_639_1': 'es',
                    }
                  ],
                },
              }),
              200,
              request: request,
            ),
          '/3/tv/77/season/1' => http.Response(
              jsonEncode({
                'episodes': [
                  {
                    'episode_number': 1,
                    'name': 'El inicio',
                    'overview': 'Resumen del capitulo',
                    'still_path': '/still.jpg',
                    'runtime': 24,
                    'air_date': '2024-04-05',
                  }
                ],
              }),
              200,
              request: request,
            ),
          '/3/tv/77/images' => http.Response(
              jsonEncode({
                'logos': [
                  {
                    'file_path': '/logo.png',
                    'iso_639_1': 'ja',
                    'vote_count': 7,
                    'width': 800,
                  }
                ],
              }),
              200,
              request: request,
            ),
          '/v3/tv/1234' => http.Response(
              jsonEncode({
                'seasonposter': [
                  {
                    'url': 'https://fanart.test/season.jpg',
                    'lang': 'es',
                    'likes': '5',
                  }
                ],
                'showbackground': [
                  {
                    'url': 'https://fanart.test/background.jpg',
                    'lang': 'es',
                    'likes': '3',
                  }
                ],
              }),
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final series = await service.buildImportSeries(
      const RemoteSearchCandidate(
        provider: RemoteProvider.catalog,
        slug: '123',
        title: 'Demo Anime',
        watchUrl: 'https://myanimelist.net/anime/123',
        imageUrl: 'https://jikan.test/poster.jpg',
        episodeCount: 1,
        format: 'TV',
        releaseYear: 2024,
        catalogId: 123,
      ),
      existingNames: const [],
    );

    expect(calls.any((url) => url.contains('/3/search/tv')), isTrue);
    expect(calls.any((url) => url.contains('/v3/tv/1234')), isTrue);
    expect(series.logoUrl, 'https://image.tmdb.org/t/p/original/logo.png');
    expect(series.imageUrl, 'https://fanart.test/season.jpg');
    expect(
        series.backgroundUrl, 'https://image.tmdb.org/t/p/w1280/backdrop.jpg');
    expect(series.description, 'Descripcion TMDB');
    expect(series.rating, 'TV-14');
    expect(series.trailerUrl, 'https://www.youtube.com/watch?v=trail123');
    expect(series.cast, ['Actor Demo | Heroe Demo']);
    expect(series.episodes.single.displayName, 'El inicio');
    expect(series.episodes.single.description, 'Resumen del capitulo');
    expect(series.episodes.single.imageUrl,
        'https://image.tmdb.org/t/p/w780/still.jpg');
    expect(series.episodes.single.durationLabel, '24 min');
    expect(series.episodes.single.airDateIso, '2024-04-05');
  });

  test('enriches imported catalog series with Jikan episodes and cast',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.path) {
          '/v4/anime/222/episodes' => http.Response(
              jsonEncode({
                'data': [
                  {
                    'mal_id': 1,
                    'number': 1,
                    'title': 'La llegada',
                    'synopsis': 'Resumen desde Jikan',
                    'duration': '25 min',
                    'aired': '2024-05-06T00:00:00+00:00',
                    'images': {
                      'jpg': {
                        'image_url': 'https://jikan.test/episode-1.jpg',
                      }
                    },
                  }
                ],
                'pagination': {
                  'last_visible_page': 1,
                  'has_next_page': false,
                },
              }),
              200,
              request: request,
            ),
          '/v4/anime/222/characters' => http.Response(
              jsonEncode({
                'data': [
                  {
                    'character': {'name': 'Personaje Demo'},
                    'role': 'Main',
                  }
                ],
              }),
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final series = await service.buildImportSeries(
      const RemoteSearchCandidate(
        provider: RemoteProvider.catalog,
        slug: '222',
        title: 'Catalog Demo',
        watchUrl: 'https://myanimelist.net/anime/222',
        imageUrl: 'https://jikan.test/poster.jpg',
        episodeCount: 1,
        format: 'TV',
        releaseYear: 2024,
        catalogId: 222,
      ),
      existingNames: const [],
    );

    expect(series.cast, ['Personaje Demo | Main']);
    expect(series.episodes.single.displayName, 'La llegada');
    expect(series.episodes.single.description, 'Resumen desde Jikan');
    expect(series.episodes.single.durationLabel, '25 min');
    expect(series.episodes.single.airDateIso, '2024-05-06T00:00:00+00:00');
    expect(series.episodes.single.imageUrl, 'https://jikan.test/episode-1.jpg');
  });

  test('resolves a catalog episode through provider search', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          String url when url.startsWith('https://jkanime.net/directorio') =>
            http.Response(
              '''
              <script>
                var animes = {"data":[
                  {
                    "url":"https://jkanime.net/demo/",
                    "slug":"demo",
                    "title":"Demo Anime",
                    "type":"TV",
                    "image":"https://jkanime.test/demo.jpg"
                  }
                ]};
              </script>
              ''',
              200,
              request: request,
            ),
          'https://jkanime.net/demo/' => http.Response(
              '''
              <html><script>paginationEps(12)</script></html>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final episode = await service.resolveProviderEpisode(
      series: const SeriesItem(
        name: 'Demo Anime',
        seriesStateKey: 'catalog:222',
        sourceType: SourceType.remote,
        provider: RemoteProvider.catalog,
        episodeCount: 12,
        releaseYear: 2024,
        format: 'TV',
        episodes: [],
      ),
      episode: const EpisodeItem(
        seriesName: 'Demo Anime',
        seriesStateKey: 'catalog:222',
        episodeIndex: 1,
        episodeNumber: 2,
        displayName: 'Demo Anime - Capitulo 2',
        relativePath: 'Catalogo / Capitulo 2',
        filePath: 'https://myanimelist.net/anime/222',
        sourceType: SourceType.remote,
        provider: RemoteProvider.catalog,
        watchUrl: 'https://myanimelist.net/anime/222',
      ),
      provider: RemoteProvider.jkAnime,
    );

    expect(episode?.provider, RemoteProvider.jkAnime);
    expect(episode?.episodeNumber, 2);
    expect(episode?.filePath, 'https://jkanime.net/demo/2/');
  });

  test('guesses JKAnime episode url when provider search has no match',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return http.Response('', 404, request: request);
      }),
    );

    final episode = await service.resolveProviderEpisode(
      series: const SeriesItem(
        name: 'Demo Anime (TV)',
        seriesStateKey: 'catalog:333',
        sourceType: SourceType.remote,
        provider: RemoteProvider.catalog,
        episodeCount: 12,
        releaseYear: 2024,
        format: 'TV',
        episodes: [],
      ),
      episode: const EpisodeItem(
        seriesName: 'Demo Anime (TV)',
        seriesStateKey: 'catalog:333',
        episodeIndex: 2,
        episodeNumber: 3,
        displayName: 'Demo Anime - Capitulo 3',
        relativePath: 'Catalogo / Capitulo 3',
        filePath: 'https://myanimelist.net/anime/333',
        sourceType: SourceType.remote,
        provider: RemoteProvider.catalog,
        watchUrl: 'https://myanimelist.net/anime/333',
      ),
      provider: RemoteProvider.jkAnime,
    );

    expect(episode?.provider, RemoteProvider.jkAnime);
    expect(episode?.slug, 'demo-anime');
    expect(episode?.filePath, 'https://jkanime.net/demo-anime/3/');
    expect(episode?.watchUrl, 'https://jkanime.net/demo-anime/');
  });

  test('resolves JKAnime var servers payload through a host page', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                var servers = [{
                  "remote":"aHR0cHM6Ly93d3cubXA0dXBsb2FkLmNvbS9lbWJlZC1kZW1vLmh0bWw=",
                  "server":"Mp4upload"
                }];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://www.mp4upload.com/embed-demo.html' => http.Response(
              '''
              <script>
                player.src({ src: "https://cdn.example.test/demo/video.mp4" });
              </script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/video.mp4');
  });

  test('resolves JKAnime window.servers payload through a host page', () async {
    final mp4Url = base64Encode(
        utf8.encode('https://www.mp4upload.com/embed-window.html'));
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                window.servers = [{
                  "remote":"$mp4Url",
                  "server":"Mp4upload"
                }];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://www.mp4upload.com/embed-window.html' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/window.mp4"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/window.mp4');
    expect(stream?.server, 'mp4upload');
  });

  test('prioritizes preferred JKAnime server host', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                var servers = [
                  {
                    "remote":"aHR0cHM6Ly9zdHJlYW13aXNoLmNvbS9lL2RlbW8=",
                    "server":"StreamWish"
                  },
                  {
                    "remote":"aHR0cHM6Ly93d3cubXA0dXBsb2FkLmNvbS9lbWJlZC1kZW1vLmh0bWw=",
                    "server":"Mp4upload"
                  }
                ];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://streamwish.com/e/demo' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/streamwish.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          'https://www.mp4upload.com/embed-demo.html' => http.Response(
              '''
              <script>
                player.src({ src: "https://cdn.example.test/demo/mp4upload.mp4" });
              </script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.jkAnime,
        filePath: 'https://jkanime.net/demo/1/',
        watchUrl: 'https://jkanime.net/demo/',
        slug: 'demo',
      ),
      preferredServer: 'mp4upload',
    );

    expect(stream?.playbackKind, 'mp4');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/demo/mp4upload.mp4',
    );
  });

  test('normalizes JKAnime sw server alias like Android', () async {
    final streamwishUrl =
        base64Encode(utf8.encode('https://sfastwish.com/e/sw-demo'));
    final mixdropUrl =
        base64Encode(utf8.encode('https://mixdrop.co/e/sw-fallback'));
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                var servers = [
                  {"remote":"$streamwishUrl","server":"sw"},
                  {"remote":"$mixdropUrl","server":"MixDrop"}
                ];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://sfastwish.com/e/sw-demo' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/sw.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          'https://mixdrop.co/e/sw-fallback' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/mixdrop.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.jkAnime,
        filePath: 'https://jkanime.net/demo/1/',
        watchUrl: 'https://jkanime.net/demo/',
        slug: 'demo',
      ),
      preferredServer: 'streamwish',
    );

    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/sw.m3u8');
    expect(stream?.server, 'streamwish');
    expect(requestedUrls, isNot(contains('https://mixdrop.co/e/sw-fallback')));
  });

  test('filters JKAnime hosts by payload server labels', () async {
    final desuUrl =
        base64Encode(utf8.encode('https://generic-player.test/embed/desu'));
    final mixdropUrl = base64Encode(utf8.encode('https://mixdrop.co/e/demo'));
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                var servers = [
                  {"remote":"$desuUrl","server":"Desu"},
                  {"remote":"$mixdropUrl","server":"MixDrop"}
                ];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://generic-player.test/embed/desu' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/desu.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          'https://mixdrop.co/e/demo' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/mixdrop.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.jkAnime,
        filePath: 'https://jkanime.net/demo/1/',
        watchUrl: 'https://jkanime.net/demo/',
        slug: 'demo',
      ),
      excludedServers: const {'desu'},
    );

    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/mixdrop.m3u8');
    expect(stream?.server, 'mixdrop');
    expect(requestedUrls,
        isNot(contains('https://generic-player.test/embed/desu')));
  });

  test('uses JKAnime automatic host order before fallback hosts', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                var servers = [
                  {
                    "remote":"aHR0cHM6Ly93d3cubXA0dXBsb2FkLmNvbS9lbWJlZC1hdXRvLmh0bWw=",
                    "server":"Mp4upload"
                  },
                  {
                    "remote":"aHR0cHM6Ly9taXhkcm9wLmNvL2UvZGVtbw==",
                    "server":"MixDrop"
                  }
                ];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://www.mp4upload.com/embed-auto.html' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/mp4upload.mp4"</script>
              ''',
              200,
              request: request,
            ),
          'https://mixdrop.co/e/demo' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/mixdrop.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/mixdrop.m3u8');
    expect(stream?.server, 'mixdrop');
  });

  test('prefers JKAnime var servers over native iframe like Android', () async {
    const jkIframe =
        'https://jkanime.net/jkplayer/um?e=demo&t=hash&op=OTc0MQ==';
    final streamwishUrl =
        base64Encode(utf8.encode('https://sfastwish.com/e/android-order'));
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                video[0] = '<iframe class="player_conte" src="$jkIframe"></iframe>';
                var servers = [{
                  "remote":"$streamwishUrl",
                  "server":"Streamwish"
                }]
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://sfastwish.com/e/android-order' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/android-order.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          jkIframe => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/native.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/demo/android-order.m3u8',
    );
    expect(stream?.server, 'streamwish');
    expect(requestedUrls, isNot(contains(jkIframe)));
  });

  test('resolves JKAnime flaswish Streamwish redirects', () async {
    final flaswishUrl =
        base64Encode(utf8.encode('https://flaswish.com/e/redirected'));
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                var servers = [{
                  "remote":"$flaswishUrl",
                  "server":"Streamwish"
                }];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://flaswish.com/e/redirected' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/flaswish.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/demo/flaswish.m3u8',
    );
    expect(stream?.server, 'streamwish');
  });

  test('resolves JKAnime wish-family Streamwish hosts like Android', () async {
    final wishUrl = base64Encode(utf8.encode('https://vidwish.com/e/family'));
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                var servers = [{
                  "remote":"$wishUrl",
                  "server":"Streamwish"
                }];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://vidwish.com/e/family' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/wish-family.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/demo/wish-family.m3u8',
    );
    expect(stream?.server, 'streamwish');
  });

  test('prefers JKAnime native iframe over stale host-like mp4 urls', () async {
    const jkIframe =
        'https://jkanime.net/jkplayer/um?e=demo&t=hash&op=OTc0MQ==';
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                //sel[0].click();
                video[0] = '<iframe class="player_conte" src="$jkIframe"></iframe>';
                const staleStreamwish = 'https://sfastwish.com/e/demo';
                const staleStreamtape = 'https://streamtape.com/e/demo/01.mp4';
              </script></html>
              ''',
              200,
              request: request,
            ),
          jkIframe => http.Response(
              '''
              <script src="https://cdn.jkdesa.com/assets3/js/hls.min.js"></script>
              <script>
                const player = {
                  video: {
                    url: 'https://nika.playmudos.com/demo/master.m3u8?st=abc'
                  }
                };
              </script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://nika.playmudos.com/demo/master.m3u8?st=abc',
    );
    expect(stream?.pageUrl, jkIframe);
    expect(stream?.server, 'desu');
    expect(requestedUrls, isNot(contains('https://sfastwish.com/e/demo')));
    expect(
      requestedUrls,
      isNot(contains('https://streamtape.com/e/demo/01.mp4')),
    );
  });

  test('skips excluded JKAnime host servers after playback failure', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                var servers = [
                  {
                    "remote":"aHR0cHM6Ly9zdHJlYW13aXNoLmNvbS9lL2RlbW8=",
                    "server":"StreamWish"
                  },
                  {
                    "remote":"aHR0cHM6Ly9taXhkcm9wLmNvL2UvZGVtbw==",
                    "server":"MixDrop"
                  }
                ];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://streamwish.com/e/demo' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/streamwish.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          'https://mixdrop.co/e/demo' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/mixdrop.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.jkAnime,
        filePath: 'https://jkanime.net/demo/1/',
        watchUrl: 'https://jkanime.net/demo/',
        slug: 'demo',
      ),
      excludedServers: const {'mixdrop'},
    );

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/demo/streamwish.m3u8',
    );
    expect(stream?.server, 'streamwish');
  });

  test('resolves JKAnime ajax endpoint host payload without WebView', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                fetch('/ajax/source/demo').then((response) => response.json());
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://jkanime.net/ajax/source/demo' => http.Response(
              '{"url":"https://streamwish.com/e/ajaxdemo"}',
              200,
              request: request,
            ),
          'https://streamwish.com/e/ajaxdemo' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/ajax.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/ajax.m3u8');
    expect(stream?.selectedMode, 'network-endpoint');
  });

  test('resolves JKAnime ajax endpoint assigned to JavaScript variables',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                const sourceUrl = '/ajax/source-variable/demo';
                fetch(sourceUrl).then((response) => response.json());
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://jkanime.net/ajax/source-variable/demo' => http.Response(
              '{"url":"https://mixdrop.co/e/variable-demo"}',
              200,
              request: request,
            ),
          'https://mixdrop.co/e/variable-demo' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/variable.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/demo/variable.m3u8',
    );
    expect(stream?.selectedMode, 'network-endpoint');
    expect(stream?.server, 'mixdrop');
  });

  test('resolves JKAnime ajax endpoint built by JavaScript concatenation',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                const sourceUrl = "/ajax/" + "source-concat/" + "demo";
                fetch(sourceUrl).then((response) => response.json());
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://jkanime.net/ajax/source-concat/demo' => http.Response(
              '{"url":"https://streamwish.com/e/concat-endpoint"}',
              200,
              request: request,
            ),
          'https://streamwish.com/e/concat-endpoint' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/concat-endpoint.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/demo/concat-endpoint.m3u8',
    );
    expect(stream?.selectedMode, 'network-endpoint');
    expect(stream?.server, 'streamwish');
  });

  test('resolves JKAnime ajax endpoint concatenated with string variables',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <html><script>
                const kind = "source-with-vars";
                const episodeId = "demo";
                const sourceUrl = "/ajax/" + kind + "/" + episodeId;
                fetch(sourceUrl).then((response) => response.json());
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://jkanime.net/ajax/source-with-vars/demo' => http.Response(
              '{"url":"https://mixdrop.co/e/variable-concat"}',
              200,
              request: request,
            ),
          'https://mixdrop.co/e/variable-concat' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/variable-concat.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/demo/variable-concat.m3u8',
    );
    expect(stream?.selectedMode, 'network-endpoint');
    expect(stream?.server, 'mixdrop');
  });

  test('resolves plain text ajax host and direct media payloads', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <script>
                jQuery.get('/ajax/plain-source/demo');
              </script>
              ''',
              200,
              request: request,
            ),
          'https://jkanime.net/ajax/plain-source/demo' => http.Response(
              'https://streamwish.com/e/plain-demo',
              200,
              request: request,
            ),
          'https://streamwish.com/e/plain-demo' => http.Response(
              'https://cdn.example.test/demo/plain.m3u8?token=abc',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/demo/plain.m3u8?token=abc',
    );
    expect(stream?.selectedMode, 'network-endpoint');
  });

  test('carries remote subtitle tracks from supported host payloads', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <iframe src="https://streamwish.com/e/subtitle-demo"></iframe>
              ''',
              200,
              request: request,
            ),
          'https://streamwish.com/e/subtitle-demo' => http.Response(
              r'''
              <script>
                const playerConfig = {
                  file: "https://cdn.example.test/demo/subtitle.m3u8",
                  tracks: [
                    {
                      file: "/subs/demo-es.vtt",
                      label: "Español",
                      kind: "subtitles",
                      srclang: "es",
                      default: true
                    }
                  ]
                };
              </script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(stream?.subtitleTracks, hasLength(1));
    expect(
      stream?.subtitleTracks.first.url,
      'https://streamwish.com/subs/demo-es.vtt',
    );
    expect(stream?.subtitleTracks.first.label, 'Español');
    expect(stream?.subtitleTracks.first.language, 'es');
    expect(stream?.subtitleTracks.first.mimeType, 'text/vtt');
    expect(stream?.subtitleTracks.first.isDefault, isTrue);
  });

  test('converts Zilla play payloads to AnimeAV1 HLS urls', () async {
    const streamId = '0123456789abcdef0123456789abcdef';
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <script>
                fetch('/ajax/zilla-source/demo');
              </script>
              ''',
              200,
              request: request,
            ),
          'https://jkanime.net/ajax/zilla-source/demo' => http.Response(
              'player.zilla-networks.com/play/$streamId',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://player.zilla-networks.com/m3u8/$streamId',
    );
    expect(stream?.selectedMode, 'network-endpoint');
  });

  test('resolves AnimeAV1 Svelte embed payloads by selected variant', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://animeav1.com/media/hunter-x-hunter/1' => http.Response(
              '''
              <script>
                data:[{type:"data",data:{episode:{number:1},
                embeds:{DUB:[{server:"HLS",url:"https://player.zilla-networks.com/play/2573f4ea87a59934236b7d7a0d37ecbd"}],
                SUB:[{server:"HLS",url:"https://player.zilla-networks.com/play/b340aa7e8c596a6c376adf1f44d8e2e1"}]}}}]
              </script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.animeAv1,
        filePath: 'https://animeav1.com/media/hunter-x-hunter/1',
        watchUrl: 'https://animeav1.com/media/hunter-x-hunter',
        slug: 'hunter-x-hunter',
      ),
    );

    expect(stream?.playbackKind, 'hls');
    expect(stream?.selectedMode, 'sub-hls');
    expect(
      stream?.playbackUrl,
      'https://player.zilla-networks.com/m3u8/b340aa7e8c596a6c376adf1f44d8e2e1',
    );
  });

  test('resolves AnimeAV1 visible Zilla iframe when variants are absent',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://animeav1.com/media/rurouni-kenshin-meiji-kenkaku-romantan/1' =>
            http.Response(
              '''
              <iframe
                class="aspect-video h-auto min-h-64 w-full object-cover"
                src="https://player.zilla-networks.com/play/148c333c484207780ae81447a5145a66"
                title="Episodio Embebido"
                frameborder="0"
                allowfullscreen>
              </iframe>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.animeAv1,
        filePath:
            'https://animeav1.com/media/rurouni-kenshin-meiji-kenkaku-romantan/1',
        watchUrl:
            'https://animeav1.com/media/rurouni-kenshin-meiji-kenkaku-romantan',
        slug: 'rurouni-kenshin-meiji-kenkaku-romantan',
      ),
    );

    expect(stream?.playbackKind, 'hls');
    expect(stream?.selectedMode, 'iframe-hls');
    expect(
      stream?.playbackUrl,
      'https://player.zilla-networks.com/m3u8/148c333c484207780ae81447a5145a66',
    );
  });

  test('resolves AnimeFLV var videos payload through Streamtape', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://www4.animeflv.net/ver/demo-1' => http.Response(
              r'''
              <html><script>
                var videos = {"SUB":[{"server":"stape","title":"Stape","code":"https:\/\/streamtape.com\/e\/demoid\/"}]};
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://streamtape.com/e/demoid/' => http.Response(
              '''
              <span id="botlink">/streamtape.com/get_video?id=demoid&token=abc&stream=1</span>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.animeFlv,
      filePath: 'https://www4.animeflv.net/ver/demo-1',
      watchUrl: 'https://www4.animeflv.net/anime/demo',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(
      stream?.playbackUrl,
      'https://streamtape.com/get_video?id=demoid&token=abc&stream=1',
    );
    expect(stream?.server, 'stape');
  });

  test('skips excluded AnimeFLV host servers after playback failure', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://www4.animeflv.net/ver/demo-1' => http.Response(
              '''
              <html><script>
                var videos = {"SUB":[
                  {"server":"sw","title":"StreamWish","url":"https://streamwish.com/e/flv-demo"},
                  {"server":"stape","title":"Stape","url":"https://streamtape.com/e/flv-demo/"}
                ]};
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://streamwish.com/e/flv-demo' => http.Response(
              '''
              <script>file: "https://cdn.example.test/flv/streamwish.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          'https://streamtape.com/e/flv-demo/' => http.Response(
              '''
              <span id="botlink">/streamtape.com/get_video?id=flv-demo&token=abc&stream=1</span>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.animeFlv,
        filePath: 'https://www4.animeflv.net/ver/demo-1',
        watchUrl: 'https://www4.animeflv.net/anime/demo',
        slug: 'demo',
      ),
      excludedServers: const {'streamwish'},
    );

    expect(stream?.playbackKind, 'mp4');
    expect(
      stream?.playbackUrl,
      'https://streamtape.com/get_video?id=flv-demo&token=abc&stream=1',
    );
    expect(stream?.server, 'stape');
  });

  test('resolves Streamtape robotlink from host pages', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://www4.animeflv.net/ver/demo-1' => http.Response(
              r'''
              <html><script>
                var videos = {"SUB":[{"server":"stape","title":"Stape","code":"https:\/\/streamtape.com\/e\/robotid\/"}]};
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://streamtape.com/e/robotid/' => http.Response(
              '''
              <span id="robotlink">/streamtape.com/get_video?id=robotid&token=xyz&stream=1</span>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.animeFlv,
      filePath: 'https://www4.animeflv.net/ver/demo-1',
      watchUrl: 'https://www4.animeflv.net/anime/demo',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(
      stream?.playbackUrl,
      'https://streamtape.com/get_video?id=robotid&token=xyz&stream=1',
    );
  });

  test('resolves LatAnime data-player payload through YourUpload', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://latanime.org/ver/demo-episodio-1' => http.Response(
              '''
              <a class="play-video" data-player="aHR0cHM6Ly93d3cueW91cnVwbG9hZC5jb20vZW1iZWQvZGVtbw==">yourupload</a>
              ''',
              200,
              request: request,
            ),
          'https://www.yourupload.com/embed/demo' => http.Response(
              '''
              <meta property="og:video" content="https://vidcache.example.test/a/video.mp4">
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.latAnime,
      filePath: 'https://latanime.org/ver/demo-episodio-1',
      watchUrl: 'https://latanime.org/anime/demo',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, 'https://vidcache.example.test/a/video.mp4');
    expect(stream?.server, 'yourupload');
  });

  test('prefers LatAnime data-player hosts over stale direct downloads',
      () async {
    final yourUploadUrl =
        base64Encode(utf8.encode('https://www.yourupload.com/embed/demo'));
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://latanime.org/ver/demo-episodio-1' => http.Response(
              '''
              <a class="play-video" data-player="$yourUploadUrl">yourupload</a>
              <a class="direct-link" href="https://www.fireload.com/demo/removed.mp4">
                Descargar
              </a>
              ''',
              200,
              request: request,
            ),
          'https://www.yourupload.com/embed/demo' => http.Response(
              '''
              <meta property="og:video" content="https://vidcache.example.test/a/video.mp4">
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.latAnime,
      filePath: 'https://latanime.org/ver/demo-episodio-1',
      watchUrl: 'https://latanime.org/anime/demo',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, 'https://vidcache.example.test/a/video.mp4');
    expect(stream?.server, 'yourupload');
    expect(
      requestedUrls,
      isNot(contains('https://www.fireload.com/demo/removed.mp4')),
    );
  });

  test('skips excluded LatAnime host servers after playback failure', () async {
    final uqloadUrl = Uri.encodeComponent(
      base64Encode(utf8.encode('https://uqload.to/embed-demo.html')),
    );
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://latanime.org/ver/demo-episodio-1' => http.Response(
              '''
              <a data-player="aHR0cHM6Ly93d3cueW91cnVwbG9hZC5jb20vZW1iZWQvZGVtbw==">yourupload</a>
              <a href="https://latanime.org/reproductor?url=$uqloadUrl">uqload</a>
              ''',
              200,
              request: request,
            ),
          'https://www.yourupload.com/embed/demo' => http.Response(
              '''
              <meta property="og:video" content="https://vidcache.example.test/a/video.mp4">
              ''',
              200,
              request: request,
            ),
          String url
              when url == 'https://latanime.org/reproductor?url=$uqloadUrl' =>
            http.Response(
              '<html></html>',
              200,
              request: request,
            ),
          'https://uqload.to/embed-demo.html' => http.Response(
              '''
              <script>file: "https://cdn.example.test/uqload/demo.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.latAnime,
        filePath: 'https://latanime.org/ver/demo-episodio-1',
        watchUrl: 'https://latanime.org/anime/demo',
        slug: 'demo',
      ),
      excludedServers: const {'yourupload'},
    );

    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, 'https://cdn.example.test/uqload/demo.m3u8');
    expect(stream?.server, 'uqload');
  });

  test('filters LatAnime data-player wrappers by visible server labels',
      () async {
    final uqloadTarget =
        base64Encode(utf8.encode('https://uqload.to/embed-demo.html'));
    final uqloadWrapper =
        'https://latanime.org/reproductor?url=${Uri.encodeComponent(uqloadTarget)}';
    final encodedUqloadWrapper = base64Encode(utf8.encode(uqloadWrapper));
    final encodedYourUpload =
        base64Encode(utf8.encode('https://www.yourupload.com/embed/demo'));
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://latanime.org/ver/demo-episodio-1' => http.Response(
              '''
              <a class="play-video" data-player="$encodedUqloadWrapper">Uqload</a>
              <a class="play-video" data-player="$encodedYourUpload">YourUpload</a>
              ''',
              200,
              request: request,
            ),
          String url when url == uqloadWrapper => http.Response(
              '<script>file: "https://cdn.example.test/uqload/demo.m3u8"</script>',
              200,
              request: request,
            ),
          'https://www.yourupload.com/embed/demo' => http.Response(
              '''
              <meta property="og:video" content="https://vidcache.example.test/a/video.mp4">
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.latAnime,
        filePath: 'https://latanime.org/ver/demo-episodio-1',
        watchUrl: 'https://latanime.org/anime/demo',
        slug: 'demo',
      ),
      excludedServers: const {'uqload'},
    );

    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, 'https://vidcache.example.test/a/video.mp4');
    expect(stream?.server, 'yourupload');
    expect(requestedUrls, isNot(contains(uqloadWrapper)));
  });

  test('uses LatAnime Android server order for data-player hosts', () async {
    final encodedUqload =
        base64Encode(utf8.encode('https://uqload.to/embed-default.html'));
    final encodedYourUpload = base64Encode(
      utf8.encode('https://www.yourupload.com/embed/default'),
    );
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://latanime.org/ver/demo-episodio-1' => http.Response(
              '''
              <a class="play-video" data-player="$encodedYourUpload">YourUpload</a>
              <a class="play-video" data-player="$encodedUqload">Uqload</a>
              ''',
              200,
              request: request,
            ),
          'https://uqload.to/embed-default.html' => http.Response(
              '''
              <script>file: "https://cdn.example.test/uqload/default.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          'https://www.yourupload.com/embed/default' => http.Response(
              '''
              <meta property="og:video" content="https://vidcache.example.test/default/video.mp4">
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.latAnime,
      filePath: 'https://latanime.org/ver/demo-episodio-1',
      watchUrl: 'https://latanime.org/anime/demo',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/uqload/default.m3u8',
    );
    expect(stream?.server, 'uqload');
    expect(
      requestedUrls,
      isNot(contains('https://www.yourupload.com/embed/default')),
    );
  });

  test('reads LatAnime data-player labels without play-video class', () async {
    final encodedUqload =
        base64Encode(utf8.encode('https://uqload.to/embed-unclassed.html'));
    final encodedYourUpload = base64Encode(
      utf8.encode('https://www.yourupload.com/embed/unclassed'),
    );
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://latanime.org/ver/demo-episodio-1' => http.Response(
              '''
              <button data-player="$encodedYourUpload">YourUpload</button>
              <button data-player="$encodedUqload">Uqload</button>
              ''',
              200,
              request: request,
            ),
          'https://uqload.to/embed-unclassed.html' => http.Response(
              '''
              <script>file: "https://cdn.example.test/uqload/unclassed.m3u8"</script>
              ''',
              200,
              request: request,
            ),
          'https://www.yourupload.com/embed/unclassed' => http.Response(
              '''
              <meta property="og:video" content="https://vidcache.example.test/unclassed/video.mp4">
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.latAnime,
      filePath: 'https://latanime.org/ver/demo-episodio-1',
      watchUrl: 'https://latanime.org/anime/demo',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/uqload/unclassed.m3u8',
    );
    expect(stream?.server, 'uqload');
    expect(
      requestedUrls,
      isNot(contains('https://www.yourupload.com/embed/unclassed')),
    );
  });

  test('resolves LatAnime wrapper query url payload through host page',
      () async {
    final encodedHost = Uri.encodeComponent(
      base64Encode(utf8.encode('https://www.yourupload.com/embed/wrapper')),
    );
    final wrapperUrl = 'https://latanime.org/reproductor?url=$encodedHost';
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          String url when url == wrapperUrl => http.Response(
              '<html></html>',
              200,
              request: request,
            ),
          'https://www.yourupload.com/embed/wrapper' => http.Response(
              '''
              <meta property="og:video" content="https://vidcache.example.test/wrapper/video.mp4">
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.latAnime,
      filePath: wrapperUrl,
      watchUrl: 'https://latanime.org/anime/demo',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(
      stream?.playbackUrl,
      'https://vidcache.example.test/wrapper/video.mp4',
    );
  });

  test('resolves player manifest keys from nested host pages', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <iframe src="https://netu.tv/e/demo"></iframe>
              ''',
              200,
              request: request,
            ),
          'https://netu.tv/e/demo' => http.Response(
              '''
              <script>
                window.playerConfig = {
                  "playback_url": "/hls/master.m3u8"
                };
              </script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, 'https://netu.tv/hls/master.m3u8');
  });

  test('resolves Netu bot_link JavaScript globals from host pages', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <iframe src="https://netu.tv/e/botlink-demo"></iframe>
              ''',
              200,
              request: request,
            ),
          'https://netu.tv/e/botlink-demo' => http.Response(
              '''
              <script>
                window.bot_link = "/hqq.tv/player/get_video?id=botlink-demo&token=abc";
              </script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(
      stream?.playbackUrl,
      'https://hqq.tv/player/get_video?id=botlink-demo&token=abc&stream=1',
    );
    expect(stream?.server, 'netu');
  });

  test('resolves packed JavaScript host sources without WebView', () async {
    final packedPayload =
        r'''0.1({2:[{3:"https://cdn.example.test/demo/packed.m3u8"}]})''';
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <iframe src="https://upcloud.to/e/packed-demo"></iframe>
              ''',
              200,
              request: request,
            ),
          'https://upcloud.to/e/packed-demo' => http.Response(
              '''
              <script>
                eval(function(p,a,c,k,e,d){return p;}(
                  '$packedPayload',4,4,'jwplayer|setup|sources|file'.split('|'),0,{}
                ));
              </script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/packed.m3u8');
  });

  test('resolves concatenated JavaScript media urls from supported hosts',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <script>
                const host = "https://megacloud.tv/e/concat-demo";
                location.href = host;
              </script>
              ''',
              200,
              request: request,
            ),
          'https://megacloud.tv/e/concat-demo' => http.Response(
              '''
              <script>
                const media = "https://cdn.example.test" +
                  "/demo/" + "concat.m3u8?token=abc";
              </script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.jkAnime,
      filePath: 'https://jkanime.net/demo/1/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'hls');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/demo/concat.m3u8?token=abc',
    );
  });

  test('resolves Doodstream pass_md5 host pages without WebView', () async {
    final encodedHost =
        base64Encode(utf8.encode('https://doodstream.com/e/demo'));
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://latanime.org/ver/demo-episodio-1' => http.Response(
              '''
              <a class="play-video" data-player="$encodedHost">doodstream</a>
              ''',
              200,
              request: request,
            ),
          'https://doodstream.com/e/demo' => http.Response(
              '''
              <script>
                \$.get('/pass_md5/demo-token', function(data) {
                  video.src = data + makePlay();
                });
                var playbackToken = "?token=abc123&expiry=";
              </script>
              ''',
              200,
              request: request,
            ),
          'https://doodstream.com/pass_md5/demo-token' => http.Response(
              'https://cloudatacdn.com/v/demo/',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.latAnime,
      filePath: 'https://latanime.org/ver/demo-episodio-1',
      watchUrl: 'https://latanime.org/anime/demo',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, startsWith('https://cloudatacdn.com/v/demo/'));
    expect(stream?.playbackUrl, contains('?token=abc123&expiry='));
  });

  test('treats LatAnime myvidplay hosts as Doodstream', () async {
    final encodedHost =
        base64Encode(utf8.encode('https://myvidplay.com/e/demo'));
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://latanime.org/ver/demo-episodio-1' => http.Response(
              '''
              <a class="play-video" data-player="$encodedHost">myvidplay</a>
              ''',
              200,
              request: request,
            ),
          'https://myvidplay.com/e/demo' => http.Response(
              '''
              <script>
                \$.get('/pass_md5/myvidplay-token', function(data) {
                  video.src = data + makePlay();
                });
                var playbackToken = "?token=abc123&expiry=";
              </script>
              ''',
              200,
              request: request,
            ),
          'https://myvidplay.com/pass_md5/myvidplay-token' => http.Response(
              'https://myvidplay.com/v/demo/',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.latAnime,
      filePath: 'https://latanime.org/ver/demo-episodio-1',
      watchUrl: 'https://latanime.org/anime/demo',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, startsWith('https://myvidplay.com/v/demo/'));
    expect(stream?.server, 'doodstream');
  });

  test('resolves Facebook progressive playback urls from page JSON', () async {
    final progressiveTag =
        base64UrlEncode(utf8.encode('{"label":"xpv_progressive"}'))
            .replaceAll('=', '');
    final audioTag =
        base64UrlEncode(utf8.encode('{"label":"audio"}')).replaceAll('=', '');
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://www.facebook.com/demo/videos/123/' => http.Response(
              '''
              <html>
                <script>
                  require("Relay").preload({
                    "playable_url_quality_hd":"https:\\/\\/video.xx.fbcdn.net\\/v\\/t42.1790-2\\/demo_hd.mp4?efg=$progressiveTag\\u0026bytestart=0",
                    "browser_native_sd_url":"https:\\/\\/video.xx.fbcdn.net\\/v\\/t42.1790-2\\/demo_sd.mp4?efg=$progressiveTag",
                    "dash_manifest_url":"https:\\/\\/video.xx.fbcdn.net\\/v\\/dash\\/manifest.mpd?efg=$audioTag"
                  });
                </script>
              </html>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.facebook,
        filePath: 'https://www.facebook.com/demo/videos/123/',
        watchUrl: 'https://www.facebook.com/demo/videos/123/',
        slug: 'demo',
      ),
      preferredFacebookMode: FacebookPlaybackMode.sub.id,
    );

    expect(stream?.playbackKind, 'mp4');
    expect(
      stream?.playbackUrl,
      'https://video.xx.fbcdn.net/v/t42.1790-2/demo_hd.mp4'
      '?efg=$progressiveTag&bytestart=0',
    );
  });

  test('ignores social preview mp4 direct media candidates', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://catalog.example.test/demo/1' => http.Response(
              '''
              <meta property="og:video" content="https://pbs.twimg.com/static/money/x-card-animation-v4.mp4">
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(_episode(
      provider: RemoteProvider.catalog,
      filePath: 'https://catalog.example.test/demo/1',
      watchUrl: 'https://catalog.example.test/demo',
      slug: 'demo',
    ));

    expect(stream, isNull);
  });

  test('uses Android WebView resolver fallback after HTTP resolver misses',
      () async {
    final webResolver = _FakeRemoteWebResolver(
      const RemoteDirectStream(
        playbackUrl: 'https://streamwish.to/hls/demo.m3u8',
        playbackKind: 'hls',
        pageUrl: 'https://streamwish.to/e/demo',
        selectedMode: 'android-webview',
        server: 'streamwish',
        httpHeaders: {'Cookie': 'session=demo'},
      ),
    );
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://jkanime.net/demo/1/');
        return http.Response(
          '<html><body>no direct media</body></html>',
          200,
          request: request,
        );
      }),
      webResolver: webResolver,
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.jkAnime,
        filePath: 'https://jkanime.net/demo/1/',
        watchUrl: 'https://jkanime.net/demo/',
        slug: 'demo',
      ),
      preferredServer: JkAnimeServerPreference.streamWish.id,
    );

    expect(webResolver.requests, hasLength(1));
    expect(webResolver.requests.single.pageUrl, 'https://jkanime.net/demo/1/');
    expect(webResolver.requests.single.preferredServer, 'streamwish');
    expect(stream?.playbackUrl, 'https://streamwish.to/hls/demo.m3u8');
    expect(stream?.provider, RemoteProvider.jkAnime);
    expect(stream?.server, 'streamwish');
    expect(stream?.httpHeaders['Cookie'], 'session=demo');
  });

  test('uses Android WebView resolver fallback after AnimeAV1 direct miss',
      () async {
    final webResolver = _FakeRemoteWebResolver(
      const RemoteDirectStream(
        playbackUrl:
            'https://player.zilla-networks.com/m3u8/148c333c484207780ae81447a5145a66',
        playbackKind: 'hls',
        pageUrl:
            'https://player.zilla-networks.com/play/148c333c484207780ae81447a5145a66',
        selectedMode: 'android-webview',
        httpHeaders: {'Cookie': 'zilla=session'},
      ),
    );
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://animeav1.com/media/demo/1');
        return http.Response(
          '<html><body><div id="player"></div></body></html>',
          200,
          request: request,
        );
      }),
      webResolver: webResolver,
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.animeAv1,
        filePath: 'https://animeav1.com/media/demo/1',
        watchUrl: 'https://animeav1.com/media/demo',
        slug: 'demo',
      ),
    );

    expect(webResolver.requests, hasLength(1));
    expect(webResolver.requests.single.pageUrl,
        'https://animeav1.com/media/demo/1');
    expect(stream?.playbackKind, 'hls');
    expect(stream?.provider, RemoteProvider.animeAv1);
    expect(
      stream?.playbackUrl,
      'https://player.zilla-networks.com/m3u8/148c333c484207780ae81447a5145a66',
    );
    expect(stream?.httpHeaders['Cookie'], 'zilla=session');
  });
}

EpisodeItem _episode({
  required RemoteProvider provider,
  required String filePath,
  required String watchUrl,
  required String slug,
}) {
  return EpisodeItem(
    seriesName: 'Demo',
    seriesStateKey: 'demo',
    episodeIndex: 0,
    episodeNumber: 1,
    displayName: 'Demo - Capitulo 1',
    relativePath: 'Demo / Capitulo 1',
    filePath: filePath,
    sourceType: SourceType.remote,
    provider: provider,
    slug: slug,
    watchUrl: watchUrl,
  );
}

class _FakeRemoteWebResolver extends RemoteWebResolver {
  _FakeRemoteWebResolver(this.stream);

  final RemoteDirectStream? stream;
  final requests = <({
    String pageUrl,
    String preferredServer,
    Set<String> excludedServers
  })>[];

  @override
  bool get isAvailable => true;

  @override
  Future<RemoteDirectStream?> resolveDirectStream({
    required EpisodeItem entry,
    required String pageUrl,
    String referer = '',
    String preferredServer = '',
    Set<String> excludedServers = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((
      pageUrl: pageUrl,
      preferredServer: preferredServer,
      excludedServers: excludedServers,
    ));
    return stream;
  }
}
