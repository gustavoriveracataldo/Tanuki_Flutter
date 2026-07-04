import '../models.dart';

class PlaylistEngine {
  const PlaylistEngine();

  List<EpisodeItem> buildNextEntries({
    required PlaylistState playlist,
    required List<SeriesItem> library,
    int limit = 12,
    bool Function(EpisodeItem episode)? shouldIncludeEpisode,
  }) {
    final includeEpisode = shouldIncludeEpisode ?? (_) => true;
    final workingProgress = Map<String, int>.from(playlist.progress);
    final entries = <EpisodeItem>[];
    var lastSeriesKey = playlist.lastPlayedSeriesName;
    final safeLimit = limit.clamp(1, 50).toInt();

    for (var index = 0; index < safeLimit; index += 1) {
      final next = pickNextEntry(
        playlist: playlist.copyWith(
          progress: workingProgress,
          lastPlayedSeriesName: lastSeriesKey,
        ),
        library: library,
        shouldIncludeEpisode: includeEpisode,
      );
      if (next == null) {
        break;
      }
      entries.add(next);
      final nextKey = next.seriesStateKey.isNotEmpty ? next.seriesStateKey : normalizeSeriesKey(next.seriesName);
      workingProgress[nextKey] = next.episodeIndex + 1;
      lastSeriesKey = nextKey;
    }

    return entries;
  }

  EpisodeItem? pickNextEntry({
    required PlaylistState playlist,
    required List<SeriesItem> library,
    bool Function(EpisodeItem episode)? shouldIncludeEpisode,
  }) {
    final includeEpisode = shouldIncludeEpisode ?? (_) => true;
    bool hasRemainingEpisode(SeriesItem series) {
      final nextIndex = playlist.progress[series.stableKey] ?? 0;
      return series.episodes.skip(nextIndex).any(includeEpisode);
    }

    final seriesCandidates = library
        .where((series) => playlist.selectedSeries.contains(series.stableKey))
        .where(hasRemainingEpisode);
    final availableSeries = _dedupeSeries(seriesCandidates, playlist).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (availableSeries.isEmpty) {
      return null;
    }

    final playbackOrder =
        PlaylistPlaybackOrder.normalize(playlist.playbackOrder);
    if (playbackOrder == PlaylistPlaybackOrder.series) {
      final chosenSeries = availableSeries.first;
      final nextEpisodeIndex = playlist.progress[chosenSeries.stableKey] ?? 0;
      return chosenSeries.episodes
          .skip(nextEpisodeIndex)
          .firstWhereOrNull(includeEpisode);
    }

    final startIndex = availableSeries.indexWhere(
      (series) => series.stableKey == playlist.lastPlayedSeriesName,
    );
    final ordered = startIndex >= 0
        ? [
            ...availableSeries.skip(startIndex + 1),
            ...availableSeries.take(startIndex + 1),
          ]
        : availableSeries;
    final chosenSeries = ordered.first;
    final nextEpisodeIndex = playlist.progress[chosenSeries.stableKey] ?? 0;
    return chosenSeries.episodes
        .skip(nextEpisodeIndex)
        .firstWhereOrNull(includeEpisode);
  }

  Iterable<SeriesItem> _dedupeSeries(
    Iterable<SeriesItem> seriesItems,
    PlaylistState playlist,
  ) {
    final byIdentity = <String, SeriesItem>{};
    for (final series in seriesItems) {
      final identities = _seriesIdentityKeys(series);
      final identity = identities.firstWhere(
        byIdentity.containsKey,
        orElse: () => identities.first,
      );
      final current = byIdentity[identity];
      if (current == null ||
          _seriesScore(series, playlist) > _seriesScore(current, playlist)) {
        if (current != null) {
          for (final key in byIdentity.entries
              .where((entry) => identical(entry.value, current))
              .map((entry) => entry.key)
              .toList(growable: false)) {
            byIdentity[key] = series;
          }
        }
        for (final key in identities) {
          byIdentity[key] = series;
        }
      }
    }
    return byIdentity.values.toSet();
  }

  List<String> _seriesIdentityKeys(SeriesItem series) {
    if (series.catalogId > 0) {
      return ['catalog:${series.catalogId}'];
    }
    final keys = <String>{
      normalizeSeriesKey(series.name),
      normalizeSeriesKey(series.japaneseTitle),
      ...series.aliases.map(normalizeSeriesKey),
    }..removeWhere((entry) => entry.isEmpty);
    return keys.isEmpty ? [series.stableKey] : keys.toList(growable: false);
  }

  int _seriesScore(SeriesItem series, PlaylistState playlist) {
    final progress = playlist.progress[series.stableKey] ?? 0;
    return (progress * 100000) +
        series.episodeCount +
        (series.episodes.length * 2) +
        (series.imageUrl.isNotEmpty ? 10000 : 0) +
        (series.backgroundUrl.isNotEmpty ? 8000 : 0) +
        (series.logoUrl.isNotEmpty ? 6000 : 0);
  }
}

extension _IterableFirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T value) test) {
    for (final value in this) {
      if (test(value)) {
        return value;
      }
    }
    return null;
  }
}
