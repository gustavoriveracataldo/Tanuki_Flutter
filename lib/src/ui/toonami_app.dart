import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../services/window_fullscreen_controller.dart';
import 'home_screen.dart';
import 'toonami_theme.dart';

class ToonamiApp extends StatefulWidget {
  const ToonamiApp({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<ToonamiApp> createState() => _ToonamiAppState();
}

class _ToonamiAppState extends State<ToonamiApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.startAutomaticAccountSync();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.resumeAutomaticAccountSync();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tanuki',
      debugShowCheckedModeBanner: false,
      theme: tanukiTheme,
      scrollBehavior: const _TanukiScrollBehavior(),
      builder: (context, child) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f11): _toggleAppFullscreen,
        },
        child: _TanukiDisplayScaler(child: child),
      ),
      home: HomeScreen(controller: widget.controller),
    );
  }

  void _toggleAppFullscreen() {
    unawaited(WindowFullscreenController.toggle());
  }
}

class _TanukiDisplayScaler extends StatelessWidget {
  const _TanukiDisplayScaler({required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scale = _tvUiScale(media);
    final textScaler = media.textScaler.clamp(
      minScaleFactor: 0.85,
      maxScaleFactor: 1,
    );
    final content = MediaQuery(
      data: media.copyWith(textScaler: textScaler),
      child: child ?? const SizedBox.shrink(),
    );
    if (scale >= 0.999) {
      return content;
    }
    final layoutSize = Size(
      media.size.width / scale,
      media.size.height / scale,
    );
    return SizedBox(
      width: media.size.width,
      height: media.size.height,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: layoutSize.width,
          height: layoutSize.height,
          child: MediaQuery(
            data: media.copyWith(
              size: layoutSize,
              textScaler: textScaler,
            ),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  double _tvUiScale(MediaQueryData media) {
    final isAndroidTv = !kIsWeb && Platform.isAndroid;
    if (!isAndroidTv) {
      return 1;
    }

    const targetSize = Size(1920, 1080);
    final widthScale = media.size.width / targetSize.width;
    final heightScale = media.size.height / targetSize.height;
    final scale = widthScale < heightScale ? widthScale : heightScale;

    if (scale >= 0.999) {
      return 1;
    }
    return scale.clamp(0.4, 1.0);
  }
}

class _TanukiScrollBehavior extends MaterialScrollBehavior {
  const _TanukiScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      };
}
