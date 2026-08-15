import 'dart:async';

import 'package:flutter/services.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../domain/browser/browser_models.dart';
import 'browser_service_base.dart';

class WindowsBrowserService extends BrowserServiceBase {
  final WebviewController controller = WebviewController();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized || isDisposed) return;
    final runtimeVersion = await WebviewController.getWebViewVersion();
    if (runtimeVersion == null) {
      updateState(
        status: BrowserLoadStatus.error,
        message: '未检测到 Microsoft Edge WebView2 Runtime，无法启动内置浏览器。',
      );
      return;
    }
    try {
      await controller.initialize();
      await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await controller.addScriptToExecuteOnDocumentCreated(_mediaBridgeScript);
      _subscriptions.add(controller.url.listen(_handleUrl));
      _subscriptions.add(controller.title.listen((title) {
        updateState(title: title);
      }));
      _subscriptions.add(controller.loadingState.listen((loading) {
        updateState(
          status: loading == LoadingState.loading
              ? BrowserLoadStatus.loading
              : BrowserLoadStatus.loaded,
          progress: loading == LoadingState.loading ? 30 : 100,
          clearMessage: loading != LoadingState.loading,
        );
      }));
      _subscriptions.add(controller.historyChanged.listen((history) {
        updateState(
          canGoBack: history.canGoBack,
          canGoForward: history.canGoForward,
        );
      }));
      _subscriptions.add(controller.onLoadError.listen((_) {
        updateState(
          status: BrowserLoadStatus.error,
          message: '网页加载失败，请检查网络或网址。',
        );
      }));
      _subscriptions.add(controller.webMessage.listen(_handleWebMessage));
      _initialized = true;
      updateState(status: BrowserLoadStatus.idle);
    } on PlatformException {
      updateState(
        status: BrowserLoadStatus.error,
        message: '内置浏览器启动失败，请确认 WebView2 Runtime 可用。',
      );
    }
  }

  void _handleUrl(String value) {
    final url = Uri.tryParse(value);
    if (url == null) return;
    final previousPage = currentState.url ?? url;
    if (handleCandidate(candidate: url, originPage: previousPage)) {
      if (previousPage != url) {
        unawaited(controller.goBack());
      }
      return;
    }
    updateState(
      url: url,
      status: BrowserLoadStatus.loading,
      progress: 10,
      clearMessage: true,
    );
  }

  void _handleWebMessage(dynamic message) {
    if (message is! Map) return;
    final kind = message['kind'];
    final page = currentState.url;
    if (page == null) return;
    if (kind == 'media') {
      final candidate = Uri.tryParse(message['url']?.toString() ?? '');
      if (candidate != null) {
        handleCandidate(
          candidate: candidate,
          originPage: page,
          title: message['title']?.toString(),
        );
      }
    } else if (kind == 'unsupported') {
      emitUnsupported(page: page, reason: '该视频未提供可交接的真实媒体地址。');
    }
  }

  @override
  Future<void> load(Uri url) async {
    await initialize();
    if (!_initialized) return;
    if (handleCandidate(candidate: url, originPage: currentState.url ?? url)) {
      return;
    }
    updateState(
      url: url,
      status: BrowserLoadStatus.loading,
      progress: 5,
      clearMessage: true,
    );
    await controller.loadUrl(url.toString());
  }

  @override
  Future<void> goBack() async {
    if (_initialized && currentState.canGoBack) await controller.goBack();
  }

  @override
  Future<void> goForward() async {
    if (_initialized && currentState.canGoForward) await controller.goForward();
  }

  @override
  Future<void> reload() async {
    if (_initialized) await controller.reload();
  }

  @override
  Future<void> stop() async {
    if (_initialized) await controller.stop();
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    if (_initialized) await controller.dispose();
    await super.dispose();
  }
}

const _mediaBridgeScript = r'''
(() => {
  const post = (payload) => window.chrome?.webview?.postMessage(payload);
  const attach = (video) => {
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    video.playsInline = true;
    if (video.dataset.aiVideoPlayerBound) return;
    video.dataset.aiVideoPlayerBound = '1';
    const intercept = (event) => {
      const source = video.currentSrc || video.src;
      event.preventDefault();
      event.stopImmediatePropagation();
      video.pause();
      if (source) {
        post({kind: 'media', url: source, title: document.title});
      } else {
        post({kind: 'unsupported'});
      }
    };
    video.addEventListener('click', intercept, true);
    video.addEventListener('play', intercept, true);
  };
  const bind = () => document.querySelectorAll('video').forEach(attach);
  new MutationObserver(bind).observe(document.documentElement, {childList: true, subtree: true});
  bind();
})();
''';
