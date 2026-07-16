import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models.dart';

typedef AppStoreDirectoryProvider = Future<Directory> Function();

Future<Directory> _defaultAppStoreDirectory() {
  return getApplicationSupportDirectory();
}

class AppStore {
  const AppStore() : _directoryProvider = _defaultAppStoreDirectory;

  AppStore.inDirectory(Directory directory)
      : _directoryProvider = (() async => directory);

  static const _fileName = 'tanuki_state.json';
  static const _backupFileName = 'tanuki_state.bak.json';
  static const _tempFileName = 'tanuki_state.tmp.json';

  final AppStoreDirectoryProvider _directoryProvider;

  Future<AppState> load() async {
    final file = await _stateFile();
    final backupFile = await _backupStateFile();
    for (final candidate in [file, backupFile]) {
      final state = await _tryLoadState(candidate);
      if (state != null) {
        return state;
      }
    }
    return AppState.initial();
  }

  Future<void> save(AppState state) async {
    final file = await _stateFile();
    final backupFile = await _backupStateFile();
    final tempFile = await _tempStateFile();
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    if (await file.exists()) {
      await file.copy(backupFile.path);
    }
    await tempFile.writeAsString(encoder.convert(state.toJson()), flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
  }

  Future<String> storagePath() async {
    return (await _stateFile()).path;
  }

  Future<File> _stateFile() async {
    final directory = await _directoryProvider();
    return File('${directory.path}${Platform.pathSeparator}$_fileName');
  }

  Future<File> _backupStateFile() async {
    final directory = await _directoryProvider();
    return File('${directory.path}${Platform.pathSeparator}$_backupFileName');
  }

  Future<File> _tempStateFile() async {
    final directory = await _directoryProvider();
    return File('${directory.path}${Platform.pathSeparator}$_tempFileName');
  }

  Future<AppState?> _tryLoadState(File file) async {
    try {
      if (!await file.exists()) {
        return null;
      }
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AppState.fromJson(decoded);
      }
      if (decoded is Map) {
        return AppState.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
