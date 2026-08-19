import 'dart:async';

import 'package:flutter/services.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../domain/browser/browser_models.dart';
import 'browser_service_base.dart';

class WindowsBrowserService extends BrowserServiceBase {
  WindowsBrowserService({super.logs});

  final WebviewController controller = WebviewController();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized || isDisposed) return;
    final runtimeVersion = await WebviewController.getWebViewVersion();
    if (runtimeVersion == null) {
      logs?.error('内置浏览器', '未检测到 WebView2 Runtime');
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
        logs?.info('内置浏览器', '网页标题发生变化', {'标题': title});
        updateState(title: title);
      }));
      _subscriptions.add(controller.loadingState.listen((loading) {
        logs?.info('内置浏览器', '网页加载状态变化', {
          '状态': loading.name,
          '网址': currentState.url,
        });
        if (loading == LoadingState.navigationCompleted) {
          unawaited(controller.executeScript(_mediaBridgeScript));
        }
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
      logs?.info('内置浏览器', 'Windows 浏览器已初始化', {
        'WebView2版本': runtimeVersion,
      });
      updateState(status: BrowserLoadStatus.idle);
    } on PlatformException catch (error) {
      logs?.error('内置浏览器', 'Windows 浏览器初始化失败', {'错误': error});
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
    logs?.info('内置浏览器', '网页地址发生变化', {'网址': url});
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
    final page =
        currentState.url ?? Uri.tryParse(message['page']?.toString() ?? '');
    if (kind == 'trace') {
      logs?.info('网页媒体桥接', message['action']?.toString() ?? '网页事件', {
        '序号': message['sequence'],
        '网页地址': message['page'] ?? page,
        '网页标题': message['title'],
        '元素': message['element'],
        '视频序号': message['videoIndex'],
        '视频地址': message['url'],
        '视频状态': message['state'],
        '附加信息': message['detail'],
      });
      return;
    }
    if (page == null) return;
    if (kind == 'media') {
      final candidate = Uri.tryParse(message['url']?.toString() ?? '');
      if (candidate != null) {
        handleCandidate(
          candidate: candidate,
          originPage: page,
          title: message['title']?.toString(),
          isVideoElementSource: message['videoElement'] == true,
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
    logs?.info('内置浏览器', '请求打开网址', {'网址': url});
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
    if (_initialized && currentState.canGoBack) {
      logs?.info('内置浏览器', '用户点击后退');
      await controller.goBack();
    }
  }

  @override
  Future<void> goForward() async {
    if (_initialized && currentState.canGoForward) {
      logs?.info('内置浏览器', '用户点击前进');
      await controller.goForward();
    }
  }

  @override
  Future<void> reload() async {
    if (_initialized) {
      logs?.info('内置浏览器', '用户点击刷新');
      await controller.reload();
    }
  }

  @override
  Future<void> stop() async {
    if (_initialized) {
      logs?.info('内置浏览器', '用户停止加载');
      await controller.stop();
    }
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
  if (window.__aiVideoPlayerWindowsBridgeInstalled) {
    window.__aiVideoPlayerWindowsBridgeInstalled.start();
    return;
  }
  const post = (payload) => window.chrome?.webview?.postMessage(payload);
  let sequence = 0;
  const lastTrace = new Map();
  const sourceOf = (video) => video.currentSrc || video.src || video.querySelector('source[src]')?.src;
  const isHttpMedia = (source) => /^https?:/i.test(source || '');
  const textOf = (value, limit = 120) => {
    const text = (value || '').toString().replace(/\s+/g, ' ').trim();
    return text.length > limit ? `${text.slice(0, limit)}...` : text;
  };
  const trace = (action, detail = {}, video = null, element = null) => {
    const state = video ? {
      currentSrc: sourceOf(video) || '',
      paused: video.paused,
      readyState: video.readyState,
      networkState: video.networkState,
      visible: video.getBoundingClientRect().width > 8 && video.getBoundingClientRect().height > 8,
    } : {};
    const signature = JSON.stringify([action, detail, state.currentSrc, state.paused, state.readyState]);
    if (lastTrace.get(action) === signature) return;
    lastTrace.set(action, signature);
    const elementInfo = element instanceof Element ? {
      tag: element.tagName,
      id: textOf(element.id, 80),
      class: textOf(typeof element.className === 'string' ? element.className : '', 120),
      ariaLabel: textOf(element.getAttribute('aria-label'), 120),
      title: textOf(element.getAttribute('title'), 120),
      text: textOf(element.textContent, 120),
    } : {};
    post({
      kind: 'trace',
      action,
      sequence: ++sequence,
      timestamp: new Date().toISOString(),
      page: location.href,
      title: document.title,
      element: elementInfo,
      videoIndex: video ? Array.from(document.querySelectorAll('video')).indexOf(video) : -1,
      url: video ? sourceOf(video) : '',
      state,
      detail,
    });
  };
  const attach = (video) => {
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    video.playsInline = true;
    if (video.dataset.aiVideoPlayerBound) return;
    video.dataset.aiVideoPlayerBound = '1';
    trace('发现并绑定 video 元素', {}, video);
    let handoffRequested = false;
    let unsupportedReported = false;
    const intercept = (event) => {
      const source = sourceOf(video);
      trace(`用户触发网页 ${event.type} 操作`, {
        button: event.button,
        clientX: event.clientX,
        clientY: event.clientY,
      }, video, event.target);
      if (isHttpMedia(source)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        video.pause();
        if (!handoffRequested) {
          handoffRequested = true;
          trace('发送媒体交接', {source}, video);
          post({kind: 'media', url: source, title: document.title, videoElement: true});
        }
      } else if (!unsupportedReported) {
        unsupportedReported = true;
        trace('发送不支持媒体提示', {}, video);
        post({kind: 'unsupported'});
      }
    };
    video.addEventListener('pointerdown', intercept, true);
    video.addEventListener('click', intercept, true);
    video.addEventListener('play', intercept, true);
    video.addEventListener('pause', () => trace('video 触发 pause 事件', {}, video));
    video.addEventListener('playing', () => trace('video 触发 playing 事件', {}, video));
    video.addEventListener('loadedmetadata', () => trace('video 触发 loadedmetadata 事件', {}, video));
    video.addEventListener('canplay', () => trace('video 触发 canplay 事件', {}, video));
    video.addEventListener('waiting', () => trace('video 触发 waiting 事件', {}, video));
    video.addEventListener('error', () => trace('video 触发 error 事件', {
      mediaError: video.error?.code || '',
    }, video));
  };
  const bind = () => {
    document.querySelectorAll('video').forEach(attach);
  };
  document.addEventListener('pointerdown', (event) => trace('网页 pointerdown', {
    button: event.button,
    clientX: event.clientX,
    clientY: event.clientY,
  }, null, event.target), true);
  document.addEventListener('click', (event) => trace('网页 click', {}, null, event.target), true);
  document.addEventListener('fullscreenchange', () => trace('网页触发 fullscreenchange 事件', {
    fullscreen: Boolean(document.fullscreenElement),
  }), true);
  const originalRequestFullscreen = Element.prototype.requestFullscreen;
  if (originalRequestFullscreen) {
    Element.prototype.requestFullscreen = function() {
      trace('网页调用 requestFullscreen()', {}, this instanceof HTMLVideoElement ? this : null, this);
      return originalRequestFullscreen.apply(this, arguments);
    };
  }
  const start = () => {
    trace('媒体桥接已启动');
    bind();
    new MutationObserver(bind).observe(document, {childList: true, subtree: true});
  };
  window.__aiVideoPlayerWindowsBridgeInstalled = {start};
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, {once: true});
  } else {
    start();
  }
})();
''';
