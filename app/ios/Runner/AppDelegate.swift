import Flutter
import UIKit
import WebKit
import webview_flutter_wkwebview

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
  }
}
