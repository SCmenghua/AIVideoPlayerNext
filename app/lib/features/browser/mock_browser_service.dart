import '../../domain/browser/browser_models.dart';
import 'browser_service_base.dart';

class MockBrowserService extends BrowserServiceBase {
  MockBrowserService();

  final List<Uri> loadedUrls = [];

  @override
  Future<void> initialize() async =>
      updateState(status: BrowserLoadStatus.idle);

  @override
  Future<void> load(Uri url) async {
    loadedUrls.add(url);
    updateState(
      url: url,
      title: url.host,
      status: BrowserLoadStatus.loaded,
      progress: 100,
      clearMessage: true,
    );
  }

  @override
  Future<void> goBack() async {}

  @override
  Future<void> goForward() async {}

  @override
  Future<void> reload() async {}

  @override
  Future<void> stop() async {}
}
