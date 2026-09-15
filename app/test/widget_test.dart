import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/app/app.dart';
import 'package:ai_video_player_next/app/providers.dart';
import 'package:ai_video_player_next/core/diagnostics/diagnostic_log_service.dart';
import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/features/browser/mock_browser_service.dart';
import 'package:ai_video_player_next/features/player/media_picker.dart';
import 'package:ai_video_player_next/features/player/mock_services.dart';
import 'package:ai_video_player_next/features/recognition/recognition_media_resolver.dart';
import 'package:ai_video_player_next/features/recognition/recognition_service.dart';
import 'package:ai_video_player_next/features/recognition/transcript_store.dart';
import 'package:ai_video_player_next/features/recognition/whisper_model_store.dart';
import 'package:ai_video_player_next/features/settings/app_settings.dart';

class _FakeMediaPicker implements MediaPicker {
  @override
  Future<MediaSource?> pickLocalVideo() async => MediaSource.localFile(
        path: Platform.isWindows ? r'C:\test\示例视频.mp4' : '/test/示例视频.mp4',
        title: '示例视频.mp4',
      );
}

RecognitionService _testRecognition(TranscriptStore store) => RecognitionService(
      logs: DiagnosticLogService(),
      store: store,
      modelStore: Future.value(
        WhisperModelStore(installDirectory: Directory.systemTemp.createTempSync('models')),
      ),
      resolver: RecognitionMediaResolver(),
      sourceFactory: () => UnavailablePcmSource(message: 'test'),
      libraryPath: null,
    );

Widget _app({
  required MockPlayerService player,
  required MockBrowserService browser,
  AppSettingsController? settings,
}) {
  final store = TranscriptStore();
  return ProviderScope(
    overrides: [
      playerServiceProvider.overrideWithValue(player),
      mediaPickerProvider.overrideWithValue(_FakeMediaPicker()),
      browserServiceProvider.overrideWithValue(browser),
      transcriptStoreProvider.overrideWith((ref) => store),
      recognitionServiceProvider.overrideWith((ref) => _testRecognition(store)),
      if (settings != null) appSettingsProvider.overrideWith((ref) => settings),
    ],
    child: const AIVideoPlayerApp(),
  );
}

void main() {
  testWidgets('empty state opens local media and shows the player overlay', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = MockPlayerService();
    final browser = MockBrowserService();
    await tester.pumpWidget(_app(
      player: player,
      browser: browser,
      settings: AppSettingsController(waitForSubtitlePreparation: false),
    ));
    await tester.pump();

    expect(find.text('打开本地视频'), findsOneWidget);
    await tester.tap(find.text('打开本地视频'));
    await tester.pump();
    await tester.pump();

    expect(find.text('示例视频.mp4'), findsOneWidget);
    expect(find.byTooltip('播放速度'), findsOneWidget);
    expect(find.byTooltip('全屏 (F)'), findsOneWidget);
    await player.dispose();
  });

  testWidgets('browser handoff returns to the player and keeps the browser alive',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = MockPlayerService();
    final browser = MockBrowserService();
    await tester.pumpWidget(_app(
      player: player,
      browser: browser,
      settings: AppSettingsController(waitForSubtitlePreparation: false),
    ));
    await tester.pump();

    await tester.tap(find.text('从内置浏览器打开'));
    await tester.pump();
    expect(find.text('输入网址'), findsOneWidget);

    browser.handleCandidate(
      candidate: Uri.parse('https://media.example.test/clip.mp4'),
      originPage: Uri.parse('https://media.example.test/watch'),
      title: '浏览器视频',
      isVideoElementSource: true,
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('浏览器视频'), findsOneWidget);
    expect(find.byTooltip('播放速度'), findsOneWidget);

    await tester.tap(find.byTooltip('内置浏览器'));
    await tester.pump();
    expect(find.text('输入网址'), findsOneWidget);
    expect(browser.isDisposed, isFalse);
    await player.dispose();
    await browser.dispose();
  });

  testWidgets('settings page exposes recognition, translation and playback options',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = MockPlayerService();
    final browser = MockBrowserService();
    await tester.pumpWidget(_app(player: player, browser: browser));
    await tester.pump();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();

    expect(find.text('识别原语言'), findsOneWidget);
    expect(find.text('Whisper 模型'), findsOneWidget);
    expect(find.text('DeepL'), findsOneWidget);
    expect(find.text('通用 API'), findsOneWidget);
    expect(find.text('系统翻译'), findsOneWidget);
    expect(find.text('本地模型'), findsOneWidget);
    expect(find.text('翻译目标语言'), findsOneWidget);
    expect(find.text('双语'), findsOneWidget);
    expect(find.text('原文'), findsOneWidget);
    expect(find.text('译文'), findsOneWidget);
    expect(find.text('字幕优先'), findsOneWidget);
    expect(find.text('翻译优先'), findsOneWidget);
    expect(find.text('播放优先'), findsOneWidget);
    expect(find.textContaining('构建时间'), findsOneWidget);

    final playbackPriority = find.text('播放优先');
    await tester.ensureVisible(playbackPriority);
    await tester.tap(playbackPriority);
    await tester.pump();
    expect(find.text('不等待字幕，播放永不因识别暂停。'), findsOneWidget);

    await player.dispose();
    await browser.dispose();
  });

  testWidgets('system translation mode hides batching and answers the test', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = MockPlayerService();
    final browser = MockBrowserService();
    await tester.pumpWidget(_app(player: player, browser: browser));
    await tester.pump();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();

    final systemMode = find.text('系统翻译');
    await tester.ensureVisible(systemMode);
    await tester.tap(systemMode);
    await tester.pump();

    expect(find.textContaining('串行执行'), findsOneWidget);
    expect(find.text('并发请求数'), findsNothing);
    expect(find.text('每批字幕数'), findsNothing);

    final testButton = find.text('测试连接');
    await tester.ensureVisible(testButton);
    await tester.tap(testButton);
    await tester.pump();
    expect(find.textContaining('系统翻译'), findsWidgets);

    await player.dispose();
    await browser.dispose();
  });
}
