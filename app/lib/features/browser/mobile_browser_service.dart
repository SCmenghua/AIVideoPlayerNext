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
          final page = currentState.url;
          if (url != null &&
              page != null &&
              handleCandidate(candidate: url, originPage: page)) {
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
    await controller.runJavaScript(_mobileMediaBridgeScript);
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
  const post = (payload) => window.AIVideoPlayerMedia?.postMessage(JSON.stringify(payload));
  const sourceOf = (video) => video.currentSrc || video.src || video.querySelector('source[src]')?.src;
  const isHttpMedia = (source) => /^https?:/i.test(source || '');
  const attach = (video) => {
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    video.playsInline = true;
    if (video.dataset.aiVideoPlayerBound) return;
    video.dataset.aiVideoPlayerBound = '1';
    let handoffRequested = false;
    let unsupportedReported = false;
    const intercept = (event) => {
      const source = sourceOf(video);
      if (isHttpMedia(source)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        video.pause();
        if (!handoffRequested) {
          handoffRequested = true;
          post({kind: 'media', url: source, title: document.title, videoElement: true});
        }
      } else if (!unsupportedReported) {
        unsupportedReported = true;
        post({kind: 'unsupported'});
      }
    };
    video.addEventListener('pointerdown', intercept, true);
    video.addEventListener('click', intercept, true);
    video.addEventListener('play', intercept, true);
  };
  const bind = () => document.querySelectorAll('video').forEach(attach);
  const start = () => {
    bind();
    new MutationObserver(bind).observe(document, {childList: true, subtree: true});
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, {once: true});
  } else {
    start();
  }
})();
''';
