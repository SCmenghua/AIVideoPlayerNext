import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import 'package:ai_video_player_next/app/app.dart';
import 'package:ai_video_player_next/app/providers.dart';
import 'package:ai_video_player_next/domain/player/player_service.dart';
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerServiceProvider.overrideWithValue(player),
          mediaPickerProvider.overrideWithValue(_FakeMediaPicker()),
        ],
        child: const AIVideoPlayerApp(),
      ),
    );
    await tester.pump();

    expect(find.text('尚未选择媒体'), findsOneWidget);
    await tester.tap(find.byTooltip('打开本地视频').first);
    await tester.pump();
    await tester.pump();

    expect(find.text('示例视频.mp4'), findsOneWidget);
    await player.dispose();
  });
}
