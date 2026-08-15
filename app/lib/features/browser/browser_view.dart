import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart';

import 'mobile_browser_service.dart';
import 'windows_browser_service.dart';

class BrowserView extends StatelessWidget {
  const BrowserView({required this.service, super.key});

  final Object service;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.windows &&
        service is WindowsBrowserService) {
      final browser = service as WindowsBrowserService;
      return ValueListenableBuilder<WebviewValue>(
        valueListenable: browser.controller,
        builder: (context, value, _) {
          if (!value.isInitialized) {
            return const Center(child: CircularProgressIndicator());
          }
          return Webview(browser.controller);
        },
      );
    }
    if (service is MobileBrowserService) {
      final browser = service as MobileBrowserService;
      if (!browser.isInitialized) {
        return const Center(child: CircularProgressIndicator());
      }
      return WebViewWidget(controller: browser.controller);
    }
    return const Center(child: Text('当前平台暂不支持内置浏览器。'));
  }
}
