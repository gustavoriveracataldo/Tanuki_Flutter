import 'dart:io';

import 'package:flutter/services.dart';

class WindowFullscreenController {
  WindowFullscreenController._();

  static const MethodChannel _desktopWindowChannel =
      MethodChannel('tanuki/window');

  static bool _fullscreen = false;

  static bool get isFullscreen => _fullscreen;

  static Future<bool> toggle() {
    return setFullscreen(!_fullscreen);
  }

  static Future<bool> setFullscreen(bool enabled) async {
    if (Platform.isLinux || Platform.isWindows) {
      await _desktopWindowChannel.invokeMethod<void>(
        'setFullscreen',
        enabled,
      );
    } else {
      await SystemChrome.setEnabledSystemUIMode(
        enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
    _fullscreen = enabled;
    return _fullscreen;
  }
}
