import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'src/app_controller.dart';
import 'src/services/playback_backend.dart';
import 'src/ui/toonami_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  fvp.registerWith();
  PlaybackBackend.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  final controller = AppController();
  await controller.initialize();
  runApp(ToonamiApp(controller: controller));
}
