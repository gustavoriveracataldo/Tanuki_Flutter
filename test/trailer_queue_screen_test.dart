import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toonami_viernes_noche_flutter/src/ui/trailer_queue_screen.dart';

const _sampleYouTubeTrailerUrl = 'https://www.youtube.com/watch?v=M-3YqJA6UlM';
const _sampleYouTubeShortUrl = 'https://youtu.be/M-3YqJA6UlM';
const _sampleYouTubeShortsUrl =
    'https://www.youtube.com/shorts/M-3YqJA6UlM?feature=share';

void main() {
  test('uses embedded trailer webview where the platform is stable', () {
    expect(
      canUseEmbeddedTrailerWebView(platform: TargetPlatform.android),
      isTrue,
    );
    expect(
      canUseEmbeddedTrailerWebView(platform: TargetPlatform.iOS),
      isTrue,
    );
    expect(
      canUseEmbeddedTrailerWebView(platform: TargetPlatform.linux),
      isTrue,
    );
    expect(
      canUseEmbeddedTrailerWebView(platform: TargetPlatform.windows),
      isTrue,
    );
    expect(
      canUseEmbeddedTrailerWebView(
        platform: TargetPlatform.android,
        isWeb: true,
      ),
      isFalse,
    );
  });

  test('opens all YouTube trailer queues in native Android player', () {
    expect(
      shouldOpenNativeYouTubeTrailerQueue(
        const [
          TrailerQueueEntry(
            title: 'One',
            trailerUrl: _sampleYouTubeTrailerUrl,
          ),
          TrailerQueueEntry(
            title: 'Two',
            trailerUrl: _sampleYouTubeShortUrl,
          ),
        ],
        platform: TargetPlatform.android,
      ),
      isTrue,
    );
    expect(
      shouldOpenNativeYouTubeTrailerQueue(
        const [
          TrailerQueueEntry(
            title: 'One',
            trailerUrl: _sampleYouTubeTrailerUrl,
          ),
          TrailerQueueEntry(
            title: 'MP4',
            trailerUrl: 'https://cdn.example.test/trailer.mp4',
          ),
        ],
        platform: TargetPlatform.android,
      ),
      isFalse,
    );
    expect(
      shouldOpenNativeYouTubeTrailerQueue(
        const [
          TrailerQueueEntry(
            title: 'One',
            trailerUrl: _sampleYouTubeTrailerUrl,
          ),
        ],
        platform: TargetPlatform.iOS,
      ),
      isFalse,
    );
  });

  test('embeds desktop trailer WebViews on Windows and Linux', () {
    expect(
      canUseFloatingDesktopTrailerWebView(platform: TargetPlatform.linux),
      isTrue,
    );
    expect(
      canUseFloatingDesktopTrailerWebView(platform: TargetPlatform.windows),
      isTrue,
    );
    expect(
      canUseFloatingDesktopTrailerWebView(
        platform: TargetPlatform.linux,
        isWeb: true,
      ),
      isFalse,
    );
    expect(
      shouldOpenNativeYouTubeTrailerQueue(
        const [
          TrailerQueueEntry(
            title: 'One',
            trailerUrl: _sampleYouTubeTrailerUrl,
          ),
        ],
        platform: TargetPlatform.linux,
      ),
      isFalse,
    );
  });

  test('recognizes YouTube trailer urls even with alternate formats', () {
    expect(isYouTubeTrailerUrl(_sampleYouTubeTrailerUrl), isTrue);
    expect(isYouTubeTrailerUrl(_sampleYouTubeShortUrl), isTrue);
    expect(isYouTubeTrailerUrl(_sampleYouTubeShortsUrl), isTrue);
    expect(
        isYouTubeTrailerUrl('https://cdn.example.test/trailer.mp4'), isFalse);
  });

  test('normalizes YouTube embeds before playback', () {
    const embedUrl = 'https://www.youtube-nocookie.com/embed/ODxfIvSgWuo'
        '?enablejsapi=1&wmode=opaque&autoplay=1';

    expect(
      normalizeTrailerUrl(embedUrl),
      'https://www.youtube.com/watch?v=ODxfIvSgWuo',
    );
  });

  test('builds internal detail links for trailer entries', () {
    final uri = trailerDetailUri(
      const TrailerQueueEntry(
        title: 'Frieren',
        trailerUrl: _sampleYouTubeShortUrl,
        providerId: 'catalog',
        slug: 'frieren',
        watchUrl: 'https://example.test/watch',
        seriesUrl: 'https://example.test/series/frieren',
        catalogId: 52991,
      ),
    );

    expect(uri.scheme, 'tanuki');
    expect(uri.host, 'series');
    expect(uri.path, '/detail');
    expect(uri.queryParameters['title'], 'Frieren');
    expect(uri.queryParameters['provider'], 'catalog');
    expect(uri.queryParameters['slug'], 'frieren');
    expect(uri.queryParameters['catalogId'], '52991');
    expect(
      uri.queryParameters['trailerUrl'],
      'https://www.youtube.com/watch?v=M-3YqJA6UlM',
    );
  });

  test('builds YouTube embed html for embedded WebView playback', () {
    final html = youtubeWebTrailerEmbedHtml('ODxfIvSgWuo');

    expect(html, contains('https://www.youtube.com/iframe_api'));
    expect(html, contains("host: 'https://www.youtube-nocookie.com'"));
    expect(html, contains('videoId: "ODxfIvSgWuo"'));
    expect(html, contains('autoplay: 1'));
    expect(html, contains('playsinline: 1'));
    expect(html, contains("origin: 'https://www.youtube-nocookie.com'"));
    expect(html, contains('strict-origin-when-cross-origin'));
    expect(
        html,
        contains(
            "iframe.allow = 'autoplay; encrypted-media; fullscreen; picture-in-picture'"));
  });

  test('builds desktop YouTube queue html with in-webview controls', () {
    final html = desktopYouTubeTrailerQueueHtml(
      title: 'Tendencias',
      entries: const [
        TrailerQueueEntry(
          title: 'One',
          trailerUrl: _sampleYouTubeTrailerUrl,
          providerId: 'catalog',
          slug: 'one',
        ),
        TrailerQueueEntry(
          title: 'Two',
          trailerUrl: _sampleYouTubeShortUrl,
          providerId: 'catalog',
          slug: 'two',
        ),
      ],
      initialIndex: 1,
    );

    expect(html, contains('TanukiTrailerPlayer.postMessage'));
    expect(html, contains("typeof window.TanukiTrailerPlayer === 'function'"));
    expect(html, contains('Trailer anterior'));
    expect(html, contains('Trailer siguiente'));
    expect(html, contains('Ver detalle'));
    expect(html, contains('"initialIndex":1'));
    expect(html, contains('"videoId":"M-3YqJA6UlM"'));
    expect(html, contains('"entryIndex":1'));
    expect(html, contains("host: 'https://www.youtube-nocookie.com'"));
    expect(html, contains('playWhenReady'));
  });
}
