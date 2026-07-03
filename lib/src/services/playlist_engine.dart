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
    final availableSeries = library
        .where((series) => playlist.selectedSeries.contains(series.stableKey))
        .where((series) {
          final nextIndex = playlist.progress[series.stableKey] ?? 0;
          return series.episodes.skip(nextIndex).any(includeEpisode);
        })
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (availableSeries.isEmpty) {
      return null;
    }

    final startIndex = availableSeries.indexWhere((series) => series.stableKey == playlist.lastPlayedSeriesName);
    final ordered = startIndex >= 0
        ? [...availableSeries.skip(startIndex + 1), ...availableSeries.take(startIndex + 1)]
        : availableSeries;
    final chosenSeries = ordered.first;
    final nextEpisodeIndex = playlist.progress[chosenSeries.stableKey] ?? 0;
    return chosenSeries.episodes.skip(nextEpisodeIndex).firstWhereOrNull(includeEpisode);
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
