import 'package:flutter/material.dart';

import '../features/player/player_screen.dart';

class AIVideoPlayerApp extends StatelessWidget {
  const AIVideoPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI 视频播放器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF111315),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5ED6A0), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const PlayerScreen(),
    );
  }
}
