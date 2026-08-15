import 'dart:async';

import '../../domain/browser/browser_media_classifier.dart';
import '../../domain/browser/browser_models.dart';
import '../../domain/browser/browser_service.dart';

abstract class BrowserServiceBase implements BrowserService {
  BrowserServiceBase({BrowserMediaClassifier? classifier})
      : _classifier = classifier ?? const BrowserMediaClassifier(),
        _state = BrowserPageState(
          sessionId: 'browser-${DateTime.now().microsecondsSinceEpoch}',
        );

  final BrowserMediaClassifier _classifier;
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
        eventController.add(BrowserMediaDetected(decision.handoff!));
        return true;
      case BrowserMediaDisposition.unsupported:
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
