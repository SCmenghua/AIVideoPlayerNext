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
  const originalPlay = HTMLMediaElement.prototype.play;
  const originalRequestFullscreen = Element.prototype.requestFullscreen;
  const originalVideoFullscreen = HTMLVideoElement.prototype.webkitEnterFullscreen;
  let selectedVideo = null;
  let selectionExpiresAt = 0;
  let selectionSerial = 0;
  let lastHandoff = '';
  let lastHandoffAt = 0;
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
    const serial = selectionSerial;
    // Keep the intent while a short pre-roll finishes and the page swaps in its content source.
    selectionExpiresAt = Date.now() + 120000;
    // Some sites create the video source only after their click handler returns.
    // Retry against the selected element and any replacement element so the
    // first tap does not merely start playback inside the web view.
    [40, 120, 250, 500, 900, 1500, 2500, 4000].forEach((delay) => {
      setTimeout(() => {
        if (serial !== selectionSerial || Date.now() >= selectionExpiresAt) return;
        const candidate = selectedVideo?.isConnected ? selectedVideo : primaryVideo();
        if (!candidate) return;
        attach(candidate);
        reportVideo(candidate);
      }, delay);
    });
  };
  const hasIntentFor = (video) => selectedVideo === video && Date.now() < selectionExpiresAt;
  const emitMedia = (source) => {
    if (source === lastHandoff && Date.now() - lastHandoffAt < 1500) return;
    lastHandoff = source;
    lastHandoffAt = Date.now();
    post({kind: 'media', url: source, title: document.title, videoElement: true});
  };
  const emitUnsupported = () => post({kind: 'unsupported'});
  const reportVideo = (video) => {
    if (!hasIntentFor(video) || isLikelyAdvertisement(video)) return false;
    const source = sourceOf(video);
    // A page can reuse one video element for a pre-roll and its main content.
    // Leave identifiable ad sources in the inline web view and wait for the next source.
    if (isLikelyAdvertisementSource(source)) return false;
    if (isHttpMedia(source)) {
      video.pause();
      emitMedia(source);
      return true;
    }
    if (isBrowserOnlySource(source)) emitUnsupported();
    return false;
  };

  const attach = (video) => {
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    video.playsInline = true;
    if (video.dataset.aiVideoPlayerBound) return;
    video.dataset.aiVideoPlayerBound = '1';
    video.addEventListener('play', () => {
      // Autoplaying advertisements have no user-selected video and are ignored.
      reportVideo(video);
    }, true);
    video.addEventListener('loadedmetadata', () => {
      reportVideo(video);
    }, true);
  };
  const bind = () => document.querySelectorAll('video').forEach(attach);
  const discoverFromControl = (event) => {
    const video = videoFromEvent(event);
    if (!video || !isPlaybackGesture(event, video)) return;
    attach(video);
    if (isLikelyAdvertisement(video)) return;
    arm(video);
    // Do not consume the tap here. Many sites create or select the main media
    // source from their own click handler; play/fullscreen interception below
    // performs the handoff only after that handler has run.
  };
  const patchedPlay = function() {
    const video = this instanceof HTMLVideoElement ? this : null;
    if (video && reportVideo(video)) {
      return Promise.resolve();
    }
    return originalPlay.apply(this, arguments);
  };
  const patchedRequestFullscreen = function() {
    const video = this instanceof HTMLVideoElement ? this : selectedVideo;
    if (video && reportVideo(video)) {
      return Promise.resolve();
    }
    return originalRequestFullscreen ? originalRequestFullscreen.apply(this, arguments) : Promise.resolve();
  };
  const patchedVideoFullscreen = function() {
    if (reportVideo(this)) return Promise.resolve();
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
    const video = selectedVideo;
    if (document.fullscreenElement && video && reportVideo(video)) {
      if (document.exitFullscreen) document.exitFullscreen().catch(() => {});
    }
  }, true);
  document.addEventListener('webkitbeginfullscreen', (event) => {
    const video = event.target instanceof HTMLVideoElement ? event.target : selectedVideo;
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
