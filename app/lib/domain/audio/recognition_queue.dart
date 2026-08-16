import 'dart:async';
import 'dart:collection';

import 'audio_models.dart';

class RecognitionQueue {
  RecognitionQueue({this.maxWaiting = 1}) {
    if (maxWaiting < 1) throw ArgumentError.value(maxWaiting, 'maxWaiting');
  }

  final int maxWaiting;
  final Queue<RecognitionWindow> _waiting = Queue<RecognitionWindow>();
  RecognitionWindow? _active;
  bool _closed = false;
  Completer<void>? _available;

  int get depth => _waiting.length + (_active == null ? 0 : 1);
  bool get isFull => depth >= maxWaiting + 1;
  RecognitionWindow? get active => _active;
  List<RecognitionWindow> get waiting => List.unmodifiable(_waiting);

  RecognitionWindow? takeNow() {
    if (_closed || _active != null || _waiting.isEmpty) return null;
    _active = _waiting.removeFirst();
    return _active;
  }

  bool offer(RecognitionWindow window) {
    if (_closed || isFull) return false;
    _waiting.addLast(window);
    _wake();
    return true;
  }

  Future<RecognitionWindow?> take() async {
    while (!_closed) {
      final next = takeNow();
      if (next != null) return next;
      _available ??= Completer<void>();
      await _available!.future;
    }
    return null;
  }

  void complete(RecognitionWindow window) {
    if (identical(_active, window)) _active = null;
    _wake();
  }

  List<RecognitionWindow> clear() {
    final removed = <RecognitionWindow>[..._waiting];
    _waiting.clear();
    _wake();
    return removed;
  }

  void close() {
    _closed = true;
    _waiting.clear();
    _active = null;
    _wake();
  }

  void _wake() {
    final completer = _available;
    _available = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}
