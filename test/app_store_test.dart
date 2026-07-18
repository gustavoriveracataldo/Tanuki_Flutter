import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/services/app_store.dart';

void main() {
  late Directory tempDir;
  late AppStore store;

  File stateFile(String name) {
    return File('${tempDir.path}${Platform.pathSeparator}$name');
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tanuki_store_test_');
    store = AppStore.inDirectory(tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('saves and loads app state from the configured directory', () async {
    const state = AppState(
      myAnimeListClientId: 'mal-client',
      simklClientId: 'simkl-client',
    );

    await store.save(state);

    final restored = await store.load();
    expect(restored.myAnimeListClientId, 'mal-client');
    expect(restored.simklClientId, 'simkl-client');
    expect(await stateFile('tanuki_state.json').exists(), isTrue);
  });

  test('writes the current app state schema version', () async {
    await store.save(AppState.initial());

    final json = jsonDecode(
      await stateFile('tanuki_state.json').readAsString(),
    ) as Map<String, dynamic>;

    expect(json['schemaVersion'], AppState.schemaVersion);
  });

  test('keeps a backup of the last valid state before overwriting', () async {
    await store.save(const AppState(myAnimeListClientId: 'first'));
    await store.save(const AppState(myAnimeListClientId: 'second'));

    final main = jsonDecode(
      await stateFile('tanuki_state.json').readAsString(),
    ) as Map<String, dynamic>;
    final backup = jsonDecode(
      await stateFile('tanuki_state.bak.json').readAsString(),
    ) as Map<String, dynamic>;

    expect(main['myAnimeListClientId'], 'second');
    expect(backup['myAnimeListClientId'], 'first');
  });

  test('serializes concurrent saves without losing the temp file', () async {
    await Future.wait([
      store.save(const AppState(myAnimeListClientId: 'first')),
      store.save(const AppState(myAnimeListClientId: 'second')),
      store.save(const AppState(myAnimeListClientId: 'third')),
    ]);

    final restored = await store.load();

    expect(
      restored.myAnimeListClientId,
      isIn(['first', 'second', 'third']),
    );
    expect(await stateFile('tanuki_state.json').exists(), isTrue);
    expect(await stateFile('tanuki_state.tmp.json').exists(), isFalse);
  });

  test('loads backup when the primary state file is corrupt', () async {
    await store.save(const AppState(myAnimeListClientId: 'first-valid'));
    await store.save(const AppState(myAnimeListClientId: 'second-valid'));
    await stateFile('tanuki_state.json').writeAsString('{broken');

    final restored = await store.load();

    expect(restored.myAnimeListClientId, 'first-valid');
  });
}
