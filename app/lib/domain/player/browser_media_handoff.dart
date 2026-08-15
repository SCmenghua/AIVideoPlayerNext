import 'dart:collection';

import 'player_service.dart';

/// Transient media data received from the in-app browser.
///
/// Browser cookies and request headers remain in memory only and must not be
/// persisted or written to logs.
class BrowserMediaHandoff {
  BrowserMediaHandoff({
    required this.mediaUri,
    required this.title,
    required this.originPage,
    required this.browserSessionId,
    Map<String, String> requestHeaders = const {},
  }) : requestHeaders = UnmodifiableMapView(Map.of(requestHeaders));

  final Uri mediaUri;
  final String title;
  final Uri originPage;
  final String browserSessionId;
  final Map<String, String> requestHeaders;

  MediaSource toMediaSource() => MediaSource(
        uri: mediaUri,
        title: title,
        kind: MediaSourceKind.browserHandoff,
        originPage: originPage,
        requestHeaders: requestHeaders,
        browserSessionId: browserSessionId,
      );
}
