import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';

import 'package:ai_video_player_next/app/app.dart';
import 'package:ai_video_player_next/app/providers.dart';
import 'package:ai_video_player_next/domain/audio/audio_models.dart';
import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/domain/subtitles/transcript_document.dart';
import 'package:ai_video_player_next/domain/translation/translation_service.dart';
import 'package:ai_video_player_next/features/audio/fake_audio_decoder.dart';
import 'package:ai_video_player_next/features/audio/recognition_controller.dart';
import 'package:ai_video_player_next/features/player/media_picker.dart';
import 'package:ai_video_player_next/features/player/mock_services.dart';
import 'package:ai_video_player_next/features/player/startup_preparation.dart';
import 'package:ai_video_player_next/features/settings/app_settings.dart';

void main() {
  final startedAt = DateTime(2026, 8, 19, 12, 0);

  StartupPreparation preparation() => StartupPreparation(
        startedAt: startedAt,
        strategy: PlaybackStartStrategy.translationPriority,
        waitForSubtitlePreparation: false,
      );

  test('translation priority does not delay automatic start', () {
    final state = preparation()..translationReadyAt = startedAt;

    state.networkReadyAt = startedAt.add(const Duration(milliseconds: 120));
    expect(state.canAutoPlay(windowsSkipped: 0), isTrue);
  });

  test('network readiness requires decoded media data, not an opened request',
      () {
    final source = MediaSource(
      uri: Uri.parse('https://media.example.test/video.mp4'),
      title: 'network.mp4',
      kind: MediaSourceKind.browserHandoff,
    );
    const initial = PlaybackSnapshot(
      status: PlaybackStatus.paused,
      position: Duration.zero,
      duration: Duration.zero,
      source: null,
      bufferedDuration: Duration(milliseconds: 999),
    );

    expect(
      hasStartupPlayableMediaData(source: source, snapshot: initial),
      isFalse,
    );
    expect(
      hasStartupPlayableMediaData(
        source: source,
        snapshot: initial.copyWith(
          bufferedDuration: minimumNetworkStartupBuffer,
        ),
      ),
      isTrue,
    );
  });

  test('local media does not wait for a network cache', () {
    final source = MediaSource.localFile(
      path: r'C:\test\local.mp4',
      title: 'local.mp4',
    );
    const snapshot = PlaybackSnapshot(
      status: PlaybackStatus.paused,
      position: Duration.zero,
      duration: Duration.zero,
      source: null,
    );

    expect(hasStartupPlayableMediaData(source: source, snapshot: snapshot),
        isTrue);
  });

  test('the preparation gate can release playback after four skipped windows',
      () {
    final state = preparation()
      ..networkReadyAt = startedAt
      ..translationReadyAt = null;
    state.waitForSubtitlePreparation = true;

    expect(state.canAutoPlay(windowsSkipped: 3), isFalse);
    expect(
      state.canAutoPlay(
        windowsSkipped: 4,
        nextTranslationReady: true,
      ),
      isTrue,
    );
  });

  test('skipped windows only affect the optional startup gate', () {
    final state = preparation()
      ..networkReadyAt = startedAt
      ..translationReadyAt = null;

    expect(state.canAutoPlay(windowsSkipped: 4), isTrue);
    expect(
      state.shouldPrompt(
        now: startedAt.add(const Duration(seconds: 10)),
        windowsSkipped: 4,
      ),
      isFalse,
    );
  });

  test('failed translation does not count toward the two-subtitle threshold',
      () {
    const translations = [
      TranscriptTranslation(
        segmentId: 'segment-1',
        targetLanguage: 'zh-CN',
        text: '',
        status: TranscriptTranslationStatus.failed,
      ),
      TranscriptTranslation(
        segmentId: 'segment-2',
        targetLanguage: 'zh-CN',
        text: '第二条译文',
        status: TranscriptTranslationStatus.translated,
      ),
    ];

    expect(hasEnoughTranslatedSubtitles(translations), isFalse);
    expect(
      hasEnoughTranslatedSubtitles([
        ...translations,
        const TranscriptTranslation(
          segmentId: 'segment-3',
          targetLanguage: 'zh-CN',
          text: '第三条译文',
          status: TranscriptTranslationStatus.translated,
        ),
      ]),
      isTrue,
    );
  });

  test('one completed translation does not satisfy the startup gate', () {
    final state = preparation()..networkReadyAt = startedAt;
    state.waitForSubtitlePreparation = true;

    state.recognitionReadyAt = startedAt.add(const Duration(seconds: 1));
    expect(
      state.canAutoPlay(
        windowsSkipped: 0,
        completedTranslationCount: 1,
      ),
      isFalse,
    );
  });

  test('timeout prompt starts at ten seconds while still blocked', () {
    final state = preparation();

    expect(
      state.shouldPrompt(
        now: startedAt.add(const Duration(seconds: 9, milliseconds: 999)),
        windowsSkipped: 0,
      ),
      isFalse,
    );
    expect(
      state.shouldPrompt(
        now: startedAt.add(const Duration(seconds: 10)),
        windowsSkipped: 0,
      ),
      isTrue,
    );
  });

  test('two completed translations suppress the timeout prompt', () {
    final state = preparation()
      ..networkReadyAt = startedAt
      ..translationReadyAt = startedAt.add(const Duration(seconds: 2));

    expect(
      state.shouldPrompt(
        now: startedAt.add(const Duration(seconds: 20)),
        windowsSkipped: 0,
        completedTranslationCount: 2,
      ),
      isFalse,
    );
  });

  testWidgets(
      'starts automatically, then waits during playback for translation',
      (tester) async {
    final player = MockPlayerService();
    final recognition = _recognitionController(
      player,
      recognizer: _EmptyWindowRecognitionService(),
    );
    final settings = _settings(waitForSubtitlePreparation: false);
    final translation = _AvailableTranslationService();
    await _pumpApp(
      tester,
      player: player,
      recognition: recognition,
      settings: settings,
      translation: translation,
    );

    await tester.tap(find.text('打开本地视频').first);
    await tester.pump();
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('正在准备播放'), findsNothing);
    expect(find.text('播放中: 等待翻译返回中。'), findsOneWidget);
    expect(find.byTooltip('开始播放'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('turning off preparation releases an already blocked startup',
      (tester) async {
    final player = MockPlayerService();
    final recognition = _recognitionController(
      player,
      recognizer: _EmptyWindowRecognitionService(),
    );
    final settings = _settings(waitForSubtitlePreparation: true);
    await _pumpApp(
      tester,
      player: player,
      recognition: recognition,
      settings: settings,
      translation: _AvailableTranslationService(),
    );

    await tester.tap(find.text('打开本地视频').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在准备播放'), findsOneWidget);

    settings.setWaitForSubtitlePreparation(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('正在准备播放'), findsNothing);
    expect(find.text('播放中: 等待翻译返回中。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows the timeout dialog after ten seconds', (tester) async {
    final player = MockPlayerService();
    final recognition = _recognitionController(
      player,
      recognizer: _EmptyWindowRecognitionService(),
    );
    final settings = _settings();
    final translation = _AvailableTranslationService();
    var now = startedAt;
    await _pumpApp(
      tester,
      player: player,
      recognition: recognition,
      settings: settings,
      translation: translation,
      now: () => now,
    );

    settings.setWaitForSubtitlePreparation(true);
    await tester.tap(find.text('打开本地视频').first);
    await tester.pump();
    now = startedAt.add(const Duration(seconds: 10, milliseconds: 200));
    await tester.pump(const Duration(seconds: 10, milliseconds: 200));

    expect(find.text('翻译准备时间较长'), findsOneWidget);
    expect(
      find.text('已启用启动准备，等待两条翻译完成或跳过四个识别窗口。'),
      findsOneWidget,
    );
    expect(find.text('继续等待'), findsOneWidget);
    expect(find.text('立即播放'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}

class _FakeMediaPicker implements MediaPicker {
  @override
  Future<MediaSource?> pickLocalVideo() async => MediaSource.localFile(
        path: r'C:\test\startup.mp4',
        title: 'startup.mp4',
      );
}

class _AvailableTranslationService
    implements TranslationService, TranslationServiceStatusProvider {
  @override
  TranslationServiceStatus get status =>
      const TranslationServiceStatus.available(provider: 'test');

  @override
  Future<TranslationResult> translate(TranslationRequest request) async =>
      TranslationResult(
        segmentId: request.segmentId,
        text: request.text,
        provider: 'test',
      );
}

RecognitionController _recognitionController(
  MockPlayerService player, {
  required WindowRecognitionService recognizer,
}) =>
    RecognitionController(
      player: player,
      decoder: FakeAudioDecoder(chunks: [
        for (var index = 0; index < 8; index++)
          AudioChunk(
            sessionId: 'decoder-session',
            mediaStart: Duration(seconds: index),
            sampleRate: 16000,
            channels: 1,
            samples: List<double>.filled(16000, 0.1),
            isLast: index == 7,
          ),
      ]),
      recognizer: recognizer,
    );

class _EmptyWindowRecognitionService implements WindowRecognitionService {
  @override
  Future<WindowRecognitionResult> recognize(RecognitionWindow window) async =>
      WindowRecognitionResult(window: window, events: const []);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

AppSettingsController _settings({bool waitForSubtitlePreparation = true}) =>
    AppSettingsController(
      translationMode: TranslationMode.genericApi,
      genericEndpoint: Uri.parse('https://example.test'),
      genericApiKey: 'test-key',
      waitForSubtitlePreparation: waitForSubtitlePreparation,
    );

Future<void> _pumpApp(
  WidgetTester tester, {
  required MockPlayerService player,
  required RecognitionController recognition,
  required AppSettingsController settings,
  required TranslationService translation,
  DateTime Function()? now,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerServiceProvider.overrideWithValue(player),
        recognitionControllerProvider.overrideWithValue(recognition),
        appSettingsProvider.overrideWith((ref) => settings),
        translationServiceProvider.overrideWithValue(translation),
        mediaPickerProvider.overrideWithValue(_FakeMediaPicker()),
      ],
      child: AIVideoPlayerApp(now: now ?? DateTime.now),
    ),
  );
  await tester.pump();
}
