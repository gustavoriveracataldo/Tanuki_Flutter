import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toonami_viernes_noche_flutter/src/services/open_subtitles_service.dart';

void main() {
  test('searches legacy OpenSubtitles and caches gzipped SRT downloads',
      () async {
    final requested = <Uri>[];
    final cacheDir = await io.Directory.systemTemp.createTemp(
      'tanuki_open_subtitles_test_',
    );
    addTearDown(() async {
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    });

    final client = MockClient((request) async {
      requested.add(request.url);
      if (request.url.host == 'data.vidsrcme.test') {
        return http.Response(
          jsonEncode({
            'status_code': '200',
            'data': {
              'title': 'Predator 1987',
              'imdb_id': 'tt0093773',
              'file_name': 'Predator.1987.1080p.BluRay.x264.mkv',
            },
            'default_subs': [
              {
                'lang': 'Spanish',
                'code': 'es',
                'url': 'https://vidapi.test/predator.es.srt',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.host == 'rest.opensubtitles.test') {
        expect(request.headers['X-User-Agent'], 'trailers.to-UA');
        final language =
            request.url.path.contains('sublanguageid-spa') ? 'spa' : 'eng';
        return http.Response(
          jsonEncode([
            {
              'IDSubtitleFile': language == 'spa' ? '1951656656' : '74056',
              'SubDownloadLink':
                  'https://dl.opensubtitles.test/${language}_file.gz',
              'SubFileName': language == 'spa'
                  ? 'Predator.1987.1080p.BluRay.SPA.srt'
                  : 'Predator.1987.1080p.BluRay.ENG.srt',
              'SubLanguageID': language,
              'LanguageName': language == 'spa' ? 'Spanish' : 'English',
              'SubEncoding': 'UTF-8',
              'SubDownloadsCnt': '1000',
              'MovieYear': '1987',
              'SubFromTrusted': '1',
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.host == 'dl.opensubtitles.test') {
        final body = utf8.encode(
          '1\n00:00:01,000 --> 00:00:02,000\nHola desde OpenSubtitles\n',
        );
        return http.Response.bytes(
          io.gzip.encode(body),
          200,
          headers: {'content-type': 'application/octet-stream'},
        );
      }
      return http.Response('', 404);
    });

    final service = OpenSubtitlesService(
      client: client,
      restBaseUrl: 'https://rest.opensubtitles.test',
      vidsrcMetaBaseUrl: 'https://data.vidsrcme.test',
      cacheDirectory: cacheDir,
    );
    addTearDown(service.close);

    final tracks = await service.searchSubtitleTracks(
      const OpenSubtitlesSearchRequest(
        query: 'Predator',
        languages: ['es', 'en'],
        mediaType: 'movie',
        tmdbId: 106,
        year: 1987,
      ),
    );

    expect(
      requested.map((uri) => uri.toString()),
      containsAll([
        'https://data.vidsrcme.test/api.php?type=movie&tmdb=106',
        'https://rest.opensubtitles.test/search/imdbid-0093773/sublanguageid-spa',
        'https://rest.opensubtitles.test/search/imdbid-0093773/sublanguageid-eng',
      ]),
    );
    expect(tracks.map((track) => track.language), containsAll(['es', 'en']));
    expect(tracks.first.label, startsWith('Vidsrc Español'));

    final downloaded = tracks.where((track) => track.url.endsWith('.srt'));
    expect(downloaded, isNotEmpty);
    final text = await io.File(downloaded.last.url).readAsString();
    expect(text, contains('Hola desde OpenSubtitles'));
  });
}
