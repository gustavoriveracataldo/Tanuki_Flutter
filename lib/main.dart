import 'dart:io';

import 'package:dart_vlc/dart_vlc.dart' as vlc;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app_controller.dart';
import 'src/services/playback_backend.dart';
import 'src/ui/toonami_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSize = 1200;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 << 20;
  if (Platform.isLinux || Platform.isWindows) {
    vlc.DartVLC.initialize();
  }
  PlaybackBackend.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  final controller = AppController();
  await controller.initialize();
  runApp(ToonamiApp(controller: controller));
}
