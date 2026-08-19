import 'dart:async';

import '../../core/diagnostics/diagnostic_log_service.dart';
import '../../domain/browser/browser_media_classifier.dart';
import '../../domain/browser/browser_models.dart';
import '../../domain/browser/browser_service.dart';

abstract class BrowserServiceBase implements BrowserService {
  BrowserServiceBase({
    BrowserMediaClassifier? classifier,
    this.logs,
  })  : _classifier = classifier ?? const BrowserMediaClassifier(),
        _state = BrowserPageState(
          sessionId: 'browser-${DateTime.now().microsecondsSinceEpoch}',
        );

  final BrowserMediaClassifier _classifier;
  final DiagnosticLogService? logs;
  final StreamController<BrowserPageState> stateController =
      StreamController.broadcast();
  final StreamController<BrowserEvent> eventController =
      StreamController.broadcast();
  BrowserPageState _state;
  bool isDisposed = false;

  @override
  BrowserPageState get currentState => _state;

  @override
  Stream<BrowserPageState> get states => stateController.stream;

  @override
  Stream<BrowserEvent> get events => eventController.stream;

  void emitState(BrowserPageState state) {
    if (isDisposed) return;
    _state = state;
    stateController.add(state);
  }

  void updateState({
    Uri? url,
    String? title,
    bool? canGoBack,
    bool? canGoForward,
    int? progress,
    BrowserLoadStatus? status,
    String? message,
    bool clearMessage = false,
  }) {
    emitState(_state.copyWith(
      url: url,
      title: title,
      canGoBack: canGoBack,
      canGoForward: canGoForward,
      progress: progress,
      status: status,
      message: message,
      clearMessage: clearMessage,
    ));
  }

  bool handleCandidate({
    required Uri candidate,
    required Uri originPage,
    String? title,
    bool isVideoElementSource = false,
  }) {
    final decision = _classifier.classify(
      candidate: candidate,
      originPage: originPage,
      browserSessionId: _state.sessionId,
      title: title ?? _state.title,
      isVideoElementSource: isVideoElementSource,
      requestHeaders: {'Referer': originPage.toString()},
    );
    switch (decision.disposition) {
      case BrowserMediaDisposition.handoff:
        logs?.info('浏览器媒体', '媒体分类为可交接', {
          '候选地址': candidate,
          '来源页面': originPage,
          '媒体标题': title ?? _state.title,
          '来源类型': isVideoElementSource ? '网页 video 元素' : '导航地址',
        });
        eventController.add(BrowserMediaDetected(decision.handoff!));
        return true;
      case BrowserMediaDisposition.unsupported:
        logs?.warning('浏览器媒体', '媒体无法交接', {
          '候选地址': candidate,
          '来源页面': originPage,
          '原因': decision.reason,
        });
        eventController.add(BrowserUnsupportedMedia(
          page: originPage,
          reason: decision.reason!,
        ));
        return true;
      case BrowserMediaDisposition.ignore:
        return false;
    }
  }

  void emitUnsupported({required Uri page, required String reason}) {
    if (!isDisposed) {
      logs?.warning('浏览器媒体', '网页报告不支持媒体', {
        '来源页面': page,
        '原因': reason,
      });
      eventController.add(BrowserUnsupportedMedia(page: page, reason: reason));
    }
  }

  @override
  Future<void> dispose() async {
    if (isDisposed) return;
    isDisposed = true;
    await stateController.close();
    await eventController.close();
  }
}
