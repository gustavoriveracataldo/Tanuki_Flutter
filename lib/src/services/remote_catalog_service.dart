import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:http/http.dart' as http;

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
  })  : _client = client ?? http.Client(),
        _webResolver = webResolver ?? const RemoteWebResolver(),
        _tmdbBearerToken =
            _runtimeConfigValue(tmdbBearerToken, 'TMDB_BEARER_TOKEN'),
        _tmdbApiKey = _runtimeConfigValue(tmdbApiKey, 'TMDB_API_KEY'),
        _fanartApiKey = _runtimeConfigValue(fanartApiKey, 'FANART_API_KEY');

  static const _animeAv1BaseUrl = 'https://animeav1.com';
  static const _jkAnimeBaseUrl = 'https://jkanime.net';
  static const _latAnimeBaseUrl = 'https://latanime.org';
  static const _animeFlvBaseUrl = 'https://www4.animeflv.net';
  static const _tmdbImageBaseUrl = 'https://image.tmdb.org/t/p';
  static const _defaultFetchUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';
  static const _animeAv1ModeSubHls = 'sub-hls';
  static const _animeAv1ModeDubHls = 'dub-hls';

  final http.Client _client;
  final RemoteWebResolver _webResolver;
  final String _tmdbBearerToken;
  final String _tmdbApiKey;
  final String _fanartApiKey;

  static String _runtimeConfigValue(String dartDefineValue, String envKey) {
    final fromDefine = dartDefineValue.trim();
    if (fromDefine.isNotEmpty) {
      return fromDefine;
    }
    return (io.Platform.environment[envKey] ?? '').trim();
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
    ]);
    return _dedupe([...providerResults.expand((entry) => entry), ...catalog]);
  }

  Future<List<RemoteSearchCandidate>> searchCatalog(
    String query, {
    int limit = 25,
    int page = 1,
  }) {
    return _safeSearchJikan(
      query.trim(),
      limit: limit,
      page: page,
    );
  }

  Future<List<RemoteSearchCandidate>> discoverCatalogMovies({
    int limit = 25,
    int page = 1,
  }) async {
    final normalizedLimit = limit.clamp(1, 25).toInt();
    final normalizedPage = page < 1 ? 1 : page;
    final uri = Uri.https('api.jikan.moe', '/v4/anime', {
      'type': 'movie',
      'status': 'complete',
      'order_by': 'start_date',
      'sort': 'desc',
      'page': '$normalizedPage',
      'limit': '$normalizedLimit',
      'sfw': 'true',
    });
    final response = await _get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RemoteCatalogException(
        'Jikan peliculas respondio ${response.statusCode}',
      );
    }
    return _parseJikanCandidateList(response.body)
        .where((candidate) => _candidateLooksMovie(candidate))
        .toList(growable: false);
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
    return null;
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

  Future<List<RemoteSearchCandidate>> discoverCatalogBySeason({
    required String season,
    required int year,
    String type = '',
    int limit = 25,
    int page = 1,
  }) async {
    final normalizedSeason = season.trim().toLowerCase();
    if (!{'winter', 'spring', 'summer', 'fall'}.contains(normalizedSeason)) {
      return const [];
    }
    if (year < 1900 || year > 2100) {
      return const [];
    }
    final normalizedType = _normalizeCatalogType(type);
    final response = await _get(
      Uri.https(
        'api.jikan.moe',
        '/v4/seasons/$year/$normalizedSeason',
        {
          'page': '${page < 1 ? 1 : page}',
          'limit': '${limit.clamp(1, 25)}',
          'sfw': 'true',
          if (normalizedType.isNotEmpty) 'filter': normalizedType,
        },
      ),
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
      RemoteProvider.animeFlv => await _buildAnimeFlvSeries(enrichedCandidate,
          existingNames: existingNames),
      _ => enrichedCandidate.toSeries(existingNames: existingNames),
    };
  }

  Future<RemoteSearchCandidate> enrichCandidateVisuals(
      RemoteSearchCandidate candidate) async {
    return _enrichCatalogCandidateFromJikan(
      await _enrichCandidateVisuals(candidate),
    );
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
      RemoteProvider.animeFlv =>
        searchAnimeFlv(query, releaseYear: releaseYear),
      _ => Future.value(const <RemoteSearchCandidate>[]),
    };
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
    if (entry.provider == RemoteProvider.animeKai) {
      return null;
    }
    if (entry.provider != RemoteProvider.animeAv1) {
      final resolved = await _resolveGenericDirectStream(
        entry,
        preferredFacebookMode: preferredFacebookMode,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
      if (resolved != null) {
        return resolved;
      }
      return _resolvePlatformWebDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
    }
    final seriesUrl = _normalizeAnimeAv1SeriesUrl(
        entry.watchUrl.isNotEmpty ? entry.watchUrl : entry.filePath);
    if (seriesUrl.isEmpty) {
      return _resolvePlatformWebDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
    }
    final episodeUrl = _buildAnimeAv1EpisodeUrl(seriesUrl, entry.episodeNumber);
    if (episodeUrl.isEmpty) {
      return _resolvePlatformWebDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
    }
    final response = await _get(Uri.parse(episodeUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return _resolvePlatformWebDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
    }

    final playbackByMode = <String, String>{};
    final playPageByMode = <String, String>{};
    final subPlayUrl = _extractAnimeAv1PlayUrl(response.body, 'SUB');
    final subHls = _buildAnimeAv1HlsUrl(subPlayUrl);
    if (subHls.isNotEmpty) {
      playbackByMode[_animeAv1ModeSubHls] = subHls;
      playPageByMode[_animeAv1ModeSubHls] = subPlayUrl;
    }
    final dubPlayUrl = _extractAnimeAv1PlayUrl(response.body, 'DUB');
    final dubHls = _buildAnimeAv1HlsUrl(dubPlayUrl);
    if (dubHls.isNotEmpty) {
      playbackByMode[_animeAv1ModeDubHls] = dubHls;
      playPageByMode[_animeAv1ModeDubHls] = dubPlayUrl;
    }
    if (playbackByMode.isEmpty) {
      for (final playUrl
          in _extractAnimeAv1PlayUrls(response.body, episodeUrl)) {
        final hlsUrl = _buildAnimeAv1HlsUrl(playUrl);
        if (hlsUrl.isEmpty) {
          continue;
        }
        playbackByMode['iframe-hls'] = hlsUrl;
        playPageByMode['iframe-hls'] = playUrl;
        break;
      }
    }
    if (playbackByMode.isEmpty) {
      return _resolvePlatformWebDirectStream(
        entry,
        preferredServer: preferredServer,
        excludedServers: excludedServers,
      );
    }
    final selectedMode = playbackByMode.containsKey(preferredMode)
        ? preferredMode
        : playbackByMode.containsKey(_animeAv1ModeSubHls)
            ? _animeAv1ModeSubHls
            : playbackByMode.keys.first;
    final playbackUrl = playbackByMode[selectedMode] ?? '';
    if (playbackUrl.isEmpty) {
      return null;
    }
    return RemoteDirectStream(
      playbackUrl: playbackUrl,
      playbackKind: 'hls',
      pageUrl: playPageByMode[selectedMode] ?? episodeUrl,
      availableModes: playbackByMode.keys.toSet(),
      selectedMode: selectedMode,
    );
  }

  Future<RemoteDirectStream?> _resolvePlatformWebDirectStream(
    EpisodeItem entry, {
    String preferredServer = '',
    Set<String> excludedServers = const {},
  }) async {
    final provider = entry.provider;
    if (!_shouldUsePlatformWebResolver(provider)) {
      return null;
    }
    final pageUrl = _buildRemoteEpisodePageUrl(entry);
    if (pageUrl.isEmpty) {
      return null;
    }
    final resolved = await _webResolver.resolveDirectStream(
      entry: entry,
      pageUrl: pageUrl,
      referer: entry.watchUrl,
      preferredServer: preferredServer,
      excludedServers: excludedServers,
    );
    if (resolved == null) {
      return null;
    }
    final server = resolved.server.trim().isNotEmpty
        ? resolved.server
        : _normalizeServerPreference(
            resolved.pageUrl.trim().isNotEmpty
                ? resolved.pageUrl
                : resolved.playbackUrl,
          );
    return resolved.copyWith(provider: provider, server: server);
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
      return null;
    }
    final directKind = _inferPlaybackKind(pageUrl);
    if (directKind.isNotEmpty) {
      return RemoteDirectStream(
        playbackUrl: pageUrl,
        playbackKind: directKind,
        pageUrl: pageUrl,
        availableModes: const {'direct'},
        selectedMode: 'direct',
      );
    }

    final uri = Uri.tryParse(pageUrl);
    if (uri == null || !uri.hasScheme) {
      return null;
    }
    final response = await _get(uri, referer: entry.watchUrl);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    return _resolveDirectStreamFromHtml(
      html: response.body,
      pageUrl: pageUrl,
      referer: entry.watchUrl,
      visited: {pageUrl},
      preferredFacebookMode: preferredFacebookMode,
      preferredServer: preferredServer,
      excludedServers: excludedServers,
    );
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
      final resolved = await _resolveDirectStreamFromHtml(
        html: response.body,
        pageUrl: hostUrl,
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
        );
      }
    }
    return null;
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

  String _jikanTrailerUrl(Map trailer) {
    final youtubeId = _readString(trailer['youtube_id']);
    if (youtubeId.isNotEmpty) {
      return 'https://www.youtube.com/watch?v=$youtubeId';
    }
    return _firstNonEmpty([
      _readString(trailer['url']),
      _readString(trailer['embed_url']),
    ]);
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
      imageUrl: _firstNonEmpty([visuals.imageUrl, candidate.imageUrl]),
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
      episodeDetails: visuals.episodes.isNotEmpty
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
        _fetchJikanCandidateDetail(candidate.catalogId),
        _fetchJikanEpisodeMetadata(candidate.catalogId),
        _fetchJikanCast(candidate.catalogId),
      ]);
      final detail = results[0] as RemoteSearchCandidate?;
      final episodes = results[1] as List<SeriesEpisodeMetadata>;
      final cast = results[2] as List<String>;
      if (detail == null && episodes.isEmpty && cast.isEmpty) {
        return candidate;
      }
      final episodeCount = max(
        max(candidate.episodeCount, detail?.episodeCount ?? 0),
        episodes.length,
      );
      return _copyCandidate(
        candidate,
        watchUrl: _firstNonEmpty([candidate.watchUrl, detail?.watchUrl ?? '']),
        seriesUrl:
            _firstNonEmpty([candidate.seriesUrl, detail?.seriesUrl ?? '']),
        imageUrl: _firstNonEmpty([candidate.imageUrl, detail?.imageUrl ?? '']),
        backgroundUrl: _firstNonEmpty([
          candidate.backgroundUrl,
          detail?.backgroundUrl ?? '',
        ]),
        trailerUrl:
            _firstNonEmpty([candidate.trailerUrl, detail?.trailerUrl ?? '']),
        description: _firstNonEmpty([
          candidate.description,
          detail?.description ?? '',
        ]),
        rating: _firstNonEmpty([candidate.rating, detail?.rating ?? '']),
        episodeCount: episodeCount,
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
            _firstNonEmpty([candidate.airDateIso, detail?.airDateIso ?? '']),
        episodeDetails: _mergeEpisodeMetadata(
          candidate.episodeDetails,
          episodes,
        ),
        cast: _mergeCast(candidate.cast, [
          ...?detail?.cast,
          ...cast,
        ]),
      );
    } catch (_) {
      return candidate;
    }
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
    } catch (_) {
      return null;
    }
  }

  Future<_SeriesVisuals?> _fetchTmdbVisuals(
      RemoteSearchCandidate candidate) async {
    final mediaType = _candidateLooksMovie(candidate) ? 'movie' : 'tv';
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
    if (!_isCompatibleTmdbMatchYear(candidate.releaseYear, detailsYear)) {
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
    final explicitSeasonNumber = mediaType == 'tv'
        ? _explicitSeasonNumberForCandidate(candidate)
        : 0;
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
    final text = _normalizeMatchText([
      candidate.title,
      candidate.japaneseTitle,
      ...candidate.aliases,
      candidate.format,
      candidate.watchUrl,
      candidate.seriesUrl,
    ].join(' '));
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
          if (!_isCompatibleTmdbMatchYear(candidate.releaseYear, matchYear)) {
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
          final score = _scoreTmdbMatch(
                query: query,
                candidate: candidate,
                match: match,
              ) +
              max(0, 8 - queryIndex) * 25;
          if (score > bestScore) {
            bestScore = score;
            bestMatch = match;
          }
        }
      }
    }
    return bestScore <= 0 ? null : bestMatch;
  }

  _TmdbMatch? _forcedTmdbMatchForCandidate(
    RemoteSearchCandidate candidate,
    String mediaType,
  ) {
    if (mediaType != 'tv') {
      return null;
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

  bool _isCompatibleTmdbMatchYear(int requestedYear, int matchYear) {
    if (requestedYear <= 0 || matchYear <= 0) {
      return true;
    }
    return (requestedYear - matchYear).abs() <= 2;
  }

  List<String> _buildTmdbLookupQueries(RemoteSearchCandidate candidate) {
    final queries = <String>{
      candidate.title,
      candidate.japaneseTitle,
      ...candidate.aliases,
    }.map(_cleanRemoteText).where((entry) => entry.isNotEmpty).toList();
    return queries.toList();
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
        return 0;
      }
      score += switch (diff) {
        0 => 520,
        1 => 160,
        2 => 40,
        _ => 0,
      };
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
        if (detail.episodeNumber > 0) detail.episodeNumber: detail,
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
    bool explicitSeasonOnly = false,
  }) async {
    final primary =
        await _fetchTmdbSeasonEpisodes(seriesId, primarySeasonNumber);
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
    final episodeNumbers = <int>{
      ...primaryByEpisode.keys,
      ...supplementalByEpisode.keys,
    }.toList()
      ..sort();
    return [
      for (final episodeNumber in episodeNumbers)
        _mergeEpisodeDetail(
          primaryByEpisode[episodeNumber],
          supplementalByEpisode[episodeNumber],
        ),
    ];
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
      title: primary.title.isNotEmpty ? primary.title : supplemental.title,
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
    _client.close();
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

  String _buildRemoteEpisodePageUrl(EpisodeItem entry) {
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
      'desu' => 1000,
      'streamwish' => 860,
      'vidhide' => 720,
      'mixdrop' => 560,
      'doodstream' => 420,
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
      'yourupload' => 850,
      'doodstream' => 650,
      'mp4upload' => 450,
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
      'vidmoly',
      'vidstream',
      'vidoza',
      'upcloud',
      'megacloud',
      'filemoon',
      'mixdrop',
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
      score += 620;
    } else if (lower.contains('jkanime.net/jkplayer/um')) {
      score += 760;
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
    if (lower.contains('desu')) {
      score += 360;
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
}

class RemoteCatalogException implements Exception {
  const RemoteCatalogException(this.message);

  final String message;

  @override
  String toString() => message;
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
          r'\s*\((AnimeAV1|AnimeKai|JKAnime|LatAnime|AnimeFLV|Facebook|Catalogo)(\s+\d+)?\)\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
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
