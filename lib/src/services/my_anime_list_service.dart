import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../build_config.dart';
import '../models.dart';

class MyAnimeListService {
  MyAnimeListService({
    http.Client? client,
    String defaultClientId = const String.fromEnvironment(
      'MYANIMELIST_CLIENT_ID',
      defaultValue: buildDefaultMyAnimeListClientId,
    ),
    String defaultClientSecret = const String.fromEnvironment(
      'MYANIMELIST_CLIENT_SECRET',
      defaultValue: buildDefaultMyAnimeListClientSecret,
    ),
    String authBaseUrl = 'https://myanimelist.net/v1/oauth2',
    String apiBaseUrl = 'https://api.myanimelist.net/v2',
  })  : _client = client ?? http.Client(),
        _defaultClientId = defaultClientId.trim(),
        _defaultClientSecret = defaultClientSecret.trim(),
        _authBaseUri = Uri.parse(authBaseUrl),
        _apiBaseUri = Uri.parse(apiBaseUrl);

  static const redirectUri = 'toonamitvshell://mal-auth/callback';
  static const favoriteTag = 'toonami.favorite';
  static const syntheticPlanToWatchTag = 'toonami.status.none';
  static const _userAgent = 'TanukiFlutter/1.0';
  static const _authRefreshLeewayMs = 60000;
  static const _maxSearchQueryLength = 64;

  final http.Client _client;
  final String _defaultClientId;
  final String _defaultClientSecret;
  final Uri _authBaseUri;
  final Uri _apiBaseUri;

  String resolveClientId(String configuredClientId) {
    final configured = configuredClientId.trim();
    return configured.isNotEmpty ? configured : _defaultClientId;
  }

  String resolveClientSecret(String configuredClientSecret) {
    final configured = configuredClientSecret.trim();
    return configured.isNotEmpty ? configured : _defaultClientSecret;
  }

  bool hasConfiguredClientId(String configuredClientId) {
    return resolveClientId(configuredClientId).isNotEmpty;
  }

  MyAnimeListPendingAuthorization buildAuthorizationRequest({
    required String clientId,
  }) {
    final normalizedClientId = clientId.trim();
    if (normalizedClientId.isEmpty) {
      throw const MyAnimeListException('Falta el Client ID de MyAnimeList.');
    }
    final request = MyAnimeListPendingAuthorization(
      clientId: normalizedClientId,
      state: _randomToken(48),
      codeVerifier: _randomToken(72),
      requestedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    return request.copyWith(authorizationUrl: buildAuthorizationUrl(request));
  }

  String buildAuthorizationUrl(MyAnimeListPendingAuthorization request) {
    return _authUri(
      '/authorize',
      query: {
        'response_type': 'code',
        'client_id': request.clientId,
        'state': request.state,
        'redirect_uri': redirectUri,
        'code_challenge': request.codeVerifier,
        'code_challenge_method': 'plain',
      },
    ).toString();
  }

  bool looksLikeAuthorizationRedirect(String value) {
    return value.trim().toLowerCase().startsWith(redirectUri.toLowerCase());
  }

  Future<MyAnimeListAuthState> completeAuthorization({
    required MyAnimeListPendingAuthorization request,
    required String redirectUrl,
    required String clientSecret,
  }) async {
    final uri = Uri.tryParse(redirectUrl.trim());
    if (uri == null || !looksLikeAuthorizationRedirect(uri.toString())) {
      throw const MyAnimeListException(
          'La URL de retorno de MyAnimeList no es valida.');
    }
    final error = _readString(uri.queryParameters['error']);
    if (error.isNotEmpty) {
      throw MyAnimeListException('MyAnimeList rechazo la autorizacion: $error');
    }
    final returnedState = _readString(uri.queryParameters['state']);
    if (returnedState != request.state) {
      throw const MyAnimeListException(
          'La respuesta de MyAnimeList no coincide con la sesion abierta.');
    }
    final code = _readString(uri.queryParameters['code']);
    if (code.isEmpty) {
      throw const MyAnimeListException(
          'MyAnimeList no devolvio un codigo de autorizacion.');
    }
    final token = await _exchangeAuthorizationCode(
      clientId: request.clientId,
      clientSecret: clientSecret,
      code: code,
      codeVerifier: request.codeVerifier,
    );
    final user = await fetchAuthenticatedUser(accessToken: token.accessToken);
    return MyAnimeListAuthState(
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAtMs: token.expiresAtMs,
      userId: user.userId,
      userName: user.userName,
      userPictureUrl: user.pictureUrl,
      connectedAtMs: DateTime.now().millisecondsSinceEpoch,
      lastSyncStatus: 'Cuenta MyAnimeList conectada.',
    );
  }

  Future<MyAnimeListAuthState> ensureFreshAuth({
    required MyAnimeListAuthState auth,
    required String clientId,
    required String clientSecret,
  }) async {
    if (!auth.isConnected) {
      throw const MyAnimeListException(
          'Este perfil todavia no esta conectado a MyAnimeList.');
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (auth.expiresAtMs <= 0 ||
        auth.expiresAtMs > nowMs + _authRefreshLeewayMs) {
      return auth;
    }
    final normalizedClientId = clientId.trim();
    if (normalizedClientId.isEmpty) {
      throw const MyAnimeListException(
          'Falta el Client ID de MyAnimeList para refrescar el token.');
    }
    final refreshed = await _refreshAccessToken(
      clientId: normalizedClientId,
      clientSecret: clientSecret,
      refreshToken: auth.refreshToken,
    );
    return auth.copyWith(
      accessToken: refreshed.accessToken,
      refreshToken: refreshed.refreshToken.isEmpty
          ? auth.refreshToken
          : refreshed.refreshToken,
      expiresAtMs: refreshed.expiresAtMs,
      lastSyncError: '',
    );
  }

  Future<MyAnimeListAuthenticatedUser> fetchAuthenticatedUser({
    required String accessToken,
  }) async {
    final response = await _getApi(
      '/users/@me',
      accessToken: accessToken,
    );
    final json = _expectJsonObject(response);
    return MyAnimeListAuthenticatedUser(
      userId: _readInt(json['id']),
      userName: _readString(json['name'], fallback: 'MyAnimeList'),
      pictureUrl: _readString(json['picture']),
    );
  }

  Future<MyAnimeListPushResult> pushLocalAnimeState({
    required String accessToken,
    required List<MyAnimeListLocalAnimeUpdate> updates,
  }) async {
    var pushed = 0;
    final unresolved = <String>[];
    final mappings = <String, int>{};

    for (final update in updates) {
      final animeId = await _resolveAnimeId(
        accessToken: accessToken,
        update: update,
      );
      if (animeId <= 0) {
        unresolved.add(update.seriesKey);
        continue;
      }

      final remoteStatus = await _fetchAnimeListStatus(
        accessToken: accessToken,
        animeId: animeId,
      );
      final status = update.listStatus.trim();
      final persistedStatus = status.isNotEmpty
          ? status
          : update.favorite
              ? 'plan_to_watch'
              : '';
      final mergedTags = _normalizeTags(
        [
          ...?remoteStatus?.tags.where((tag) => !_isManagedTag(tag)),
          ..._managedTagsFor(update, persistedStatus),
        ],
      );

      final nothingToPersist = persistedStatus.isEmpty &&
          update.watchedEpisodes <= 0 &&
          mergedTags.isEmpty;
      if (nothingToPersist) {
        if (remoteStatus != null) {
          await _deleteAnimeListStatus(
            accessToken: accessToken,
            animeId: animeId,
          );
          pushed += 1;
        }
        mappings[update.seriesKey] = animeId;
        continue;
      }

      final params = <String, String>{};
      if (persistedStatus.isNotEmpty) {
        params['status'] = persistedStatus;
      }
      if (update.watchedEpisodes > 0 || persistedStatus == 'completed') {
        params['num_watched_episodes'] =
            _watchedEpisodePayload(update, persistedStatus).toString();
      }
      if (mergedTags.isNotEmpty || remoteStatus != null) {
        params['tags'] = mergedTags.join(',');
      }
      if (params.isEmpty) {
        continue;
      }

      await _updateAnimeListStatus(
        accessToken: accessToken,
        animeId: animeId,
        params: params,
      );
      pushed += 1;
      mappings[update.seriesKey] = animeId;
    }

    return MyAnimeListPushResult(
      pushedCount: pushed,
      mappings: mappings,
      unresolvedKeys: unresolved.toSet().toList(),
    );
  }

  Future<MyAnimeListRemoteSyncResult> fetchRemoteAnimeState({
    required String accessToken,
  }) async {
    final entries = <MyAnimeListRemoteAnimeEntry>[];
    Uri? nextUri = _apiUri(
      '/users/@me/animelist',
      query: const {
        'limit': '1000',
        'fields':
            'list_status,alternative_titles,start_date,media_type,num_episodes',
        'sort': 'list_updated_at',
      },
    );

    while (nextUri != null) {
      final response = await _client.get(
        nextUri,
        headers: _headers(accessToken: accessToken),
      );
      final json = _expectJsonObject(response);
      for (final item in _readList(json['data'])) {
        if (item is! Map) {
          continue;
        }
        final node = _readMap(item['node']);
        final animeId = _readInt(node['id']);
        final title = _readString(node['title']);
        if (animeId <= 0 || title.isEmpty) {
          continue;
        }
        final alternativeTitles = _parseAlternativeTitles(
          _readNullableMap(node['alternative_titles']),
        );
        entries.add(
          MyAnimeListRemoteAnimeEntry(
            malId: animeId,
            title: title,
            imageUrl: _parseNodeImage(node),
            aliases: alternativeTitles
                .where((alias) => !alias.equalsIgnoreCase(title))
                .toList(),
            japaneseTitle:
                _readString(_readMap(node['alternative_titles'])['ja']),
            year: _readString(node['start_date']).take(4).toIntOrZero(),
            mediaType: _readString(node['media_type']),
            episodeCount:
                _readInt(node['num_episodes']).clamp(0, 10000).toInt(),
            status: _parseAnimeListStatus(
              _readNullableMap(item['list_status']),
            ),
          ),
        );
      }
      final next = _readString(_readMap(json['paging'])['next']);
      nextUri = next.isEmpty ? null : Uri.parse(next);
    }

    return MyAnimeListRemoteSyncResult(
      remoteEntries: entries.toSetBy((entry) => entry.malId),
    );
  }

  void close() {
    _client.close();
  }

  Future<_OAuthToken> _refreshAccessToken({
    required String clientId,
    required String clientSecret,
    required String refreshToken,
  }) async {
    final response = await _client.post(
      _authUri('/token'),
      headers: _headers(form: true),
      body: {
        'client_id': clientId.trim(),
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken.trim(),
        if (clientSecret.trim().isNotEmpty)
          'client_secret': clientSecret.trim(),
      },
    );
    final json = _expectJsonObject(response);
    return _OAuthToken(
      accessToken: _readString(json['access_token']),
      refreshToken: _readString(json['refresh_token']),
      expiresAtMs: DateTime.now().millisecondsSinceEpoch +
          (_readInt(json['expires_in']).clamp(0, 31536000).toInt() * 1000),
    );
  }

  Future<_OAuthToken> _exchangeAuthorizationCode({
    required String clientId,
    required String clientSecret,
    required String code,
    required String codeVerifier,
  }) async {
    final response = await _client.post(
      _authUri('/token'),
      headers: _headers(form: true),
      body: {
        'client_id': clientId.trim(),
        'grant_type': 'authorization_code',
        'code': code.trim(),
        'redirect_uri': redirectUri,
        'code_verifier': codeVerifier.trim(),
        if (clientSecret.trim().isNotEmpty)
          'client_secret': clientSecret.trim(),
      },
    );
    final json = _expectJsonObject(response);
    return _OAuthToken(
      accessToken: _readString(json['access_token']),
      refreshToken: _readString(json['refresh_token']),
      expiresAtMs: DateTime.now().millisecondsSinceEpoch +
          (_readInt(json['expires_in']).clamp(0, 31536000).toInt() * 1000),
    );
  }

  Future<int> _resolveAnimeId({
    required String accessToken,
    required MyAnimeListLocalAnimeUpdate update,
  }) async {
    if (update.malId > 0) {
      return update.malId;
    }

    MyAnimeListRemoteAnimeEntry? bestEntry;
    var bestScore = -1 << 31;
    for (final query in _searchQueries(update)) {
      final response = await _client.get(
        _apiUri(
          '/anime',
          query: {
            'q': query,
            'limit': '12',
            'fields': 'alternative_titles,start_date,media_type,num_episodes',
          },
        ),
        headers: _headers(accessToken: accessToken),
      );
      if (!_isOk(response)) {
        if (_isInvalidSearchQuery(response.body)) {
          continue;
        }
        throw MyAnimeListException(
          _extractApiError(response.body, response.statusCode),
        );
      }
      final json = _decodeJsonObject(response.body);
      for (final item in _readList(json['data'])) {
        if (item is! Map) {
          continue;
        }
        final node = _readMap(item['node']);
        final animeId = _readInt(node['id']);
        final title = _readString(node['title']);
        if (animeId <= 0 || title.isEmpty) {
          continue;
        }
        final candidate = MyAnimeListRemoteAnimeEntry(
          malId: animeId,
          title: title,
          imageUrl: _parseNodeImage(node),
          aliases: _parseAlternativeTitles(
            _readNullableMap(node['alternative_titles']),
          ),
          japaneseTitle:
              _readString(_readMap(node['alternative_titles'])['ja']),
          year: _readString(node['start_date']).take(4).toIntOrZero(),
          mediaType: _readString(node['media_type']),
          episodeCount: _readInt(node['num_episodes']).clamp(0, 10000).toInt(),
          status: const MyAnimeListRemoteStatus(),
        );
        final score = _scoreMatch(update, candidate);
        if (score > bestScore) {
          bestScore = score;
          bestEntry = candidate;
        }
      }
    }
    return bestScore >= 50 ? bestEntry?.malId ?? 0 : 0;
  }

  Future<MyAnimeListRemoteStatus?> _fetchAnimeListStatus({
    required String accessToken,
    required int animeId,
  }) async {
    final response = await _getApi(
      '/anime/$animeId',
      query: const {'fields': 'my_list_status'},
      accessToken: accessToken,
    );
    final json = _expectJsonObject(response);
    return _parseNullableAnimeListStatus(
      _readNullableMap(json['my_list_status']),
    );
  }

  Future<void> _updateAnimeListStatus({
    required String accessToken,
    required int animeId,
    required Map<String, String> params,
  }) async {
    final response = await _client.put(
      _apiUri('/anime/$animeId/my_list_status'),
      headers: _headers(accessToken: accessToken, form: true),
      body: params,
    );
    _expectJsonObject(response);
  }

  Future<void> _deleteAnimeListStatus({
    required String accessToken,
    required int animeId,
  }) async {
    final response = await _client.delete(
      _apiUri('/anime/$animeId/my_list_status'),
      headers: _headers(accessToken: accessToken),
    );
    if (!_isOk(response) && response.statusCode != 404) {
      throw MyAnimeListException(
        _extractApiError(response.body, response.statusCode),
      );
    }
  }

  Future<http.Response> _getApi(
    String path, {
    Map<String, String> query = const {},
    String accessToken = '',
  }) {
    return _client.get(
      _apiUri(path, query: query),
      headers: _headers(accessToken: accessToken),
    );
  }

  Uri _apiUri(String path, {Map<String, String> query = const {}}) {
    return _baseUri(_apiBaseUri, path, query: query);
  }

  Uri _authUri(String path, {Map<String, String> query = const {}}) {
    return _baseUri(_authBaseUri, path, query: query);
  }

  Uri _baseUri(
    Uri base,
    String path, {
    Map<String, String> query = const {},
  }) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      final uri = Uri.parse(path);
      return query.isEmpty ? uri : uri.replace(queryParameters: query);
    }
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return base.replace(
      path: '$basePath$normalizedPath',
      queryParameters: query.isEmpty ? null : query,
    );
  }

  Map<String, String> _headers({
    String accessToken = '',
    bool form = false,
  }) {
    return {
      'Accept': 'application/json',
      'User-Agent': _userAgent,
      if (accessToken.trim().isNotEmpty)
        'Authorization': 'Bearer ${accessToken.trim()}',
      if (form) 'Content-Type': 'application/x-www-form-urlencoded',
    };
  }

  Map<String, dynamic> _expectJsonObject(http.Response response) {
    final json = _decodeJsonObject(response.body);
    if (!_isOk(response)) {
      throw MyAnimeListException(
        _extractApiError(response.body, response.statusCode),
      );
    }
    return json;
  }

  bool _isOk(http.Response response) {
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  Map<String, dynamic> _decodeJsonObject(String body) {
    if (body.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    return const {};
  }

  String _extractApiError(String body, int statusCode) {
    final json = _safeDecodeJsonObject(body);
    final parts = [
      'MyAnimeList respondio $statusCode',
      _readString(json['error']),
      _readString(json['error_description']),
      _readString(json['message']),
    ].where((part) => part.trim().isNotEmpty).toList();
    return parts.join(': ');
  }

  Map<String, dynamic> _safeDecodeJsonObject(String body) {
    try {
      return _decodeJsonObject(body);
    } catch (_) {
      return const {};
    }
  }

  bool _isInvalidSearchQuery(String body) {
    return body.toLowerCase().contains('invalid q');
  }

  MyAnimeListRemoteStatus _parseAnimeListStatus(Map<String, dynamic>? json) {
    return _parseNullableAnimeListStatus(json) ??
        const MyAnimeListRemoteStatus();
  }

  MyAnimeListRemoteStatus? _parseNullableAnimeListStatus(
    Map<String, dynamic>? json,
  ) {
    if (json == null) {
      return null;
    }
    return MyAnimeListRemoteStatus(
      status: _readString(json['status']).toLowerCase(),
      watchedEpisodes: max(
        _readInt(json['num_episodes_watched']),
        _readInt(json['num_watched_episodes']),
      ),
      tags: _normalizeTags(_parseTags(json['tags'])),
      updatedAt: _readString(json['updated_at']),
    );
  }

  List<String> _parseTags(Object? value) {
    if (value is List) {
      return value.map(_readString).where((tag) => tag.isNotEmpty).toList();
    }
    if (value is String) {
      return value
          .split(',')
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toList();
    }
    return const [];
  }

  List<String> _parseAlternativeTitles(Map<String, dynamic>? json) {
    if (json == null) {
      return const [];
    }
    return [
      _readString(json['en']),
      _readString(json['ja']),
      ..._readList(json['synonyms']).map(_readString),
    ].where((title) => title.isNotEmpty).toSet().toList();
  }

  String _parseNodeImage(Map<String, dynamic> node) {
    final picture = _readMap(node['main_picture']);
    return _readString(
      picture['large'],
      fallback: _readString(picture['medium']),
    );
  }

  List<String> _searchQueries(MyAnimeListLocalAnimeUpdate update) {
    final values = <String, String>{};
    for (final title in [
      update.title,
      update.japaneseTitle,
      ...update.aliases,
    ]) {
      for (final variant in _searchVariants(title)) {
        final sanitized = _sanitizeSearchQuery(variant);
        if (sanitized.length >= 3) {
          values.putIfAbsent(sanitized.toLowerCase(), () => sanitized);
        }
      }
    }
    return values.values.toList();
  }

  List<String> _searchVariants(String value) {
    final title = _collapseWhitespace(value);
    if (title.isEmpty) {
      return const [];
    }
    final variants = <String>{title};
    variants.add(title.replaceFirst(RegExp(r'\s*[\(\[].*?$'), '').trim());
    variants.add(title.replaceAll(RegExp(r'[,:;!?.]+'), ' ').trim());
    for (final separator in [':', ' - ', ' - ', ' | ', ' / ']) {
      final index = title.indexOf(separator);
      if (index > 0) {
        variants.add(title.substring(0, index).trim());
      }
    }
    return variants.where((entry) => entry.isNotEmpty).toList();
  }

  String _sanitizeSearchQuery(String value) {
    var sanitized = _collapseWhitespace(value).trimChars(' -:/|,;');
    if (sanitized.length > _maxSearchQueryLength) {
      final shortened = sanitized.substring(0, _maxSearchQueryLength).trim();
      final lastSpace = shortened.lastIndexOf(' ');
      sanitized = lastSpace >= _maxSearchQueryLength ~/ 2
          ? shortened.substring(0, lastSpace).trim()
          : shortened;
    }
    return sanitized.trimChars(' -:/|,;');
  }

  int _scoreMatch(
    MyAnimeListLocalAnimeUpdate update,
    MyAnimeListRemoteAnimeEntry candidate,
  ) {
    var score = 0;
    final requestedTitles = [
      update.title,
      update.japaneseTitle,
      ...update.aliases,
    ].map(_normalizeTitle).where((title) => title.isNotEmpty).toSet();
    final candidateTitles = [
      candidate.title,
      candidate.japaneseTitle,
      ...candidate.aliases,
    ].map(_normalizeTitle).where((title) => title.isNotEmpty).toSet();
    if (requestedTitles.any(candidateTitles.contains)) {
      score += 120;
    }

    final requestedTokens = requestedTitles.expand(_tokens).toSet();
    final candidateTokens = candidateTitles.expand(_tokens).toSet();
    score += requestedTokens.intersection(candidateTokens).length * 12;

    if (update.year > 0 && candidate.year > 0) {
      final diff = (update.year - candidate.year).abs();
      score += switch (diff) {
        0 => 40,
        1 => 18,
        _ => -24,
      };
    }

    if (update.episodeCount > 0 && candidate.episodeCount > 0) {
      final diff = (update.episodeCount - candidate.episodeCount).abs();
      score += switch (diff) {
        0 => 24,
        <= 2 => 8,
        _ => -10,
      };
    }

    final requestedMovie = _isMovieFormat(update.format);
    final candidateMovie = _isMovieFormat(candidate.mediaType);
    if (update.format.trim().isNotEmpty && requestedMovie != candidateMovie) {
      score -= 55;
    } else if (update.format.trim().isNotEmpty) {
      score += 12;
    }

    return score;
  }

  List<String> _managedTagsFor(
    MyAnimeListLocalAnimeUpdate update,
    String effectiveStatus,
  ) {
    return [
      if (update.favorite) favoriteTag,
      if (update.favorite &&
          effectiveStatus.isEmpty &&
          update.watchedEpisodes <= 0)
        syntheticPlanToWatchTag,
    ];
  }

  int _watchedEpisodePayload(
    MyAnimeListLocalAnimeUpdate update,
    String status,
  ) {
    if (status == 'completed' && update.episodeCount > 0) {
      return max(update.watchedEpisodes, update.episodeCount);
    }
    return max(update.watchedEpisodes, 0);
  }

  List<String> _normalizeTags(Iterable<String> tags) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final tag in tags) {
      final clean = tag.trim();
      if (clean.isEmpty) {
        continue;
      }
      if (seen.add(clean.toLowerCase())) {
        normalized.add(clean);
      }
    }
    return normalized;
  }

  bool _isManagedTag(String tag) {
    final normalized = tag.trim().toLowerCase();
    return normalized == favoriteTag || normalized == syntheticPlanToWatchTag;
  }

  bool _isMovieFormat(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'movie' ||
        normalized.contains('movie') ||
        normalized.contains('pelicula');
  }

  Iterable<String> _tokens(String value) {
    return value
        .split(' ')
        .map((token) => token.trim())
        .where((token) => token.length >= 3);
  }

  String _normalizeTitle(String value) {
    const replacements = {
      'á': 'a',
      'à': 'a',
      'ä': 'a',
      'â': 'a',
      'ã': 'a',
      'é': 'e',
      'è': 'e',
      'ë': 'e',
      'ê': 'e',
      'í': 'i',
      'ì': 'i',
      'ï': 'i',
      'î': 'i',
      'ó': 'o',
      'ò': 'o',
      'ö': 'o',
      'ô': 'o',
      'õ': 'o',
      'ú': 'u',
      'ù': 'u',
      'ü': 'u',
      'û': 'u',
      'ñ': 'n',
      'ç': 'c',
    };
    var normalized = value.toLowerCase();
    replacements.forEach((from, to) {
      normalized = normalized.replaceAll(from, to);
    });
    return normalized
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _collapseWhitespace(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _randomToken(int length) {
    const alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final random = Random.secure();
    final targetLength = max(length, 43);
    return String.fromCharCodes(
      List.generate(
        targetLength,
        (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ),
    );
  }
}

class MyAnimeListPendingAuthorization {
  const MyAnimeListPendingAuthorization({
    required this.clientId,
    required this.state,
    required this.codeVerifier,
    this.authorizationUrl = '',
    this.requestedAtMs = 0,
  });

  final String clientId;
  final String state;
  final String codeVerifier;
  final String authorizationUrl;
  final int requestedAtMs;

  MyAnimeListPendingAuthorization copyWith({
    String? authorizationUrl,
  }) {
    return MyAnimeListPendingAuthorization(
      clientId: clientId,
      state: state,
      codeVerifier: codeVerifier,
      authorizationUrl: authorizationUrl ?? this.authorizationUrl,
      requestedAtMs: requestedAtMs,
    );
  }
}

class MyAnimeListLocalAnimeUpdate {
  const MyAnimeListLocalAnimeUpdate({
    required this.seriesKey,
    required this.title,
    this.malId = 0,
    this.imageUrl = '',
    this.aliases = const [],
    this.japaneseTitle = '',
    this.year = 0,
    this.format = '',
    this.episodeCount = 0,
    this.watchedEpisodes = 0,
    this.favorite = false,
    this.listStatus = '',
  });

  final String seriesKey;
  final String title;
  final int malId;
  final String imageUrl;
  final List<String> aliases;
  final String japaneseTitle;
  final int year;
  final String format;
  final int episodeCount;
  final int watchedEpisodes;
  final bool favorite;
  final String listStatus;
}

class MyAnimeListRemoteAnimeEntry {
  const MyAnimeListRemoteAnimeEntry({
    required this.malId,
    required this.title,
    this.imageUrl = '',
    this.aliases = const [],
    this.japaneseTitle = '',
    this.year = 0,
    this.mediaType = '',
    this.episodeCount = 0,
    this.status = const MyAnimeListRemoteStatus(),
  });

  final int malId;
  final String title;
  final String imageUrl;
  final List<String> aliases;
  final String japaneseTitle;
  final int year;
  final String mediaType;
  final int episodeCount;
  final MyAnimeListRemoteStatus status;
}

class MyAnimeListRemoteStatus {
  const MyAnimeListRemoteStatus({
    this.status = '',
    this.watchedEpisodes = 0,
    this.tags = const [],
    this.updatedAt = '',
  });

  final String status;
  final int watchedEpisodes;
  final List<String> tags;
  final String updatedAt;
}

class MyAnimeListAuthenticatedUser {
  const MyAnimeListAuthenticatedUser({
    required this.userId,
    required this.userName,
    this.pictureUrl = '',
  });

  final int userId;
  final String userName;
  final String pictureUrl;
}

class MyAnimeListRemoteSyncResult {
  const MyAnimeListRemoteSyncResult({
    this.remoteEntries = const [],
  });

  final List<MyAnimeListRemoteAnimeEntry> remoteEntries;
}

class MyAnimeListPushResult {
  const MyAnimeListPushResult({
    this.pushedCount = 0,
    this.mappings = const {},
    this.unresolvedKeys = const [],
  });

  final int pushedCount;
  final Map<String, int> mappings;
  final List<String> unresolvedKeys;
}

class MyAnimeListException implements Exception {
  const MyAnimeListException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _OAuthToken {
  const _OAuthToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAtMs,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresAtMs;
}

extension on String {
  bool equalsIgnoreCase(String other) => toLowerCase() == other.toLowerCase();

  String take(int count) {
    if (count <= 0) {
      return '';
    }
    return length <= count ? this : substring(0, count);
  }

  int toIntOrZero() => int.tryParse(this) ?? 0;

  String trimChars(String chars) {
    var start = 0;
    var end = length;
    while (start < end && chars.contains(this[start])) {
      start += 1;
    }
    while (end > start && chars.contains(this[end - 1])) {
      end -= 1;
    }
    return substring(start, end);
  }
}

extension<T> on Iterable<T> {
  List<T> toSetBy(Object Function(T value) keyOf) {
    final result = <T>[];
    final keys = <Object>{};
    for (final value in this) {
      if (keys.add(keyOf(value))) {
        result.add(value);
      }
    }
    return result;
  }
}

String _readString(Object? value, {String fallback = ''}) {
  if (value == null) {
    return fallback;
  }
  final text = '$value'.trim();
  return text.isEmpty ? fallback : text;
}

int _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse('$value') ?? 0;
}

List<dynamic> _readList(Object? value) {
  return value is List ? value : const [];
}

Map<String, dynamic> _readMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const {};
}

Map<String, dynamic>? _readNullableMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return null;
}
