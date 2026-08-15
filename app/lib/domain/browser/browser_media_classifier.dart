import '../player/browser_media_handoff.dart';

enum BrowserMediaDisposition { handoff, unsupported, ignore }

class BrowserMediaDecision {
  const BrowserMediaDecision._({
    required this.disposition,
    this.handoff,
    this.reason,
  });

  const BrowserMediaDecision.handoff(BrowserMediaHandoff handoff)
      : this._(
          disposition: BrowserMediaDisposition.handoff,
          handoff: handoff,
        );

  const BrowserMediaDecision.unsupported(String reason)
      : this._(
          disposition: BrowserMediaDisposition.unsupported,
          reason: reason,
        );

  const BrowserMediaDecision.ignore()
      : this._(disposition: BrowserMediaDisposition.ignore);

  final BrowserMediaDisposition disposition;
  final BrowserMediaHandoff? handoff;
  final String? reason;
}

/// Classifies URLs observed in a browser without extracting protected media.
class BrowserMediaClassifier {
  const BrowserMediaClassifier();

  BrowserMediaDecision classify({
    required Uri candidate,
    required Uri originPage,
    required String browserSessionId,
    required String title,
    bool isVideoElementSource = false,
    Map<String, String> requestHeaders = const {},
  }) {
    final scheme = candidate.scheme.toLowerCase();
    if (scheme == 'blob' || scheme == 'mediasource') {
      return const BrowserMediaDecision.unsupported(
        '该视频使用浏览器媒体流，无法由内置播放器接管。',
      );
    }
    if (scheme != 'http' && scheme != 'https') {
      return const BrowserMediaDecision.ignore();
    }

    final path = candidate.path.toLowerCase();
    if (isVideoElementSource ||
        path.endsWith('.mp4') ||
        path.endsWith('.m4v') ||
        path.endsWith('.mov') ||
        path.endsWith('.webm') ||
        path.endsWith('.mkv') ||
        path.endsWith('.m3u8')) {
      return BrowserMediaDecision.handoff(BrowserMediaHandoff(
        mediaUri: candidate,
        title: title.isEmpty ? '网页视频' : title,
        originPage: originPage,
        browserSessionId: browserSessionId,
        requestHeaders: requestHeaders,
      ));
    }
    return const BrowserMediaDecision.ignore();
  }
}
