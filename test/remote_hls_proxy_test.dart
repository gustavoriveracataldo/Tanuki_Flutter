import 'package:flutter_test/flutter_test.dart';
import 'package:toonami_viernes_noche_flutter/src/services/remote_hls_proxy.dart';

void main() {
  test('rewrites Zilla HTML fragments with media extensions', () {
    const source = '''#EXTM3U
#EXT-X-MAP:URI="https://player.zilla-networks.com/segs/id/init.html"
#EXTINF:10.0,
https://player.zilla-networks.com/segs/id/000.html
''';

    final rewritten = rewriteHlsPlaylist(
      source,
      playlistUri: Uri.parse('https://player.zilla-networks.com/m3u8/id'),
      localOrigin: 'http://127.0.0.1:1234',
    );

    expect(rewritten, contains('/media.mp4?url='));
    expect(rewritten, contains('/media.m4s?url='));
    expect(rewritten, isNot(contains('/segs/id/000.html\n')));
  });

  test('only proxies Zilla HLS endpoints', () {
    expect(
      shouldProxyZillaHls('https://player.zilla-networks.com/m3u8/id'),
      isTrue,
    );
    expect(shouldProxyZillaHls('https://example.test/video.m3u8'), isFalse);
  });
}
