import 'package:flutter_test/flutter_test.dart';

import 'package:ai_video_player_next/features/browser/browser_service_base.dart';
import 'package:ai_video_player_next/domain/browser/browser_models.dart';

void main() {
  test('reports an unsupported media source once per page and reason',
      () async {
    final service = _TestBrowserService();
    final events = <BrowserEvent>[];
    final subscription = service.events.listen(events.add);
    final page = Uri.parse('https://example.test/watch/42#comments');

    service.reportUnsupported(
      page: page,
      reason: '该视频使用浏览器媒体流，无法由内置播放器接管。',
    );
    service.reportUnsupported(
      page: page.replace(fragment: 'related'),
      reason: '该视频使用浏览器媒体流，无法由内置播放器接管。',
    );
    await Future<void>.delayed(Duration.zero);

    expect(events.whereType<BrowserUnsupportedMedia>(), hasLength(1));
    await subscription.cancel();
    await service.dispose();
  });
}

class _TestBrowserService extends BrowserServiceBase {
  void reportUnsupported({required Uri page, required String reason}) =>
      emitUnsupported(page: page, reason: reason);

  @override
  Future<void> goBack() async {}

  @override
  Future<void> goForward() async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<void> load(Uri url) async {}

  @override
  Future<void> reload() async {}

  @override
  Future<void> stop() async {}
}
