import '../player/browser_media_handoff.dart';

enum BrowserLoadStatus { idle, loading, loaded, error }

class BrowserPageState {
  const BrowserPageState({
    required this.sessionId,
    this.url,
    this.title = '',
    this.canGoBack = false,
    this.canGoForward = false,
    this.progress = 0,
    this.status = BrowserLoadStatus.idle,
    this.message,
  });

  final String sessionId;
  final Uri? url;
  final String title;
  final bool canGoBack;
  final bool canGoForward;
  final int progress;
  final BrowserLoadStatus status;
  final String? message;

  BrowserPageState copyWith({
    Uri? url,
    String? title,
    bool? canGoBack,
    bool? canGoForward,
    int? progress,
    BrowserLoadStatus? status,
    String? message,
    bool clearMessage = false,
  }) =>
      BrowserPageState(
        sessionId: sessionId,
        url: url ?? this.url,
        title: title ?? this.title,
        canGoBack: canGoBack ?? this.canGoBack,
        canGoForward: canGoForward ?? this.canGoForward,
        progress: progress ?? this.progress,
        status: status ?? this.status,
        message: clearMessage ? null : message ?? this.message,
      );
}

sealed class BrowserEvent {
  const BrowserEvent();
}

class BrowserMediaDetected extends BrowserEvent {
  const BrowserMediaDetected(this.handoff);

  final BrowserMediaHandoff handoff;
}

class BrowserUnsupportedMedia extends BrowserEvent {
  const BrowserUnsupportedMedia({
    required this.page,
    required this.reason,
  });

  final Uri page;
  final String reason;
}
