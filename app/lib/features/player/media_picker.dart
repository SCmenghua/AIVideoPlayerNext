import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

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
          uniformTypeIdentifiers: ['public.movie'],
        ),
      ],
    );
    if (file == null) return null;

    final path = Platform.isIOS ? await _copyForIosPlayback(file) : file.path;
    return MediaSource.localFile(path: path, title: file.name);
  }

  Future<String> _copyForIosPlayback(XFile file) async {
    final support = await getApplicationSupportDirectory();
    final directory =
        Directory('${support.path}${Platform.pathSeparator}media');
    await directory.create(recursive: true);
    final safeName = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final target = File(
      '${directory.path}${Platform.pathSeparator}'
      '${DateTime.now().microsecondsSinceEpoch}_${safeName.isEmpty ? 'video' : safeName}',
    );
    await file.saveTo(target.path);
    return target.path;
  }
}
