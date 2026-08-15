import 'package:file_selector/file_selector.dart';

import '../../domain/player/player_service.dart';

abstract interface class MediaPicker {
  Future<MediaSource?> pickLocalVideo();
}

class FileSelectorMediaPicker implements MediaPicker {
  @override
  Future<MediaSource?> pickLocalVideo() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '视频文件',
          extensions: ['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v'],
        ),
      ],
    );
    if (file == null) return null;

    return MediaSource.localFile(path: file.path, title: file.name);
  }
}
