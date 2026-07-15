import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toonami_viernes_noche_flutter/src/models.dart';
import 'package:toonami_viernes_noche_flutter/src/services/remote_catalog_service.dart';
import 'package:toonami_viernes_noche_flutter/src/ui/player_screen.dart';

void main() {
  test('searches ani.pm and preserves its ani/anime route', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      expect(request.url.path, '/api/anime/search');
      return http.Response(
        jsonEncode({
          'items': [
            {
              'id': 1516,
              'source': 'anilist',
              'title': 'Kirarin Revolution',
              'poster': 'https://img.test/kirarin.jpg',
              'year': 2006,
              'episodeCount': 153,
              'anilistId': '1516',
            },
            {
              'id': 7421,
              'source': 'anikoto',
              'title': 'Lamune',
              'year': 2005,
              'episodeCount': 12,
            },
          ],
        }),
        200,
      );
    }));

    final results = await service.searchAniPm('anime');

    expect(results.map((item) => item.slug), ['ani:1516', 'anime:7421']);
    expect(results.first.provider, RemoteProvider.aniPm);
    expect(results.first.toSeries(existingNames: const []).episodes,
        hasLength(153));
  });

  test('resolves dynamic ani.pm server and its own subtitle track', () async {
    final service = RemoteCatalogService(client: MockClient((request) async {
      if (request.url.path == '/api/anime/ani/182317') {
        return http.Response(
          jsonEncode({
            'title': 'The Dangers in My Heart: The Movie',
            'year': 2026,
            'anilistId': '182317',
            'malId': '59985',
          }),
          200,
        );
      }
      if (request.url.path == '/api/anime/src/servers') {
        expect(request.url.queryParameters['ep'], '1');
        return http.Response(
          jsonEncode({
            'sub': [
              {
                'provider': 'Lyra',
                'name': 'Lyra · 11',
                'kind': 'hls',
                'url': '/api/anime/src/hls?t=video',
                'priority': 108,
                'subtitle': 'soft',
                'tracks': [
                  {
                    'url': '/api/anime/src/vtt?t=sub',
                    'label': 'English',
                    'default': true,
                  }
                ],
              },
              {
                'provider': 'Nova',
                'name': 'Nova · 1',
                'kind': 'file',
                'url': '/api/anime/src/file?t=nova',
                'priority': 114,
              },
            ],
            'dub': [],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    }));
    const episode = EpisodeItem(
      seriesName: 'The Dangers in My Heart: The Movie',
      episodeIndex: 0,
      episodeNumber: 1,
      displayName: 'Episode 1',
      relativePath: 'Episode 1',
      filePath: 'https://ani.pm/ani/182317',
      sourceType: SourceType.remote,
      provider: RemoteProvider.aniPm,
      slug: 'ani:182317',
      watchUrl: 'https://ani.pm/ani/182317',
    );

    final stream = await service.resolveDirectStream(
      episode,
      preferredMode: 'sub',
      preferredServer: 'lyra-11',
    );

    expect(stream?.provider, RemoteProvider.aniPm);
    expect(stream?.server, 'lyra-11');
    expect(stream?.playbackKind, 'hls');
    expect(stream?.availableModes, containsAll(['lyra-11', 'nova-1']));
    expect(stream?.subtitleTracks.single.label, 'English');
    expect(stream?.subtitleTracks.single.url,
        'https://ani.pm/api/anime/src/vtt?t=sub');
  });

  test('persists ani.pm audio and dynamic server preferences', () {
    const preference = SeriesPlaybackPreference(
      provider: RemoteProvider.aniPm,
      aniPmMode: 'dub',
      aniPmServer: 'pulse-2',
    );
    final restored = SeriesPlaybackPreference.fromJson(preference.toJson());

    expect(restored.provider, RemoteProvider.aniPm);
    expect(restored.aniPmMode, 'dub');
    expect(restored.aniPmServer, 'pulse-2');
  });

  test('parses Pulse ASS subtitles for the player overlay', () {
    final cues = parseRemoteCaptionCues('''
[Script Info]
Title: Example
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:01:02.34,0:01:05.60,Default,,0,0,0,,{\\i1}Hello\\Nworld
''');

    expect(cues, hasLength(1));
    expect(cues.single.start,
        const Duration(minutes: 1, seconds: 2, milliseconds: 340));
    expect(cues.single.end,
        const Duration(minutes: 1, seconds: 5, milliseconds: 600));
    expect(cues.single.text, 'Hello\nworld');
  });
}
