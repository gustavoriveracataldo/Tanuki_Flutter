import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/services/remote_catalog_service.dart';
import 'package:toonami_viernes_noche_flutter/src/services/remote_web_resolver.dart';

void main() {
  test('keeps explicit episode zero when converting catalog candidates',
      () async {
    final series = const RemoteSearchCandidate(
      provider: RemoteProvider.catalog,
      slug: 'gundam-demo',
      title: 'Gundam Demo',
      episodeCount: 3,
      imageUrl: 'https://cdn.example.test/poster.jpg',
      episodeDetails: [
        SeriesEpisodeMetadata(
          episodeNumber: 0,
          title: 'Prologo',
          imageUrl: 'https://cdn.example.test/prologue.jpg',
        ),
        SeriesEpisodeMetadata(
          episodeNumber: 1,
          title: 'Capitulo 1',
          imageUrl: 'https://cdn.example.test/episode-1.jpg',
        ),
        SeriesEpisodeMetadata(episodeNumber: 2),
      ],
    ).toSeries(existingNames: const []);

    expect(series.episodes.map((episode) => episode.episodeNumber), [0, 1, 2]);
    expect(series.episodes.first.relativePath, 'Episodio 0');
    expect(series.episodes.first.imageUrl,
        'https://cdn.example.test/prologue.jpg');
  });

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

  test('fetches AniList recommendations using the AniList id from Ani.pm',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://graphql.anilist.co');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final variables = body['variables'] as Map<String, dynamic>;
        expect(variables['id'], 21204);
        expect(body['query'], contains('recommendations'));
        return http.Response(
          jsonEncode({
            'data': {
              'Media': {
                'relations': {
                  'edges': [
                    {
                      'relationType': 'SEQUEL',
                      'node': {
                        'id': 120204,
                        'idMal': 40437,
                        'type': 'ANIME',
                        'title': {
                          'romaji': 'Wakako-zake Movie',
                          'english': null,
                          'native': 'ワカコ酒 劇場版',
                        },
                        'episodes': 1,
                        'format': 'MOVIE',
                        'startDate': {'year': 2016, 'month': 1, 'day': 1},
                      },
                    },
                    {
                      'relationType': 'SOURCE',
                      'node': {
                        'id': 86339,
                        'idMal': null,
                        'type': 'MANGA',
                        'title': {'romaji': 'Wakako-Zake'},
                      },
                    },
                  ],
                },
                'recommendations': {
                  'nodes': [
                    {
                      'rating': 20,
                      'mediaRecommendation': {
                        'id': 98657,
                        'idMal': 35484,
                        'title': {
                          'romaji': 'Osake wa Fuufu ni Natte kara',
                          'english': 'Love is Like a Cocktail',
                          'native': 'お酒は夫婦になってから',
                        },
                        'episodes': 13,
                        'format': 'TV_SHORT',
                        'startDate': {'year': 2017, 'month': 10, 'day': 4},
                      },
                    },
                    {
                      'rating': 8,
                      'mediaRecommendation': {
                        'id': 99753,
                        'idMal': 36108,
                        'title': {
                          'romaji': 'Takunomi.',
                          'english': null,
                          'native': 'たくのみ。',
                        },
                        'episodes': 12,
                        'format': 'TV_SHORT',
                        'startDate': {'year': 2018, 'month': 1, 'day': 12},
                      },
                    },
                  ],
                },
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
          request: request,
        );
      }),
    );
    final series = const RemoteSearchCandidate(
      provider: RemoteProvider.aniPm,
      slug: 'ani:21204',
      title: 'Wakako-zake',
      watchUrl: 'https://ani.pm/ani/21204',
      seriesUrl: 'https://ani.pm/ani/21204',
      releaseYear: 2015,
      catalogId: 21204,
      episodeCount: 12,
    ).toSeries(existingNames: const []);

    final recommendations =
        await service.fetchAniListRecommendationsForSeries(series);

    expect(
      recommendations.map((candidate) => candidate.title),
      [
        'Wakako-zake Movie',
        'Osake wa Fuufu ni Natte kara',
        'Takunomi.',
      ],
    );
    expect(recommendations.first.catalogId, 40437);
  });

  test('parses recommendations from the public MyAnimeList page', () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        expect(
          request.url.toString(),
          'https://myanimelist.net/anime/30437/_/userrecs',
        );
        return http.Response('''
          <div class="picSurround"><a href="https://myanimelist.net/anime/35484/Osake_wa_Fuufu_ni_Natte_kara" class="hoverinfo_trigger">
            <img src="spacer.gif" data-src="https://cdn.myanimelist.net/r/50x70/images/anime/osake.jpg" alt="Anime: Osake wa Fuufu ni Natte kara">
          </div>
          <div class="picSurround"><a href="https://myanimelist.net/anime/36108/Takunomi" class="hoverinfo_trigger">
            <img data-src="https://cdn.myanimelist.net/r/50x70/images/anime/takunomi.jpg" alt="Anime: Takunomi.">
          </div>
        ''', 200, request: request);
      }),
    );

    final recommendations =
        await service.fetchMyAnimeListWebRecommendations(30437);

    expect(
      recommendations.map((candidate) => candidate.title),
      ['Osake wa Fuufu ni Natte kara', 'Takunomi.'],
    );
    expect(recommendations.map((candidate) => candidate.catalogId),
        [35484, 36108]);
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

  test('keeps AniList airing schedule when top airing result lacks dates',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        if (request.url.host == 'api.jikan.moe') {
          return http.Response(
            '''
            {
              "data": [
                {
                  "mal_id": 100,
                  "title": "Airing Demo",
                  "url": "https://myanimelist.net/anime/100",
                  "type": "TV",
                  "episodes": 12,
                  "year": 2026,
                  "images": {
                    "jpg": {
                      "large_image_url": "https://cdn.example.test/jikan.jpg"
                    }
                  }
                }
              ]
            }
            ''',
            200,
            request: request,
          );
        }
        if (request.url.host == 'myanimelist.net') {
          return http.Response('temporarily blocked', 503, request: request);
        }
        if (request.url.host == 'graphql.anilist.co') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['query'], contains('airingSchedule(notYetAired: true'));
          return http.Response(
            '''
            {
              "data": {
                "Page": {
                  "media": [
                    {
                      "id": 200,
                      "idMal": 100,
                      "title": {
                        "romaji": "Airing Demo",
                        "english": null,
                        "native": "Airing Demo"
                      },
                      "synonyms": [],
                      "description": "Demo",
                      "episodes": 12,
                      "format": "TV",
                      "averageScore": 80,
                      "startDate": {
                        "year": 2026,
                        "month": 7,
                        "day": 1
                      },
                      "coverImage": {
                        "extraLarge": "https://cdn.example.test/anilist.jpg",
                        "large": "https://cdn.example.test/anilist-large.jpg"
                      },
                      "bannerImage": null,
                      "trailer": null,
                      "airingSchedule": {
                        "nodes": [
                          {
                            "episode": 4,
                            "airingAt": 4102444800
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
            ''',
            200,
            request: request,
          );
        }
        return http.Response('not found', 404, request: request);
      }),
    );

    final results = await service.discoverCatalogAiring(limit: 10);

    expect(results, hasLength(1));
    expect(results.single.title, 'Airing Demo');
    expect(results.single.imageUrl, 'https://cdn.example.test/jikan.jpg');
    expect(results.single.episodeDetails, hasLength(1));
    expect(results.single.episodeDetails.single.episodeNumber, 4);
    expect(
      results.single.episodeDetails.single.airDateIso,
      startsWith('2100-01-01'),
    );
  });

  test('discovers latest movies from playable JKAnime and AnimeAV1 catalogs',
      () async {
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        if (request.url.host == 'jkanime.net') {
          expect(request.url.path, '/directorio');
          expect(request.url.queryParameters['tipo'], 'peliculas');
          return http.Response(
            '''
            <script>
            var animes = {
              "data": [
                {
                  "title": "JK Movie Demo",
                  "image": "https://cdn.jkdesa.com/movie.jpg",
                  "slug": "jk-movie-demo",
                  "type": "Movie",
                  "tipo": "Pelicula",
                  "url": "https://jkanime.net/jk-movie-demo/"
                }
              ]
            };
            </script>
            ''',
            200,
            request: request,
          );
        }
        if (request.url.host == 'animeav1.com') {
          expect(request.url.path, '/catalogo');
          expect(request.url.queryParameters['category'], 'pelicula');
          expect(request.url.queryParameters['order'], 'latest_released');
          return http.Response(
            '''
            <article class="group/item relative text-body">
              <img src="https://cdn.animeav1.com/covers/1.jpg" />
              <div class="rounded bg-line px-2">Película</div>
              <h3>AnimeAV1 Movie Demo</h3>
              <a href="/media/animeav1-movie-demo">Ver</a>
            </article>
            ''',
            200,
            request: request,
          );
        }
        return http.Response('not found', 404, request: request);
      }),
    );

    final movies = await service.discoverCatalogMovies(limit: 10);

    expect(requestedUrls, hasLength(2));
    expect(movies.map((candidate) => candidate.provider), [
      RemoteProvider.jkAnime,
      RemoteProvider.animeAv1,
    ]);
    expect(movies.map((candidate) => candidate.title), [
      'JK Movie Demo',
      'AnimeAV1 Movie Demo',
    ]);
  });

  test('keeps full movie catalog pages without requiring per-card movie labels',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        if (request.url.host == 'jkanime.net') {
          final data = List.generate(
            15,
            (index) => {
              'title': 'JK Theatrical Demo ${index + 1}',
              'image': 'https://cdn.jkdesa.com/movie-${index + 1}.jpg',
              'slug': 'jk-theatrical-demo-${index + 1}',
              'type': 'Serie',
              'tipo': 'Serie',
              'url': 'https://jkanime.net/jk-theatrical-demo-${index + 1}/',
            },
          );
          return http.Response(
            '<script>var animes = ${jsonEncode({'data': data})};</script>',
            200,
            request: request,
          );
        }
        if (request.url.host == 'animeav1.com') {
          final html = StringBuffer();
          for (var index = 1; index <= 15; index += 1) {
            html.write('''
            <article class="group/item relative text-body">
              <img src="https://cdn.animeav1.com/covers/$index.jpg" />
              <div class="rounded bg-line px-2">TV Anime</div>
              <h3>AnimeAV1 Theatrical Demo $index</h3>
              <a href="/media/animeav1-theatrical-demo-$index">Ver</a>
            </article>
            ''');
          }
          return http.Response('$html', 200, request: request);
        }
        return http.Response('not found', 404, request: request);
      }),
    );

    final movies = await service.discoverCatalogMovies(limit: 15);

    expect(movies, hasLength(30));
    expect(
      movies.where((candidate) => candidate.provider == RemoteProvider.jkAnime),
      hasLength(15),
    );
    expect(
      movies.where(
        (candidate) => candidate.provider == RemoteProvider.animeAv1,
      ),
      hasLength(15),
    );
    expect(movies.every((candidate) => candidate.format == 'Movie'), isTrue);
  });

  test('aggregate search skips disabled AnimeFLV provider', () async {
    final requestedHosts = <String>[];
    final service = RemoteCatalogService(
      myAnimeListClientId: '',
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

  test('aggregate search keeps catalog variants before provider results',
      () async {
    final service = RemoteCatalogService(
      myAnimeListClientId: 'mal-client',
      client: MockClient((request) async {
        if (request.url.host == 'api.jikan.moe') {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'mal_id': 39535,
                  'title': 'Mushoku Tensei: Isekai Ittara Honki Dasu',
                  'type': 'TV',
                  'episodes': 11,
                  'score': 8.3,
                  'year': 2021,
                  'images': {
                    'jpg': {'large_image_url': 'https://jikan.test/s1.jpg'},
                  },
                },
              ],
            }),
            200,
            request: request,
          );
        }
        if (request.url.host == 'graphql.anilist.co') {
          return http.Response(
            jsonEncode({
              'data': {
                'Page': {
                  'media': [
                    {
                      'id': 178789,
                      'idMal': 59193,
                      'title': {
                        'romaji':
                            'Mushoku Tensei III: Isekai Ittara Honki Dasu',
                      },
                      'episodes': 14,
                      'format': 'TV',
                      'averageScore': 89,
                      'startDate': {'year': 2026},
                      'coverImage': {
                        'large': 'https://anilist.test/s3.jpg',
                      },
                    },
                  ],
                },
              },
            }),
            200,
            request: request,
          );
        }
        if (request.url.host == 'api.myanimelist.net') {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'node': {
                    'id': 51179,
                    'title': 'Mushoku Tensei II: Isekai Ittara Honki Dasu',
                    'main_picture': {
                      'large': 'https://mal.test/s2.jpg',
                    },
                    'start_date': '2023-07-03',
                    'media_type': 'tv',
                    'num_episodes': 12,
                    'mean': 8.2,
                  },
                },
              ],
            }),
            200,
            request: request,
          );
        }
        if (request.url.host == 'animeav1.com') {
          return http.Response(
            '''
            <article class="group/item">
              <img src="https://animeav1.test/mushoku-provider.jpg">
              <div class="rounded bg-line">TV</div>
              <h3>Mushoku Provider</h3>
              <a href="/media/mushoku-provider"></a>
            </article>
            ''',
            200,
            request: request,
          );
        }
        return http.Response('', 200, request: request);
      }),
    );

    final results = await service.search('mushoku');

    expect(results.take(3).map((candidate) => candidate.provider),
        everyElement(RemoteProvider.catalog));
    expect(results.take(3).map((candidate) => candidate.catalogId),
        containsAllInOrder([39535, 51179, 59193]));
    expect(results.skip(3).map((candidate) => candidate.provider),
        contains(RemoteProvider.animeAv1));
  });

  test('falls back to MyAnimeList catalog search when Jikan fails', () async {
    final requestedHosts = <String>[];
    final service = RemoteCatalogService(
      myAnimeListClientId: 'mal-client',
      client: MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'api.jikan.moe') {
          return http.Response(
            '{"status":504,"message":"Jikan failed"}',
            504,
            request: request,
          );
        }
        if (request.url.host == 'graphql.anilist.co') {
          return http.Response(
            '{"data":{"Page":{"media":[]}}}',
            200,
            request: request,
          );
        }
        if (request.url.host == 'api.myanimelist.net') {
          expect(request.headers['X-MAL-CLIENT-ID'], 'mal-client');
          expect(request.url.path, '/v2/anime');
          expect(request.url.queryParameters['q'], 'kirarin');
          return http.Response.bytes(
            utf8.encode('''
            {
              "data": [
                {
                  "node": {
                    "id": 1516,
                    "title": "Kirarin☆Revolution",
                    "main_picture": {
                      "medium": "https://cdn.example.test/kirarin.jpg",
                      "large": "https://cdn.example.test/kirarin-large.jpg"
                    },
                    "alternative_titles": {
                      "synonyms": [],
                      "en": "Kirarin Revolution",
                      "ja": "きらりん☆レボリューション"
                    },
                    "start_date": "2006-04-07",
                    "media_type": "tv",
                    "num_episodes": 153,
                    "synopsis": "Kirari demo",
                    "mean": 7.05
                  }
                }
              ]
            }
            '''),
            200,
            request: request,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        expect(request.url.host, 'myanimelist.net');
        return http.Response(
          '<h2 id="anime">Anime</h2><article></article>',
          200,
          request: request,
        );
      }),
    );

    final results = await service.searchCatalog('kirarin');

    expect(requestedHosts, [
      'api.jikan.moe',
      'api.myanimelist.net',
      'myanimelist.net',
      'graphql.anilist.co',
    ]);
    expect(results, hasLength(1));
    expect(results.first.provider, RemoteProvider.catalog);
    expect(results.first.catalogId, 1516);
    expect(results.first.title, 'Kirarin☆Revolution');
    expect(results.first.aliases, contains('Kirarin Revolution'));
    expect(results.first.format, 'TV');
    expect(results.first.episodeCount, 153);
    expect(results.first.releaseYear, 2006);
    expect(results.first.rating, '7.0');
  });

  test('uses public MyAnimeList web search when API client is unavailable',
      () async {
    final requestedHosts = <String>[];
    final service = RemoteCatalogService(
      myAnimeListClientId: '',
      client: MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'api.jikan.moe') {
          return http.Response('{"data":[]}', 200, request: request);
        }
        if (request.url.host == 'graphql.anilist.co') {
          return http.Response(
            '{"data":{"Page":{"media":[]}}}',
            200,
            request: request,
          );
        }
        expect(request.url.host, 'myanimelist.net');
        expect(request.url.path, '/search/all');
        expect(request.url.queryParameters['q'], 'mushoku');
        expect(request.url.queryParameters['cat'], 'anime');
        return http.Response(
          '''
          <h2 id="anime">Anime</h2>
          <article>
            <div class="list di-t w100">
              <div class="picSurround di-tc thumb">
                <a href="https://myanimelist.net/anime/59193/Mushoku_Tensei_III__Isekai_Ittara_Honki_Dasu">
                  <img data-src="https://cdn.myanimelist.net/r/100x140/images/anime/1527/158340.jpg?s=demo"
                       alt="Mushoku Tensei III: Isekai Ittara Honki Dasu">
                </a>
              </div>
              <div class="information di-tc va-t pt4 pl8">
                <div class="title">
                  <a data-l-content-type="anime"
                     href="https://myanimelist.net/anime/59193/Mushoku_Tensei_III__Isekai_Ittara_Honki_Dasu">
                    Mushoku Tensei III: Isekai Ittara Honki Dasu
                  </a>
                </div>
                <div class="pt8 fs10 lh14 fn-grey4">
                  <a>TV</a> (14 eps)<br>
                  Scored 8.92<br>
                  260,867 members<br>
                </div>
              </div>
            </div>
          </article>
          ''',
          200,
          request: request,
        );
      }),
    );

    final results = await service.searchCatalog('mushoku');

    expect(requestedHosts,
        ['api.jikan.moe', 'myanimelist.net', 'graphql.anilist.co']);
    expect(results, hasLength(1));
    expect(results.first.catalogId, 59193);
    expect(results.first.title, 'Mushoku Tensei III: Isekai Ittara Honki Dasu');
    expect(results.first.imageUrl,
        'https://cdn.myanimelist.net/images/anime/1527/158340.jpg');
    expect(results.first.format, 'TV');
    expect(results.first.episodeCount, 14);
    expect(results.first.rating, '8.92');
  });

  test('falls back to AniList catalog search when Jikan fails', () async {
    final requestedHosts = <String>[];
    final service = RemoteCatalogService(
      myAnimeListClientId: 'mal-client',
      client: MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'api.jikan.moe') {
          return http.Response(
            '{"status":504,"message":"Jikan failed"}',
            504,
            request: request,
          );
        }
        if (request.url.host == 'api.myanimelist.net') {
          return http.Response('{"data":[]}', 200, request: request);
        }
        if (request.url.host == 'myanimelist.net') {
          return http.Response(
            '<h2 id="anime">Anime</h2><article></article>',
            200,
            request: request,
          );
        }
        expect(request.url.host, 'graphql.anilist.co');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['variables']['search'], 'oshi no ko');
        return http.Response(
          jsonEncode({
            'data': {
              'Page': {
                'media': [
                  {
                    'id': 182587,
                    'idMal': 60058,
                    'title': {
                      'romaji': '[Oshi no Ko] 3rd Season',
                      'english': 'OSHI NO KO Season 3',
                      'native': '【推しの子】第3期',
                    },
                    'synonyms': ['My Star Season 3'],
                    'description': 'AniList demo',
                    'episodes': 11,
                    'format': 'TV',
                    'averageScore': 86,
                    'startDate': {
                      'year': 2026,
                      'month': 1,
                      'day': 14,
                    },
                    'coverImage': {
                      'extraLarge': 'https://anilist.test/cover.jpg',
                    },
                    'bannerImage': 'https://anilist.test/banner.jpg',
                    'trailer': {
                      'site': 'youtube',
                      'id': 'trailer123',
                    },
                  }
                ],
              },
            },
          }),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final results = await service.searchCatalog('oshi no ko');

    expect(requestedHosts, [
      'api.jikan.moe',
      'api.myanimelist.net',
      'myanimelist.net',
      'graphql.anilist.co',
    ]);
    expect(results, hasLength(1));
    expect(results.first.catalogId, 60058);
    expect(results.first.title, '[Oshi no Ko] 3rd Season');
    expect(results.first.aliases, contains('My Star Season 3'));
    expect(results.first.episodeCount, 11);
    expect(results.first.releaseYear, 2026);
    expect(results.first.airDateIso, '2026-01-14');
    expect(results.first.rating, '8.6');
    expect(
        results.first.trailerUrl, 'https://www.youtube.com/watch?v=trailer123');
  });

  test('falls back to AniList random when Jikan random fails', () async {
    final requestedHosts = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'api.jikan.moe') {
          return http.Response(
            '{"status":504,"message":"Jikan failed"}',
            504,
            request: request,
          );
        }
        expect(request.url.host, 'graphql.anilist.co');
        return http.Response(
          jsonEncode({
            'data': {
              'Page': {
                'media': [
                  {
                    'id': 178789,
                    'idMal': 59193,
                    'title': {
                      'romaji': 'Mushoku Tensei III',
                    },
                    'episodes': 14,
                    'format': 'TV',
                    'averageScore': 88,
                    'startDate': {'year': 2026},
                    'coverImage': {
                      'large': 'https://anilist.test/mushoku.jpg',
                    },
                  }
                ],
              },
            },
          }),
          200,
          request: request,
        );
      }),
    );

    final candidate = await service.fetchCatalogRandomFallback(attempts: 1);

    expect(requestedHosts, ['api.jikan.moe', 'graphql.anilist.co']);
    expect(candidate?.catalogId, 59193);
    expect(candidate?.title, 'Mushoku Tensei III');
    expect(candidate?.format, 'TV');
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

  test('discovers MyAnimeList TV New season section without continuing shows',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        expect(request.url.host, 'myanimelist.net');
        expect(request.url.path, '/anime/season/2026/summer');
        return http.Response(
          '''
          <div class="seasonal-anime-list js-seasonal-anime-list">
            <div class="anime-header">TV (New)</div>
            <div class="seasonal-anime js-anime-type-1">
              <h2 class="h2_anime_title"><a href="https://myanimelist.net/anime/59193/Mushoku_Tensei_III__Isekai_Ittara_Honki_Dasu" class="link-title">Mushoku Tensei III: Isekai Ittara Honki Dasu</a></h2>
              <span class="js-start_date">20260705</span>
              <span class="js-score">8.50</span>
              <img data-src="https://cdn.myanimelist.net/images/anime/1/1.jpg" />
              <div class="eps">12 eps</div>
            </div>
            <div class="seasonal-anime js-anime-type-1">
              <h2 class="h2_anime_title"><a href="https://myanimelist.net/anime/49233/Youjo_Senki_II" class="link-title">Youjo Senki II</a></h2>
              <span class="js-start_date">20260708</span>
              <img data-src="https://cdn.myanimelist.net/images/anime/2/2.jpg" />
            </div>
          </div>
          <div class="seasonal-anime-list js-seasonal-anime-list">
            <div class="anime-header">TV (Continuing)</div>
            <div class="seasonal-anime js-anime-type-1">
              <h2 class="h2_anime_title"><a href="https://myanimelist.net/anime/21/One_Piece" class="link-title">One Piece</a></h2>
              <span class="js-start_date">19991020</span>
            </div>
          </div>
          ''',
          200,
          request: request,
        );
      }),
    );

    final results = await service.discoverCatalogBySeason(
      season: 'summer',
      year: 2026,
      type: 'tv',
      limit: 50,
      tvNewOnly: true,
    );

    expect(
      results.map((candidate) => candidate.title),
      [
        'Mushoku Tensei III: Isekai Ittara Honki Dasu',
        'Youjo Senki II',
      ],
    );
    expect(results.map((candidate) => candidate.title),
        isNot(contains('One Piece')));
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
    expect(series.imageUrl, 'https://jikan.test/poster.jpg');
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

  test('uses trailing roman numeral sequel title as TMDB season number',
      () async {
    final requestedTmdbPaths = <String>[];
    final service = RemoteCatalogService(
      tmdbApiKey: 'tmdb-key',
      client: MockClient((request) async {
        if (request.url.host != 'api.themoviedb.org') {
          return http.Response('', 404, request: request);
        }
        requestedTmdbPaths.add(request.url.toString());
        expect(request.url.queryParameters['api_key'], 'tmdb-key');
        return switch (request.url.path) {
          '/3/search/tv' => http.Response.bytes(
              utf8.encode(jsonEncode({
                'results': request.url.queryParameters.containsKey(
                          'first_air_date_year',
                        ) ||
                        request.url.queryParameters.containsKey('year')
                    ? []
                    : [
                        {
                          'id': 69346,
                          'name': 'Saga of Tanya the Evil',
                          'original_name': '幼女戦記',
                          'first_air_date': '2017-01-06',
                          'poster_path': '/series-poster.jpg',
                          'backdrop_path': '/series-backdrop.jpg',
                        }
                      ],
              })),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
              request: request,
            ),
          '/3/tv/69346/keywords' => http.Response(
              jsonEncode({
                'results': [
                  {'name': 'anime'}
                ],
              }),
              200,
              request: request,
            ),
          '/3/tv/69346' => http.Response.bytes(
              utf8.encode(jsonEncode({
                'id': 69346,
                'name': 'Saga of Tanya the Evil',
                'original_name': '幼女戦記',
                'first_air_date': '2017-01-06',
                'overview': 'TMDB detail',
                'poster_path': '/series-poster.jpg',
                'backdrop_path': '/series-backdrop.jpg',
                'external_ids': {'tvdb_id': 0},
                'seasons': [
                  {
                    'season_number': 1,
                    'episode_count': 12,
                    'air_date': '2017-01-06',
                  },
                  {
                    'season_number': 2,
                    'episode_count': 12,
                    'air_date': '2026-07-08',
                  },
                ],
              })),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
              request: request,
            ),
          '/3/tv/69346/images' ||
          '/3/tv/69346/season/2/images' =>
            http.Response('{"logos":[],"posters":[]}', 200, request: request),
          '/3/tv/69346/season/2' => http.Response(
              jsonEncode({
                'episodes': [
                  {
                    'episode_number': 1,
                    'name': 'Salamander Combat Team',
                    'overview': 'Episode 1 detail',
                    'still_path': '/youjo-s2e1.jpg',
                    'runtime': 24,
                    'air_date': '2026-07-08',
                  },
                  {
                    'episode_number': 2,
                    'name': 'Episodio 2',
                    'still_path': '/youjo-s2e2.jpg',
                    'runtime': 24,
                    'air_date': '2026-07-15',
                  },
                ],
              }),
              200,
              request: request,
            ),
          _ => http.Response('{"results":[]}', 200, request: request),
        };
      }),
    );

    final series = await service.buildImportSeries(
      const RemoteSearchCandidate(
        provider: RemoteProvider.catalog,
        slug: '49233',
        title: 'Youjo Senki II',
        watchUrl: 'https://myanimelist.net/anime/49233/Youjo_Senki_II',
        imageUrl: 'https://jikan.test/youjo.jpg',
        episodeCount: 12,
        format: 'TV',
        releaseYear: 2026,
        catalogId: 0,
        aliases: ['Saga of Tanya the Evil II'],
      ),
      existingNames: const [],
    );

    expect(
      requestedTmdbPaths.any((url) => url.contains('/3/tv/69346/season/2')),
      isTrue,
      reason: requestedTmdbPaths.join('\n'),
    );
    expect(series.episodes.first.displayName, 'Salamander Combat Team');
    expect(series.episodes.first.imageUrl,
        'https://image.tmdb.org/t/p/w780/youjo-s2e1.jpg');
    expect(series.episodes[1].imageUrl,
        'https://image.tmdb.org/t/p/w780/youjo-s2e2.jpg');
  });

  test('aligns split-cour catalog episodes to TMDB season episodes by air date',
      () async {
    final service = RemoteCatalogService(
      tmdbApiKey: 'tmdb-key',
      client: MockClient((request) async {
        if (request.url.host == 'api.jikan.moe') {
          return switch (request.url.path) {
            '/v4/anime/59229/full' => http.Response(
                jsonEncode({
                  'data': {
                    'mal_id': 59229,
                    'title': 'Enen no Shouboutai: San no Shou Part 2',
                    'url': 'https://myanimelist.net/anime/59229',
                    'type': 'TV',
                    'episodes': 13,
                    'year': 2026,
                    'images': {
                      'jpg': {
                        'large_image_url': 'https://jikan.test/enen.jpg',
                      }
                    },
                  },
                }),
                200,
                request: request,
              ),
            '/v4/anime/59229/episodes' => http.Response(
                jsonEncode({
                  'data': [
                    {
                      'mal_id': 1,
                      'number': 1,
                      'title': 'Unaware',
                      'synopsis': 'Jikan ep 1',
                      'duration': '24 min',
                      'aired': '2026-01-10T00:00:00+00:00',
                    },
                    {
                      'mal_id': 2,
                      'number': 2,
                      'title': 'With the Sun at His Back',
                      'duration': '24 min',
                      'aired': '2026-01-17T00:00:00+00:00',
                    },
                  ],
                  'pagination': {
                    'last_visible_page': 1,
                    'has_next_page': false,
                  },
                }),
                200,
                request: request,
              ),
            _ => http.Response('', 404, request: request),
          };
        }
        if (request.url.host == 'api.themoviedb.org') {
          expect(request.url.queryParameters['api_key'], 'tmdb-key');
          return switch (request.url.path) {
            '/3/tv/88046' => http.Response(
                jsonEncode({
                  'id': 88046,
                  'name': 'Fire Force',
                  'original_name': 'Enen no Shouboutai',
                  'overview': 'Fire Force',
                  'poster_path': '/poster.jpg',
                  'backdrop_path': '/backdrop.jpg',
                  'external_ids': {'tvdb_id': 0},
                  'seasons': [
                    {
                      'season_number': 1,
                      'episode_count': 24,
                      'air_date': '2019-07-06',
                    },
                    {
                      'season_number': 2,
                      'episode_count': 24,
                      'air_date': '2020-07-04',
                    },
                    {
                      'season_number': 3,
                      'episode_count': 25,
                      'air_date': '2025-04-05',
                    },
                  ],
                }),
                200,
                request: request,
              ),
            '/3/tv/88046/images' ||
            '/3/tv/88046/season/3/images' =>
              http.Response('{"logos":[],"posters":[]}', 200, request: request),
            '/3/tv/88046/season/3' => http.Response(
                jsonEncode({
                  'episodes': [
                    {
                      'episode_number': 12,
                      'name': 'The Madness of the Distant Past',
                      'still_path': '/season3-12.jpg',
                      'runtime': 23,
                      'air_date': '2025-06-21',
                    },
                    {
                      'episode_number': 13,
                      'name': 'Unaware',
                      'overview': 'TMDB season 3 episode 13',
                      'still_path': '/season3-13.jpg',
                      'runtime': 24,
                      'air_date': '2026-01-10',
                    },
                    {
                      'episode_number': 14,
                      'name': 'With the Sun at His Back',
                      'still_path': '/season3-14.jpg',
                      'runtime': 24,
                      'air_date': '2026-01-17',
                    },
                  ],
                }),
                200,
                request: request,
              ),
            _ => http.Response('{"results":[]}', 200, request: request),
          };
        }
        return http.Response('', 404, request: request);
      }),
    );

    final series = await service.buildImportSeries(
      const RemoteSearchCandidate(
        provider: RemoteProvider.catalog,
        slug: '59229',
        title: 'Enen no Shouboutai: San no Shou Part 2',
        watchUrl: 'https://myanimelist.net/anime/59229',
        imageUrl: 'https://jikan.test/enen.jpg',
        episodeCount: 13,
        format: 'TV',
        releaseYear: 2026,
        catalogId: 59229,
      ),
      existingNames: const [],
    );

    expect(series.episodes.first.episodeNumber, 1);
    expect(series.episodes.first.displayName, 'Unaware');
    expect(series.episodes.first.description, 'Jikan ep 1');
    expect(series.episodes.first.imageUrl,
        'https://image.tmdb.org/t/p/w780/season3-13.jpg');
    expect(series.episodes[1].imageUrl,
        'https://image.tmdb.org/t/p/w780/season3-14.jpg');
  });

  test('uses AniList episodes as catalog base and TMDB only for dated stills',
      () async {
    final requestedTmdbPaths = <String>[];
    final service = RemoteCatalogService(
      tmdbApiKey: 'tmdb-key',
      client: MockClient((request) async {
        if (request.url.host == 'api.jikan.moe') {
          return http.Response('Jikan unavailable', 504, request: request);
        }
        if (request.url.host == 'animeav1.com') {
          return http.Response('', 404, request: request);
        }
        if (request.url.host == 'graphql.anilist.co') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final query = body['query'] as String;
          if (query.contains('AnimeDetail')) {
            return http.Response.bytes(
              utf8.encode(jsonEncode({
                'data': {
                  'Media': {
                    'id': 182587,
                    'idMal': 60058,
                    'title': {
                      'romaji': '[Oshi no Ko] 3rd Season',
                      'native': '【推しの子】第3期',
                    },
                    'synonyms': ['My Star Season 3'],
                    'description': 'AniList detail',
                    'episodes': 11,
                    'format': 'TV',
                    'averageScore': 87,
                    'startDate': {
                      'year': 2026,
                      'month': 1,
                      'day': 14,
                    },
                    'coverImage': {
                      'extraLarge': 'https://anilist.test/oshi3.jpg',
                    },
                    'bannerImage': 'https://anilist.test/oshi3-bg.jpg',
                  },
                },
              })),
              200,
              request: request,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (query.contains('AnimeAiring')) {
            return http.Response(
              jsonEncode({
                'data': {
                  'Media': {
                    'airingSchedule': {
                      'nodes': [
                        {'episode': 1, 'airingAt': 1768399200},
                      ],
                      'pageInfo': {'hasNextPage': false},
                    },
                  },
                },
              }),
              200,
              request: request,
            );
          }
        }
        if (request.url.host == 'api.themoviedb.org') {
          requestedTmdbPaths.add(request.url.path);
          return switch (request.url.path) {
            '/3/tv/203737' => http.Response.bytes(
                utf8.encode(jsonEncode({
                  'id': 203737,
                  'name': 'Oshi no Ko',
                  'original_name': '【推しの子】',
                  'first_air_date': '2023-04-12',
                  'overview': 'TMDB detail',
                  'poster_path': '/poster.jpg',
                  'backdrop_path': '/backdrop.jpg',
                  'external_ids': {'tvdb_id': 0},
                  'seasons': [
                    {
                      'season_number': 1,
                      'episode_count': 11,
                      'air_date': '2023-04-12',
                    },
                    {
                      'season_number': 3,
                      'episode_count': 11,
                      'air_date': '2026-01-14',
                    },
                  ],
                })),
                200,
                request: request,
                headers: {'content-type': 'application/json; charset=utf-8'},
              ),
            '/3/tv/203737/images' ||
            '/3/tv/203737/season/3/images' =>
              http.Response('{"logos":[],"posters":[]}', 200, request: request),
            '/3/tv/203737/season/3' => http.Response(
                jsonEncode({
                  'episodes': [
                    {
                      'episode_number': 13,
                      'name': 'TMDB absolute episode',
                      'overview': 'TMDB image source',
                      'still_path': '/oshi-absolute-13.jpg',
                      'runtime': 24,
                      'air_date': '2026-01-14',
                    },
                  ],
                }),
                200,
                request: request,
              ),
            _ => http.Response('{"results":[]}', 200, request: request),
          };
        }
        return http.Response('', 404, request: request);
      }),
    );

    final series = await service.buildImportSeries(
      const RemoteSearchCandidate(
        provider: RemoteProvider.catalog,
        slug: '60058',
        title: '[Oshi no Ko] 3rd Season',
        watchUrl: 'https://myanimelist.net/anime/60058',
        episodeCount: 11,
        format: 'TV',
        releaseYear: 2026,
        catalogId: 60058,
      ),
      existingNames: const [],
    );

    expect(series.episodes, hasLength(11));
    expect(requestedTmdbPaths, contains('/3/tv/203737/season/3'));
    expect(series.episodes.first.episodeNumber, 1);
    expect(series.episodes.first.airDateIso, '2026-01-14T14:00:00.000Z');
    expect(series.episodes.first.imageUrl,
        'https://image.tmdb.org/t/p/w780/oshi-absolute-13.jpg');
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

  test('enriches imported catalog series with AniList detail when Jikan fails',
      () async {
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        if (request.url.host == 'api.jikan.moe') {
          return http.Response('Jikan failed', 504, request: request);
        }
        if (request.url.host == 'api.myanimelist.net') {
          return http.Response('MAL failed', 500, request: request);
        }
        if (request.url.host == 'animeav1.com') {
          return http.Response('', 404, request: request);
        }
        if (request.url.host == 'graphql.anilist.co') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final query = body['query'] as String;
          if (query.contains('AnimeDetail')) {
            return http.Response.bytes(
              utf8.encode(jsonEncode({
                'data': {
                  'Media': {
                    'id': 182587,
                    'idMal': 60058,
                    'title': {
                      'romaji': '[Oshi no Ko] 3rd Season',
                      'native': '【推しの子】第3期',
                    },
                    'synonyms': ['My Star Season 3'],
                    'description': 'AniList detail',
                    'episodes': 11,
                    'format': 'TV',
                    'averageScore': 87,
                    'startDate': {
                      'year': 2026,
                      'month': 1,
                      'day': 14,
                    },
                    'coverImage': {
                      'extraLarge': 'https://anilist.test/oshi3.jpg',
                    },
                    'bannerImage': 'https://anilist.test/oshi3-bg.jpg',
                  },
                },
              })),
              200,
              request: request,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (query.contains('AnimeAiring')) {
            return http.Response(
              jsonEncode({
                'data': {
                  'Media': {
                    'airingSchedule': {
                      'nodes': [
                        {'episode': 1, 'airingAt': 1768399200},
                        {'episode': 2, 'airingAt': 1769004000},
                      ],
                      'pageInfo': {'hasNextPage': false},
                    },
                  },
                },
              }),
              200,
              request: request,
            );
          }
        }
        return http.Response('', 404, request: request);
      }),
    );

    final series = await service.buildImportSeries(
      const RemoteSearchCandidate(
        provider: RemoteProvider.catalog,
        slug: '60058',
        title: '[Oshi no Ko] 3rd Season',
        watchUrl: 'https://myanimelist.net/anime/60058',
        episodeCount: 11,
        format: 'TV',
        releaseYear: 2026,
        catalogId: 60058,
      ),
      existingNames: const [],
    );

    expect(series.name, '[Oshi no Ko] 3rd Season');
    expect(series.episodes, hasLength(11));
    expect(series.episodes.first.airDateIso, '2026-01-14T14:00:00.000Z');
    expect(series.episodes[1].airDateIso, '2026-01-21T14:00:00.000Z');
    expect(series.episodes.first.imageUrl, 'https://anilist.test/oshi3.jpg');
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
    expect(stream?.availableServers, contains('mp4upload'));
  });

  test('normalizes JKAnime series page to episode page before resolving',
      () async {
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
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
      filePath: 'https://jkanime.net/demo/',
      watchUrl: 'https://jkanime.net/demo/',
      slug: 'demo',
    ));

    expect(requestedUrls.first, 'https://jkanime.net/demo/1/');
    expect(requestedUrls, isNot(contains('https://jkanime.net/demo/')));
    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/video.mp4');
  });

  test('keeps JKAnime movie page when resolving peliculas', () async {
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://jkanime.net/demo-movie/pelicula/' => http.Response(
              '''
              <html><script>
                var servers = [{
                  "remote":"aHR0cHM6Ly93d3cubXA0dXBsb2FkLmNvbS9lbWJlZC1tb3ZpZS5odG1s",
                  "server":"Mp4upload"
                }];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://www.mp4upload.com/embed-movie.html' => http.Response(
              '''
              <script>
                player.src({ src: "https://cdn.example.test/demo/movie.mp4" });
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
      filePath: 'https://jkanime.net/demo-movie/pelicula/',
      watchUrl: 'https://jkanime.net/demo-movie/',
      slug: 'demo-movie',
    ));

    expect(requestedUrls.first, 'https://jkanime.net/demo-movie/pelicula/');
    expect(requestedUrls, isNot(contains('https://jkanime.net/demo-movie/1/')));
    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/movie.mp4');
  });

  test('normalizes JKAnime movie series page to pelicula page before resolving',
      () async {
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://jkanime.net/demo-movie/pelicula/' => http.Response(
              '''
              <html><script>
                var servers = [{
                  "remote":"aHR0cHM6Ly93d3cubXA0dXBsb2FkLmNvbS9lbWJlZC1tb3ZpZS5odG1s",
                  "server":"Mp4upload"
                }];
              </script></html>
              ''',
              200,
              request: request,
            ),
          'https://www.mp4upload.com/embed-movie.html' => http.Response(
              '''
              <script>
                player.src({ src: "https://cdn.example.test/demo/movie.mp4" });
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
      filePath: 'https://jkanime.net/demo-movie/',
      watchUrl: 'https://jkanime.net/demo-movie/',
      slug: 'demo-movie',
      relativePath: 'JKAnime / Pelicula',
    ));

    expect(requestedUrls.first, 'https://jkanime.net/demo-movie/pelicula/');
    expect(requestedUrls, isNot(contains('https://jkanime.net/demo-movie/1/')));
    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/movie.mp4');
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
    expect(stream?.httpHeaders['Referer'],
        'https://www.mp4upload.com/embed-window.html');
    expect(stream?.httpHeaders['Origin'], 'https://www.mp4upload.com');
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

  test('resolves BiliBili dash media through local manifest proxy', () async {
    const pageUrl = 'https://www.bilibili.tv/en/video/2044128968';
    const videoUrl =
        'https://upos.example.test/kirarin-111210.m4s?e=abc&uipk=1';
    const audioUrl = 'https://upos.example.test/kirarin-1a130.m4s?e=abc&uipk=1';
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          pageUrl => http.Response(
              '''
              <script>
                window.__initialState={"duration":1376,
                  "video":"${videoUrl.replaceAll('/', r'\/').replaceAll('&', r'\u0026')}",
                  "audio":"${audioUrl.replaceAll('/', r'\/').replaceAll('&', r'\u0026')}"
                };
              </script>
              ''',
              200,
              request: request,
            ),
          videoUrl => http.Response.bytes(
              const [0, 1, 2, 3],
              206,
              headers: const {
                'content-type': 'video/mp4',
                'content-range': 'bytes 0-3/4',
                'accept-ranges': 'bytes',
              },
              request: request,
            ),
          audioUrl => http.Response.bytes(
              const [4, 5, 6, 7],
              206,
              headers: const {
                'content-type': 'audio/mp4',
                'content-range': 'bytes 0-3/4',
                'accept-ranges': 'bytes',
              },
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.bilibili,
        filePath: pageUrl,
        watchUrl: pageUrl,
        slug: '2044128968',
      ),
    );
    addTearDown(service.close);

    expect(stream?.playbackKind, 'dash');
    expect(stream?.server, 'bilibili-1');
    expect(stream?.httpHeaders['X-Tanuki-Vlc-Hls-Url'], isNotEmpty);
    expect(stream?.httpHeaders['X-Tanuki-Vlc-Video-Url'], isNotEmpty);
    expect(stream?.httpHeaders['X-Tanuki-Vlc-Audio-Url'], isNotEmpty);
    expect(stream?.httpHeaders['X-Tanuki-Vlc-Playlist-Url'], isNotEmpty);
    expect(stream?.httpHeaders['X-Tanuki-Vlc-Playlist-Path'], isNotEmpty);
    final manifest = await http.get(Uri.parse(stream!.playbackUrl));
    expect(manifest.statusCode, 200);
    expect(manifest.body, contains('mediaPresentationDuration="PT1376S"'));
    expect(manifest.body, contains('<SegmentList'));
    expect(manifest.body, contains('video.m4s'));
    expect(manifest.body, contains('audio.m4s'));
    final vlcPlaylist = await http.get(
      Uri.parse(stream.httpHeaders['X-Tanuki-Vlc-Playlist-Url']!),
    );
    expect(vlcPlaylist.statusCode, 200);
    expect(vlcPlaylist.body, contains('#EXTVLCOPT:input-slave='));
    expect(vlcPlaylist.body, contains('/audio.m4s'));
    expect(vlcPlaylist.body, contains('/video.m4s'));
    final localVlcPlaylist = await io.File(
      stream.httpHeaders['X-Tanuki-Vlc-Playlist-Path']!,
    ).readAsString();
    expect(localVlcPlaylist, contains('#EXTVLCOPT:input-slave='));
    expect(localVlcPlaylist, contains('/audio.m4s'));
    expect(localVlcPlaylist, contains('/video.m4s'));
    final vlcHls = await http.get(
      Uri.parse(stream.httpHeaders['X-Tanuki-Vlc-Hls-Url']!),
    );
    expect(vlcHls.statusCode, 200);
    expect(vlcHls.body, contains('#EXT-X-MEDIA:TYPE=AUDIO'));
    expect(vlcHls.body, contains('/audio.m3u8'));
    expect(vlcHls.body, contains('/video.m3u8'));
    final vlcHlsWithStart = await http.get(
      Uri.parse(stream.httpHeaders['X-Tanuki-Vlc-Hls-Url']!)
          .replace(queryParameters: const {'start': '296'}),
    );
    expect(vlcHlsWithStart.statusCode, 200);
    expect(
      vlcHlsWithStart.body,
      contains('#EXT-X-START:TIME-OFFSET=296.000,PRECISE=YES'),
    );
    expect(vlcHlsWithStart.body, contains('/audio.m3u8?start=296'));
    expect(vlcHlsWithStart.body, contains('/video.m3u8?start=296'));
    final audioPlaylist = await http.get(
      Uri.parse(stream.httpHeaders['X-Tanuki-Vlc-Hls-Url']!)
          .replace(path: '/audio.m3u8'),
    );
    expect(audioPlaylist.statusCode, 200);
    expect(audioPlaylist.body, contains('/audio.m4s'));
    final audioPlaylistWithStart = await http.get(
      Uri.parse(stream.httpHeaders['X-Tanuki-Vlc-Hls-Url']!).replace(
          path: '/audio.m3u8', queryParameters: const {'start': '296'}),
    );
    expect(audioPlaylistWithStart.statusCode, 200);
    expect(
      audioPlaylistWithStart.body,
      contains('#EXT-X-START:TIME-OFFSET=296.000,PRECISE=YES'),
    );

    final videoResponse = await http.get(
      Uri.parse(stream.httpHeaders['X-Tanuki-Vlc-Video-Url']!),
      headers: const {'Range': 'bytes=0-3'},
    );
    expect(videoResponse.statusCode, 206);
    expect(videoResponse.bodyBytes, const [0, 1, 2, 3]);
    expect(requestedUrls, contains(videoUrl));
    final audioResponse = await http.get(
      Uri.parse(stream.httpHeaders['X-Tanuki-Vlc-Audio-Url']!),
      headers: const {'Range': 'bytes=0-3'},
    );
    expect(audioResponse.statusCode, 206);
    expect(audioResponse.bodyBytes, const [4, 5, 6, 7]);
    expect(requestedUrls, contains(audioUrl));
  });

  test('probes real JKAnime servers with ffprobe', () async {
    const pageUrl =
        'https://jkanime.net/disney-twisted-wonderland-the-animation-episode-of-heartslabyul/1/';
    const seriesUrl =
        'https://jkanime.net/disney-twisted-wonderland-the-animation-episode-of-heartslabyul/';
    const servers = [
      'desu',
      'magi',
      'streamwish',
      'mp4upload',
      'vidhide',
      'mixdrop',
      'voe',
      'filemoon',
      'doodstream',
      'stape',
    ];
    final playable = <String>{};
    for (final server in servers) {
      final service = RemoteCatalogService();
      try {
        final stream = await service.resolveDirectStream(
          _episode(
            provider: RemoteProvider.jkAnime,
            filePath: pageUrl,
            watchUrl: seriesUrl,
            slug:
                'disney-twisted-wonderland-the-animation-episode-of-heartslabyul',
          ),
          preferredServer: server,
        );
        if (stream == null) {
          // ignore: avoid_print
          print('JKAnime $server: resolver returned null');
          continue;
        }
        final headers = stream.httpHeaders.entries
            .map((entry) => '${entry.key}: ${entry.value}\r\n')
            .join();
        final probe = await io.Process.run('ffprobe', [
          '-v',
          'error',
          if (headers.isNotEmpty) ...['-headers', headers],
          '-print_format',
          'json',
          '-show_streams',
          stream.playbackUrl,
        ]).timeout(const Duration(seconds: 30));
        final decoded = probe.exitCode == 0
            ? jsonDecode('${probe.stdout}') as Map<String, dynamic>
            : const <String, dynamic>{};
        final types = (decoded['streams'] as List? ?? const [])
            .whereType<Map>()
            .map((entry) => '${entry['codec_type']}')
            .toSet();
        if (types.contains('video') && types.contains('audio')) {
          playable.add(server);
        }
        // ignore: avoid_print
        print(
          'JKAnime $server: resolved=${stream.server} '
          'kind=${stream.playbackKind} types=$types exit=${probe.exitCode}',
        );
      } catch (error) {
        // ignore: avoid_print
        print('JKAnime $server: $error');
      } finally {
        service.close();
      }
    }
    expect(playable, contains('desu'));
    expect(playable, contains('magi'));
  },
      skip: io.Platform.environment['RUN_JKANIME_PROBE'] != '1',
      timeout: const Timeout(Duration(minutes: 8)));

  test('probes real BiliBili dash media with ffprobe', () async {
    const pageUrl = 'https://www.bilibili.tv/en/video/2044128968';
    final service = RemoteCatalogService();
    addTearDown(service.close);

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.bilibili,
        filePath: pageUrl,
        watchUrl: pageUrl,
        slug: '2044128968',
      ),
    );

    expect(stream, isNotNull);
    expect(stream?.playbackKind, 'dash');
    expect(stream?.httpHeaders['X-Tanuki-Duration-Seconds'], '1376');

    final manifestResponse = await http.get(Uri.parse(stream!.playbackUrl));
    expect(manifestResponse.statusCode, 200);
    expect(
      manifestResponse.body,
      contains('mediaPresentationDuration="PT1376S"'),
    );

    Future<
        ({
          int exitCode,
          Set<String> streamTypes,
          double duration,
          String stderr
        })> probeUrl(String url) async {
      final probe = await io.Process.run(
        'ffprobe',
        [
          '-v',
          'error',
          '-print_format',
          'json',
          '-show_streams',
          '-show_format',
          url,
        ],
      ).timeout(const Duration(seconds: 45));
      if (probe.exitCode != 0) {
        return (
          exitCode: probe.exitCode,
          streamTypes: <String>{},
          duration: 0.0,
          stderr: '${probe.stderr}\n${probe.stdout}',
        );
      }
      final decoded = jsonDecode('${probe.stdout}') as Map<String, dynamic>;
      final streams = (decoded['streams'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final streamTypes = streams
          .map((entry) => '${entry['codec_type']}'.trim())
          .where((entry) => entry.isNotEmpty)
          .toSet();
      final duration = double.tryParse(
            '${(decoded['format'] as Map<String, dynamic>?)?['duration']}',
          ) ??
          0;
      return (
        exitCode: probe.exitCode,
        streamTypes: streamTypes,
        duration: duration,
        stderr: '${probe.stderr}',
      );
    }

    final dashProbe = await probeUrl(stream.playbackUrl);
    final hlsProbe =
        await probeUrl(stream.httpHeaders['X-Tanuki-Vlc-Hls-Url']!);
    final hlsStartProbe = await probeUrl(
      Uri.parse(stream.httpHeaders['X-Tanuki-Vlc-Hls-Url']!)
          .replace(queryParameters: const {'start': '296'}).toString(),
    );
    final playlistProbe =
        await probeUrl(stream.httpHeaders['X-Tanuki-Vlc-Playlist-Url']!);
    // Keep these prints in the opt-in probe; they are the diagnostic output.
    // ignore: avoid_print
    print('BiliBili DASH ${stream.playbackUrl}: $dashProbe');
    // ignore: avoid_print
    print(
      'BiliBili HLS ${stream.httpHeaders['X-Tanuki-Vlc-Hls-Url']}: $hlsProbe',
    );
    // ignore: avoid_print
    print(
      'BiliBili HLS start '
      '${stream.httpHeaders['X-Tanuki-Vlc-Hls-Url']}?start=296: '
      '$hlsStartProbe',
    );
    // ignore: avoid_print
    print(
      'BiliBili VLC playlist '
      '${stream.httpHeaders['X-Tanuki-Vlc-Playlist-Url']}: $playlistProbe',
    );

    final probe = dashProbe;
    expect(probe.exitCode, 0, reason: probe.stderr);
    expect(probe.streamTypes, contains('video'));
    expect(probe.streamTypes, contains('audio'));
    expect(probe.duration, greaterThan(1300));

    expect(hlsProbe.exitCode, 0, reason: hlsProbe.stderr);
    expect(hlsProbe.streamTypes, contains('video'));
    expect(hlsProbe.streamTypes, contains('audio'));
    expect(hlsProbe.duration, greaterThan(1300));
    expect(hlsStartProbe.exitCode, 0, reason: hlsStartProbe.stderr);
    expect(hlsStartProbe.streamTypes, contains('video'));
    expect(hlsStartProbe.streamTypes, contains('audio'));
  }, skip: io.Platform.environment['RUN_BILIBILI_PROBE'] != '1');

  test('probes real YouTube search returns expected dub option', () async {
    final service = RemoteCatalogService();
    addTearDown(service.close);

    final youtubeEpisode = await service.resolveProviderEpisode(
      series: _kaitouSaintTailSeries(),
      episode: _kaitouSaintTailEpisode(),
      provider: RemoteProvider.youtube,
    );

    expect(youtubeEpisode, isNotNull);
    expect(youtubeEpisode?.provider, RemoteProvider.youtube);
    expect(youtubeEpisode?.description, contains('youtube-dub-1'));
    expect(youtubeEpisode?.description, contains('1nePXee26HA'));
  }, skip: io.Platform.environment['RUN_YOUTUBE_PROBE'] != '1');

  test('probes real YouTube direct muxed stream', () async {
    final service = RemoteCatalogService();
    addTearDown(service.close);
    const targetUrl = 'https://www.youtube.com/watch?v=1nePXee26HA';
    final youtubeEpisode = await service.resolveProviderEpisode(
      series: _kaitouSaintTailSeries(),
      episode: _kaitouSaintTailEpisode(),
      provider: RemoteProvider.youtube,
    );
    expect(youtubeEpisode, isNotNull);

    final stream = await service.resolveDirectStream(
      youtubeEpisode!,
      preferredMode: YoutubePlaybackMode.dub.id,
      preferredServer: 'youtube-dub-1',
    );

    expect(stream, isNotNull);
    expect(stream?.provider, RemoteProvider.youtube);
    expect(stream?.server, 'youtube-dub-1');
    expect(stream?.pageUrl, targetUrl);
    expect(stream?.playbackUrl, startsWith('http'));
    expect(stream?.playbackKind, anyOf('mp4', 'direct'));

    final probe = await _probeMediaUrlWithFfprobe(stream!.playbackUrl);
    expect(probe.exitCode, 0, reason: probe.stderr);
    expect(probe.streamTypes, contains('video'));
    expect(probe.streamTypes, contains('audio'));
    expect(probe.duration, greaterThan(1400));
  }, skip: io.Platform.environment['RUN_YOUTUBE_STREAM_PROBE'] != '1');

  test('probes real YouTube with yt-dlp direct stream', () async {
    final ytDlpVersion = await io.Process.run('yt-dlp', ['--version']);
    expect(ytDlpVersion.exitCode, 0, reason: 'yt-dlp no esta instalado');

    final service = RemoteCatalogService();
    addTearDown(service.close);
    const targetUrl = 'https://www.youtube.com/watch?v=1nePXee26HA';
    final youtubeEpisode = await service.resolveProviderEpisode(
      series: _kaitouSaintTailSeries(),
      episode: _kaitouSaintTailEpisode(),
      provider: RemoteProvider.youtube,
    );

    expect(youtubeEpisode, isNotNull);
    expect(youtubeEpisode?.description, contains('youtube-dub-1'));
    expect(youtubeEpisode?.description, contains('1nePXee26HA'));

    final directEntry = youtubeEpisode!.copyWith(
      filePath: '$targetUrl&t=746s',
      watchUrl: '$targetUrl&t=746s',
      description: '',
      slug: '1nePXee26HA',
    );
    final stream = await service.resolveDirectStream(
      directEntry,
      preferredMode: YoutubePlaybackMode.dub.id,
      preferredServer: 'youtube-dub-1',
    );

    expect(stream, isNotNull);
    expect(stream?.provider, RemoteProvider.youtube);
    expect(stream?.server, 'youtube-sub-1');
    expect(stream?.pageUrl, targetUrl);
    expect(stream?.playbackUrl, startsWith('http'));
    expect(stream?.playbackKind, anyOf('mp4', 'hls', 'direct'));
  }, skip: io.Platform.environment['RUN_YTDLP_PROBE'] != '1');

  test(
      'resolves BiliBili provider episode from first two episode search videos',
      () async {
    final requestedUrls = <String>[];
    const page222 = 'https://www.bilibili.tv/en/video/222';
    const videoUrl =
        'https://upos.example.test/kirarin-114-111210.m4s?e=abc&uipk=1';
    const audioUrl =
        'https://upos.example.test/kirarin-114-1a130.m4s?e=abc&uipk=1';
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        if (request.url.host == 'www.bilibili.tv' &&
            request.url.path == '/en/search-result') {
          expect(
            request.url.queryParameters['q'],
            'Kirarin Revolution episode 114',
          );
          return http.Response(
            '''
            <a href="/en/video/111" class="bstar-video-card__cover-link">
              <img src="//img.example.test/111.jpg" alt="Kirarin Revolution ep. 114">
              <span class="bstar-video-card__cover-mask-text">22:55</span>
            </a>
            <a href="/en/video/222" class="bstar-video-card__cover-link">
              <img src="//img.example.test/222.jpg" alt="Kirarin Revolution ep. 114 sub">
              <span class="bstar-video-card__cover-mask-text">22:56</span>
            </a>
            <a href="/en/video/333" class="bstar-video-card__cover-link">
              <img src="//img.example.test/333.jpg" alt="Kirarin Revolution ep. 115">
              <span class="bstar-video-card__cover-mask-text">22:56</span>
            </a>
            ''',
            200,
            request: request,
          );
        }
        if (request.url.toString() == page222) {
          return http.Response(
            '''
            <script>
              window.__initialState={"duration":1376,
                "video":"${videoUrl.replaceAll('/', r'\/').replaceAll('&', r'\u0026')}",
                "audio":"${audioUrl.replaceAll('/', r'\/').replaceAll('&', r'\u0026')}"
              };
            </script>
            ''',
            200,
            request: request,
          );
        }
        if (request.url.toString() == videoUrl ||
            request.url.toString() == audioUrl) {
          return http.Response.bytes(
            const [0, 1],
            206,
            headers: const {'content-type': 'video/mp4'},
            request: request,
          );
        }
        return http.Response('', 404, request: request);
      }),
    );
    addTearDown(service.close);

    final series = SeriesItem(
      name: 'Kirarin☆Revolution',
      seriesStateKey: 'kirarin-revolution',
      sourceType: SourceType.remote,
      episodeCount: 153,
      episodes: const [],
    );
    final episode = _episode(
      provider: RemoteProvider.catalog,
      filePath: 'https://myanimelist.net/anime/1516',
      watchUrl: 'https://myanimelist.net/anime/1516',
      slug: '1516',
      episodeNumber: 114,
    );

    final resolvedEpisode = await service.resolveProviderEpisode(
      series: series,
      episode: episode,
      provider: RemoteProvider.bilibili,
    );
    expect(resolvedEpisode?.filePath, 'https://www.bilibili.tv/en/video/111');

    final stream = await service.resolveDirectStream(
      resolvedEpisode!,
      excludedServers: const {'bilibili-1'},
    );
    expect(stream?.server, 'bilibili-2');
    expect(stream?.pageUrl, 'https://www.bilibili.tv/en/video/222');
    expect(requestedUrls, contains(page222));
  });

  test('resolves Internet Archive episode and rejects longplay results',
      () async {
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        if (request.url.host == 'archive.org' &&
            request.url.path == '/advancedsearch.php') {
          expect(
            request.url.queryParameters['q'],
            'Kaitou Saint Tail AND mediatype:movies',
          );
          expect(
            request.url.queryParametersAll['fl[]'],
            containsAll(['identifier', 'title', 'description']),
          );
          return http.Response(
            jsonEncode({
              'response': {
                'docs': [
                  {
                    'identifier': 'kaitou-saint-tail-longplay',
                    'title': 'Sega Master System Longplay - Kaitou Saint Tail',
                    'description': 'Video game longplay',
                    'year': 2025,
                  },
                  {
                    'identifier': 'las-aventuras-de-saint-tail',
                    'title': 'Las Aventuras de Saint Tail',
                    'description': 'Serie completa',
                    'year': 2014,
                  },
                ],
              },
            }),
            200,
            request: request,
          );
        }
        if (request.url.toString() ==
            'https://archive.org/metadata/las-aventuras-de-saint-tail') {
          return http.Response(
            jsonEncode({
              'files': [
                {
                  'name':
                      'Las Aventuras de Saint Tail Capitulo 01 Espanol Latino HD.avi',
                  'source': 'original',
                  'format': 'AVI',
                  'length': '1495',
                },
                {
                  'name':
                      'Las Aventuras de Saint Tail Capitulo 01 Espanol Latino HD.mp4',
                  'source': 'derivative',
                  'format': 'MPEG4',
                  'length': '1495',
                },
                {
                  'name':
                      'Las Aventuras de Saint Tail Capitulo 02 Espanol Latino HD.mp4',
                  'source': 'derivative',
                  'format': 'MPEG4',
                  'length': '1764',
                },
                {
                  'name':
                      'Las Aventuras de Saint Tail 100% extra Capitulo 99.mp4',
                  'source': 'derivative',
                  'format': 'MPEG4',
                  'length': '60',
                },
              ],
            }),
            200,
            request: request,
          );
        }
        if (request.url.toString() ==
            'https://archive.org/details/las-aventuras-de-saint-tail/'
                'Las%20Aventuras%20de%20Saint%20Tail%20Capitulo%2001%20Espanol%20Latino%20HD.mp4') {
          final playlist = jsonEncode([
            {
              'title':
                  'Las Aventuras de Saint Tail Capitulo 01 Espanol Latino HD',
              'orig':
                  'Las Aventuras de Saint Tail Capitulo 01 Espanol Latino HD.mp4',
              'duration': 1495,
              'sources': [
                {
                  'file':
                      '/download/las-aventuras-de-saint-tail/Las%20Aventuras%20de%20Saint%20Tail%20Capitulo%2001%20Espanol%20Latino%20HD.mp4',
                  'type': 'mp4',
                  'height': '1080',
                },
              ],
            },
            {
              'title':
                  'Las Aventuras de Saint Tail Capitulo 02 Espanol Latino HD',
              'orig':
                  'Las Aventuras de Saint Tail Capitulo 02 Espanol Latino HD.mp4',
              'duration': 1764,
              'sources': [
                {
                  'file':
                      '/download/las-aventuras-de-saint-tail/Las%20Aventuras%20de%20Saint%20Tail%20Capitulo%2002%20Espanol%20Latino%20HD.mp4',
                  'type': 'mp4',
                  'height': '1080',
                },
              ],
            },
          ]).replaceAll('"', '&quot;');
          return http.Response(
            '<html><body><play-av playlist="$playlist"></play-av></body></html>',
            200,
            request: request,
          );
        }
        return http.Response('', 404, request: request);
      }),
    );
    addTearDown(service.close);

    final resolvedEpisode = await service.resolveProviderEpisode(
      series: _kaitouSaintTailSeries(),
      episode: _kaitouSaintTailEpisode(),
      provider: RemoteProvider.internetArchive,
    );

    expect(resolvedEpisode, isNotNull);
    expect(resolvedEpisode?.provider, RemoteProvider.internetArchive);
    expect(
      resolvedEpisode?.filePath,
      'https://archive.org/download/las-aventuras-de-saint-tail/'
      'Las%20Aventuras%20de%20Saint%20Tail%20Capitulo%2001%20Espanol%20Latino%20HD.mp4',
    );
    expect(
      resolvedEpisode?.watchUrl,
      'https://archive.org/details/las-aventuras-de-saint-tail/'
      'Las%20Aventuras%20de%20Saint%20Tail%20Capitulo%2001%20Espanol%20Latino%20HD.mp4',
    );
    expect(resolvedEpisode?.relativePath, contains('Internet Archive /'));
    expect(resolvedEpisode?.durationLabel, '24:55');
    expect(
      requestedUrls,
      isNot(
          contains('https://archive.org/metadata/kaitou-saint-tail-longplay')),
    );

    final stream = await service.resolveDirectStream(resolvedEpisode!);
    expect(stream?.provider, RemoteProvider.internetArchive);
    expect(stream?.server, 'archive-direct');
    expect(
      stream?.playbackUrl,
      'https://archive.org/download/las-aventuras-de-saint-tail/'
      'Las%20Aventuras%20de%20Saint%20Tail%20Capitulo%2001%20Espanol%20Latino%20HD.mp4',
    );
    expect(stream?.pageUrl, resolvedEpisode.watchUrl);
    expect(stream?.httpHeaders['X-Tanuki-Duration-Seconds'], '1495');
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

    expect(stream?.playbackKind, 'mp4');
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/mp4upload.mp4');
    expect(stream?.server, 'mp4upload');
  });

  test('uses Magi before Desu in JKAnime automatic host order', () async {
    final desuUrl =
        base64Encode(utf8.encode('https://generic-player.test/embed/desu'));
    final magiUrl =
        base64Encode(utf8.encode('https://generic-player.test/embed/magi'));
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
                  {"remote":"$magiUrl","server":"Magi"}
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
          'https://generic-player.test/embed/magi' => http.Response(
              '''
              <script>file: "https://cdn.example.test/demo/magi.m3u8"</script>
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
    expect(stream?.playbackUrl, 'https://cdn.example.test/demo/magi.m3u8');
    expect(stream?.server, 'magi');
    expect(requestedUrls,
        isNot(contains('https://generic-player.test/embed/desu')));
  });

  test('keeps JKAnime Desu native HLS before download host fallback', () async {
    final desuUrl = base64Encode(
      utf8.encode('https://jkanime.net/jkplayer/um?e=demo&t=token'),
    );
    final streamTapeUrl = base64Encode(
      utf8.encode('https://streamtape.com/e/demo/demo.mp4'),
    );
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://jkanime.net/demo/1/' => http.Response(
              '''
              <script>
                video[0] = '<iframe src="https://jkanime.net/jkplayer/um?e=demo&t=token"></iframe>';
                var servers = [
                  {"remote":"$desuUrl","server":"Desu"},
                  {"remote":"$streamTapeUrl","server":"Streamtape"}
                ];
              </script>
              ''',
              200,
              request: request,
            ),
          'https://jkanime.net/jkplayer/um?e=demo&t=token' => http.Response(
              '''
              <script>
                const player = {
                  video: {
                    url: 'https://nika.playmudos.com/demo/desu.m3u8',
                    type: 'customHls'
                  }
                };
              </script>
              ''',
              200,
              request: request,
            ),
          'https://streamtape.com/e/demo/demo.mp4' => http.Response(
              '''
              <div id="botlink">//streamtape.com/get_video?id=demo</div>
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
      preferredServer: 'desu',
    );

    expect(stream?.playbackUrl, 'https://nika.playmudos.com/demo/desu.m3u8');
    expect(stream?.server, 'desu');
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

  test('keeps AnimeAV1 episode zero urls when resolving specials', () async {
    final requestedUrls = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        requestedUrls.add(request.url.toString());
        return switch (request.url.toString()) {
          'https://animeav1.com/media/mushoku-tensei-ii-isekai-ittara-honki-dasu/0' =>
            http.Response(
              '''
              <script>
                data:[{type:"data",data:{episode:{number:0},
                embeds:{SUB:[{server:"HLS",url:"https://player.zilla-networks.com/play/00000000000000000000000000000000"}]}}}]
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
        episodeNumber: 0,
        filePath:
            'https://animeav1.com/media/mushoku-tensei-ii-isekai-ittara-honki-dasu/0',
        watchUrl:
            'https://animeav1.com/media/mushoku-tensei-ii-isekai-ittara-honki-dasu',
        slug: 'mushoku-tensei-ii-isekai-ittara-honki-dasu',
      ),
    );

    expect(
      requestedUrls,
      contains(
        'https://animeav1.com/media/mushoku-tensei-ii-isekai-ittara-honki-dasu/0',
      ),
    );
    expect(
      requestedUrls,
      isNot(
        contains(
          'https://animeav1.com/media/mushoku-tensei-ii-isekai-ittara-honki-dasu/1',
        ),
      ),
    );
    expect(stream?.selectedMode, 'sub-hls');
    expect(
      stream?.playbackUrl,
      'https://player.zilla-networks.com/m3u8/00000000000000000000000000000000',
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

  test('rejects WebView AnimeAV1 HLS when segments remain protected', () async {
    const streamId = '33666400d29fbaf3f499efc5eff29c0d';
    final segmentCookies = <String>[];
    final webResolver = _FakeRemoteWebResolver(
      const RemoteDirectStream(
        playbackUrl: 'https://player.zilla-networks.com/m3u8/$streamId',
        playbackKind: 'hls',
        pageUrl: 'https://player.zilla-networks.com/play/$streamId',
        selectedMode: 'android-webview',
        httpHeaders: {'Cookie': 'zilla=session'},
      ),
    );
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://animeav1.com/media/tensei-shitara-slime-datta-ken/2' =>
            http.Response(
              '''
              <script>
                data:[{type:"data",data:{episode:{number:2},
                embeds:{SUB:[{server:"HLS",url:"https://player.zilla-networks.com/play/$streamId"}]}}}]
              </script>
              ''',
              200,
              request: request,
            ),
          'https://player.zilla-networks.com/m3u8/$streamId' => http.Response(
              '''
              #EXTM3U
              #EXT-X-VERSION:7
              #EXT-X-MAP:URI="https://player.zilla-networks.com/segs/$streamId/init.html"
              #EXTINF:10.0,
              https://player.zilla-networks.com/segs/$streamId/000.html
              ''',
              200,
              request: request,
            ),
          'https://player.zilla-networks.com/segs/$streamId/init.html' => () {
              segmentCookies.add(request.headers['Cookie'] ?? '');
              return http.Response(
                '<html>blocked</html>',
                403,
                request: request,
              );
            }(),
          _ => http.Response('', 404, request: request),
        };
      }),
      webResolver: webResolver,
    );
    addTearDown(service.close);

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.animeAv1,
        episodeNumber: 2,
        filePath: 'https://animeav1.com/media/tensei-shitara-slime-datta-ken/2',
        watchUrl: 'https://animeav1.com/media/tensei-shitara-slime-datta-ken',
        slug: 'tensei-shitara-slime-datta-ken',
      ),
    );

    expect(webResolver.requests, hasLength(1));
    expect(
      webResolver.requests.single.pageUrl,
      'https://animeav1.com/media/tensei-shitara-slime-datta-ken/2',
    );
    expect(webResolver.requests.single.preferredServer, 'mp4upload');
    expect(segmentCookies, ['', 'zilla=session']);
    expect(stream, isNull);
  });

  test('uses MP4Upload HTTP fallback when AnimeAV1 Zilla is protected',
      () async {
    const streamId = '33666400d29fbaf3f499efc5eff29c0d';
    final segmentCookies = <String>[];
    final webResolver = _FakeRemoteWebResolver(null);
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://animeav1.com/media/tensei-shitara-slime-datta-ken/2' =>
            http.Response(
              '''
              <script>
                data:[{type:"data",data:{episode:{number:2},
                embeds:{SUB:[
                  {server:"HLS",url:"https://player.zilla-networks.com/play/$streamId"},
                  {server:"MP4Upload",url:"https://www.mp4upload.com/embed-demo.html"}
                ]}}}]
              </script>
              ''',
              200,
              request: request,
            ),
          'https://player.zilla-networks.com/m3u8/$streamId' => http.Response(
              '''
              #EXTM3U
              #EXT-X-VERSION:7
              #EXT-X-MAP:URI="https://player.zilla-networks.com/segs/$streamId/init.html"
              #EXTINF:10.0,
              https://player.zilla-networks.com/segs/$streamId/000.html
              ''',
              200,
              request: request,
            ),
          'https://player.zilla-networks.com/segs/$streamId/init.html' => () {
              segmentCookies.add(request.headers['Cookie'] ?? '');
              return http.Response(
                '<html>blocked</html>',
                403,
                request: request,
              );
            }(),
          'https://www.mp4upload.com/embed-demo.html' => http.Response(
              '''
              <script>
                player.src({ src: "https://cdn.example.test/animeav1/mp4upload.mp4" });
              </script>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
      webResolver: webResolver,
    );

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.animeAv1,
        episodeNumber: 2,
        filePath: 'https://animeav1.com/media/tensei-shitara-slime-datta-ken/2',
        watchUrl: 'https://animeav1.com/media/tensei-shitara-slime-datta-ken',
        slug: 'tensei-shitara-slime-datta-ken',
      ),
    );

    expect(webResolver.requests, isEmpty);
    expect(segmentCookies, ['']);
    expect(stream?.playbackUrl, startsWith('http://127.0.0.1:'));
    expect(stream?.playbackKind, 'mp4');
    expect(stream?.selectedMode, AnimeAv1PlaybackMode.subHls.id);
    expect(stream?.server, 'mp4upload');
    expect(stream?.httpHeaders['X-Tanuki-Upstream-Url'],
        'https://cdn.example.test/animeav1/mp4upload.mp4');
  });

  test('uses DUB MP4Upload fallback when AnimeAV1 DUB Zilla is protected',
      () async {
    const subStreamId = '11116400d29fbaf3f499efc5eff29c0d';
    const dubStreamId = '22226400d29fbaf3f499efc5eff29c0d';
    final segmentRequests = <String>[];
    final embedRequests = <String>[];
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://animeav1.com/media/tensei-shitara-slime-datta-ken/2' =>
            http.Response(
              '''
              <script>
                data:[{type:"data",data:{episode:{number:2},
                embeds:{
                  SUB:[
                    {server:"HLS",url:"https://player.zilla-networks.com/play/$subStreamId"},
                    {server:"MP4Upload",url:"https://www.mp4upload.com/embed-sub.html"}
                  ],
                  DUB:[
                    {server:"HLS",url:"https://player.zilla-networks.com/play/$dubStreamId"},
                    {server:"MP4Upload",url:"https://www.mp4upload.com/embed-dub.html"}
                  ]
                }}}]
              </script>
              ''',
              200,
              request: request,
            ),
          'https://player.zilla-networks.com/m3u8/$dubStreamId' =>
            http.Response(
              '''
              #EXTM3U
              #EXT-X-VERSION:7
              #EXT-X-MAP:URI="https://player.zilla-networks.com/segs/$dubStreamId/init.html"
              #EXTINF:10.0,
              https://player.zilla-networks.com/segs/$dubStreamId/000.html
              ''',
              200,
              request: request,
            ),
          'https://player.zilla-networks.com/segs/$dubStreamId/init.html' =>
            () {
              segmentRequests.add(request.url.toString());
              return http.Response(
                '<html>blocked</html>',
                403,
                request: request,
              );
            }(),
          'https://www.mp4upload.com/embed-dub.html' => () {
              embedRequests.add(request.url.toString());
              return http.Response(
                '''
                <script>
                  player.src({ src: "https://cdn.example.test/animeav1/dub.mp4" });
                </script>
                ''',
                200,
                request: request,
              );
            }(),
          'https://www.mp4upload.com/embed-sub.html' => () {
              embedRequests.add(request.url.toString());
              return http.Response(
                '''
                <script>
                  player.src({ src: "https://cdn.example.test/animeav1/sub.mp4" });
                </script>
                ''',
                200,
                request: request,
              );
            }(),
          _ => http.Response('', 404, request: request),
        };
      }),
    );
    addTearDown(service.close);

    final stream = await service.resolveDirectStream(
      _episode(
        provider: RemoteProvider.animeAv1,
        episodeNumber: 2,
        filePath: 'https://animeav1.com/media/tensei-shitara-slime-datta-ken/2',
        watchUrl: 'https://animeav1.com/media/tensei-shitara-slime-datta-ken',
        slug: 'tensei-shitara-slime-datta-ken',
      ),
      preferredMode: AnimeAv1PlaybackMode.dubHls.id,
    );

    expect(segmentRequests, [
      'https://player.zilla-networks.com/segs/$dubStreamId/init.html',
    ]);
    expect(embedRequests, ['https://www.mp4upload.com/embed-dub.html']);
    expect(stream?.playbackKind, 'mp4');
    expect(stream?.selectedMode, AnimeAv1PlaybackMode.dubHls.id);
    expect(stream?.server, 'mp4upload');
    expect(stream?.httpHeaders['X-Tanuki-Upstream-Url'],
        'https://cdn.example.test/animeav1/dub.mp4');
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

  test('resolves LatAnime MP4Upload host with embed headers', () async {
    final encodedMp4Upload = base64Encode(
      utf8.encode('https://www.mp4upload.com/embed-latanime.html'),
    );
    final service = RemoteCatalogService(
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://latanime.org/ver/demo-episodio-1' => http.Response(
              '''
              <a class="play-video" data-player="$encodedMp4Upload">MP4Upload</a>
              ''',
              200,
              request: request,
            ),
          'https://www.mp4upload.com/embed-latanime.html' => http.Response(
              '''
              <script>
                player.src({ src: "https://cdn.example.test/latanime/video.mp4" });
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
      provider: RemoteProvider.latAnime,
      filePath: 'https://latanime.org/ver/demo-episodio-1',
      watchUrl: 'https://latanime.org/anime/demo',
      slug: 'demo',
    ));

    expect(stream?.playbackKind, 'mp4');
    expect(
      stream?.playbackUrl,
      'https://cdn.example.test/latanime/video.mp4',
    );
    expect(stream?.server, 'mp4upload');
    expect(stream?.httpHeaders['Referer'],
        'https://www.mp4upload.com/embed-latanime.html');
    expect(stream?.httpHeaders['Origin'], 'https://www.mp4upload.com');
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

EpisodeItem _kaitouSaintTailEpisode() {
  return const EpisodeItem(
    seriesName: 'Kaitou Saint Tail',
    seriesStateKey: 'kaitou-saint-tail',
    episodeIndex: 0,
    episodeNumber: 1,
    displayName: 'Kaitou Saint Tail - Episodio 1',
    relativePath: 'Catalogo / Episodio 1',
    filePath: '',
    sourceType: SourceType.remote,
    provider: RemoteProvider.catalog,
    watchUrl: '',
  );
}

SeriesItem _kaitouSaintTailSeries() {
  return SeriesItem(
    name: 'Kaitou Saint Tail',
    seriesStateKey: 'kaitou-saint-tail',
    sourceType: SourceType.remote,
    provider: RemoteProvider.catalog,
    episodeCount: 1,
    episodes: [_kaitouSaintTailEpisode()],
  );
}

EpisodeItem _episode({
  required RemoteProvider provider,
  required String filePath,
  required String watchUrl,
  required String slug,
  int episodeNumber = 1,
  String? relativePath,
}) {
  return EpisodeItem(
    seriesName: 'Demo',
    seriesStateKey: 'demo',
    episodeIndex: episodeNumber - 1,
    episodeNumber: episodeNumber,
    displayName: 'Demo - Capitulo $episodeNumber',
    relativePath: relativePath ?? 'Demo / Capitulo $episodeNumber',
    filePath: filePath,
    sourceType: SourceType.remote,
    provider: provider,
    slug: slug,
    watchUrl: watchUrl,
  );
}

Future<
    ({
      int exitCode,
      Set<String> streamTypes,
      double duration,
      String stderr
    })> _probeMediaUrlWithFfprobe(String url) async {
  final probe = await io.Process.run(
    'ffprobe',
    [
      '-v',
      'error',
      '-print_format',
      'json',
      '-show_streams',
      '-show_format',
      url,
    ],
  ).timeout(const Duration(seconds: 45));
  if (probe.exitCode != 0) {
    return (
      exitCode: probe.exitCode,
      streamTypes: <String>{},
      duration: 0.0,
      stderr: '${probe.stderr}\n${probe.stdout}',
    );
  }
  final decoded = jsonDecode('${probe.stdout}') as Map<String, dynamic>;
  final streams = (decoded['streams'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final streamTypes = streams
      .map((entry) => '${entry['codec_type']}'.trim())
      .where((entry) => entry.isNotEmpty)
      .toSet();
  final duration = double.tryParse(
        '${(decoded['format'] as Map<String, dynamic>?)?['duration']}',
      ) ??
      0;
  return (
    exitCode: probe.exitCode,
    streamTypes: streamTypes,
    duration: duration,
    stderr: '${probe.stderr}',
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
