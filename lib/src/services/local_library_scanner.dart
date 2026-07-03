import 'dart:io';

import '../models.dart';

class LocalLibraryScanner {
  const LocalLibraryScanner();

  static const _mediaExtensions = {
    'avi',
    'm4v',
    'mkv',
    'mov',
    'mp4',
    'mpeg',
    'mpg',
    'ts',
    'webm',
    'wmv',
  };

  Future<List<SeriesItem>> scan(List<String> rootPaths) async {
    final series = <SeriesItem>[];
    for (final rawPath in rootPaths) {
      final path = rawPath.trim();
      if (path.isEmpty) {
        continue;
      }
      final root = Directory(path);
      if (!await root.exists()) {
        continue;
      }
      series.addAll(await _scanRoot(root));
    }
    series.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return series;
  }

  Future<List<SeriesItem>> _scanRoot(Directory root) async {
    final children = await _listChildren(root);
    final childDirectories = children.whereType<Directory>().toList()
      ..sort((a, b) => _entityName(a).toLowerCase().compareTo(_entityName(b).toLowerCase()));

    if (childDirectories.isNotEmpty) {
      final series = <SeriesItem>[];
      for (final directory in childDirectories) {
        final item = await _buildSeries(directory, _entityName(directory));
        if (item != null) {
          series.add(item);
        }
      }
      return series;
    }

    final singleSeries = await _buildSeries(root, _entityName(root));
    return singleSeries == null ? const [] : [singleSeries];
  }

  Future<SeriesItem?> _buildSeries(Directory root, String seriesName) async {
    final documents = await _collectEpisodeFiles(root);
    if (documents.isEmpty) {
      return null;
    }

    final stateKey = normalizeSeriesKey(seriesName);
    final episodes = documents.asMap().entries.map((entry) {
      final index = entry.key;
      final document = entry.value;
      return EpisodeItem(
        seriesName: seriesName,
        seriesStateKey: stateKey,
        episodeIndex: index,
        episodeNumber: index + 1,
        displayName: _formatDisplayName(document.relativePath),
        relativePath: document.relativePath,
        filePath: document.file.path,
        sourceType: SourceType.local,
      );
    }).toList();

    return SeriesItem(
      name: seriesName,
      seriesStateKey: stateKey,
      sourceType: SourceType.local,
      episodeCount: episodes.length,
      episodes: episodes,
    );
  }

  Future<List<_ResolvedDocument>> _collectEpisodeFiles(Directory root) async {
    final pending = <({Directory directory, String prefix})>[(directory: root, prefix: '')];
    final results = <_ResolvedDocument>[];

    while (pending.isNotEmpty) {
      final current = pending.removeAt(0);
      final children = await _listChildren(current.directory);
      children.sort((a, b) => _entityName(a).toLowerCase().compareTo(_entityName(b).toLowerCase()));

      for (final child in children) {
        final name = _entityName(child);
        if (name.isEmpty) {
          continue;
        }
        final relativePath = [current.prefix, name].where((part) => part.isNotEmpty).join('/');
        if (child is Directory) {
          pending.add((directory: child, prefix: relativePath));
        } else if (child is File && _mediaExtensions.contains(_extensionOf(name))) {
          results.add(_ResolvedDocument(file: child, relativePath: relativePath));
        }
      }
    }

    results.sort((a, b) => a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase()));
    return results;
  }

  Future<List<FileSystemEntity>> _listChildren(Directory directory) async {
    try {
      return directory.list(followLinks: false).toList();
    } catch (_) {
      return const [];
    }
  }

  String _formatDisplayName(String relativePath) {
    final withoutExtension = relativePath.contains('.')
        ? relativePath.substring(0, relativePath.lastIndexOf('.'))
        : relativePath;
    return withoutExtension.replaceAll('/', ' ');
  }

  String _entityName(FileSystemEntity entity) {
    final normalized = entity.path.replaceAll('\\', '/');
    final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? '' : parts.last;
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }
}

class _ResolvedDocument {
  const _ResolvedDocument({
    required this.file,
    required this.relativePath,
  });

  final File file;
  final String relativePath;
}
