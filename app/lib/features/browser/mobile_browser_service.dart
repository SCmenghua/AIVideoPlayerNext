import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../domain/browser/browser_models.dart';
import 'browser_service_base.dart';

class MobileBrowserService extends BrowserServiceBase {
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
    updateState(status: BrowserLoadStatus.idle);
    await _installEarlyMediaBridge();
  }

  void _handleJavaScriptMessage(JavaScriptMessage message) {
    final page = currentState.url;
    if (page == null) return;
    try {
      final payload = jsonDecode(message.message) as Map<String, dynamic>;
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
    } catch (_) {
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
    if (handleCandidate(candidate: url, originPage: currentState.url ?? url)) {
      return;
    }
    await controller.loadRequest(url);
  }

  @override
  Future<void> goBack() async {
    if (_initialized && await controller.canGoBack()) {
      await controller.goBack();
      await _updateHistory();
    }
  }

  @override
  Future<void> goForward() async {
    if (_initialized && await controller.canGoForward()) {
      await controller.goForward();
      await _updateHistory();
    }
  }

  @override
  Future<void> reload() async {
    if (_initialized) await controller.reload();
  }

  @override
  Future<void> stop() async {
    if (_initialized) await controller.runJavaScript('window.stop();');
  }
}

const _mobileMediaBridgeScript = r'''
(() => {
  if (window.__aiVideoPlayerMediaBridgeInstalled) {
    window.__aiVideoPlayerMediaBridgeInstalled.start();
    return;
  }

  const post = (payload) => window.AIVideoPlayerMedia?.postMessage(JSON.stringify(payload));
  const emitted = new Set();
  const originalPlay = HTMLMediaElement.prototype.play;
  const originalRequestFullscreen = Element.prototype.requestFullscreen;
  const originalVideoFullscreen = HTMLVideoElement.prototype.webkitEnterFullscreen;
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
  const visibleVideo = () => Array.from(document.querySelectorAll('video')).find((video) => {
    const rect = video.getBoundingClientRect();
    const style = window.getComputedStyle(video);
    return rect.width > 1 && rect.height > 1 && style.display !== 'none' && style.visibility !== 'hidden';
  }) || document.querySelector('video');
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

  const attach = (video) => {
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    video.playsInline = true;
    if (video.dataset.aiVideoPlayerBound) return;
    video.dataset.aiVideoPlayerBound = '1';

    const report = () => {
      const source = sourceOf(video);
      if (isHttpMedia(source)) {
        video.pause();
        if (!emitted.has(source)) {
          emitted.add(source);
          post({kind: 'media', url: source, title: document.title, videoElement: true});
        }
        return true;
      }
      if (isBrowserOnlySource(source) && !emitted.has(source)) {
        emitted.add(source);
        post({kind: 'unsupported'});
      }
      return false;
    };
    const interceptKnownSource = (event) => {
      if (!report()) return;
      event.preventDefault();
      event.stopImmediatePropagation();
    };
    const discoverAfterPageStartsPlayback = () => {
      [0, 80, 260, 800].forEach((delay) => setTimeout(report, delay));
    };
    video.addEventListener('pointerdown', interceptKnownSource, true);
    video.addEventListener('touchstart', interceptKnownSource, true);
    video.addEventListener('click', interceptKnownSource, true);
    video.addEventListener('play', () => {
      report();
    }, true);
    ['loadstart', 'loadedmetadata', 'canplay', 'playing'].forEach((eventName) => {
      video.addEventListener(eventName, report, true);
    });
    video.addEventListener('pointerdown', discoverAfterPageStartsPlayback, true);
    video.addEventListener('touchstart', discoverAfterPageStartsPlayback, true);
    video.addEventListener('click', discoverAfterPageStartsPlayback, true);
  };
  const bind = () => document.querySelectorAll('video').forEach(attach);
  const discoverFromControl = (event) => {
    const path = event.composedPath ? event.composedPath() : [];
    const video = path.find((node) => node && node.tagName === 'VIDEO') || visibleVideo();
    if (!video || !isPlaybackGesture(event, video)) return;
    attach(video);
    if (reportVideo(video)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    [0, 80, 260, 800].forEach((delay) => setTimeout(() => reportVideo(video), delay));
  };
  const reportVideo = (video) => {
    const source = sourceOf(video);
    if (!isHttpMedia(source)) {
      if (isBrowserOnlySource(source) && !emitted.has(source)) {
        emitted.add(source);
        post({kind: 'unsupported'});
      }
      return false;
    }
    video.pause();
    if (!emitted.has(source)) {
      emitted.add(source);
      post({kind: 'media', url: source, title: document.title, videoElement: true});
    }
    return true;
  };
  const handoffOrBlockFullscreen = (video) => {
    if (!video) return false;
    const source = sourceOf(video);
    if (isHttpMedia(source)) {
      reportVideo(video);
      return true;
    }
    if (isBrowserOnlySource(source)) {
      if (!emitted.has(source)) {
        emitted.add(source);
        post({kind: 'unsupported'});
      }
      return true;
    }
    return false;
  };
  const patchedPlay = function() {
    const video = this instanceof HTMLVideoElement ? this : visibleVideo();
    if (video && handoffOrBlockFullscreen(video)) {
      return Promise.resolve();
    }
    return originalPlay.apply(this, arguments);
  };
  const patchedRequestFullscreen = function() {
    const video = this instanceof HTMLVideoElement ? this : visibleVideo();
    if (video && handoffOrBlockFullscreen(video)) {
      return Promise.resolve();
    }
    return originalRequestFullscreen ? originalRequestFullscreen.apply(this, arguments) : Promise.resolve();
  };
  const patchedVideoFullscreen = function() {
    if (handoffOrBlockFullscreen(this)) return Promise.resolve();
    return originalVideoFullscreen ? originalVideoFullscreen.apply(this, arguments) : Promise.resolve();
  };
  try {
    HTMLMediaElement.prototype.play = patchedPlay;
    Element.prototype.requestFullscreen = patchedRequestFullscreen;
    HTMLVideoElement.prototype.webkitEnterFullscreen = patchedVideoFullscreen;
  } catch (_) {
    // Some protected pages expose read-only media prototypes.
  }
  document.addEventListener('fullscreenchange', () => {
    const video = visibleVideo();
    if (document.fullscreenElement && video) {
      handoffOrBlockFullscreen(video);
      if (document.exitFullscreen) document.exitFullscreen().catch(() => {});
    }
  }, true);
  document.addEventListener('webkitbeginfullscreen', (event) => {
    const video = event.target instanceof HTMLVideoElement ? event.target : visibleVideo();
    if (handoffOrBlockFullscreen(video)) {
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
