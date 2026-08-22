import Flutter
import UIKit
import WebKit
import webview_flutter_wkwebview

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audioBridge = IOSAudioDecoderBridge()
  private let systemTranslationBridge = SystemTranslationBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "ai_video_player/ios_webview",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "installUserScript",
            let arguments = call.arguments as? [String: Any],
            let identifier = arguments["identifier"] as? Int,
            let source = arguments["source"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }

      guard let webView = FWFWebViewFlutterWKWebViewExternalAPI.webView(
        forIdentifier: Int64(identifier),
        withPluginRegistry: engineBridge.pluginRegistry
      ) else {
        result(FlutterError(
          code: "WEBVIEW_NOT_FOUND",
          message: "无法找到内置浏览器页面。",
          details: nil
        ))
        return
      }

      let userScript = WKUserScript(
        source: source,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
      )
      webView.configuration.userContentController.addUserScript(userScript)
      result(nil)
    }

    audioBridge.register(with: engineBridge.applicationRegistrar)
    systemTranslationBridge.register(with: engineBridge.applicationRegistrar)

    let speechChannel = FlutterMethodChannel(
      name: "ai_video_player/ios_speech_core",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    speechChannel.setMethodCallHandler { call, result in
      if call.method == "installModel" {
        guard let typedData = call.arguments as? FlutterStandardTypedData else {
          result(FlutterError(code: "MODEL_DATA", message: "模型数据无效。", details: nil))
          return
        }
        do {
          let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
          ).first!.appendingPathComponent("models", isDirectory: true)
          try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
          )
          let model = directory.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
          try typedData.data.write(to: model, options: .atomic)
          result(model.path)
        } catch {
          result(FlutterError(code: "MODEL_WRITE", message: "无法安装 Whisper 模型。", details: error.localizedDescription))
        }
        return
      }
      guard call.method == "modelPath" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let directory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first!.appendingPathComponent("models", isDirectory: true)
      let model = directory.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
      if FileManager.default.fileExists(atPath: model.path) {
        result(model.path)
        return
      }
      result(Bundle.main.path(forResource: "ggml-large-v3-turbo-q5_0", ofType: "bin"))
    }
  }
}
