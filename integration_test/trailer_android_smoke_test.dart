import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:toonami_viernes_noche_flutter/src/ui/trailer_queue_screen.dart';

const _sampleYouTubeTrailerUrl = 'https://www.youtube.com/watch?v=M-3YqJA6UlM';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('prefers native Android player for YouTube trailers', (_) async {
    expect(
      shouldOpenNativeYouTubeTrailerQueue(
        const [
          TrailerQueueEntry(
            title: 'Test YouTube Trailer',
            trailerUrl: _sampleYouTubeTrailerUrl,
          ),
        ],
        platform: TargetPlatform.android,
      ),
      isTrue,
    );
  });
}
