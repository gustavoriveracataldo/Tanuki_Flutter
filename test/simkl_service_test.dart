import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toonami_viernes_noche_flutter/src/services/simkl_service.dart';

void main() {
  test('handles SIMKL PIN auth and remote anime state', () async {
    final requests = <String>[];
    final postedBodies = <String, dynamic>{};
    final service = SimklService(
      defaultClientId: 'client',
      client: MockClient((request) async {
        requests.add('${request.method} ${request.url}');
        if (request.url.path == '/users/settings' ||
            request.url.path == '/sync/all-items/anime/' ||
            request.url.path == '/sync/add-to-list' ||
            request.url.path == '/sync/history' ||
            request.url.path == '/scrobble/start') {
          expect(request.headers['simkl-api-key'], 'client');
        }
        if (request.method == 'POST') {
          postedBodies[request.url.path] = jsonDecode(request.body);
        }
        return switch ('${request.method} ${request.url.path}') {
          'GET /oauth/pin' => http.Response(
              jsonEncode({
                'result': 'OK',
                'device_code': 'device',
                'user_code': 'ABCD',
                'verification_url': 'https://simkl.com/pin/',
                'expires_in': 900,
                'interval': 5,
              }),
              200,
              request: request,
            ),
          'GET /oauth/pin/ABCD' => http.Response(
              jsonEncode({'result': 'OK', 'access_token': 'token'}),
              200,
              request: request,
            ),
          'POST /users/settings' => http.Response(
              jsonEncode({
                'user': {
                  'name': 'SIMKL User',
                  'avatar': 'https://example.test/avatar.jpg',
                },
                'account': {'id': 99},
              }),
              200,
              request: request,
            ),
          'GET /sync/all-items/anime/' => http.Response(
              jsonEncode({
                'anime': [
                  {
                    'status': 'watching',
                    'last_watched': 'S1E3',
                    'total_episodes': 12,
                    'anime_type': 'tv',
                    'show': {
                      'title': 'Remote Demo',
                      'year': 2024,
                      'ids': {'simkl': 654, 'mal': 321},
                    },
                  },
                ],
              }),
              200,
              request: request,
            ),
          'GET /sync/history' => http.Response(
              jsonEncode({
                'shows': [
                  {
                    'title': 'Remote Demo',
                    'year': 2024,
                    'ids': {'simkl': 654, 'mal': 321},
                    'seasons': [
                      {
                        'number': 1,
                        'episodes': [
                          {'number': 4, 'progress': 42.5},
                          {'number': 5, 'progress': 0},
                        ],
                      },
                      {
                        'number': 2,
                        'episodes': [
                          {'number': 1, 'progress': 50},
                        ],
                      },
                    ],
                  },
                ],
              }),
              200,
              request: request,
            ),
          'POST /sync/add-to-list' => http.Response(
              jsonEncode({'result': 'OK'}),
              200,
              request: request,
            ),
          'POST /sync/history' => http.Response(
              jsonEncode({'result': 'OK'}),
              200,
              request: request,
            ),
          'POST /scrobble/start' => http.Response(
              jsonEncode({'result': 'OK'}),
              200,
              request: request,
            ),
          _ => http.Response('', 404, request: request),
        };
      }),
    );

    final clientId = service.resolveClientId('');
    final pin = await service.requestPinAuthorization(clientId: clientId);
    final poll = await service.pollPinAuthorization(pin);
    final user = await service.fetchAuthenticatedUser(
      accessToken: 'token',
      clientId: clientId,
    );
    final sync = await service.fetchRemoteAnimeState(
      accessToken: 'token',
      clientId: clientId,
    );
    final episodeProgress = await service.fetchRemoteEpisodeProgress(
      accessToken: 'token',
      clientId: clientId,
    );
    final push = await service.pushLocalAnimeState(
      accessToken: 'token',
      clientId: clientId,
      updates: const [
        SimklLocalAnimeUpdate(
          seriesKey: 'demo',
          title: 'Remote Demo',
          simklId: 654,
          malId: 321,
          year: 2024,
          listStatus: 'watching',
          watchedEpisodes: 3,
        ),
      ],
    );
    await service.scrobbleEpisode(
      accessToken: 'token',
      clientId: clientId,
      action: 'start',
      update: const SimklEpisodeScrobbleUpdate(
        seriesKey: 'demo',
        title: 'Remote Demo',
        simklId: 654,
        malId: 321,
        year: 2024,
        episodeNumber: 4,
        progressPercent: 42.5,
      ),
    );

    expect(pin.userCode, 'ABCD');
    expect(poll, isA<SimklPinPollSuccess>());
    expect(user.userName, 'SIMKL User');
    expect(sync.remoteEntries.single.title, 'Remote Demo');
    expect(sync.remoteEntries.single.watchedEpisodes, 3);
    expect(episodeProgress, hasLength(1));
    expect(episodeProgress.single.simklId, 654);
    expect(episodeProgress.single.malId, 321);
    expect(episodeProgress.single.episodeNumber, 4);
    expect(episodeProgress.single.progressPercent, 42.5);
    expect(push.pushedCount, 1);
    expect(postedBodies['/sync/add-to-list']['shows'].single['to'], 'watching');
    expect(
      postedBodies['/sync/history']['shows'].single['episodes'].last['number'],
      3,
    );
    expect(
      postedBodies['/scrobble/start']['shows'].single['ids']['simkl'],
      654,
    );
    expect(
      postedBodies['/scrobble/start']['shows']
          .single['seasons']
          .single['episodes']
          .single['number'],
      4,
    );
    expect(postedBodies['/scrobble/start']['progress'], 42.5);
    expect(
      requests,
      contains(startsWith('GET https://api.simkl.com/oauth/pin')),
    );
  });
}
