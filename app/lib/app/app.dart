import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/player/player_shell.dart';

class AIVideoPlayerApp extends StatelessWidget {
  const AIVideoPlayerApp({super.key, this.now = DateTime.now});

  final DateTime Function() now;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AI 视频播放器',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: PlayerShell(now: now),
      );
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3DDC97),
    brightness: Brightness.dark,
    surface: const Color(0xFF0E1012),
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFallbacks,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.4)),
  );
}

String? get _fontFamily => switch (defaultTargetPlatform) {
      TargetPlatform.windows => 'Microsoft YaHei UI',
      TargetPlatform.android => 'Noto Sans CJK SC',
      TargetPlatform.iOS || TargetPlatform.macOS => 'PingFang SC',
      TargetPlatform.linux => 'Noto Sans CJK SC',
      TargetPlatform.fuchsia => null,
    };

const _fontFallbacks = [
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
  'Hiragino Sans',
  'Noto Sans CJK JP',
  'Noto Sans CJK SC',
  'Noto Sans SC',
  'Segoe UI',
];

class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AI 视频播放器',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
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
                    Text('播放器初始化失败', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    const Text('请重新安装完整的应用包；若问题仍然存在，请反馈以下诊断信息。'),
                    const SizedBox(height: 16),
                    SelectableText(error.toString(), style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
