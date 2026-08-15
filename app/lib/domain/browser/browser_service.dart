import 'browser_models.dart';

abstract interface class BrowserService {
  BrowserPageState get currentState;
  Stream<BrowserPageState> get states;
  Stream<BrowserEvent> get events;

  Future<void> initialize();
  Future<void> load(Uri url);
  Future<void> goBack();
  Future<void> goForward();
  Future<void> reload();
  Future<void> stop();
  Future<void> dispose();
}
