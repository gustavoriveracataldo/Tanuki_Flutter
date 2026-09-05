import 'dart:convert';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models.dart';

class OpenSubtitlesService {
  OpenSubtitlesService({
    http.Client? client,
    String restBaseUrl = 'https://rest.opensubtitles.org',
    String vidsrcMetaBaseUrl = 'https://data.vidsrcme.ru',
    String userAgent = 'trailers.to-UA',
    io.Directory? cacheDirectory,
  })  : _client = client ?? http.Client(),
        _restBaseUri = Uri.parse(restBaseUrl),
        _vidsrcMetaBaseUri = Uri.parse(vidsrcMetaBaseUrl),
        _userAgent = userAgent.trim().isEmpty ? 'trailers.to-UA' : userAgent,
        _cacheDirectory = cacheDirectory ??
            io.Directory(
              '${io.Directory.systemTemp.path}${io.Platform.pathSeparator}'
              'tanuki_subtitles',
            );

  final http.Client _client;
  final Uri _restBaseUri;
  final Uri _vidsrcMetaBaseUri;
  final String _userAgent;
  final io.Directory _cacheDirectory;

  bool get isConfigured => true;

  Future<List<RemoteSubtitleTrack>> searchSubtitleTracks(
    OpenSubtitlesSearchRequest request, {
    int limit = 10,
  }) async {
    final metadata = await _fetchVidsrcMetadata(request);
    final imdbId = _normalizeImdbId(
      request.imdbId.isNotEmpty ? request.imdbId : metadata.imdbId,
    );
    final videoInfo = _OpenSubtitlesVideoInfo.fromRequest(
      request,
      fileName: metadata.fileName,
    );
    final tracks = <RemoteSubtitleTrack>[];
    final seen = <String>{};

    for (final track in _vidsrcDefaultSubtitleTracks(metadata, request)) {
      if (tracks.length >= limit) break;
      if (seen.add(remoteSubtitleTrackIdentity(track))) {
        tracks.add(track);
      }
    }

    final remaining = limit - tracks.length;
    if (remaining <= 0) {
      return tracks;
    }

    final candidates = <OpenSubtitlesSearchResult>[];
    for (final language in _legacyLanguages(request.languages)) {
      final results = imdbId.isNotEmpty
          ? await _searchByImdb(
              imdbId: imdbId,
              language: language,
              request: request,
            )
          : await _searchByQuery(
              query: request.query,
              language: language,
            );
      candidates.addAll(results);
    }

    candidates.sort((left, right) {
      final score =
          right._scoreFor(videoInfo).compareTo(left._scoreFor(videoInfo));
      if (score != 0) return score;
      final trusted = (right.fromTrusted ? 1 : 0) - (left.fromTrusted ? 1 : 0);
      if (trusted != 0) return trusted;
      return right.downloadCount.compareTo(left.downloadCount);
    });

    for (final candidate in candidates) {
      if (tracks.length >= limit) break;
      if (candidate.downloadLink.isEmpty || candidate.fileId.isEmpty) continue;
      if (!seen.add(candidate.downloadLink)) continue;
      final subtitlePath = await _downloadAndCacheSubtitle(candidate);
      if (subtitlePath.isEmpty) continue;
      final track = RemoteSubtitleTrack(
        url: subtitlePath,
        label: _subtitleLabel(candidate, videoInfo),
        language: _normalizeOutputLanguage(candidate.language),
        mimeType: _subtitleMimeType(candidate.fileName),
      );
      if (seen.add(remoteSubtitleTrackIdentity(track))) {
        tracks.add(track);
      }
    }

    return tracks;
  }

  Future<_VidsrcSubtitleMetadata> _fetchVidsrcMetadata(
    OpenSubtitlesSearchRequest request,
  ) async {
    if (request.tmdbId <= 0 ||
        (request.mediaType != 'movie' && request.mediaType != 'tv')) {
      return const _VidsrcSubtitleMetadata();
    }
    final query = <String, String>{
      'type': request.mediaType,
      'tmdb': '${request.tmdbId}',
      if (request.mediaType == 'tv' && request.seasonNumber > 0)
        'season': '${request.seasonNumber}',
      if (request.mediaType == 'tv' && request.episodeNumber > 0)
        'episode': '${request.episodeNumber}',
    };
    try {
      final response = await _client.get(
        _vidsrcMetaBaseUri.replace(path: '/api.php', queryParameters: query),
        headers: _jsonHeaders,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const _VidsrcSubtitleMetadata();
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return const _VidsrcSubtitleMetadata();
      return _VidsrcSubtitleMetadata.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      return const _VidsrcSubtitleMetadata();
    }
  }

  Iterable<RemoteSubtitleTrack> _vidsrcDefaultSubtitleTracks(
    _VidsrcSubtitleMetadata metadata,
    OpenSubtitlesSearchRequest request,
  ) sync* {
    final acceptedLanguages = _normalizedRequestedLanguages(request.languages);
    for (final sub in metadata.defaultSubtitles) {
      final url = sub.url.trim();
      if (url.isEmpty) continue;
      final language = _normalizeOutputLanguage(
          sub.code.isNotEmpty ? sub.code : sub.language);
      if (acceptedLanguages.isNotEmpty &&
          !acceptedLanguages.contains(language)) {
        continue;
      }
      yield RemoteSubtitleTrack(
        url: url,
        label: 'Vidsrc ${_friendlyLanguage(language, fallback: sub.language)}',
        language: language,
        mimeType: _subtitleMimeType(url),
      );
    }
  }

  Future<List<OpenSubtitlesSearchResult>> _searchByImdb({
    required String imdbId,
    required String language,
    required OpenSubtitlesSearchRequest request,
  }) {
    var path = '/search';
    if (request.mediaType == 'tv' &&
        request.seasonNumber > 0 &&
        request.episodeNumber > 0) {
      path += '/episode-${request.episodeNumber}'
          '/imdbid-$imdbId'
          '/season-${request.seasonNumber}';
    } else {
      path += '/imdbid-$imdbId';
    }
    path += '/sublanguageid-$language';
    return _search(path);
  }

  Future<List<OpenSubtitlesSearchResult>> _searchByQuery({
    required String query,
    required String language,
  }) {
    final cleaned = query.trim();
    if (cleaned.isEmpty) return Future.value(const []);
    final encoded = Uri.encodeComponent(cleaned).replaceAll('%20', '+');
    return _search('/search/query-$encoded/sublanguageid-$language');
  }

  Future<List<OpenSubtitlesSearchResult>> _search(String path) async {
    try {
      final response = await _client.get(_restUri(path), headers: _restHeaders);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((entry) => OpenSubtitlesSearchResult.fromJson(
                Map<String, dynamic>.from(entry),
              ))
          .where((entry) => entry.downloadLink.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<String> _downloadAndCacheSubtitle(
    OpenSubtitlesSearchResult subtitle,
  ) async {
    await _cacheDirectory.create(recursive: true);
    final extension = _subtitleExtension(subtitle.fileName);
    final cacheKey = sha1
        .convert(utf8.encode('${subtitle.fileId}|${subtitle.downloadLink}'))
        .toString();
    final file = io.File(
      '${_cacheDirectory.path}${io.Platform.pathSeparator}'
      'opensubtitles_$cacheKey.$extension',
    );
    if (await file.exists() && await file.length() > 0) {
      return file.path;
    }
    try {
      final response =
          await _client.get(Uri.parse(subtitle.downloadLink), headers: {
        'User-Agent': _userAgent,
        'X-User-Agent': _userAgent,
        'Accept': '*/*',
      });
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return '';
      }
      List<int> bytes = response.bodyBytes;
      if (_looksGzipped(bytes) || subtitle.downloadLink.endsWith('.gz')) {
        bytes = io.gzip.decode(bytes);
      }
      final text = _decodeSubtitleText(bytes, subtitle.encoding);
      if (text.trim().isEmpty) {
        return '';
      }
      await file.writeAsString(text, encoding: utf8);
      return file.path;
    } catch (_) {
      return '';
    }
  }

  Uri _restUri(String path) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return _restBaseUri.replace(path: normalized);
  }

  Map<String, String> get _jsonHeaders => {
        'Accept': 'application/json',
        'User-Agent': _userAgent,
      };

  Map<String, String> get _restHeaders => {
        'Accept': 'application/json',
        'User-Agent': _userAgent,
        'X-User-Agent': _userAgent,
      };

  void close() {
    _client.close();
  }
}

class OpenSubtitlesSearchRequest {
  const OpenSubtitlesSearchRequest({
    required this.query,
    this.languages = const ['es', 'en'],
    this.mediaType = '',
    this.tmdbId = 0,
    this.imdbId = '',
    this.seasonNumber = 0,
    this.episodeNumber = 0,
    this.year = 0,
  });

  final String query;
  final List<String> languages;
  final String mediaType;
  final int tmdbId;
  final String imdbId;
  final int seasonNumber;
  final int episodeNumber;
  final int year;
}

class OpenSubtitlesSearchResult {
  const OpenSubtitlesSearchResult({
    required this.fileId,
    required this.downloadLink,
    this.fileName = '',
    this.release = '',
    this.language = '',
    this.languageName = '',
    this.encoding = '',
    this.downloadCount = 0,
    this.rating = 0,
    this.fromTrusted = false,
    this.year = 0,
    this.seasonNumber = 0,
    this.episodeNumber = 0,
  });

  final String fileId;
  final String downloadLink;
  final String fileName;
  final String release;
  final String language;
  final String languageName;
  final String encoding;
  final int downloadCount;
  final double rating;
  final bool fromTrusted;
  final int year;
  final int seasonNumber;
  final int episodeNumber;

  static OpenSubtitlesSearchResult fromJson(Map<String, dynamic> json) {
    return OpenSubtitlesSearchResult(
      fileId: _readString(json['IDSubtitleFile']),
      downloadLink: _readString(json['SubDownloadLink']),
      fileName: _readString(json['SubFileName']),
      release: _readString(json['MovieReleaseName']),
      language: _readString(json['SubLanguageID']),
      languageName: _readString(json['LanguageName']),
      encoding: _readString(json['SubEncoding']),
      downloadCount: _readInt(json['SubDownloadsCnt']),
      rating: _readDouble(json['SubRating']),
      fromTrusted: _readString(json['SubFromTrusted']) == '1' ||
          _readString(json['UserRank']).toLowerCase().contains('trusted'),
      year: _readInt(json['MovieYear']),
      seasonNumber: _readInt(json['SeriesSeason']),
      episodeNumber: _readInt(json['SeriesEpisode']),
    );
  }

  int _scoreFor(_OpenSubtitlesVideoInfo video) {
    var score = 0;
    final text = '$fileName $release'.toLowerCase();
    if (video.year > 0 && year > 0) {
      score += video.year == year ? 15 : -12;
    }
    if (video.seasonNumber > 0 && video.episodeNumber > 0) {
      if (seasonNumber == video.seasonNumber &&
          episodeNumber == video.episodeNumber) {
        score += 25;
      } else if (seasonNumber > 0 || episodeNumber > 0) {
        score -= 35;
      }
    }
    for (final quality in const ['2160p', '1080p', '720p', '480p']) {
      if (video.fileName.toLowerCase().contains(quality) &&
          text.contains(quality)) {
        score += 10;
        break;
      }
    }
    if (text.contains('bluray') || text.contains('brrip')) score += 4;
    if (text.contains('web-dl') || text.contains('webrip')) score += 4;
    if (fromTrusted) score += 8;
    score += downloadCount > 10000
        ? 3
        : downloadCount > 1000
            ? 2
            : downloadCount > 100
                ? 1
                : 0;
    score += rating.round().clamp(0, 10);
    return score;
  }
}

class OpenSubtitlesException implements Exception {
  const OpenSubtitlesException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _VidsrcSubtitleMetadata {
  const _VidsrcSubtitleMetadata({
    this.imdbId = '',
    this.fileName = '',
    this.defaultSubtitles = const [],
  });

  final String imdbId;
  final String fileName;
  final List<_VidsrcDefaultSubtitle> defaultSubtitles;

  static _VidsrcSubtitleMetadata fromJson(Map<String, dynamic> json) {
    final data = _readMap(json['data']);
    final defaultSubs = _readList(json['default_subs'])
        .whereType<Map>()
        .map((entry) => _VidsrcDefaultSubtitle.fromJson(
              Map<String, dynamic>.from(entry),
            ))
        .where((entry) => entry.url.isNotEmpty)
        .toList(growable: false);
    return _VidsrcSubtitleMetadata(
      imdbId: _readString(data['imdb_id']),
      fileName: _readString(data['file_name']),
      defaultSubtitles: defaultSubs,
    );
  }
}

class _VidsrcDefaultSubtitle {
  const _VidsrcDefaultSubtitle({
    required this.url,
    this.language = '',
    this.code = '',
  });

  final String url;
  final String language;
  final String code;

  static _VidsrcDefaultSubtitle fromJson(Map<String, dynamic> json) {
    return _VidsrcDefaultSubtitle(
      url: _readString(json['url']),
      language: _readString(json['lang']),
      code: _readString(json['code']),
    );
  }
}

class _OpenSubtitlesVideoInfo {
  const _OpenSubtitlesVideoInfo({
    this.fileName = '',
    this.year = 0,
    this.seasonNumber = 0,
    this.episodeNumber = 0,
  });

  final String fileName;
  final int year;
  final int seasonNumber;
  final int episodeNumber;

  static _OpenSubtitlesVideoInfo fromRequest(
    OpenSubtitlesSearchRequest request, {
    required String fileName,
  }) {
    return _OpenSubtitlesVideoInfo(
      fileName: fileName,
      year: request.year,
      seasonNumber: request.seasonNumber,
      episodeNumber: request.episodeNumber,
    );
  }
}

List<String> _legacyLanguages(List<String> languages) {
  final output = <String>[];
  for (final language in languages) {
    final normalized = _normalizeLegacyLanguage(language);
    if (normalized.isNotEmpty && !output.contains(normalized)) {
      output.add(normalized);
    }
  }
  if (output.isEmpty) {
    output.addAll(const ['spa', 'eng']);
  }
  return output;
}

Set<String> _normalizedRequestedLanguages(List<String> languages) {
  return _legacyLanguages(languages)
      .map(_normalizeOutputLanguage)
      .where((entry) => entry.isNotEmpty)
      .toSet();
}

String _normalizeLegacyLanguage(String value) {
  final normalized = value.trim().toLowerCase();
  return switch (normalized) {
    'es' || 'esp' || 'esl' || 'spa' || 'spanish' || 'español' => 'spa',
    'en' || 'eng' || 'english' || 'ingles' || 'inglés' => 'eng',
    'pt-br' || 'pt_br' || 'pob' => 'pob',
    'pt' || 'por' || 'portuguese' => 'por',
    _ when normalized.length == 3 => normalized,
    _ => '',
  };
}

String _normalizeOutputLanguage(String value) {
  final normalized = value.trim().toLowerCase();
  return switch (normalized) {
    'spa' || 'esp' || 'esl' || 'spanish' || 'español' => 'es',
    'eng' || 'english' => 'en',
    'pob' => 'pt-BR',
    'por' => 'pt',
    _ => normalized,
  };
}

String _normalizeImdbId(String value) {
  final digits =
      value.trim().replaceFirst(RegExp(r'^tt', caseSensitive: false), '');
  if (!RegExp(r'^\d{4,}$').hasMatch(digits)) {
    return '';
  }
  return digits.padLeft(7, '0');
}

bool _looksGzipped(List<int> bytes) {
  return bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
}

String _decodeSubtitleText(List<int> bytes, String encoding) {
  final normalized = encoding.trim().toLowerCase();
  if (normalized.contains('1252') || normalized.contains('latin')) {
    return latin1.decode(bytes, allowInvalid: true);
  }
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes, allowInvalid: true);
  }
}

String _subtitleLabel(
  OpenSubtitlesSearchResult result,
  _OpenSubtitlesVideoInfo video,
) {
  final language = _friendlyLanguage(
    _normalizeOutputLanguage(result.language),
    fallback: result.languageName,
  );
  final score = result._scoreFor(video).clamp(0, 99);
  final detail = result.fileName.trim().isNotEmpty
      ? result.fileName.trim()
      : result.release.trim();
  return detail.isEmpty
      ? 'OpenSubtitles $language'
      : 'OpenSubtitles $language - $detail ($score%)';
}

String _friendlyLanguage(String language, {String fallback = ''}) {
  return switch (language.trim().toLowerCase()) {
    'es' => 'Español',
    'en' => 'Ingles',
    'pt-br' => 'Portugués BR',
    'pt' => 'Portugués',
    _ => fallback.trim().isNotEmpty ? fallback.trim() : language.toUpperCase(),
  };
}

String _subtitleMimeType(String value) {
  final lower = value.toLowerCase();
  if (lower.endsWith('.vtt')) return 'text/vtt';
  if (lower.endsWith('.ass')) return 'text/ass';
  if (lower.endsWith('.ssa')) return 'text/ssa';
  return 'application/x-subrip';
}

String _subtitleExtension(String value) {
  final lower = value.toLowerCase();
  if (lower.endsWith('.vtt')) return 'vtt';
  if (lower.endsWith('.ass')) return 'ass';
  if (lower.endsWith('.ssa')) return 'ssa';
  return 'srt';
}

String remoteSubtitleTrackIdentity(RemoteSubtitleTrack track) {
  return '${track.url.trim().toLowerCase()}|'
      '${track.language.trim().toLowerCase()}|'
      '${track.label.trim().toLowerCase()}';
}

Map<String, dynamic> _readMap(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const {};
}

List<Object?> _readList(Object? value) {
  return value is List ? value : const [];
}

String _readString(Object? value) {
  if (value == null) return '';
  return value is String ? value.trim() : '$value'.trim();
}

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse('$value') ?? 0;
}

double _readDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0;
}
