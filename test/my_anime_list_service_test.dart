import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/services/my_anime_list_service.dart';

void main() {
  test(
      'handles OAuth, refreshes auth, pushes local state and pulls remote list',
      () async {
    final requests = <String>[];
    final formBodies = <String, Map<String, String>>{};
    final tokenGrantTypes = <String>[];
    var tokenRequests = 0;
    final service = MyAnimeListService(
      defaultClientId: 'client',
      defaultClientSecret: 'secret',
      client: MockClient((request) async {
        requests.add('${request.method} ${request.url}');
        if (request.url.host == 'api.myanimelist.net') {
          expect(request.headers['Authorization'], startsWith('Bearer '));
        }
        if (request.method == 'POST' || request.method == 'PUT') {
          final body = Uri.splitQueryString(request.body);
          formBodies['${request.method} ${request.url.path}'] = body;
          if (request.url.path == '/v1/oauth2/token') {
            tokenGrantTypes.add(body['grant_type'] ?? '');
          }
        }
        return switch ('${request.method} ${request.url.path}') {
          'POST /v1/oauth2/token' => () {
              tokenRequests += 1;
              return http.Response(
                jsonEncode({
                  'access_token':
                      tokenRequests == 1 ? 'oauth-access' : 'fresh-access',
                  'refresh_token':
                      tokenRequests == 1 ? 'oauth-refresh' : 'fresh-refresh',
                  'expires_in': 3600,
                }),
                200,
                request: request,
              );
            }(),
          'GET /v2/users/@me' => http.Response(
              jsonEncode({
                'id': 42,
                'name': 'MAL User',
                'picture': 'https://example.test/mal.jpg',
              }),
              200,
              request: request,
            ),
          'GET /v2/anime/321' => http.Response(
              jsonEncode({
                'my_list_status': {
                  'status': 'plan_to_watch',
                  'num_episodes_watched': 1,
                  'tags': ['old-tag', MyAnimeListService.favoriteTag],
                },
              }),
              200,
              request: request,
            ),
          'PUT /v2/anime/321/my_list_status' => http.Response(
              jsonEncode({
                'status': 'watching',
                'num_episodes_watched': 3,
                'tags': ['old-tag', MyAnimeListService.favoriteTag],
              }),
              200,
              request: request,
            ),
          'GET /v2/users/@me/animelist' => http.Response(
              jsonEncode({
                'data': [
                  {
                    'node': {
                      'id': 321,
                      'title': 'Remote Demo',
                      'main_picture': {
                        'large': 'https://example.test/poster.jpg',
                      },
                      'alternative_titles': {
                        'en': 'Demo EN',
                        'ja': 'Demo JA',
                        'synonyms': ['Demo Alt'],
                      },
                      'start_date': '2024-01-10',
                      'media_type': 'tv',
                      'num_episodes': 12,
                    },
                    'list_status': {
                      'status': 'watching',
                      'num_episodes_watched': 3,
                      'tags': [MyAnimeListService.favoriteTag],
                    },
                  },
                ],
              }),
              200,
              request: request,
            ),
          _ => http.Response('{}', 404, request: request),
        };
      }),
    );

    final request = service.buildAuthorizationRequest(clientId: 'client');
    final connectedAuth = await service.completeAuthorization(
      request: request,
      redirectUrl:
          '${MyAnimeListService.redirectUri}?code=oauth-code&state=${request.state}',
      clientSecret: 'secret',
    );
    final auth = await service.ensureFreshAuth(
      auth: const MyAnimeListAuthState(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        expiresAtMs: 1,
        userId: 42,
      ),
      clientId: service.resolveClientId(''),
      clientSecret: service.resolveClientSecret(''),
    );
    final push = await service.pushLocalAnimeState(
      accessToken: auth.accessToken,
      updates: const [
        MyAnimeListLocalAnimeUpdate(
          seriesKey: 'demo',
          title: 'Remote Demo',
          malId: 321,
          year: 2024,
          format: 'TV',
          episodeCount: 12,
          watchedEpisodes: 3,
          favorite: true,
          listStatus: 'watching',
        ),
      ],
    );
    final sync = await service.fetchRemoteAnimeState(
      accessToken: auth.accessToken,
    );

    expect(request.authorizationUrl, contains('/v1/oauth2/authorize'));
    expect(request.authorizationUrl, contains('code_challenge_method=plain'));
    expect(connectedAuth.userName, 'MAL User');
    expect(auth.accessToken, 'fresh-access');
    expect(push.pushedCount, 1);
    expect(push.mappings['demo'], 321);
    expect(sync.remoteEntries.single.title, 'Remote Demo');
    expect(sync.remoteEntries.single.status.watchedEpisodes, 3);
    expect(
      formBodies['PUT /v2/anime/321/my_list_status']?['status'],
      'watching',
    );
    expect(
      formBodies['PUT /v2/anime/321/my_list_status']?['num_watched_episodes'],
      '3',
    );
    expect(
      formBodies['PUT /v2/anime/321/my_list_status']?['tags'],
      'old-tag,${MyAnimeListService.favoriteTag}',
    );
    expect(
        tokenGrantTypes, containsAll(['authorization_code', 'refresh_token']));
    expect(
      requests,
      contains(startsWith('POST https://myanimelist.net/v1/oauth2/token')),
    );
  });
}
