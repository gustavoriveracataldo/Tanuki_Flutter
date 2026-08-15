import 'dart:convert';

import 'package:http/http.dart' as http;

import '../build_config.dart';

class SimklService {
  SimklService({
    http.Client? client,
    String defaultClientId = const String.fromEnvironment(
      'SIMKL_CLIENT_ID',
      defaultValue: buildDefaultSimklClientId,
    ),
    String apiBaseUrl = 'https://api.simkl.com',
  })  : _client = client ?? http.Client(),
        _defaultClientId = defaultClientId.trim(),
        _apiBaseUri = Uri.parse(apiBaseUrl);

  static const verificationUri = 'https://simkl.com/pin/';
  static const _userAgent = 'TanukiFlutter/1.0';

  final http.Client _client;
  final String _defaultClientId;
  final Uri _apiBaseUri;

  String resolveClientId(String configuredClientId) {
    final configured = configuredClientId.trim();
    return configured.isNotEmpty ? configured : _defaultClientId;
  }

  bool hasConfiguredClientId(String configuredClientId) {
    return resolveClientId(configuredClientId).isNotEmpty;
  }

  Future<SimklPendingAuthorization> requestPinAuthorization({
    required String clientId,
  }) async {
    final normalizedClientId = clientId.trim();
    if (normalizedClientId.isEmpty) {
      throw const SimklException('Falta configurar el Client ID de SIMKL.');
    }
    final response = await _get(
      '/oauth/pin',
      query: {'client_id': normalizedClientId},
    );
    final json = _decodeJsonObject(response.body);
    if (!_isOk(response) || !_jsonResultOk(json)) {
      throw SimklException(_extractApiError(json, response.statusCode));
    }
    final deviceCode = _readString(json['device_code']);
    final userCode = _readString(json['user_code']);
    if (deviceCode.isEmpty || userCode.isEmpty) {
      throw const SimklException('SIMKL no devolvio un codigo PIN valido.');
    }
    return SimklPendingAuthorization(
      clientId: normalizedClientId,
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUrl: _readString(
        json['verification_url'],
        fallback: verificationUri,
      ),
      expiresInSeconds: _readInt(
        json['expires_in'],
        fallback: 900,
      ).clamp(60, 3600).toInt(),
      intervalSeconds: _readInt(
        json['interval'],
        fallback: 5,
      ).clamp(3, 60).toInt(),
      requestedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<SimklPinPollResult> pollPinAuthorization(
    SimklPendingAuthorization request,
  ) async {
    if (DateTime.now().millisecondsSinceEpoch >= request.expiresAtMs) {
      return const SimklPinPollExpired(
        'El codigo de SIMKL expiro. Vuelve a intentarlo.',
      );
    }
    final response = await _get(
      '/oauth/pin/${Uri.encodeComponent(request.userCode)}',
      query: {'client_id': request.clientId},
    );
    final json = _decodeJsonObject(response.body);
    if (_isOk(response) && _jsonResultOk(json)) {
      final accessToken = _readString(json['access_token']);
      if (accessToken.isEmpty) {
        return const SimklPinPollFailed(
          'SIMKL aprobo el dispositivo, pero no devolvio access_token.',
        );
      }
      return SimklPinPollSuccess(accessToken);
    }
    final message = _readString(json['message']);
    if (message.toLowerCase() == 'authorization pending') {
      return SimklPinPollPending(request.intervalSeconds);
    }
    if (message.toLowerCase() == 'slow down') {
      return SimklPinPollPending(request.intervalSeconds + 2);
    }
    if (response.statusCode == 404 || response.statusCode == 410) {
      return const SimklPinPollExpired(
        'El codigo de SIMKL expiro. Vuelve a intentarlo.',
      );
    }
    return SimklPinPollFailed(
      message.isEmpty ? _extractApiError(json, response.statusCode) : message,
    );
  }

  Future<SimklAuthenticatedUser> fetchAuthenticatedUser({
    required String accessToken,
    required String clientId,
  }) async {
    final response = await _post(
      '/users/settings',
      clientId: clientId,
      accessToken: accessToken,
      body: const {},
    );
    final json = _decodeJsonObject(response.body);
    if (!_isOk(response)) {
      throw SimklException(_extractApiError(json, response.statusCode));
    }
    final user = _readMap(json['user']);
    final account = _readMap(json['account']);
    return SimklAuthenticatedUser(
      userId: _readInt(account['id']),
      userName: _readString(user['name'], fallback: 'SIMKL'),
      avatarUrl: _readString(user['avatar']),
    );
  }

  Future<SimklSyncResult> fetchRemoteAnimeState({
    required String accessToken,
    required String clientId,
  }) async {
    final response = await _get(
      '/sync/all-items/anime/',
      clientId: clientId,
      accessToken: accessToken,
    );
    final json = _decodeJsonObject(response.body);
    if (!_isOk(response)) {
      throw SimklException(_extractApiError(json, response.statusCode));
    }
    final entries = _readList(json['anime'])
        .whereType<Map>()
        .map(
          (entry) =>
              _remoteAnimeEntryFromJson(Map<String, dynamic>.from(entry)),
        )
        .where(
          (entry) =>
              entry.title.isNotEmpty || entry.simklId > 0 || entry.malId > 0,
        )
        .toList();
    return SimklSyncResult(remoteEntries: entries);
  }

  Future<List<SimklRemoteEpisodeProgress>> fetchRemoteEpisodeProgress({
    required String accessToken,
    required String clientId,
  }) async {
    final response = await _get(
      '/sync/playback/episodes',
      clientId: clientId,
      accessToken: accessToken,
    );
    if (!_isOk(response)) {
      throw SimklException(
        _extractApiError(_decodeJsonObject(response.body), response.statusCode),
      );
    }
    final progress = <SimklRemoteEpisodeProgress>[];
    for (final rawPlayback in _decodeJsonList(response.body).whereType<Map>()) {
      final playback = Map<String, dynamic>.from(rawPlayback);
      final show = _readMap(playback['anime']).isNotEmpty
          ? _readMap(playback['anime'])
          : _readMap(playback['show']);
      final episode = _readMap(playback['episode']);
      final ids = _readMap(show['ids']);
      final simklId = _readInt(ids['simkl']);
      final malId = _readInt(ids['mal']);
      final title = _readString(show['title']);
      final year = _readInt(show['year']);
      final episodeNumber = _readInt(episode['number']);
      final progressPercent = _readDouble(playback['progress']);
      if (episodeNumber <= 0 || progressPercent <= 0) {
        continue;
      }
      progress.add(
        SimklRemoteEpisodeProgress(
          simklId: simklId,
          malId: malId,
          title: title,
          year: year,
          episodeNumber: episodeNumber,
          progressPercent: progressPercent.clamp(0, 100).toDouble(),
          updatedAtMs: _readDateTimeMs(playback['paused_at']),
        ),
      );
    }
    return progress;
  }

  Future<SimklPushResult> pushLocalAnimeState({
    required String accessToken,
    required String clientId,
    required List<SimklLocalAnimeUpdate> updates,
  }) async {
    var pushed = 0;
    final unresolved = <String>[];
    for (final update in updates) {
      final itemPayload = _buildItemPayload(update);
      if (itemPayload == null) {
        unresolved.add(update.seriesKey);
        continue;
      }
      var didPush = false;
      if (update.removeFromList) {
        await _removeFromList(
          accessToken: accessToken,
          clientId: clientId,
          itemPayload: itemPayload,
        );
        didPush = true;
      } else if (update.watchedEpisodes > 0) {
        await _addHistory(
          accessToken: accessToken,
          clientId: clientId,
          itemPayload: itemPayload,
          listStatus: update.listStatus,
          watchedEpisodes: update.watchedEpisodes,
        );
        didPush = true;
      } else if (update.listStatus.isNotEmpty) {
        await _addToList(
          accessToken: accessToken,
          clientId: clientId,
          itemPayload: itemPayload,
          targetList: update.listStatus,
          watchedEpisodes: update.watchedEpisodes,
        );
        didPush = true;
      }
      if (didPush) {
        pushed += 1;
      }
    }
    return SimklPushResult(pushedCount: pushed, unresolvedKeys: unresolved);
  }

  Future<void> scrobbleEpisode({
    required String accessToken,
    required String clientId,
    required String action,
    required SimklEpisodeScrobbleUpdate update,
  }) async {
    final normalizedAction = switch (action.trim().toLowerCase()) {
      'pause' => 'pause',
      'stop' => 'stop',
      _ => 'start',
    };
    final itemPayload = _buildScrobbleItemPayload(update);
    if (itemPayload == null || update.episodeNumber <= 0) {
      throw const SimklException(
        'No hay datos suficientes para scrobble SIMKL.',
      );
    }
    final response = await _post(
      '/scrobble/$normalizedAction',
      clientId: clientId,
      accessToken: accessToken,
      body: {
        'anime': itemPayload,
        'episode': {'number': update.episodeNumber},
        'progress': update.progressPercent.clamp(0, 100).toDouble(),
      },
    );
    if (!_isOk(response)) {
      throw SimklException(
        _extractApiError(_decodeJsonObject(response.body), response.statusCode),
      );
    }
  }

  void close() {
    _client.close();
  }

  SimklRemoteAnimeEntry _remoteAnimeEntryFromJson(Map<String, dynamic> json) {
    final show = _readMap(json['show']);
    final ids = _readMap(show['ids']);
    final title = _readString(show['title']);
    return SimklRemoteAnimeEntry(
      simklId: _readInt(ids['simkl']),
      malId: _readInt(ids['mal']),
      title: title,
      year: _readInt(show['year']),
      status: _readString(json['status']).toLowerCase(),
      watchedEpisodes: _parseLastWatchedEpisode(
        _readString(json['last_watched']),
      ),
      episodesTotal: _readInt(json['total_episodes']),
      animeType: _readString(
        json['anime_type'],
        fallback: _readString(show['anime_type']),
      ),
    );
  }

  Map<String, dynamic>? _buildItemPayload(SimklLocalAnimeUpdate update) {
    return _buildMediaPayload(
      title: update.title,
      year: update.year,
      simklId: update.simklId,
      malId: update.malId,
      tmdbId: update.tmdbId,
      imdbId: update.imdbId,
    );
  }

  Map<String, dynamic>? _buildScrobbleItemPayload(
    SimklEpisodeScrobbleUpdate update,
  ) {
    return _buildMediaPayload(
      title: update.title,
      year: update.year,
      simklId: update.simklId,
      malId: update.malId,
      tmdbId: update.tmdbId,
      imdbId: update.imdbId,
    );
  }

  Map<String, dynamic>? _buildMediaPayload({
    required String title,
    required int year,
    required int simklId,
    required int malId,
    required int tmdbId,
    required String imdbId,
  }) {
    final ids = <String, dynamic>{
      if (simklId > 0) 'simkl': simklId,
      if (malId > 0) 'mal': malId,
      if (tmdbId > 0) 'tmdb': tmdbId,
      if (imdbId.trim().isNotEmpty) 'imdb': imdbId.trim(),
    };
    final payload = <String, dynamic>{
      if (title.trim().isNotEmpty) 'title': title.trim(),
      if (year > 0) 'year': year,
      if (ids.isNotEmpty) 'ids': ids,
    };
    return payload.isEmpty ? null : payload;
  }

  Future<void> _addToList({
    required String accessToken,
    required String clientId,
    required Map<String, dynamic> itemPayload,
    required String targetList,
    required int watchedEpisodes,
  }) async {
    final item = <String, dynamic>{
      ...itemPayload,
      'to': targetList,
      if (targetList == 'completed' && watchedEpisodes > 0)
        'watched_at': DateTime.now().toUtc().toIso8601String(),
    };
    final response = await _post(
      '/sync/add-to-list',
      clientId: clientId,
      accessToken: accessToken,
      body: {
        'shows': [item],
      },
    );
    if (!_isOk(response)) {
      throw SimklException(
        _extractApiError(_decodeJsonObject(response.body), response.statusCode),
      );
    }
  }

  Future<void> _removeFromList({
    required String accessToken,
    required String clientId,
    required Map<String, dynamic> itemPayload,
  }) async {
    final response = await _post(
      '/sync/remove-from-list',
      clientId: clientId,
      accessToken: accessToken,
      body: {
        'anime': [itemPayload],
      },
    );
    if (!_isOk(response)) {
      throw SimklException(
        _extractApiError(_decodeJsonObject(response.body), response.statusCode),
      );
    }
  }

  Future<void> _addHistory({
    required String accessToken,
    required String clientId,
    required Map<String, dynamic> itemPayload,
    required String listStatus,
    required int watchedEpisodes,
  }) async {
    final episodes = List.generate(
      watchedEpisodes.clamp(1, 2000).toInt(),
      (index) => {'number': index + 1},
    );
    final response = await _post(
      '/sync/history',
      clientId: clientId,
      accessToken: accessToken,
      body: {
        'shows': [
          {
            ...itemPayload,
            if (listStatus.isNotEmpty) 'status': listStatus,
            'episodes': episodes,
          },
        ],
      },
    );
    if (!_isOk(response)) {
      throw SimklException(
        _extractApiError(_decodeJsonObject(response.body), response.statusCode),
      );
    }
  }

  Future<http.Response> _get(
    String path, {
    Map<String, String> query = const {},
    String clientId = '',
    String accessToken = '',
  }) {
    return _client
        .get(
          _uri(path, _requestQuery(query, clientId)),
          headers: _headers(clientId: clientId, accessToken: accessToken),
        )
        .timeout(const Duration(seconds: 20));
  }

  Future<http.Response> _post(
    String path, {
    required String clientId,
    required String accessToken,
    Object? body,
  }) {
    return _client
        .post(
          _uri(path, _requestQuery(const {}, clientId)),
          headers: {
            ..._headers(clientId: clientId, accessToken: accessToken),
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body ?? const {}),
        )
        .timeout(const Duration(seconds: 20));
  }

  Uri _uri(String path, [Map<String, String> query = const {}]) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return _apiBaseUri.replace(
      path: '${_apiBaseUri.path.replaceAll(RegExp(r'/+$'), '')}$normalizedPath',
      queryParameters: query.isEmpty ? null : query,
    );
  }

  Map<String, String> _headers({
    String clientId = '',
    String accessToken = '',
  }) {
    return {
      'Accept': 'application/json',
      'User-Agent': _userAgent,
      if (clientId.trim().isNotEmpty) 'simkl-api-key': clientId.trim(),
      if (accessToken.trim().isNotEmpty)
        'Authorization': 'Bearer ${accessToken.trim()}',
    };
  }

  bool _isOk(http.Response response) {
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  bool _jsonResultOk(Map<String, dynamic> json) {
    return _readString(json['result']).toLowerCase() == 'ok';
  }

  Map<String, dynamic> _decodeJsonObject(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (_) {
      return const {};
    }
  }

  List<dynamic> _decodeJsonList(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is List ? decoded : const [];
    } catch (_) {
      return const [];
    }
  }

  Map<String, String> _requestQuery(
    Map<String, String> query,
    String clientId,
  ) {
    final normalizedClientId = clientId.trim();
    return {
      ...query,
      if (normalizedClientId.isNotEmpty) 'client_id': normalizedClientId,
      'app-name': 'tanuki',
      'app-version': '1.0.0',
    };
  }

  String _extractApiError(Map<String, dynamic> json, int statusCode) {
    final parts = [
      'SIMKL respondio $statusCode',
      _readString(json['error']),
      _readString(json['message']),
    ].where((entry) => entry.isNotEmpty).toList();
    return parts.join(': ');
  }

  int _parseLastWatchedEpisode(String value) {
    return int.tryParse(
          RegExp(
                r'(?:^|[SE])(\d+)$',
                caseSensitive: false,
              ).firstMatch(value.trim())?.group(1) ??
              '',
        ) ??
        0;
  }
}

class SimklPendingAuthorization {
  const SimklPendingAuthorization({
    required this.clientId,
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresInSeconds,
    required this.intervalSeconds,
    required this.requestedAtMs,
  });

  final String clientId;
  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int expiresInSeconds;
  final int intervalSeconds;
  final int requestedAtMs;

  int get expiresAtMs => requestedAtMs + expiresInSeconds * 1000;
}

sealed class SimklPinPollResult {
  const SimklPinPollResult();
}

class SimklPinPollSuccess extends SimklPinPollResult {
  const SimklPinPollSuccess(this.accessToken);

  final String accessToken;
}

class SimklPinPollPending extends SimklPinPollResult {
  const SimklPinPollPending(this.nextIntervalSeconds);

  final int nextIntervalSeconds;
}

class SimklPinPollFailed extends SimklPinPollResult {
  const SimklPinPollFailed(this.message);

  final String message;
}

class SimklPinPollExpired extends SimklPinPollResult {
  const SimklPinPollExpired(this.message);

  final String message;
}

class SimklAuthenticatedUser {
  const SimklAuthenticatedUser({
    required this.userId,
    required this.userName,
    this.avatarUrl = '',
  });

  final int userId;
  final String userName;
  final String avatarUrl;
}

class SimklRemoteAnimeEntry {
  const SimklRemoteAnimeEntry({
    this.simklId = 0,
    this.malId = 0,
    this.title = '',
    this.year = 0,
    this.status = '',
    this.watchedEpisodes = 0,
    this.episodesTotal = 0,
    this.animeType = '',
  });

  final int simklId;
  final int malId;
  final String title;
  final int year;
  final String status;
  final int watchedEpisodes;
  final int episodesTotal;
  final String animeType;
}

class SimklRemoteEpisodeProgress {
  const SimklRemoteEpisodeProgress({
    this.simklId = 0,
    this.malId = 0,
    this.title = '',
    this.year = 0,
    required this.episodeNumber,
    required this.progressPercent,
    this.updatedAtMs = 0,
  });

  final int simklId;
  final int malId;
  final String title;
  final int year;
  final int episodeNumber;
  final double progressPercent;
  final int updatedAtMs;
}

class SimklLocalAnimeUpdate {
  const SimklLocalAnimeUpdate({
    required this.seriesKey,
    required this.title,
    this.simklId = 0,
    this.malId = 0,
    this.tmdbId = 0,
    this.imdbId = '',
    this.year = 0,
    this.listStatus = '',
    this.watchedEpisodes = 0,
    this.episodeCount = 0,
    this.removeFromList = false,
  });

  final String seriesKey;
  final String title;
  final int simklId;
  final int malId;
  final int tmdbId;
  final String imdbId;
  final int year;
  final String listStatus;
  final int watchedEpisodes;
  final int episodeCount;
  final bool removeFromList;
}

class SimklEpisodeScrobbleUpdate {
  const SimklEpisodeScrobbleUpdate({
    required this.seriesKey,
    required this.title,
    required this.episodeNumber,
    required this.progressPercent,
    this.simklId = 0,
    this.malId = 0,
    this.tmdbId = 0,
    this.imdbId = '',
    this.year = 0,
  });

  final String seriesKey;
  final String title;
  final int episodeNumber;
  final double progressPercent;
  final int simklId;
  final int malId;
  final int tmdbId;
  final String imdbId;
  final int year;
}

class SimklSyncResult {
  const SimklSyncResult({this.remoteEntries = const []});

  final List<SimklRemoteAnimeEntry> remoteEntries;
}

class SimklPushResult {
  const SimklPushResult({this.pushedCount = 0, this.unresolvedKeys = const []});

  final int pushedCount;
  final List<String> unresolvedKeys;
}

class SimklException implements Exception {
  const SimklException(this.message);

  final String message;

  @override
  String toString() => message;
}

Map<String, dynamic> _readMap(Object? value) {
  return value is Map ? Map<String, dynamic>.from(value) : const {};
}

List<dynamic> _readList(Object? value) {
  return value is List ? value : const [];
}

String _readString(Object? value, {String fallback = ''}) {
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  return fallback;
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

int _readDateTimeMs(Object? value) {
  final parsed = DateTime.tryParse('${value ?? ''}'.trim());
  return parsed?.millisecondsSinceEpoch ?? 0;
}
