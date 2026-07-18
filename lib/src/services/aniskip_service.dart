import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models.dart';

class AniSkipInterval {
  const AniSkipInterval({
    required this.type,
    required this.start,
    required this.end,
  });

  final AnimeSkipSegmentType type;
  final Duration start;
  final Duration end;

  String get stableKey {
    return '${type.id}:${start.inMilliseconds}:${end.inMilliseconds}';
  }

  factory AniSkipInterval.fromJson(Map<String, dynamic> json) {
    final interval = json['interval'];
    if (interval is! Map) {
      throw const FormatException('AniSkip interval missing');
    }
    final type = animeSkipSegmentTypeFromId(json['skipType']);
    if (type == null) {
      throw const FormatException('AniSkip type unknown');
    }
    final startSeconds = _readSeconds(interval['startTime']);
    final endSeconds = _readSeconds(interval['endTime']);
    if (endSeconds <= startSeconds) {
      throw const FormatException('AniSkip interval invalid');
    }
    return AniSkipInterval(
      type: type,
      start: _secondsToDuration(startSeconds),
      end: _secondsToDuration(endSeconds),
    );
  }
}

class AniSkipService {
  AniSkipService({
    http.Client? client,
    String apiBaseUrl = 'https://api.aniskip.com',
  })  : _client = client ?? http.Client(),
        _apiBaseUrl = apiBaseUrl.replaceFirst(RegExp(r'/$'), '');

  final http.Client _client;
  final String _apiBaseUrl;

  Future<List<AniSkipInterval>> fetchSkipTimes({
    required int malId,
    required int episodeNumber,
    required Duration episodeLength,
    required Set<AnimeSkipSegmentType> types,
  }) async {
    if (malId <= 0 || episodeNumber <= 0 || types.isEmpty) {
      return const [];
    }
    final seconds = (episodeLength.inMilliseconds / 1000)
        .clamp(0, double.infinity)
        .toStringAsFixed(1);
    final uri = Uri.parse(
      '$_apiBaseUrl/v2/skip-times/$malId/$episodeNumber',
    ).replace(queryParameters: {
      'episodeLength': seconds,
      'types': types.map((type) => type.id).toList(),
    });

    assert(() {
      debugPrint('AniSkipService: GET $uri');
      return true;
    }());
    final response = await _client.get(uri).timeout(const Duration(seconds: 8));
    assert(() {
      debugPrint(
        'AniSkipService: status=${response.statusCode} '
        'malId=$malId episode=$episodeNumber length=$seconds '
        'body=${response.body.length > 240 ? '${response.body.substring(0, 240)}...' : response.body}',
      );
      return true;
    }());
    if (response.statusCode == 404) {
      return const [];
    }
    if (response.statusCode != 200) {
      throw AniSkipException('AniSkip respondio ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('AniSkip response invalid');
    }
    if (decoded['found'] == false) {
      return const [];
    }
    final results = decoded['results'];
    if (results is! List) {
      return const [];
    }
    final intervals = <AniSkipInterval>[];
    for (final item in results) {
      if (item is! Map) {
        continue;
      }
      try {
        intervals.add(
          AniSkipInterval.fromJson(Map<String, dynamic>.from(item)),
        );
      } catch (_) {
        continue;
      }
    }
    intervals.sort((left, right) => left.start.compareTo(right.start));
    assert(() {
      debugPrint(
        'AniSkipService: intervals=${intervals.map((interval) => '${interval.type.id}:${interval.start.inSeconds}-${interval.end.inSeconds}').join(',')}',
      );
      return true;
    }());
    return intervals;
  }

  void close() {
    _client.close();
  }
}

class AniSkipException implements Exception {
  const AniSkipException(this.message);

  final String message;

  @override
  String toString() => message;
}

double _readSeconds(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse('$value') ?? 0;
}

Duration _secondsToDuration(double value) {
  return Duration(milliseconds: (value * 1000).round());
}
