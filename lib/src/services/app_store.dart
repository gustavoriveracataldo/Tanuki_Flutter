import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models.dart';

class AppStore {
  const AppStore();

  static const _fileName = 'tanuki_state.json';

  Future<AppState> load() async {
    try {
      final file = await _stateFile();
      if (!await file.exists()) {
        return AppState.initial();
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
      return AppState.initial();
    }
    return AppState.initial();
  }

  Future<void> save(AppState state) async {
    final file = await _stateFile();
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(state.toJson()));
  }

  Future<String> storagePath() async {
    return (await _stateFile()).path;
  }

  Future<File> _stateFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}$_fileName');
  }
}
