import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';

import 'package:ai_video_player_next/app/app.dart';
import 'package:ai_video_player_next/app/providers.dart';
import 'package:ai_video_player_next/domain/player/player_service.dart';
import 'package:ai_video_player_next/features/browser/mock_browser_service.dart';
import 'package:ai_video_player_next/features/player/media_picker.dart';
import 'package:ai_video_player_next/features/player/mock_services.dart';

class _FakeMediaPicker implements MediaPicker {
  @override
  Future<MediaSource?> pickLocalVideo() async => MediaSource.localFile(
        path: r'C:\test\示例视频.mp4',
        title: '示例视频.mp4',
      );
}

void main() {
  testWidgets('workbench opens local media through injected services',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = MockPlayerService();
    final browser = MockBrowserService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerServiceProvider.overrideWithValue(player),
          mediaPickerProvider.overrideWithValue(_FakeMediaPicker()),
          browserServiceProvider.overrideWithValue(browser),
        ],
        child: const AIVideoPlayerApp(),
      ),
    );
    await tester.pump();

    expect(find.text('尚未选择媒体'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('打开本地视频'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('打开内置浏览器'),
      ),
      findsNothing,
    );
    await tester.tap(find.text('打开本地视频').first);
    await tester.pump();
    await tester.pump();

    expect(find.text('示例视频.mp4'), findsOneWidget);
    await player.dispose();
  });

  testWidgets(
      'browser media handoff returns to the persistent player workspace',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = MockPlayerService();
    final browser = MockBrowserService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerServiceProvider.overrideWithValue(player),
          mediaPickerProvider.overrideWithValue(_FakeMediaPicker()),
          browserServiceProvider.overrideWithValue(browser),
        ],
        child: const AIVideoPlayerApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('内置浏览器').first);
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

    await tester.tap(find.text('内置浏览器').first);
    await tester.pump();
    expect(find.text('输入网址'), findsOneWidget);
    expect(browser.isDisposed, isFalse);
    await player.dispose();
    await browser.dispose();
  });

  testWidgets('settings workspace exposes recognition and translation modes',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = MockPlayerService();
    final browser = MockBrowserService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerServiceProvider.overrideWithValue(player),
          mediaPickerProvider.overrideWithValue(_FakeMediaPicker()),
          browserServiceProvider.overrideWithValue(browser),
        ],
        child: const AIVideoPlayerApp(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('设置').first);
    await tester.pump();

    expect(find.text('完整预识别'), findsOneWidget);
    expect(find.text('按需预取'), findsOneWidget);
    expect(find.text('DeepL'), findsOneWidget);
    expect(find.text('通用 API'), findsOneWidget);
    expect(find.text('本地模型'), findsOneWidget);
    expect(find.text('字幕显示'), findsOneWidget);
    expect(find.text('双语'), findsOneWidget);
    expect(find.text('原文'), findsOneWidget);
    expect(find.text('翻译'), findsOneWidget);
    expect(find.text('播放启动策略'), findsOneWidget);
    expect(find.text('字幕优先'), findsOneWidget);
    expect(find.text('翻译优先'), findsOneWidget);
    expect(find.text('播放优先'), findsOneWidget);
    expect(find.text('等待两条翻译或跳过四个窗口'), findsOneWidget);
    expect(find.textContaining('构建时间'), findsOneWidget);

    await tester.tap(find.text('按需预取'));
    await tester.pump();
    expect(find.text('识别保持约 20 至 45 秒的前瞻缓冲。'), findsOneWidget);

    final playbackPriority = find.text('播放优先');
    await tester.ensureVisible(playbackPriority);
    await tester.tap(playbackPriority);
    await tester.pump();
    final gateSwitch = tester.widget<SwitchListTile>(
      find.byType(SwitchListTile).first,
    );
    expect(gateSwitch.onChanged, isNotNull);
    expect(gateSwitch.value, isTrue);

    await player.dispose();
    await browser.dispose();
  });
}
