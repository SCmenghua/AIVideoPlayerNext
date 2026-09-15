import 'package:file_selector/file_selector.dart';

import 'recognition_service.dart';
import 'whisper_model_catalog.dart';
import 'whisper_model_store.dart';

/// Lets the user pick a model file downloaded by other means and installs it.
/// Returns a message for the UI; null when the picker was cancelled.
Future<String?> pickAndImportModel(
  RecognitionService service, {
  WhisperModelSpec? expected,
}) async {
  final file = await openFile(
    acceptedTypeGroups: const [XTypeGroup(label: 'GGML 模型', extensions: ['bin'])],
    confirmButtonText: '导入',
  );
  if (file == null) return null;
  final name = file.name;
  WhisperModelSpec? spec = expected;
  if (spec == null) {
    for (final candidate in WhisperModelCatalog.all) {
      if (candidate.fileName == name) spec = candidate;
    }
  }
  if (spec == null) {
    return '无法识别 $name：文件名需与模型清单一致（如 ${WhisperModelCatalog.kotobaV2.fileName}）。';
  }
  try {
    await service.importModel(spec, file.path);
    return '已导入 ${spec.fileName}。';
  } on ModelInstallException catch (error) {
    return '导入失败：${error.message}';
  } on Object catch (error) {
    return '导入失败：$error';
  }
}
