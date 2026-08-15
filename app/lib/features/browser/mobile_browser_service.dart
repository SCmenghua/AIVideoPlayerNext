import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../domain/browser/browser_models.dart';
import 'browser_service_base.dart';

class MobileBrowserService extends BrowserServiceBase {
  MobileBrowserService({super.logs});

  late final WebViewController controller;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  @override
  Future<void> initialize() async {
    if (_initialized || isDisposed) return;
    final PlatformWebViewControllerCreationParams params;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }
    controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final url = Uri.tryParse(request.url);
          if (url != null &&
              (url.scheme == 'blob' || url.scheme == 'mediasource')) {
            emitUnsupported(
              page: currentState.url ?? url,
              reason: '该视频使用浏览器媒体流，无法由内置播放器接管。',
            );
            return NavigationDecision.navigate;
          }
          if (url != null &&
              handleCandidate(
                candidate: url,
                originPage: currentState.url ?? url,
              )) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (url) {
          final page = Uri.tryParse(url);
          logs?.info('内置浏览器', '网页开始加载', {'网址': url});
          if (page != null) {
            updateState(
              url: page,
              status: BrowserLoadStatus.loading,
              progress: 5,
              clearMessage: true,
            );
          }
          unawaited(_injectMediaBridge());
        },
        onPageFinished: (url) async {
          final page = Uri.tryParse(url);
          logs?.info('内置浏览器', '网页加载完成', {
            '网址': url,
            '标题': await controller.getTitle(),
          });
          if (page != null) {
            updateState(
                url: page, status: BrowserLoadStatus.loaded, progress: 100);
          }
          await _injectMediaBridge();
          await _updateHistory();
        },
        onProgress: (progress) => updateState(
          status: BrowserLoadStatus.loading,
          progress: progress,
        ),
        onWebResourceError: (error) {
          logs?.error('内置浏览器', '网页资源加载错误', {
            '错误代码': error.errorCode,
            '描述': error.description,
            '网址': error.url,
            '主框架': error.isForMainFrame,
          });
          if (error.isForMainFrame ?? false) {
            updateState(
              status: BrowserLoadStatus.error,
              message: '网页加载失败，请检查网络或网址。',
            );
          }
        },
      ))
      ..addJavaScriptChannel(
        'AIVideoPlayerMedia',
        onMessageReceived: _handleJavaScriptMessage,
      );
    _initialized = true;
    logs?.info('内置浏览器', '移动端浏览器已初始化', {
      '平台': defaultTargetPlatform.name,
    });
    updateState(status: BrowserLoadStatus.idle);
    await _installEarlyMediaBridge();
  }

  void _handleJavaScriptMessage(JavaScriptMessage message) {
    try {
      final payload = jsonDecode(message.message) as Map<String, dynamic>;
      final page = currentState.url ??
          Uri.tryParse(payload['page']?.toString() ?? '');
      if (payload['kind'] == 'trace') {
        logs?.info('网页媒体桥接', payload['action']?.toString() ?? '网页事件', {
          '序号': payload['sequence'],
          '网页地址': payload['page'] ?? page,
          '网页标题': payload['title'],
          '元素': payload['element'],
          '视频序号': payload['videoIndex'],
          '视频地址': payload['url'] ?? payload['source'],
          '视频状态': payload['state'],
          '附加信息': payload['detail'],
        });
        return;
      }
      if (page == null) return;
      if (payload['kind'] == 'media') {
        final candidate = Uri.tryParse(payload['url']?.toString() ?? '');
        if (candidate != null) {
          handleCandidate(
            candidate: candidate,
            originPage: page,
            title: payload['title']?.toString(),
            isVideoElementSource: payload['videoElement'] == true,
          );
        }
      } else if (payload['kind'] == 'unsupported') {
        emitUnsupported(page: page, reason: '该视频未提供可交接的真实媒体地址。');
      }
    } on FormatException {
      // Ignore third-party page messages that are not our JSON payload.
    } catch (error) {
      logs?.error('网页媒体桥接', '处理网页消息失败', {'错误': error});
    }
  }

  Future<void> _injectMediaBridge() async {
    try {
      await controller.runJavaScript(_mobileMediaBridgeScript);
    } catch (_) {
      // A navigation can replace the document while the bridge is injected.
    }
  }

  Future<void> _installEarlyMediaBridge() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    final platform = controller.platform;
    if (platform is! WebKitWebViewController) return;
    try {
      await const MethodChannel('ai_video_player/ios_webview').invokeMethod<void>(
        'installUserScript',
        <String, Object>{
          'identifier': platform.webViewIdentifier,
          'source': _mobileMediaBridgeScript,
        },
      );
      logs?.info('网页媒体桥接', 'iOS 文档开始阶段注入成功');
    } catch (_) {
      logs?.warning('网页媒体桥接', 'iOS 提前注入失败，使用页面回调注入');
      // The normal page callbacks remain as a fallback on unsupported hosts.
    }
  }

  Future<void> _updateHistory() async {
    updateState(
      canGoBack: await controller.canGoBack(),
      canGoForward: await controller.canGoForward(),
      title: await controller.getTitle() ?? '',
    );
  }

  @override
  Future<void> load(Uri url) async {
    await initialize();
    logs?.info('内置浏览器', '请求打开网址', {'网址': url});
    if (handleCandidate(candidate: url, originPage: currentState.url ?? url)) {
      return;
    }
    await controller.loadRequest(url);
  }

  @override
  Future<void> goBack() async {
    if (_initialized && await controller.canGoBack()) {
      logs?.info('内置浏览器', '用户点击后退');
      await controller.goBack();
      await _updateHistory();
    }
  }

  @override
  Future<void> goForward() async {
    if (_initialized && await controller.canGoForward()) {
      logs?.info('内置浏览器', '用户点击前进');
      await controller.goForward();
      await _updateHistory();
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
      await controller.runJavaScript('window.stop();');
    }
  }
}

const _mobileMediaBridgeScript = r'''
(() => {
  if (window.__aiVideoPlayerMediaBridgeInstalled) {
    window.__aiVideoPlayerMediaBridgeInstalled.start();
    return;
  }

  const post = (payload) => window.AIVideoPlayerMedia?.postMessage(JSON.stringify(payload));
  let traceSequence = 0;
  const lastTraces = new Map();
  const shortText = (value, limit = 120) => {
    const text = (value || '').toString().replace(/\s+/g, ' ').trim();
    return text.length > limit ? `${text.slice(0, limit)}...` : text;
  };
  const elementInfo = (element) => {
    if (!(element instanceof Element)) return {};
    return {
      tag: element.tagName,
      id: shortText(element.id, 80),
      class: shortText(typeof element.className === 'string' ? element.className : '', 120),
      ariaLabel: shortText(element.getAttribute('aria-label'), 120),
      title: shortText(element.getAttribute('title'), 120),
      text: shortText(element.textContent, 120),
    };
  };
  const trace = (action, detail = {}, video = null, element = null, dedupe = '') => {
    const state = video ? {
      currentSrc: video.currentSrc || '',
      src: video.getAttribute('src') || '',
      paused: video.paused,
      readyState: video.readyState,
      networkState: video.networkState,
      width: Math.round(video.getBoundingClientRect().width),
      height: Math.round(video.getBoundingClientRect().height),
      visible: isVisible(video),
      advertisement: isLikelyAdvertisement(video),
    } : {};
    const signature = dedupe || JSON.stringify([action, detail, state.currentSrc, state.paused, state.readyState]);
    if (lastTraces.get(action) === signature) return;
    lastTraces.set(action, signature);
    post({
      kind: 'trace',
      action,
      sequence: ++traceSequence,
      timestamp: new Date().toISOString(),
      page: location.href,
      title: document.title,
      element: elementInfo(element),
      videoIndex: video ? Array.from(document.querySelectorAll('video')).indexOf(video) : -1,
      url: video ? sourceOf(video) : '',
      state,
      detail,
    });
  };
  const originalPlay = HTMLMediaElement.prototype.play;
  const originalRequestFullscreen = Element.prototype.requestFullscreen;
  const originalVideoFullscreen = HTMLVideoElement.prototype.webkitEnterFullscreen;
  let selectedVideo = null;
  let selectionExpiresAt = 0;
  let selectionSerial = 0;
  let lastHandoff = '';
  const absolute = (source) => {
    try {
      return new URL(source, document.baseURI).href;
    } catch (_) {
      return source || '';
    }
  };
  const sourceOf = (video) => absolute(
    video.currentSrc ||
    video.src ||
    video.getAttribute('src') ||
    video.querySelector('source[src]')?.src ||
    video.querySelector('source[src]')?.getAttribute('src')
  );
  const isHttpMedia = (source) => /^https?:/i.test(source || '');
  const isBrowserOnlySource = (source) => /^(blob:|mediasource:|data:)/i.test(source || '');
  const isLikelyAdvertisementSource = (source) => {
    try {
      const url = new URL(source);
      const marker = `${url.hostname}${url.pathname}${url.search}`.toLowerCase();
      return /(^|[./?&=_-])(ads?|adserver|advert(?:isement)?|preroll|midroll|postroll|commercial|doubleclick|vast|vmap)([./?&=_-]|$)/.test(marker);
    } catch (_) {
      return false;
    }
  };
  const isVisible = (video) => {
    const rect = video.getBoundingClientRect();
    const style = window.getComputedStyle(video);
    return rect.width > 8 && rect.height > 8 && style.display !== 'none' && style.visibility !== 'hidden';
  };
  const isLikelyAdvertisement = (video) => {
    let node = video;
    for (let depth = 0; node instanceof Element && depth < 5; depth += 1, node = node.parentElement) {
      const marker = [node.id, node.className, node.getAttribute('aria-label')]
        .filter((value) => typeof value === 'string')
        .join(' ')
        .toLowerCase();
      if (/(advert|advertisement|preroll|midroll|postroll|commercial|promo|(^|[-_\s])ads?([-_\s]|$))/.test(marker)) {
        return true;
      }
    }
    return false;
  };
  const primaryVideo = () => Array.from(document.querySelectorAll('video'))
    .filter(isVisible)
    .filter((video) => !isLikelyAdvertisement(video))
    .sort((left, right) => {
      const leftRect = left.getBoundingClientRect();
      const rightRect = right.getBoundingClientRect();
      return (rightRect.width * rightRect.height) - (leftRect.width * leftRect.height);
    })[0] || null;
  const videoFromEvent = (event) => {
    const path = event.composedPath ? event.composedPath() : [];
    return path.find((node) => node instanceof HTMLVideoElement) || primaryVideo();
  };
  const isPlaybackGesture = (event, video) => {
    const target = event.target instanceof Element ? event.target : null;
    const label = [
      target?.getAttribute('aria-label'),
      target?.getAttribute('title'),
      target?.id,
      target?.className,
    ].filter(Boolean).join(' ').toLowerCase();
    if (/play|播放|fullscreen|全屏|全畫面|全屏幕/.test(label)) return true;
    const rect = video.getBoundingClientRect();
    return event.clientX >= rect.left && event.clientX <= rect.right &&
      event.clientY >= rect.top && event.clientY <= rect.bottom;
  };
  const arm = (video) => {
    selectedVideo = video;
    selectionSerial += 1;
    lastHandoff = '';
    const serial = selectionSerial;
    trace('建立播放意图', {serial}, video);
    // Keep the intent while a short pre-roll finishes and the page swaps in its content source.
    selectionExpiresAt = Date.now() + 120000;
    // Some sites create the video source only after their click handler returns.
    // Retry against the selected element and any replacement element so the
    // first tap does not merely start playback inside the web view.
    [40, 120, 250, 500, 900, 1500, 2500, 4000].forEach((delay) => {
      setTimeout(() => {
        if (serial !== selectionSerial || Date.now() >= selectionExpiresAt) return;
        let candidate = selectedVideo?.isConnected ? selectedVideo : null;
        const selectedSource = candidate ? sourceOf(candidate) : '';
        if (!candidate || !isVisible(candidate) || isLikelyAdvertisement(candidate) ||
            isLikelyAdvertisementSource(selectedSource)) {
          candidate = primaryVideo();
          if (candidate) selectedVideo = candidate;
        }
        if (!candidate) return;
        trace('重试检查选中视频', {serial, delay}, candidate);
        attach(candidate);
        reportVideo(candidate);
      }, delay);
    });
    // A few players emit `play` before assigning currentSrc, then never emit
    // another media event after the source becomes ready. Observe only this
    // user-selected video briefly so the first tap still hands off.
    let checks = 0;
    const observeSelectedPlayback = () => {
      if (serial !== selectionSerial || Date.now() >= selectionExpiresAt || checks >= 80) return;
      checks += 1;
      let candidate = selectedVideo?.isConnected ? selectedVideo : null;
      const selectedSource = candidate ? sourceOf(candidate) : '';
      if (!candidate || !isVisible(candidate) || isLikelyAdvertisement(candidate) ||
          isLikelyAdvertisementSource(selectedSource)) {
        candidate = primaryVideo();
      }
      if (candidate) {
        if (candidate !== selectedVideo && isVisible(candidate) && !isLikelyAdvertisement(candidate)) {
          selectedVideo = candidate;
        }
        if (hasIntentFor(candidate) && !candidate.paused) {
          trace('观察到选中视频正在播放', {serial, check: checks}, candidate);
          reportVideo(candidate);
        }
      }
      setTimeout(observeSelectedPlayback, 100);
    };
    setTimeout(observeSelectedPlayback, 50);
  };
  const hasIntentFor = (video) => selectedVideo === video && Date.now() < selectionExpiresAt;
  const emitMedia = (source) => {
    if (source === lastHandoff) return;
    lastHandoff = source;
    trace('发送媒体交接', {source}, selectedVideo, null, `handoff:${source}`);
    post({kind: 'media', url: source, title: document.title, videoElement: true});
  };
  const emitUnsupported = () => {
    trace('发送不支持媒体提示', {}, selectedVideo);
    post({kind: 'unsupported'});
  };
  const reportVideo = (video) => {
    if (!hasIntentFor(video) || isLikelyAdvertisement(video)) {
      trace('忽略媒体候选', {
        hasIntent: hasIntentFor(video),
        reason: isLikelyAdvertisement(video) ? '疑似广告' : '没有用户播放意图',
      }, video);
      return false;
    }
    const source = sourceOf(video);
    trace('检查媒体候选', {
      sourceType: isBrowserOnlySource(source) ? '浏览器内部流' : '外部地址',
    }, video);
    // A page can reuse one video element for a pre-roll and its main content.
    // Leave identifiable ad sources in the inline web view and wait for the next source.
    if (isLikelyAdvertisementSource(source)) {
      trace('忽略疑似广告媒体源', {}, video);
      return false;
    }
    if (isHttpMedia(source)) {
      trace('发现可交接媒体源', {}, video);
      video.pause();
      emitMedia(source);
      return true;
    }
    if (isBrowserOnlySource(source)) {
      trace('发现浏览器内部媒体流', {}, video);
      emitUnsupported();
    }
    return false;
  };

  const attach = (video) => {
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    video.playsInline = true;
    if (video.dataset.aiVideoPlayerBound) return;
    video.dataset.aiVideoPlayerBound = '1';
    trace('发现并绑定 video 元素', {}, video);
    video.addEventListener('play', () => {
      // Autoplaying advertisements have no user-selected video and are ignored.
      trace('video 触发 play 事件', {}, video);
      reportVideo(video);
    }, true);
    video.addEventListener('pause', () => trace('video 触发 pause 事件', {}, video));
    video.addEventListener('playing', () => trace('video 触发 playing 事件', {}, video));
    video.addEventListener('waiting', () => trace('video 触发 waiting 事件', {}, video));
    video.addEventListener('canplay', () => trace('video 触发 canplay 事件', {}, video));
    video.addEventListener('error', () => trace('video 触发 error 事件', {
      mediaError: video.error?.code || '',
    }, video));
    video.addEventListener('loadedmetadata', () => {
      trace('video 触发 loadedmetadata 事件', {}, video);
      reportVideo(video);
    }, true);
    video.addEventListener('emptied', () => trace('video 触发 emptied 事件', {}, video));
    video.addEventListener('durationchange', () => trace('video 触发 durationchange 事件', {}, video));
  };
  const bind = () => document.querySelectorAll('video').forEach(attach);
  const discoverFromControl = (event) => {
    const video = videoFromEvent(event);
    if (!video || !isPlaybackGesture(event, video)) return;
    trace(`用户触发网页 ${event.type} 操作`, {
      clientX: event.clientX,
      clientY: event.clientY,
      button: event.button,
    }, video, event.target);
    attach(video);
    if (isLikelyAdvertisement(video)) return;
    arm(video);
    // Do not consume the tap here. Many sites create or select the main media
    // source from their own click handler; play/fullscreen interception below
    // performs the handoff only after that handler has run.
  };
  const patchedPlay = function() {
    const video = this instanceof HTMLVideoElement ? this : null;
    if (video) trace('网页调用 video.play()', {}, video);
    if (video && reportVideo(video)) {
      return Promise.resolve();
    }
    return originalPlay.apply(this, arguments);
  };
  const patchedRequestFullscreen = function() {
    const video = this instanceof HTMLVideoElement ? this : selectedVideo;
    trace('网页调用 requestFullscreen()', {}, video);
    if (video && reportVideo(video)) {
      return Promise.resolve();
    }
    return originalRequestFullscreen ? originalRequestFullscreen.apply(this, arguments) : Promise.resolve();
  };
  const patchedVideoFullscreen = function() {
    trace('网页调用 webkitEnterFullscreen()', {}, this);
    if (reportVideo(this)) return Promise.resolve();
    return originalVideoFullscreen ? originalVideoFullscreen.apply(this, arguments) : Promise.resolve();
  };
  ['pointerdown', 'touchstart', 'click'].forEach((eventName) => {
    document.addEventListener(eventName, (event) => {
      trace(`网页 ${eventName} 事件`, {
        clientX: event.clientX,
        clientY: event.clientY,
        button: event.button,
      }, null, event.target);
    }, true);
  });
  try {
    HTMLMediaElement.prototype.play = patchedPlay;
    Element.prototype.requestFullscreen = patchedRequestFullscreen;
    HTMLVideoElement.prototype.webkitEnterFullscreen = patchedVideoFullscreen;
  } catch (_) {
    // Some protected pages expose read-only media prototypes.
  }
  document.addEventListener('fullscreenchange', () => {
    const video = selectedVideo;
    trace('网页触发 fullscreenchange 事件', {
      fullscreen: Boolean(document.fullscreenElement),
    }, video);
    if (document.fullscreenElement && video && reportVideo(video)) {
      if (document.exitFullscreen) document.exitFullscreen().catch(() => {});
    }
  }, true);
  document.addEventListener('webkitbeginfullscreen', (event) => {
    const video = event.target instanceof HTMLVideoElement ? event.target : selectedVideo;
    trace('网页触发 webkitbeginfullscreen 事件', {}, video);
    if (video && reportVideo(video)) {
      event.preventDefault();
      if (video) video.pause();
    }
  }, true);
  let started = false;
  const start = () => {
    if (started) {
      bind();
      return;
    }
    started = true;
    trace('媒体桥接已启动');
    bind();
    new MutationObserver(bind).observe(document, {childList: true, subtree: true});
    ['pointerdown', 'touchstart', 'click'].forEach((eventName) => {
      document.addEventListener(eventName, discoverFromControl, true);
    });
  };
  window.__aiVideoPlayerMediaBridgeInstalled = {start};
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, {once: true});
  } else {
    start();
  }
})();
''';
