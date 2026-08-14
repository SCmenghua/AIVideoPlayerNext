import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../features/player/player_screen.dart';

class AIVideoPlayerApp extends StatelessWidget {
  const AIVideoPlayerApp({super.key});

  String? get _fontFamily => switch (defaultTargetPlatform) {
        TargetPlatform.windows => 'Microsoft YaHei UI',
        TargetPlatform.android => 'Noto Sans CJK SC',
        TargetPlatform.iOS || TargetPlatform.macOS => 'PingFang SC',
        TargetPlatform.linux => 'Noto Sans CJK SC',
        TargetPlatform.fuchsia => null,
      };

  List<String> get _fontFallbacks => const [
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'PingFang SC',
        'Noto Sans CJK SC',
        'Noto Sans SC',
        'Segoe UI',
      ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI 视频播放器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF111315),
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF5ED6A0), brightness: Brightness.dark),
        textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: _fontFamily,
              fontFamilyFallback: _fontFallbacks,
            ),
        useMaterial3: true,
      ),
      home: const PlayerScreen(),
    );
  }
}
