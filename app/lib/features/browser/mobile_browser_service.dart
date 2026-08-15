import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
    if (/play|播放/.test(label)) return true;
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
