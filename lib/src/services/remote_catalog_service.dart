import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../build_config.dart';
import '../models.dart';
import 'remote_web_resolver.dart';

class RemoteCatalogService {
  RemoteCatalogService({
    http.Client? client,
    RemoteWebResolver? webResolver,
    String tmdbBearerToken = const String.fromEnvironment(
      'TMDB_BEARER_TOKEN',
      defaultValue: buildDefaultTmdbBearerToken,
    ),
    String tmdbApiKey = const String.fromEnvironment(
      'TMDB_API_KEY',
      defaultValue: buildDefaultTmdbApiKey,
    ),
    String fanartApiKey = const String.fromEnvironment(
      'FANART_API_KEY',
      defaultValue: buildDefaultFanartApiKey,
    ),
    String myAnimeListClientId = const String.fromEnvironment(
      'MYANIMELIST_CLIENT_ID',
      defaultValue: buildDefaultMyAnimeListClientId,
    ),
  })  : _client = client ?? http.Client(),
        _webResolver = webResolver ?? const RemoteWebResolver(),
        _tmdbBearerToken =
            _runtimeConfigValue(tmdbBearerToken, 'TMDB_BEARER_TOKEN'),
        _tmdbApiKey = _runtimeConfigValue(tmdbApiKey, 'TMDB_API_KEY'),
        _fanartApiKey = _runtimeConfigValue(fanartApiKey, 'FANART_API_KEY'),
        _myAnimeListClientId =
            _runtimeConfigValue(myAnimeListClientId, 'MYANIMELIST_CLIENT_ID');

  static const _animeAv1BaseUrl = 'https://animeav1.com';
  static const _jkAnimeBaseUrl = 'https://jkanime.net';
  static const _latAnimeBaseUrl = 'https://latanime.org';
  static const _justAnimeBaseUrl = 'https://www.justanime.to';
  static const _justAnimeApiBaseUrl = 'https://core.justanime.to/api';
  static const _aniPmBaseUrl = 'https://ani.pm';
  static const _animeFlvBaseUrl = 'https://www4.animeflv.net';
  static const _bilibiliBaseUrl = 'https://www.bilibili.tv';
  static const _internetArchiveBaseUrl = 'https://archive.org';
  static const _myAnimeListApiBaseUrl = 'https://api.myanimelist.net/v2';
  static const _anilistGraphQlUrl = 'https://graphql.anilist.co';
  static const _tmdbImageBaseUrl = 'https://image.tmdb.org/t/p';
  static const _defaultFetchUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';
  static const _animeAv1ModeSubHls = 'sub-hls';
  static const _animeAv1ModeDubHls = 'dub-hls';
  static const _bilibiliEpisodeOptionsPrefix = 'tanuki:bilibili-options:';
  static const _youtubeEpisodeOptionsPrefix = 'tanuki:youtube-options:';

  final http.Client _client;
  final RemoteWebResolver _webResolver;
  final String _tmdbBearerToken;
  final String _tmdbApiKey;
  final String _fanartApiKey;
  final String _myAnimeListClientId;
  final List<_BiliBiliDashProxy> _bilibiliDashProxies = <_BiliBiliDashProxy>[];
  final List<_JustAnimeHlsProxy> _justAnimeHlsProxies = [];
  final Map<int, Future<RemoteSearchCandidate?>> _aniListDetailCache = {};
  final Map<int, Future<List<SeriesEpisodeMetadata>>> _aniListEpisodeCache = {};
  DateTime? _aniListBlockedUntil;

  static String _runtimeConfigValue(String dartDefineValue, String envKey) {
    final fromDefine = dartDefineValue.trim();
    if (fromDefine.isNotEmpty) {
      return fromDefine;
    }
    return (io.Platform.environment[envKey] ?? '').trim();
  }

  void _debugResolver(String message) {
    assert(() {
      debugPrint('RemoteCatalogResolver: $message');
      return true;
    }());
  }

  String _debugBodySnippet(String value) {
    return value.substring(0, value.length.clamp(0, 400));
  }

  String _debugUrlLabel(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return value;
    }
    final path =
        uri.path.length > 52 ? '${uri.path.substring(0, 52)}...' : uri.path;
    return '${uri.scheme}://${uri.host}$path';
  }

  String _debugStreamLabel(RemoteDirectStream? stream) {
    if (stream == null) {
      return 'null';
    }
    return 'provider=${stream.provider?.id ?? 'none'} '
        'kind=${stream.playbackKind} mode=${stream.selectedMode} '
        'server=${stream.server} url=${_debugUrlLabel(stream.playbackUrl)} '
        'page=${_debugUrlLabel(stream.pageUrl)} '
        'modes=${stream.availableModes.join(',')} '
        'subs=${stream.subtitleTracks.length} '
        'headers=${stream.httpHeaders.keys.join(',')}';
  }

  Future<List<RemoteSearchCandidate>> search(String query) async {
    final normalized = query.trim();
    final catalog = await _safeProviderSearch(() => searchCatalog(normalized));
    if (normalized.isEmpty) {
      return catalog;
    }

    final releaseYear = catalog
        .map((candidate) => candidate.releaseYear)
        .firstWhere((year) => year > 0, orElse: () => 0);
    final providerResults = await Future.wait([
      _safeProviderSearch(
          () => searchAnimeAv1(normalized, releaseYear: releaseYear)),
      _safeProviderSearch(
          () => searchJkAnime(normalized, releaseYear: releaseYear)),
      _safeProviderSearch(
          () => searchLatAnime(normalized, releaseYear: releaseYear)),
      _safeProviderSearch(
          () => searchJustAnime(normalized, releaseYear: releaseYear)),
      _safeProviderSearch(
          () => searchAniPm(normalized, releaseYear: releaseYear)),
    ]);
    return _dedupe([...catalog, ...providerResults.expand((entry) => entry)]);
  }

  Future<List<RemoteSearchCandidate>> searchCatalog(
    String query, {
    int limit = 25,
    int page = 1,
  }) async {
    final normalized = query.trim();
    final jikan = await _safeProviderSearch(
      () => _safeSearchJikan(
        normalized,
        limit: limit,
        page: page,
      ),
    );
    if (normalized.isEmpty) {
      return jikan;
    }
    final myAnimeList = await _safeProviderSearch(
      () => searchMyAnimeListCatalog(
        normalized,
        limit: limit,
        page: page,
      ),
    );
    final anilist = await _safeProviderSearch(
      () => searchAniListCatalog(
        normalized,
        limit: limit,
        page: page,
      ),
    );
    return _dedupe([...jikan, ...myAnimeList, ...anilist]);
  }

  bool get _hasMyAnimeListClientId => _myAnimeListClientId.trim().isNotEmpty;

  Future<List<RemoteSearchCandidate>> discoverCatalogMovies({
    int limit = 25,
    int page = 1,
  }) async {
    final normalizedLimit = limit.clamp(1, 25).toInt();
    final normalizedPage = page < 1 ? 1 : page;
    final providerResults = await Future.wait([
      _safeProviderSearch(
        () => _discoverJkAnimeMovies(
          limit: normalizedLimit,
          page: normalizedPage,
        ),
      ),
      _safeProviderSearch(
        () => _discoverAnimeAv1Movies(
          limit: normalizedLimit,
          page: normalizedPage,
        ),
      ),
    ]);
    return _dedupe(_interleaveCandidateLists(providerResults))
        .take(normalizedLimit)
        .toList(growable: false);
  }

  Future<List<RemoteSearchCandidate>> discoverCatalogAiring({
    int limit = 25,
    int page = 1,
  }) async {
    final providerResults = await Future.wait([
      _safeProviderSearch(
        () => _discoverJikanAiring(limit: limit, page: page),
      ),
      _safeProviderSearch(
        () => _discoverMyAnimeListTopAiring(limit: limit, page: page),
      ),
      _safeProviderSearch(
        () => _discoverAniListAiring(limit: limit, page: page),
      ),
    ]);
    final results = providerResults.expand((entry) => entry).toList();
    return _dedupePreferAiringMetadata(results)
        .take(limit.clamp(1, 50).toInt())
        .toList();
  }

  Future<List<RemoteSearchCandidate>> _discoverJikanAiring({
    required int limit,
    required int page,
  }) async {
    final response = await _get(
      Uri.https('api.jikan.moe', '/v4/top/anime', {
        'filter': 'airing',
        'page': '${page < 1 ? 1 : page}',
        'limit': '${limit.clamp(1, 25)}',
        'sfw': 'true',
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException('Jikan respondio ${response.statusCode}');
    }
    return _parseJikanCandidateList(response.body);
  }

  Future<RemoteSearchCandidate?> fetchCatalogRandomFallback(
      {int attempts = 8}) async {
    final targetAttempts = attempts.clamp(1, 20).toInt();
    for (var index = 0; index < targetAttempts; index += 1) {
      try {
        final response =
            await _get(Uri.https('api.jikan.moe', '/v4/random/anime'));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final decoded = jsonDecode(response.body);
        final data = decoded is Map ? decoded['data'] : null;
        if (data is! Map) {
          continue;
        }
        final candidate = _candidateFromJikan(Map<String, dynamic>.from(data));
        if (_isSupportedRandomCatalogFormat(candidate.format)) {
          return candidate;
        }
      } catch (_) {
        continue;
      }
    }
    return _fetchAniListRandomFallback(attempts: targetAttempts);
  }

  Future<List<RemoteSearchCandidate>> fetchCatalogRecommendations(
    int catalogId, {
    int limit = 15,
  }) async {
    if (catalogId <= 0) {
      return const [];
    }
    final response = await _get(
        Uri.https('api.jikan.moe', '/v4/anime/$catalogId/recommendations'));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException('Jikan respondio ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) {
      return const [];
    }
    final targetLimit = limit.clamp(1, 25).toInt();
    return data
        .whereType<Map>()
        .map((entry) => entry['entry'])
        .whereType<Map>()
        .map((entry) => _candidateFromJikan(Map<String, dynamic>.from(entry)))
        .where((candidate) => candidate.title.isNotEmpty)
        .take(targetLimit)
        .toList();
  }

  Future<List<RemoteSearchCandidate>> fetchMyAnimeListWebRecommendations(
    int malId, {
    int limit = 15,
  }) async {
    if (malId <= 0) return const [];
    final response = await _get(
      Uri.https('myanimelist.net', '/anime/$malId/_/userrecs'),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException(
        'MyAnimeList recomendaciones respondio ${response.statusCode}',
      );
    }
    final candidates = <RemoteSearchCandidate>[];
    final seen = <int>{};
    final pattern = RegExp(
      r'''<div\s+class="picSurround"><a\s+href="(https://myanimelist\.net/anime/(\d+)/[^"]+)"[\s\S]*?<img[^>]+data-src="([^"]+)"[^>]+alt="Anime:\s*([^"]+)"''',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(response.body)) {
      final id = int.tryParse(match.group(2) ?? '') ?? 0;
      if (id <= 0 || !seen.add(id)) continue;
      candidates.add(RemoteSearchCandidate(
        provider: RemoteProvider.catalog,
        slug: '$id',
        title: _decodeHtml(match.group(4) ?? '').trim(),
        watchUrl: _decodeHtml(match.group(1) ?? ''),
        seriesUrl: _decodeHtml(match.group(1) ?? ''),
        imageUrl: _normalizeMyAnimeListImageUrl(
          _decodeHtml(match.group(3) ?? ''),
        ),
        catalogId: id,
      ));
      if (candidates.length >= limit.clamp(1, 25)) break;
    }
    return candidates;
  }

  Future<List<RemoteSearchCandidate>> fetchAniListRecommendationsForSeries(
    SeriesItem series, {
    int limit = 15,
  }) async {
    final anilistId = _anilistIdFromSeries(series);
    final targetLimit = limit.clamp(1, 25).toInt();
    final decoded = await _postAniList({
      'query': anilistId > 0
          ? r'''query Recommendations($id: Int, $limit: Int) {
              Media(id: $id, type: ANIME) {
                relations {
                  edges { relationType(version: 2) node { ...RecommendationMedia } }
                }
                recommendations(sort: RATING_DESC, perPage: $limit) {
                  nodes { rating mediaRecommendation { ...RecommendationMedia } }
                }
              }
            }
            fragment RecommendationMedia on Media {
              id idMal type title { romaji english native } synonyms
              coverImage { extraLarge large } bannerImage description
              averageScore episodes format startDate { year month day }
            }'''
          : r'''query Recommendations($search: String, $year: Int, $limit: Int) {
              Media(search: $search, seasonYear: $year, type: ANIME) {
                relations {
                  edges { relationType(version: 2) node { ...RecommendationMedia } }
                }
                recommendations(sort: RATING_DESC, perPage: $limit) {
                  nodes { rating mediaRecommendation { ...RecommendationMedia } }
                }
              }
            }
            fragment RecommendationMedia on Media {
              id idMal type title { romaji english native } synonyms
              coverImage { extraLarge large } bannerImage description
              averageScore episodes format startDate { year month day }
            }''',
      'variables': {
        if (anilistId > 0) 'id': anilistId else 'search': series.name,
        if (anilistId <= 0 && series.releaseYear > 0)
          'year': series.releaseYear,
        'limit': targetLimit,
      },
    });
    final data = decoded['data'];
    final media = data is Map ? data['Media'] : null;
    final recommendations = media is Map ? media['recommendations'] : null;
    final nodes = recommendations is Map ? recommendations['nodes'] : null;
    final relations = media is Map ? media['relations'] : null;
    final edges = relations is Map ? relations['edges'] : null;
    final relatedMedia = <Map<String, dynamic>>[
      if (edges is List)
        ...edges
            .whereType<Map>()
            .map((edge) => edge['node'])
            .whereType<Map>()
            .where(
              (node) => _readString(node['type']).toUpperCase() == 'ANIME',
            )
            .map((node) => Map<String, dynamic>.from(node)),
      if (nodes is List)
        ...nodes
            .whereType<Map>()
            .map((node) => node['mediaRecommendation'])
            .whereType<Map>()
            .map(
              (node) => Map<String, dynamic>.from(node),
            ),
    ];
    final seen = <String>{};
    return relatedMedia
        .map(_candidateFromAniList)
        .where((candidate) => candidate.title.isNotEmpty)
        .where((candidate) => seen.add(candidate.catalogId > 0
            ? 'mal:${candidate.catalogId}'
            : normalizeSeriesKey(candidate.title)))
        .take(targetLimit)
        .toList(growable: false);
  }

  int _anilistIdFromSeries(SeriesItem series) {
    final urls = [series.watchUrl, ...series.episodes.map((e) => e.watchUrl)];
    for (final value in urls) {
      final uri = Uri.tryParse(value);
      if (uri == null) continue;
      final pattern = uri.host.contains('anilist.co')
          ? RegExp(r'/anime/(\d+)')
          : uri.host.contains('ani.pm')
              ? RegExp(r'/ani/(\d+)')
              : null;
      final id =
          int.tryParse(pattern?.firstMatch(uri.path)?.group(1) ?? '') ?? 0;
      if (id > 0) return id;
    }
    if (series.provider == RemoteProvider.justAnime) {
      return series.catalogId;
    }
    return 0;
  }

  Future<int> resolveMyAnimeListIdForSeries(SeriesItem series) async {
    final urls = [series.watchUrl, ...series.episodes.map((e) => e.watchUrl)];
    for (final value in urls) {
      final uri = Uri.tryParse(value);
      if (uri == null || !uri.host.contains('myanimelist.net')) continue;
      final match = RegExp(r'/anime/(\d+)').firstMatch(uri.path);
      final id = int.tryParse(match?.group(1) ?? '') ?? 0;
      if (id > 0) return id;
    }

    final anilistId = _anilistIdFromSeries(series);

    try {
      final decoded = await _postAniList({
        'query': anilistId > 0
            ? r'''query MalId($id: Int) { Media(id: $id, type: ANIME) { idMal } }'''
            : r'''query MalId($search: String, $year: Int) {
                Media(search: $search, seasonYear: $year, type: ANIME) { idMal }
              }''',
        'variables': anilistId > 0
            ? {'id': anilistId}
            : {
                'search': series.name,
                if (series.releaseYear > 0) 'year': series.releaseYear,
              },
      });
      final media =
          decoded['data'] is Map ? (decoded['data'] as Map)['Media'] : null;
      final malId = media is Map ? _readInt(media['idMal']) : 0;
      if (malId > 0) return malId;
    } catch (error) {
      _debugResolver('AniList MAL id lookup failed: $error');
    }

    try {
      final matches = await searchMyAnimeListCatalog(series.name, limit: 10);
      final requestedTitle = normalizeSeriesKey(series.name);
      RemoteSearchCandidate? best;
      var bestScore = -1;
      for (final match in matches) {
        var score =
            normalizeSeriesKey(match.title) == requestedTitle ? 1000 : 0;
        if (series.releaseYear > 0 && match.releaseYear > 0) {
          final difference = (series.releaseYear - match.releaseYear).abs();
          if (difference == 0) score += 500;
          if (difference > 2) continue;
        }
        if (score > bestScore) {
          best = match;
          bestScore = score;
        }
      }
      if (best != null && bestScore >= 1000 && best.catalogId > 0) {
        return best.catalogId;
      }
    } catch (error) {
      _debugResolver('MyAnimeList MAL id lookup failed: $error');
    }

    // catalogId is safe as a MAL id only when its URL explicitly came from
    // MyAnimeList. Provider APIs such as Ani.pm and JustAnime expose AniList
    // ids in the same field.
    return 0;
  }

  Future<List<RemoteSearchCandidate>> _safeProviderSearch(
      Future<List<RemoteSearchCandidate>> Function() loader) async {
    try {
      return await loader();
    } catch (_) {
      return const [];
    }
  }

  Future<List<RemoteSearchCandidate>> _safeSearchJikan(
    String normalized, {
    int limit = 25,
    int page = 1,
  }) async {
    final normalizedLimit = limit.clamp(1, 25).toInt();
    final normalizedPage = page < 1 ? 1 : page;
    final uri = normalized.isEmpty
        ? Uri.https('api.jikan.moe', '/v4/seasons/now', {
            'page': '$normalizedPage',
            'limit': '$normalizedLimit',
            'sfw': 'true',
          })
        : Uri.https('api.jikan.moe', '/v4/anime', {
            'q': normalized,
            'page': '$normalizedPage',
            'limit': '$normalizedLimit',
            'sfw': 'true',
          });

    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException('Jikan respondio ${response.statusCode}');
    }

    return _parseJikanCandidateList(response.body);
  }

  bool _isSupportedRandomCatalogFormat(String format) {
    return switch (format.trim().toLowerCase()) {
      'tv' || 'movie' || 'ova' || 'ona' => true,
      _ => false,
    };
  }

  List<RemoteSearchCandidate> _parseJikanCandidateList(String payload) {
    final decoded = jsonDecode(payload);
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) {
      return const [];
    }

    return data
        .whereType<Map>()
        .map((entry) => _candidateFromJikan(Map<String, dynamic>.from(entry)))
        .where((candidate) => candidate.title.isNotEmpty)
        .toList();
  }

  Future<List<RemoteSearchCandidate>> searchMyAnimeListCatalog(
    String query, {
    int limit = 25,
    int page = 1,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final normalizedLimit = limit.clamp(1, 100).toInt();
    final normalizedPage = page < 1 ? 1 : page;
    final results = <RemoteSearchCandidate>[];
    if (_hasMyAnimeListClientId) {
      try {
        final offset = (normalizedPage - 1) * normalizedLimit;
        final uri = Uri.parse('$_myAnimeListApiBaseUrl/anime').replace(
          queryParameters: {
            'q': normalized,
            'limit': '$normalizedLimit',
            if (offset > 0) 'offset': '$offset',
            'fields': [
              'id',
              'title',
              'main_picture',
              'alternative_titles',
              'start_date',
              'media_type',
              'num_episodes',
              'synopsis',
              'mean',
            ].join(','),
          },
        );
        final response = await _getMyAnimeList(uri);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw RemoteCatalogException(
            'MyAnimeList respondio ${response.statusCode}',
          );
        }
        results.addAll(_parseMyAnimeListCandidateList(response.body));
      } catch (error) {
        _debugResolver('MyAnimeList API search failed: $error');
      }
    }
    results.addAll(await _searchMyAnimeListWebCatalog(
      normalized,
      limit: normalizedLimit,
      page: normalizedPage,
    ));
    return _dedupe(results).take(normalizedLimit).toList(growable: false);
  }

  List<RemoteSearchCandidate> _parseMyAnimeListCandidateList(String payload) {
    final decoded = jsonDecode(payload);
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) {
      return const [];
    }
    return data
        .whereType<Map>()
        .map((entry) => entry['node'])
        .whereType<Map>()
        .map((entry) => _candidateFromMyAnimeListNode(
              Map<String, dynamic>.from(entry),
            ))
        .where((candidate) => candidate.title.isNotEmpty)
        .toList();
  }

  Future<List<RemoteSearchCandidate>> _searchMyAnimeListWebCatalog(
    String query, {
    required int limit,
    required int page,
  }) async {
    final offset = (page - 1) * limit;
    final uri = Uri.https('myanimelist.net', '/search/all', {
      'q': query,
      'cat': 'anime',
      if (offset > 0) 'show': '$offset',
    });
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException(
        'MyAnimeList web respondio ${response.statusCode}',
      );
    }
    return _parseMyAnimeListWebCandidateList(response.body)
        .take(limit)
        .toList(growable: false);
  }

  List<RemoteSearchCandidate> _parseMyAnimeListWebCandidateList(String html) {
    final animeStart = html.indexOf('<h2 id="anime">');
    if (animeStart < 0) {
      return const [];
    }
    final nextSection = RegExp(r'<h2\s+id="[^"]+">', caseSensitive: false)
        .firstMatch(html.substring(animeStart + 1));
    final animeHtml = nextSection == null
        ? html.substring(animeStart)
        : html.substring(animeStart, animeStart + 1 + nextSection.start);
    final blocks = RegExp(
      r'<div\s+class="list\s+di-t\s+w100">([\s\S]*?)(?=<div\s+class="list\s+di-t\s+w100">|</article>)',
      caseSensitive: false,
    ).allMatches(animeHtml);
    return blocks
        .map((match) => _candidateFromMyAnimeListWebBlock(match.group(1) ?? ''))
        .whereType<RemoteSearchCandidate>()
        .toList(growable: false);
  }

  Future<List<RemoteSearchCandidate>> _discoverMyAnimeListTopAiring({
    required int limit,
    required int page,
  }) async {
    final offset = (page - 1) * limit;
    final response = await _get(
      Uri.https('myanimelist.net', '/topanime.php', {
        'type': 'airing',
        if (offset > 0) 'limit': '$offset',
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException(
        'MyAnimeList airing respondio ${response.statusCode}',
      );
    }
    return _parseMyAnimeListTopAnimePage(response.body)
        .take(limit.clamp(1, 50).toInt())
        .toList(growable: false);
  }

  Future<List<RemoteSearchCandidate>> _discoverMyAnimeListSeason({
    required String season,
    required int year,
    required String type,
    required int limit,
    required int page,
    required bool tvNewOnly,
  }) async {
    final response = await _get(
      Uri.https('myanimelist.net', '/anime/season/$year/$season'),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException(
        'MyAnimeList season respondio ${response.statusCode}',
      );
    }
    final html = tvNewOnly
        ? _myAnimeListSeasonSectionHtml(response.body, 'TV (New)')
        : response.body;
    final candidates = _parseMyAnimeListSeasonPage(html)
        .where((candidate) =>
            type.isEmpty || _normalizeCatalogType(candidate.format) == type)
        .toList(growable: false);
    final normalizedLimit = limit.clamp(1, 50).toInt();
    final normalizedPage = page < 1 ? 1 : page;
    final start = (normalizedPage - 1) * normalizedLimit;
    if (start >= candidates.length) {
      return const [];
    }
    return candidates.skip(start).take(normalizedLimit).toList(growable: false);
  }

  String _myAnimeListSeasonSectionHtml(String html, String header) {
    final escapedHeader = RegExp.escape(header);
    final headerMatch = RegExp(
      '<div\\s+class="anime-header">\\s*$escapedHeader\\s*</div>',
      caseSensitive: false,
    ).firstMatch(html);
    if (headerMatch == null) {
      return html;
    }
    final start = headerMatch.end;
    final nextHeader = RegExp(
      r'<div\s+class="anime-header">',
      caseSensitive: false,
    ).firstMatch(html.substring(start));
    final end = nextHeader == null ? html.length : start + nextHeader.start;
    return html.substring(start, end);
  }

  List<RemoteSearchCandidate> _parseMyAnimeListSeasonPage(String html) {
    final blocks = RegExp(
      r'<div\s+class="[^"]*seasonal-anime[^"]*"[\s\S]*?(?=<div\s+class="[^"]*seasonal-anime[^"]*"|</div>\s*</div>\s*</div>\s*<div\s+class="seasonal-anime-list|</div>\s*</div>\s*</div>\s*</div>\s*</div>\s*</div>)',
      caseSensitive: false,
    ).allMatches(html);
    final candidates = <RemoteSearchCandidate>[];
    for (final match in blocks) {
      final block = match.group(0) ?? '';
      final candidate = _candidateFromMyAnimeListSeasonBlock(block);
      if (candidate != null) {
        candidates.add(candidate);
      }
    }
    if (candidates.isNotEmpty) {
      return candidates;
    }
    return RegExp(
      r'<h2\s+class="h2_anime_title">[\s\S]*?(?=<h2\s+class="h2_anime_title"|</body>)',
      caseSensitive: false,
    )
        .allMatches(html)
        .map((match) => _candidateFromMyAnimeListSeasonBlock(
              match.group(0) ?? '',
            ))
        .whereType<RemoteSearchCandidate>()
        .toList(growable: false);
  }

  RemoteSearchCandidate? _candidateFromMyAnimeListSeasonBlock(String block) {
    final hrefMatch = RegExp(
      r'href="(https://myanimelist\.net/anime/(\d+)/[^"]+)"[^>]*class="link-title"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    ).firstMatch(block);
    final id = int.tryParse(hrefMatch?.group(2) ?? '') ?? 0;
    if (id <= 0) {
      return null;
    }
    final href = _decodeHtml(hrefMatch?.group(1) ?? '');
    final title = _decodeHtml(hrefMatch?.group(3) ?? '')
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .trim();
    if (title.isEmpty) {
      return null;
    }
    final imageUrl = _normalizeMyAnimeListImageUrl(_decodeHtml(_firstNonEmpty([
      RegExp(r'<img[^>]+data-src="([^"]*)"', caseSensitive: false)
              .firstMatch(block)
              ?.group(1) ??
          '',
      RegExp(r'<img[^>]+src="([^"]*)"', caseSensitive: false)
              .firstMatch(block)
              ?.group(1) ??
          '',
    ])));
    final startRaw = RegExp(
          r'class="js-start_date">\s*(\d{8})\s*</span>',
          caseSensitive: false,
        ).firstMatch(block)?.group(1) ??
        '';
    final airDateIso = startRaw.length == 8
        ? '${startRaw.substring(0, 4)}-${startRaw.substring(4, 6)}-${startRaw.substring(6, 8)}'
        : '';
    final info = _decodeHtml(block.replaceAll(RegExp(r'<[^>]*>'), ' '));
    final episodeCount = _readInt(RegExp(
      r'\b(\d+)\s+eps?\b',
      caseSensitive: false,
    ).firstMatch(info)?.group(1));
    final score = RegExp(
          r'class="js-score">\s*([0-9.]+)\s*</span>',
          caseSensitive: false,
        ).firstMatch(block)?.group(1) ??
        RegExp(r'\bScore\s*([0-9.]+)', caseSensitive: false)
            .firstMatch(info)
            ?.group(1) ??
        '';
    final typeClass = RegExp(
          r'js-anime-type-(\d+)',
          caseSensitive: false,
        ).firstMatch(block)?.group(1) ??
        '';
    final format = switch (typeClass) {
      '1' => 'TV',
      '2' => 'OVA',
      '3' => 'Movie',
      '4' => 'Special',
      '5' => 'ONA',
      '6' => 'Music',
      _ => 'TV',
    };
    final description = _decodeHtml(RegExp(
              r'<p\s+class="preline">([\s\S]*?)</p>',
              caseSensitive: false,
            ).firstMatch(block)?.group(1) ??
            '')
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .trim();
    return RemoteSearchCandidate(
      provider: RemoteProvider.catalog,
      slug: '$id',
      title: title,
      watchUrl: href,
      seriesUrl: href,
      imageUrl: imageUrl,
      backgroundUrl: imageUrl,
      description: description,
      rating: score,
      episodeCount: episodeCount,
      format: format,
      releaseYear: airDateIso.length >= 4
          ? int.tryParse(airDateIso.substring(0, 4)) ?? 0
          : 0,
      airDateIso: airDateIso,
      catalogId: id,
    );
  }

  List<RemoteSearchCandidate> _parseMyAnimeListTopAnimePage(String html) {
    final rows = RegExp(
      r'<tr\s+class="ranking-list"[\s\S]*?</tr>',
      caseSensitive: false,
    ).allMatches(html);
    return rows
        .map((match) => _candidateFromMyAnimeListTopRow(match.group(0) ?? ''))
        .whereType<RemoteSearchCandidate>()
        .toList(growable: false);
  }

  RemoteSearchCandidate? _candidateFromMyAnimeListTopRow(String row) {
    final hrefMatch = RegExp(
      r'href="(https://myanimelist\.net/anime/(\d+)/[^"]+)"',
      caseSensitive: false,
    ).firstMatch(row);
    final id = int.tryParse(hrefMatch?.group(2) ?? '') ?? 0;
    if (id <= 0) {
      return null;
    }
    final href = _decodeHtml(hrefMatch?.group(1) ?? '');
    final title = _decodeHtml(_firstNonEmpty([
      RegExp(
            r'<h3[^>]*class="[^"]*anime_ranking_h3[^"]*"[^>]*>\s*<a[^>]*>([\s\S]*?)</a>',
            caseSensitive: false,
          ).firstMatch(row)?.group(1) ??
          '',
      RegExp(r'<img[^>]+alt="([^"]*)"', caseSensitive: false)
              .firstMatch(row)
              ?.group(1) ??
          '',
    ])).replaceAll(RegExp(r'<[^>]*>'), ' ').trim();
    if (title.isEmpty) {
      return null;
    }
    final imageUrl = _normalizeMyAnimeListImageUrl(_decodeHtml(_firstNonEmpty([
      RegExp(r'<img[^>]+data-src="([^"]*)"', caseSensitive: false)
              .firstMatch(row)
              ?.group(1) ??
          '',
      RegExp(r'<img[^>]+src="([^"]*)"', caseSensitive: false)
              .firstMatch(row)
              ?.group(1) ??
          '',
    ])));
    final info = _decodeHtml(row.replaceAll(RegExp(r'<[^>]*>'), ' '));
    final format = RegExp(
          r'\b(TV|Movie|OVA|ONA|Special|Music)\b',
          caseSensitive: false,
        ).firstMatch(info)?.group(1) ??
        '';
    final episodeCount = _readInt(RegExp(
      r'\((\d+)\s+eps?\)',
      caseSensitive: false,
    ).firstMatch(info)?.group(1));
    final score = RegExp(
          r'Score\s*([0-9.]+)',
          caseSensitive: false,
        ).firstMatch(info)?.group(1) ??
        '';
    return RemoteSearchCandidate(
      provider: RemoteProvider.catalog,
      slug: '$id',
      title: title,
      watchUrl: href,
      seriesUrl: href,
      imageUrl: imageUrl,
      backgroundUrl: imageUrl,
      rating: score,
      episodeCount: episodeCount,
      format: format,
      catalogId: id,
    );
  }

  RemoteSearchCandidate? _candidateFromMyAnimeListWebBlock(String block) {
    final hrefMatch = RegExp(
      r'href="(https://myanimelist\.net/anime/(\d+)/[^"]+)"',
      caseSensitive: false,
    ).firstMatch(block);
    final id = int.tryParse(hrefMatch?.group(2) ?? '') ?? 0;
    if (id <= 0) {
      return null;
    }
    final href = _decodeHtml(hrefMatch?.group(1) ?? '');
    final title = _firstNonEmpty([
      _decodeHtml(RegExp(
                r'<a[^>]+data-l-content-type="anime"[^>]*>\s*([\s\S]*?)\s*</a>',
                caseSensitive: false,
              ).firstMatch(block)?.group(1) ??
              '')
          .replaceAll(RegExp(r'<[^>]*>'), ' ')
          .trim(),
      _decodeHtml(RegExp(r'<img[^>]+alt="([^"]*)"', caseSensitive: false)
              .firstMatch(block)
              ?.group(1) ??
          ''),
    ]);
    if (title.isEmpty) {
      return null;
    }
    final imageUrl = _normalizeMyAnimeListImageUrl(_decodeHtml(_firstNonEmpty([
      RegExp(r'<img[^>]+data-src="([^"]*)"', caseSensitive: false)
              .firstMatch(block)
              ?.group(1) ??
          '',
      RegExp(r'<img[^>]+src="([^"]*)"', caseSensitive: false)
              .firstMatch(block)
              ?.group(1) ??
          '',
    ])));
    final info = _decodeHtml(RegExp(
          r'<div\s+class="pt8\s+fs10\s+lh14\s+fn-grey4">([\s\S]*?)</div>',
          caseSensitive: false,
        ).firstMatch(block)?.group(1) ??
        '');
    final cleanedInfo = info.replaceAll(RegExp(r'<[^>]*>'), ' ');
    final format = RegExp(
          r'\b(TV|Movie|OVA|ONA|Special|Music)\b',
          caseSensitive: false,
        ).firstMatch(cleanedInfo)?.group(1) ??
        '';
    final episodeCount = _readInt(RegExp(
      r'\((\d+)\s+eps?\)',
      caseSensitive: false,
    ).firstMatch(cleanedInfo)?.group(1));
    final score = RegExp(
          r'Scored\s+([0-9.]+)',
          caseSensitive: false,
        ).firstMatch(cleanedInfo)?.group(1) ??
        '';
    return RemoteSearchCandidate(
      provider: RemoteProvider.catalog,
      slug: '$id',
      title: title,
      watchUrl: href,
      seriesUrl: href,
      imageUrl: imageUrl,
      backgroundUrl: imageUrl,
      rating: score,
      episodeCount: episodeCount,
      format: format,
      catalogId: id,
    );
  }

  String _normalizeMyAnimeListImageUrl(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return '';
    }
    final withoutResize = normalized.replaceFirst(
      RegExp(r'/r/\d+x\d+/', caseSensitive: false),
      '/',
    );
    final questionIndex = withoutResize.indexOf('?');
    final clean = questionIndex >= 0
        ? withoutResize.substring(0, questionIndex)
        : withoutResize;
    return clean.startsWith('//') ? 'https:$clean' : clean;
  }

  Future<List<RemoteSearchCandidate>> searchAniListCatalog(
    String query, {
    int limit = 25,
    int page = 1,
  }) async {
    final normalized = query.trim();
    final normalizedLimit = limit.clamp(1, 50).toInt();
    final normalizedPage = page < 1 ? 1 : page;
    const mediaFields = r'''
      id
      idMal
      title {
        romaji
        english
        native
      }
      synonyms
      description(asHtml: false)
      episodes
      format
      averageScore
      startDate {
        year
        month
        day
      }
      coverImage {
        extraLarge
        large
      }
      bannerImage
      trailer {
        id
        site
      }
    ''';
    final body = normalized.isEmpty
        ? {
            'query': '''
              query CatalogFallback(\$page: Int, \$perPage: Int) {
                Page(page: \$page, perPage: \$perPage) {
                  media(
                    type: ANIME
                    isAdult: false
                    sort: [TRENDING_DESC, POPULARITY_DESC]
                  ) {
                    $mediaFields
                  }
                }
              }
            ''',
            'variables': {
              'page': normalizedPage,
              'perPage': normalizedLimit,
            },
          }
        : {
            'query': '''
              query CatalogSearch(\$search: String, \$page: Int, \$perPage: Int) {
                Page(page: \$page, perPage: \$perPage) {
                  media(
                    search: \$search
                    type: ANIME
                    isAdult: false
                    sort: [SEARCH_MATCH, POPULARITY_DESC]
                  ) {
                    $mediaFields
                  }
                }
              }
            ''',
            'variables': {
              'search': normalized,
              'page': normalizedPage,
              'perPage': normalizedLimit,
            },
          };
    final decoded = await _postAniList(body);
    final root = decoded['data'] is Map
        ? Map<String, dynamic>.from(decoded['data'] as Map)
        : const <String, dynamic>{};
    final pageMap = root['Page'] is Map
        ? Map<String, dynamic>.from(root['Page'] as Map)
        : const <String, dynamic>{};
    final media = pageMap['media'];
    if (media is! List) {
      return const [];
    }
    return media
        .whereType<Map>()
        .map((entry) => _candidateFromAniList(Map<String, dynamic>.from(entry)))
        .where((candidate) => candidate.title.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<RemoteSearchCandidate>> _discoverAniListSeason({
    required String season,
    required int year,
    required String type,
    required int limit,
    required int page,
  }) {
    final seasonEnum = switch (season) {
      'winter' => 'WINTER',
      'spring' => 'SPRING',
      'summer' => 'SUMMER',
      'fall' => 'FALL',
      _ => '',
    };
    if (seasonEnum.isEmpty) {
      return Future.value(const <RemoteSearchCandidate>[]);
    }
    return _discoverAniListPage(
      page: page,
      limit: limit,
      extraArgs: 'season: $seasonEnum seasonYear: $year',
      type: type,
      sort: '[POPULARITY_DESC, SCORE_DESC]',
    );
  }

  Future<List<RemoteSearchCandidate>> _discoverAniListAiring({
    required int limit,
    required int page,
  }) {
    return _discoverAniListPage(
      page: page,
      limit: limit,
      extraArgs: 'status: RELEASING',
      type: 'tv',
      sort: '[POPULARITY_DESC, TRENDING_DESC]',
      includeAiringSchedule: true,
    );
  }

  Future<List<RemoteSearchCandidate>> _discoverAniListPage({
    required int page,
    required int limit,
    required String extraArgs,
    required String type,
    required String sort,
    bool includeAiringSchedule = false,
  }) async {
    final normalizedLimit = limit.clamp(1, 50).toInt();
    final formatFilter = switch (type.trim().toLowerCase()) {
      'tv' => 'format: TV',
      'movie' => 'format: MOVIE',
      'ova' => 'format: OVA',
      'ona' => 'format: ONA',
      _ => '',
    };
    final args = [
      extraArgs,
      formatFilter,
      'type: ANIME',
      'isAdult: false',
      'sort: $sort',
    ].where((entry) => entry.trim().isNotEmpty).join('\n                    ');
    final airingScheduleFields = includeAiringSchedule
        ? '''
              airingSchedule(notYetAired: true, page: 1, perPage: 6) {
                nodes {
                  episode
                  airingAt
                }
              }
'''
        : '';
    final decoded = await _postAniList({
      'query': '''
        query CatalogDiscover(\$page: Int, \$perPage: Int) {
          Page(page: \$page, perPage: \$perPage) {
            media(
              $args
            ) {
              id
              idMal
              title {
                romaji
                english
                native
              }
              synonyms
              description(asHtml: false)
              episodes
              format
              averageScore
              startDate {
                year
                month
                day
              }
              coverImage {
                extraLarge
                large
              }
              bannerImage
              trailer {
                id
                site
              }
$airingScheduleFields
            }
          }
        }
      ''',
      'variables': {
        'page': page < 1 ? 1 : page,
        'perPage': normalizedLimit,
      },
    });
    final root = decoded['data'] is Map
        ? Map<String, dynamic>.from(decoded['data'] as Map)
        : const <String, dynamic>{};
    final pageMap = root['Page'] is Map
        ? Map<String, dynamic>.from(root['Page'] as Map)
        : const <String, dynamic>{};
    final media = pageMap['media'];
    if (media is! List) {
      return const [];
    }
    return media
        .whereType<Map>()
        .map((entry) => _candidateFromAniList(Map<String, dynamic>.from(entry)))
        .where((candidate) => candidate.title.isNotEmpty)
        .toList(growable: false);
  }

  Future<RemoteSearchCandidate?> _fetchAniListRandomFallback({
    int attempts = 8,
  }) async {
    final targetAttempts = attempts.clamp(1, 20).toInt();
    final random = Random();
    for (var index = 0; index < targetAttempts; index += 1) {
      try {
        final results = await searchAniListCatalog(
          '',
          limit: 1,
          page: 1 + random.nextInt(50),
        );
        if (results.isEmpty) {
          continue;
        }
        final candidate = results.first;
        if (_isSupportedRandomCatalogFormat(candidate.format)) {
          return candidate;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  String _normalizeCatalogType(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'tv' || 'movie' || 'ova' || 'ona' => normalized,
      _ => '',
    };
  }

  Future<List<RemoteSearchCandidate>> searchAnimeAv1(String query,
      {int releaseYear = 0}) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final params = <String, String>{'search': normalized};
    if (releaseYear >= 1900 && releaseYear <= 2100) {
      params['minYear'] = '$releaseYear';
      params['maxYear'] = '$releaseYear';
    }
    final uri = Uri.https('animeav1.com', '/catalogo', params);
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException('AnimeAV1 respondio ${response.statusCode}');
    }
    return _parseAnimeAv1Results(response.body);
  }

  Future<List<RemoteSearchCandidate>> _discoverAnimeAv1Movies({
    required int limit,
    required int page,
  }) async {
    final uri = Uri.https('animeav1.com', '/catalogo', {
      'category': 'pelicula',
      'order': 'latest_released',
      if (page > 1) 'page': '$page',
    });
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException(
        'AnimeAV1 peliculas respondio ${response.statusCode}',
      );
    }
    return _parseAnimeAv1Results(response.body)
        .where((candidate) => _candidateLooksMovie(candidate))
        .take(limit)
        .toList(growable: false);
  }

  Future<List<RemoteSearchCandidate>> searchJkAnime(String query,
      {int releaseYear = 0}) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final attempts = <Uri>[
      _buildJkAnimeDirectoryUri(normalized, releaseYear),
      if (releaseYear > 0) _buildJkAnimeDirectoryUri(normalized, 0),
    ];
    for (final uri in attempts) {
      final response = await _get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        continue;
      }
      final fallbackYear =
          int.tryParse(uri.queryParameters['fecha'] ?? '') ?? 0;
      final parsed = _parseJkAnimeResults(response.body, fallbackYear);
      if (parsed.isNotEmpty) {
        return parsed;
      }
    }
    return _searchJkAnimeByDirectSlug(normalized, releaseYear: releaseYear);
  }

  Future<List<RemoteSearchCandidate>> searchJustAnime(String query,
      {int releaseYear = 0}) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];
    final response = await _getRemoteProviderWithRetry(
      Uri.parse('$_justAnimeApiBaseUrl/search').replace(
        queryParameters: {'query': normalized},
      ),
      referer: _justAnimeBaseUrl,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const [];
    }
    final decoded = jsonDecode(response.body);
    final results = decoded is Map ? decoded['results'] : null;
    if (results is! List) return const [];
    return results.whereType<Map>().map((raw) {
      final entry = Map<String, dynamic>.from(raw);
      final id = _readInt(entry['id']);
      final titles = entry['title'] is Map
          ? Map<String, dynamic>.from(entry['title'] as Map)
          : const <String, dynamic>{};
      final title = _cleanRemoteText(
        _readString(titles['english']).isNotEmpty
            ? _readString(titles['english'])
            : _readString(titles['romaji']),
      );
      final slug = title
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
      final seriesUrl = '$_justAnimeBaseUrl/anime/$id/$slug';
      return RemoteSearchCandidate(
        provider: RemoteProvider.justAnime,
        slug: '$id',
        title: title,
        seriesUrl: seriesUrl,
        watchUrl: seriesUrl,
        imageUrl: _readString(entry['cover']),
        episodeCount: _readInt(entry['episodes']),
        format: _readString(entry['type']),
        releaseYear: _readInt(entry['year']),
        catalogId: id,
      );
    }).where((candidate) {
      return candidate.catalogId > 0 &&
          candidate.title.isNotEmpty &&
          (releaseYear <= 0 || candidate.releaseYear == releaseYear);
    }).toList(growable: false);
  }

  Future<List<RemoteSearchCandidate>> searchAniPm(String query,
      {int releaseYear = 0}) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];
    final response = await _getRemoteProviderWithRetry(
      Uri.parse('$_aniPmBaseUrl/api/anime/search').replace(
        queryParameters: {'q': normalized},
      ),
      referer: _aniPmBaseUrl,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const [];
    }
    final decoded = jsonDecode(response.body);
    final items = decoded is Map ? decoded['items'] : null;
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((raw) {
          final entry = Map<String, dynamic>.from(raw);
          final id = _readInt(entry['id']);
          final source = _readString(entry['source']).toLowerCase();
          final route = source == 'anilist' ? 'ani' : 'anime';
          final title = _cleanRemoteText(_readString(entry['title']));
          return RemoteSearchCandidate(
            provider: RemoteProvider.aniPm,
            slug: '$route:$id',
            title: title,
            seriesUrl: '$_aniPmBaseUrl/$route/$id',
            watchUrl: '$_aniPmBaseUrl/$route/$id',
            imageUrl: _readString(entry['poster']),
            backgroundUrl: _readString(entry['banner']),
            description: _readString(entry['synopsis']),
            rating: _readString(entry['score']),
            episodeCount: _readInt(entry['episodeCount']),
            format: _readString(entry['type']),
            japaneseTitle: _cleanRemoteText(_readString(entry['native'])),
            releaseYear: _readInt(entry['year']),
            catalogId: _readInt(entry['anilistId']),
          );
        })
        .where((candidate) =>
            candidate.slug.split(':').last != '0' &&
            candidate.title.isNotEmpty &&
            (releaseYear <= 0 || candidate.releaseYear == releaseYear))
        .toList(growable: false);
  }

  Future<List<RemoteSearchCandidate>> searchLatAnime(String query,
      {int releaseYear = 0}) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final attempts = <Uri>[
      _buildLatAnimeDirectoryUri(normalized, releaseYear),
      if (releaseYear > 0) _buildLatAnimeDirectoryUri(normalized, 0),
      Uri.https('latanime.org', '/buscar', {'q': normalized}),
    ];
    final merged = <String, RemoteSearchCandidate>{};
    for (final uri in attempts) {
      final response = await _get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        continue;
      }
      for (final candidate in _parseLatAnimeResults(response.body)) {
        final key = '${candidate.provider.id}::${candidate.slug}';
        merged[key] = candidate.releaseYear > 0 || releaseYear <= 0
            ? candidate
            : _copyCandidate(candidate, releaseYear: releaseYear);
      }
      if (merged.isNotEmpty) {
        break;
      }
    }
    return merged.values.toList()
      ..sort((left, right) =>
          _scoreLatAnimeCandidate(normalized, right, releaseYear).compareTo(
            _scoreLatAnimeCandidate(normalized, left, releaseYear),
          ));
  }

  Future<List<RemoteSearchCandidate>> searchAnimeFlv(String query,
      {int releaseYear = 0}) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final uri = Uri.https('www4.animeflv.net', '/browse', {'q': normalized});
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException('AnimeFLV respondio ${response.statusCode}');
    }
    return _parseAnimeFlvResults(response.body, releaseYear);
  }

  Future<List<RemoteSearchCandidate>> searchBiliBili(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final uri = Uri.https('www.bilibili.tv', '/en/search-result', {
      'q': normalized,
    });
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException('BiliBili respondio ${response.statusCode}');
    }
    return _parseBiliBiliResults(response.body);
  }

  Future<List<RemoteSearchCandidate>> searchInternetArchive(
      String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return const [];
    }
    final response = await _getInternetArchiveJson(
      Uri.https('archive.org', '/advancedsearch.php', {
        'q': '$normalized AND mediatype:movies',
        'fl[]': [
          'identifier',
          'title',
          'description',
          'year',
          'downloads',
        ],
        'rows': '8',
        'page': '1',
        'output': 'json',
        'sort[]': 'downloads desc',
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException(
        'Internet Archive respondio ${response.statusCode}',
      );
    }
    return _parseInternetArchiveSearchResults(response.body);
  }

  Future<List<_BiliBiliVideoResult>> _searchBiliBiliEpisodeOptions(
    String query, {
    int limit = 2,
  }) async {
    final normalized = _cleanBiliBiliSearchQuery(query);
    if (normalized.isEmpty) {
      return const [];
    }
    final uri = Uri.https('www.bilibili.tv', '/en/search-result', {
      'q': normalized,
    });
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException('BiliBili respondio ${response.statusCode}');
    }
    return _parseBiliBiliVideoResults(response.body)
        .take(limit.clamp(1, 8).toInt())
        .toList(growable: false);
  }

  Future<List<RemoteSearchCandidate>> discoverCatalogBySeason({
    required String season,
    required int year,
    String type = '',
    int limit = 25,
    int page = 1,
    bool tvNewOnly = false,
  }) async {
    final normalizedSeason = season.trim().toLowerCase();
    if (!{'winter', 'spring', 'summer', 'fall'}.contains(normalizedSeason)) {
      return const [];
    }
    if (year < 1900 || year > 2100) {
      return const [];
    }
    final normalizedType = _normalizeCatalogType(type);
    if (tvNewOnly) {
      final malResults = await _safeProviderSearch(
        () => _discoverMyAnimeListSeason(
          season: normalizedSeason,
          year: year,
          type: normalizedType.isEmpty ? 'tv' : normalizedType,
          limit: limit,
          page: page,
          tvNewOnly: true,
        ),
      );
      if (malResults.isNotEmpty) {
        return _dedupe(malResults).take(limit.clamp(1, 50).toInt()).toList();
      }
    }
    final providerResults = await Future.wait([
      _safeProviderSearch(
        () => _discoverJikanSeason(
          season: normalizedSeason,
          year: year,
          type: normalizedType,
          limit: limit,
          page: page,
        ),
      ),
      _safeProviderSearch(
        () => _discoverMyAnimeListSeason(
          season: normalizedSeason,
          year: year,
          type: normalizedType,
          limit: limit,
          page: page,
          tvNewOnly: false,
        ),
      ),
      _safeProviderSearch(
        () => _discoverAniListSeason(
          season: normalizedSeason,
          year: year,
          type: normalizedType,
          limit: limit,
          page: page,
        ),
      ),
    ]);
    final results = providerResults.expand((entry) => entry).toList();
    return _dedupe(results).take(limit.clamp(1, 50).toInt()).toList();
  }

  Future<List<RemoteSearchCandidate>> _discoverJikanSeason({
    required String season,
    required int year,
    required String type,
    required int limit,
    required int page,
  }) async {
    final response = await _get(
      Uri.https('api.jikan.moe', '/v4/seasons/$year/$season', {
        'page': '${page < 1 ? 1 : page}',
        'limit': '${limit.clamp(1, 25)}',
        'sfw': 'true',
        if (type.isNotEmpty) 'filter': type,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException('Jikan respondio ${response.statusCode}');
    }
    return _parseJikanCandidateList(response.body);
  }

  Future<List<RemoteSearchCandidate>> discoverCatalogByYearRange({
    int startYear = 0,
    int endYear = 0,
    String type = '',
    int limit = 25,
    int page = 1,
  }) async {
    final normalizedStart =
        startYear >= 1900 && startYear <= 2100 ? startYear : 0;
    final normalizedEnd = endYear >= 1900 && endYear <= 2100 ? endYear : 0;
    if (normalizedStart <= 0 && normalizedEnd <= 0) {
      return const [];
    }
    final normalizedType = _normalizeCatalogType(type);
    final response = await _get(
      Uri.https(
        'api.jikan.moe',
        '/v4/anime',
        {
          'page': '${page < 1 ? 1 : page}',
          'limit': '${limit.clamp(1, 25)}',
          'sfw': 'true',
          'order_by': 'start_date',
          'sort': 'desc',
          if (normalizedStart > 0) 'start_date': '$normalizedStart-01-01',
          if (normalizedEnd > 0) 'end_date': '$normalizedEnd-12-31',
          if (normalizedType.isNotEmpty) 'type': normalizedType,
        },
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException('Jikan respondio ${response.statusCode}');
    }
    return _parseJikanCandidateList(response.body);
  }

  Future<SeriesItem> buildImportSeries(
    RemoteSearchCandidate candidate, {
    required Iterable<String> existingNames,
  }) async {
    final enrichedCandidate = await enrichCandidateVisuals(candidate);
    return switch (enrichedCandidate.provider) {
      RemoteProvider.animeAv1 => await _buildAnimeAv1Series(enrichedCandidate,
          existingNames: existingNames),
      RemoteProvider.jkAnime => await _buildJkAnimeSeries(enrichedCandidate,
          existingNames: existingNames),
      RemoteProvider.latAnime => await _buildLatAnimeSeries(enrichedCandidate,
          existingNames: existingNames),
      RemoteProvider.justAnime =>
        enrichedCandidate.toSeries(existingNames: existingNames),
      RemoteProvider.aniPm =>
        enrichedCandidate.toSeries(existingNames: existingNames),
      RemoteProvider.animeFlv => await _buildAnimeFlvSeries(enrichedCandidate,
          existingNames: existingNames),
      RemoteProvider.bilibili =>
        _buildBiliBiliSeries(enrichedCandidate, existingNames: existingNames),
      _ => enrichedCandidate.toSeries(existingNames: existingNames),
    };
  }

  Future<RemoteSearchCandidate> enrichCandidateVisuals(
      RemoteSearchCandidate candidate) async {
    if (candidate.provider == RemoteProvider.catalog) {
      return _enrichCandidateVisuals(
        await _enrichCatalogCandidateFromJikan(candidate),
      );
    }
    return _enrichCatalogCandidateFromJikan(
      await _enrichCandidateVisuals(candidate),
    );
  }

  Future<RemoteSearchCandidate> enrichCatalogCandidateMetadata(
    RemoteSearchCandidate candidate,
  ) {
    return _enrichCatalogCandidateFromJikan(candidate);
  }

  Future<EpisodeItem?> resolveProviderEpisode({
    required SeriesItem series,
    required EpisodeItem episode,
    required RemoteProvider provider,
  }) async {
    if (!episode.isRemote ||
        provider == RemoteProvider.animeKai ||
        provider == RemoteProvider.catalog ||
        provider == RemoteProvider.facebook) {
      return null;
    }
    if (provider == RemoteProvider.bilibili) {
      return _resolveBiliBiliProviderEpisode(series: series, episode: episode);
    }
    if (provider == RemoteProvider.youtube) {
      return _resolveYoutubeProviderEpisode(series: series, episode: episode);
    }
    if (provider == RemoteProvider.internetArchive) {
      return _resolveInternetArchiveProviderEpisode(
        series: series,
        episode: episode,
      );
    }
    final queries = _seriesProviderLookupQueries(series, episode).take(4);
    final candidates = <RemoteSearchCandidate>[];
    for (final query in queries) {
      final results = await _safeProviderSearch(
        () => _searchProvider(provider, query, releaseYear: series.releaseYear),
      );
      candidates.addAll(results);
      if (results.any(
          (candidate) => _scoreProviderCandidate(series, candidate) >= 900)) {
        break;
      }
    }
    final best = _pickBestProviderCandidate(
      series: series,
      episode: episode,
      candidates: _dedupe(candidates),
    );
    if (best == null) {
      if (provider == RemoteProvider.jkAnime) {
        return _buildGuessedJkAnimeEpisode(series: series, episode: episode);
      }
      return null;
    }
    final imported = await buildImportSeries(
      best,
      existingNames: const [],
    );
    return _findEquivalentProviderEpisode(imported, episode);
  }

  Future<List<RemoteSearchCandidate>> _searchProvider(
    RemoteProvider provider,
    String query, {
    required int releaseYear,
  }) {
    return switch (provider) {
      RemoteProvider.animeAv1 =>
        searchAnimeAv1(query, releaseYear: releaseYear),
      RemoteProvider.jkAnime => searchJkAnime(query, releaseYear: releaseYear),
      RemoteProvider.latAnime =>
        searchLatAnime(query, releaseYear: releaseYear),
      RemoteProvider.justAnime =>
        searchJustAnime(query, releaseYear: releaseYear),
      RemoteProvider.aniPm => searchAniPm(query, releaseYear: releaseYear),
      RemoteProvider.animeFlv =>
        searchAnimeFlv(query, releaseYear: releaseYear),
      RemoteProvider.internetArchive => searchInternetArchive(query),
      RemoteProvider.bilibili => searchBiliBili(query),
      _ => Future.value(const <RemoteSearchCandidate>[]),
    };
  }

  Future<EpisodeItem?> _resolveInternetArchiveProviderEpisode({
    required SeriesItem series,
    required EpisodeItem episode,
  }) async {
    final title = _internetArchiveLookupTitle(series);
    if (title.isEmpty || episode.episodeNumber < 0) {
      return null;
    }
    final candidates = await _safeProviderSearch(
      () => searchInternetArchive(title),
    );
    for (final candidate in candidates.take(4)) {
      final files = await _internetArchiveVideoFiles(candidate.slug);
      final selected = _selectInternetArchiveEpisodeFile(
        files,
        episode.episodeNumber,
      );
      if (selected == null) {
        continue;
      }
      final directUrl = _internetArchiveDownloadUrl(
        candidate.slug,
        selected.name,
      );
      final watchUrl = _internetArchiveDetailsUrl(
        candidate.slug,
        fileName: selected.name,
      );
      _debugResolver(
        'internetarchive selected identifier=${candidate.slug} '
        'episode=${episode.episodeNumber} file="${selected.name}" '
        'url=${_debugUrlLabel(directUrl)}',
      );
      return episode.copyWith(
        displayName: episode.displayName,
        relativePath: 'Internet Archive / ${selected.displayName}',
        filePath: directUrl,
        provider: RemoteProvider.internetArchive,
        slug: candidate.slug,
        watchUrl: watchUrl,
        imageUrl: episode.imageUrl.isNotEmpty
            ? episode.imageUrl
            : _internetArchiveImageUrl(candidate.slug),
        durationLabel: episode.durationLabel.isNotEmpty
            ? episode.durationLabel
            : selected.durationLabel,
      );
    }
    _debugResolver(
      'internetarchive lookup no match title="$title" '
      'episode=${episode.episodeNumber}',
    );
    return null;
  }

  Future<RemoteDirectStream?> _resolveInternetArchiveDirectStream(
    EpisodeItem entry,
  ) async {
    final pageResolved = await _resolveInternetArchivePlayerStream(entry);
    if (pageResolved != null) {
      return pageResolved;
    }

    final playbackUrl = entry.filePath.trim();
    if (playbackUrl.isEmpty) {
      return null;
    }
    return _internetArchiveDirectStream(
      playbackUrl: playbackUrl,
      pageUrl: entry.watchUrl.trim().isNotEmpty ? entry.watchUrl : playbackUrl,
    );
  }

  Future<RemoteDirectStream?> _resolveInternetArchivePlayerStream(
    EpisodeItem entry,
  ) async {
    final pageUrl = entry.watchUrl.trim();
    if (pageUrl.isEmpty || !pageUrl.contains('archive.org/details/')) {
      return null;
    }
    try {
      final response = await _client.get(Uri.parse(pageUrl), headers: const {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'User-Agent': _defaultFetchUserAgent,
      }).timeout(const Duration(seconds: 18));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _debugResolver(
          'internetarchive player page failed status=${response.statusCode} '
          'page=${_debugUrlLabel(pageUrl)}',
        );
        return null;
      }
      final selected = _selectInternetArchivePlaylistItem(
        _parseInternetArchivePlayAvPlaylist(response.body),
        entry,
      );
      if (selected == null) {
        _debugResolver(
          'internetarchive player playlist no match '
          'page=${_debugUrlLabel(pageUrl)} episode=${entry.episodeNumber}',
        );
        return null;
      }
      final sourceUrl = _internetArchiveSourceUrl(selected.sourceFile);
      if (sourceUrl.isEmpty) {
        return null;
      }
      _debugResolver(
        'internetarchive player selected title="${selected.title}" '
        'source=${_debugUrlLabel(sourceUrl)}',
      );
      return _internetArchiveDirectStream(
        playbackUrl: sourceUrl,
        pageUrl: pageUrl,
        durationSeconds: selected.durationSeconds,
      );
    } catch (error) {
      _debugResolver(
        'internetarchive player resolve failed page=${_debugUrlLabel(pageUrl)} '
        'error=$error',
      );
      return null;
    }
  }

  RemoteDirectStream _internetArchiveDirectStream({
    required String playbackUrl,
    required String pageUrl,
    int durationSeconds = 0,
  }) {
    final kind = _inferPlaybackKind(playbackUrl);
    return RemoteDirectStream(
      playbackUrl: playbackUrl,
      playbackKind: kind.isNotEmpty ? kind : 'direct',
      pageUrl: pageUrl,
      availableModes: const {'archive-direct'},
      selectedMode: 'archive-direct',
      provider: RemoteProvider.internetArchive,
      server: 'archive-direct',
      httpHeaders: {
        'User-Agent': _defaultFetchUserAgent,
        'Referer': pageUrl.isNotEmpty ? pageUrl : _internetArchiveBaseUrl,
        if (durationSeconds > 0)
          'X-Tanuki-Duration-Seconds': '$durationSeconds',
      },
    );
  }

  List<_InternetArchivePlaylistItem> _parseInternetArchivePlayAvPlaylist(
    String html,
  ) {
    final match = RegExp(
      r'<play-av\b[^>]*\bplaylist="([^"]*)"',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    final rawPlaylist = match?.group(1);
    if (rawPlaylist == null || rawPlaylist.trim().isEmpty) {
      return const [];
    }
    final decodedPlaylist = _decodeHtml(rawPlaylist);
    final decoded = jsonDecode(decodedPlaylist);
    if (decoded is! List) {
      return const [];
    }
    return decoded
        .whereType<Map>()
        .map((entry) => _internetArchivePlaylistItemFromJson(
              Map<String, dynamic>.from(entry),
            ))
        .whereType<_InternetArchivePlaylistItem>()
        .toList(growable: false);
  }

  _InternetArchivePlaylistItem? _internetArchivePlaylistItemFromJson(
    Map<String, dynamic> entry,
  ) {
    final sources = entry['sources'];
    if (sources is! List || sources.isEmpty) {
      return null;
    }
    final sourceFiles = sources
        .whereType<Map>()
        .map((source) => Map<String, dynamic>.from(source))
        .where((source) {
      final file = _readString(source['file']);
      final type = _readString(source['type']).toLowerCase();
      return file.isNotEmpty &&
          !file.toLowerCase().contains('longplay') &&
          (_internetArchiveVideoExtension(file).isNotEmpty ||
              const {'mp4', 'webm', 'm4v', 'mkv', 'avi', 'mov'}.contains(type));
    }).toList();
    if (sourceFiles.isEmpty) {
      return null;
    }
    sourceFiles.sort((left, right) {
      final leftFile = _readString(left['file']);
      final rightFile = _readString(right['file']);
      return _internetArchiveSourceScore(rightFile, right)
          .compareTo(_internetArchiveSourceScore(leftFile, left));
    });
    final title = _cleanRemoteText(_readString(entry['title']));
    final orig = _readString(entry['orig']);
    final sourceFile = _readString(sourceFiles.first['file']);
    final number = _internetArchiveEpisodeNumberFromName(
      orig.isNotEmpty
          ? orig
          : title.isNotEmpty
              ? title
              : sourceFile,
    );
    if (number < 0 || sourceFile.isEmpty) {
      return null;
    }
    return _InternetArchivePlaylistItem(
      title: title,
      orig: orig,
      sourceFile: sourceFile,
      episodeNumber: number,
      durationSeconds: _readDouble(entry['duration']).round(),
    );
  }

  int _internetArchiveSourceScore(
    String file,
    Map<String, dynamic> source,
  ) {
    final extension = _internetArchiveVideoExtension(file);
    var score = 0;
    if (extension == 'mp4') {
      score += 1000;
    } else if (extension == 'webm' || extension == 'm4v') {
      score += 700;
    } else if (extension == 'mkv') {
      score += 500;
    } else if (extension == 'avi') {
      score += 300;
    }
    final height = _readInt(source['height']);
    score += min(height, 2160);
    return score;
  }

  _InternetArchivePlaylistItem? _selectInternetArchivePlaylistItem(
    List<_InternetArchivePlaylistItem> items,
    EpisodeItem entry,
  ) {
    if (items.isEmpty) {
      return null;
    }
    final fileName = _internetArchiveFileNameFromDetailsUrl(entry.watchUrl);
    if (fileName.isNotEmpty) {
      final normalizedFileName = _normalizeInternetArchiveFileName(fileName);
      for (final item in items) {
        if (_normalizeInternetArchiveFileName(item.orig) ==
                normalizedFileName ||
            _normalizeInternetArchiveFileName(item.sourceFile)
                .endsWith(normalizedFileName)) {
          return item;
        }
      }
    }
    return items.firstWhere(
      (item) => item.episodeNumber == entry.episodeNumber,
      orElse: () => items.first,
    );
  }

  String _internetArchiveSourceUrl(String sourceFile) {
    final normalized = _decodeHtml(sourceFile).trim();
    if (normalized.isEmpty) {
      return '';
    }
    final uri = Uri.tryParse(normalized);
    if (uri != null && uri.hasScheme) {
      return normalized;
    }
    if (normalized.startsWith('//')) {
      return 'https:$normalized';
    }
    if (normalized.startsWith('/')) {
      return '$_internetArchiveBaseUrl$normalized';
    }
    return '$_internetArchiveBaseUrl/$normalized';
  }

  String _internetArchiveFileNameFromDetailsUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.pathSegments.length < 3) {
      return '';
    }
    final detailsIndex = uri.pathSegments.indexOf('details');
    if (detailsIndex < 0 || uri.pathSegments.length <= detailsIndex + 2) {
      return '';
    }
    return uri.pathSegments
        .skip(detailsIndex + 2)
        .map(_safeDecodeUriComponent)
        .join('/');
  }

  String _normalizeInternetArchiveFileName(String value) {
    return _safeDecodeUriComponent(value)
        .split('/')
        .last
        .replaceAll('+', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
  }

  String _internetArchiveLookupTitle(SeriesItem series) {
    final candidates = [
      series.name,
      series.japaneseTitle,
      ...series.aliases,
    ];
    for (final candidate in candidates) {
      final cleaned = _cleanInternetArchiveSearchQuery(candidate);
      if (cleaned.isNotEmpty) {
        return cleaned;
      }
    }
    return '';
  }

  String _cleanInternetArchiveSearchQuery(String value) {
    return value
        .replaceAll(RegExp(r'[\[\]【】★☆]'), ' ')
        .replaceAll(
            RegExp(r'\b(season|temporada)\s+\d+\b', caseSensitive: false), ' ')
        .replaceAll(
            RegExp(r'\b\d+(st|nd|rd|th)\s+season\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<RemoteSearchCandidate> _parseInternetArchiveSearchResults(
    String payload,
  ) {
    final decoded = jsonDecode(payload);
    final response = decoded is Map ? decoded['response'] : null;
    final docs = response is Map ? response['docs'] : null;
    if (docs is! List) {
      return const [];
    }
    return docs
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .where((entry) {
          final searchable = [
            _readString(entry['identifier']),
            _readString(entry['title']),
            _readString(entry['description']),
          ].join(' ').toLowerCase();
          return !searchable.contains('longplay');
        })
        .map((entry) {
          final identifier = _readString(entry['identifier']);
          final title = _cleanRemoteText(_readString(entry['title']));
          return RemoteSearchCandidate(
            provider: RemoteProvider.internetArchive,
            slug: identifier,
            title: title.isNotEmpty ? title : identifier,
            watchUrl: _internetArchiveDetailsUrl(identifier),
            seriesUrl: _internetArchiveDetailsUrl(identifier),
            imageUrl: _internetArchiveImageUrl(identifier),
            description: _cleanRemoteText(_readString(entry['description'])),
            releaseYear: _readInt(entry['year']),
            format: 'Video',
          );
        })
        .where((candidate) =>
            candidate.slug.isNotEmpty && candidate.title.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<_InternetArchiveVideoFile>> _internetArchiveVideoFiles(
    String identifier,
  ) async {
    if (identifier.trim().isEmpty) {
      return const [];
    }
    final response = await _getInternetArchiveJson(
      Uri.https('archive.org', '/metadata/$identifier'),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _debugResolver(
        'internetarchive metadata failed status=${response.statusCode} '
        'identifier=$identifier',
      );
      return const [];
    }
    final decoded = jsonDecode(response.body);
    final files = decoded is Map ? decoded['files'] : null;
    if (files is! List) {
      return const [];
    }
    return files
        .whereType<Map>()
        .map((entry) =>
            _internetArchiveVideoFileFromJson(Map<String, dynamic>.from(entry)))
        .whereType<_InternetArchiveVideoFile>()
        .toList(growable: false);
  }

  _InternetArchiveVideoFile? _internetArchiveVideoFileFromJson(
    Map<String, dynamic> entry,
  ) {
    final name = _readString(entry['name']);
    if (name.isEmpty || _internetArchiveVideoExtension(name).isEmpty) {
      return null;
    }
    final lower = name.toLowerCase();
    if (lower.contains('longplay')) {
      return null;
    }
    final episodeNumber = _internetArchiveEpisodeNumberFromName(name);
    if (episodeNumber < 0) {
      return null;
    }
    final lengthSeconds = _readDouble(entry['length']).round();
    return _InternetArchiveVideoFile(
      name: name,
      episodeNumber: episodeNumber,
      source: _readString(entry['source']),
      format: _readString(entry['format']),
      lengthSeconds: lengthSeconds,
    );
  }

  _InternetArchiveVideoFile? _selectInternetArchiveEpisodeFile(
    List<_InternetArchiveVideoFile> files,
    int episodeNumber,
  ) {
    final candidates =
        files.where((file) => file.episodeNumber == episodeNumber).toList();
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((left, right) => _internetArchiveFileScore(right)
        .compareTo(_internetArchiveFileScore(left)));
    return candidates.first;
  }

  int _internetArchiveFileScore(_InternetArchiveVideoFile file) {
    final extension = _internetArchiveVideoExtension(file.name);
    var score = 0;
    if (extension == 'mp4') {
      score += 1000;
    } else if (extension == 'webm' || extension == 'm4v') {
      score += 700;
    } else if (extension == 'mkv') {
      score += 500;
    } else if (extension == 'avi') {
      score += 300;
    }
    final format = file.format.toLowerCase();
    if (format.contains('h.264') || format.contains('mpeg4')) {
      score += 120;
    }
    if (file.source.toLowerCase() == 'derivative') {
      score += 80;
    }
    if (file.lengthSeconds >= 10 * 60) {
      score += 40;
    }
    return score;
  }

  int _internetArchiveEpisodeNumberFromName(String name) {
    final normalized = _safeDecodeUriComponent(name)
        .replaceAll(RegExp(r'[_+]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final patterns = [
      RegExp(
        r'(?:capitulo|capítulo|episodio|episode|chapter|cap|ep)\.?\s*(\d{1,4})',
        caseSensitive: false,
      ),
      RegExp(r'(?:^|[\/\s._-])(\d{1,4})(?=\.[a-z0-9]{2,5}$)',
          caseSensitive: false),
      RegExp(r'(?:^|[\/\s._-])(\d{1,4})(?:[\/\s._-]|$)', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(normalized);
      final value = match == null ? null : int.tryParse(match.group(1) ?? '');
      if (value != null && value >= 0 && value < 2000) {
        return value;
      }
    }
    return -1;
  }

  String _internetArchiveVideoExtension(String name) {
    final lower = name.toLowerCase();
    final match = RegExp(r'\.([a-z0-9]{2,5})(?:\?|$)').firstMatch(lower);
    final extension = match?.group(1) ?? '';
    return const {'mp4', 'm4v', 'webm', 'mkv', 'avi', 'mov'}.contains(extension)
        ? extension
        : '';
  }

  String _internetArchiveDetailsUrl(String identifier, {String fileName = ''}) {
    final cleanIdentifier = identifier.trim();
    if (cleanIdentifier.isEmpty) {
      return _internetArchiveBaseUrl;
    }
    final base =
        '$_internetArchiveBaseUrl/details/${Uri.encodeComponent(cleanIdentifier)}';
    if (fileName.trim().isEmpty) {
      return base;
    }
    return '$base/${_encodeInternetArchiveFilePath(fileName)}';
  }

  String _internetArchiveDownloadUrl(String identifier, String fileName) {
    return '$_internetArchiveBaseUrl/download/'
        '${Uri.encodeComponent(identifier.trim())}/'
        '${_encodeInternetArchiveFilePath(fileName)}';
  }

  String _internetArchiveImageUrl(String identifier) {
    return identifier.trim().isEmpty
        ? ''
        : '$_internetArchiveBaseUrl/services/img/${Uri.encodeComponent(identifier.trim())}';
  }

  String _encodeInternetArchiveFilePath(String fileName) {
    return fileName
        .split('/')
        .map((segment) => Uri.encodeComponent(segment))
        .join('/');
  }

  Future<EpisodeItem?> _resolveYoutubeProviderEpisode({
    required SeriesItem series,
    required EpisodeItem episode,
  }) async {
    final title = _youtubeLookupTitle(series);
    if (title.isEmpty || episode.episodeNumber <= 0) {
      return null;
    }
    final options = <_YoutubePlaybackOption>[];
    options.addAll(
      await _searchYoutubeEpisodeOptions(
        '$title episodio ${episode.episodeNumber} sub esp',
        mode: YoutubePlaybackMode.sub,
        episodeNumber: episode.episodeNumber,
        limit: 2,
      ),
    );
    options.addAll(
      await _searchYoutubeEpisodeOptions(
        '$title episodio ${episode.episodeNumber} latino',
        mode: YoutubePlaybackMode.dub,
        episodeNumber: episode.episodeNumber,
        limit: 2,
      ),
    );
    if (options.isEmpty) {
      _debugResolver('youtube lookup no options title="$title"');
      return null;
    }
    final first = options.first;
    final stateKey = episode.seriesStateKey.trim().isNotEmpty
        ? episode.seriesStateKey
        : series.stableKey;
    return EpisodeItem(
      seriesName: episode.seriesName,
      seriesStateKey: stateKey,
      episodeIndex: episode.episodeIndex,
      episodeNumber: episode.episodeNumber,
      displayName: episode.displayName,
      relativePath: 'YouTube / Capitulo ${episode.episodeNumber}',
      filePath: first.url,
      sourceType: SourceType.remote,
      provider: RemoteProvider.youtube,
      slug: first.videoId,
      watchUrl: first.url,
      releaseYear:
          episode.releaseYear > 0 ? episode.releaseYear : series.releaseYear,
      imageUrl: first.imageUrl.isNotEmpty ? first.imageUrl : episode.imageUrl,
      description: _encodeYoutubeEpisodeOptions(options),
      durationLabel: first.durationLabel.isNotEmpty
          ? first.durationLabel
          : episode.durationLabel,
    );
  }

  Future<EpisodeItem?> _resolveBiliBiliProviderEpisode({
    required SeriesItem series,
    required EpisodeItem episode,
  }) async {
    final title = _bilibiliLookupTitle(series);
    if (title.isEmpty || episode.episodeNumber <= 0) {
      return null;
    }
    final query = '$title episode ${episode.episodeNumber}';
    final options = await _searchBiliBiliEpisodeOptions(query, limit: 2);
    if (options.isEmpty) {
      _debugResolver('bilibili lookup no options query="$query"');
      return null;
    }
    final first = options.first;
    final stateKey = episode.seriesStateKey.trim().isNotEmpty
        ? episode.seriesStateKey
        : series.stableKey;
    final imageUrl =
        first.imageUrl.isNotEmpty ? first.imageUrl : episode.imageUrl;
    return EpisodeItem(
      seriesName: episode.seriesName,
      seriesStateKey: stateKey,
      episodeIndex: episode.episodeIndex,
      episodeNumber: episode.episodeNumber,
      displayName: episode.displayName,
      relativePath: 'BiliBili / Capitulo ${episode.episodeNumber}',
      filePath: first.url,
      sourceType: SourceType.remote,
      provider: RemoteProvider.bilibili,
      slug: first.videoId,
      watchUrl: first.url,
      releaseYear:
          episode.releaseYear > 0 ? episode.releaseYear : series.releaseYear,
      imageUrl: imageUrl,
      description: _encodeBiliBiliEpisodeOptions(options),
      durationLabel: first.durationLabel.isNotEmpty
          ? first.durationLabel
          : episode.durationLabel,
    );
  }

  String _bilibiliLookupTitle(SeriesItem series) {
    final candidates = [
      series.name,
      ...series.aliases,
      series.japaneseTitle,
    ];
    for (final candidate in candidates) {
      final cleaned = _cleanBiliBiliSearchQuery(candidate);
      if (cleaned.isNotEmpty) {
        return cleaned;
      }
    }
    return '';
  }

  RemoteSearchCandidate? _pickBestProviderCandidate({
    required SeriesItem series,
    required EpisodeItem episode,
    required List<RemoteSearchCandidate> candidates,
  }) {
    RemoteSearchCandidate? best;
    var bestScore = 0;
    for (final candidate in candidates) {
      var score = _scoreProviderCandidate(series, candidate);
      if (candidate.episodeCount > 0) {
        if (candidate.episodeCount >= episode.episodeNumber) {
          score += 160;
        } else {
          score -= 420;
        }
      }
      if (series.episodeCount > 0 && candidate.episodeCount > 0) {
        final diff = (candidate.episodeCount - series.episodeCount).abs();
        score += switch (diff) {
          0 => 220,
          1 || 2 => 90,
          _ => -min(220, diff * 20),
        };
      }
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return bestScore >= 240 ? best : null;
  }

  int _scoreProviderCandidate(
    SeriesItem series,
    RemoteSearchCandidate candidate,
  ) {
    var score = 0;
    for (final query in _seriesProviderLookupQueries(series, null)) {
      score = max(score, _scoreCandidateAgainstQuery(query, candidate));
    }
    if (series.releaseYear > 0 && candidate.releaseYear > 0) {
      final diff = (series.releaseYear - candidate.releaseYear).abs();
      score += switch (diff) {
        0 => 420,
        1 => 130,
        2 => 40,
        _ => -260,
      };
    }
    final seriesMovie = _normalizeMatchText(series.format).contains('movie') ||
        _normalizeMatchText(series.format).contains('pelicula');
    final candidateMovie = _candidateLooksMovie(candidate);
    if (series.format.trim().isNotEmpty && seriesMovie == candidateMovie) {
      score += 80;
    }
    return score;
  }

  List<String> _seriesProviderLookupQueries(
    SeriesItem series,
    EpisodeItem? episode,
  ) {
    final queries = <String>[
      series.name,
      _stripProviderSuffix(series.name),
      series.japaneseTitle,
      ...series.aliases,
      if (episode != null) episode.seriesName,
      if (episode != null) _stripProviderSuffix(episode.seriesName),
    ];
    final seen = <String>{};
    return queries
        .map(_cleanRemoteText)
        .where((entry) => entry.isNotEmpty)
        .where((entry) => seen.add(_normalizeMatchText(entry)))
        .toList();
  }

  EpisodeItem? _findEquivalentProviderEpisode(
    SeriesItem series,
    EpisodeItem episode,
  ) {
    final requestedDate = _episodeDateKey(episode.airDateIso);
    if (requestedDate.isNotEmpty) {
      final dateMatches = series.episodes
          .where((candidate) =>
              _episodeDateKey(candidate.airDateIso) == requestedDate)
          .toList(growable: false);
      if (dateMatches.length == 1) {
        return dateMatches.single;
      }
      for (final candidate in dateMatches) {
        if (candidate.episodeNumber == episode.episodeNumber) {
          return candidate;
        }
      }
    }
    for (final candidate in series.episodes) {
      if (candidate.episodeNumber == episode.episodeNumber) {
        return candidate;
      }
    }
    if (episode.episodeIndex >= 0 &&
        episode.episodeIndex < series.episodes.length) {
      return series.episodes[episode.episodeIndex];
    }
    return null;
  }

  EpisodeItem? _buildGuessedJkAnimeEpisode({
    required SeriesItem series,
    required EpisodeItem episode,
  }) {
    final sourceSlug =
        episode.provider == RemoteProvider.jkAnime ? episode.slug.trim() : '';
    final slug = _normalizeJkAnimeGuessSlug(
      sourceSlug.isNotEmpty ? sourceSlug : episode.seriesName,
    );
    if (slug.isEmpty) {
      return null;
    }
    final episodeNumber = episode.episodeNumber < 1 ? 1 : episode.episodeNumber;
    final seriesUrl = _normalizeJkAnimeSeriesUrl(slug);
    final movieLike = _seriesLooksMovie(series) ||
        episode.filePath.toLowerCase().contains('/pelicula/');
    final episodeUrl =
        _buildJkAnimeEpisodeUrl(slug, episodeNumber, movie: movieLike);
    if (seriesUrl.isEmpty || episodeUrl.isEmpty) {
      return null;
    }
    return episode.copyWith(
      provider: RemoteProvider.jkAnime,
      slug: slug,
      filePath: episodeUrl,
      watchUrl: seriesUrl,
      releaseYear:
          episode.releaseYear > 0 ? episode.releaseYear : series.releaseYear,
    );
  }

  Future<SeriesItem> _buildAnimeAv1Series(
    RemoteSearchCandidate candidate, {
    required Iterable<String> existingNames,
  }) async {
    final slug = _extractAnimeAv1Slug(candidate.seriesUrl.isNotEmpty
        ? candidate.seriesUrl
        : candidate.watchUrl);
    final seriesUrl = _normalizeAnimeAv1SeriesUrl(
      candidate.seriesUrl.isNotEmpty
          ? candidate.seriesUrl
          : candidate.watchUrl.isNotEmpty
              ? candidate.watchUrl
              : slug.isEmpty
                  ? ''
                  : '$_animeAv1BaseUrl/media/$slug',
    );
    if (slug.isEmpty || seriesUrl.isEmpty) {
      return candidate.toSeries(existingNames: existingNames);
    }

    final response = await _get(Uri.parse(seriesUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return candidate.toSeries(existingNames: existingNames);
    }
    final html = response.body;
    final episodeNumbers = _parseAnimeAv1EpisodeNumbers(html, slug);
    if (episodeNumbers.isEmpty) {
      return candidate.toSeries(existingNames: existingNames);
    }

    final title = _cleanRemoteText(candidate.title).isNotEmpty
        ? _cleanRemoteText(candidate.title)
        : _cleanRemoteText(_extractAnimeAv1SeriesTitle(html));
    final name = uniqueSeriesName(
        title.isEmpty ? 'Serie AnimeAV1' : title, existingNames, 'AnimeAV1');
    final stateKey = normalizeSeriesKey(name);
    final imageUrl = _cleanRemoteUrl(candidate.imageUrl).isNotEmpty
        ? _cleanRemoteUrl(candidate.imageUrl)
        : _extractAnimeAv1SeriesImageUrl(html);
    final episodeDetails = _episodeMetadataByNumber(candidate.episodeDetails);
    final parsedEpisodes = episodeNumbers.asMap().entries.map((entry) {
      final index = entry.key;
      final episodeNumber = entry.value;
      final episode = EpisodeItem(
        seriesName: name,
        seriesStateKey: stateKey,
        episodeIndex: index,
        episodeNumber: episodeNumber,
        displayName: '$name - Capitulo $episodeNumber',
        relativePath: 'AnimeAV1 / Capitulo $episodeNumber',
        filePath: _buildAnimeAv1EpisodeUrl(seriesUrl, episodeNumber),
        sourceType: SourceType.remote,
        provider: RemoteProvider.animeAv1,
        slug: slug,
        watchUrl: seriesUrl,
        releaseYear: candidate.releaseYear,
        imageUrl: imageUrl,
      );
      return _applyEpisodeMetadata(
        episode,
        episodeDetails[episodeNumber],
        fallbackImageUrl: imageUrl,
      );
    }).toList();
    final episodes = _completeImportedEpisodes(
      parsedEpisodes,
      candidate: candidate,
      seriesName: name,
      seriesStateKey: stateKey,
      fallbackImageUrl: imageUrl,
      fallbackWatchUrl: seriesUrl,
      releaseYear: candidate.releaseYear,
      episodeDetails: episodeDetails,
    );

    return SeriesItem(
      name: name,
      seriesStateKey: stateKey,
      sourceType: SourceType.remote,
      provider: RemoteProvider.animeAv1,
      slug: slug,
      watchUrl: seriesUrl,
      episodeCount: episodes.length,
      imageUrl: imageUrl,
      backgroundUrl: candidate.backgroundUrl,
      logoUrl: candidate.logoUrl,
      trailerUrl: candidate.trailerUrl,
      description: candidate.description,
      rating: candidate.rating,
      episodes: episodes,
      releaseYear: candidate.releaseYear,
      format: candidate.format,
      catalogId: candidate.catalogId,
      japaneseTitle: candidate.japaneseTitle,
      aliases: candidate.aliases,
      cast: candidate.cast,
    );
  }

  Future<SeriesItem> _buildJkAnimeSeries(
    RemoteSearchCandidate candidate, {
    required Iterable<String> existingNames,
  }) async {
    final slug = candidate.slug.isNotEmpty
        ? candidate.slug
        : _extractJkAnimeSlug(candidate.seriesUrl.isNotEmpty
            ? candidate.seriesUrl
            : candidate.watchUrl);
    final seriesUrl = _normalizeJkAnimeSeriesUrl(
      candidate.seriesUrl.isNotEmpty
          ? candidate.seriesUrl
          : slug.isEmpty
              ? ''
              : '$_jkAnimeBaseUrl/$slug/',
    );
    if (slug.isEmpty || seriesUrl.isEmpty) {
      return candidate.toSeries(existingNames: existingNames);
    }

    final response = await _get(Uri.parse(seriesUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return candidate.toSeries(existingNames: existingNames);
    }
    final html = response.body;
    final episodeCount = _parseJkAnimeEpisodeCount(html);
    if (episodeCount <= 0) {
      return candidate.toSeries(existingNames: existingNames);
    }

    final title = _cleanRemoteText(candidate.title).isNotEmpty
        ? _cleanRemoteText(candidate.title)
        : _parseJkAnimeSeriesTitle(html);
    final name = uniqueSeriesName(
        title.isEmpty ? 'Serie JKAnime' : title, existingNames, 'JKAnime');
    final stateKey = normalizeSeriesKey(name);
    final imageUrl = _cleanRemoteUrl(candidate.imageUrl).isNotEmpty
        ? _cleanRemoteUrl(candidate.imageUrl)
        : _parseJkAnimeImageUrl(html);
    final movieLike = _candidateLooksMovie(candidate) ||
        candidate.watchUrl.toLowerCase().contains('/pelicula/');
    final episodeDetails = _episodeMetadataByNumber(candidate.episodeDetails);
    final parsedEpisodes = List.generate(episodeCount, (index) {
      final episodeNumber = index + 1;
      final episode = EpisodeItem(
        seriesName: name,
        seriesStateKey: stateKey,
        episodeIndex: index,
        episodeNumber: episodeNumber,
        displayName:
            movieLike ? '$name - Pelicula' : '$name - Capitulo $episodeNumber',
        relativePath: movieLike
            ? 'JKAnime / Pelicula'
            : 'JKAnime / Capitulo $episodeNumber',
        filePath:
            _buildJkAnimeEpisodeUrl(slug, episodeNumber, movie: movieLike),
        sourceType: SourceType.remote,
        provider: RemoteProvider.jkAnime,
        slug: slug,
        watchUrl: seriesUrl,
        releaseYear: candidate.releaseYear,
        imageUrl: imageUrl,
      );
      return _applyEpisodeMetadata(
        episode,
        episodeDetails[episodeNumber],
        fallbackImageUrl: imageUrl,
      );
    });
    final episodes = _completeImportedEpisodes(
      parsedEpisodes,
      candidate: candidate,
      seriesName: name,
      seriesStateKey: stateKey,
      fallbackImageUrl: imageUrl,
      fallbackWatchUrl: seriesUrl,
      releaseYear: candidate.releaseYear,
      episodeDetails: episodeDetails,
    );

    return SeriesItem(
      name: name,
      seriesStateKey: stateKey,
      sourceType: SourceType.remote,
      provider: RemoteProvider.jkAnime,
      slug: slug,
      watchUrl: seriesUrl,
      episodeCount: episodes.length,
      imageUrl: imageUrl,
      backgroundUrl: candidate.backgroundUrl,
      logoUrl: candidate.logoUrl,
      trailerUrl: candidate.trailerUrl,
      description: candidate.description,
      rating: candidate.rating,
      episodes: episodes,
      releaseYear: candidate.releaseYear,
      format: candidate.format,
      catalogId: candidate.catalogId,
      japaneseTitle: candidate.japaneseTitle,
      aliases: candidate.aliases,
      cast: candidate.cast,
    );
  }

  Future<SeriesItem> _buildLatAnimeSeries(
    RemoteSearchCandidate candidate, {
    required Iterable<String> existingNames,
  }) async {
    final slug = candidate.slug.isNotEmpty
        ? candidate.slug
        : _extractLatAnimeSlug(candidate.seriesUrl.isNotEmpty
            ? candidate.seriesUrl
            : candidate.watchUrl);
    final seriesUrl = _normalizeLatAnimeSeriesUrl(
      candidate.seriesUrl.isNotEmpty
          ? candidate.seriesUrl
          : slug.isEmpty
              ? ''
              : '$_latAnimeBaseUrl/anime/$slug',
    );
    if (slug.isEmpty || seriesUrl.isEmpty) {
      return candidate.toSeries(existingNames: existingNames);
    }

    final response = await _get(Uri.parse(seriesUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return candidate.toSeries(existingNames: existingNames);
    }
    final html = response.body;
    final episodeLinks = _parseLatAnimeEpisodeLinks(html);
    if (episodeLinks.isEmpty) {
      return candidate.toSeries(existingNames: existingNames);
    }

    final title = _cleanRemoteText(candidate.title).isNotEmpty
        ? _cleanRemoteText(candidate.title)
        : _extractLatAnimeSeriesTitle(html);
    final name = uniqueSeriesName(
        title.isEmpty ? 'Serie LatAnime' : title, existingNames, 'LatAnime');
    final stateKey = normalizeSeriesKey(name);
    final imageUrl = _cleanRemoteUrl(candidate.imageUrl).isNotEmpty
        ? _cleanRemoteUrl(candidate.imageUrl)
        : _extractLatAnimeSeriesImageUrl(html);
    final releaseYear = candidate.releaseYear > 0
        ? candidate.releaseYear
        : _extractYearFromText(html);
    final episodeDetails = _episodeMetadataByNumber(candidate.episodeDetails);
    final parsedEpisodes = episodeLinks.asMap().entries.map((entry) {
      final index = entry.key;
      final episode = entry.value;
      final item = EpisodeItem(
        seriesName: name,
        seriesStateKey: stateKey,
        episodeIndex: index,
        episodeNumber: episode.episodeNumber,
        displayName: '$name - Capitulo ${episode.episodeNumber}',
        relativePath: 'LatAnime / Capitulo ${episode.episodeNumber}',
        filePath: episode.url,
        sourceType: SourceType.remote,
        provider: RemoteProvider.latAnime,
        slug: slug,
        watchUrl: seriesUrl,
        releaseYear: releaseYear,
        imageUrl: imageUrl,
      );
      return _applyEpisodeMetadata(
        item,
        episodeDetails[episode.episodeNumber],
        fallbackImageUrl: imageUrl,
      );
    }).toList();
    final episodes = _completeImportedEpisodes(
      parsedEpisodes,
      candidate: candidate,
      seriesName: name,
      seriesStateKey: stateKey,
      fallbackImageUrl: imageUrl,
      fallbackWatchUrl: seriesUrl,
      releaseYear: releaseYear,
      episodeDetails: episodeDetails,
    );

    return SeriesItem(
      name: name,
      seriesStateKey: stateKey,
      sourceType: SourceType.remote,
      provider: RemoteProvider.latAnime,
      slug: slug,
      watchUrl: seriesUrl,
      episodeCount: episodes.length,
      imageUrl: imageUrl,
      backgroundUrl: candidate.backgroundUrl,
      logoUrl: candidate.logoUrl,
      trailerUrl: candidate.trailerUrl,
      description: candidate.description,
      rating: candidate.rating,
      episodes: episodes,
      releaseYear: releaseYear,
      format: candidate.format,
      catalogId: candidate.catalogId,
      japaneseTitle: candidate.japaneseTitle,
      aliases: candidate.aliases,
      cast: candidate.cast,
    );
  }

  Future<SeriesItem> _buildAnimeFlvSeries(
    RemoteSearchCandidate candidate, {
    required Iterable<String> existingNames,
  }) async {
    final slug = candidate.slug.isNotEmpty
        ? candidate.slug
        : _extractAnimeFlvSlug(candidate.seriesUrl.isNotEmpty
            ? candidate.seriesUrl
            : candidate.watchUrl);
    final seriesUrl = _normalizeAnimeFlvSeriesUrl(
      candidate.seriesUrl.isNotEmpty
          ? candidate.seriesUrl
          : slug.isEmpty
              ? ''
              : '$_animeFlvBaseUrl/anime/$slug',
    );
    if (slug.isEmpty || seriesUrl.isEmpty) {
      return candidate.toSeries(existingNames: existingNames);
    }

    final response = await _get(Uri.parse(seriesUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return candidate.toSeries(existingNames: existingNames);
    }
    final html = response.body;
    final episodeNumbers = _parseAnimeFlvEpisodeNumbers(html);
    if (episodeNumbers.isEmpty) {
      return candidate.toSeries(existingNames: existingNames);
    }

    final title = _cleanRemoteText(candidate.title).isNotEmpty
        ? _cleanRemoteText(candidate.title)
        : _extractAnimeFlvSeriesTitle(html);
    final name = uniqueSeriesName(
        title.isEmpty ? 'Serie AnimeFLV' : title, existingNames, 'AnimeFLV');
    final stateKey = normalizeSeriesKey(name);
    final imageUrl = _cleanRemoteUrl(candidate.imageUrl).isNotEmpty
        ? _cleanRemoteUrl(candidate.imageUrl)
        : _extractAnimeFlvSeriesImageUrl(html);
    final format = candidate.format.isNotEmpty
        ? candidate.format
        : _extractAnimeFlvSeriesFormat(html);
    final episodeDetails = _episodeMetadataByNumber(candidate.episodeDetails);
    final parsedEpisodes = episodeNumbers.asMap().entries.map((entry) {
      final index = entry.key;
      final episodeNumber = entry.value;
      final episode = EpisodeItem(
        seriesName: name,
        seriesStateKey: stateKey,
        episodeIndex: index,
        episodeNumber: episodeNumber,
        displayName: '$name - Capitulo $episodeNumber',
        relativePath: 'AnimeFLV / Capitulo $episodeNumber',
        filePath: _buildAnimeFlvEpisodeUrl(slug, episodeNumber),
        sourceType: SourceType.remote,
        provider: RemoteProvider.animeFlv,
        slug: slug,
        watchUrl: seriesUrl,
        releaseYear: candidate.releaseYear,
        imageUrl: imageUrl,
      );
      return _applyEpisodeMetadata(
        episode,
        episodeDetails[episodeNumber],
        fallbackImageUrl: imageUrl,
      );
    }).toList();
    final episodes = _completeImportedEpisodes(
      parsedEpisodes,
      candidate: candidate,
      seriesName: name,
      seriesStateKey: stateKey,
      fallbackImageUrl: imageUrl,
      fallbackWatchUrl: seriesUrl,
      releaseYear: candidate.releaseYear,
      episodeDetails: episodeDetails,
    );

    return SeriesItem(
      name: name,
      seriesStateKey: stateKey,
      sourceType: SourceType.remote,
      provider: RemoteProvider.animeFlv,
      slug: slug,
      watchUrl: seriesUrl,
      episodeCount: episodes.length,
      imageUrl: imageUrl,
      backgroundUrl: candidate.backgroundUrl,
      logoUrl: candidate.logoUrl,
      trailerUrl: candidate.trailerUrl,
      description: candidate.description,
      rating: candidate.rating,
      episodes: episodes,
      releaseYear: candidate.releaseYear,
      format: format,
      catalogId: candidate.catalogId,
      japaneseTitle: candidate.japaneseTitle,
      aliases: candidate.aliases,
      cast: candidate.cast,
    );
  }

  SeriesItem _buildBiliBiliSeries(
    RemoteSearchCandidate candidate, {
    required Iterable<String> existingNames,
  }) {
    final title = _cleanRemoteText(candidate.title).isNotEmpty
        ? _cleanRemoteText(candidate.title)
        : 'Serie BiliBili';
    final name = uniqueSeriesName(title, existingNames, 'BiliBili');
    final stateKey = normalizeSeriesKey(name);
    final seriesUrl = candidate.seriesUrl.isNotEmpty
        ? candidate.seriesUrl
        : candidate.watchUrl.isNotEmpty
            ? candidate.watchUrl
            : _bilibiliSearchUrl(title);
    final imageUrl = _cleanRemoteUrl(candidate.imageUrl);
    final details = [
      ...candidate.episodeDetails
    ]..sort((left, right) => left.episodeNumber.compareTo(right.episodeNumber));
    final episodes = <EpisodeItem>[];
    for (final detail in details) {
      if (detail.episodeNumber <= 0 || detail.description.trim().isEmpty) {
        continue;
      }
      final episode = EpisodeItem(
        seriesName: name,
        seriesStateKey: stateKey,
        episodeIndex: episodes.length,
        episodeNumber: detail.episodeNumber,
        displayName: '$name - Capitulo ${detail.episodeNumber}',
        relativePath: 'BiliBili / Capitulo ${detail.episodeNumber}',
        filePath: detail.description.trim(),
        sourceType: SourceType.remote,
        provider: RemoteProvider.bilibili,
        slug: candidate.slug,
        watchUrl: detail.description.trim(),
        releaseYear: candidate.releaseYear,
        imageUrl: detail.imageUrl.isNotEmpty ? detail.imageUrl : imageUrl,
        durationLabel: detail.durationLabel,
      );
      episodes.add(episode);
    }
    final fallbackEpisodeUrl = candidate.watchUrl.trim().isNotEmpty
        ? candidate.watchUrl.trim()
        : seriesUrl;
    final normalizedEpisodes = episodes.isNotEmpty
        ? episodes
        : [
            EpisodeItem(
              seriesName: name,
              seriesStateKey: stateKey,
              episodeIndex: 0,
              episodeNumber: 1,
              displayName: '$name - Capitulo 1',
              relativePath: 'BiliBili / Capitulo 1',
              filePath: fallbackEpisodeUrl,
              sourceType: SourceType.remote,
              provider: RemoteProvider.bilibili,
              slug: candidate.slug,
              watchUrl: fallbackEpisodeUrl,
              releaseYear: candidate.releaseYear,
              imageUrl: imageUrl,
            ),
          ];

    return SeriesItem(
      name: name,
      seriesStateKey: stateKey,
      sourceType: SourceType.remote,
      provider: RemoteProvider.bilibili,
      slug: candidate.slug,
      watchUrl: seriesUrl,
      episodeCount: normalizedEpisodes.length,
      imageUrl: imageUrl,
      backgroundUrl: candidate.backgroundUrl,
      logoUrl: candidate.logoUrl,
      trailerUrl: candidate.trailerUrl,
      description: candidate.description,
      rating: candidate.rating,
      episodes: normalizedEpisodes,
      releaseYear: candidate.releaseYear,
      format: candidate.format.isNotEmpty ? candidate.format : 'UGC',
      catalogId: candidate.catalogId,
      japaneseTitle: candidate.japaneseTitle,
      aliases: candidate.aliases,
      cast: candidate.cast,
    );
  }

  List<EpisodeItem> _completeImportedEpisodes(
    List<EpisodeItem> parsedEpisodes, {
    required RemoteSearchCandidate candidate,
    required String seriesName,
    required String seriesStateKey,
    required String fallbackImageUrl,
    required String fallbackWatchUrl,
    required int releaseYear,
    required Map<int, SeriesEpisodeMetadata> episodeDetails,
  }) {
    final targetCount = max(candidate.episodeCount, parsedEpisodes.length);
    if (targetCount <= parsedEpisodes.length) {
      return [
        for (var index = 0; index < parsedEpisodes.length; index += 1)
          parsedEpisodes[index].copyWith(episodeIndex: index),
      ];
    }
    final byNumber = <int, EpisodeItem>{
      for (final episode in parsedEpisodes)
        if (episode.episodeNumber > 0) episode.episodeNumber: episode,
    };
    final completed = <EpisodeItem>[];
    for (var episodeNumber = 1;
        episodeNumber <= targetCount;
        episodeNumber += 1) {
      final existing = byNumber[episodeNumber];
      if (existing != null) {
        completed.add(existing.copyWith(episodeIndex: completed.length));
        continue;
      }
      final detail = episodeDetails[episodeNumber];
      final episode = EpisodeItem(
        seriesName: seriesName,
        seriesStateKey: seriesStateKey,
        episodeIndex: completed.length,
        episodeNumber: episodeNumber,
        displayName: '$seriesName - Capitulo $episodeNumber',
        relativePath: 'Catalogo / Capitulo $episodeNumber',
        filePath: fallbackWatchUrl,
        sourceType: SourceType.remote,
        provider: RemoteProvider.catalog,
        slug:
            candidate.catalogId > 0 ? '${candidate.catalogId}' : candidate.slug,
        watchUrl: fallbackWatchUrl,
        releaseYear: releaseYear,
        imageUrl: fallbackImageUrl,
      );
      completed.add(_applyEpisodeMetadata(
        episode,
        detail,
        fallbackImageUrl: fallbackImageUrl,
      ));
    }
    return completed;
  }

  Future<RemoteDirectStream?> resolveDirectStream(
    EpisodeItem entry, {
    String preferredMode = _animeAv1ModeSubHls,
    String preferredFacebookMode = '',
    String preferredServer = '',
    Set<String> excludedServers = const {},
  }) async {
    _debugResolver(
      'resolve start provider=${entry.provider?.id ?? 'none'} '
      'episode="${entry.displayName}" preferredMode=$preferredMode '
      'preferredFacebookMode=$preferredFacebookMode '
      'preferredServer=$preferredServer excludedServers=${excludedServers.join(',')} '
      'file=${_debugUrlLabel(entry.filePath)} watch=${_debugUrlLabel(entry.watchUrl)}',
    );
    if (entry.provider == RemoteProvider.animeKai) {
      _debugResolver('resolve skipped animekai provider');
      return null;
    }
    if (entry.provider == RemoteProvider.bilibili) {
      final resolved = await _resolveBiliBiliDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      _debugResolver('bilibili resolved ${_debugStreamLabel(resolved)}');
      return resolved;
    }
    if (entry.provider == RemoteProvider.youtube) {
      final resolved = await _resolveYoutubeDirectStream(
        entry,
        preferredMode: preferredMode,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      _debugResolver('youtube resolved ${_debugStreamLabel(resolved)}');
      return resolved;
    }
    if (entry.provider == RemoteProvider.internetArchive) {
      final resolved = await _resolveInternetArchiveDirectStream(entry);
      _debugResolver(
        'internetarchive resolved ${_debugStreamLabel(resolved)}',
      );
      return resolved;
    }
    if (entry.provider == RemoteProvider.justAnime) {
      final resolved = await _resolveJustAnimeDirectStream(
        entry,
        preferredMode: preferredMode,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      _debugResolver('justanime resolved ${_debugStreamLabel(resolved)}');
      return resolved;
    }
    if (entry.provider == RemoteProvider.aniPm) {
      final resolved = await _resolveAniPmDirectStream(
        entry,
        preferredMode: preferredMode,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      _debugResolver('anipm resolved ${_debugStreamLabel(resolved)}');
      return resolved;
    }
    if (entry.provider != RemoteProvider.animeAv1) {
      final resolved = await _resolveGenericDirectStream(
        entry,
        preferredFacebookMode: preferredFacebookMode,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      if (resolved != null) {
        _debugResolver('generic resolved ${_debugStreamLabel(resolved)}');
        return resolved;
      }
      final webResolved = await _resolvePlatformWebDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      _debugResolver('generic web fallback ${_debugStreamLabel(webResolved)}');
      return webResolved;
    }
    final seriesUrl = _normalizeAnimeAv1SeriesUrl(
        entry.watchUrl.isNotEmpty ? entry.watchUrl : entry.filePath);
    if (seriesUrl.isEmpty) {
      _debugResolver('animeav1 empty series url, using platform web');
      final webResolved = await _resolvePlatformWebDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      _debugResolver(
          'animeav1 empty series web ${_debugStreamLabel(webResolved)}');
      return webResolved;
    }
    final episodeUrl = _buildAnimeAv1EpisodeUrl(seriesUrl, entry.episodeNumber);
    if (episodeUrl.isEmpty) {
      _debugResolver('animeav1 empty episode url, using platform web');
      final webResolved = await _resolvePlatformWebDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      _debugResolver(
        'animeav1 empty episode web ${_debugStreamLabel(webResolved)}',
      );
      return webResolved;
    }
    _debugResolver('animeav1 fetch ${_debugUrlLabel(episodeUrl)}');
    final response = await _get(Uri.parse(episodeUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _debugResolver(
        'animeav1 episode fetch failed status=${response.statusCode} '
        'url=${_debugUrlLabel(episodeUrl)} '
        'body=${_debugBodySnippet(response.body)}',
      );
      final webResolved = await _resolvePlatformWebDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      _debugResolver('animeav1 fetch web ${_debugStreamLabel(webResolved)}');
      return webResolved;
    }

    final playbackByMode = <String, String>{};
    final playPageByMode = <String, String>{};
    final subPlayUrl = _extractAnimeAv1PlayUrl(response.body, 'SUB');
    final subHls = _buildAnimeAv1HlsUrl(subPlayUrl);
    if (subHls.isNotEmpty) {
      playbackByMode[_animeAv1ModeSubHls] = subHls;
      playPageByMode[_animeAv1ModeSubHls] = subPlayUrl;
      _debugResolver(
        'animeav1 SUB play=${_debugUrlLabel(subPlayUrl)} '
        'hls=${_debugUrlLabel(subHls)}',
      );
    }
    final dubPlayUrl = _extractAnimeAv1PlayUrl(response.body, 'DUB');
    final dubHls = _buildAnimeAv1HlsUrl(dubPlayUrl);
    if (dubHls.isNotEmpty) {
      playbackByMode[_animeAv1ModeDubHls] = dubHls;
      playPageByMode[_animeAv1ModeDubHls] = dubPlayUrl;
      _debugResolver(
        'animeav1 DUB play=${_debugUrlLabel(dubPlayUrl)} '
        'hls=${_debugUrlLabel(dubHls)}',
      );
    }
    if (playbackByMode.isEmpty) {
      _debugResolver(
        'animeav1 no playback modes url=${_debugUrlLabel(episodeUrl)} '
        'body=${_debugBodySnippet(response.body)}',
      );
      for (final playUrl
          in _extractAnimeAv1PlayUrls(response.body, episodeUrl)) {
        final hlsUrl = _buildAnimeAv1HlsUrl(playUrl);
        if (hlsUrl.isEmpty) {
          continue;
        }
        playbackByMode['iframe-hls'] = hlsUrl;
        playPageByMode['iframe-hls'] = playUrl;
        _debugResolver(
          'animeav1 iframe fallback play=${_debugUrlLabel(playUrl)} '
          'hls=${_debugUrlLabel(hlsUrl)}',
        );
        break;
      }
    }
    if (playbackByMode.isEmpty) {
      final webResolved = await _resolvePlatformWebDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      _debugResolver('animeav1 no modes web ${_debugStreamLabel(webResolved)}');
      return webResolved;
    }
    final selectedMode = playbackByMode.containsKey(preferredMode)
        ? preferredMode
        : playbackByMode.containsKey(_animeAv1ModeSubHls)
            ? _animeAv1ModeSubHls
            : playbackByMode.keys.first;
    final playbackUrl = playbackByMode[selectedMode] ?? '';
    if (playbackUrl.isEmpty) {
      _debugResolver('animeav1 selected mode $selectedMode has empty url');
      return null;
    }
    final resolved = RemoteDirectStream(
      playbackUrl: playbackUrl,
      playbackKind: 'hls',
      pageUrl: playPageByMode[selectedMode] ?? episodeUrl,
      availableModes: playbackByMode.keys.toSet(),
      selectedMode: selectedMode,
    );
    _debugResolver('animeav1 resolved ${_debugStreamLabel(resolved)}');
    return resolved;
  }

  Future<RemoteDirectStream?> _resolvePlatformWebDirectStream(
    EpisodeItem entry, {
    String preferredServer = '',
    Set<String> excludedServers = const {},
  }) async {
    final provider = entry.provider;
    if (!_shouldUsePlatformWebResolver(provider)) {
      _debugResolver(
        'platform web skipped provider=${provider?.id ?? 'none'} available=${_webResolver.isAvailable}',
      );
      return null;
    }
    final pageUrl = _buildRemoteEpisodePageUrl(entry);
    if (pageUrl.isEmpty) {
      _debugResolver('platform web skipped empty page url');
      return null;
    }
    _debugResolver(
      'platform web start provider=${provider?.id ?? 'none'} '
      'page=${_debugUrlLabel(pageUrl)} preferredServer=$preferredServer '
      'excludedServers=${excludedServers.join(',')}',
    );
    final resolved = await _webResolver.resolveDirectStream(
      entry: entry,
      pageUrl: pageUrl,
      referer: entry.watchUrl,
      preferredServer: preferredServer,
      excludedServers: excludedServers,
    );
    if (resolved == null) {
      _debugResolver('platform web returned null');
      return null;
    }
    final server = resolved.server.trim().isNotEmpty
        ? resolved.server
        : _normalizeServerPreference(
            resolved.pageUrl.trim().isNotEmpty
                ? resolved.pageUrl
                : resolved.playbackUrl,
          );
    final tagged = resolved.copyWith(provider: provider, server: server);
    _debugResolver('platform web resolved ${_debugStreamLabel(tagged)}');
    return tagged;
  }

  Future<RemoteDirectStream?> _resolveJustAnimeDirectStream(
    EpisodeItem entry, {
    required String preferredMode,
    required String preferredServer,
    required Set<String> excludedServers,
  }) async {
    final animeId = int.tryParse(entry.slug.trim()) ?? 0;
    if (animeId <= 0) return null;
    final episode = entry.episodeNumber < 1 ? 1 : entry.episodeNumber;
    final language = justAnimePlaybackModeFromId(preferredMode).id;
    final requestedServer = justAnimeServerPreferenceFromId(preferredServer);
    final servers = <JustAnimeServerPreference>[
      requestedServer,
      ...JustAnimeServerPreference.values
          .where((item) => item != requestedServer),
    ];
    final subtitles = await _fetchJustAnimeMomoSubtitles(
      animeId,
      episode,
      language,
    );
    for (final server in servers) {
      if (excludedServers.contains(server.id)) continue;
      if (server == JustAnimeServerPreference.neko && language == 'dub') {
        continue;
      }
      final endpoint = server == JustAnimeServerPreference.neko
          ? 'anineko/$language/hd1'
          : 'animegg';
      final response = await _getJustAnimeApi(
        '/watch/$animeId/episode/$episode/$endpoint',
      );
      if (response == null) continue;
      final selected = server == JustAnimeServerPreference.gigi
          ? (response[language] is Map
              ? Map<String, dynamic>.from(response[language] as Map)
              : null)
          : response;
      if (selected == null || selected['sources'] is! List) continue;
      final sources = (selected['sources'] as List).whereType<Map>().toList();
      if (sources.isEmpty) continue;
      final source = Map<String, dynamic>.from(sources.first);
      final rawUrl = _readString(source['url']);
      if (rawUrl.isEmpty) continue;
      final isHls = source['isM3U8'] == true || rawUrl.contains('.m3u8');
      var playbackUrl = rawUrl;
      if (server == JustAnimeServerPreference.neko) {
        final upstream = Uri.parse('https://neko.justanime.to/m3u8-proxy')
            .replace(queryParameters: {'url': rawUrl}).toString();
        final proxy = await _JustAnimeHlsProxy.start(
          client: _client,
          upstreamUrl: upstream,
          userAgent: _defaultFetchUserAgent,
        );
        _justAnimeHlsProxies.add(proxy);
        playbackUrl = proxy.playlistUrl;
      }
      final ownTracks = _parseJustAnimeSubtitleTracks(
        selected['subtitles'] ?? selected['tracks'],
        proxy: server == JustAnimeServerPreference.neko,
      );
      return RemoteDirectStream(
        playbackUrl: playbackUrl,
        playbackKind: isHls ? 'hls' : 'http',
        pageUrl:
            '$_justAnimeBaseUrl/watch/$animeId/${entry.slug}/episode/$episode',
        availableModes: JustAnimeServerPreference.values
            .where((item) =>
                language != 'dub' || item != JustAnimeServerPreference.neko)
            .map((item) => item.id)
            .toSet(),
        selectedMode: language,
        provider: RemoteProvider.justAnime,
        server: server.id,
        subtitleTracks: _mergeJustAnimeSubtitleTracks(subtitles, ownTracks),
        httpHeaders: server == JustAnimeServerPreference.neko
            ? const {'User-Agent': _defaultFetchUserAgent}
            : const {
                'Referer': 'https://www.animegg.org/',
                'User-Agent': _defaultFetchUserAgent,
              },
      );
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getJustAnimeApi(String path) async {
    try {
      final response = await _getRemoteProviderWithRetry(
        Uri.parse('$_justAnimeApiBaseUrl$path'),
        referer: _justAnimeBaseUrl,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<RemoteDirectStream?> _resolveAniPmDirectStream(
    EpisodeItem entry, {
    required String preferredMode,
    required String preferredServer,
    required Set<String> excludedServers,
  }) async {
    final slugParts = entry.slug.trim().split(':');
    final route =
        slugParts.length > 1 && slugParts.first == 'anime' ? 'series' : 'ani';
    final id = int.tryParse(slugParts.last) ?? 0;
    if (id <= 0) return null;
    final detail = await _getAniPmJson('/api/anime/$route/$id');
    if (detail == null) return null;
    final title = _readString(detail['title']);
    if (title.isEmpty) return null;
    final episode = entry.episodeNumber < 1 ? 1 : entry.episodeNumber;
    final query = <String, String>{
      'title': title,
      'ep': '$episode',
      if (_readInt(detail['year']) > 0) 'year': '${_readInt(detail['year'])}',
      if (_readString(detail['anilistId']).isNotEmpty)
        'anilistId': _readString(detail['anilistId']),
      if (_readString(detail['malId']).isNotEmpty)
        'malId': _readString(detail['malId']),
    };
    final servers = await _getAniPmJson(
      Uri.parse('$_aniPmBaseUrl/api/anime/src/servers')
          .replace(queryParameters: query)
          .toString(),
      absolute: true,
    );
    if (servers == null) return null;
    final mode = aniPmPlaybackModeFromId(preferredMode).id;
    final rawServers = servers[mode];
    if (rawServers is! List || rawServers.isEmpty) return null;
    final candidates = rawServers
        .whereType<Map>()
        .map((raw) {
          final item = Map<String, dynamic>.from(raw);
          return (item: item, key: _aniPmServerKey(item));
        })
        .where((candidate) =>
            candidate.key.isNotEmpty &&
            !excludedServers.contains(candidate.key) &&
            !excludedServers.contains(_aniPmServerFamily(candidate.key)))
        .toList();
    if (candidates.isEmpty) return null;
    final preferred = preferredServer.trim().toLowerCase();
    candidates.sort((left, right) {
      int score(({Map<String, dynamic> item, String key}) candidate) {
        final family = _aniPmServerFamily(candidate.key);
        final preferredScore = candidate.key == preferred
            ? 100000
            : family == preferred
                ? 50000
                : 0;
        return preferredScore + _readInt(candidate.item['priority']);
      }

      return score(right).compareTo(score(left));
    });
    final availableServers = candidates.map((item) => item.key).toSet();
    for (final candidate in candidates) {
      final item = candidate.item;
      var playbackUrl = _aniPmAbsoluteUrl(_readString(item['url']));
      var kind = _readString(item['kind']).toLowerCase();
      var tracks = _parseAniPmSubtitleTracks(item['tracks']);
      var pageUrl = playbackUrl;
      if (playbackUrl.isEmpty) continue;
      if (kind == 'embed') {
        final embedded = await _getAniPmJson(
          Uri.parse('$_aniPmBaseUrl/api/anime/src/embed-direct').replace(
            queryParameters: {'u': playbackUrl},
          ).toString(),
          absolute: true,
        );
        if (embedded == null) continue;
        final rawResolved = [
          embedded['m3u8'],
          embedded['file'],
          embedded['url'],
        ]
            .map(_readString)
            .firstWhere((value) => value.isNotEmpty, orElse: () => '');
        if (rawResolved.isEmpty) continue;
        playbackUrl = _aniPmAbsoluteUrl(rawResolved);
        kind = rawResolved.contains('.m3u8') || embedded['direct'] == false
            ? 'hls'
            : 'http';
        tracks = [
          ...tracks,
          ..._parseAniPmSubtitleTracks(
              embedded['tracks'] ?? embedded['subtitles']),
        ];
        if (_aniPmServerFamily(candidate.key) == 'pulse') {
          tracks = [
            ...tracks,
            ...await _fetchAniPmEmbedSubtitleTracks(pageUrl)
          ];
        }
      }
      return RemoteDirectStream(
        playbackUrl: playbackUrl,
        playbackKind: kind == 'hls' ? 'hls' : 'http',
        pageUrl: pageUrl,
        availableModes: availableServers,
        selectedMode: mode,
        provider: RemoteProvider.aniPm,
        server: candidate.key,
        subtitleTracks: _dedupeAniPmSubtitleTracks(tracks),
        httpHeaders: const {
          'Referer': 'https://ani.pm/',
          'Origin': 'https://ani.pm',
          'User-Agent': _defaultFetchUserAgent,
        },
      );
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getAniPmJson(String path,
      {bool absolute = false}) async {
    try {
      final uri = Uri.parse(absolute ? path : '$_aniPmBaseUrl$path');
      final response =
          await _getRemoteProviderWithRetry(uri, referer: _aniPmBaseUrl);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<http.Response> _getRemoteProviderWithRetry(
    Uri uri, {
    required String referer,
  }) async {
    late http.Response response;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      response = await _get(
        uri,
        referer: referer,
        headers: const {'Accept': 'application/json'},
      );
      if (response.statusCode != 429 && response.statusCode < 500) {
        return response;
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    return response;
  }

  String _aniPmAbsoluteUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('/')) return '$_aniPmBaseUrl$trimmed';
    return trimmed;
  }

  String _aniPmServerKey(Map<String, dynamic> item) {
    final provider = _readString(item['provider']).toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9]+'),
          '-',
        );
    final name = _readString(item['name']).toLowerCase();
    final numberMatches = RegExp(r'(\d+)').allMatches(name).toList();
    final number =
        numberMatches.isEmpty ? '' : numberMatches.last.group(1) ?? '';
    return [provider, if (number.isNotEmpty) number]
        .where((part) => part.isNotEmpty)
        .join('-');
  }

  String _aniPmServerFamily(String key) => key.split('-').first;

  List<RemoteSubtitleTrack> _parseAniPmSubtitleTracks(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((raw) {
          final item = Map<String, dynamic>.from(raw);
          final url = _aniPmAbsoluteUrl(_readString(item['url']).isNotEmpty
              ? _readString(item['url'])
              : _readString(item['file']));
          final label = _readString(item['label']).isNotEmpty
              ? _readString(item['label'])
              : _readString(item['language']);
          return RemoteSubtitleTrack(
            url: url,
            label: label.isEmpty ? 'Subtitulo' : label,
            language: _readString(item['language']),
            mimeType:
                url.toLowerCase().contains('.ass') ? 'text/x-ssa' : 'text/vtt',
            isDefault: item['default'] == true,
          );
        })
        .where((track) => track.url.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<RemoteSubtitleTrack>> _fetchAniPmEmbedSubtitleTracks(
      String url) async {
    try {
      final response = await _get(Uri.parse(url), referer: _aniPmBaseUrl);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }
      final matches = RegExp(
        r'''\{url:["']([^"']+\.(?:ass|vtt|srt))[^}]*language:["']([^"']*)["'][^}]*\}''',
        caseSensitive: false,
      ).allMatches(response.body);
      return matches.map((match) {
        final trackUrl = match.group(1) ?? '';
        return RemoteSubtitleTrack(
          url: trackUrl,
          label: match.group(2) ?? 'Subtitulo',
          language: match.group(2) ?? '',
          mimeType: trackUrl.toLowerCase().endsWith('.ass')
              ? 'text/x-ssa'
              : 'text/vtt',
          isDefault: response.body
              .substring(match.start, match.end)
              .contains('default:true'),
        );
      }).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  List<RemoteSubtitleTrack> _dedupeAniPmSubtitleTracks(
      List<RemoteSubtitleTrack> tracks) {
    final result = <String, RemoteSubtitleTrack>{};
    for (final track in tracks) {
      result[track.url] = track;
    }
    return result.values.toList(growable: false);
  }

  Future<List<RemoteSubtitleTrack>> _fetchJustAnimeMomoSubtitles(
    int animeId,
    int episode,
    String language,
  ) async {
    final response = await _getJustAnimeApi(
      '/watch/$animeId/episode/$episode/megaplay',
    );
    final stream = response?[language];
    if (stream is! Map) return const [];
    return _parseJustAnimeSubtitleTracks(stream['subtitles'], proxy: true);
  }

  List<RemoteSubtitleTrack> _parseJustAnimeSubtitleTracks(
    Object? value, {
    required bool proxy,
  }) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((raw) {
          final track = Map<String, dynamic>.from(raw);
          final direct = _readString(track['file']).isNotEmpty
              ? _readString(track['file'])
              : _readString(track['url']);
          final label = _readString(track['label']).isNotEmpty
              ? _readString(track['label'])
              : _readString(track['lang']);
          return RemoteSubtitleTrack(
            url: proxy && direct.isNotEmpty
                ? Uri.parse('https://momo.calm-koi.workers.dev/proxy').replace(
                    queryParameters: {'url': direct},
                  ).toString()
                : direct,
            label: label,
            language: label,
            mimeType: 'text/vtt',
            isDefault: track['default'] == true,
          );
        })
        .where((track) => track.url.isNotEmpty)
        .toList(growable: false);
  }

  List<RemoteSubtitleTrack> _mergeJustAnimeSubtitleTracks(
    List<RemoteSubtitleTrack> preferred,
    List<RemoteSubtitleTrack> fallback,
  ) {
    final result = <RemoteSubtitleTrack>[];
    final seen = <String>{};
    for (final track in [...preferred, ...fallback]) {
      final key = '${track.label.toLowerCase()}|${track.url}';
      if (seen.add(key)) result.add(track);
    }
    return result;
  }

  Future<RemoteDirectStream?> _resolveBiliBiliDirectStream(
    EpisodeItem entry, {
    String preferredServer = '',
    Set<String> excludedServers = const {},
  }) async {
    final options = _bilibiliPlaybackOptionsFor(entry);
    if (options.isEmpty) {
      _debugResolver('bilibili skipped empty playback options');
      return null;
    }
    final selectedOption = _selectBiliBiliPlaybackOption(
      options,
      preferredServer: preferredServer,
      excludedServers: excludedServers,
    );
    if (selectedOption == null) {
      _debugResolver(
        'bilibili skipped all options excluded=${excludedServers.join(',')}',
      );
      return null;
    }
    final pageUrl = selectedOption.url;
    if (pageUrl.isEmpty) {
      _debugResolver('bilibili skipped empty page url');
      return null;
    }

    final response = await _get(
      Uri.parse(pageUrl),
      referer: _bilibiliBaseUrl,
      headers: const {
        'Accept-Language': 'en-US,en;q=0.9,es;q=0.8',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException(
        'BiliBili respondio ${response.statusCode}',
      );
    }
    final html = _decodeJavaScriptEscapes(response.body);
    final mediaUrls = _extractBiliBiliMediaUrls(html);
    final videoUrl = _selectBiliBiliVideoUrl(mediaUrls);
    final audioUrl = _selectBiliBiliAudioUrl(mediaUrls);
    if (videoUrl.isEmpty || audioUrl.isEmpty) {
      _debugResolver(
        'bilibili missing dash media video=${videoUrl.isNotEmpty} '
        'audio=${audioUrl.isNotEmpty}',
      );
      return null;
    }

    final durationSeconds = _extractBiliBiliDurationSeconds(html);
    final proxy = await _BiliBiliDashProxy.start(
      client: _client,
      pageUrl: pageUrl,
      videoUrl: videoUrl,
      audioUrl: audioUrl,
      durationSeconds: durationSeconds,
      userAgent: _defaultFetchUserAgent,
    );
    _bilibiliDashProxies.add(proxy);
    return RemoteDirectStream(
      playbackUrl: proxy.manifestUrl,
      playbackKind: 'dash',
      pageUrl: pageUrl,
      availableModes: options.map((option) => option.server).toSet(),
      selectedMode: selectedOption.server,
      provider: RemoteProvider.bilibili,
      server: selectedOption.server,
      httpHeaders: {
        'User-Agent': _defaultFetchUserAgent,
        'Referer': pageUrl,
        'Origin': _bilibiliBaseUrl,
        if (durationSeconds > 0)
          'X-Tanuki-Duration-Seconds': '$durationSeconds',
        'X-Tanuki-Vlc-Hls-Url': proxy.vlcHlsUrl,
        'X-Tanuki-Vlc-Video-Url': proxy.vlcVideoUrl,
        'X-Tanuki-Vlc-Audio-Url': proxy.vlcAudioUrl,
        'X-Tanuki-Vlc-Playlist-Url': proxy.vlcPlaylistUrl,
        'X-Tanuki-Vlc-Playlist-Path': proxy.vlcPlaylistPath,
      },
    );
  }

  List<String> _extractBiliBiliMediaUrls(String html) {
    final urls = <String>[];
    final seen = <String>{};
    final pattern = RegExp(
      r'https?://[^"\\\s<>]+?\.m4s[^"\\\s<>]*',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(html)) {
      final url = _decodeHtml(match.group(0) ?? '').trim();
      if (url.isEmpty || !seen.add(url)) {
        continue;
      }
      urls.add(url);
    }
    return urls;
  }

  String _selectBiliBiliAudioUrl(List<String> urls) {
    return urls.firstWhere(
      (url) => RegExp(r'-1a\d+', caseSensitive: false).hasMatch(url),
      orElse: () => urls.firstWhere(
        (url) => url.toLowerCase().contains('audio'),
        orElse: () => '',
      ),
    );
  }

  String _selectBiliBiliVideoUrl(List<String> urls) {
    final videoUrls = urls
        .where((url) =>
            !RegExp(r'-1a\d+', caseSensitive: false).hasMatch(url) &&
            !url.toLowerCase().contains('audio'))
        .toList();
    for (final preferred in const ['-111210', '-1e121', '-1f121']) {
      final match = videoUrls.firstWhere(
        (url) => url.toLowerCase().contains(preferred),
        orElse: () => '',
      );
      if (match.isNotEmpty) {
        return match;
      }
    }
    for (final fallback in videoUrls) {
      if (!RegExp(r'-1[ef]122|-111220', caseSensitive: false)
          .hasMatch(fallback)) {
        return fallback;
      }
    }
    return videoUrls.isNotEmpty ? videoUrls.first : '';
  }

  int _extractBiliBiliDurationSeconds(String html) {
    final duration = int.tryParse(
      RegExp(r'\bduration\s*:\s*(\d{2,5})', caseSensitive: false)
              .firstMatch(html)
              ?.group(1) ??
          '',
    );
    if (duration != null && duration > 0) {
      return duration;
    }
    final label = RegExp(r'"duration"\s*:\s*(\d{2,5})', caseSensitive: false)
        .firstMatch(html)
        ?.group(1);
    return int.tryParse(label ?? '') ?? 0;
  }

  String _decodeJavaScriptEscapes(String value) {
    return value
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u002F', '/')
        .replaceAll(r'\u002f', '/')
        .replaceAll(r'\u003A', ':')
        .replaceAll(r'\u003a', ':')
        .replaceAll(r'\u003D', '=')
        .replaceAll(r'\u003d', '=')
        .replaceAll(r'\u0026', '&')
        .replaceAll(r'\u0026amp;', '&')
        .replaceAll(r'\u003F', '?')
        .replaceAll(r'\u003f', '?');
  }

  List<_BiliBiliPlaybackOption> _bilibiliPlaybackOptionsFor(
    EpisodeItem entry,
  ) {
    final decoded = _decodeBiliBiliEpisodeOptions(entry.description);
    if (decoded.isNotEmpty) {
      return decoded;
    }
    final pageUrl = _buildRemoteEpisodePageUrl(entry);
    if (pageUrl.isEmpty) {
      return const [];
    }
    return [
      _BiliBiliPlaybackOption(
        server: 'bilibili-1',
        url: pageUrl,
        title: entry.displayName,
        imageUrl: entry.imageUrl,
        durationLabel: entry.durationLabel,
      ),
    ];
  }

  _BiliBiliPlaybackOption? _selectBiliBiliPlaybackOption(
    List<_BiliBiliPlaybackOption> options, {
    required String preferredServer,
    required Set<String> excludedServers,
  }) {
    final excluded =
        excludedServers.map((entry) => entry.toLowerCase()).toSet();
    final preferred = preferredServer.trim().toLowerCase();
    if (preferred.isNotEmpty && !excluded.contains(preferred)) {
      for (final option in options) {
        if (option.server.toLowerCase() == preferred) {
          return option;
        }
      }
    }
    for (final option in options) {
      if (!excluded.contains(option.server.toLowerCase())) {
        return option;
      }
    }
    return null;
  }

  String _encodeBiliBiliEpisodeOptions(List<_BiliBiliVideoResult> options) {
    final payload = [
      for (final entry in options.indexed)
        {
          'server': 'bilibili-${entry.$1 + 1}',
          'url': entry.$2.url,
          'title': entry.$2.title,
          'imageUrl': entry.$2.imageUrl,
          'durationLabel': entry.$2.durationLabel,
        },
    ];
    return '$_bilibiliEpisodeOptionsPrefix${jsonEncode(payload)}';
  }

  List<_BiliBiliPlaybackOption> _decodeBiliBiliEpisodeOptions(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith(_bilibiliEpisodeOptionsPrefix)) {
      return const [];
    }
    try {
      final raw = trimmed.substring(_bilibiliEpisodeOptionsPrefix.length);
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      final options = <_BiliBiliPlaybackOption>[];
      for (final entry in decoded.whereType<Map>()) {
        final url = _readString(entry['url']);
        final server = _readString(entry['server']);
        if (url.isEmpty || server.isEmpty) {
          continue;
        }
        options.add(
          _BiliBiliPlaybackOption(
            server: server,
            url: url,
            title: _readString(entry['title']),
            imageUrl: _readString(entry['imageUrl']),
            durationLabel: _readString(entry['durationLabel']),
          ),
        );
      }
      return options;
    } catch (_) {
      return const [];
    }
  }

  Future<List<_YoutubePlaybackOption>> _searchYoutubeEpisodeOptions(
    String query, {
    required YoutubePlaybackMode mode,
    required int episodeNumber,
    int limit = 2,
  }) async {
    final normalized = _cleanBiliBiliSearchQuery(query);
    if (normalized.isEmpty) {
      return const [];
    }
    final ytDlpOptions = await _searchYoutubeEpisodeOptionsWithYtDlp(
      normalized,
      mode: mode,
      episodeNumber: episodeNumber,
      limit: limit,
    );
    if (ytDlpOptions.isNotEmpty) {
      return ytDlpOptions;
    }
    final ytClient = yt.YoutubeExplode();
    try {
      final results = await ytClient.search.search(normalized);
      final exactMatches = <_YoutubePlaybackOption>[];
      final fallbackMatches = <_YoutubePlaybackOption>[];
      for (final video in results) {
        if (video.isLive) {
          continue;
        }
        if (!_isLikelyFullYoutubeEpisode(
          title: video.title,
          durationSeconds: video.duration?.inSeconds,
        )) {
          continue;
        }
        final option = _YoutubePlaybackOption(
          server: '',
          mode: mode,
          option: YoutubePlaybackOption.first,
          videoId: video.id.value,
          url: video.url,
          title: _cleanRemoteText(video.title),
          imageUrl: video.thumbnails.highResUrl,
          durationLabel: _formatYoutubeDuration(video.duration),
        );
        if (_youtubeTitleMatchesEpisodeNumber(video.title, episodeNumber)) {
          exactMatches.add(option);
        } else {
          fallbackMatches.add(option);
        }
        if (exactMatches.length >= limit.clamp(1, 8).toInt()) {
          break;
        }
      }
      return _renumberYoutubeOptions(
        exactMatches.isNotEmpty ? exactMatches : fallbackMatches,
        mode: mode,
        limit: limit,
      );
    } finally {
      ytClient.close();
    }
  }

  Future<List<_YoutubePlaybackOption>> _searchYoutubeEpisodeOptionsWithYtDlp(
    String query, {
    required YoutubePlaybackMode mode,
    required int episodeNumber,
    int limit = 2,
  }) async {
    final searchLimit = max(limit.clamp(1, 8).toInt() * 4, 8);
    _debugResolver(
      'youtube yt-dlp search query="$query" mode=${mode.id} '
      'episode=$episodeNumber limit=$limit searchLimit=$searchLimit',
    );
    final result = await _runYtDlp([
      '--dump-single-json',
      '--flat-playlist',
      '--no-warnings',
      'ytsearch$searchLimit:$query',
    ]);
    if (result == null || result.exitCode != 0) {
      return const [];
    }
    try {
      final decoded = jsonDecode(result.stdout);
      final entries = decoded is Map ? decoded['entries'] : null;
      if (entries is! List) {
        return const [];
      }
      final exactMatches = <_YoutubePlaybackOption>[];
      final fallbackMatches = <_YoutubePlaybackOption>[];
      for (final entry in entries.whereType<Map>()) {
        final videoId = _readString(entry['id']);
        if (!_isYoutubeVideoId(videoId)) {
          _debugResolver('youtube search reject invalid id="$videoId"');
          continue;
        }
        final title = _cleanRemoteText(_readString(entry['title']));
        final durationSeconds = _readInt(entry['duration']);
        if (!_isLikelyFullYoutubeEpisode(
          title: title,
          durationSeconds: durationSeconds,
        )) {
          _debugResolver(
            'youtube search reject id=$videoId duration='
            '${durationSeconds <= 0 ? 'unknown' : durationSeconds}s '
            'title="$title"',
          );
          continue;
        }
        final option = _YoutubePlaybackOption(
          server: '',
          mode: mode,
          option: YoutubePlaybackOption.first,
          videoId: videoId,
          url: _youtubeWatchUrl(videoId),
          title: title,
          imageUrl: _youtubeThumbnailUrl(videoId),
          durationLabel: _formatSecondsDuration(durationSeconds),
        );
        _debugResolver(
          'youtube search candidate id=$videoId '
          'duration=${durationSeconds <= 0 ? 'unknown' : durationSeconds}s '
          'exact=${_youtubeTitleMatchesEpisodeNumber(title, episodeNumber)} '
          'url=${option.url} title="$title"',
        );
        if (_youtubeTitleMatchesEpisodeNumber(title, episodeNumber)) {
          exactMatches.add(option);
        } else {
          fallbackMatches.add(option);
        }
        if (exactMatches.length >= limit.clamp(1, 8).toInt()) {
          break;
        }
      }
      return _renumberYoutubeOptions(
        exactMatches.isNotEmpty ? exactMatches : fallbackMatches,
        mode: mode,
        limit: limit,
      );
    } catch (error) {
      _debugResolver('youtube yt-dlp search parse failed: $error');
      return const [];
    }
  }

  List<_YoutubePlaybackOption> _renumberYoutubeOptions(
    List<_YoutubePlaybackOption> options, {
    required YoutubePlaybackMode mode,
    required int limit,
  }) {
    final normalizedLimit = limit.clamp(1, 8).toInt();
    final normalized = <_YoutubePlaybackOption>[];
    for (final option in options) {
      if (normalized.length >= normalizedLimit) {
        break;
      }
      final optionIndex = normalized.length + 1;
      normalized.add(
        option.copyWith(
          server: 'youtube-${mode.id}-$optionIndex',
          option: optionIndex == 1
              ? YoutubePlaybackOption.first
              : YoutubePlaybackOption.second,
        ),
      );
    }
    return normalized;
  }

  bool _isLikelyFullYoutubeEpisode({
    required String title,
    required int? durationSeconds,
  }) {
    final normalizedTitle = title.toLowerCase();
    if (normalizedTitle.contains('opening') ||
        normalizedTitle.contains('ending') ||
        normalizedTitle.contains('op ') ||
        normalizedTitle.contains(' ed ') ||
        normalizedTitle.contains('tema de apertura')) {
      return false;
    }
    if (durationSeconds == null || durationSeconds <= 0) {
      return true;
    }
    return durationSeconds >= 10 * 60;
  }

  bool _youtubeTitleMatchesEpisodeNumber(String title, int episodeNumber) {
    if (episodeNumber <= 0) {
      return true;
    }
    final normalized = title
        .toLowerCase()
        .replaceAll(RegExp(r'[\[\]\(\)\|:_\-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final escaped = RegExp.escape('$episodeNumber');
    final patterns = [
      RegExp(r'(^|\s)(ep|eps|episodio|episode|chapter|capitulo|cap)\.?\s*' +
          escaped +
          r'(\s|$)'),
      RegExp(r'(^|\s)' + escaped + r'(\s|$)'),
    ];
    return patterns.any((pattern) => pattern.hasMatch(normalized));
  }

  Future<RemoteDirectStream?> _resolveYoutubeDirectStream(
    EpisodeItem entry, {
    String preferredMode = '',
    String preferredServer = '',
    Set<String> excludedServers = const {},
  }) async {
    final options = _youtubePlaybackOptionsFor(entry);
    if (options.isEmpty) {
      _debugResolver('youtube skipped empty playback options');
      return null;
    }
    final selected = _selectYoutubePlaybackOption(
      options,
      preferredMode: preferredMode,
      preferredServer: preferredServer,
      excludedServers: excludedServers,
    );
    if (selected == null) {
      _debugResolver('youtube skipped all options');
      return null;
    }
    _debugResolver(
      'youtube selected server=${selected.server} mode=${selected.mode.id} '
      'option=${selected.option.id} id=${selected.videoId} '
      'url=${selected.url} title="${selected.title}"',
    );
    if (io.Platform.isAndroid || io.Platform.isLinux || io.Platform.isWindows) {
      return RemoteDirectStream(
        playbackUrl: selected.url,
        playbackKind: 'webview',
        pageUrl: selected.url,
        availableModes: options.map((option) => option.server).toSet(),
        selectedMode: selected.server,
        provider: RemoteProvider.youtube,
        server: selected.server,
        httpHeaders: const {
          'User-Agent': _defaultFetchUserAgent,
        },
      );
    }
    final ytDlpStream = await _resolveYoutubeDirectStreamWithYtDlp(
      selected,
      availableModes: options.map((option) => option.server).toSet(),
    );
    if (ytDlpStream != null) {
      return ytDlpStream;
    }
    final ytClient = yt.YoutubeExplode();
    try {
      final manifest =
          await ytClient.videos.streamsClient.getManifest(selected.videoId);
      final muxed = manifest.muxed.toList()
        ..sort((left, right) {
          final containerCompare = (right.container.name == 'mp4' ? 1 : 0)
              .compareTo(left.container.name == 'mp4' ? 1 : 0);
          if (containerCompare != 0) {
            return containerCompare;
          }
          final heightCompare = right.videoResolution.height
              .compareTo(left.videoResolution.height);
          if (heightCompare != 0) {
            return heightCompare;
          }
          return right.bitrate.bitsPerSecond
              .compareTo(left.bitrate.bitsPerSecond);
        });
      if (muxed.isEmpty) {
        _debugResolver('youtube missing muxed streams id=${selected.videoId}');
        return null;
      }
      final stream = muxed.first;
      return RemoteDirectStream(
        playbackUrl: stream.url.toString(),
        playbackKind: stream.container.name == 'mp4' ? 'mp4' : 'direct',
        pageUrl: selected.url,
        availableModes: options.map((option) => option.server).toSet(),
        selectedMode: selected.server,
        provider: RemoteProvider.youtube,
        server: selected.server,
        httpHeaders: const {
          'User-Agent': _defaultFetchUserAgent,
        },
      );
    } on yt.YoutubeExplodeException catch (error) {
      _debugResolver('youtube manifest failed id=${selected.videoId}: $error');
      return null;
    } finally {
      ytClient.close();
    }
  }

  Future<RemoteDirectStream?> _resolveYoutubeDirectStreamWithYtDlp(
    _YoutubePlaybackOption selected, {
    required Set<String> availableModes,
  }) async {
    _YtDlpResult? result;
    String attemptedFormat = '';
    for (final format in const [
      '18/best[ext=mp4][vcodec!=none][acodec!=none]/best[vcodec!=none][acodec!=none]/best',
      'best',
    ]) {
      attemptedFormat = format;
      _debugResolver(
        'youtube yt-dlp resolve start id=${selected.videoId} '
        'server=${selected.server} format="$format" url=${selected.url}',
      );
      result = await _runYtDlp([
        '-g',
        '-f',
        format,
        '--extractor-args',
        'youtube:player_client=android',
        '--no-warnings',
        selected.url,
      ]);
      _debugResolver(
        'youtube yt-dlp resolve result id=${selected.videoId} '
        'format="$format" exit=${result?.exitCode ?? -1} '
        'stdout=${_debugSingleLine(result?.stdout ?? '')} '
        'stderr=${_debugSingleLine(result?.stderr ?? '')}',
      );
      if (result != null && result.exitCode == 0) {
        break;
      }
    }
    if (result == null || result.exitCode != 0) {
      if (result != null) {
        _debugResolver(
          'youtube yt-dlp resolve failed id=${selected.videoId}: '
          '${result.stderr}',
        );
      }
      await _debugYoutubeFormatsWithYtDlp(
        selected,
        reason: 'direct resolve failed format="$attemptedFormat"',
      );
      return null;
    }
    final playbackUrl = result.stdout
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .firstWhere(
          (line) => line.startsWith('http://') || line.startsWith('https://'),
          orElse: () => '',
        );
    if (playbackUrl.isEmpty) {
      await _debugYoutubeFormatsWithYtDlp(
        selected,
        reason: 'direct resolve returned no http playback url',
      );
      return null;
    }
    _debugResolver(
      'youtube yt-dlp playback id=${selected.videoId} '
      'server=${selected.server} kind='
      '${playbackUrl.toLowerCase().contains('.m3u8') ? 'hls' : playbackUrl.toLowerCase().contains('.mp4') ? 'mp4' : 'direct'} '
      'url=${_debugUrlLabel(playbackUrl)}',
    );
    return RemoteDirectStream(
      playbackUrl: playbackUrl,
      playbackKind: playbackUrl.toLowerCase().contains('.m3u8')
          ? 'hls'
          : playbackUrl.toLowerCase().contains('.mp4')
              ? 'mp4'
              : 'direct',
      pageUrl: selected.url,
      availableModes: availableModes,
      selectedMode: selected.server,
      provider: RemoteProvider.youtube,
      server: selected.server,
      httpHeaders: const {
        'User-Agent': _defaultFetchUserAgent,
      },
    );
  }

  List<_YoutubePlaybackOption> _youtubePlaybackOptionsFor(EpisodeItem entry) {
    final decoded = _decodeYoutubeEpisodeOptions(entry.description);
    if (decoded.isNotEmpty) {
      return decoded;
    }
    final videoId = _youtubeVideoIdFromUrl(
        entry.watchUrl.isNotEmpty ? entry.watchUrl : entry.filePath);
    if (videoId.isEmpty) {
      return const [];
    }
    return [
      _YoutubePlaybackOption(
        server: 'youtube-sub-1',
        mode: YoutubePlaybackMode.sub,
        option: YoutubePlaybackOption.first,
        videoId: videoId,
        url: _youtubeWatchUrl(videoId),
        title: entry.displayName,
        imageUrl: entry.imageUrl,
        durationLabel: entry.durationLabel,
      ),
    ];
  }

  _YoutubePlaybackOption? _selectYoutubePlaybackOption(
    List<_YoutubePlaybackOption> options, {
    required String preferredMode,
    required String preferredServer,
    required Set<String> excludedServers,
  }) {
    final excluded =
        excludedServers.map((entry) => entry.toLowerCase()).toSet();
    final preferred = preferredServer.trim().toLowerCase();
    if (preferred.isNotEmpty && !excluded.contains(preferred)) {
      for (final option in options) {
        if (option.server.toLowerCase() == preferred) {
          return option;
        }
      }
    }
    final mode = youtubePlaybackModeFromId(preferredMode);
    final byMode = options
        .where((option) =>
            option.mode == mode &&
            !excluded.contains(option.server.toLowerCase()))
        .toList();
    if (byMode.isNotEmpty) {
      return byMode.first;
    }
    for (final option in options) {
      if (!excluded.contains(option.server.toLowerCase())) {
        return option;
      }
    }
    return null;
  }

  String _encodeYoutubeEpisodeOptions(List<_YoutubePlaybackOption> options) {
    final payload = [
      for (final option in options)
        {
          'server': option.server,
          'mode': option.mode.id,
          'option': option.option.id,
          'videoId': option.videoId,
          'url': option.url,
          'title': option.title,
          'imageUrl': option.imageUrl,
          'durationLabel': option.durationLabel,
        },
    ];
    return '$_youtubeEpisodeOptionsPrefix${jsonEncode(payload)}';
  }

  List<_YoutubePlaybackOption> _decodeYoutubeEpisodeOptions(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith(_youtubeEpisodeOptionsPrefix)) {
      return const [];
    }
    try {
      final decoded =
          jsonDecode(trimmed.substring(_youtubeEpisodeOptionsPrefix.length));
      if (decoded is! List) {
        return const [];
      }
      final options = <_YoutubePlaybackOption>[];
      for (final entry in decoded.whereType<Map>()) {
        final videoId = _readString(entry['videoId']);
        final url = _readString(entry['url']);
        final server = _readString(entry['server']);
        if (videoId.isEmpty || url.isEmpty || server.isEmpty) {
          continue;
        }
        options.add(
          _YoutubePlaybackOption(
            server: server,
            mode: youtubePlaybackModeFromId(entry['mode']),
            option: youtubePlaybackOptionFromId(entry['option']),
            videoId: videoId,
            url: url,
            title: _readString(entry['title']),
            imageUrl: _readString(entry['imageUrl']),
            durationLabel: _readString(entry['durationLabel']),
          ),
        );
      }
      return options;
    } catch (_) {
      return const [];
    }
  }

  String _youtubeLookupTitle(SeriesItem series) {
    final candidates = [
      series.name,
      ...series.aliases,
      series.japaneseTitle,
    ];
    for (final candidate in candidates) {
      final cleaned = _cleanBiliBiliSearchQuery(candidate);
      if (cleaned.isNotEmpty) {
        return cleaned;
      }
    }
    return '';
  }

  String _formatYoutubeDuration(Duration? duration) {
    if (duration == null || duration <= Duration.zero) {
      return '';
    }
    return _formatSecondsDuration(duration.inSeconds);
  }

  String _formatSecondsDuration(int secondsValue) {
    if (secondsValue <= 0) {
      return '';
    }
    final duration = Duration(seconds: secondsValue);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _youtubeThumbnailUrl(String videoId) {
    return _isYoutubeVideoId(videoId)
        ? 'https://img.youtube.com/vi/$videoId/hqdefault.jpg'
        : '';
  }

  Future<_YtDlpResult?> _runYtDlp(List<String> arguments) async {
    if (!io.Platform.isLinux && !io.Platform.isWindows) {
      return null;
    }
    final ytDlpArguments = [
      ..._ytDlpAuthenticationArguments(),
      ...arguments,
    ];
    Object? lastError;
    for (final executable in _ytDlpExecutableCandidates()) {
      try {
        _debugResolver(
          'yt-dlp exec ${_debugShellCommand([executable, ...ytDlpArguments])}',
        );
        final result = await io.Process.run(
          executable,
          ytDlpArguments,
        ).timeout(const Duration(seconds: 45));
        _debugResolver(
          'yt-dlp exit=${result.exitCode} executable=$executable '
          'stdout=${_debugSingleLine('${result.stdout}')} '
          'stderr=${_debugSingleLine('${result.stderr}')}',
        );
        return _YtDlpResult(
          exitCode: result.exitCode,
          stdout: '${result.stdout}',
          stderr: '${result.stderr}',
        );
      } on Object catch (error) {
        lastError = error;
      }
    }
    _debugResolver('yt-dlp unavailable or failed: $lastError');
    return null;
  }

  Future<void> _debugYoutubeFormatsWithYtDlp(
    _YoutubePlaybackOption selected, {
    required String reason,
  }) async {
    if (!kDebugMode) {
      return;
    }
    _debugResolver(
      'youtube yt-dlp list-formats start id=${selected.videoId} '
      'reason=$reason url=${selected.url}',
    );
    final result = await _runYtDlp([
      '--list-formats',
      '--extractor-args',
      'youtube:player_client=android',
      '--no-warnings',
      selected.url,
    ]);
    if (result == null) {
      _debugResolver(
        'youtube yt-dlp list-formats unavailable id=${selected.videoId}',
      );
      return;
    }
    _debugResolver(
      'youtube yt-dlp list-formats exit=${result.exitCode} '
      'id=${selected.videoId}',
    );
    final output = [
      ...result.stdout.split(RegExp(r'\r?\n')),
      if (result.stderr.trim().isNotEmpty) 'stderr:',
      ...result.stderr.split(RegExp(r'\r?\n')),
    ].map((line) => line.trimRight()).where((line) => line.isNotEmpty);
    var count = 0;
    for (final line in output) {
      count += 1;
      if (count > 80) {
        _debugResolver(
          'youtube yt-dlp format id=${selected.videoId} '
          '... truncated after 80 lines',
        );
        break;
      }
      _debugResolver(
        'youtube yt-dlp format id=${selected.videoId} $line',
      );
    }
  }

  String _debugShellCommand(List<String> parts) {
    return parts.map(_debugShellArg).join(' ');
  }

  String _debugShellArg(String value) {
    if (value.isEmpty) {
      return "''";
    }
    if (!RegExp(r'''[\s'"$`\\]''').hasMatch(value)) {
      return value;
    }
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  String _debugSingleLine(String value, {int maxLength = 360}) {
    final cleaned = value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(_defaultFetchUserAgent, '<user-agent>')
        .trim();
    if (cleaned.length <= maxLength) {
      return cleaned;
    }
    return '${cleaned.substring(0, maxLength)}...';
  }

  List<String> _ytDlpExecutableCandidates() {
    final configured = io.Platform.environment['YTDLP_PATH']?.trim() ?? '';
    final candidates = <String>[
      if (configured.isNotEmpty) configured,
      io.Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp',
    ];
    if (io.Platform.isLinux) {
      final home = io.Platform.environment['HOME']?.trim() ?? '';
      if (home.isNotEmpty) {
        candidates.add('$home/.local/bin/yt-dlp');
      }
      candidates.add('/var/data/python/bin/yt-dlp');
    }
    return candidates.toSet().toList(growable: false);
  }

  List<String> _ytDlpAuthenticationArguments() {
    final cookiesFile = _firstNonEmpty([
      io.Platform.environment['TANUKI_YTDLP_COOKIES'] ?? '',
      io.Platform.environment['YTDLP_COOKIES'] ?? '',
    ]).trim();
    if (cookiesFile.isNotEmpty) {
      return ['--cookies', cookiesFile];
    }

    final cookiesFromBrowser = _firstNonEmpty([
      io.Platform.environment['TANUKI_YTDLP_COOKIES_FROM_BROWSER'] ?? '',
      io.Platform.environment['YTDLP_COOKIES_FROM_BROWSER'] ?? '',
    ]).trim();
    if (cookiesFromBrowser.isNotEmpty) {
      return ['--cookies-from-browser', cookiesFromBrowser];
    }
    return const [];
  }

  Future<List<RemoteSearchCandidate>> _discoverJkAnimeMovies({
    required int limit,
    required int page,
  }) async {
    final uri = Uri.https('jkanime.net', '/directorio', {
      'tipo': 'peliculas',
      if (page > 1) 'p': '$page',
    });
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException(
        'JKAnime peliculas respondio ${response.statusCode}',
      );
    }
    return _parseJkAnimeResults(response.body, 0)
        .where((candidate) => _candidateLooksMovie(candidate))
        .take(limit)
        .toList(growable: false);
  }

  String _cleanBiliBiliSearchQuery(String value) {
    final buffer = StringBuffer();
    var previousWasSpace = true;
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      final keep = RegExp(r'[A-Za-z0-9]').hasMatch(char);
      if (keep) {
        buffer.write(char);
        previousWasSpace = false;
      } else if (!previousWasSpace) {
        buffer.write(' ');
        previousWasSpace = true;
      }
    }
    return buffer.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  bool _shouldUsePlatformWebResolver(RemoteProvider? provider) {
    if (!_webResolver.isAvailable) {
      return false;
    }
    return provider == RemoteProvider.animeAv1 ||
        provider == RemoteProvider.jkAnime ||
        provider == RemoteProvider.latAnime ||
        provider == RemoteProvider.facebook;
  }

  Future<RemoteDirectStream?> _resolveGenericDirectStream(
    EpisodeItem entry, {
    String preferredFacebookMode = '',
    String preferredServer = '',
    Set<String> excludedServers = const {},
  }) async {
    final pageUrl = _buildRemoteEpisodePageUrl(entry);
    if (pageUrl.isEmpty) {
      _debugResolver('generic skipped empty page url');
      return null;
    }
    final directKind = _inferPlaybackKind(pageUrl);
    if (directKind.isNotEmpty) {
      final direct = RemoteDirectStream(
        playbackUrl: pageUrl,
        playbackKind: directKind,
        pageUrl: pageUrl,
        availableModes: const {'direct'},
        selectedMode: 'direct',
      );
      _debugResolver('generic direct ${_debugStreamLabel(direct)}');
      return direct;
    }

    final uri = Uri.tryParse(pageUrl);
    if (uri == null || !uri.hasScheme) {
      _debugResolver('generic invalid page url $pageUrl');
      return null;
    }
    _debugResolver(
      'generic fetch page=${_debugUrlLabel(pageUrl)} '
      'referer=${_debugUrlLabel(entry.watchUrl)}',
    );
    final response = await _get(uri, referer: entry.watchUrl);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _debugResolver(
        'generic fetch failed status=${response.statusCode} '
        'page=${_debugUrlLabel(pageUrl)}',
      );
      return null;
    }
    final resolved = await _resolveDirectStreamFromHtml(
      html: response.body,
      pageUrl: pageUrl,
      referer: entry.watchUrl,
      visited: {pageUrl},
      preferredFacebookMode: preferredFacebookMode,
      preferredServer: preferredServer,
      excludedServers: excludedServers,
    );
    final availableServers = _extractHostCandidates(response.body, pageUrl)
        .map(_normalizedCandidateServer)
        .where((server) => server.isNotEmpty)
        .toSet();
    final resolvedWithServers = resolved?.copyWith(
      availableServers: availableServers,
    );
    _debugResolver(
      'generic html resolved ${_debugStreamLabel(resolvedWithServers)} '
      'servers=${availableServers.join(',')}',
    );
    return resolvedWithServers;
  }

  Future<RemoteDirectStream?> _resolveDirectStreamFromHtml({
    required String html,
    required String pageUrl,
    required String referer,
    required Set<String> visited,
    String preferredFacebookMode = '',
    String preferredServer = '',
    Set<String> excludedServers = const {},
    int depth = 0,
  }) async {
    final resolverHtml = _expandResolverHtml(html);
    final subtitleTracks = _extractSubtitleTracks(resolverHtml, pageUrl);
    final endpointStream =
        await _resolveDownloadEndpointStream(resolverHtml, pageUrl);
    if (endpointStream != null) {
      return endpointStream.copyWith(
        subtitleTracks: _mergeRemoteSubtitleTracks(
          subtitleTracks,
          endpointStream.subtitleTracks,
        ),
      );
    }

    final preferHostCandidates =
        _shouldPreferHostCandidateResolution(resolverHtml, pageUrl);
    if (preferHostCandidates) {
      final hostStream = await _resolveHostCandidateStream(
        html: resolverHtml,
        pageUrl: pageUrl,
        referer: referer,
        visited: visited,
        preferredFacebookMode: preferredFacebookMode,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
        depth: depth,
      );
      if (hostStream != null) {
        return hostStream.copyWith(
          subtitleTracks: _mergeRemoteSubtitleTracks(
            subtitleTracks,
            hostStream.subtitleTracks,
          ),
        );
      }
    }

    final directUrl = _findBestDirectMediaUrl(
      resolverHtml,
      pageUrl,
      preferredFacebookMode: preferredFacebookMode,
    );
    if (directUrl.isNotEmpty) {
      return RemoteDirectStream(
        playbackUrl: directUrl,
        playbackKind: _inferPlaybackKind(directUrl),
        pageUrl: pageUrl,
        availableModes: const {'http-direct'},
        selectedMode: 'http-direct',
        server: _normalizeServerPreference(pageUrl),
        subtitleTracks: subtitleTracks,
        httpHeaders: _directMediaHttpHeaders(
          directUrl: directUrl,
          pageUrl: pageUrl,
        ),
      );
    }
    final doodstreamPassStream =
        await _resolveDoodstreamPassMd5Stream(resolverHtml, pageUrl, referer);
    if (doodstreamPassStream != null) {
      return doodstreamPassStream.copyWith(
        subtitleTracks: _mergeRemoteSubtitleTracks(
          subtitleTracks,
          doodstreamPassStream.subtitleTracks,
        ),
      );
    }
    final networkEndpointStream = await _resolveNetworkEndpointStream(
      html: resolverHtml,
      pageUrl: pageUrl,
      referer: referer,
      visited: visited,
      preferredFacebookMode: preferredFacebookMode,
      preferredServer: preferredServer,
      excludedServers: excludedServers,
      depth: depth,
    );
    if (networkEndpointStream != null) {
      return networkEndpointStream.copyWith(
        subtitleTracks: _mergeRemoteSubtitleTracks(
          subtitleTracks,
          networkEndpointStream.subtitleTracks,
        ),
      );
    }
    if (depth >= 2) {
      return null;
    }

    if (!preferHostCandidates) {
      final hostStream = await _resolveHostCandidateStream(
        html: resolverHtml,
        pageUrl: pageUrl,
        referer: referer,
        visited: visited,
        preferredFacebookMode: preferredFacebookMode,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
        depth: depth,
      );
      if (hostStream != null) {
        return hostStream.copyWith(
          subtitleTracks: _mergeRemoteSubtitleTracks(
            subtitleTracks,
            hostStream.subtitleTracks,
          ),
        );
      }
    }
    return null;
  }

  Future<RemoteDirectStream?> _resolveHostCandidateStream({
    required String html,
    required String pageUrl,
    required String referer,
    required Set<String> visited,
    String preferredFacebookMode = '',
    String preferredServer = '',
    Set<String> excludedServers = const {},
    int depth = 0,
  }) async {
    if (depth >= 2) {
      return null;
    }
    final hostCandidates = _extractHostCandidates(
      html,
      pageUrl,
      preferredServer: preferredServer,
      excludedServers: excludedServers,
    );
    for (final candidate in hostCandidates.take(10)) {
      final hostUrl = candidate.url;
      if (visited.contains(hostUrl) || !_shouldFetchHostUrl(hostUrl)) {
        continue;
      }
      final uri = Uri.tryParse(hostUrl);
      if (uri == null || !uri.hasScheme) {
        continue;
      }
      visited.add(hostUrl);
      final response = await _get(uri, referer: pageUrl);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        continue;
      }
      final effectiveHostUrl = response.request?.url.toString() ?? hostUrl;
      final resolved = await _resolveDirectStreamFromHtml(
        html: response.body,
        pageUrl: effectiveHostUrl,
        referer: pageUrl,
        visited: visited,
        preferredFacebookMode: preferredFacebookMode,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
        depth: depth + 1,
      );
      if (resolved != null) {
        final candidateServer = _explicitCandidateServer(candidate);
        return resolved.copyWith(
          pageUrl: resolved.pageUrl.trim().isEmpty ? hostUrl : resolved.pageUrl,
          server:
              candidateServer.isNotEmpty ? candidateServer : resolved.server,
        );
      }
    }
    return null;
  }

  Future<RemoteDirectStream?> _resolveNetworkEndpointStream({
    required String html,
    required String pageUrl,
    required String referer,
    required Set<String> visited,
    String preferredFacebookMode = '',
    String preferredServer = '',
    Set<String> excludedServers = const {},
    int depth = 0,
  }) async {
    if (depth >= 2) {
      return null;
    }
    final endpointUrls = _extractResolverEndpointUrls(html, pageUrl);
    for (final endpointUrl in endpointUrls.take(8)) {
      if (visited.contains(endpointUrl) ||
          !_shouldFetchResolverEndpoint(endpointUrl, pageUrl)) {
        continue;
      }
      final uri = Uri.tryParse(endpointUrl);
      if (uri == null || !uri.hasScheme) {
        continue;
      }
      visited.add(endpointUrl);
      final response = await _get(
        uri,
        referer: pageUrl.isNotEmpty ? pageUrl : referer,
        headers: const {
          'Accept': 'application/json,text/plain,*/*',
          'X-Requested-With': 'XMLHttpRequest',
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        continue;
      }

      final responseHtml = _expandResolverHtml(response.body);
      final subtitleTracks = _extractSubtitleTracks(responseHtml, endpointUrl);
      final directUrl = _findBestDirectMediaUrl(
        responseHtml,
        endpointUrl,
        preferredFacebookMode: preferredFacebookMode,
      );
      if (directUrl.isNotEmpty) {
        return RemoteDirectStream(
          playbackUrl: directUrl,
          playbackKind: _inferPlaybackKind(directUrl),
          pageUrl: pageUrl,
          availableModes: const {'network-endpoint'},
          selectedMode: 'network-endpoint',
          server: _normalizeServerPreference(endpointUrl).isNotEmpty
              ? _normalizeServerPreference(endpointUrl)
              : _normalizeServerPreference(pageUrl),
          subtitleTracks: subtitleTracks,
          httpHeaders: _directMediaHttpHeaders(
            directUrl: directUrl,
            pageUrl: endpointUrl,
          ),
        );
      }

      final resolved = await _resolveDirectStreamFromHtml(
        html: responseHtml,
        pageUrl: endpointUrl,
        referer: pageUrl,
        visited: visited,
        preferredFacebookMode: preferredFacebookMode,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
        depth: depth + 1,
      );
      if (resolved != null) {
        return RemoteDirectStream(
          playbackUrl: resolved.playbackUrl,
          playbackKind: resolved.playbackKind,
          pageUrl: pageUrl,
          availableModes: const {'network-endpoint'},
          selectedMode: 'network-endpoint',
          server: resolved.server.isNotEmpty
              ? resolved.server
              : _normalizeServerPreference(endpointUrl),
          subtitleTracks: _mergeRemoteSubtitleTracks(
            subtitleTracks,
            resolved.subtitleTracks,
          ),
          httpHeaders: resolved.httpHeaders,
        );
      }
    }
    return null;
  }

  Map<String, String> _directMediaHttpHeaders({
    required String directUrl,
    required String pageUrl,
  }) {
    if (_inferPlaybackKind(directUrl).isEmpty) {
      return const {};
    }
    final server = _normalizeServerPreference(pageUrl);
    if (server != 'mp4upload') {
      return const {};
    }
    final uri = Uri.tryParse(pageUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return const {};
    }
    return {
      'User-Agent': _defaultFetchUserAgent,
      'Referer': pageUrl,
      'Origin': _baseOrigin(pageUrl),
    };
  }

  Future<RemoteDirectStream?> _resolveDoodstreamPassMd5Stream(
    String html,
    String pageUrl,
    String referer,
  ) async {
    final passUrl = _extractDoodstreamPassMd5Url(html, pageUrl);
    if (passUrl.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(passUrl);
    if (uri == null || !uri.hasScheme) {
      return null;
    }

    final response = await _get(
      uri,
      referer: pageUrl.isNotEmpty ? pageUrl : referer,
      headers: const {'Accept': '*/*'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final prefix = _normalizeExtractedUrl(response.body, baseUrl: passUrl);
    if (prefix.isEmpty) {
      return null;
    }
    if (_inferPlaybackKind(prefix).isNotEmpty) {
      return RemoteDirectStream(
        playbackUrl: prefix,
        playbackKind: _inferPlaybackKind(prefix),
        pageUrl: pageUrl,
        availableModes: const {'doodstream-pass-md5'},
        selectedMode: 'doodstream-pass-md5',
        server: _normalizeServerPreference(pageUrl),
      );
    }

    final token = _extractDoodstreamToken(html);
    if (token.isEmpty) {
      return null;
    }
    final directUrl = '$prefix${_randomAlphaNumeric(10)}?token=$token&expiry='
        '${DateTime.now().millisecondsSinceEpoch}';
    final kind = _inferPlaybackKind(directUrl);
    if (kind.isEmpty) {
      return null;
    }
    return RemoteDirectStream(
      playbackUrl: directUrl,
      playbackKind: kind,
      pageUrl: pageUrl,
      availableModes: const {'doodstream-pass-md5'},
      selectedMode: 'doodstream-pass-md5',
      server: _normalizeServerPreference(pageUrl),
    );
  }

  Future<RemoteDirectStream?> _resolveDownloadEndpointStream(
      String html, String pageUrl) async {
    final endpointPath = RegExp(
          "[\"'](/ajax/download_episode/\\d+)[\"']",
          caseSensitive: false,
        ).firstMatch(html)?.group(1) ??
        '';
    if (endpointPath.isEmpty) {
      return null;
    }
    final endpointUrl = Uri.tryParse(pageUrl)?.resolve(endpointPath).toString();
    if (endpointUrl == null || endpointUrl.isEmpty) {
      return null;
    }
    final response = await _get(Uri.parse(endpointUrl), referer: pageUrl);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    final decoded = () {
      try {
        return jsonDecode(response.body);
      } catch (_) {
        return null;
      }
    }();
    if (decoded is! Map) {
      return null;
    }
    final rawUrl = _readString(decoded['url']);
    final directUrl = _normalizeExtractedUrl(rawUrl, baseUrl: pageUrl);
    final kind = _inferPlaybackKind(directUrl);
    if (kind.isEmpty) {
      return null;
    }
    return RemoteDirectStream(
      playbackUrl: directUrl,
      playbackKind: kind,
      pageUrl: pageUrl,
      availableModes: const {'download-direct'},
      selectedMode: 'download-direct',
      server: _normalizeServerPreference(pageUrl),
    );
  }

  RemoteSearchCandidate _candidateFromJikan(Map<String, dynamic> entry) {
    final malId = _readInt(entry['mal_id']);
    final title = _firstNonEmpty([
      _readString(entry['title']),
      _readString(entry['title_english']),
      _readString(entry['title_japanese']),
      malId > 0 ? 'Anime $malId' : '',
    ]);
    final images = entry['images'] is Map ? entry['images'] as Map : const {};
    final jpg = images['jpg'] is Map ? images['jpg'] as Map : const {};
    final trailer =
        entry['trailer'] is Map ? entry['trailer'] as Map : const {};
    final trailerImages =
        trailer['images'] is Map ? trailer['images'] as Map : const {};
    final aliases = <String>{
      _readString(entry['title_english']),
      _readString(entry['title_japanese']),
    }..removeWhere((value) => value.isEmpty || value == title);

    return RemoteSearchCandidate(
      provider: RemoteProvider.catalog,
      slug: malId > 0 ? '$malId' : normalizeSeriesKey(title),
      title: title,
      watchUrl: _readString(entry['url'],
          fallback: malId > 0 ? 'https://myanimelist.net/anime/$malId' : ''),
      seriesUrl: _readString(entry['url']),
      imageUrl: _firstNonEmpty([
        _readString(jpg['large_image_url']),
        _readString(jpg['image_url']),
      ]),
      backgroundUrl: _firstNonEmpty([
        _readString(trailerImages['maximum_image_url']),
        _readString(trailerImages['large_image_url']),
        _readString(jpg['large_image_url']),
      ]),
      trailerUrl: _jikanTrailerUrl(trailer),
      description: _readString(entry['synopsis']),
      rating: _readScore(entry['score']),
      episodeCount: _readInt(entry['episodes']),
      format: _readString(entry['type']),
      japaneseTitle: _readString(entry['title_japanese']),
      aliases: aliases.toList(),
      releaseYear:
          _readInt(entry['year'], fallback: _yearFromAired(entry['aired'])),
      airDateIso: _airedIso(entry['aired']),
      catalogId: malId,
    );
  }

  RemoteSearchCandidate _candidateFromMyAnimeListNode(
    Map<String, dynamic> node,
  ) {
    final malId = _readInt(node['id']);
    final alternativeTitles = node['alternative_titles'] is Map
        ? Map<String, dynamic>.from(node['alternative_titles'] as Map)
        : const <String, dynamic>{};
    final title = _firstNonEmpty([
      _readString(node['title']),
      _readString(alternativeTitles['en']),
      _readString(alternativeTitles['ja']),
      malId > 0 ? 'Anime $malId' : '',
    ]);
    final mainPicture = node['main_picture'] is Map
        ? Map<String, dynamic>.from(node['main_picture'] as Map)
        : const <String, dynamic>{};
    final synonyms = alternativeTitles['synonyms'];
    final aliases = <String>{
      _readString(alternativeTitles['en']),
      _readString(alternativeTitles['ja']),
      if (synonyms is List) ...synonyms.map(_readString),
    }..removeWhere((value) => value.isEmpty || value == title);
    final startDate = _readString(node['start_date']);
    final mean = _readDouble(node['mean']);
    return RemoteSearchCandidate(
      provider: RemoteProvider.catalog,
      slug: malId > 0 ? '$malId' : normalizeSeriesKey(title),
      title: title,
      watchUrl: malId > 0 ? 'https://myanimelist.net/anime/$malId' : '',
      seriesUrl: malId > 0 ? 'https://myanimelist.net/anime/$malId' : '',
      imageUrl: _firstNonEmpty([
        _readString(mainPicture['large']),
        _readString(mainPicture['medium']),
      ]),
      backgroundUrl: _readString(mainPicture['large']),
      description: _readString(node['synopsis']),
      rating: mean > 0 ? mean.toStringAsFixed(1) : '',
      episodeCount: _readInt(node['num_episodes']),
      format: _formatMyAnimeListMediaType(_readString(node['media_type'])),
      japaneseTitle: _readString(alternativeTitles['ja']),
      aliases: aliases.toList(),
      releaseYear: _extractYearFromText(startDate),
      airDateIso: startDate,
      catalogId: malId,
    );
  }

  RemoteSearchCandidate _candidateFromAniList(Map<String, dynamic> entry) {
    final malId = _readInt(entry['idMal']);
    final anilistId = _readInt(entry['id']);
    final titles = entry['title'] is Map
        ? Map<String, dynamic>.from(entry['title'] as Map)
        : const <String, dynamic>{};
    final title = _firstNonEmpty([
      _readString(titles['romaji']),
      _readString(titles['english']),
      _readString(titles['native']),
      malId > 0 ? 'Anime $malId' : '',
    ]);
    final coverImage = entry['coverImage'] is Map
        ? Map<String, dynamic>.from(entry['coverImage'] as Map)
        : const <String, dynamic>{};
    final startDate = entry['startDate'] is Map
        ? Map<String, dynamic>.from(entry['startDate'] as Map)
        : const <String, dynamic>{};
    final synonyms = entry['synonyms'];
    final aliases = <String>{
      _readString(titles['english']),
      _readString(titles['native']),
      if (synonyms is List) ...synonyms.map(_readString),
    }..removeWhere((value) => value.isEmpty || value == title);
    final airDateIso = _anilistDateIso(startDate);
    final airingSchedule = entry['airingSchedule'] is Map
        ? Map<String, dynamic>.from(entry['airingSchedule'] as Map)
        : const <String, dynamic>{};
    final scheduleNodes = airingSchedule['nodes'];
    final episodeDetails = scheduleNodes is List
        ? scheduleNodes
            .whereType<Map>()
            .map((rawNode) {
              final node = Map<String, dynamic>.from(rawNode);
              final episodeNumber = _readInt(node['episode']);
              if (episodeNumber <= 0) {
                return null;
              }
              return SeriesEpisodeMetadata(
                episodeNumber: episodeNumber,
                airDateIso: _anilistUnixDateIso(_readInt(node['airingAt'])),
              );
            })
            .whereType<SeriesEpisodeMetadata>()
            .toList(growable: false)
        : const <SeriesEpisodeMetadata>[];
    return RemoteSearchCandidate(
      provider: RemoteProvider.catalog,
      slug: malId > 0
          ? '$malId'
          : anilistId > 0
              ? 'anilist-$anilistId'
              : normalizeSeriesKey(title),
      title: title,
      watchUrl: malId > 0
          ? 'https://myanimelist.net/anime/$malId'
          : anilistId > 0
              ? 'https://anilist.co/anime/$anilistId'
              : '',
      seriesUrl: malId > 0
          ? 'https://myanimelist.net/anime/$malId'
          : anilistId > 0
              ? 'https://anilist.co/anime/$anilistId'
              : '',
      imageUrl: _firstNonEmpty([
        _readString(coverImage['extraLarge']),
        _readString(coverImage['large']),
      ]),
      backgroundUrl: _firstNonEmpty([
        _readString(entry['bannerImage']),
        _readString(coverImage['extraLarge']),
      ]),
      trailerUrl: _anilistTrailerUrl(entry['trailer']),
      description: _cleanRemoteText(_readString(entry['description'])),
      rating: _readAniListScore(entry['averageScore']),
      episodeCount: _readInt(entry['episodes']),
      format: _formatAniListMediaType(_readString(entry['format'])),
      japaneseTitle: _readString(titles['native']),
      aliases: aliases.toList(),
      releaseYear: _readInt(startDate['year'],
          fallback: _extractYearFromText(airDateIso)),
      airDateIso: airDateIso,
      catalogId: malId,
      episodeDetails: episodeDetails,
    );
  }

  Future<RemoteSearchCandidate?> _fetchAniListCandidateDetail(
    int catalogId,
  ) async {
    if (catalogId <= 0) {
      return null;
    }
    final decoded = await _postAniList({
      'query': r'''
        query AnimeDetail($idMal: Int) {
          Media(idMal: $idMal, type: ANIME) {
            id
            idMal
            title {
              romaji
              english
              native
            }
            synonyms
            description(asHtml: false)
            episodes
            format
            averageScore
            startDate {
              year
              month
              day
            }
            coverImage {
              extraLarge
              large
            }
            bannerImage
            trailer {
              id
              site
            }
          }
        }
      ''',
      'variables': {'idMal': catalogId},
    });
    final data = decoded['data'] is Map
        ? Map<String, dynamic>.from(decoded['data'] as Map)
        : const <String, dynamic>{};
    final media = data['Media'];
    if (media is! Map) {
      return null;
    }
    return _candidateFromAniList(Map<String, dynamic>.from(media));
  }

  Future<RemoteSearchCandidate?> _safeFetchAniListCandidateDetail(
    int catalogId,
  ) async {
    if (catalogId <= 0) {
      return null;
    }
    final cached = _aniListDetailCache[catalogId];
    if (cached != null) {
      try {
        return await cached;
      } catch (_) {
        _aniListDetailCache.remove(catalogId);
      }
    }
    final future = _fetchAniListCandidateDetail(catalogId);
    _aniListDetailCache[catalogId] = future;
    try {
      return await future;
    } catch (error) {
      _aniListDetailCache.remove(catalogId);
      if (!'$error'.contains('en espera por rate limit')) {
        _debugResolver('AniList detail failed: $error');
      }
      return null;
    }
  }

  Future<List<SeriesEpisodeMetadata>> _fetchAniListEpisodeMetadata(
    int catalogId,
  ) async {
    if (catalogId <= 0) {
      return const [];
    }
    final collected = <SeriesEpisodeMetadata>[];
    var page = 1;
    var hasNextPage = true;
    while (hasNextPage && page <= 20) {
      final decoded = await _postAniList({
        'query': r'''
          query AnimeAiring($idMal: Int, $page: Int) {
            Media(idMal: $idMal, type: ANIME) {
              airingSchedule(page: $page, perPage: 50) {
                nodes {
                  episode
                  airingAt
                }
                pageInfo {
                  hasNextPage
                }
              }
            }
          }
        ''',
        'variables': {
          'idMal': catalogId,
          'page': page,
        },
      });
      final data = decoded['data'] is Map
          ? Map<String, dynamic>.from(decoded['data'] as Map)
          : const <String, dynamic>{};
      final media = data['Media'] is Map
          ? Map<String, dynamic>.from(data['Media'] as Map)
          : const <String, dynamic>{};
      final schedule = media['airingSchedule'] is Map
          ? Map<String, dynamic>.from(media['airingSchedule'] as Map)
          : const <String, dynamic>{};
      final nodes = schedule['nodes'];
      if (nodes is! List || nodes.isEmpty) {
        break;
      }
      for (final rawNode in nodes) {
        if (rawNode is! Map) {
          continue;
        }
        final node = Map<String, dynamic>.from(rawNode);
        final episodeNumber = _readInt(node['episode']);
        if (episodeNumber <= 0) {
          continue;
        }
        collected.add(SeriesEpisodeMetadata(
          episodeNumber: episodeNumber,
          airDateIso: _anilistUnixDateIso(_readInt(node['airingAt'])),
        ));
      }
      final pageInfo = schedule['pageInfo'] is Map
          ? Map<String, dynamic>.from(schedule['pageInfo'] as Map)
          : const <String, dynamic>{};
      hasNextPage = pageInfo['hasNextPage'] == true;
      page += 1;
    }
    collected.sort(
        (left, right) => left.episodeNumber.compareTo(right.episodeNumber));
    final seen = <int>{};
    return collected.where((entry) => seen.add(entry.episodeNumber)).toList();
  }

  Future<List<SeriesEpisodeMetadata>> _safeFetchAniListEpisodeMetadata(
    int catalogId,
  ) async {
    if (catalogId <= 0) {
      return const [];
    }
    final cached = _aniListEpisodeCache[catalogId];
    if (cached != null) {
      try {
        return await cached;
      } catch (_) {
        _aniListEpisodeCache.remove(catalogId);
      }
    }
    final future = _fetchAniListEpisodeMetadata(catalogId);
    _aniListEpisodeCache[catalogId] = future;
    try {
      return await future;
    } catch (error) {
      _aniListEpisodeCache.remove(catalogId);
      if (!'$error'.contains('en espera por rate limit')) {
        _debugResolver('AniList episodes failed: $error');
      }
      return const [];
    }
  }

  Future<Map<String, dynamic>> _postAniList(Map<String, Object?> body) async {
    final blockedUntil = _aniListBlockedUntil;
    if (blockedUntil != null && DateTime.now().isBefore(blockedUntil)) {
      throw const RemoteCatalogException('AniList en espera por rate limit');
    }
    final response = await _client.post(
      Uri.parse(_anilistGraphQlUrl),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'User-Agent': _defaultFetchUserAgent,
      },
      body: jsonEncode(body),
    );
    if (response.statusCode == 429) {
      _aniListBlockedUntil = DateTime.now().add(const Duration(seconds: 75));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException('AniList respondio ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const RemoteCatalogException('AniList respondio JSON invalido');
    }
    final root = Map<String, dynamic>.from(decoded);
    final errors = root['errors'];
    if (errors is List && errors.isNotEmpty) {
      throw RemoteCatalogException('AniList respondio con errores');
    }
    return root;
  }

  String _formatAniListMediaType(String value) {
    final normalized = value.trim().toUpperCase();
    return switch (normalized) {
      'TV' => 'TV',
      'TV_SHORT' => 'TV',
      'MOVIE' => 'Movie',
      'OVA' => 'OVA',
      'ONA' => 'ONA',
      'SPECIAL' => 'Special',
      'MUSIC' => 'Music',
      _ => value,
    };
  }

  String _anilistDateIso(Map<String, dynamic> date) {
    final year = _readInt(date['year']);
    final month = _readInt(date['month']);
    final day = _readInt(date['day']);
    if (year <= 0) {
      return '';
    }
    if (month <= 0 || day <= 0) {
      return '$year';
    }
    return '$year-${month.toString().padLeft(2, '0')}-'
        '${day.toString().padLeft(2, '0')}';
  }

  String _anilistUnixDateIso(int seconds) {
    if (seconds <= 0) {
      return '';
    }
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
        .toIso8601String();
  }

  String _anilistTrailerUrl(Object? value) {
    if (value is! Map) {
      return '';
    }
    final trailer = Map<String, dynamic>.from(value);
    final site = _readString(trailer['site']).toLowerCase();
    final id = _readString(trailer['id']);
    if (site == 'youtube' && id.isNotEmpty) {
      return _youtubeWatchUrl(id);
    }
    return '';
  }

  String _readAniListScore(Object? value) {
    final score = _readDouble(value);
    if (score <= 0) {
      return '';
    }
    return (score / 10).toStringAsFixed(1);
  }

  String _formatMyAnimeListMediaType(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'tv' => 'TV',
      'movie' => 'Movie',
      'ova' => 'OVA',
      'ona' => 'ONA',
      'special' => 'Special',
      'music' => 'Music',
      _ => value,
    };
  }

  String _jikanTrailerUrl(Map trailer) {
    final youtubeId = _readString(trailer['youtube_id']);
    if (youtubeId.isNotEmpty) {
      return _youtubeWatchUrl(youtubeId);
    }
    return _normalizeYoutubeTrailerUrl(_firstNonEmpty([
      _readString(trailer['url']),
      _readString(trailer['embed_url']),
    ]));
  }

  String _normalizeYoutubeTrailerUrl(String value) {
    final videoId = _youtubeVideoIdFromUrl(value);
    if (videoId.isEmpty) {
      return value;
    }
    return _youtubeWatchUrl(videoId);
  }

  String _youtubeWatchUrl(String videoId) {
    return 'https://www.youtube.com/watch?v=$videoId';
  }

  String _youtubeVideoIdFromUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      return '';
    }
    final host = uri.host.toLowerCase();
    final isYoutube = host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtube-nocookie.com' ||
        host.endsWith('.youtube-nocookie.com') ||
        host == 'youtu.be' ||
        host.endsWith('.youtu.be');
    if (!isYoutube) {
      return '';
    }
    final queryId = uri.queryParameters['v'];
    if (_isYoutubeVideoId(queryId)) {
      return queryId!;
    }
    final segments = uri.pathSegments;
    if ((host == 'youtu.be' || host.endsWith('.youtu.be')) &&
        segments.isNotEmpty &&
        _isYoutubeVideoId(segments.first)) {
      return segments.first;
    }
    for (var index = 0; index < segments.length - 1; index += 1) {
      final marker = segments[index].toLowerCase();
      if ((marker == 'embed' || marker == 'shorts' || marker == 'live') &&
          _isYoutubeVideoId(segments[index + 1])) {
        return segments[index + 1];
      }
    }
    return '';
  }

  bool _isYoutubeVideoId(String? value) {
    return value != null && RegExp(r'^[0-9A-Za-z_-]{11}$').hasMatch(value);
  }

  Future<RemoteSearchCandidate> _enrichCandidateVisuals(
      RemoteSearchCandidate candidate) async {
    if (candidate.provider == RemoteProvider.animeKai ||
        !_isTmdbConfigured() ||
        candidate.title.trim().isEmpty) {
      return candidate;
    }

    final visuals = await _safeFetchTmdbVisuals(candidate);
    if (visuals == null || !visuals.hasMeaningfulContent) {
      return candidate;
    }

    return _copyCandidate(
      candidate,
      // La caratula pertenece al catalogo de anime (Jikan/AniList o la
      // fuente original). TMDB solo complementa artes horizontales y logos.
      imageUrl: candidate.imageUrl,
      backgroundUrl:
          _firstNonEmpty([visuals.backgroundUrl, candidate.backgroundUrl]),
      logoUrl: _firstNonEmpty([visuals.logoUrl, candidate.logoUrl]),
      trailerUrl: _firstNonEmpty([candidate.trailerUrl, visuals.trailerUrl]),
      description: _firstNonEmpty([visuals.description, candidate.description]),
      rating: _firstNonEmpty([candidate.rating, visuals.rating]),
      japaneseTitle:
          _firstNonEmpty([candidate.japaneseTitle, visuals.originalTitle]),
      aliases: _mergeAliases(
        candidate.aliases,
        [visuals.title, visuals.originalTitle],
        title: candidate.title,
      ),
      cast: _mergeCast(candidate.cast, visuals.cast),
      episodeDetails: candidate.episodeDetails.isNotEmpty
          ? _mergeEpisodeMetadata(candidate.episodeDetails, visuals.episodes)
          : visuals.episodes.isNotEmpty
              ? visuals.episodes
              : candidate.episodeDetails,
    );
  }

  Future<RemoteSearchCandidate> _enrichCatalogCandidateFromJikan(
    RemoteSearchCandidate candidate,
  ) async {
    if (candidate.provider != RemoteProvider.catalog ||
        candidate.catalogId <= 0) {
      return candidate;
    }
    try {
      final results = await Future.wait<Object?>([
        _safeFetchJikanCandidateDetail(candidate.catalogId),
        _safeFetchJikanEpisodeMetadata(candidate.catalogId),
        _safeFetchJikanCast(candidate.catalogId),
        _safeFetchAniListCandidateDetail(candidate.catalogId),
        _safeFetchAniListEpisodeMetadata(candidate.catalogId),
      ]);
      final jikanDetail = results[0] as RemoteSearchCandidate?;
      final anilistDetail = results[3] as RemoteSearchCandidate?;
      final detail = jikanDetail ??
          await _fetchMyAnimeListCandidateDetail(candidate.catalogId) ??
          anilistDetail;
      final jikanEpisodes = results[1] as List<SeriesEpisodeMetadata>;
      final anilistEpisodes = results[4] as List<SeriesEpisodeMetadata>;
      final episodes = anilistEpisodes.isNotEmpty
          ? _mergeEpisodeMetadata(anilistEpisodes, jikanEpisodes)
          : jikanEpisodes;
      final cast = results[2] as List<String>;
      if (detail == null && episodes.isEmpty && cast.isEmpty) {
        return candidate;
      }
      final catalogEpisodeCount = anilistDetail?.episodeCount ?? 0;
      final detailEpisodeCount = detail?.episodeCount ?? 0;
      final episodeCount = catalogEpisodeCount > 0
          ? catalogEpisodeCount
          : detailEpisodeCount > 0
              ? detailEpisodeCount
              : episodes.isNotEmpty
                  ? episodes.length
                  : 0;
      var episodeDetails = episodeCount > 0 || episodes.isNotEmpty
          ? _mergeEpisodeMetadata(
              episodes,
              candidate.episodeDetails,
            )
          : const <SeriesEpisodeMetadata>[];
      episodeDetails = await _mergeAnimeAv1EpisodeScaffold(
        candidate,
        episodeDetails,
        fallbackImageUrl: _firstNonEmpty([
          detail?.imageUrl ?? '',
          candidate.imageUrl,
        ]),
      );
      final scaffoldEpisodeCount = episodeDetails.isEmpty
          ? episodeCount
          : episodeDetails
              .where((episode) => episode.episodeNumber >= 0)
              .length;
      return _copyCandidate(
        candidate,
        watchUrl: _firstNonEmpty([candidate.watchUrl, detail?.watchUrl ?? '']),
        seriesUrl:
            _firstNonEmpty([candidate.seriesUrl, detail?.seriesUrl ?? '']),
        imageUrl: _firstNonEmpty([detail?.imageUrl ?? '', candidate.imageUrl]),
        backgroundUrl: _firstNonEmpty([
          candidate.backgroundUrl,
          detail?.backgroundUrl ?? '',
        ]),
        trailerUrl:
            _firstNonEmpty([candidate.trailerUrl, detail?.trailerUrl ?? '']),
        description:
            _firstNonEmpty([detail?.description ?? '', candidate.description]),
        rating: _firstNonEmpty([candidate.rating, detail?.rating ?? '']),
        episodeCount: max(episodeCount, scaffoldEpisodeCount),
        format: _firstNonEmpty([candidate.format, detail?.format ?? '']),
        japaneseTitle: _firstNonEmpty([
          candidate.japaneseTitle,
          detail?.japaneseTitle ?? '',
        ]),
        aliases: _mergeAliases(
          candidate.aliases,
          [
            detail?.title ?? '',
            detail?.japaneseTitle ?? '',
            ...?detail?.aliases,
          ],
          title: candidate.title,
        ),
        releaseYear: candidate.releaseYear > 0
            ? candidate.releaseYear
            : detail?.releaseYear ?? 0,
        airDateIso:
            _firstNonEmpty([detail?.airDateIso ?? '', candidate.airDateIso]),
        episodeDetails: episodeDetails,
        cast: _mergeCast(candidate.cast, [
          ...?detail?.cast,
          ...cast,
        ]),
      );
    } catch (error) {
      _debugResolver('catalog enrich failed: $error');
      return candidate;
    }
  }

  Future<RemoteSearchCandidate?> _safeFetchJikanCandidateDetail(
    int catalogId,
  ) async {
    try {
      return await _fetchJikanCandidateDetail(catalogId);
    } catch (error) {
      _debugResolver('Jikan detail failed: $error');
      return null;
    }
  }

  Future<List<SeriesEpisodeMetadata>> _safeFetchJikanEpisodeMetadata(
    int catalogId,
  ) async {
    try {
      return await _fetchJikanEpisodeMetadata(catalogId);
    } catch (error) {
      _debugResolver('Jikan episodes failed: $error');
      return const [];
    }
  }

  Future<List<String>> _safeFetchJikanCast(int catalogId) async {
    try {
      return await _fetchJikanCast(catalogId);
    } catch (error) {
      _debugResolver('Jikan cast failed: $error');
      return const [];
    }
  }

  Future<List<SeriesEpisodeMetadata>> _mergeAnimeAv1EpisodeScaffold(
    RemoteSearchCandidate candidate,
    List<SeriesEpisodeMetadata> episodeDetails, {
    required String fallbackImageUrl,
  }) async {
    if (candidate.provider != RemoteProvider.catalog ||
        candidate.title.trim().isEmpty) {
      return episodeDetails;
    }
    final queries = _seriesProviderLookupQueries(
      candidate.toSeries(existingNames: const []),
      null,
    ).take(4);
    RemoteSearchCandidate? best;
    var bestScore = 0;
    for (final query in queries) {
      final results = await _safeProviderSearch(
        () => searchAnimeAv1(query, releaseYear: candidate.releaseYear),
      );
      for (final result in results) {
        final score = _scoreCandidateAgainstQuery(query, result);
        if (score > bestScore) {
          bestScore = score;
          best = result;
        }
      }
      if (bestScore >= 900) {
        break;
      }
    }
    if (best == null || bestScore < 520) {
      return episodeDetails;
    }
    final slug = _extractAnimeAv1Slug(
      best.seriesUrl.isNotEmpty ? best.seriesUrl : best.watchUrl,
    );
    final seriesUrl = _normalizeAnimeAv1SeriesUrl(
      best.seriesUrl.isNotEmpty
          ? best.seriesUrl
          : best.watchUrl.isNotEmpty
              ? best.watchUrl
              : slug.isEmpty
                  ? ''
                  : '$_animeAv1BaseUrl/media/$slug',
    );
    if (slug.isEmpty || seriesUrl.isEmpty) {
      return episodeDetails;
    }
    final response = await _get(Uri.parse(seriesUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return episodeDetails;
    }
    final episodeNumbers = _parseAnimeAv1EpisodeNumbers(response.body, slug);
    if (episodeNumbers.isEmpty) {
      return episodeDetails;
    }
    final currentNumbers = episodeDetails
        .map((episode) => episode.episodeNumber)
        .where((number) => number >= 0)
        .toSet();
    final hasExtraNumbers = episodeNumbers.any(
      (episodeNumber) => !currentNumbers.contains(episodeNumber),
    );
    if (!hasExtraNumbers &&
        !episodeNumbers.contains(0) &&
        episodeNumbers.length <= currentNumbers.length) {
      return episodeDetails;
    }
    final existingByNumber = _episodeMetadataByNumber(episodeDetails);
    final merged = <SeriesEpisodeMetadata>[];
    for (final episodeNumber in episodeNumbers) {
      final existing = existingByNumber[episodeNumber];
      if (existing != null) {
        merged.add(existing);
        continue;
      }
      merged.add(SeriesEpisodeMetadata(
        episodeNumber: episodeNumber,
        title: episodeNumber == 0 ? 'Episodio 0' : '',
        imageUrl: episodeNumber == 0 ? fallbackImageUrl : '',
      ));
    }
    return merged;
  }

  Future<RemoteSearchCandidate?> _fetchJikanCandidateDetail(
    int catalogId,
  ) async {
    if (catalogId <= 0) {
      return null;
    }
    for (final path in [
      '/v4/anime/$catalogId/full',
      '/v4/anime/$catalogId',
    ]) {
      final response = await _get(Uri.https('api.jikan.moe', path));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        continue;
      }
      final decoded = jsonDecode(response.body);
      final root = decoded is Map ? Map<String, dynamic>.from(decoded) : null;
      final data = root?['data'];
      if (data is Map) {
        return _candidateFromJikan(Map<String, dynamic>.from(data));
      }
    }
    return null;
  }

  Future<RemoteSearchCandidate?> _fetchMyAnimeListCandidateDetail(
    int catalogId,
  ) async {
    if (catalogId <= 0 || !_hasMyAnimeListClientId) {
      return null;
    }
    final uri = Uri.parse('$_myAnimeListApiBaseUrl/anime/$catalogId').replace(
      queryParameters: {
        'fields': [
          'id',
          'title',
          'main_picture',
          'alternative_titles',
          'start_date',
          'media_type',
          'num_episodes',
          'synopsis',
          'mean',
        ].join(','),
      },
    );
    final response = await _getMyAnimeList(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      return null;
    }
    return _candidateFromMyAnimeListNode(
      Map<String, dynamic>.from(decoded),
    );
  }

  Future<List<SeriesEpisodeMetadata>> _fetchJikanEpisodeMetadata(
    int catalogId,
  ) async {
    if (catalogId <= 0) {
      return const [];
    }
    final collected = <SeriesEpisodeMetadata>[];
    var page = 1;
    var lastVisiblePage = 1;
    while (page <= lastVisiblePage && page <= 20) {
      final response = await _get(
        Uri.https('api.jikan.moe', '/v4/anime/$catalogId/episodes', {
          'page': '$page',
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        break;
      }
      final decoded = jsonDecode(response.body);
      final root = decoded is Map ? Map<String, dynamic>.from(decoded) : null;
      final data = root?['data'];
      if (data is! List || data.isEmpty) {
        break;
      }
      for (final rawEpisode in data) {
        if (rawEpisode is! Map) {
          continue;
        }
        final episode = Map<String, dynamic>.from(rawEpisode);
        final episodeNumber = _readInt(
          episode['number'],
          fallback: _readInt(episode['mal_id']),
        );
        if (episodeNumber <= 0) {
          continue;
        }
        final aired = episode['aired'];
        final images = episode['images'] is Map
            ? Map<String, dynamic>.from(episode['images'] as Map)
            : const <String, dynamic>{};
        final jpg = images['jpg'] is Map
            ? Map<String, dynamic>.from(images['jpg'] as Map)
            : const <String, dynamic>{};
        final webp = images['webp'] is Map
            ? Map<String, dynamic>.from(images['webp'] as Map)
            : const <String, dynamic>{};
        final rawDuration = _readString(episode['duration']);
        final durationMinutes = _readInt(episode['duration']);
        collected.add(SeriesEpisodeMetadata(
          episodeNumber: episodeNumber,
          title: _firstNonEmpty([
            _readString(episode['title']),
            _readString(episode['title_romanji']),
            _readString(episode['title_japanese']),
          ]),
          description: _cleanRemoteText(_readString(episode['synopsis'])),
          imageUrl: _cleanRemoteUrl(_firstNonEmpty([
            _readString(jpg['image_url']),
            _readString(webp['image_url']),
          ])),
          durationLabel: rawDuration.isNotEmpty
              ? rawDuration
              : durationMinutes > 0
                  ? '$durationMinutes min'
                  : '',
          airDateIso: aired is Map
              ? _readString(Map<String, dynamic>.from(aired)['from'])
              : _readString(aired),
        ));
      }
      final pagination = root?['pagination'];
      final paginationMap = pagination is Map
          ? Map<String, dynamic>.from(pagination)
          : const <String, dynamic>{};
      lastVisiblePage =
          _readInt(paginationMap['last_visible_page'], fallback: page);
      final hasNextPage = paginationMap['has_next_page'] == true;
      if (!hasNextPage && page >= lastVisiblePage) {
        break;
      }
      page += 1;
    }
    collected.sort(
        (left, right) => left.episodeNumber.compareTo(right.episodeNumber));
    final seen = <int>{};
    return collected.where((entry) => seen.add(entry.episodeNumber)).toList();
  }

  Future<List<String>> _fetchJikanCast(int catalogId) async {
    if (catalogId <= 0) {
      return const [];
    }
    final response = await _get(
      Uri.https('api.jikan.moe', '/v4/anime/$catalogId/characters'),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const [];
    }
    final decoded = jsonDecode(response.body);
    final root = decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    final data = root?['data'];
    if (data is! List) {
      return const [];
    }
    final cast = <String>[];
    for (final rawEntry in data) {
      if (rawEntry is! Map) {
        continue;
      }
      final entry = Map<String, dynamic>.from(rawEntry);
      final character = entry['character'] is Map
          ? Map<String, dynamic>.from(entry['character'] as Map)
          : const <String, dynamic>{};
      final name = _cleanRemoteText(_readString(character['name']));
      if (name.isEmpty) {
        continue;
      }
      final role = _cleanRemoteText(_readString(entry['role']));
      cast.add(role.isEmpty ? name : '$name | $role');
      if (cast.length >= 10) {
        break;
      }
    }
    return cast;
  }

  Future<_SeriesVisuals?> _safeFetchTmdbVisuals(
      RemoteSearchCandidate candidate) async {
    try {
      return await _fetchTmdbVisuals(candidate);
    } catch (error) {
      _debugResolver('tmdb visuals failed: $error');
      return null;
    }
  }

  Future<_SeriesVisuals?> _fetchTmdbVisuals(
      RemoteSearchCandidate candidate) async {
    final mediaType = _candidateLooksMovie(candidate) ? 'movie' : 'tv';
    if (mediaType == 'tv' && _candidateLooksStandalonePilot(candidate)) {
      return null;
    }
    final match = await _findBestTmdbMatch(candidate, mediaType);
    if (match == null) {
      return null;
    }

    final append = mediaType == 'movie'
        ? 'release_dates,external_ids,videos,credits'
        : 'content_ratings,external_ids,videos,aggregate_credits';
    final details = await _fetchTmdbJsonObject(
      '/3/$mediaType/${match.id}',
      params: {
        'language': 'es-MX',
        'append_to_response': append,
      },
    );
    if (details == null) {
      return null;
    }
    final detailsYear = _extractYearFromText(_readString(
      details[mediaType == 'movie' ? 'release_date' : 'first_air_date'],
    ));
    if (!_isCompatibleTmdbMatchYearForCandidate(candidate, detailsYear)) {
      return null;
    }

    final images = await _fetchTmdbJsonObject(
          '/3/$mediaType/${match.id}/images',
          params: {'include_image_language': 'ja,es,en,null'},
        ) ??
        const <String, dynamic>{};
    final externalIds = details['external_ids'] is Map
        ? Map<String, dynamic>.from(details['external_ids'] as Map)
        : const <String, dynamic>{};
    final posterPath = _readString(details['poster_path']);
    final backdropPath = _readString(details['backdrop_path']);
    final detailsPosterUrl = _tmdbImageUrl(posterPath, 'w500');
    final detailsBackdropUrl = _tmdbImageUrl(backdropPath, 'w1280');
    final tmdbPosterAssetUrl =
        _pickTmdbImageAsset(images, 'posters', preferJapanese: true);
    final tmdbBackdropAssetUrl = _pickTmdbImageAsset(images, 'backdrops');
    final explicitSeasonNumber =
        mediaType == 'tv' ? _explicitSeasonNumberForCandidate(candidate) : 0;
    final seasonNumber = mediaType == 'tv'
        ? _pickBestTmdbSeasonNumber(
            details,
            releaseYear: candidate.releaseYear,
            expectedEpisodeCount: candidate.episodeCount,
            explicitSeasonNumber: explicitSeasonNumber,
          )
        : 0;
    final seasonPosterUrl = mediaType == 'tv' && seasonNumber > 0
        ? await _fetchTmdbSeasonPosterUrl(match.id, details, seasonNumber)
        : '';
    final fanartVisuals = mediaType == 'movie'
        ? await _fetchFanartMovieVisuals(match.id)
        : await _fetchFanartSeriesVisuals(
            _readInt(externalIds['tvdb_id']),
            seasonNumber: seasonNumber,
          );
    final episodes = mediaType == 'tv' && seasonNumber > 0
        ? await _fetchTmdbSeriesEpisodes(
            match.id,
            details,
            primarySeasonNumber: seasonNumber,
            expectedEpisodeCount: candidate.episodeCount,
            explicitSeasonNumber: explicitSeasonNumber,
            explicitSeasonOnly: explicitSeasonNumber > 0,
          )
        : _buildTmdbMovieEpisodeMetadata(
            details,
            imageUrl: _firstNonEmpty([detailsBackdropUrl, detailsPosterUrl]),
          );

    return _SeriesVisuals(
      title: _firstNonEmpty([
        _readString(details[mediaType == 'movie' ? 'title' : 'name']),
        match.title,
      ]),
      originalTitle: _firstNonEmpty([
        _readString(
            details[mediaType == 'movie' ? 'original_title' : 'original_name']),
        match.originalTitle,
      ]),
      logoUrl: _firstNonEmpty([
        _pickTmdbLogo(images),
        fanartVisuals?.logoUrl ?? '',
      ]),
      imageUrl: _firstNonEmpty([
        seasonPosterUrl,
        tmdbPosterAssetUrl,
        fanartVisuals?.imageUrl ?? '',
        detailsPosterUrl,
        match.imageUrl,
      ]),
      backgroundUrl: _firstNonEmpty([
        tmdbBackdropAssetUrl,
        detailsBackdropUrl,
        fanartVisuals?.backgroundUrl ?? '',
        match.backgroundUrl,
      ]),
      description: _cleanRemoteText(_readString(details['overview'])),
      trailerUrl: _pickTmdbTrailerUrl(details),
      rating: _extractTmdbRating(details, mediaType),
      cast: mediaType == 'movie'
          ? _buildTmdbMovieCast(details)
          : _buildTmdbSeriesCast(details),
      episodes: episodes,
    );
  }

  int _explicitSeasonNumberForCandidate(RemoteSearchCandidate candidate) {
    final seasonTexts = [
      candidate.title,
      candidate.japaneseTitle,
      ...candidate.aliases,
      candidate.format,
      candidate.watchUrl,
      candidate.seriesUrl,
    ]
        .map(_normalizeMatchText)
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    final text = seasonTexts.join(' ');
    final patterns = [
      RegExp(r'(?:season|temporada|temp)\s*([0-9]{1,2})'),
      RegExp(r'\b([0-9]{1,2})(?:st|nd|rd|th)\s+season\b'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      final value = match == null ? 0 : int.tryParse(match.group(1) ?? '') ?? 0;
      if (value > 1 && value <= 30) {
        return value;
      }
    }
    const japaneseSeasonWords = {
      'ni no shou': 2,
      'san no shou': 3,
      'yon no shou': 4,
      'shi no shou': 4,
      'go no shou': 5,
      'roku no shou': 6,
    };
    for (final entry in japaneseSeasonWords.entries) {
      if (text.contains(entry.key)) {
        return entry.value;
      }
    }
    for (final entry in seasonTexts) {
      final romanSeason = _romanSeasonSuffixNumber(entry);
      if (romanSeason > 1) {
        return romanSeason;
      }
    }
    return 0;
  }

  Future<String> _fetchTmdbSeasonPosterUrl(
    int seriesId,
    Map<String, dynamic> details,
    int seasonNumber,
  ) async {
    if (seriesId > 0 && seasonNumber > 0) {
      final images = await _fetchTmdbJsonObject(
        '/3/tv/$seriesId/season/$seasonNumber/images',
        params: {'include_image_language': 'ja,es,en,null'},
      );
      final posterUrl = _pickTmdbImageAsset(
        images ?? const <String, dynamic>{},
        'posters',
        preferJapanese: true,
      );
      if (posterUrl.isNotEmpty) {
        return posterUrl;
      }
    }
    final seasons = details['seasons'];
    if (seasons is! List || seasonNumber <= 0) {
      return '';
    }
    for (final rawSeason in seasons) {
      if (rawSeason is! Map) {
        continue;
      }
      final season = Map<String, dynamic>.from(rawSeason);
      if (_readInt(season['season_number']) != seasonNumber) {
        continue;
      }
      return _tmdbImageUrl(_readString(season['poster_path']), 'w500');
    }
    return '';
  }

  Future<_TmdbMatch?> _findBestTmdbMatch(
    RemoteSearchCandidate candidate,
    String mediaType,
  ) async {
    final forcedMatch = _forcedTmdbMatchForCandidate(candidate, mediaType);
    if (forcedMatch != null) {
      return forcedMatch;
    }

    _TmdbMatch? bestMatch;
    var bestScore = -100000;
    final animeKeywordById = <int, bool>{};
    final queries = _buildTmdbLookupQueries(candidate);
    for (var queryIndex = 0; queryIndex < queries.length; queryIndex += 1) {
      final query = queries[queryIndex];
      for (final searchParams in _tmdbSearchParamSets(candidate, mediaType)) {
        final params = <String, String>{
          'query': query,
          'include_adult': 'false',
          'language': 'es-MX',
          ...searchParams,
        };
        final payload =
            await _fetchTmdbJsonObject('/3/search/$mediaType', params: params);
        final results = payload?['results'];
        if (results is! List) {
          continue;
        }
        for (final rawResult in results) {
          if (rawResult is! Map) {
            continue;
          }
          final result = Map<String, dynamic>.from(rawResult);
          final id = _readInt(result['id']);
          if (id <= 0) {
            continue;
          }
          final title = _firstNonEmpty([
            _readString(result[mediaType == 'movie' ? 'title' : 'name']),
            _readString(
                result[mediaType == 'movie' ? 'name' : 'original_name']),
          ]);
          final originalTitle = _readString(result[
              mediaType == 'movie' ? 'original_title' : 'original_name']);
          final matchYear = _extractYearFromText(_readString(result[
              mediaType == 'movie' ? 'release_date' : 'first_air_date']));
          if (!_isCompatibleTmdbMatchYearForCandidate(candidate, matchYear)) {
            continue;
          }
          final match = _TmdbMatch(
            id: id,
            title: title,
            originalTitle: originalTitle,
            releaseYear: matchYear,
            imageUrl: _tmdbImageUrl(_readString(result['poster_path']), 'w500'),
            backgroundUrl:
                _tmdbImageUrl(_readString(result['backdrop_path']), 'w1280'),
          );
          var score = _scoreTmdbMatch(
                query: query,
                candidate: candidate,
                match: match,
              ) +
              max(0, 8 - queryIndex) * 25;
          // TMDB's Animation genre is broader than anime and also appears on
          // mixed/live-action records. For close title/year matches, use the
          // explicit `anime` keyword as the discriminator instead.
          if (score >= 1000) {
            final hasAnimeKeyword = animeKeywordById[id] ??
                await _tmdbHasAnimeKeyword(id, mediaType);
            animeKeywordById[id] = hasAnimeKeyword;
            if (hasAnimeKeyword) {
              score += 1200;
            }
          }
          if (score > bestScore) {
            bestScore = score;
            bestMatch = match;
          }
        }
      }
    }
    return bestScore <= 0 ? null : bestMatch;
  }

  Future<bool> _tmdbHasAnimeKeyword(int id, String mediaType) async {
    final payload = await _fetchTmdbJsonObject('/3/$mediaType/$id/keywords');
    final rawKeywords = payload?[mediaType == 'movie' ? 'keywords' : 'results'];
    if (rawKeywords is! List) {
      return false;
    }
    return rawKeywords.whereType<Map>().any((rawKeyword) {
      return _normalizeMatchText(_readString(rawKeyword['name'])) == 'anime';
    });
  }

  _TmdbMatch? _forcedTmdbMatchForCandidate(
    RemoteSearchCandidate candidate,
    String mediaType,
  ) {
    if (mediaType != 'tv') {
      return null;
    }
    final baseTerms = <String>{
      candidate.title,
      candidate.japaneseTitle,
      ...candidate.aliases,
    }
        .expand((term) {
          final cleaned = _cleanRemoteText(term);
          final stripped = _stripSeasonQualifier(cleaned);
          return [
            _normalizeMatchText(cleaned),
            if (stripped.isNotEmpty) _normalizeMatchText(stripped),
          ];
        })
        .where((entry) => entry.isNotEmpty)
        .toSet();
    final isOshiNoKo = baseTerms.any((term) {
      return term == 'oshi no ko' ||
          term == 'oshinoko' ||
          term.contains('oshi no ko');
    });
    if (isOshiNoKo) {
      return const _TmdbMatch(
        id: 203737,
        title: 'Oshi no Ko',
        originalTitle: '【推しの子】',
        releaseYear: 2023,
        imageUrl: '',
        backgroundUrl: '',
      );
    }
    final isFireForce = baseTerms.any((term) {
      return term == 'fire force' ||
          term.contains('fire force') ||
          term.contains('enen no shouboutai') ||
          term.contains('enen no shobotai');
    });
    if (isFireForce) {
      return const _TmdbMatch(
        id: 88046,
        title: 'Fire Force',
        originalTitle: 'Enen no Shouboutai',
        releaseYear: 2019,
        imageUrl: '',
        backgroundUrl: '',
      );
    }
    // TMDB has an identically named live-action entry (110397) with a nearby
    // air date. The anime record is 77237 and carries the `anime` keyword.
    final isWakakoZake = baseTerms.any((term) {
      return term == 'wakako zake' || term.contains('wakako zake');
    });
    if (isWakakoZake) {
      return const _TmdbMatch(
        id: 77237,
        title: 'Wakako-zake',
        originalTitle: 'ワカコ酒',
        releaseYear: 2015,
        imageUrl: '',
        backgroundUrl: '',
      );
    }
    final releaseYear = candidate.releaseYear;
    if (releaseYear < 1985 || releaseYear > 1990) {
      return null;
    }
    final terms = <String>{
      candidate.title,
      candidate.japaneseTitle,
      ...candidate.aliases,
    }.map(_normalizeMatchText).where((entry) => entry.isNotEmpty);
    final isClassicSaintSeiya = terms.any((term) {
      return term == 'saint seiya' ||
          term.contains('saint seiya') ||
          (term.contains('caballeros') && term.contains('zodiaco')) ||
          (term.contains('knights') && term.contains('zodiac'));
    });
    if (!isClassicSaintSeiya) {
      return null;
    }
    return const _TmdbMatch(
      id: 42444,
      title: 'Saint Seiya',
      originalTitle: 'Saint Seiya',
      releaseYear: 1986,
      imageUrl: '',
      backgroundUrl: '',
    );
  }

  List<Map<String, String>> _tmdbSearchParamSets(
    RemoteSearchCandidate candidate,
    String mediaType,
  ) {
    final releaseYear = candidate.releaseYear;
    if (releaseYear <= 0) {
      return const [<String, String>{}];
    }
    final year = '$releaseYear';
    if (mediaType == 'movie') {
      return [
        {'year': year},
        const <String, String>{},
      ];
    }
    return [
      {'first_air_date_year': year},
      {'year': year},
      const <String, String>{},
    ];
  }

  bool _isCompatibleTmdbMatchYearForCandidate(
    RemoteSearchCandidate candidate,
    int matchYear,
  ) {
    final requestedYear = candidate.releaseYear;
    if (requestedYear <= 0 || matchYear <= 0) {
      return true;
    }
    if ((candidate.provider == RemoteProvider.catalog ||
            _explicitSeasonNumberForCandidate(candidate) > 1 ||
            _candidateHasSeasonQualifier(candidate)) &&
        matchYear <= requestedYear) {
      return (requestedYear - matchYear).abs() <= 12;
    }
    return (requestedYear - matchYear).abs() <= 2;
  }

  bool _candidateHasSeasonQualifier(RemoteSearchCandidate candidate) {
    final seasonTexts = [
      candidate.title,
      candidate.japaneseTitle,
      ...candidate.aliases,
      candidate.format,
      candidate.watchUrl,
      candidate.seriesUrl,
    ]
        .map(_normalizeMatchText)
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    final text = seasonTexts.join(' ');
    if (text.contains('season') ||
        text.contains('temporada') ||
        text.contains('part')) {
      return true;
    }
    if (seasonTexts.any((entry) => _romanSeasonSuffixNumber(entry) > 1)) {
      return true;
    }
    return const [
      'ni no shou',
      'san no shou',
      'yon no shou',
      'shi no shou',
      'go no shou',
      'roku no shou',
    ].any(text.contains);
  }

  List<String> _buildTmdbLookupQueries(RemoteSearchCandidate candidate) {
    final queries = <String>{};
    for (final raw in [
      candidate.title,
      candidate.japaneseTitle,
      ...candidate.aliases,
    ]) {
      final cleaned = _cleanRemoteText(raw);
      if (cleaned.isEmpty) {
        continue;
      }
      queries.add(cleaned);
      final baseSeasonTitle = _stripSeasonQualifier(cleaned);
      if (baseSeasonTitle.isNotEmpty) {
        queries.add(baseSeasonTitle);
      }
      final romanBaseSeasonTitle = _stripRomanSeasonSuffix(cleaned);
      if (romanBaseSeasonTitle.isNotEmpty) {
        queries.add(romanBaseSeasonTitle);
      }
    }
    return queries.toList();
  }

  bool _candidateLooksStandalonePilot(RemoteSearchCandidate candidate) {
    final terms = [
      candidate.title,
      candidate.japaneseTitle,
      ...candidate.aliases,
      candidate.format,
    ].map(_normalizeMatchText).where((entry) => entry.isNotEmpty);
    return terms.any((term) => _tokenize(term).contains('pilot'));
  }

  String _stripSeasonQualifier(String value) {
    var normalized = value
        .replaceAll(
          RegExp(
            r'\b(?:season|temporada|temp)\s*[0-9ivxlcdm]{1,6}\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b[0-9]{1,2}(?:st|nd|rd|th)\s+season\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b(?:ni|san|yon|shi|go|roku)\s+no\s+shou\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(r'\bpart\s*[0-9]{1,2}\b', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'\b(?:ii|iii|iv|v|vi|vii|viii|ix|x)\b\s*$',
              caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized == value.trim()) {
      return '';
    }
    return normalized;
  }

  int _romanSeasonSuffixNumber(String normalizedText) {
    final match = RegExp(r'\b(ii|iii|iv|v|vi|vii|viii|ix|x)\b$')
        .firstMatch(normalizedText.trim().toLowerCase());
    if (match == null) {
      return 0;
    }
    return switch (match.group(1)) {
      'ii' => 2,
      'iii' => 3,
      'iv' => 4,
      'v' => 5,
      'vi' => 6,
      'vii' => 7,
      'viii' => 8,
      'ix' => 9,
      'x' => 10,
      _ => 0,
    };
  }

  String _stripRomanSeasonSuffix(String value) {
    final parts = value
        .trim()
        .split(RegExp(r'[^A-Za-z0-9]+'))
        .where((entry) => entry.trim().isNotEmpty)
        .toList(growable: false);
    if (parts.length < 2) {
      return '';
    }
    final season = _romanSeasonSuffixNumber(parts.last);
    if (season <= 1) {
      return '';
    }
    return parts.take(parts.length - 1).join(' ');
  }

  int _scoreTmdbMatch({
    required String query,
    required RemoteSearchCandidate candidate,
    required _TmdbMatch match,
  }) {
    final requested = _normalizeMatchText(query);
    if (requested.isEmpty) {
      return 0;
    }
    var score = 0;
    final requestedTokens = _tokenize(requested);
    for (final rawTitle in [match.title, match.originalTitle]) {
      final title = _normalizeMatchText(rawTitle);
      if (title.isEmpty) {
        continue;
      }
      if (title == requested) {
        score = score < 1200 ? 1200 : score;
      } else if (title.contains(requested) || requested.contains(title)) {
        score = score < 620 ? 620 : score;
      }
      final overlap = requestedTokens.intersection(_tokenize(title)).length;
      score += overlap * 120;
    }
    if (candidate.releaseYear > 0 && match.releaseYear > 0) {
      final diff = (candidate.releaseYear - match.releaseYear).abs();
      if (diff > 2) {
        if (_explicitSeasonNumberForCandidate(candidate) <= 1 ||
            match.releaseYear > candidate.releaseYear ||
            diff > 12) {
          return 0;
        }
        score += max(20, 220 - diff * 30);
      } else {
        score += switch (diff) {
          0 => 520,
          1 => 160,
          2 => 40,
          _ => 0,
        };
      }
    } else if (candidate.releaseYear > 0 && match.releaseYear <= 0) {
      score -= 120;
    }
    return score;
  }

  Future<_SeriesVisuals?> _fetchFanartSeriesVisuals(
    int tvdbId, {
    int seasonNumber = 0,
  }) async {
    if (!_isFanartConfigured() || tvdbId <= 0) {
      return null;
    }
    final json = await _fetchFanartJsonObject('/v3/tv/$tvdbId');
    if (json == null) {
      return null;
    }
    return _SeriesVisuals(
      logoUrl: _pickFanartAsset(json, const ['hdtvlogo', 'clearlogo'],
          preferJapanese: true),
      imageUrl: _firstNonEmpty([
        _pickFanartAsset(json, const ['seasonposter'],
            seasonNumber: seasonNumber),
        _pickFanartAsset(json, const ['tvposter']),
      ]),
      backgroundUrl: _firstNonEmpty([
        _pickFanartAsset(json, const ['showbackground', 'tvbanner', 'tvthumb']),
        _pickFanartAsset(json, const ['seasonbanner'],
            seasonNumber: seasonNumber),
      ]),
    );
  }

  Future<_SeriesVisuals?> _fetchFanartMovieVisuals(int tmdbId) async {
    if (!_isFanartConfigured() || tmdbId <= 0) {
      return null;
    }
    final json = await _fetchFanartJsonObject('/v3/movies/$tmdbId');
    if (json == null) {
      return null;
    }
    final visuals = _SeriesVisuals(
      logoUrl: _pickFanartAsset(json, const ['hdmovielogo', 'movielogo'],
          preferJapanese: true),
      imageUrl: _pickFanartAsset(json, const ['movieposter', 'moviethumb']),
      backgroundUrl: _pickFanartAsset(
          json, const ['moviebackground', 'moviethumb', 'moviebanner']),
    );
    return visuals.hasMeaningfulContent ? visuals : null;
  }

  Future<Map<String, dynamic>?> _fetchFanartJsonObject(String path) async {
    final response = await _get(
      Uri.https('webservice.fanart.tv', path, {'api_key': _fanartApiKey}),
      headers: const {'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    return _decodeJsonObject(response.body);
  }

  String _pickFanartAsset(
    Map<String, dynamic> json,
    List<String> keys, {
    int seasonNumber = 0,
    bool preferJapanese = false,
  }) {
    var bestUrl = '';
    var bestScore = -100000;
    final rejectSvg = keys.any((key) => key.contains('logo'));
    for (var keyIndex = 0; keyIndex < keys.length; keyIndex += 1) {
      final assets = json[keys[keyIndex]];
      if (assets is! List) {
        continue;
      }
      for (final rawAsset in assets) {
        if (rawAsset is! Map) {
          continue;
        }
        final asset = Map<String, dynamic>.from(rawAsset);
        final url = _cleanRemoteUrl(_readString(asset['url']));
        if (url.isEmpty || (rejectSvg && _isSvgAssetUrl(url))) {
          continue;
        }
        final assetSeason = _readInt(asset['season']);
        if (seasonNumber > 0 &&
            assetSeason > 0 &&
            assetSeason != seasonNumber) {
          continue;
        }
        final language = _readString(asset['lang']).toLowerCase();
        final likes = _readInt(asset['likes']);
        var score = (keys.length - keyIndex) * 100;
        score += _languageScore(language, preferJapanese: preferJapanese);
        score += likes.clamp(0, 1000).toInt() * 3;
        if (score > bestScore) {
          bestScore = score;
          bestUrl = url;
        }
      }
    }
    return bestUrl;
  }

  Future<Map<String, dynamic>?> _fetchTmdbJsonObject(
    String path, {
    Map<String, String> params = const {},
  }) async {
    final response = await _getTmdb(path, params: params);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    return _decodeJsonObject(response.body);
  }

  Future<http.Response> _getTmdb(
    String path, {
    Map<String, String> params = const {},
  }) async {
    final uri = _tmdbUri(path, params);
    final headers = <String, String>{
      'Accept': 'application/json',
      if (_tmdbBearerToken.isNotEmpty)
        'Authorization': 'Bearer $_tmdbBearerToken',
    };
    final response = await _get(uri, headers: headers);
    if (response.statusCode != 401 ||
        _tmdbBearerToken.isEmpty ||
        _tmdbApiKey.isEmpty) {
      return response;
    }
    return _get(uri, headers: const {'Accept': 'application/json'});
  }

  Uri _tmdbUri(String path, Map<String, String> params) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final query = <String, String>{...params};
    if (_tmdbApiKey.isNotEmpty) {
      query['api_key'] = _tmdbApiKey;
    }
    return Uri.https('api.themoviedb.org', normalizedPath, query);
  }

  Map<String, dynamic>? _decodeJsonObject(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  String _pickTmdbLogo(Map<String, dynamic> images) {
    final logos = images['logos'];
    if (logos is! List) {
      return '';
    }
    final candidates = <({String language, String url, int score})>[];
    for (final rawLogo in logos) {
      if (rawLogo is! Map) {
        continue;
      }
      final logo = Map<String, dynamic>.from(rawLogo);
      final filePath = _readString(logo['file_path']);
      if (filePath.isEmpty || _isSvgAssetUrl(filePath)) {
        continue;
      }
      final language = _readString(logo['iso_639_1']).toLowerCase();
      var score = 0;
      score += _readInt(logo['vote_count']) * 5;
      score += (_readInt(logo['width']) / 50).round();
      candidates.add((
        language: language,
        url: _tmdbImageUrl(filePath, 'original'),
        score: score,
      ));
    }
    const languagePriority = [
      {'ja', 'ja-jp', 'jp'},
      {'es', 'es-mx'},
      {'en'},
      {'', 'null', 'xx', '00'},
      <String>{},
    ];
    for (final accepted in languagePriority) {
      final group = candidates.where((candidate) {
        if (accepted.isEmpty) {
          return !languagePriority
              .take(languagePriority.length - 1)
              .any((group) => group.contains(candidate.language));
        }
        return accepted.contains(candidate.language);
      }).toList();
      if (group.isEmpty) {
        continue;
      }
      group.sort((left, right) => right.score.compareTo(left.score));
      return group.first.url;
    }
    return '';
  }

  String _pickTmdbImageAsset(
    Map<String, dynamic> images,
    String key, {
    bool preferJapanese = false,
  }) {
    final assets = images[key];
    if (assets is! List) {
      return '';
    }
    final candidates = <({String language, String url, int score})>[];
    for (final rawAsset in assets) {
      if (rawAsset is! Map) {
        continue;
      }
      final asset = Map<String, dynamic>.from(rawAsset);
      final filePath = _readString(asset['file_path']);
      if (filePath.isEmpty) {
        continue;
      }
      final voteAverage = (_readDouble(asset['vote_average']) * 100).round();
      final voteCount = _readInt(asset['vote_count']);
      final width = _readInt(asset['width']);
      final height = _readInt(asset['height']);
      final language = _readString(asset['iso_639_1']).toLowerCase();
      final score = voteAverage + voteCount * 3 + width ~/ 25 + height ~/ 40;
      candidates.add((
        language: language,
        url: _tmdbImageUrl(filePath, 'original'),
        score: score,
      ));
    }
    if (candidates.isEmpty) {
      return '';
    }
    if (!preferJapanese) {
      candidates.sort((left, right) => right.score.compareTo(left.score));
      return candidates.first.url;
    }
    const languagePriority = [
      {'ja', 'ja-jp', 'jp'},
      {'es', 'es-mx'},
      {'en'},
      {'', 'null', 'xx', '00'},
      <String>{},
    ];
    for (final accepted in languagePriority) {
      final group = candidates.where((candidate) {
        if (accepted.isEmpty) {
          return !languagePriority
              .take(languagePriority.length - 1)
              .any((group) => group.contains(candidate.language));
        }
        return accepted.contains(candidate.language);
      }).toList();
      if (group.isEmpty) {
        continue;
      }
      group.sort((left, right) => right.score.compareTo(left.score));
      return group.first.url;
    }
    return '';
  }

  int _languageScore(String language, {required bool preferJapanese}) {
    final normalized = language.trim().toLowerCase();
    if (preferJapanese) {
      return switch (normalized) {
        'ja' || 'jp' => 260,
        'es' => 240,
        'en' => 220,
        'xx' || '00' || '' || 'null' => 190,
        _ => 120,
      };
    }
    return switch (normalized) {
      'es' => 260,
      'ja' || 'jp' => 240,
      'en' => 220,
      'xx' || '00' || '' || 'null' => 190,
      _ => 120,
    };
  }

  String _tmdbImageUrl(String path, String size) {
    final normalized = _cleanRemoteUrl(path);
    if (normalized.isEmpty) {
      return '';
    }
    if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
      return normalized;
    }
    final cleanSize = size.trim().isEmpty ? 'original' : size.trim();
    return '$_tmdbImageBaseUrl/$cleanSize${normalized.startsWith('/') ? normalized : '/$normalized'}';
  }

  String _pickTmdbTrailerUrl(Map<String, dynamic> details) {
    final videos = details['videos'];
    final results = videos is Map ? videos['results'] : null;
    if (results is! List) {
      return '';
    }
    var bestKey = '';
    var bestScore = -100000;
    for (final rawVideo in results) {
      if (rawVideo is! Map) {
        continue;
      }
      final video = Map<String, dynamic>.from(rawVideo);
      final site = _readString(video['site']).toLowerCase();
      final key = _readString(video['key']);
      if (site != 'youtube' || key.isEmpty) {
        continue;
      }
      final type = _readString(video['type']).toLowerCase();
      final language = _readString(video['iso_639_1']).toLowerCase();
      var score = type == 'trailer'
          ? 500
          : type == 'teaser'
              ? 320
              : 120;
      score += _languageScore(language, preferJapanese: false);
      if (video['official'] == true) {
        score += 90;
      }
      if (score > bestScore) {
        bestScore = score;
        bestKey = key;
      }
    }
    return bestKey.isEmpty ? '' : 'https://www.youtube.com/watch?v=$bestKey';
  }

  String _extractTmdbRating(Map<String, dynamic> details, String mediaType) {
    if (mediaType == 'tv') {
      final ratings = details['content_ratings'];
      final results = ratings is Map ? ratings['results'] : null;
      return _pickTmdbCertification(results, countryKey: 'iso_3166_1');
    }
    final releaseDates = details['release_dates'];
    final results = releaseDates is Map ? releaseDates['results'] : null;
    if (results is! List) {
      return '';
    }
    final countryResults = <String, List<Map<String, dynamic>>>{};
    for (final rawEntry in results) {
      if (rawEntry is! Map) {
        continue;
      }
      final entry = Map<String, dynamic>.from(rawEntry);
      final country = _readString(entry['iso_3166_1']);
      final releases = entry['release_dates'];
      if (releases is List) {
        countryResults[country] = releases
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      }
    }
    for (final country in const ['US', 'JP', 'MX', 'ES']) {
      final releases = countryResults[country] ?? const [];
      for (final release in releases) {
        final certification = _readString(release['certification']);
        if (certification.isNotEmpty) {
          return certification;
        }
      }
    }
    for (final releases in countryResults.values) {
      for (final release in releases) {
        final certification = _readString(release['certification']);
        if (certification.isNotEmpty) {
          return certification;
        }
      }
    }
    return '';
  }

  String _pickTmdbCertification(Object? results, {required String countryKey}) {
    if (results is! List) {
      return '';
    }
    final entries = results
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
    for (final country in const ['US', 'JP', 'MX', 'ES']) {
      final match = entries.firstWhere(
        (entry) => _readString(entry[countryKey]) == country,
        orElse: () => const {},
      );
      final rating = _readString(match['rating']);
      if (rating.isNotEmpty) {
        return rating;
      }
    }
    for (final entry in entries) {
      final rating = _readString(entry['rating']);
      if (rating.isNotEmpty) {
        return rating;
      }
    }
    return '';
  }

  Map<int, SeriesEpisodeMetadata> _episodeMetadataByNumber(
    List<SeriesEpisodeMetadata> details,
  ) {
    return {
      for (final detail in details)
        if (detail.episodeNumber >= 0) detail.episodeNumber: detail,
    };
  }

  EpisodeItem _applyEpisodeMetadata(
    EpisodeItem episode,
    SeriesEpisodeMetadata? detail, {
    required String fallbackImageUrl,
  }) {
    if (detail == null) {
      return episode;
    }
    final title = _cleanRemoteText(detail.title);
    return episode.copyWith(
      displayName: title.isNotEmpty ? title : episode.displayName,
      imageUrl: _firstNonEmpty([
        detail.imageUrl,
        episode.imageUrl,
        fallbackImageUrl,
      ]),
      description: detail.description,
      airDateIso: detail.airDateIso,
      durationLabel: detail.durationLabel,
    );
  }

  int _pickBestTmdbSeasonNumber(
    Map<String, dynamic> details, {
    required int releaseYear,
    required int expectedEpisodeCount,
    int explicitSeasonNumber = 0,
  }) {
    final seasons = details['seasons'];
    if (seasons is! List || seasons.isEmpty) {
      return 1;
    }
    if (explicitSeasonNumber > 0) {
      for (final rawSeason in seasons) {
        if (rawSeason is! Map) {
          continue;
        }
        final number =
            _readInt(Map<String, dynamic>.from(rawSeason)['season_number']);
        if (number == explicitSeasonNumber) {
          return explicitSeasonNumber;
        }
      }
    }
    var bestSeason = 0;
    var bestScore = -100000;
    for (final rawSeason in seasons) {
      if (rawSeason is! Map) {
        continue;
      }
      final season = Map<String, dynamic>.from(rawSeason);
      final number = _readInt(season['season_number']);
      if (number <= 0) {
        continue;
      }
      final episodeCount = _readInt(season['episode_count']);
      final airYear = _extractYearFromText(_readString(season['air_date']));
      var score = number == 1 ? 80 : 0;
      if (expectedEpisodeCount > 0 && episodeCount > 0) {
        final diff = (episodeCount - expectedEpisodeCount).abs();
        score += switch (diff) {
          0 => 520,
          1 => 180,
          2 => 80,
          _ => -diff * 30,
        };
      }
      if (releaseYear > 0 && airYear > 0) {
        final diff = (airYear - releaseYear).abs();
        score += switch (diff) {
          0 => 360,
          1 => 100,
          _ => -diff * 45,
        };
      }
      if (score > bestScore) {
        bestScore = score;
        bestSeason = number;
      }
    }
    return bestSeason > 0 ? bestSeason : 1;
  }

  Future<List<SeriesEpisodeMetadata>> _fetchTmdbSeriesEpisodes(
    int seriesId,
    Map<String, dynamic> details, {
    required int primarySeasonNumber,
    required int expectedEpisodeCount,
    int explicitSeasonNumber = 0,
    bool explicitSeasonOnly = false,
  }) async {
    final primary =
        await _fetchTmdbSeasonEpisodes(seriesId, primarySeasonNumber);
    final flattenedSeason = _pickFlattenedTmdbSeasonSegment(
      primary,
      expectedEpisodeCount: expectedEpisodeCount,
      explicitSeasonNumber: explicitSeasonNumber,
      primarySeasonNumber: primarySeasonNumber,
    );
    if (flattenedSeason.isNotEmpty) {
      return flattenedSeason;
    }
    if (explicitSeasonOnly) {
      return primary;
    }
    final targetCount = expectedEpisodeCount > 0 ? expectedEpisodeCount : 0;
    if (targetCount <= 0 || primary.length >= targetCount) {
      return primary;
    }
    final seasons = details['seasons'];
    if (seasons is! List) {
      return primary;
    }
    final seasonNumbers = <int>[];
    for (final rawSeason in seasons) {
      if (rawSeason is! Map) {
        continue;
      }
      final number =
          _readInt(Map<String, dynamic>.from(rawSeason)['season_number']);
      if (number > 0) {
        seasonNumbers.add(number);
      }
    }
    seasonNumbers.sort();
    if (seasonNumbers.length <= 1) {
      return primary;
    }
    final collected = <SeriesEpisodeMetadata>[];
    for (final seasonNumber in seasonNumbers) {
      final seasonEpisodes = seasonNumber == primarySeasonNumber
          ? primary
          : await _fetchTmdbSeasonEpisodes(seriesId, seasonNumber);
      if (seasonEpisodes.isEmpty) {
        continue;
      }
      final offset = collected.length;
      for (final episode in seasonEpisodes) {
        collected.add(_renumberTmdbEpisodeMetadata(
          episode,
          offset + episode.episodeNumber,
        ));
      }
      if (targetCount > 0 && collected.length >= targetCount) {
        break;
      }
    }
    return collected.length > primary.length ? collected : primary;
  }

  List<SeriesEpisodeMetadata> _pickFlattenedTmdbSeasonSegment(
    List<SeriesEpisodeMetadata> primary, {
    required int expectedEpisodeCount,
    required int explicitSeasonNumber,
    required int primarySeasonNumber,
  }) {
    if (primarySeasonNumber != 1 ||
        explicitSeasonNumber <= 1 ||
        expectedEpisodeCount <= 0 ||
        primary.length <= expectedEpisodeCount) {
      return const [];
    }
    final startIndex = (explicitSeasonNumber - 1) * expectedEpisodeCount;
    final endIndex = startIndex + expectedEpisodeCount;
    if (startIndex < 0 || endIndex > primary.length) {
      return const [];
    }
    return [
      for (var index = startIndex; index < endIndex; index += 1)
        _renumberTmdbEpisodeMetadata(
          primary[index],
          index - startIndex + 1,
        ),
    ];
  }

  SeriesEpisodeMetadata _renumberTmdbEpisodeMetadata(
    SeriesEpisodeMetadata episode,
    int episodeNumber,
  ) {
    return SeriesEpisodeMetadata(
      episodeNumber: episodeNumber,
      title: episode.title,
      description: episode.description,
      imageUrl: episode.imageUrl,
      durationLabel: episode.durationLabel,
      airDateIso: episode.airDateIso,
    );
  }

  Future<List<SeriesEpisodeMetadata>> _fetchTmdbSeasonEpisodes(
    int seriesId,
    int seasonNumber,
  ) async {
    if (seriesId <= 0 || seasonNumber <= 0) {
      return const [];
    }
    final payload = await _fetchTmdbJsonObject(
      '/3/tv/$seriesId/season/$seasonNumber',
      params: const {'language': 'es-MX'},
    );
    final episodes = payload?['episodes'];
    if (episodes is! List) {
      return const [];
    }
    final results = <SeriesEpisodeMetadata>[];
    for (final rawEpisode in episodes) {
      if (rawEpisode is! Map) {
        continue;
      }
      final episode = Map<String, dynamic>.from(rawEpisode);
      final episodeNumber = _readInt(episode['episode_number']);
      if (episodeNumber <= 0) {
        continue;
      }
      final runtime = _readInt(episode['runtime']);
      results.add(SeriesEpisodeMetadata(
        episodeNumber: episodeNumber,
        title: _cleanRemoteText(_readString(episode['name'])),
        description: _cleanRemoteText(_readString(episode['overview'])),
        imageUrl: _tmdbImageUrl(_readString(episode['still_path']), 'w780'),
        durationLabel: runtime > 0 ? '$runtime min' : '',
        airDateIso: _cleanRemoteText(_readString(episode['air_date'])),
      ));
    }
    return results;
  }

  List<SeriesEpisodeMetadata> _buildTmdbMovieEpisodeMetadata(
    Map<String, dynamic> details, {
    required String imageUrl,
  }) {
    final runtime = _readInt(details['runtime']);
    final metadata = SeriesEpisodeMetadata(
      episodeNumber: 1,
      title: _firstNonEmpty([
        _readString(details['title']),
        _readString(details['name']),
      ]),
      description: _cleanRemoteText(_readString(details['overview'])),
      imageUrl: imageUrl,
      durationLabel: runtime > 0 ? '$runtime min' : '',
      airDateIso: _firstNonEmpty([
        _readString(details['release_date']),
        _readString(details['first_air_date']),
      ]),
    );
    return metadata.title.isEmpty &&
            metadata.description.isEmpty &&
            metadata.imageUrl.isEmpty &&
            metadata.durationLabel.isEmpty &&
            metadata.airDateIso.isEmpty
        ? const []
        : [metadata];
  }

  List<String> _buildTmdbSeriesCast(Map<String, dynamic> details) {
    final credits = details['aggregate_credits'];
    final cast = credits is Map ? credits['cast'] : null;
    if (cast is! List) {
      return const [];
    }
    final results = <String>[];
    for (final rawCast in cast) {
      if (rawCast is! Map) {
        continue;
      }
      final item = Map<String, dynamic>.from(rawCast);
      final name = _cleanRemoteText(_readString(item['name']));
      if (name.isEmpty) {
        continue;
      }
      final roles = item['roles'];
      var character = '';
      if (roles is List && roles.isNotEmpty && roles.first is Map) {
        character = _cleanRemoteText(
          _readString(
              Map<String, dynamic>.from(roles.first as Map)['character']),
        );
      }
      results.add(character.isEmpty ? name : '$name | $character');
      if (results.length >= 10) {
        break;
      }
    }
    return results;
  }

  List<String> _buildTmdbMovieCast(Map<String, dynamic> details) {
    final credits = details['credits'];
    final cast = credits is Map ? credits['cast'] : null;
    if (cast is! List) {
      return const [];
    }
    final results = <String>[];
    for (final rawCast in cast) {
      if (rawCast is! Map) {
        continue;
      }
      final item = Map<String, dynamic>.from(rawCast);
      final name = _cleanRemoteText(_readString(item['name']));
      if (name.isEmpty) {
        continue;
      }
      final character = _cleanRemoteText(_readString(item['character']));
      results.add(character.isEmpty ? name : '$name | $character');
      if (results.length >= 10) {
        break;
      }
    }
    return results;
  }

  List<String> _mergeCast(List<String> current, List<String> extra) {
    final seen = <String>{};
    final merged = <String>[];
    for (final value in [...current, ...extra]) {
      final cleaned = _cleanRemoteText(value);
      final key = _normalizeMatchText(cleaned);
      if (cleaned.isEmpty || key.isEmpty || !seen.add(key)) {
        continue;
      }
      merged.add(cleaned);
      if (merged.length >= 12) {
        break;
      }
    }
    return merged;
  }

  List<SeriesEpisodeMetadata> _mergeEpisodeMetadata(
    List<SeriesEpisodeMetadata> primary,
    List<SeriesEpisodeMetadata> supplemental,
  ) {
    final primaryByEpisode = _episodeMetadataByNumber(primary);
    final supplementalByEpisode = _episodeMetadataByNumber(supplemental);
    final supplementalByDate = _episodeMetadataByDate(supplemental);
    final supplementalOffset = _episodeMetadataDateOffset(
      primaryByEpisode,
      supplementalByEpisode,
    );
    if (supplementalOffset != 0 && primaryByEpisode.isNotEmpty) {
      final episodeNumbers = primaryByEpisode.keys.toList()..sort();
      return [
        for (final episodeNumber in episodeNumbers)
          _mergeEpisodeDetail(
            primaryByEpisode[episodeNumber],
            _mergeSupplementalEpisodeDetail(
              supplementalByEpisode[episodeNumber + supplementalOffset],
              supplementalByDate[_episodeDateKey(
                primaryByEpisode[episodeNumber]?.airDateIso ?? '',
              )],
            ),
          ),
      ];
    }
    final episodeNumbers = <int>{
      ...primaryByEpisode.keys,
      ...supplementalByEpisode.keys,
    }.toList()
      ..sort();
    return [
      for (final episodeNumber in episodeNumbers)
        _mergeEpisodeDetail(
          primaryByEpisode[episodeNumber],
          _mergeSupplementalEpisodeDetail(
            supplementalByEpisode[episodeNumber],
            supplementalByDate[_episodeDateKey(
              primaryByEpisode[episodeNumber]?.airDateIso ?? '',
            )],
          ),
        ),
    ];
  }

  Map<String, SeriesEpisodeMetadata> _episodeMetadataByDate(
    List<SeriesEpisodeMetadata> details,
  ) {
    final byDate = <String, SeriesEpisodeMetadata>{};
    for (final detail in details) {
      final key = _episodeDateKey(detail.airDateIso);
      if (key.isEmpty) {
        continue;
      }
      final current = byDate[key];
      if (current == null ||
          _episodeMetadataContentScore(detail) >
              _episodeMetadataContentScore(current)) {
        byDate[key] = detail;
      }
    }
    return byDate;
  }

  SeriesEpisodeMetadata? _mergeSupplementalEpisodeDetail(
    SeriesEpisodeMetadata? direct,
    SeriesEpisodeMetadata? dated,
  ) {
    if (direct == null) {
      return dated;
    }
    if (dated == null || identical(direct, dated)) {
      return direct;
    }
    return SeriesEpisodeMetadata(
      episodeNumber: direct.episodeNumber,
      title: direct.title.isNotEmpty ? direct.title : dated.title,
      description: direct.description.isNotEmpty
          ? direct.description
          : dated.description,
      imageUrl: direct.imageUrl.isNotEmpty ? direct.imageUrl : dated.imageUrl,
      durationLabel: direct.durationLabel.isNotEmpty
          ? direct.durationLabel
          : dated.durationLabel,
      airDateIso:
          direct.airDateIso.isNotEmpty ? direct.airDateIso : dated.airDateIso,
    );
  }

  int _episodeMetadataContentScore(SeriesEpisodeMetadata detail) {
    var score = 0;
    if (detail.imageUrl.isNotEmpty) score += 8;
    if (detail.title.isNotEmpty && !_isGenericEpisodeTitle(detail.title)) {
      score += 4;
    }
    if (detail.description.isNotEmpty) score += 2;
    if (detail.durationLabel.isNotEmpty) score += 1;
    return score;
  }

  SeriesEpisodeMetadata _mergeEpisodeDetail(
    SeriesEpisodeMetadata? primary,
    SeriesEpisodeMetadata? supplemental,
  ) {
    if (primary == null) {
      return supplemental!;
    }
    if (supplemental == null) {
      return primary;
    }
    return SeriesEpisodeMetadata(
      episodeNumber: primary.episodeNumber,
      title: primary.title.isNotEmpty && !_isGenericEpisodeTitle(primary.title)
          ? primary.title
          : supplemental.title.isNotEmpty
              ? supplemental.title
              : primary.title,
      description: primary.description.isNotEmpty
          ? primary.description
          : supplemental.description,
      imageUrl: primary.imageUrl.isNotEmpty
          ? primary.imageUrl
          : supplemental.imageUrl,
      durationLabel: primary.durationLabel.isNotEmpty
          ? primary.durationLabel
          : supplemental.durationLabel,
      airDateIso: primary.airDateIso.isNotEmpty
          ? primary.airDateIso
          : supplemental.airDateIso,
    );
  }

  bool _isGenericEpisodeTitle(String value) {
    final normalized = _normalizeMatchText(value);
    return RegExp(r'^episodio\s*[0-9]+$').hasMatch(normalized) ||
        RegExp(r'^episode\s*[0-9]+$').hasMatch(normalized);
  }

  int _episodeMetadataDateOffset(
    Map<int, SeriesEpisodeMetadata> primaryByEpisode,
    Map<int, SeriesEpisodeMetadata> supplementalByEpisode,
  ) {
    if (primaryByEpisode.isEmpty || supplementalByEpisode.isEmpty) {
      return 0;
    }
    final primaryEntries = primaryByEpisode.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    for (final primaryEntry in primaryEntries) {
      final primaryDate = _episodeDateKey(primaryEntry.value.airDateIso);
      if (primaryDate.isEmpty) {
        continue;
      }
      final direct = supplementalByEpisode[primaryEntry.key];
      if (_episodeDateKey(direct?.airDateIso ?? '') == primaryDate) {
        return 0;
      }
      for (final supplementalEntry in supplementalByEpisode.entries) {
        if (supplementalEntry.key == primaryEntry.key) {
          continue;
        }
        if (_episodeDateKey(supplementalEntry.value.airDateIso) ==
            primaryDate) {
          return supplementalEntry.key - primaryEntry.key;
        }
      }
    }
    return 0;
  }

  String _episodeDateKey(String value) {
    final normalized = value.trim();
    if (normalized.length < 10) {
      return normalized;
    }
    return normalized.substring(0, 10);
  }

  bool _isTmdbConfigured() =>
      _tmdbBearerToken.isNotEmpty || _tmdbApiKey.isNotEmpty;

  bool _isFanartConfigured() => _fanartApiKey.isNotEmpty;

  bool _candidateLooksMovie(RemoteSearchCandidate candidate) {
    final format = _normalizeMatchText(candidate.format);
    final title = _normalizeMatchText(
      '${candidate.title} ${candidate.seriesUrl} ${candidate.watchUrl}',
    );
    return format.contains('movie') ||
        format.contains('pelicula') ||
        title.contains('movie') ||
        title.contains('pelicula');
  }

  bool _seriesLooksMovie(SeriesItem series) {
    final format = _normalizeMatchText(series.format);
    final title = _normalizeMatchText(series.name);
    return format.contains('movie') ||
        format.contains('pelicula') ||
        title.contains('movie') ||
        title.contains('pelicula');
  }

  bool _isSvgAssetUrl(String value) {
    return value.trim().toLowerCase().split('?').first.endsWith('.svg');
  }

  List<String> _mergeAliases(
    List<String> current,
    List<String> extra, {
    required String title,
  }) {
    final titleKey = _normalizeMatchText(title);
    final seen = <String>{};
    final merged = <String>[];
    for (final value in [...current, ...extra]) {
      final cleaned = _cleanRemoteText(value);
      final key = _normalizeMatchText(cleaned);
      if (cleaned.isEmpty || key.isEmpty || key == titleKey || !seen.add(key)) {
        continue;
      }
      merged.add(cleaned);
    }
    return merged;
  }

  void close() {
    for (final proxy in _bilibiliDashProxies) {
      unawaited(proxy.close());
    }
    _bilibiliDashProxies.clear();
    for (final proxy in _justAnimeHlsProxies) {
      unawaited(proxy.close());
    }
    _justAnimeHlsProxies.clear();
    _client.close();
  }

  void retirePlaybackProxy(String playbackUrl) {
    final target = Uri.tryParse(playbackUrl.trim());
    if (target == null ||
        (target.host != '127.0.0.1' && target.host != 'localhost')) {
      return;
    }
    final justAnime = _justAnimeHlsProxies
        .where((proxy) => Uri.parse(proxy.playlistUrl).port == target.port)
        .toList(growable: false);
    final biliBili = _bilibiliDashProxies
        .where((proxy) => Uri.parse(proxy.manifestUrl).port == target.port)
        .toList(growable: false);
    _justAnimeHlsProxies.removeWhere(justAnime.contains);
    _bilibiliDashProxies.removeWhere(biliBili.contains);
    if (justAnime.isEmpty && biliBili.isEmpty) return;
    unawaited(Future<void>.delayed(const Duration(milliseconds: 250), () async {
      for (final proxy in justAnime) {
        await proxy.close();
      }
      for (final proxy in biliBili) {
        await proxy.close();
      }
    }));
  }

  Future<http.Response> _get(
    Uri uri, {
    String referer = '',
    Map<String, String> headers = const {},
  }) {
    final normalizedReferer = referer.trim();
    return _client.get(uri, headers: {
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'User-Agent': _defaultFetchUserAgent,
      if (normalizedReferer.isNotEmpty) 'Referer': normalizedReferer,
      if (normalizedReferer.isNotEmpty)
        'Origin': _baseOrigin(normalizedReferer),
      ...headers,
    }).timeout(const Duration(seconds: 14));
  }

  Future<http.Response> _getMyAnimeList(Uri uri) {
    return _client.get(uri, headers: {
      'Accept': 'application/json',
      'User-Agent': 'TanukiFlutter/1.0',
      'X-MAL-CLIENT-ID': _myAnimeListClientId,
    }).timeout(const Duration(seconds: 14));
  }

  Future<http.Response> _getInternetArchiveJson(Uri uri) {
    return _client.get(uri, headers: {
      'Accept': 'application/json',
      'User-Agent': _defaultFetchUserAgent,
    }).timeout(const Duration(seconds: 18));
  }

  String _buildRemoteEpisodePageUrl(EpisodeItem entry) {
    if (entry.provider == RemoteProvider.jkAnime) {
      return _buildJkAnimeRemoteEpisodePageUrl(entry);
    }
    final currentPath = entry.filePath.trim();
    if (currentPath.isNotEmpty) {
      return currentPath;
    }
    final episodeNumber = entry.episodeNumber < 1 ? 1 : entry.episodeNumber;
    return switch (entry.provider) {
      RemoteProvider.jkAnime => _buildJkAnimeEpisodeUrl(
          entry.slug,
          episodeNumber,
          movie: entry.filePath.toLowerCase().contains('/pelicula/') ||
              entry.relativePath.toLowerCase().contains('pelicula'),
        ),
      RemoteProvider.latAnime =>
        _buildLatAnimeEpisodeUrl(entry.watchUrl, episodeNumber),
      RemoteProvider.animeFlv =>
        _buildAnimeFlvEpisodeUrl(entry.slug, episodeNumber),
      RemoteProvider.facebook => entry.watchUrl,
      _ => entry.watchUrl,
    };
  }

  String _buildJkAnimeRemoteEpisodePageUrl(EpisodeItem entry) {
    final currentPath = entry.filePath.trim();
    if (_isJkAnimeEpisodePageUrl(currentPath)) {
      return currentPath;
    }
    final episodeNumber = entry.episodeNumber < 1 ? 1 : entry.episodeNumber;
    final movie = currentPath.toLowerCase().contains('/pelicula/') ||
        entry.relativePath.toLowerCase().contains('pelicula');
    final slug = [
      _extractJkAnimeSlugFromUrlOrSlug(entry.slug),
      _extractJkAnimeSlugFromUrlOrSlug(currentPath),
      _extractJkAnimeSlugFromUrlOrSlug(entry.watchUrl),
    ].map((value) => value.trim()).firstWhere(
          (value) => value.isNotEmpty,
          orElse: () => '',
        );
    if (slug.isNotEmpty) {
      return _buildJkAnimeEpisodeUrl(slug, episodeNumber, movie: movie);
    }
    if (currentPath.isNotEmpty) {
      return currentPath;
    }
    return entry.watchUrl.trim();
  }

  bool _isJkAnimeEpisodePageUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || !uri.host.contains('jkanime.net')) {
      return false;
    }
    final segments = uri.pathSegments
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.length < 2) {
      return false;
    }
    final last = segments.last.toLowerCase();
    return last == 'pelicula' || int.tryParse(last) != null;
  }

  String _findBestDirectMediaUrl(
    String html,
    String baseUrl, {
    String preferredFacebookMode = '',
  }) {
    final candidates = <String, int>{};
    void addCandidate(String rawValue,
        {int bonus = 0, bool decodeJsonLiteral = false}) {
      final decoded =
          decodeJsonLiteral ? _decodeJsonUrlLiteral(rawValue) : rawValue;
      final candidate = _normalizeExtractedUrl(decoded, baseUrl: baseUrl);
      if (_inferPlaybackKind(candidate).isEmpty) {
        return;
      }
      final current = candidates[candidate];
      if (current == null || bonus > current) {
        candidates[candidate] = bonus;
      }
    }

    final patterns = [
      RegExp(
        r"""(?:^|[,{;\s])(?:file|src|source|sources|url|uri|manifest|playlist|hls|stream|video[_-]?url|download[_-]?url|playback[_-]?url)\s*[:=]\s*['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        "(?:file|src)\\s*[:=]\\s*['\\\"]([^'\\\"]+)['\\\"]",
        caseSensitive: false,
      ),
      RegExp(
        r"""['"](?:file|src|source|sources|url|uri|manifest|playlist|hls|stream|video[_-]?url|download[_-]?url|playback[_-]?url)['"]\s*:\s*['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        "property=['\\\"]og:video['\\\"][^>]+content=['\\\"]([^'\\\"]+)['\\\"]",
        caseSensitive: false,
      ),
      RegExp(
        "content=['\\\"]([^'\\\"]+)['\\\"][^>]+property=['\\\"]og:video['\\\"]",
        caseSensitive: false,
      ),
      RegExp(
        "['\\\"]((?:https?:)?//[^'\\\"]+(?:\\.m3u8|\\.mp4|\\.mpd|/m3u8/|master\\.txt)[^'\\\"]*)['\\\"]",
        caseSensitive: false,
      ),
      RegExp(
        r"""((?:https?:)?//[^\s"'<>]+(?:\.m3u8(?:\?[^\s"'<>]*)?|\.mp4(?:\?[^\s"'<>]*)?|\.mpd(?:\?[^\s"'<>]*)?|/m3u8/[^\s"'<>]*|master\.txt(?:\?[^\s"'<>]*)?))""",
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(html)) {
        for (var index = 1; index <= match.groupCount; index += 1) {
          addCandidate(match.group(index) ?? '');
        }
      }
    }
    for (final candidate in _extractFacebookMediaUrlCandidates(html)) {
      addCandidate(candidate.url,
          bonus: candidate.scoreBonus, decodeJsonLiteral: true);
    }
    for (final candidate in _extractEncodedUrlCandidates(html, baseUrl)) {
      addCandidate(candidate);
    }
    for (final candidate in _extractEncodedQueryUrlCandidates(baseUrl)) {
      addCandidate(candidate);
    }
    for (final playUrl in _extractAnimeAv1PlayUrls(html, baseUrl)) {
      addCandidate(_buildAnimeAv1HlsUrl(playUrl), bonus: 80);
    }

    for (final specialLink in _extractSpecialHostDirectLinks(html, baseUrl)) {
      if (specialLink.contains('hqq.tv') &&
          !specialLink.toLowerCase().contains('stream=1')) {
        addCandidate(
          '$specialLink${specialLink.contains('?') ? '&' : '?'}stream=1',
          bonus: 40,
        );
      } else {
        addCandidate(specialLink, bonus: 40);
      }
    }

    final sorted = candidates.entries
        .where((entry) => _inferPlaybackKind(entry.key).isNotEmpty)
        .toList()
      ..sort((left, right) => (_directMediaScore(
                    right.key,
                    preferredFacebookMode: preferredFacebookMode,
                  ) +
                  right.value)
              .compareTo(
            _directMediaScore(
                  left.key,
                  preferredFacebookMode: preferredFacebookMode,
                ) +
                left.value,
          ));
    return sorted.isEmpty ? '' : sorted.first.key;
  }

  List<RemoteSubtitleTrack> _extractSubtitleTracks(
    String html,
    String baseUrl,
  ) {
    final normalizedHtml = _decodeHtml(html).replaceAll(r'\/', '/');
    final tracks = <RemoteSubtitleTrack>[];

    final trackTagPattern = RegExp(
      r"""<track\b([^>]*)>""",
      caseSensitive: false,
    );
    for (final match in trackTagPattern.allMatches(normalizedHtml)) {
      final attrs = _parseHtmlAttributes(match.group(1) ?? '');
      final track = _subtitleTrackFromFields(
        rawUrl: attrs['src'] ?? attrs['file'] ?? attrs['url'] ?? '',
        baseUrl: baseUrl,
        label: attrs['label'] ?? attrs['name'] ?? attrs['title'] ?? '',
        language: attrs['srclang'] ?? attrs['language'] ?? attrs['lang'] ?? '',
        rawType: attrs['type'] ?? '',
        rawKind: attrs['kind'] ?? '',
        isDefault: attrs.containsKey('default'),
      );
      if (track != null) {
        tracks.add(track);
      }
    }

    final objectPattern = RegExp(
      r"""\{[^{}]{0,1400}(?:file|src|url|trackUrl|trackFile)\s*:\s*['"][^'"]+['"][^{}]{0,1400}\}""",
      caseSensitive: false,
    );
    for (final match in objectPattern.allMatches(normalizedHtml)) {
      final objectText = match.group(0) ?? '';
      final fields = _parseJavascriptObjectStringFields(objectText);
      final track = _subtitleTrackFromFields(
        rawUrl: fields['file'] ??
            fields['src'] ??
            fields['url'] ??
            fields['trackurl'] ??
            fields['trackfile'] ??
            '',
        baseUrl: baseUrl,
        label: fields['label'] ?? fields['name'] ?? fields['title'] ?? '',
        language:
            fields['srclang'] ?? fields['language'] ?? fields['lang'] ?? '',
        rawType: fields['type'] ?? '',
        rawKind: fields['kind'] ?? '',
        isDefault: _readJavascriptBoolField(objectText, 'default') ||
            _readJavascriptBoolField(objectText, 'isDefault'),
      );
      if (track != null) {
        tracks.add(track);
      }
    }

    final directUrlPattern = RegExp(
      r"""['"]((?:https?:)?//[^'"]+\.(?:vtt|srt|ass|ssa|ttml|dfxp)(?:\?[^'"]*)?)['"]""",
      caseSensitive: false,
    );
    for (final match in directUrlPattern.allMatches(normalizedHtml)) {
      final track = _subtitleTrackFromFields(
        rawUrl: match.group(1) ?? '',
        baseUrl: baseUrl,
      );
      if (track != null) {
        tracks.add(track);
      }
    }

    return _mergeRemoteSubtitleTracks(tracks);
  }

  Map<String, String> _parseHtmlAttributes(String value) {
    final attrs = <String, String>{};
    final pattern = RegExp(
      r"""([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?""",
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(value)) {
      final key = (match.group(1) ?? '').trim().toLowerCase();
      if (key.isEmpty) {
        continue;
      }
      attrs[key] = _decodeJavascriptStringLiteral(
          match.group(2) ?? match.group(3) ?? match.group(4) ?? '');
    }
    return attrs;
  }

  Map<String, String> _parseJavascriptObjectStringFields(String value) {
    final fields = <String, String>{};
    final pattern = RegExp(
      r"""['"]?([a-zA-Z_][a-zA-Z0-9_]*)['"]?\s*:\s*['"]((?:\\.|[^'"\\])*)['"]""",
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(value)) {
      final key = (match.group(1) ?? '').trim().toLowerCase();
      final rawValue = match.group(2) ?? '';
      if (key.isEmpty || rawValue.trim().isEmpty) {
        continue;
      }
      fields[key] = _decodeJavascriptStringLiteral(rawValue);
    }
    return fields;
  }

  bool _readJavascriptBoolField(String objectText, String key) {
    return RegExp(
      "['\\\"]?${RegExp.escape(key)}['\\\"]?\\s*:\\s*true\\b",
      caseSensitive: false,
    ).hasMatch(objectText);
  }

  RemoteSubtitleTrack? _subtitleTrackFromFields({
    required String rawUrl,
    required String baseUrl,
    String label = '',
    String language = '',
    String rawType = '',
    String rawKind = '',
    bool isDefault = false,
  }) {
    final kind = rawKind.trim().toLowerCase();
    if (kind.isNotEmpty &&
        !{'captions', 'subtitles', 'subtitle'}.contains(kind)) {
      return null;
    }
    final url = _normalizeExtractedUrl(rawUrl, baseUrl: baseUrl);
    if (url.isEmpty || _inferPlaybackKind(url).isNotEmpty) {
      return null;
    }
    final mimeType = _inferSubtitleMimeType(
      url: url,
      rawType: rawType,
      rawKind: kind,
    );
    if (mimeType.isEmpty) {
      return null;
    }
    final cleanedLabel = _cleanRemoteText(label);
    return RemoteSubtitleTrack(
      url: url,
      label: cleanedLabel.isEmpty ? 'Subtitulos' : cleanedLabel,
      language: _normalizeSubtitleLanguage(language, label),
      mimeType: mimeType,
      isDefault: isDefault,
    );
  }

  String _inferSubtitleMimeType({
    required String url,
    String rawType = '',
    String rawKind = '',
  }) {
    final normalizedType = rawType.trim().toLowerCase();
    final normalizedUrl = url.trim().toLowerCase();
    if (normalizedType.contains('vtt') ||
        RegExp(r'\.vtt(?:\?|$)').hasMatch(normalizedUrl)) {
      return 'text/vtt';
    }
    if (normalizedType.contains('subrip') ||
        normalizedType.contains('srt') ||
        RegExp(r'\.srt(?:\?|$)').hasMatch(normalizedUrl)) {
      return 'application/x-subrip';
    }
    if (normalizedType.contains('ttml') ||
        normalizedType.contains('dfxp') ||
        RegExp(r'\.(?:ttml|dfxp)(?:\?|$)').hasMatch(normalizedUrl)) {
      return 'application/ttml+xml';
    }
    if (normalizedType.contains('ssa') ||
        normalizedType.contains('ass') ||
        RegExp(r'\.(?:ssa|ass)(?:\?|$)').hasMatch(normalizedUrl)) {
      return 'text/x-ssa';
    }
    if ({'captions', 'subtitles', 'subtitle'}.contains(rawKind.toLowerCase())) {
      return 'text/vtt';
    }
    return '';
  }

  String _normalizeSubtitleLanguage(String rawLanguage, String label) {
    final candidate = rawLanguage.trim().toLowerCase();
    if (candidate.isNotEmpty) {
      return candidate.split(RegExp(r'[^a-z0-9-]')).first;
    }
    final normalizedLabel = _normalizeMatchText(label);
    if (normalizedLabel.contains('espanol') ||
        normalizedLabel.contains('spanish') ||
        normalizedLabel.contains('castellano')) {
      return 'es';
    }
    if (normalizedLabel.contains('english') ||
        normalizedLabel.contains('ingles')) {
      return 'en';
    }
    return '';
  }

  List<RemoteSubtitleTrack> _mergeRemoteSubtitleTracks(
    List<RemoteSubtitleTrack> primary, [
    List<RemoteSubtitleTrack> secondary = const [],
  ]) {
    final merged = <RemoteSubtitleTrack>[];
    final seen = <String>{};
    for (final track in [...primary, ...secondary]) {
      final key =
          '${track.url.toLowerCase()}|${track.language.toLowerCase()}|${track.label.toLowerCase()}';
      if (track.url.trim().isEmpty || !seen.add(key)) {
        continue;
      }
      if (track.isDefault) {
        merged.insert(0, track);
      } else {
        merged.add(track);
      }
    }
    return merged;
  }

  List<_HostCandidate> _extractHostCandidates(
    String html,
    String baseUrl, {
    String preferredServer = '',
    Set<String> excludedServers = const {},
  }) {
    final candidates = <String, _HostCandidate>{};
    void addCandidate(String rawValue, {String server = '', int bonus = 0}) {
      final candidateUrl = _normalizeExtractedUrl(rawValue, baseUrl: baseUrl);
      if (!_isHostCandidateUrl(candidateUrl)) {
        return;
      }
      final normalizedServer = _normalizeServerPreference(server);
      final candidate = _HostCandidate(
        url: candidateUrl,
        server: normalizedServer,
        scoreBonus: bonus,
      );
      final current = candidates[candidateUrl];
      if (current == null ||
          _hostCandidateSortScoreFor(candidate, preferredServer) >
              _hostCandidateSortScoreFor(current, preferredServer)) {
        candidates[candidateUrl] = candidate;
      }
    }

    for (final candidate in _extractStructuredHostCandidates(html, baseUrl)) {
      addCandidate(
        candidate.url,
        server: candidate.server,
        bonus: candidate.scoreBonus + 80,
      );
    }
    final patterns = [
      RegExp(
        "<(?:iframe|embed)[^>]+src=['\\\"]([^'\\\"]+)['\\\"]",
        caseSensitive: false,
      ),
      RegExp(
        "(?:data-player|data-src|data-url|data-video|data-embed|data-iframe)\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]",
        caseSensitive: false,
      ),
      RegExp(
        "['\\\"]((?:https?:)?//[^'\\\"]+)['\\\"]",
        caseSensitive: false,
      ),
      RegExp(
        r"""((?:https?:)?//[^\s"'<>]+)""",
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(html)) {
        addCandidate(match.group(1) ?? '');
      }
    }

    final atobPattern =
        RegExp("atob\\(['\\\"]([^'\\\"]+)['\\\"]\\)", caseSensitive: false);
    for (final match in atobPattern.allMatches(html)) {
      final encoded = match.group(1) ?? '';
      final decoded = _decodeBase64Text(encoded);
      addCandidate(decoded);
    }
    for (final candidate in _extractEncodedUrlCandidates(html, baseUrl)) {
      addCandidate(candidate);
    }
    for (final candidate in _extractEncodedQueryUrlCandidates(baseUrl)) {
      addCandidate(candidate);
    }

    final excluded = excludedServers
        .map(_normalizeServerPreference)
        .where((server) => server.isNotEmpty)
        .toSet();
    return candidates.values
        .where(
          (candidate) =>
              !excluded.contains(_normalizedCandidateServer(candidate)),
        )
        .toList()
      ..sort((left, right) => _hostCandidateSortScoreFor(
            right,
            preferredServer,
          ).compareTo(
            _hostCandidateSortScoreFor(left, preferredServer),
          ));
  }

  bool _shouldPreferHostCandidateResolution(String html, String pageUrl) {
    final uri = Uri.tryParse(pageUrl);
    final host = uri?.host.toLowerCase() ?? '';
    final path = uri?.path.toLowerCase() ?? '';
    final lowerHtml = html.toLowerCase();
    if (host.contains('jkanime.net')) {
      return _containsJkAnimeServerPayload(html) ||
          lowerHtml.contains('/jkplayer/') ||
          lowerHtml.contains('servers btn-show');
    }
    if (host.contains('latanime.org') && path.contains('/ver/')) {
      return lowerHtml.contains('data-player') ||
          lowerHtml.contains('play-video');
    }
    if (host.contains('animeflv.net') && path.contains('/ver/')) {
      return lowerHtml.contains('var videos');
    }
    return false;
  }

  List<_HostCandidate> _extractStructuredHostCandidates(
      String html, String baseUrl) {
    final candidates = <_HostCandidate>[];
    candidates
        .addAll(_extractJkAnimeServerPayloadHostCandidates(html, baseUrl));
    candidates.addAll(_extractLatAnimeDataPlayerHostCandidates(html, baseUrl));
    candidates
        .addAll(_extractAnimeFlvVideosPayloadHostCandidates(html, baseUrl));
    return candidates.toList()
      ..sort((left, right) => _hostCandidateSortScoreFor(right, '').compareTo(
            _hostCandidateSortScoreFor(left, ''),
          ));
  }

  List<_HostCandidate> _extractJkAnimeServerPayloadHostCandidates(
      String html, String baseUrl) {
    final payload = _jkAnimeServerPayloadPattern()
            .firstMatch(html)
            ?.namedGroup('payload') ??
        '';
    if (payload.isEmpty) {
      return const [];
    }
    final decoded = _decodeJsonPayload(payload);
    if (decoded is! List) {
      return const [];
    }

    final candidates = <String, _HostCandidate>{};
    for (final rawEntry in decoded) {
      if (rawEntry is! Map) {
        continue;
      }
      final entry = Map<String, dynamic>.from(rawEntry);
      final remote = _readString(entry['remote']);
      final decodedRemote = _decodeBase64Text(remote);
      final url = _normalizeExtractedUrl(
        decodedRemote.isNotEmpty ? decodedRemote : remote,
        baseUrl: baseUrl,
      );
      if (_isHostCandidateUrl(url)) {
        final server = _readString(
          entry['server'],
          fallback: _readString(entry['name']),
        );
        candidates[url] = _HostCandidate(
          url: url,
          server: server,
          scoreBonus: 360 + _jkAnimeHostCandidateScoreBonus(server),
        );
      }
    }
    return candidates.values.toList()
      ..sort((left, right) => _hostCandidateSortScoreFor(right, '').compareTo(
            _hostCandidateSortScoreFor(left, ''),
          ));
  }

  bool _containsJkAnimeServerPayload(String html) {
    return _jkAnimeServerPayloadPattern().hasMatch(html);
  }

  RegExp _jkAnimeServerPayloadPattern() {
    return RegExp(
      r'(?:(?:\b(?:var|let|const)\s+servers)|(?:\bwindow\s*\.\s*servers)|(?:\bservers))\s*=\s*(?<payload>\[[\s\S]*?\])\s*;?',
      caseSensitive: false,
    );
  }

  int _jkAnimeHostCandidateScoreBonus(String value) {
    return switch (_normalizeServerPreference(value)) {
      'magi' => 1000,
      'desu' => 940,
      'streamwish' => 860,
      'mp4upload' => 800,
      'vidhide' => 720,
      'mixdrop' => 560,
      'voe' => 520,
      'filemoon' => 480,
      'doodstream' => 420,
      'stape' => 360,
      _ => 0,
    };
  }

  List<_HostCandidate> _extractLatAnimeDataPlayerHostCandidates(
    String html,
    String baseUrl,
  ) {
    final candidates = <String, _HostCandidate>{};
    final dataPlayerElementPattern = RegExp(
      r"""<([a-z0-9]+)\b([^>]*)\bdata-player\s*=\s*(['"])([^'"]+)\3[^>]*>([\s\S]*?)</\1>""",
      caseSensitive: false,
    );
    for (final match in dataPlayerElementPattern.allMatches(html)) {
      final rawPlayer = match.group(4) ?? '';
      final decodedPlayer = _decodePossibleBase64Text(rawPlayer).trim();
      final url = _normalizeExtractedUrl(
        decodedPlayer.isNotEmpty ? decodedPlayer : rawPlayer,
        baseUrl: baseUrl,
      );
      if (!_isHostCandidateUrl(url)) {
        continue;
      }
      final label = _cleanRemoteText(match.group(5) ?? '');
      candidates[url] = _HostCandidate(
        url: url,
        server: label,
        scoreBonus: 120 + _latAnimeHostCandidateScoreBonus(label),
      );
    }
    return candidates.values.toList()
      ..sort((left, right) => _hostCandidateSortScoreFor(right, '').compareTo(
            _hostCandidateSortScoreFor(left, ''),
          ));
  }

  int _latAnimeHostCandidateScoreBonus(String value) {
    return switch (_normalizeServerPreference(value)) {
      'uqload' => 1000,
      'mp4upload' => 900,
      'doodstream' => 760,
      'yourupload' => 420,
      _ => 0,
    };
  }

  List<_HostCandidate> _extractAnimeFlvVideosPayloadHostCandidates(
      String html, String baseUrl) {
    final payload = RegExp(
          r'var\s+videos\s*=\s*(\{[\s\S]*?\})\s*;',
          caseSensitive: false,
        ).firstMatch(html)?.group(1) ??
        '';
    if (payload.isEmpty) {
      return const [];
    }
    final decoded = _decodeJsonPayload(payload);
    if (decoded is! Map) {
      return const [];
    }

    final candidates = <String, _HostCandidate>{};
    for (final group in decoded.values) {
      if (group is! List) {
        continue;
      }
      for (final rawEntry in group) {
        if (rawEntry is! Map) {
          continue;
        }
        final entry = Map<String, dynamic>.from(rawEntry);
        for (final rawUrl in [
          _readString(entry['code']),
          _readString(entry['url']),
        ]) {
          final url = _normalizeExtractedUrl(rawUrl, baseUrl: baseUrl);
          if (_isHostCandidateUrl(url)) {
            candidates[url] = _HostCandidate(
              url: url,
              server: _readString(entry['server'],
                  fallback: _readString(entry['title'])),
              scoreBonus: 80,
            );
          }
        }
      }
    }
    return candidates.values.toList()
      ..sort((left, right) => _hostCandidateSortScoreFor(right, '').compareTo(
            _hostCandidateSortScoreFor(left, ''),
          ));
  }

  List<_FacebookMediaCandidate> _extractFacebookMediaUrlCandidates(
      String html) {
    final candidates = <_FacebookMediaCandidate>[];
    final patterns = [
      (
        pattern: RegExp(
          r'"(?:browser_native_hd_url|playable_url_quality_hd|hd_src)"\s*:\s*"((?:\\.|[^"\\])*)"',
          caseSensitive: false,
        ),
        bonus: 140,
      ),
      (
        pattern: RegExp(
          r'"(?:browser_native_sd_url|playable_url|sd_src)"\s*:\s*"((?:\\.|[^"\\])*)"',
          caseSensitive: false,
        ),
        bonus: 90,
      ),
      (
        pattern: RegExp(
          r'"progressive_url"\s*:\s*"((?:\\.|[^"\\])*)"',
          caseSensitive: false,
        ),
        bonus: 110,
      ),
      (
        pattern: RegExp(
          r'"(?:hls_playlist_url|playable_url_hls)"\s*:\s*"((?:\\.|[^"\\])*)"',
          caseSensitive: false,
        ),
        bonus: 120,
      ),
      (
        pattern: RegExp(
          r'"(?:dash_manifest_url|playable_url_dash|manifest_url)"\s*:\s*"((?:\\.|[^"\\])*)"',
          caseSensitive: false,
        ),
        bonus: 80,
      ),
      (
        pattern: RegExp(
          r"""(?:hd_src|sd_src)\s*[:=]\s*['"]([^'"]+)['"]""",
          caseSensitive: false,
        ),
        bonus: 80,
      ),
    ];

    for (final entry in patterns) {
      for (final match in entry.pattern.allMatches(html)) {
        final value = match.group(1) ?? '';
        if (value.trim().isNotEmpty) {
          candidates.add(
            _FacebookMediaCandidate(value, entry.bonus),
          );
        }
      }
    }

    for (final value in _extractFacebookJsonScriptMediaUrls(html)) {
      candidates.add(_FacebookMediaCandidate(value, 100));
    }
    return candidates;
  }

  List<String> _extractFacebookJsonScriptMediaUrls(String html) {
    final urls = <String>{};
    final scriptPattern = RegExp(
      r"""<script[^>]*(?:type=["']application/json["']|data-sjs)[^>]*>([\s\S]*?)</script>""",
      caseSensitive: false,
    );
    for (final match in scriptPattern.allMatches(html)) {
      final payload = _decodeHtml(match.group(1) ?? '')
          .replaceFirst(RegExp(r'^\s*<!--'), '')
          .replaceFirst(RegExp(r'-->\s*$'), '')
          .trim();
      if (payload.isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(payload);
        _collectFacebookJsonMediaUrls(decoded, urls);
      } catch (_) {
        continue;
      }
    }
    return urls.toList();
  }

  void _collectFacebookJsonMediaUrls(
    Object? value,
    Set<String> urls, {
    int depth = 0,
  }) {
    if (value == null || depth > 18 || urls.length > 80) {
      return;
    }
    if (value is String) {
      final decoded = _decodeJsonUrlLiteral(value);
      if (_looksLikeFacebookMediaUrl(decoded)) {
        urls.add(decoded);
      }
      return;
    }
    if (value is List) {
      for (final item in value) {
        _collectFacebookJsonMediaUrls(item, urls, depth: depth + 1);
      }
      return;
    }
    if (value is Map) {
      const mediaKeys = {
        'playable_url',
        'playable_url_quality_hd',
        'playable_url_dash',
        'playable_url_hls',
        'browser_native_hd_url',
        'browser_native_sd_url',
        'dash_manifest_url',
        'hls_playlist_url',
        'manifest_url',
        'progressive_url',
        'hd_src',
        'sd_src',
      };
      for (final entry in value.entries) {
        final key = '${entry.key}'.trim().toLowerCase();
        final child = entry.value;
        if (child is String && mediaKeys.contains(key)) {
          final decoded = _decodeJsonUrlLiteral(child);
          if (decoded.isNotEmpty) {
            urls.add(decoded);
          }
          continue;
        }
        _collectFacebookJsonMediaUrls(child, urls, depth: depth + 1);
      }
    }
  }

  Object? _decodeJsonPayload(String payload) {
    try {
      return jsonDecode(payload.replaceAll(r'\/', '/'));
    } catch (_) {
      return null;
    }
  }

  List<String> _extractEncodedUrlCandidates(String html, String baseUrl) {
    final encodedValues = <String>{};
    final patterns = [
      RegExp(
        "(?:data-player|data-url|data-src|data-video|remote)\\s*=\\s*['\\\"]([A-Za-z0-9+/_=-]{16,})['\\\"]",
        caseSensitive: false,
      ),
      RegExp(
        "['\\\"](?:remote|url|file|src)['\\\"]\\s*:\\s*['\\\"]([A-Za-z0-9+/_=-]{16,})['\\\"]",
        caseSensitive: false,
      ),
      RegExp(
        "(?:^|[,{\\s])(?:remote|url|file|src)\\s*:\\s*['\\\"]([A-Za-z0-9+/_=-]{16,})['\\\"]",
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(html)) {
        final encoded = match.group(1)?.trim() ?? '';
        if (encoded.isNotEmpty) {
          encodedValues.add(encoded);
        }
      }
    }

    final results = <String>{};
    for (final encoded in encodedValues) {
      final decoded = _decodeBase64Text(encoded).trim();
      if (!_looksLikeAbsoluteUrl(decoded)) {
        continue;
      }
      final candidate = _normalizeExtractedUrl(decoded, baseUrl: baseUrl);
      if (candidate.isNotEmpty) {
        results.add(candidate);
      }
    }
    return results.toList();
  }

  List<String> _extractAnimeAv1PlayUrls(String html, String baseUrl) {
    final results = <String>{};
    final pattern = RegExp(
      r"""(?:(?:https?:)?//)?player\.zilla-networks\.com/play/[a-z0-9]+""",
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(html.replaceAll(r'\/', '/'))) {
      var rawValue = match.group(0)?.trim() ?? '';
      if (rawValue.toLowerCase().startsWith('player.zilla-networks.com/')) {
        rawValue = 'https://$rawValue';
      }
      final candidate = _normalizeExtractedUrl(rawValue, baseUrl: baseUrl);
      if (_buildAnimeAv1HlsUrl(candidate).isNotEmpty) {
        results.add(candidate);
      }
    }
    return results.toList();
  }

  List<String> _extractResolverEndpointUrls(String html, String baseUrl) {
    final rawUrls = <String>{};
    final patterns = [
      RegExp(
        r"""fetch\(\s*['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""(?:\$|jQuery)\.(?:get|post|getJSON)\(\s*['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""axios\.(?:get|post)\(\s*['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""XMLHttpRequest[\s\S]{0,200}?\.open\(\s*['"][A-Z]+['"]\s*,\s*['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""(?:^|[,{;\s])url\s*:\s*['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""['"](?:ajax_url|api_url|source_url|sources_url|stream_url|player_url)['"]\s*:\s*['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""(?:^|[;\s])(?:const|let|var)\s+[A-Za-z_$][\w$]*(?:url|source|api|ajax|stream|player)[\w$]*\s*=\s*['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(html)) {
        final value = match.group(1)?.trim() ?? '';
        if (value.isNotEmpty) {
          rawUrls.add(value);
        }
      }
    }
    rawUrls.addAll(_extractJavascriptResolvedEndpointStrings(html));
    rawUrls.addAll(_extractJavascriptConcatenatedStringValues(html));

    final results = <String>{};
    for (final rawUrl in rawUrls) {
      final candidate = _normalizeExtractedUrl(rawUrl, baseUrl: baseUrl);
      if (_shouldFetchResolverEndpoint(candidate, baseUrl)) {
        results.add(candidate);
      }
    }
    return results.toList();
  }

  List<String> _extractSpecialHostDirectLinks(String html, String baseUrl) {
    final rawLinks = <String>{};
    final patterns = [
      RegExp(
        r"""id=['"](?:botlink|robotlink)['"][^>]*>\s*([^<]+?)\s*<""",
        caseSensitive: false,
      ),
      RegExp(
        r"""id=['"](?:botlink|robotlink)['"][^>]*(?:href|value)=['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""(?:href|value)=['"]([^'"]+)['"][^>]*id=['"](?:botlink|robotlink)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""(?:window\s*\.\s*)?(?:botlink|bot_link)\s*=\s*['"]([^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""['"]((?:/)?(?:streamtape\.com/)?get_video\?[^'"\s<]+)['"]""",
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(html)) {
        final value = match.group(1)?.trim() ?? '';
        if (value.isNotEmpty) {
          rawLinks.add(value);
        }
      }
    }

    final results = <String>{};
    for (final rawLink in rawLinks) {
      final candidate = _normalizeExtractedUrl(rawLink, baseUrl: baseUrl);
      final lowerCandidate = candidate.toLowerCase();
      if (_inferPlaybackKind(candidate).isNotEmpty ||
          (lowerCandidate.contains('hqq.tv') &&
              lowerCandidate.contains('get_video'))) {
        results.add(candidate);
      }
    }
    return results.toList();
  }

  String _expandResolverHtml(String html) {
    final parts = <String>{html};
    parts.addAll(_extractPackedJavascriptPayloads(html));
    parts.addAll(_extractJavascriptConcatenatedStringValues(html));
    return parts.join('\n');
  }

  List<String> _extractPackedJavascriptPayloads(String html) {
    final results = <String>{};
    final patterns = [
      RegExp(
        r"""eval\s*\(\s*function\s*\(\s*p\s*,\s*a\s*,\s*c\s*,\s*k\s*,\s*e\s*,\s*d\s*\)\s*\{[\s\S]*?\}\s*\(\s*'((?:\\.|[^'\\])*)'\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*'((?:\\.|[^'\\])*)'\.split\(\s*'\|'\s*\)""",
        caseSensitive: false,
      ),
      RegExp(
        r'''eval\s*\(\s*function\s*\(\s*p\s*,\s*a\s*,\s*c\s*,\s*k\s*,\s*e\s*,\s*d\s*\)\s*\{[\s\S]*?\}\s*\(\s*"((?:\\.|[^"\\])*)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*"((?:\\.|[^"\\])*)"\.split\(\s*"\|"\s*\)''',
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(html)) {
        final payload = _decodeJavascriptStringLiteral(match.group(1) ?? '');
        final radix = int.tryParse(match.group(2) ?? '') ?? 0;
        final count = int.tryParse(match.group(3) ?? '') ?? 0;
        final symbols = _decodeJavascriptStringLiteral(match.group(4) ?? '');
        final unpacked =
            _unpackJavascriptPacker(payload, radix, count, symbols);
        if (unpacked.isNotEmpty) {
          results.add(unpacked);
        }
      }
    }
    return results.toList();
  }

  String _unpackJavascriptPacker(
    String payload,
    int radix,
    int count,
    String symbolsPayload,
  ) {
    if (payload.isEmpty ||
        symbolsPayload.isEmpty ||
        radix < 2 ||
        radix > 62 ||
        count <= 0) {
      return '';
    }
    final symbols = symbolsPayload.split('|');
    if (symbols.isEmpty) {
      return '';
    }
    return payload.replaceAllMapped(
      RegExp(r'\b[0-9A-Za-z]+\b'),
      (match) {
        final token = match.group(0) ?? '';
        final index = _parsePackerToken(token, radix);
        if (index == null || index < 0 || index >= count) {
          return token;
        }
        if (index >= symbols.length || symbols[index].isEmpty) {
          return token;
        }
        return symbols[index];
      },
    );
  }

  int? _parsePackerToken(String token, int radix) {
    const alphabet =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    var value = 0;
    for (final unit in token.codeUnits) {
      final char = String.fromCharCode(unit);
      final digit = alphabet.indexOf(char);
      if (digit < 0 || digit >= radix) {
        return null;
      }
      value = value * radix + digit;
    }
    return value;
  }

  List<String> _extractJavascriptConcatenatedStringValues(String html) {
    final results = <String>{};
    final expressionPattern = RegExp(
      r'''((?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')(?:\s*\+\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'))+)''',
    );
    final literalPattern = RegExp(
      r""""((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'""",
    );

    for (final match in expressionPattern.allMatches(html)) {
      final expression = match.group(1) ?? '';
      if (expression.length > 4096) {
        continue;
      }
      final buffer = StringBuffer();
      for (final literal in literalPattern.allMatches(expression)) {
        buffer.write(
          _decodeJavascriptStringLiteral(
            literal.group(1) ?? literal.group(2) ?? '',
          ),
        );
      }
      final decoded = buffer.toString().trim();
      if (decoded.isEmpty) {
        continue;
      }
      final lower = decoded.toLowerCase();
      if (_looksLikeAbsoluteUrl(decoded) ||
          lower.contains('.m3u8') ||
          lower.contains('.mp4') ||
          lower.contains('.mpd') ||
          lower.contains('/m3u8/') ||
          _looksLikeResolverEndpointLiteral(decoded)) {
        results.add(decoded);
      }
    }
    return results.toList();
  }

  List<String> _extractJavascriptResolvedEndpointStrings(String html) {
    final variables = <String, String>{};
    final assignmentPattern = RegExp(
      r'''(?:^|[;\s])(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*([^;\n]{1,2048})''',
      caseSensitive: false,
    );

    for (var pass = 0; pass < 3; pass += 1) {
      var changed = false;
      for (final match in assignmentPattern.allMatches(html)) {
        final name = match.group(1)?.trim() ?? '';
        final expression = match.group(2)?.trim() ?? '';
        if (name.isEmpty || expression.isEmpty) {
          continue;
        }
        final resolved =
            _resolveJavascriptStringExpression(expression, variables);
        if (resolved == null || variables[name] == resolved) {
          continue;
        }
        variables[name] = resolved;
        changed = true;
      }
      if (!changed) {
        break;
      }
    }

    final results = <String>{};
    for (final entry in variables.entries) {
      final key = entry.key.toLowerCase();
      if ((key.contains('url') ||
              key.contains('source') ||
              key.contains('api') ||
              key.contains('ajax') ||
              key.contains('stream') ||
              key.contains('player')) &&
          _looksLikeResolverEndpointLiteral(entry.value)) {
        results.add(entry.value);
      }
    }

    final callPatterns = [
      RegExp(r"""fetch\(\s*([^),]{1,2048})""", caseSensitive: false),
      RegExp(
        r"""(?:\$|jQuery)\.(?:get|post|getJSON)\(\s*([^),]{1,2048})""",
        caseSensitive: false,
      ),
      RegExp(
        r"""axios\.(?:get|post)\(\s*([^),]{1,2048})""",
        caseSensitive: false,
      ),
      RegExp(
        r"""XMLHttpRequest[\s\S]{0,200}?\.open\(\s*['"][A-Z]+['"]\s*,\s*([^),]{1,2048})""",
        caseSensitive: false,
      ),
    ];
    for (final pattern in callPatterns) {
      for (final match in pattern.allMatches(html)) {
        final expression = match.group(1)?.trim() ?? '';
        final resolved =
            _resolveJavascriptStringExpression(expression, variables);
        if (resolved != null && _looksLikeResolverEndpointLiteral(resolved)) {
          results.add(resolved);
        }
      }
    }

    return results.toList();
  }

  String? _resolveJavascriptStringExpression(
    String expression,
    Map<String, String> variables,
  ) {
    final normalized = expression.trim();
    if (normalized.isEmpty || normalized.length > 4096) {
      return null;
    }
    final tokenPattern = RegExp(
      r'''\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|([A-Za-z_$][\w$]*))\s*(?:\+|$)''',
    );
    final buffer = StringBuffer();
    var position = 0;
    var hasToken = false;
    while (position < normalized.length) {
      final match = tokenPattern.matchAsPrefix(normalized, position);
      if (match == null) {
        return null;
      }
      hasToken = true;
      final literal = match.group(1) ?? match.group(2);
      if (literal != null) {
        buffer.write(_decodeJavascriptStringLiteral(literal));
      } else {
        final variableName = match.group(3)?.trim() ?? '';
        final variableValue = variables[variableName];
        if (variableValue == null) {
          return null;
        }
        buffer.write(variableValue);
      }
      if (match.end == position) {
        return null;
      }
      position = match.end;
    }
    return hasToken ? buffer.toString().trim() : null;
  }

  bool _looksLikeResolverEndpointLiteral(String value) {
    final lower = value.trim().toLowerCase();
    if (lower.isEmpty ||
        !(lower.startsWith('/') ||
            lower.startsWith('http://') ||
            lower.startsWith('https://') ||
            lower.startsWith('//'))) {
      return false;
    }
    return lower.contains('/ajax') ||
        lower.contains('/api') ||
        lower.contains('/source') ||
        lower.contains('/sources') ||
        lower.contains('/stream') ||
        lower.contains('/playlist') ||
        lower.contains('/download') ||
        lower.contains('/player') ||
        lower.contains('/server');
  }

  String _decodeJavascriptStringLiteral(String value) {
    return value
        .replaceAllMapped(
          RegExp(r'\\x([0-9a-fA-F]{2})'),
          (match) {
            final codePoint = int.tryParse(match.group(1) ?? '', radix: 16);
            return codePoint == null
                ? match.group(0) ?? ''
                : String.fromCharCode(codePoint);
          },
        )
        .replaceAllMapped(
          RegExp(r'\\u([0-9a-fA-F]{4})'),
          (match) {
            final codePoint = int.tryParse(match.group(1) ?? '', radix: 16);
            return codePoint == null
                ? match.group(0) ?? ''
                : String.fromCharCode(codePoint);
          },
        )
        .replaceAll(r'\/', '/')
        .replaceAll(r"\'", "'")
        .replaceAll(r'\"', '"')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\\', '\\')
        .trim();
  }

  List<String> _extractEncodedQueryUrlCandidates(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.query.isEmpty) {
      return const [];
    }
    const keys = {
      'url',
      'u',
      'redir',
      'redirect',
      'target',
      'remote',
      'player',
      'data',
    };
    final encodedValues = <String>{};
    for (final part in uri.query.split('&')) {
      if (part.trim().isEmpty) {
        continue;
      }
      final separator = part.indexOf('=');
      final rawKey = separator >= 0 ? part.substring(0, separator) : part;
      final key = Uri.decodeComponent(rawKey).trim().toLowerCase();
      if (!keys.contains(key)) {
        continue;
      }
      final rawValue = separator >= 0 ? part.substring(separator + 1) : '';
      final value = Uri.decodeComponent(rawValue).trim();
      if (value.isNotEmpty) {
        encodedValues.add(value);
      }
    }

    final results = <String>{};
    for (final encoded in encodedValues) {
      final decoded = _decodePossibleBase64Text(encoded);
      for (final value in [decoded, encoded]) {
        if (value.trim().isEmpty) {
          continue;
        }
        final candidate = _normalizeExtractedUrl(value, baseUrl: baseUrl);
        if (_looksLikeAbsoluteUrl(candidate)) {
          results.add(candidate);
        }
      }
    }
    return results.toList();
  }

  String _decodePossibleBase64Text(String value) {
    final decoded = _decodeBase64Text(value);
    if (decoded.isNotEmpty) {
      return decoded;
    }
    try {
      return utf8.decode(base64Url.decode(base64.normalize(value.trim())));
    } catch (_) {
      return '';
    }
  }

  String _extractDoodstreamPassMd5Url(String html, String baseUrl) {
    final patterns = [
      RegExp(
        r"""\.get\(\s*['"]([^'"]*/pass_md5/[^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""['"]((?:https?:)?//[^'"]*/pass_md5/[^'"]+)['"]""",
        caseSensitive: false,
      ),
      RegExp(
        r"""['"]((?:/)?pass_md5/[^'"]+)['"]""",
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(html)) {
        final candidate =
            _normalizeExtractedUrl(match.group(1) ?? '', baseUrl: baseUrl);
        if (candidate.isNotEmpty) {
          return candidate;
        }
      }
    }
    return '';
  }

  String _extractDoodstreamToken(String html) {
    final patterns = [
      RegExp(r"""[?&]token=([^"'&\s]+)""", caseSensitive: false),
      RegExp(r"""token=([^"'&\s]+)""", caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final token = pattern.firstMatch(html)?.group(1)?.trim() ?? '';
      if (token.isNotEmpty) {
        return token;
      }
    }
    return '';
  }

  String _randomAlphaNumeric(int size) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return List.generate(
      size,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  String _decodeJsonUrlLiteral(String value) {
    final raw = _decodeHtml(value).trim();
    if (raw.isEmpty) {
      return '';
    }
    try {
      final decoded = jsonDecode('"${raw.replaceAll('"', r'\"')}"');
      if (decoded is String) {
        return decoded;
      }
    } catch (_) {
      // Fallback below covers the small escape subset used by provider HTML.
    }
    return _decodeJsonUrlEscapes(raw);
  }

  String _decodeJsonUrlEscapes(String value) {
    return value
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u002F', '/')
        .replaceAll(r'\u002f', '/')
        .replaceAll(r'\u0025', '%')
        .replaceAll(r'\u0026', '&')
        .replaceAll(r'\u003D', '=')
        .replaceAll(r'\u003d', '=')
        .replaceAll(r'\u003A', ':')
        .replaceAll(r'\u003a', ':');
  }

  String _normalizeExtractedUrl(String value, {required String baseUrl}) {
    var cleaned = _decodeHtml(value)
        .replaceAllMapped(
          RegExp(r'\\u([0-9a-fA-F]{4})'),
          (match) {
            final codePoint = int.tryParse(match.group(1) ?? '', radix: 16);
            return codePoint == null
                ? match.group(0) ?? ''
                : String.fromCharCode(codePoint);
          },
        )
        .replaceAll(r'\/', '/')
        .replaceAll('\\\\', '\\')
        .trim();
    cleaned = cleaned.replaceAll(RegExp("[\\s\"']+\$"), '');
    if (cleaned.isEmpty) {
      return '';
    }
    if (cleaned.startsWith('//') &&
        !RegExp(r'^//[a-z0-9.-]+\.[a-z]{2,}(?:[/:?#]|$)', caseSensitive: false)
            .hasMatch(cleaned)) {
      return '';
    }
    if (RegExp(r'^/[a-z0-9.-]+\.[a-z]{2,}/', caseSensitive: false)
        .hasMatch(cleaned)) {
      return 'https://${cleaned.substring(1)}';
    }
    final baseUri = Uri.tryParse(baseUrl);
    if (baseUri != null && baseUri.hasScheme) {
      try {
        return baseUri.resolve(cleaned).toString();
      } on FormatException {
        return '';
      }
    }
    return _normalizeUrl(cleaned, _baseOrigin(baseUrl));
  }

  String _decodeBase64Text(String value) {
    try {
      return utf8.decode(base64.decode(base64.normalize(value.trim())));
    } catch (_) {
      return '';
    }
  }

  bool _looksLikeAbsoluteUrl(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.startsWith('http://') ||
        normalized.startsWith('https://') ||
        normalized.startsWith('//');
  }

  bool _isHostCandidateUrl(String value) {
    if (value.isEmpty || _inferPlaybackKind(value).isNotEmpty) {
      return false;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return false;
    }
    final lower = value.toLowerCase();
    if (RegExp(r'\.(?:jpg|jpeg|png|gif|webp|svg|css|js|ico)(?:\?|$)')
        .hasMatch(lower)) {
      return false;
    }
    if (_isStreamWishAlias(value)) {
      return true;
    }
    const hostMarkers = [
      'streamwish',
      'sfastwish',
      'wishfast',
      'flaswish',
      'dood',
      'ds2play',
      'dsvplay',
      'd-s.io',
      'playmogo',
      'myvidplay',
      'uqload',
      'yourupload',
      'mp4upload',
      'hqq',
      'netu',
      'waaw',
      'streamtape',
      'stape',
      'streamsb',
      'sbembed',
      'sbplay',
      'vidhide',
      'voe.sx',
      'vidmoly',
      'vidstream',
      'vidoza',
      'upcloud',
      'megacloud',
      'filemoon',
      'bysekoze',
      'mixdrop',
      'mxdrop',
      'ok.ru',
      'embedsito',
      'desu',
      'sendvid',
      'mail.ru',
      'vk.com',
    ];
    if (hostMarkers.any(lower.contains)) {
      return true;
    }
    return lower.contains('/embed') ||
        lower.contains('/jkplayer/') ||
        lower.contains('/player') ||
        lower.contains('/reproductor') ||
        lower.contains('/redirect') ||
        lower.contains('/video/');
  }

  bool _shouldFetchHostUrl(String value) {
    final lower = value.toLowerCase();
    if (lower.contains('doubleclick.net') ||
        lower.contains('googlesyndication.com') ||
        lower.contains('googletagmanager.com') ||
        lower.contains('facebook.com') ||
        lower.contains('twitter.com')) {
      return false;
    }
    return _isHostCandidateUrl(value);
  }

  bool _shouldFetchResolverEndpoint(String value, String pageUrl) {
    if (value.isEmpty ||
        _inferPlaybackKind(value).isNotEmpty ||
        _isHostCandidateUrl(value)) {
      return false;
    }
    final uri = Uri.tryParse(value);
    final pageUri = Uri.tryParse(pageUrl);
    if (uri == null ||
        pageUri == null ||
        !uri.hasScheme ||
        !pageUri.hasScheme ||
        uri.host.isEmpty ||
        pageUri.host.isEmpty ||
        uri.host.toLowerCase() != pageUri.host.toLowerCase()) {
      return false;
    }
    final lower = value.toLowerCase();
    if (RegExp(r'\.(?:jpg|jpeg|png|gif|webp|svg|css|js|ico|woff2?)(?:\?|$)')
        .hasMatch(lower)) {
      return false;
    }
    return lower.contains('/ajax') ||
        lower.contains('/api') ||
        lower.contains('/source') ||
        lower.contains('/sources') ||
        lower.contains('/stream') ||
        lower.contains('/playlist') ||
        lower.contains('/download') ||
        lower.contains('/player') ||
        lower.contains('/server');
  }

  int _hostCandidateSortScoreFor(
    _HostCandidate candidate,
    String preferredServer,
  ) {
    var score = _hostCandidateScore(candidate.url) + candidate.scoreBonus;
    final preferred = _normalizeServerPreference(preferredServer);
    if (preferred.isNotEmpty &&
        _normalizedCandidateServer(candidate) == preferred) {
      score += 3000;
    }
    return score;
  }

  String _normalizedCandidateServer(_HostCandidate candidate) {
    final normalized = _normalizeServerPreference(candidate.server);
    return normalized.isEmpty
        ? _normalizeServerPreference(candidate.url)
        : normalized;
  }

  String _explicitCandidateServer(_HostCandidate candidate) {
    return _normalizeServerPreference(candidate.server);
  }

  String _normalizeServerPreference(String value) {
    final lower = value.trim().toLowerCase();
    if (lower.isEmpty) {
      return '';
    }
    if (_isStreamWishAlias(value)) {
      return 'streamwish';
    }
    if (lower.contains('jkanime.net/jkplayer/umv')) {
      return 'magi';
    }
    if (lower.contains('jkanime.net/jkplayer/um')) {
      return 'desu';
    }
    if (lower.contains('jkanime.net/jkplayer/jk')) {
      return 'desuka';
    }
    if (lower.contains('mixdrop') || lower.contains('mix drop')) {
      return 'mixdrop';
    }
    if (lower.contains('doodstream') ||
        lower.contains('dood') ||
        lower.contains('dsvplay') ||
        lower.contains('myvidplay')) {
      return 'doodstream';
    }
    if (lower.contains('vidhide') || lower.contains('vid hide')) {
      return 'vidhide';
    }
    if (lower.contains('upcloud')) {
      return 'upcloud';
    }
    if (lower.contains('vidstream')) {
      return 'vidstream';
    }
    if (lower.contains('megacloud')) {
      return 'megacloud';
    }
    if (lower.contains('filemoon')) {
      return 'filemoon';
    }
    if (lower.contains('vidoza')) {
      return 'vidoza';
    }
    if (lower.contains('streamsb') ||
        lower.contains('sbembed') ||
        lower.contains('sbplay')) {
      return 'streamsb';
    }
    if (lower.contains('desu')) {
      return 'desu';
    }
    if (lower.contains('mp4upload') || lower.contains('mp4 upload')) {
      return 'mp4upload';
    }
    if (lower.contains('yourupload') || lower.contains('vidcache')) {
      return 'yourupload';
    }
    if (lower.contains('uqload')) {
      return 'uqload';
    }
    if (lower.contains('netu') || lower.contains('hqq')) {
      return 'netu';
    }
    if (lower.contains('stape') || lower.contains('streamtape')) {
      return 'stape';
    }
    return lower.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  int _hostCandidateScore(String value) {
    final lower = value.toLowerCase();
    var score = 0;
    if (lower.contains('jkanime.net/jkplayer/umv')) {
      score += 760;
    } else if (lower.contains('jkanime.net/jkplayer/um')) {
      score += 620;
    }
    if (lower.contains('jkanime.net/jkplayer/jk')) {
      score += 560;
    }
    if (_isStreamWishAlias(value)) {
      score += 500;
    }
    if (lower.contains('mixdrop') || lower.contains('mix drop')) {
      score += 470;
    }
    if (lower.contains('doodstream') ||
        lower.contains('dood') ||
        lower.contains('dsvplay') ||
        lower.contains('myvidplay')) {
      score += 440;
    }
    if (lower.contains('streamtape') || lower.contains('stape')) {
      score += 400;
    }
    if (lower.contains('vidhide') || lower.contains('vid hide')) {
      score += 380;
    }
    if (lower.contains('upcloud') ||
        lower.contains('vidstream') ||
        lower.contains('megacloud')) {
      score += 360;
    }
    if (lower.contains('magi')) {
      score += 360;
    } else if (lower.contains('desu')) {
      score += 320;
    }
    if (lower.contains('filemoon')) {
      score += 340;
    }
    if (lower.contains('streamsb') ||
        lower.contains('sbembed') ||
        lower.contains('sbplay')) {
      score += 330;
    }
    if (lower.contains('vidoza') || lower.contains('vidmoly')) {
      score += 320;
    }
    if (lower.contains('mp4upload') || lower.contains('yourupload')) {
      score += 300;
    }
    if (lower.contains('uqload') ||
        lower.contains('hqq') ||
        lower.contains('netu')) {
      score += 260;
    }
    if (lower.contains('/embed') || lower.contains('/player')) {
      score += 30;
    }
    return score;
  }

  int _directMediaScore(
    String value, {
    String preferredFacebookMode = '',
  }) {
    final lower = value.toLowerCase();
    var score = switch (_inferPlaybackKind(value)) {
      'hls' => 500,
      'dash' => 420,
      'mp4' => 360,
      _ => 0,
    };
    if (lower.contains('/hls2/') || lower.contains('premilkyway')) {
      score += 80;
    }
    if (_looksLikeFacebookMediaUrl(value)) {
      score += 220;
      final efgTag = _decodeFacebookEfgTag(value).toLowerCase();
      final progressive =
          efgTag.contains('xpv_progressive') || efgTag.contains('progressive');
      if (progressive) {
        score += 2000;
      }
      if (efgTag.contains('audio')) {
        score -= 5000;
      }
      if (!progressive && efgTag.contains('dash')) {
        score -= 1600;
      }
      if (lower.contains('quality_hd') ||
          lower.contains('/hd') ||
          lower.contains('_hd')) {
        score += 120;
      }
      final preferred = preferredFacebookMode.trim().toLowerCase();
      if (preferred == 'dub' &&
          (lower.contains('latino') || lower.contains('dub'))) {
        score += 70;
      }
      if (preferred == 'sub' &&
          (lower.contains('sub') || lower.contains('subtitulado'))) {
        score += 70;
      }
    }
    if (lower.contains('nightdestruct.com') ||
        lower.contains('doubleclick.net') ||
        lower.contains('googlesyndication.com')) {
      score -= 10000;
    }
    return score;
  }

  String _inferPlaybackKind(String url) {
    final normalized = url.trim().toLowerCase();
    if (normalized.isEmpty) {
      return '';
    }
    if (_isBlockedDirectMediaAsset(normalized)) {
      return '';
    }
    if (_isKnownEmbedWrapperUrl(normalized)) {
      return '';
    }
    if (RegExp(r'\.m3u8(?:\?|$)').hasMatch(normalized) ||
        normalized.contains('/m3u8/') ||
        RegExp(r'/hls(?:\d+)?(?:/|\?|$)').hasMatch(normalized) ||
        RegExp(r'master\.txt(?:\?|$)').hasMatch(normalized)) {
      return 'hls';
    }
    if (RegExp(r'\.mpd(?:\?|$)').hasMatch(normalized)) {
      return 'dash';
    }
    if (RegExp(r'\.mp4(?:\?|$)').hasMatch(normalized) ||
        normalized.contains('streamtape.com/get_video') ||
        (normalized.contains('hqq.tv') && normalized.contains('stream=1')) ||
        _isLikelyFacebookProgressiveUrl(normalized) ||
        _isLikelyDoodStreamMp4Candidate(normalized)) {
      return 'mp4';
    }
    return '';
  }

  bool _isBlockedDirectMediaAsset(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) {
      return false;
    }
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final query = uri.query.toLowerCase();
    final combined = '$host $path $query';
    if (host == 'pbs.twimg.com' ||
        host.endsWith('.twimg.com') ||
        host.contains('twitter.com') ||
        host == 'x.com' ||
        host.endsWith('.x.com')) {
      return true;
    }
    return combined.contains('x-card') ||
        combined.contains('tweet_video') ||
        combined.contains('/static/money/') ||
        combined.contains('twitter_card');
  }

  bool _isKnownEmbedWrapperUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) {
      return false;
    }
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    if (host.contains('streamtape.com') || host.contains('stape')) {
      return path.startsWith('/e/');
    }
    if (host.contains('mp4upload.com')) {
      return path.contains('/embed');
    }
    if (host.contains('mixdrop') ||
        _isStreamWishAlias(value) ||
        host.contains('dood') ||
        host.contains('myvidplay') ||
        host.contains('d-s.io')) {
      return path.startsWith('/e/');
    }
    if (host.contains('filemoon')) {
      return path.startsWith('/e/') || path.contains('/embed');
    }
    if (host.contains('vidhide') || host.contains('yourupload')) {
      return path.contains('/embed') || path.startsWith('/e/');
    }
    if (host.contains('uqload')) {
      return path.contains('/embed');
    }
    if (host == 'jkanime.net' && path.contains('/jkplayer/')) {
      return true;
    }
    if (host.contains('latanime.org') && path.contains('/reproductor')) {
      return true;
    }
    return false;
  }

  bool _isStreamWishAlias(String value) {
    final lower = value.trim().toLowerCase();
    if (lower == 'sw' ||
        lower == 'wish' ||
        lower.contains('streamwish') ||
        lower.contains('stream wish') ||
        lower.contains('sfastwish') ||
        lower.contains('wishfast') ||
        lower.contains('flaswish')) {
      return true;
    }
    final uri = Uri.tryParse(value);
    final host = uri?.host.toLowerCase() ?? '';
    final path = uri?.path.toLowerCase() ?? '';
    return host.contains('wish') &&
        (path.startsWith('/e/') ||
            path.contains('/embed') ||
            path.contains('/play'));
  }

  bool _looksLikeFacebookMediaUrl(String value) {
    final lower = value.toLowerCase();
    return lower.contains('fbcdn.net') ||
        lower.contains('video.xx.fbcdn.net') ||
        lower.contains('facebook.com') && lower.contains('/video');
  }

  bool _isLikelyFacebookProgressiveUrl(String value) {
    if (!_looksLikeFacebookMediaUrl(value)) {
      return false;
    }
    final efgTag = _decodeFacebookEfgTag(value).toLowerCase();
    if (efgTag.contains('audio')) {
      return false;
    }
    return efgTag.contains('xpv_progressive') || efgTag.contains('progressive');
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

  bool _isLikelyDoodStreamMp4Candidate(String url) {
    return url.contains('token=') &&
        url.contains('expiry=') &&
        (url.contains('cloudatacdn.com') ||
            url.contains('doodcdn') ||
            url.contains('myvidplay'));
  }

  String _baseOrigin(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return baseUrl;
    }
    return '${uri.scheme}://${uri.host}';
  }

  List<RemoteSearchCandidate> _parseAnimeAv1Results(String html) {
    final regex = RegExp(
      r'<article class="group/item[\s\S]*?<img[^>]+src="(https?://[^"]+)"[\s\S]*?<div class="rounded bg-line[^"]*">([^<]+)</div>[\s\S]*?<h3[^>]*>([\s\S]*?)</h3>[\s\S]*?<a[^>]+href="(/media/[^"/?#]+)"',
      caseSensitive: false,
    );
    final seen = <String>{};
    final results = <RemoteSearchCandidate>[];
    for (final match in regex.allMatches(html)) {
      final imageUrl = _normalizeUrl(
          _cleanRemoteUrl(match.group(1) ?? ''), _animeAv1BaseUrl);
      final format = _cleanRemoteText(match.group(2) ?? '');
      final title = _cleanRemoteText(match.group(3) ?? '');
      final seriesPath = (match.group(4) ?? '').trim();
      final slug =
          seriesPath.replaceFirst('/media/', '').split('/').first.trim();
      if (slug.isEmpty || title.isEmpty || !seen.add('animeav1::$slug')) {
        continue;
      }
      results.add(
        RemoteSearchCandidate(
          provider: RemoteProvider.animeAv1,
          slug: slug,
          title: title,
          seriesUrl: _normalizeUrl(seriesPath, _animeAv1BaseUrl),
          imageUrl: imageUrl,
          format: format,
        ),
      );
    }

    return results;
  }

  List<RemoteSearchCandidate> _parseJkAnimeResults(
      String html, int fallbackReleaseYear) {
    final directory = _parseJkAnimeDirectoryResults(html, fallbackReleaseYear);
    if (directory.isNotEmpty) {
      return directory;
    }

    final regex = RegExp(
      r'<div class="anime__item">[\s\S]*?<a\s+href="(https?://jkanime\.net/[^"]+/)">[\s\S]*?(?:data-setbg|src)="([^"]+)"[\s\S]*?<div class="anime__item__text">[\s\S]*?<ul>([\s\S]*?)</ul>[\s\S]*?<h5><a[^>]*>([\s\S]*?)</a></h5>',
      caseSensitive: false,
    );
    final seen = <String>{};
    final results = <RemoteSearchCandidate>[];
    for (final match in regex.allMatches(html)) {
      final seriesUrl = (match.group(1) ?? '').trim();
      final slug = _extractJkAnimeSlug(seriesUrl);
      final title = _cleanRemoteText(match.group(4) ?? '');
      final metaItems = RegExp(r'<li[^>]*>([^<]+)</li>', caseSensitive: false)
          .allMatches(match.group(3) ?? '')
          .map((entry) => _cleanRemoteText(entry.group(1) ?? ''))
          .where((entry) => entry.isNotEmpty)
          .toList();
      final format =
          _normalizeJkAnimeFormat(metaItems.isEmpty ? '' : metaItems.last);
      if (slug.isEmpty || title.isEmpty || !seen.add('jkanime::$slug')) {
        continue;
      }
      results.add(
        RemoteSearchCandidate(
          provider: RemoteProvider.jkAnime,
          slug: slug,
          title: title,
          seriesUrl: seriesUrl,
          watchUrl: seriesUrl,
          imageUrl: _normalizeUrl(match.group(2) ?? '', _jkAnimeBaseUrl),
          format: format,
          releaseYear: fallbackReleaseYear,
        ),
      );
    }
    return results;
  }

  List<RemoteSearchCandidate> _parseJkAnimeDirectoryResults(
      String html, int fallbackReleaseYear) {
    final payload = RegExp(
          r'var\s+animes\s*=\s*(\{[\s\S]*?\})\s*;',
          caseSensitive: false,
        ).firstMatch(html)?.group(1) ??
        '';
    if (payload.isEmpty) {
      return const [];
    }
    final decoded = () {
      try {
        return jsonDecode(payload);
      } catch (_) {
        return null;
      }
    }();
    if (decoded is! Map) {
      return const [];
    }
    final data = decoded['data'];
    if (data is! List) {
      return const [];
    }
    final seen = <String>{};
    final results = <RemoteSearchCandidate>[];
    for (final rawItem in data) {
      if (rawItem is! Map) {
        continue;
      }
      final item = Map<String, dynamic>.from(rawItem);
      final rawUrl = _readString(item['url']);
      final rawSlug = _readString(item['slug']);
      final seriesUrl = rawUrl.isNotEmpty
          ? _normalizeJkAnimeSeriesUrl(rawUrl)
          : _normalizeJkAnimeSeriesUrl(rawSlug);
      final slug = rawSlug.isNotEmpty
          ? rawSlug.trim().replaceAll(RegExp(r'/+$'), '')
          : _extractJkAnimeSlug(seriesUrl);
      final title = _firstNonEmpty([
        _readString(item['title']),
        _readString(item['short_title']),
      ]);
      if (seriesUrl.isEmpty ||
          slug.isEmpty ||
          title.isEmpty ||
          !seen.add('jkanime::$slug')) {
        continue;
      }
      results.add(
        RemoteSearchCandidate(
          provider: RemoteProvider.jkAnime,
          slug: slug,
          title: title,
          seriesUrl: seriesUrl,
          watchUrl: seriesUrl,
          imageUrl: _normalizeUrl(_readString(item['image']), _jkAnimeBaseUrl),
          format: _firstNonEmpty([
            _readString(item['type']),
            _normalizeJkAnimeFormat(_readString(item['tipo'])),
          ]),
          releaseYear: fallbackReleaseYear,
        ),
      );
    }
    return results;
  }

  List<RemoteSearchCandidate> _parseLatAnimeResults(String html) {
    final cardRegex = RegExp(
      r'<a href="(https?://latanime\.org/anime/[^"]+)"[\s\S]*?</a>',
      caseSensitive: false,
    );
    final seen = <String>{};
    final results = <RemoteSearchCandidate>[];
    for (final card in cardRegex.allMatches(html)) {
      final cardHtml = card.group(0) ?? '';
      final seriesUrl = _normalizeLatAnimeSeriesUrl(card.group(1) ?? '');
      final slug = _extractLatAnimeSlug(seriesUrl);
      final title = _cleanRemoteText(
        RegExp(r'<h3[^>]*>([\s\S]*?)</h3>', caseSensitive: false)
                .firstMatch(cardHtml)
                ?.group(1) ??
            '',
      );
      if (seriesUrl.isEmpty ||
          slug.isEmpty ||
          title.isEmpty ||
          _isLatAnimeCastellanoTitle(title) ||
          !seen.add('latanime::$slug')) {
        continue;
      }
      final imageUrl = _normalizeUrl(
        RegExp(
              r'<img[^>]+(?:data-src|src)="([^"]+)"',
              caseSensitive: false,
            ).firstMatch(cardHtml)?.group(1) ??
            '',
        _latAnimeBaseUrl,
      );
      results.add(
        RemoteSearchCandidate(
          provider: RemoteProvider.latAnime,
          slug: slug,
          title: title,
          watchUrl: seriesUrl,
          seriesUrl: seriesUrl,
          imageUrl: imageUrl,
          aliases: _buildLatAnimeAliases(title),
          releaseYear: _extractYearFromText(cardHtml),
        ),
      );
    }
    return results;
  }

  List<RemoteSearchCandidate> _parseAnimeFlvResults(
      String html, int fallbackReleaseYear) {
    final regex = RegExp(
      r'<article class="Anime[\s\S]*?<a href="(/anime/[^"]+)">[\s\S]*?<figure><img src="([^"]+)"[^>]*></figure>[\s\S]*?<span class="Type ([^"]+)">[\s\S]*?</span>[\s\S]*?<h3 class="Title">([\s\S]*?)</h3>',
      caseSensitive: false,
    );
    final seen = <String>{};
    final results = <RemoteSearchCandidate>[];
    for (final match in regex.allMatches(html)) {
      final seriesUrl = _normalizeAnimeFlvSeriesUrl(match.group(1) ?? '');
      final slug = _extractAnimeFlvSlug(seriesUrl);
      final title = _cleanRemoteText(match.group(4) ?? '');
      if (seriesUrl.isEmpty ||
          slug.isEmpty ||
          title.isEmpty ||
          !seen.add('animeflv::$slug')) {
        continue;
      }
      results.add(
        RemoteSearchCandidate(
          provider: RemoteProvider.animeFlv,
          slug: slug,
          title: title,
          watchUrl: seriesUrl,
          seriesUrl: seriesUrl,
          imageUrl: _normalizeUrl(match.group(2) ?? '', _animeFlvBaseUrl),
          format: _normalizeAnimeFlvFormat(match.group(3) ?? ''),
          releaseYear: fallbackReleaseYear,
        ),
      );
    }
    return results;
  }

  RemoteSearchCandidate _copyCandidate(
    RemoteSearchCandidate candidate, {
    String? title,
    String? watchUrl,
    String? seriesUrl,
    String? imageUrl,
    String? backgroundUrl,
    String? logoUrl,
    String? trailerUrl,
    String? description,
    String? rating,
    int? episodeCount,
    String? format,
    String? japaneseTitle,
    List<String>? aliases,
    int? releaseYear,
    String? airDateIso,
    int? catalogId,
    List<String>? cast,
    List<SeriesEpisodeMetadata>? episodeDetails,
  }) {
    return RemoteSearchCandidate(
      provider: candidate.provider,
      slug: candidate.slug,
      title: title ?? candidate.title,
      watchUrl: watchUrl ?? candidate.watchUrl,
      seriesUrl: seriesUrl ?? candidate.seriesUrl,
      imageUrl: imageUrl ?? candidate.imageUrl,
      backgroundUrl: backgroundUrl ?? candidate.backgroundUrl,
      logoUrl: logoUrl ?? candidate.logoUrl,
      trailerUrl: trailerUrl ?? candidate.trailerUrl,
      description: description ?? candidate.description,
      rating: rating ?? candidate.rating,
      episodeCount: episodeCount ?? candidate.episodeCount,
      format: format ?? candidate.format,
      japaneseTitle: japaneseTitle ?? candidate.japaneseTitle,
      aliases: aliases ?? candidate.aliases,
      releaseYear: releaseYear ?? candidate.releaseYear,
      airDateIso: airDateIso ?? candidate.airDateIso,
      catalogId: catalogId ?? candidate.catalogId,
      cast: cast ?? candidate.cast,
      episodeDetails: episodeDetails ?? candidate.episodeDetails,
    );
  }

  List<RemoteSearchCandidate> _dedupe(List<RemoteSearchCandidate> candidates) {
    final seen = <String>{};
    final results = <RemoteSearchCandidate>[];
    for (final candidate in candidates) {
      final key =
          '${candidate.provider.id}::${candidate.slug.isNotEmpty ? candidate.slug : candidate.title}';
      if (seen.add(key)) {
        results.add(candidate);
      }
    }
    return results;
  }

  List<RemoteSearchCandidate> _dedupePreferAiringMetadata(
    List<RemoteSearchCandidate> candidates,
  ) {
    final results = <RemoteSearchCandidate>[];
    final indexes = <String, int>{};
    for (final candidate in candidates) {
      final key =
          '${candidate.provider.id}::${candidate.slug.isNotEmpty ? candidate.slug : candidate.title}';
      final existingIndex = indexes[key];
      if (existingIndex == null) {
        indexes[key] = results.length;
        results.add(candidate);
        continue;
      }
      final existing = results[existingIndex];
      results[existingIndex] = _mergeAiringCandidateMetadata(
        existing,
        candidate,
      );
    }
    return results;
  }

  RemoteSearchCandidate _mergeAiringCandidateMetadata(
    RemoteSearchCandidate primary,
    RemoteSearchCandidate supplemental,
  ) {
    final mergedEpisodes = _mergeEpisodeMetadata(
      primary.episodeDetails,
      supplemental.episodeDetails,
    );
    return _copyCandidate(
      primary,
      imageUrl: primary.imageUrl.isNotEmpty
          ? primary.imageUrl
          : supplemental.imageUrl,
      backgroundUrl: primary.backgroundUrl.isNotEmpty
          ? primary.backgroundUrl
          : supplemental.backgroundUrl,
      logoUrl:
          primary.logoUrl.isNotEmpty ? primary.logoUrl : supplemental.logoUrl,
      airDateIso: primary.airDateIso.isNotEmpty
          ? primary.airDateIso
          : supplemental.airDateIso,
      episodeDetails: mergedEpisodes,
    );
  }

  List<RemoteSearchCandidate> _interleaveCandidateLists(
    List<List<RemoteSearchCandidate>> lists,
  ) {
    final results = <RemoteSearchCandidate>[];
    final maxLength = lists.fold<int>(
      0,
      (max, list) => list.length > max ? list.length : max,
    );
    for (var index = 0; index < maxLength; index += 1) {
      for (final list in lists) {
        if (index < list.length) {
          results.add(list[index]);
        }
      }
    }
    return results;
  }

  Uri _buildJkAnimeDirectoryUri(String query, int releaseYear) {
    final params = <String, String>{
      'letra': query.trim(),
      'tipo': 'animes',
    };
    if (releaseYear >= 1900 && releaseYear <= 2100) {
      params['fecha'] = '$releaseYear';
    }
    return Uri.https('jkanime.net', '/directorio', params);
  }

  Uri _buildLatAnimeDirectoryUri(String query, int releaseYear) {
    return Uri.https('latanime.org', '/animes', {
      'fecha':
          releaseYear >= 1900 && releaseYear <= 2100 ? '$releaseYear' : 'false',
      'genero': 'false',
      'letra': query.trim(),
      'categoria': 'false',
    });
  }

  Future<List<RemoteSearchCandidate>> _searchJkAnimeByDirectSlug(String query,
      {int releaseYear = 0}) async {
    for (final slug in _buildJkAnimeFallbackSlugs(query)) {
      final seriesUrl = _normalizeJkAnimeSeriesUrl(slug);
      if (seriesUrl.isEmpty) {
        continue;
      }
      final response = await _get(Uri.parse(seriesUrl));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        continue;
      }
      final html = response.body;
      final episodeCount = _parseJkAnimeEpisodeCount(html);
      final title = _parseJkAnimeSeriesTitle(html);
      if (episodeCount <= 0 && title.isEmpty) {
        continue;
      }
      return [
        RemoteSearchCandidate(
          provider: RemoteProvider.jkAnime,
          slug: slug,
          title: title.isEmpty ? query : title,
          seriesUrl: seriesUrl,
          watchUrl: seriesUrl,
          imageUrl: _parseJkAnimeImageUrl(html),
          episodeCount: episodeCount,
          releaseYear: releaseYear,
        ),
      ];
    }
    return const [];
  }

  List<String> _buildJkAnimeFallbackSlugs(String query) {
    final normalized = _normalizeMatchText(query);
    if (normalized.isEmpty) {
      return const [];
    }
    final collapsed = normalized.replaceAll(' ', '-');
    return {
      collapsed,
      collapsed.replaceAll('-original', ''),
      collapsed.replaceAll('-tv', ''),
    }.where((entry) => entry.isNotEmpty).toList();
  }

  int _parseJkAnimeEpisodeCount(String html) {
    final pagination = int.tryParse(
          RegExp(r'paginationEps\((\d+)\)', caseSensitive: false)
                  .firstMatch(html)
                  ?.group(1) ??
              '',
        ) ??
        0;
    if (pagination > 0) {
      return pagination;
    }

    final structured = int.tryParse(
          RegExp(
                r'<li[^>]*>\s*<span>\s*Episodios:\s*</span>\s*(\d+)\s*</li>',
                caseSensitive: false,
              ).firstMatch(html)?.group(1) ??
              '',
        ) ??
        0;
    if (structured > 0) {
      return structured;
    }

    return int.tryParse(
          RegExp(r'\b(\d+)\s+episodios\b', caseSensitive: false)
                  .firstMatch(html)
                  ?.group(1) ??
              '',
        ) ??
        0;
  }

  String _parseJkAnimeSeriesTitle(String html) {
    final rawTitle = _cleanRemoteText(
      RegExp(r'<meta\s+property="og:title"\s+content="([^"]+)"',
                  caseSensitive: false)
              .firstMatch(html)
              ?.group(1) ??
          RegExp(r'<title>([^<]+)</title>', caseSensitive: false)
              .firstMatch(html)
              ?.group(1) ??
          '',
    );
    return rawTitle
        .replaceAll(RegExp(r'\s*-\s*anime\s+.*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+online\s+.*$', caseSensitive: false), '')
        .trim();
  }

  String _parseJkAnimeImageUrl(String html) {
    final raw = RegExp(r'<meta\s+property="og:image"\s+content="([^"]+)"',
                caseSensitive: false)
            .firstMatch(html)
            ?.group(1) ??
        '';
    return _normalizeUrl(raw, _jkAnimeBaseUrl);
  }

  List<_RemoteEpisodeLink> _parseLatAnimeEpisodeLinks(String html) {
    final regex = RegExp(
      r'<a href="(https?://latanime\.org/ver/[^"]+)">[\s\S]*?<div class="p-2 cap-layout[\s\S]*?>([\s\S]*?)</div>\s*</a>',
      caseSensitive: false,
    );
    final seen = <int>{};
    final episodes = <_RemoteEpisodeLink>[];
    for (final match in regex.allMatches(html)) {
      final url = (match.group(1) ?? '').trim();
      final label = _cleanRemoteText(match.group(2) ?? '');
      final episodeNumber = int.tryParse(
        RegExp(r'(?:capitulo|episodio)[-\s]*(\d+)', caseSensitive: false)
                .firstMatch('$url $label')
                ?.group(1) ??
            '',
      );
      if (url.isEmpty || episodeNumber == null || !seen.add(episodeNumber)) {
        continue;
      }
      episodes.add(_RemoteEpisodeLink(episodeNumber: episodeNumber, url: url));
    }
    episodes.sort(
        (left, right) => left.episodeNumber.compareTo(right.episodeNumber));
    return episodes;
  }

  String _extractLatAnimeSeriesTitle(String html) {
    return _cleanRemoteText(
      RegExp(r'<h2>([^<]+)</h2>', caseSensitive: false)
              .firstMatch(html)
              ?.group(1) ??
          '',
    );
  }

  String _extractLatAnimeSeriesImageUrl(String html) {
    final raw = RegExp(
          r'<img[^>]+src="(https?://latanime\.org/[^"]+)"[^>]*class="img-fluid2"[^>]*>',
          caseSensitive: false,
        ).firstMatch(html)?.group(1) ??
        '';
    return _normalizeUrl(raw, _latAnimeBaseUrl);
  }

  List<int> _parseAnimeFlvEpisodeNumbers(String html) {
    final payload = RegExp(
          r'var\s+episodes\s*=\s*\[([\s\S]*?)\]\s*;',
          caseSensitive: false,
        ).firstMatch(html)?.group(1) ??
        '';
    if (payload.isEmpty) {
      return const [];
    }
    final episodes = RegExp(r'\[\s*(\d+)\s*,\s*\d+\s*\]')
        .allMatches(payload)
        .map((entry) => int.tryParse(entry.group(1) ?? ''))
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();
    return episodes;
  }

  String _extractAnimeFlvSeriesTitle(String html) {
    return _cleanRemoteText(
      RegExp(r'<h1[^>]*class="Title"[^>]*>([^<]+)</h1>', caseSensitive: false)
              .firstMatch(html)
              ?.group(1) ??
          '',
    );
  }

  String _extractAnimeFlvSeriesImageUrl(String html) {
    final raw = RegExp(
          r'<div class="AnimeCover[\s\S]*?<img[^>]+src="([^"]+)"',
          caseSensitive: false,
        ).firstMatch(html)?.group(1) ??
        '';
    return _normalizeUrl(raw, _animeFlvBaseUrl);
  }

  String _extractAnimeFlvSeriesFormat(String html) {
    return _normalizeAnimeFlvFormat(
      RegExp(r'<span class="Type ([^"]+)">', caseSensitive: false)
              .firstMatch(html)
              ?.group(1) ??
          '',
    );
  }

  String _normalizeJkAnimeSeriesUrl(String value) {
    final source = value.trim();
    if (source.isEmpty) {
      return '';
    }
    final cleaned = source
        .split('?')
        .first
        .split('#')
        .first
        .trim()
        .replaceAll(RegExp(r'/+$'), '');
    if (cleaned.startsWith('http://') || cleaned.startsWith('https://')) {
      return '$cleaned/';
    }
    return '$_jkAnimeBaseUrl/${cleaned.replaceFirst(RegExp(r'^/+'), '')}/';
  }

  String _extractJkAnimeSlug(String value) {
    var source = value.trim();
    source = source
        .replaceFirst('$_jkAnimeBaseUrl/', '')
        .replaceFirst('https://jkanime.net/', '')
        .replaceFirst('http://jkanime.net/', '');
    return source.split('/').first.trim();
  }

  String _extractJkAnimeSlugFromUrlOrSlug(String value) {
    final source = value.trim();
    if (source.isEmpty) {
      return '';
    }
    final uri = Uri.tryParse(source);
    if (uri != null && uri.hasScheme) {
      if (!uri.host.contains('jkanime.net')) {
        return '';
      }
      return uri.pathSegments
          .map((segment) => segment.trim())
          .firstWhere((segment) => segment.isNotEmpty, orElse: () => '');
    }
    return _extractJkAnimeSlug(source);
  }

  String _buildJkAnimeEpisodeUrl(
    String slug,
    int episodeNumber, {
    bool movie = false,
  }) {
    final normalized = slug.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) {
      return '';
    }
    if (movie) {
      return '$_jkAnimeBaseUrl/$normalized/pelicula/';
    }
    return '$_jkAnimeBaseUrl/$normalized/${episodeNumber < 1 ? 1 : episodeNumber}/';
  }

  String _normalizeJkAnimeGuessSlug(String value) {
    final withoutParentheses =
        value.replaceAll(RegExp(r'\s*\([^)]+\)\s*'), ' ');
    return _normalizeMatchText(withoutParentheses).replaceAll(' ', '-');
  }

  String _normalizeLatAnimeSeriesUrl(String value) {
    final source = value.trim();
    if (source.isEmpty) {
      return '';
    }
    final cleaned = source
        .split('?')
        .first
        .split('#')
        .first
        .trim()
        .replaceAll(RegExp(r'/+$'), '');
    if (cleaned.contains('/anime/')) {
      if (cleaned.startsWith('http://') || cleaned.startsWith('https://')) {
        return cleaned;
      }
      return cleaned.startsWith('/')
          ? '$_latAnimeBaseUrl$cleaned'
          : '$_latAnimeBaseUrl/${cleaned.replaceFirst(RegExp(r'^/+'), '')}';
    }
    final slug = _extractLatAnimeSlug(cleaned);
    return slug.isEmpty ? '' : '$_latAnimeBaseUrl/anime/$slug';
  }

  String _extractLatAnimeSlug(String value) {
    var source = value.trim().split('?').first.split('#').first;
    source = source
        .replaceFirst('$_latAnimeBaseUrl/', '')
        .replaceFirst('https://latanime.org/', '')
        .replaceFirst('http://latanime.org/', '')
        .replaceFirst(RegExp(r'^/+'), '');
    final parts = source.split('/').where((entry) => entry.isNotEmpty).toList();
    if (parts.length >= 2 && parts.first.toLowerCase() == 'anime') {
      return parts[1];
    }
    if (parts.length >= 2 && parts.first.toLowerCase() == 'ver') {
      return parts[1].replaceAll(
        RegExp(r'-(?:episodio|capitulo)-\d+$', caseSensitive: false),
        '',
      );
    }
    return parts.isEmpty ? '' : parts.last;
  }

  String _buildLatAnimeEpisodeUrl(String seriesUrl, int episodeNumber) {
    final slug = _extractLatAnimeSlug(seriesUrl);
    if (slug.isEmpty) {
      return '';
    }
    return '$_latAnimeBaseUrl/ver/$slug-episodio-${episodeNumber < 1 ? 1 : episodeNumber}';
  }

  String _normalizeAnimeFlvSeriesUrl(String value) {
    final source = _cleanRemoteUrl(value);
    if (source.isEmpty) {
      return '';
    }
    final cleaned = source
        .split('?')
        .first
        .split('#')
        .first
        .trim()
        .replaceAll(RegExp(r'/+$'), '');
    if (cleaned.contains('/anime/')) {
      if (cleaned.startsWith('http://') || cleaned.startsWith('https://')) {
        return cleaned;
      }
      return cleaned.startsWith('/')
          ? '$_animeFlvBaseUrl$cleaned'
          : '$_animeFlvBaseUrl/${cleaned.replaceFirst(RegExp(r'^/+'), '')}';
    }
    final slug = _extractAnimeFlvSlug(cleaned);
    return slug.isEmpty ? '' : '$_animeFlvBaseUrl/anime/$slug';
  }

  String _extractAnimeFlvSlug(String value) {
    var source = _cleanRemoteUrl(value).split('?').first.split('#').first;
    source = source
        .replaceFirst('$_animeFlvBaseUrl/', '')
        .replaceFirst('https://www4.animeflv.net/', '')
        .replaceFirst('http://www4.animeflv.net/', '')
        .replaceFirst(RegExp(r'^/+'), '');
    final parts = source.split('/').where((entry) => entry.isNotEmpty).toList();
    final raw = switch (parts) {
      ['anime', final slug, ...] => slug,
      ['ver', final slug, ...] => slug,
      [final slug] => slug,
      _ => '',
    };
    return raw.replaceAll(RegExp(r'-\d+$'), '').trim();
  }

  String _buildAnimeFlvEpisodeUrl(String slug, int episodeNumber) {
    final normalized = slug.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) {
      return '';
    }
    return '$_animeFlvBaseUrl/ver/$normalized-${episodeNumber < 1 ? 1 : episodeNumber}';
  }

  String _normalizeJkAnimeFormat(String raw) {
    return switch (_normalizeMatchText(raw)) {
      'serie' => 'TV',
      'pelicula' => 'Movie',
      'ova' => 'OVA',
      'ona' => 'ONA',
      'special' => 'Special',
      _ => raw.trim(),
    };
  }

  String _normalizeAnimeFlvFormat(String raw) {
    return switch (_normalizeMatchText(raw)) {
      'tv' || 'anime' => 'TV',
      'movie' || 'pelicula' => 'Movie',
      'special' || 'especial' => 'Special',
      'ona' => 'ONA',
      'ova' => 'OVA',
      _ => raw.trim(),
    };
  }

  List<String> _buildLatAnimeAliases(String title) {
    final cleaned = _cleanRemoteText(title);
    if (cleaned.isEmpty) {
      return const [];
    }
    return {
      cleaned.replaceAll(
          RegExp(r'\b(?:audio\s+)?latino\b', caseSensitive: false), ' '),
      cleaned.replaceAll(RegExp(r'\bcastellano\b', caseSensitive: false), ' '),
      cleaned.replaceAll(
          RegExp(r'\b(?:audio\s+)?(?:latino|castellano)\b',
              caseSensitive: false),
          ' '),
    }
        .map(_cleanRemoteText)
        .where((entry) => entry.isNotEmpty && entry != cleaned)
        .toList();
  }

  bool _isLatAnimeCastellanoTitle(String title) {
    return _normalizeMatchText(title).contains('castellano');
  }

  int _scoreLatAnimeCandidate(
      String query, RemoteSearchCandidate candidate, int releaseYear) {
    var score = _scoreCandidateAgainstQuery(query, candidate);
    if (releaseYear > 0 && candidate.releaseYear > 0) {
      final diff = (releaseYear - candidate.releaseYear).abs();
      score += switch (diff) {
        0 => 520,
        1 => 140,
        2 => 40,
        _ => -260,
      };
    }
    final terms = _candidateSearchTerms(candidate).map(_normalizeMatchText);
    if (terms.any((entry) => entry.contains('castellano'))) {
      score -= 1000;
    }
    if (terms.any((entry) => entry.contains('latino'))) {
      score += 320;
    }
    return score;
  }

  int _scoreCandidateAgainstQuery(
      String query, RemoteSearchCandidate candidate) {
    final requested = _normalizeMatchText(query);
    if (requested.isEmpty) {
      return 0;
    }
    final requestedTokens = _tokenize(requested);
    var best = 0;
    for (final term
        in _candidateSearchTerms(candidate).map(_normalizeMatchText)) {
      if (term.isEmpty) {
        continue;
      }
      var score = 0;
      if (term == requested) {
        score += 1000;
      } else if (term.contains(requested) || requested.contains(term)) {
        score += 520;
      }
      final overlap = requestedTokens.intersection(_tokenize(term)).length;
      score += overlap * 80;
      if (score > best) {
        best = score;
      }
    }
    return best;
  }

  List<String> _candidateSearchTerms(RemoteSearchCandidate candidate) {
    return [
      candidate.title,
      candidate.japaneseTitle,
      ...candidate.aliases,
    ].map(_cleanRemoteText).where((entry) => entry.isNotEmpty).toList();
  }

  Set<String> _tokenize(String value) {
    return value
        .split(' ')
        .map((entry) => entry.trim())
        .where((entry) => entry.length >= 3)
        .toSet();
  }

  String _normalizeMatchText(String value) {
    var normalized = value.toLowerCase();
    const replacements = {
      '\u00e1': 'a',
      '\u00e0': 'a',
      '\u00e4': 'a',
      '\u00e2': 'a',
      '\u00e9': 'e',
      '\u00e8': 'e',
      '\u00eb': 'e',
      '\u00ea': 'e',
      '\u00ed': 'i',
      '\u00ec': 'i',
      '\u00ef': 'i',
      '\u00ee': 'i',
      '\u00f3': 'o',
      '\u00f2': 'o',
      '\u00f6': 'o',
      '\u00f4': 'o',
      '\u00fa': 'u',
      '\u00f9': 'u',
      '\u00fc': 'u',
      '\u00fb': 'u',
      '\u00f1': 'n',
    };
    for (final entry in replacements.entries) {
      normalized = normalized.replaceAll(entry.key, entry.value);
    }
    return normalized
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  int _extractYearFromText(String value) {
    return int.tryParse(
          RegExp(r'\b((?:19|20)\d{2})\b').firstMatch(value)?.group(1) ?? '',
        ) ??
        0;
  }

  List<int> _parseAnimeAv1EpisodeNumbers(String html, String slug) {
    final normalizedSlug = slug.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalizedSlug.isNotEmpty) {
      final pattern = RegExp(
        'href="/media/${RegExp.escape(normalizedSlug)}/(\\d+)',
        caseSensitive: false,
      );
      final fromLinks = pattern
          .allMatches(html)
          .map((match) => int.tryParse(match.group(1) ?? ''))
          .whereType<int>()
          .toSet()
          .toList()
        ..sort();
      if (fromLinks.isNotEmpty) {
        return fromLinks;
      }
    }
    final episodeCount = int.tryParse(
          RegExp(r'episodesCount:(\d+)', caseSensitive: false)
                  .firstMatch(html)
                  ?.group(1) ??
              '',
        ) ??
        0;
    return episodeCount > 0
        ? List.generate(episodeCount, (index) => index + 1)
        : const [];
  }

  String _extractAnimeAv1SeriesTitle(String html) {
    return RegExp(r'<h1[^>]*>([^<]+)</h1>', caseSensitive: false)
            .firstMatch(html)
            ?.group(1) ??
        '';
  }

  String _extractAnimeAv1SeriesImageUrl(String html) {
    final raw = RegExp(r'src="(https?://cdn\.animeav1\.com/covers/[^"]+)"',
                caseSensitive: false)
            .firstMatch(html)
            ?.group(1) ??
        '';
    return _normalizeUrl(raw, _animeAv1BaseUrl);
  }

  String _normalizeAnimeAv1SeriesUrl(String value) {
    final slug = _extractAnimeAv1Slug(value);
    return slug.isEmpty ? '' : '$_animeAv1BaseUrl/media/$slug';
  }

  String _extractAnimeAv1Slug(String value) {
    var source = value.trim();
    if (source.isEmpty) {
      return '';
    }
    source = source.split('?').first.split('#').first;
    source = source
        .replaceFirst('$_animeAv1BaseUrl/', '')
        .replaceFirst('https://animeav1.com/', '')
        .replaceFirst('http://animeav1.com/', '')
        .replaceFirst(RegExp(r'^/+'), '');
    final parts =
        source.split('/').where((part) => part.trim().isNotEmpty).toList();
    if (parts.isEmpty) {
      return '';
    }
    if (parts.first.toLowerCase() == 'media' && parts.length >= 2) {
      return parts[1].trim().replaceAll('/', '');
    }
    return parts.first.trim().replaceAll('/', '');
  }

  String _buildAnimeAv1EpisodeUrl(String seriesUrl, int episodeNumber) {
    final normalizedSeriesUrl = _normalizeAnimeAv1SeriesUrl(seriesUrl);
    if (normalizedSeriesUrl.isEmpty) {
      return '';
    }
    return '$normalizedSeriesUrl/${episodeNumber < 1 ? 1 : episodeNumber}';
  }

  String _extractAnimeAv1PlayUrl(String html, String variant) {
    final normalizedHtml = _decodeHtml(html).replaceAll(r'\/', '/');
    final variantKey = RegExp.escape(variant);
    final patterns = [
      RegExp(
        '["\\\']?$variantKey["\\\']?\\s*:\\s*\\[[\\s\\S]{0,1600}?'
        '["\\\']?server["\\\']?\\s*:\\s*["\\\']HLS["\\\'][\\s\\S]{0,400}?'
        '["\\\']?url["\\\']?\\s*:\\s*["\\\']'
        '(https://player\\.zilla-networks\\.com/play/[a-f0-9]{32})["\\\']',
        caseSensitive: false,
      ),
      RegExp(
        '["\\\']?$variantKey["\\\']?\\s*:\\s*\\[[\\s\\S]{0,1600}?'
        '(https://player\\.zilla-networks\\.com/play/[a-f0-9]{32})',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final playUrl = pattern.firstMatch(normalizedHtml)?.group(1) ?? '';
      if (playUrl.isNotEmpty) {
        return playUrl;
      }
    }
    return '';
  }

  String _buildAnimeAv1HlsUrl(String playUrl) {
    final streamId =
        playUrl.split('/play/').last.split('?').first.split('#').first.trim();
    return RegExp(r'^[a-f0-9]{32}$', caseSensitive: false).hasMatch(streamId)
        ? 'https://player.zilla-networks.com/m3u8/$streamId'
        : '';
  }

  String _normalizeUrl(String rawUrl, String baseUrl) {
    final value = rawUrl.trim();
    if (value.isEmpty) {
      return '';
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('//')) {
      return 'https:$value';
    }
    if (value.startsWith('/')) {
      return '$baseUrl$value';
    }
    return '$baseUrl/$value';
  }

  List<RemoteSearchCandidate> _parseBiliBiliResults(String html) {
    final videos = _parseBiliBiliVideoResults(html);
    final accumulators = <String, _BiliBiliSeriesAccumulator>{};
    for (final video in videos) {
      final episodeNumber = video.episodeNumber;
      if (video.title.isEmpty || episodeNumber <= 0) {
        continue;
      }

      final seriesTitle = _bilibiliSeriesTitleFromEpisodeTitle(video.title);
      final key = _normalizeMatchText(seriesTitle);
      if (seriesTitle.isEmpty || key.isEmpty) {
        continue;
      }

      final accumulator = accumulators.putIfAbsent(
        key,
        () => _BiliBiliSeriesAccumulator(
          key: key,
          title: seriesTitle,
          slug: video.videoId,
          imageUrl: video.imageUrl,
        ),
      );
      accumulator.add(
        SeriesEpisodeMetadata(
          episodeNumber: episodeNumber,
          title: video.title,
          description: video.url,
          imageUrl: video.imageUrl,
          durationLabel: video.durationLabel,
        ),
      );
    }

    final results = accumulators.values
        .where((entry) => entry.episodes.isNotEmpty)
        .map((entry) => entry.toCandidate())
        .toList();
    results.sort((left, right) {
      final countCompare = right.episodeCount.compareTo(left.episodeCount);
      if (countCompare != 0) {
        return countCompare;
      }
      return left.title.compareTo(right.title);
    });
    return results;
  }

  List<_BiliBiliVideoResult> _parseBiliBiliVideoResults(String html) {
    final cards = RegExp(
      r'<a[^>]+href="([^"]*/en/video/[^"]+)"[^>]*class="bstar-video-card__cover-link"[\s\S]*?<img[^>]+src="([^"]+)"[^>]*alt="([^"]*)"[\s\S]*?(?:<span[^>]+class="bstar-video-card__cover-mask-text[^"]*"[^>]*>([^<]*)</span>)?',
      caseSensitive: false,
    );
    final results = <_BiliBiliVideoResult>[];
    final seenVideoIds = <String>{};
    for (final match in cards.allMatches(html)) {
      final episodeUrl = _normalizeUrl(
        match.group(1) ?? '',
        _bilibiliBaseUrl,
      ).split('?').first.split('#').first;
      final videoId = _extractBiliBiliVideoId(episodeUrl);
      if (episodeUrl.isEmpty || videoId.isEmpty || !seenVideoIds.add(videoId)) {
        continue;
      }

      final rawTitle = _cleanRemoteText(match.group(3) ?? '');
      final episodeNumber = _extractBiliBiliEpisodeNumber(rawTitle);
      if (rawTitle.isEmpty) {
        continue;
      }

      final imageUrl = _normalizeUrl(
        _decodeHtml(match.group(2) ?? ''),
        _bilibiliBaseUrl,
      );
      final duration = _cleanRemoteText(match.group(4) ?? '');
      results.add(
        _BiliBiliVideoResult(
          videoId: videoId,
          url: episodeUrl,
          title: rawTitle,
          imageUrl: imageUrl,
          durationLabel: duration,
          episodeNumber: episodeNumber,
        ),
      );
    }
    return results;
  }

  String _bilibiliSearchUrl(String query) {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return '$_bilibiliBaseUrl/en/search-result';
    }
    return Uri.https('www.bilibili.tv', '/en/search-result', {
      'q': normalized,
    }).toString();
  }

  String _extractBiliBiliVideoId(String value) {
    return RegExp(r'/video/(\d+)', caseSensitive: false)
            .firstMatch(value)
            ?.group(1) ??
        '';
  }

  int _extractBiliBiliEpisodeNumber(String value) {
    return int.tryParse(
          RegExp(
                r'\b(?:ep(?:isode)?\.?|cap(?:itulo)?\.?)\s*(\d+)\b',
                caseSensitive: false,
              ).firstMatch(value)?.group(1) ??
              '',
        ) ??
        0;
  }

  String _bilibiliSeriesTitleFromEpisodeTitle(String value) {
    return _cleanRemoteText(
      value.replaceFirst(
        RegExp(
          r'\s*(?:ep(?:isode)?\.?|cap(?:itulo)?\.?)\s*\d+.*$',
          caseSensitive: false,
        ),
        '',
      ),
    );
  }
}

class RemoteCatalogException implements Exception {
  const RemoteCatalogException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _JustAnimeHlsProxy {
  _JustAnimeHlsProxy(this._server, this._client, this._userAgent);

  final io.HttpServer _server;
  final http.Client _client;
  final String _userAgent;

  String get playlistUrl =>
      'http://127.0.0.1:${_server.port}/fetch?url=${Uri.encodeQueryComponent(_initialUrl)}';
  late final String _initialUrl;

  static Future<_JustAnimeHlsProxy> start({
    required http.Client client,
    required String upstreamUrl,
    required String userAgent,
  }) async {
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    final proxy = _JustAnimeHlsProxy(server, client, userAgent)
      .._initialUrl = upstreamUrl;
    unawaited(proxy._serve());
    return proxy;
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(io.HttpRequest request) async {
    try {
      final target = request.uri.queryParameters['url'] ?? '';
      final uri = Uri.tryParse(target);
      if (uri == null || uri.host != 'neko.justanime.to') {
        request.response.statusCode = io.HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final upstream = await _client.get(uri, headers: {
        'Origin': 'https://www.justanime.to',
        'Referer': 'https://www.justanime.to/',
        'User-Agent': _userAgent,
        if (request.headers.value(io.HttpHeaders.rangeHeader) case final range?)
          'Range': range,
      });
      request.response.statusCode = upstream.statusCode;
      final type = upstream.headers[io.HttpHeaders.contentTypeHeader];
      if (type != null) {
        request.response.headers.contentType = io.ContentType.parse(type);
      }
      final decoded = utf8.decode(upstream.bodyBytes, allowMalformed: true);
      if (decoded.startsWith('#EXTM3U')) {
        var manifest = decoded;
        manifest = manifest.replaceAllMapped(
          RegExp(r'https://neko\.justanime\.to/[^\r\n]+'),
          (match) =>
              'http://127.0.0.1:${_server.port}/fetch?url=${Uri.encodeQueryComponent(match.group(0)!)}',
        );
        request.response.write(manifest);
      } else {
        request.response.add(upstream.bodyBytes);
      }
    } catch (_) {
      request.response.statusCode = io.HttpStatus.badGateway;
    }
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

class _BiliBiliDashProxy {
  _BiliBiliDashProxy._({
    required this.manifestUrl,
    required this.vlcHlsUrl,
    required this.vlcVideoUrl,
    required this.vlcAudioUrl,
    required this.vlcPlaylistUrl,
    required this.vlcPlaylistPath,
    required http.Client client,
    required io.HttpServer server,
    required io.File vlcPlaylistFile,
    required String pageUrl,
    required String videoUrl,
    required String audioUrl,
    required int durationSeconds,
    required String userAgent,
  })  : _client = client,
        _server = server,
        _vlcPlaylistFile = vlcPlaylistFile,
        _pageUrl = pageUrl,
        _videoUrl = videoUrl,
        _audioUrl = audioUrl,
        _durationSeconds = durationSeconds,
        _userAgent = userAgent {
    _expiryTimer = Timer(const Duration(hours: 3), () {
      unawaited(close());
    });
    _server.listen(_handleRequest);
  }

  final String manifestUrl;
  final String vlcHlsUrl;
  final String vlcVideoUrl;
  final String vlcAudioUrl;
  final String vlcPlaylistUrl;
  final String vlcPlaylistPath;
  final http.Client _client;
  final io.HttpServer _server;
  final io.File _vlcPlaylistFile;
  final String _pageUrl;
  final String _videoUrl;
  final String _audioUrl;
  final int _durationSeconds;
  final String _userAgent;
  Timer? _expiryTimer;
  bool _closed = false;

  static Future<_BiliBiliDashProxy> start({
    required http.Client client,
    required String pageUrl,
    required String videoUrl,
    required String audioUrl,
    required int durationSeconds,
    required String userAgent,
  }) async {
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    final playlistFile = io.File(
      '${io.Directory.systemTemp.path}'
      '${io.Platform.pathSeparator}'
      'tanuki-bilibili-${server.port}-${DateTime.now().microsecondsSinceEpoch}.m3u',
    );
    final proxy = _BiliBiliDashProxy._(
      manifestUrl: 'http://127.0.0.1:${server.port}/manifest.mpd',
      vlcHlsUrl: 'http://127.0.0.1:${server.port}/vlc-master.m3u8',
      vlcVideoUrl: 'http://127.0.0.1:${server.port}/video.m4s',
      vlcAudioUrl: 'http://127.0.0.1:${server.port}/audio.m4s',
      vlcPlaylistUrl: 'http://127.0.0.1:${server.port}/vlc.m3u',
      vlcPlaylistPath: playlistFile.path,
      client: client,
      server: server,
      vlcPlaylistFile: playlistFile,
      pageUrl: pageUrl,
      videoUrl: videoUrl,
      audioUrl: audioUrl,
      durationSeconds: durationSeconds,
      userAgent: userAgent,
    );
    await proxy._writeLocalVlcPlaylist();
    return proxy;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    try {
      if (await _vlcPlaylistFile.exists()) {
        await _vlcPlaylistFile.delete();
      }
    } catch (_) {
      // The temp playlist is best-effort cleanup only.
    }
    await _server.close(force: true);
  }

  Future<void> _handleRequest(io.HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/manifest.mpd') {
      await _writeManifest(request);
      return;
    }
    if (path == '/vlc.m3u') {
      await _writeVlcPlaylist(request);
      return;
    }
    if (path == '/vlc-master.m3u8') {
      await _writeVlcHlsMaster(request);
      return;
    }
    if (path == '/video.m3u8') {
      await _writeVlcHlsMedia(request, mediaPath: 'video.m4s');
      return;
    }
    if (path == '/audio.m3u8') {
      await _writeVlcHlsMedia(request, mediaPath: 'audio.m4s');
      return;
    }
    if (path == '/video.m4s') {
      await _proxyMedia(request, _videoUrl);
      return;
    }
    if (path == '/audio.m4s') {
      await _proxyMedia(request, _audioUrl);
      return;
    }
    request.response.statusCode = io.HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _writeManifest(io.HttpRequest request) async {
    final duration = _durationSeconds > 0 ? _durationSeconds : 24 * 60 * 60;
    final xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" minBufferTime="PT1.5S" mediaPresentationDuration="PT${duration}S">
  <Period id="0" duration="PT${duration}S">
    <AdaptationSet id="1" contentType="video" mimeType="video/mp4" segmentAlignment="true" subsegmentAlignment="true" startWithSAP="1">
      <Representation id="video" bandwidth="800000" codecs="avc1.64001F" width="640" height="360" startWithSAP="1">
        <BaseURL>video.m4s</BaseURL>
        <SegmentList timescale="1" duration="$duration">
          <SegmentURL media="video.m4s" />
        </SegmentList>
      </Representation>
    </AdaptationSet>
    <AdaptationSet id="2" contentType="audio" mimeType="audio/mp4" lang="und" segmentAlignment="true" subsegmentAlignment="true" startWithSAP="1">
      <Representation id="audio" bandwidth="128000" codecs="mp4a.40.2" audioSamplingRate="48000" startWithSAP="1">
        <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2" />
        <BaseURL>audio.m4s</BaseURL>
        <SegmentList timescale="1" duration="$duration">
          <SegmentURL media="audio.m4s" />
        </SegmentList>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
''';
    request.response
      ..statusCode = io.HttpStatus.ok
      ..headers.contentType =
          io.ContentType('application', 'dash+xml', charset: 'utf-8')
      ..write(xml);
    await request.response.close();
  }

  Future<void> _writeVlcHlsMaster(io.HttpRequest request) async {
    final baseUrl = 'http://127.0.0.1:${_server.port}';
    final startSeconds = _hlsStartSeconds(request);
    final startQuery = startSeconds > 0 ? '?start=$startSeconds' : '';
    final startTag = startSeconds > 0
        ? '#EXT-X-START:TIME-OFFSET=$startSeconds.000,PRECISE=YES\n'
        : '';
    final playlist = '''
#EXTM3U
#EXT-X-VERSION:7
$startTag#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="bilibili-audio",NAME="BiliBili",DEFAULT=YES,AUTOSELECT=YES,URI="$baseUrl/audio.m3u8$startQuery"
#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=640x360,CODECS="avc1.64001f,mp4a.40.2",AUDIO="bilibili-audio"
$baseUrl/video.m3u8$startQuery
''';
    request.response
      ..statusCode = io.HttpStatus.ok
      ..headers.contentType =
          io.ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8')
      ..write(playlist);
    await request.response.close();
  }

  Future<void> _writeVlcHlsMedia(
    io.HttpRequest request, {
    required String mediaPath,
  }) async {
    final baseUrl = 'http://127.0.0.1:${_server.port}';
    final duration = _durationSeconds > 0 ? _durationSeconds : 24 * 60 * 60;
    final startSeconds = _hlsStartSeconds(request);
    final startTag = startSeconds > 0
        ? '#EXT-X-START:TIME-OFFSET=$startSeconds.000,PRECISE=YES\n'
        : '';
    final playlist = '''
#EXTM3U
#EXT-X-VERSION:7
$startTag#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-TARGETDURATION:$duration
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:$duration.000,
$baseUrl/$mediaPath
#EXT-X-ENDLIST
''';
    request.response
      ..statusCode = io.HttpStatus.ok
      ..headers.contentType =
          io.ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8')
      ..write(playlist);
    await request.response.close();
  }

  int _hlsStartSeconds(io.HttpRequest request) {
    final raw = request.uri.queryParameters['start']?.trim() ?? '';
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) {
      return 0;
    }
    final duration = _durationSeconds > 0 ? _durationSeconds : 24 * 60 * 60;
    return parsed.clamp(0, max(0, duration - 1)).toInt();
  }

  Future<void> _writeVlcPlaylist(io.HttpRequest request) async {
    final playlist = _buildVlcPlaylist();
    request.response
      ..statusCode = io.HttpStatus.ok
      ..headers.contentType =
          io.ContentType('audio', 'mpegurl', charset: 'utf-8')
      ..write(playlist);
    await request.response.close();
  }

  Future<void> _writeLocalVlcPlaylist() async {
    await _vlcPlaylistFile.writeAsString(_buildVlcPlaylist(), flush: true);
  }

  String _buildVlcPlaylist() {
    final baseUrl = 'http://127.0.0.1:${_server.port}';
    final duration = _durationSeconds > 0 ? _durationSeconds : -1;
    final title = _escapeM3uText(_pageUrl.split('/').last);
    return '''
#EXTM3U
#EXTVLCOPT:input-slave=$baseUrl/audio.m4s
#EXTINF:$duration,$title
$baseUrl/video.m4s
''';
  }

  String _escapeM3uText(String value) {
    return value.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
  }

  Future<void> _proxyMedia(io.HttpRequest request, String upstreamUrl) async {
    final upstreamRequest = http.Request('GET', Uri.parse(upstreamUrl));
    upstreamRequest.headers.addAll({
      'Accept': '*/*',
      'User-Agent': _userAgent,
      'Referer': _pageUrl,
      'Origin': Uri.parse(_pageUrl).origin,
      if (request.headers.value(io.HttpHeaders.rangeHeader) != null)
        io.HttpHeaders.rangeHeader:
            request.headers.value(io.HttpHeaders.rangeHeader)!,
    });
    http.StreamedResponse? upstream;
    var responseStarted = false;
    try {
      upstream = await _client
          .send(upstreamRequest)
          .timeout(const Duration(seconds: 20));
      request.response.statusCode = upstream.statusCode;
      for (final name in const [
        io.HttpHeaders.acceptRangesHeader,
        io.HttpHeaders.contentLengthHeader,
        io.HttpHeaders.contentRangeHeader,
        io.HttpHeaders.contentTypeHeader,
        io.HttpHeaders.cacheControlHeader,
      ]) {
        final value = upstream.headers[name];
        if (value != null && value.trim().isNotEmpty) {
          request.response.headers.set(name, value);
        }
      }
      responseStarted = true;
      await upstream.stream.pipe(request.response);
    } catch (_) {
      if (!responseStarted) {
        request.response.statusCode = io.HttpStatus.badGateway;
        await request.response.close();
      }
    }
  }
}

class _HostCandidate {
  const _HostCandidate({
    required this.url,
    this.server = '',
    this.scoreBonus = 0,
  });

  final String url;
  final String server;
  final int scoreBonus;
}

class _FacebookMediaCandidate {
  const _FacebookMediaCandidate(this.url, this.scoreBonus);

  final String url;
  final int scoreBonus;
}

class _RemoteEpisodeLink {
  const _RemoteEpisodeLink({
    required this.episodeNumber,
    required this.url,
  });

  final int episodeNumber;
  final String url;
}

class _BiliBiliVideoResult {
  const _BiliBiliVideoResult({
    required this.videoId,
    required this.url,
    required this.title,
    required this.imageUrl,
    required this.durationLabel,
    required this.episodeNumber,
  });

  final String videoId;
  final String url;
  final String title;
  final String imageUrl;
  final String durationLabel;
  final int episodeNumber;
}

class _BiliBiliPlaybackOption {
  const _BiliBiliPlaybackOption({
    required this.server,
    required this.url,
    required this.title,
    required this.imageUrl,
    required this.durationLabel,
  });

  final String server;
  final String url;
  final String title;
  final String imageUrl;
  final String durationLabel;
}

class _YoutubePlaybackOption {
  const _YoutubePlaybackOption({
    required this.server,
    required this.mode,
    required this.option,
    required this.videoId,
    required this.url,
    required this.title,
    required this.imageUrl,
    required this.durationLabel,
  });

  final String server;
  final YoutubePlaybackMode mode;
  final YoutubePlaybackOption option;
  final String videoId;
  final String url;
  final String title;
  final String imageUrl;
  final String durationLabel;

  _YoutubePlaybackOption copyWith({
    String? server,
    YoutubePlaybackMode? mode,
    YoutubePlaybackOption? option,
    String? videoId,
    String? url,
    String? title,
    String? imageUrl,
    String? durationLabel,
  }) {
    return _YoutubePlaybackOption(
      server: server ?? this.server,
      mode: mode ?? this.mode,
      option: option ?? this.option,
      videoId: videoId ?? this.videoId,
      url: url ?? this.url,
      title: title ?? this.title,
      imageUrl: imageUrl ?? this.imageUrl,
      durationLabel: durationLabel ?? this.durationLabel,
    );
  }
}

class _YtDlpResult {
  const _YtDlpResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

class _BiliBiliSeriesAccumulator {
  _BiliBiliSeriesAccumulator({
    required this.key,
    required this.title,
    required this.slug,
    required this.imageUrl,
  });

  final String key;
  final String title;
  final String slug;
  final String imageUrl;
  final Map<int, SeriesEpisodeMetadata> _episodes = {};

  List<SeriesEpisodeMetadata> get episodes {
    final values = _episodes.values.toList()
      ..sort((left, right) => left.episodeNumber.compareTo(
            right.episodeNumber,
          ));
    return values;
  }

  void add(SeriesEpisodeMetadata episode) {
    if (episode.episodeNumber <= 0) {
      return;
    }
    _episodes.putIfAbsent(episode.episodeNumber, () => episode);
  }

  RemoteSearchCandidate toCandidate() {
    final details = episodes;
    final firstEpisodeUrl = details
        .map((entry) => entry.description.trim())
        .firstWhere((entry) => entry.isNotEmpty, orElse: () => '');
    return RemoteSearchCandidate(
      provider: RemoteProvider.bilibili,
      slug: slug,
      title: title,
      seriesUrl: Uri.https('www.bilibili.tv', '/en/search-result', {
        'q': title,
      }).toString(),
      watchUrl: firstEpisodeUrl,
      imageUrl: imageUrl,
      episodeCount: details.length,
      format: 'UGC',
      episodeDetails: details,
    );
  }
}

class _TmdbMatch {
  const _TmdbMatch({
    required this.id,
    required this.title,
    required this.originalTitle,
    required this.releaseYear,
    required this.imageUrl,
    required this.backgroundUrl,
  });

  final int id;
  final String title;
  final String originalTitle;
  final int releaseYear;
  final String imageUrl;
  final String backgroundUrl;
}

class _SeriesVisuals {
  const _SeriesVisuals({
    this.title = '',
    this.originalTitle = '',
    this.logoUrl = '',
    this.imageUrl = '',
    this.backgroundUrl = '',
    this.description = '',
    this.trailerUrl = '',
    this.rating = '',
    this.cast = const [],
    this.episodes = const [],
  });

  final String title;
  final String originalTitle;
  final String logoUrl;
  final String imageUrl;
  final String backgroundUrl;
  final String description;
  final String trailerUrl;
  final String rating;
  final List<String> cast;
  final List<SeriesEpisodeMetadata> episodes;

  bool get hasMeaningfulContent =>
      logoUrl.isNotEmpty ||
      imageUrl.isNotEmpty ||
      backgroundUrl.isNotEmpty ||
      description.isNotEmpty ||
      trailerUrl.isNotEmpty ||
      rating.isNotEmpty ||
      cast.isNotEmpty ||
      episodes.isNotEmpty;
}

String _readString(Object? value, {String fallback = ''}) {
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  return fallback;
}

String _cleanRemoteText(String value) {
  final cleaned = _decodeHtml(value.replaceAll(RegExp(r'<[^>]*>'), ' '))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  switch (cleaned.toLowerCase()) {
    case '':
    case 'null':
    case 'undefined':
    case 'nan':
      return '';
    default:
      return cleaned;
  }
}

String _cleanRemoteUrl(String value) {
  final cleaned = value.trim();
  switch (cleaned.toLowerCase()) {
    case '':
    case 'null':
    case 'undefined':
    case 'nan':
      return '';
    default:
      return cleaned;
  }
}

String _stripProviderSuffix(String value) {
  return value
      .replaceAll(
        RegExp(
          r'\s*\((AnimeAV1|AnimeKai|JKAnime|LatAnime|AnimeFLV|Facebook|Internet Archive|BiliBili|YouTube|Catalogo)(\s+\d+)?\)\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
}

class _InternetArchiveVideoFile {
  const _InternetArchiveVideoFile({
    required this.name,
    required this.episodeNumber,
    required this.source,
    required this.format,
    required this.lengthSeconds,
  });

  final String name;
  final int episodeNumber;
  final String source;
  final String format;
  final int lengthSeconds;

  String get displayName {
    final base = name.split('/').last;
    final withoutExtension = base.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return _cleanRemoteText(
      _safeDecodeUriComponent(withoutExtension).replaceAll('+', ' '),
    );
  }

  String get durationLabel {
    if (lengthSeconds <= 0) {
      return '';
    }
    final duration = Duration(seconds: lengthSeconds);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _InternetArchivePlaylistItem {
  const _InternetArchivePlaylistItem({
    required this.title,
    required this.orig,
    required this.sourceFile,
    required this.episodeNumber,
    required this.durationSeconds,
  });

  final String title;
  final String orig;
  final String sourceFile;
  final int episodeNumber;
  final int durationSeconds;
}

String _decodeHtml(String value) {
  return value
      .replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
        final codePoint = int.tryParse(match.group(1) ?? '');
        return codePoint == null
            ? match.group(0) ?? ''
            : String.fromCharCode(codePoint);
      })
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
        final codePoint = int.tryParse(match.group(1) ?? '', radix: 16);
        return codePoint == null
            ? match.group(0) ?? ''
            : String.fromCharCode(codePoint);
      })
      .replaceAll('&amp;', '&')
      .replaceAll('&apos;', "'")
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&frac12;', '1/2');
}

String _safeDecodeUriComponent(String value) {
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return value;
  } on ArgumentError {
    return value;
  }
}

int _readInt(Object? value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.truncate();
  }
  return int.tryParse('$value') ?? fallback;
}

double _readDouble(Object? value, {double fallback = 0}) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse('$value') ?? fallback;
}

String _readScore(Object? value) {
  if (value is num && value > 0) {
    return value.toStringAsFixed(1);
  }
  return '';
}

int _yearFromAired(Object? value) {
  if (value is! Map) {
    return 0;
  }
  final from = _readString(value['from']);
  if (from.length < 4) {
    return 0;
  }
  return int.tryParse(from.substring(0, 4)) ?? 0;
}

String _airedIso(Object? value) {
  if (value is! Map) {
    return '';
  }
  return _readString(value['from']);
}

String _firstNonEmpty(Iterable<String> values) {
  for (final value in values) {
    if (value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return '';
}
