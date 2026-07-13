import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

class PlaybackBackend {
  PlaybackBackend._();

  static bool _initialized = false;
  static bool _mediaKitAvailable = false;
  static Object? _initializationError;

  static bool get mediaKitAvailable => _mediaKitAvailable;
  static String get initializationError =>
      _initializationError?.toString() ?? '';

  static void ensureInitialized() {
    if (_initialized) {
      return;
    }

    try {
      MediaKit.ensureInitialized();
      _mediaKitAvailable = true;
    } catch (error) {
      _mediaKitAvailable = false;
      _initializationError = error;
      debugPrint('media_kit unavailable: $error');
    } finally {
      _initialized = true;
    }
  }
}
