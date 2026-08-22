import Flutter
import Foundation

#if canImport(Translation)
import Translation
#endif

/// Apple Translation framework bridge for subtitle translation.
///
/// The Translation session runs on-device once the system language packs are
/// downloaded (headless sessions cannot trigger the system download sheet,
/// so the languages must be installed in system settings beforehand). Dart
/// only ever passes subtitle text, language codes and a request ID; media
/// URLs, cookies and other handoff context can never enter this channel.
final class SystemTranslationBridge: NSObject {
  private let translator = SystemTranslator()

  private static func availabilityReply() -> [String: Any] {
    if #available(iOS 26.0, *) {
      return ["available": true]
    }
    return [
      "available": false,
      "message": TranslationBridgeError.unsupportedOS.message,
    ]
  }

  func register(with registrar: FlutterApplicationRegistrar) {
    let channel = FlutterMethodChannel(
      name: "ai_video_player/system_translation",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "DISPOSED", message: "系统翻译桥接已释放", details: nil))
        return
      }
      switch call.method {
      case "availability":
        // Pure OS-version check answered inline: it must never depend on
        // actor scheduling, otherwise the Dart-side probe could hang.
        result(Self.availabilityReply())
      case "translate":
        guard let args = call.arguments as? [String: Any],
              let requestID = args["requestId"] as? String,
              let text = args["text"] as? String,
              let sourceLanguage = args["sourceLanguage"] as? String,
              let targetLanguage = args["targetLanguage"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "系统翻译参数不完整", details: nil))
          return
        }
        Task {
          do {
            let translated = try await self.translator.translate(
              text: text,
              sourceLanguage: sourceLanguage,
              targetLanguage: targetLanguage
            )
            result(["requestId": requestID, "text": translated])
          } catch let error as TranslationBridgeError {
            result(FlutterError(code: error.code, message: error.message, details: nil))
          } catch {
            result(FlutterError(
              code: "TRANSLATION",
              message: error.localizedDescription,
              details: nil
            ))
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

private enum TranslationBridgeError: Error {
  case unsupportedOS
  case languagePackMissing(source: String, target: String)
  case sessionFailed(String)

  var code: String {
    switch self {
    case .unsupportedOS: return "UNSUPPORTED_OS"
    case .languagePackMissing: return "PREPARE"
    case .sessionFailed: return "SESSION"
    }
  }

  var message: String {
    switch self {
    case .unsupportedOS:
      return "系统翻译需要 iOS 26 或更高版本。"
    case .languagePackMissing(let source, let target):
      return "系统翻译缺少 \(source) → \(target) 语言包，请在系统设置 › 通用 › 翻译 中下载后重试。"
    case .sessionFailed(let reason):
      return "系统翻译会话失败：\(reason)"
    }
  }
}

/// Serializes TranslationSession access. Concurrent Dart requests each get
/// their own reply; the actor keeps a cached session per language pair so the
/// per-session setup cost is paid once.
///
/// Sessions are created with the headless `init(installedSource:target:)`
/// initializer (iOS 26+). It only accepts language pairs that are already
/// downloaded; the download-consent flow belongs to SwiftUI's translationTask,
/// which a background bridge cannot present, so missing language packs have
/// to be downloaded in system settings first and surface as errors here.
private actor SystemTranslator {
  private struct SessionKey: Hashable {
    let source: String
    let target: String
  }

  private var cachedSession: AnyObject?
  private var cachedKey: SessionKey?

  func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String {
    guard #available(iOS 26.0, *) else {
      throw TranslationBridgeError.unsupportedOS
    }
    #if canImport(Translation)
    let source = Self.normalize(sourceLanguage)
    let target = Self.normalize(targetLanguage)
    let session = openSession(source: source, target: target)
    do {
      let response = try await session.translate(text)
      return response.targetText
    } catch {
      // Drop the failed session; the next request rebuilds it. A session
      // that is not ready means the language pair is not installed: a
      // headless session cannot present the system download sheet, and
      // prepareTranslation would never complete, so surface a terminal
      // error instead of hanging or retrying. Anything else is a session
      // error the caller may retry.
      cachedSession = nil
      cachedKey = nil
      // isReady is an asynchronous property in this SDK.
      let sessionIsReady = await session.isReady
      if !sessionIsReady {
        throw TranslationBridgeError.languagePackMissing(source: source, target: target)
      }
      throw TranslationBridgeError.sessionFailed(error.localizedDescription)
    }
    #else
    throw TranslationBridgeError.unsupportedOS
    #endif
  }

  #if canImport(Translation)
  @available(iOS 26.0, *)
  private func openSession(source: String, target: String) -> TranslationSession {
    let key = SessionKey(source: source, target: target)
    if cachedKey == key, let cached = cachedSession as? TranslationSession {
      return cached
    }
    let session = TranslationSession(
      installedSource: Locale.Language(identifier: source),
      target: Locale.Language(identifier: target)
    )
    cachedKey = key
    cachedSession = session
    return session
  }
  #endif

  /// Apple lists Simplified Chinese as zh-Hans; subtitle pipelines commonly
  /// carry zh-CN. Everything else is passed through as BCP-47.
  private static func normalize(_ language: String) -> String {
    let trimmed = language.trimmingCharacters(in: .whitespaces)
    if trimmed == "zh-CN" || trimmed == "zh" || trimmed == "zh-SG" {
      return "zh-Hans"
    }
    return trimmed
  }
}
