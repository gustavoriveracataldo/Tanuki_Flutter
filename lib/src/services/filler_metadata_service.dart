import 'package:http/http.dart' as http;

import '../models.dart';

class FillerMetadataService {
  FillerMetadataService({
    http.Client? client,
    String baseUrl = 'https://www.animefillerlist.com',
  })  : _client = client ?? http.Client(),
        _baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  static const _minMatchScore = 620;
  static const _ambiguousGap = 120;

  final http.Client _client;
  final String _baseUrl;

  Future<FillerMetadataRecord> resolveFillerMetadata(
      Iterable<String> aliasCandidates) async {
    final aliases = _normalizeAliases(aliasCandidates);
    if (aliases.isEmpty) {
      return const FillerMetadataRecord();
    }

    final indexResponse = await _get(Uri.parse('$_baseUrl/shows'));
    if (indexResponse.statusCode < 200 || indexResponse.statusCode >= 300) {
      return const FillerMetadataRecord();
    }
    final shows = _parseAnimeFillerShowIndex(indexResponse.body);
    final show = _pickBestFillerShowMatch(aliases, shows);
    if (show == null) {
      return const FillerMetadataRecord();
    }

    final pageResponse = await _get(Uri.parse('$_baseUrl/shows/${show.slug}'));
    if (pageResponse.statusCode < 200 || pageResponse.statusCode >= 300) {
      return const FillerMetadataRecord();
    }
    final episodeMap = _parseFillerEpisodeMap(pageResponse.body);
    if (episodeMap.isEmpty) {
      return const FillerMetadataRecord();
    }

    return FillerMetadataRecord(
      status: 'found',
      provider: 'animefillerlist',
      showSlug: show.slug,
      showName: show.name,
      episodeMap: episodeMap,
    );
  }

  void close() {
    _client.close();
  }

  Future<http.Response> _get(Uri uri) {
    return _client.get(uri, headers: const {
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36',
    }).timeout(const Duration(seconds: 12));
  }

  List<_FillerShowEntry> _parseAnimeFillerShowIndex(String html) {
    final seen = <String>{};
    final shows = <_FillerShowEntry>[];
    final regex = RegExp(
      r'<a href="/shows/([^"/?#]+)"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    );
    for (final match in regex.allMatches(html)) {
      final slug = _normalizeTitle(match.group(1) ?? '');
      if (slug.isEmpty || slug == 'latest-updates' || !seen.add(slug)) {
        continue;
      }
      final name =
          _normalizeTitle(_decodeHtml(_stripHtml(match.group(2) ?? '')));
      if (name.isEmpty) {
        continue;
      }
      shows.add(_FillerShowEntry(
        slug: slug,
        name: name,
        aliases: _parseShowNameAliases(name),
      ));
    }
    return shows;
  }

  List<String> _parseShowNameAliases(String showName) {
    final aliases = <String>[showName];
    for (final match in RegExp(r'\(([^)]+)\)').allMatches(showName)) {
      aliases.add(_normalizeTitle(match.group(1) ?? ''));
    }
    aliases.add(showName
        .replaceAll(RegExp(r'\s*\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim());
    return _normalizeAliases(aliases);
  }

  _FillerShowEntry? _pickBestFillerShowMatch(
      List<String> aliases, List<_FillerShowEntry> shows) {
    if (shows.isEmpty) {
      return null;
    }
    final targetAliases = aliases.map(_normalizeSearchKey).toList();
    final ranked = shows
        .map((show) =>
            MapEntry(show, _scoreFillerShowMatch(targetAliases, show)))
        .toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    final best = ranked.first;
    final second = ranked.length > 1 ? ranked[1] : null;
    if (best.value < _minMatchScore) {
      return null;
    }
    if (second != null && best.value - second.value < _ambiguousGap) {
      return null;
    }
    return best.key;
  }

  int _scoreFillerShowMatch(List<String> targetAliases, _FillerShowEntry show) {
    final showAliases = show.aliases.map(_normalizeSearchKey).toList();
    var score = 0;
    for (final targetAlias in targetAliases) {
      for (final showAlias in showAliases) {
        final candidate = _scoreAliasPair(targetAlias, showAlias);
        if (candidate > score) {
          score = candidate;
        }
      }
    }

    final nameKey = _normalizeSearchKey(show.name);
    final showYearMatch = RegExp(r'\b(19|20)\d{2}\b').firstMatch(show.name);
    final showYear = showYearMatch?.group(0);
    final targetContainsSameYear = showYear != null &&
        targetAliases.any((alias) => alias.contains(showYear));

    if (RegExp(r'\b(film|films|movie|movies|ova|ovas|special|specials)\b')
        .hasMatch(nameKey)) {
      score -= 260;
    }
    if (showYear != null && !targetContainsSameYear) {
      score -= 320;
    }
    return score;
  }

  Map<String, String> _parseFillerEpisodeMap(String html) {
    final episodeMap = <String, String>{};
    final regex = RegExp(
      r'<tr class="[^"]*" id="eps-(\d+)"[\s\S]*?<td class="Type"><span>(.*?)</span></td>',
      caseSensitive: false,
    );
    for (final match in regex.allMatches(html)) {
      final episodeNumber = int.tryParse(match.group(1) ?? '') ?? 0;
      final type =
          _normalizeEpisodeType(_decodeHtml(_stripHtml(match.group(2) ?? '')));
      if (episodeNumber > 0 && type.isNotEmpty) {
        episodeMap['$episodeNumber'] = type;
      }
    }
    return episodeMap;
  }

  String _normalizeEpisodeType(String typeText) {
    final normalized = _normalizeSearchKey(typeText);
    if (normalized.isEmpty) {
      return '';
    }
    if (normalized.contains('mixed') && normalized.contains('filler')) {
      return 'mixed';
    }
    if (normalized == 'filler' || normalized.endsWith(' filler')) {
      return 'filler';
    }
    return 'canon';
  }

  List<String> _normalizeAliases(Iterable<String> values) {
    final unique = <String, String>{};
    for (final value in values) {
      final title = _normalizeTitle(value);
      final key = _normalizeSearchKey(title);
      if (title.isNotEmpty && key.isNotEmpty && !unique.containsKey(key)) {
        unique[key] = title;
      }
    }
    return unique.values.toList();
  }

  int _scoreAliasPair(String left, String right) {
    if (left.isEmpty || right.isEmpty) {
      return 0;
    }
    if (left == right) {
      return 2200;
    }

    final leftWithoutYear = _removeYear(left);
    final rightWithoutYear = _removeYear(right);
    if (leftWithoutYear.isNotEmpty &&
        rightWithoutYear.isNotEmpty &&
        leftWithoutYear == rightWithoutYear) {
      return 1700;
    }

    if (left.contains(right) || right.contains(left)) {
      return 950;
    }
    return (_scoreTokenOverlap(left, right) * 420.0).toInt();
  }

  String _removeYear(String value) {
    return value
        .replaceAll(RegExp(r'\b(19|20)\d{2}\b'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  double _scoreTokenOverlap(String left, String right) {
    final leftTokens =
        left.split(' ').where((token) => token.trim().isNotEmpty).toSet();
    final rightTokens =
        right.split(' ').where((token) => token.trim().isNotEmpty).toSet();
    if (leftTokens.isEmpty || rightTokens.isEmpty) {
      return 0;
    }
    final intersection = leftTokens.intersection(rightTokens).length;
    return intersection /
        (leftTokens.length > rightTokens.length
            ? leftTokens.length
            : rightTokens.length);
  }

  String _normalizeTitle(String value) => value.trim();

  String _normalizeSearchKey(String value) {
    var normalized = value.toLowerCase().replaceAll('&', ' and ');
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

  String _stripHtml(String value) {
    return value
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
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
}

class _FillerShowEntry {
  const _FillerShowEntry({
    required this.slug,
    required this.name,
    required this.aliases,
  });

  final String slug;
  final String name;
  final List<String> aliases;
}
