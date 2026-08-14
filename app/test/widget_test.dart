import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import 'package:ai_video_player_next/app/app.dart';

void main() {
  testWidgets('workbench opens mock media through the injected player service', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(child: AIVideoPlayerApp()));
    await tester.pump();

    expect(find.text('尚未选择媒体'), findsOneWidget);
    await tester.tap(find.byTooltip('打开模拟媒体'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.text('示例访谈视频.mp4'), findsOneWidget);
  });
}
