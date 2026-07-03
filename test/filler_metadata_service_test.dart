import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/services/filler_metadata_service.dart';

void main() {
  test('resolves AnimeFillerList show and normalizes episode tags', () async {
    final service = FillerMetadataService(
      baseUrl: 'https://filler.test',
      client: MockClient((request) async {
        return switch (request.url.toString()) {
          'https://filler.test/shows' => http.Response(
              '''
              <a href="/shows/demo-anime">Demo Anime</a>
              <a href="/shows/demo-anime-movie">Demo Anime Movie</a>
              ''',
              200,
              request: request,
            ),
          'https://filler.test/shows/demo-anime' => http.Response(
              '''
              <table>
                <tr class="filler" id="eps-1"><td class="Type"><span>Anime Canon</span></td></tr>
                <tr class="filler" id="eps-2"><td class="Type"><span>Filler</span></td></tr>
                <tr class="filler" id="eps-3"><td class="Type"><span>Mixed Canon/Filler</span></td></tr>
              </table>
              ''',
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final record = await service.resolveFillerMetadata(['Demo Anime']);

    expect(record.status, 'found');
    expect(record.showSlug, 'demo-anime');
    expect(record.episodeMap, {
      '1': 'canon',
      '2': 'filler',
      '3': 'mixed',
    });
  });

  test('serializes filler metadata in AppState', () {
    const record = FillerMetadataRecord(
      status: 'found',
      showSlug: 'demo-anime',
      showName: 'Demo Anime',
      episodeMap: {'2': 'filler'},
    );
    const state = AppState(fillerCache: {'demo anime': record});

    final restored = AppState.fromJson(state.toJson());

    expect(restored.fillerCache['demo anime']?.showSlug, 'demo-anime');
    expect(restored.fillerCache['demo anime']?.episodeMap['2'], 'filler');
  });
}
