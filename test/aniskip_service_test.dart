import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/services/aniskip_service.dart';

void main() {
  test('fetches AniSkip intervals with selected repeated types', () async {
    late Uri requestedUri;
    final service = AniSkipService(
      apiBaseUrl: 'https://example.test',
      client: _FakeHttpClient((request) async {
        requestedUri = request.url;
        return http.Response(
          '''
{
  "found": true,
  "results": [
    {
      "interval": {"startTime": 85.2, "endTime": 175.4},
      "skipType": "op"
    },
    {
      "interval": {"startTime": 1280, "endTime": 1368.5},
      "skipType": "ed"
    }
  ]
}
''',
          200,
        );
      }),
    );

    final intervals = await service.fetchSkipTimes(
      malId: 16498,
      episodeNumber: 1,
      episodeLength: const Duration(minutes: 24),
      types: const {
        AnimeSkipSegmentType.opening,
        AnimeSkipSegmentType.ending,
      },
    );

    expect(requestedUri.path, '/v2/skip-times/16498/1');
    expect(requestedUri.queryParametersAll['types'], ['op', 'ed']);
    expect(requestedUri.queryParameters['episodeLength'], '1440.0');
    expect(intervals, hasLength(2));
    expect(intervals.first.type, AnimeSkipSegmentType.opening);
    expect(intervals.first.start, const Duration(milliseconds: 85200));
    expect(intervals.first.end, const Duration(milliseconds: 175400));
    expect(intervals.last.type, AnimeSkipSegmentType.ending);
  });

  test('returns empty list when AniSkip has no timestamps', () async {
    final service = AniSkipService(
      apiBaseUrl: 'https://example.test',
      client: _FakeHttpClient((request) async => http.Response('', 404)),
    );

    final intervals = await service.fetchSkipTimes(
      malId: 1,
      episodeNumber: 1,
      episodeLength: const Duration(minutes: 20),
      types: const {AnimeSkipSegmentType.opening},
    );

    expect(intervals, isEmpty);
  });
}

class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this.handler);

  final FutureOr<http.Response> Function(http.BaseRequest request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      request: request,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
    );
  }
}
