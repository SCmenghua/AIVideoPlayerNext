import Flutter
import Foundation

#if canImport(Translation)
import Translation
#endif

/// Apple Translation framework bridge for subtitle translation.
///
/// The Translation session runs on-device once the system language packs are
/// downloaded (the system shows its own consent sheet through
/// prepareTranslation). Dart only ever passes subtitle text, language codes
/// and a request ID; media URLs, cookies and other handoff context can never
/// enter this channel.
final class SystemTranslationBridge: NSObject {
  private let translator = SystemTranslator()

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
        result(self.translator.availability())
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
  case languagePair(source: String, target: String)
  case prepareFailed(String)
  case sessionFailed(String)

  var code: String {
    switch self {
    case .unsupportedOS: return "UNSUPPORTED_OS"
    case .languagePair: return "LANGUAGE"
    case .prepareFailed: return "PREPARE"
    case .sessionFailed: return "SESSION"
    }
  }

  var message: String {
    switch self {
    case .unsupportedOS:
      return "系统翻译需要 iOS 18.2 或更高版本。"
    case .languagePair(let source, let target):
      return "系统翻译不支持 \(source) 到 \(target) 的语言组合。"
    case .prepareFailed(let reason):
      return "系统翻译语言包尚未就绪：\(reason)"
    case .sessionFailed(let reason):
      return "系统翻译会话失败：\(reason)"
    }
  }
}

/// Serializes TranslationSession access. Concurrent Dart requests each get
/// their own reply; the actor keeps a cached session per language pair so the
/// per-session setup cost is paid once.
///
/// The programmatic session factory is the Translation framework's global
/// `session(configuration:)` function introduced in iOS 18.2; iOS 18.0 only
/// exposed sessions through SwiftUI's translationTask modifier.
private actor SystemTranslator {
  private struct SessionKey: Hashable {
    let source: String
    let target: String
  }

  private var cachedSession: AnyObject?
  private var cachedKey: SessionKey?

  func availability() -> [String: Any] {
    if #available(iOS 18.2, *) {
      return ["available": true]
    }
    return [
      "available": false,
      "message": TranslationBridgeError.unsupportedOS.message,
    ]
  }

  func translate(text: String, sourceLanguage: String, targetLanguage: String) async throws -> String {
    guard #available(iOS 18.2, *) else {
      throw TranslationBridgeError.unsupportedOS
    }
    #if canImport(Translation)
    let source = Self.normalize(sourceLanguage)
    let target = Self.normalize(targetLanguage)
    do {
      let session = try await openSession(source: source, target: target)
      do {
        let response = try await session.translate(text)
        return response.targetText
      } catch {
        // The language pair may need on-demand assets; ask the system to
        // prepare them (this shows the system download sheet once) and retry
        // the single segment once.
        cachedSession = nil
        cachedKey = nil
        let fresh = try await openSession(source: source, target: target)
        try await fresh.prepareTranslation()
        let response = try await fresh.translate(text)
        return response.targetText
      }
    } catch let error as TranslationBridgeError {
      throw error
    } catch {
      throw TranslationBridgeError.sessionFailed(error.localizedDescription)
    }
    #else
    throw TranslationBridgeError.unsupportedOS
    #endif
  }

  #if canImport(Translation)
  @available(iOS 18.2, *)
  private func openSession(source: String, target: String) async throws -> TranslationSession {
    let key = SessionKey(source: source, target: target)
    if cachedKey == key, let cached = cachedSession as? TranslationSession {
      return cached
    }
    let configuration = TranslationSession.Configuration(
      source: Locale.Language(identifier: source),
      target: Locale.Language(identifier: target)
    )
    do {
      let session = try await session(configuration: configuration)
      cachedKey = key
      cachedSession = session
      return session
    } catch {
      throw TranslationBridgeError.sessionFailed(error.localizedDescription)
    }
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
