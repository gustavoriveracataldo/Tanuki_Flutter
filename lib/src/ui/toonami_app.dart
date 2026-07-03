import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'home_screen.dart';
import 'toonami_theme.dart';

class ToonamiApp extends StatelessWidget {
  const ToonamiApp({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tanuki',
      debugShowCheckedModeBanner: false,
      theme: tanukiTheme,
      home: HomeScreen(controller: controller),
    );
  }
}
