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

class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI 视频播放器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF111315),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5ED6A0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, size: 40),
                  const SizedBox(height: 16),
                  Text(
                    '播放器初始化失败',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text('请重新安装完整的应用包；若问题仍然存在，请反馈以下诊断信息。'),
                  const SizedBox(height: 16),
                  SelectableText(
                    error.toString(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
