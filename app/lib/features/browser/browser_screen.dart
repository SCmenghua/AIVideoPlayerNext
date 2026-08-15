import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/browser/browser_models.dart';
import '../../domain/browser/browser_service.dart';
import '../../domain/player/browser_media_handoff.dart';
import 'browser_view.dart';

/// Persistent browser content shown inside the main workbench.
class BrowserWorkspace extends ConsumerStatefulWidget {
  const BrowserWorkspace({required this.onMediaDetected, super.key});

  final Future<void> Function(BrowserMediaHandoff handoff) onMediaDetected;

  @override
  ConsumerState<BrowserWorkspace> createState() => _BrowserWorkspaceState();
}

class _BrowserWorkspaceState extends ConsumerState<BrowserWorkspace> {
  final _addressController = TextEditingController();
  StreamSubscription<BrowserPageState>? _stateSubscription;
  StreamSubscription<BrowserEvent>? _eventSubscription;
  late BrowserService _browser;
  late BrowserPageState _state;

  @override
  void initState() {
    super.initState();
    _browser = ref.read(browserServiceProvider);
    _state = _browser.currentState;
    _stateSubscription = _browser.states.listen((state) {
      if (!mounted) return;
      setState(() => _state = state);
      if (state.url != null &&
          _addressController.text != state.url.toString()) {
        _addressController.value = TextEditingValue(
          text: state.url.toString(),
          selection:
              TextSelection.collapsed(offset: state.url.toString().length),
        );
      }
    });
    _eventSubscription = _browser.events.listen(_handleBrowserEvent);
    unawaited(_browser.initialize());
  }

  Future<void> _handleBrowserEvent(BrowserEvent event) async {
    if (!mounted) return;
    if (event case BrowserMediaDetected(:final handoff)) {
      await widget.onMediaDetected(handoff);
    } else if (event case BrowserUnsupportedMedia(:final reason)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(reason)));
    }
  }

  Future<void> _submitAddress(String value) async {
    final text = value.trim();
    if (text.isEmpty) return;
    final normalized = text.contains('://') ? text : 'https://$text';
    final url = Uri.tryParse(normalized);
    if (url == null || !(url.isScheme('https') || url.isScheme('http'))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的网址。')),
      );
      return;
    }
    await _browser.load(url);
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _eventSubscription?.cancel();
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(browserServiceProvider);
    return Column(
      children: [
        Material(
          color: const Color(0xFF191C1E),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            child: _addressBar(),
          ),
        ),
        if (_state.status == BrowserLoadStatus.loading)
          LinearProgressIndicator(value: _state.progress / 100),
        if (_state.message != null)
          _BrowserNotice(
            message: _state.message!,
            onRetry: _state.url == null ? null : _browser.reload,
          ),
        Expanded(child: BrowserView(service: _browser)),
      ],
    );
  }

  Widget _addressBar() => Row(
        children: [
          IconButton(
            onPressed: _state.canGoBack ? _browser.goBack : null,
            tooltip: '后退',
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            onPressed: _state.canGoForward ? _browser.goForward : null,
            tooltip: '前进',
            icon: const Icon(Icons.arrow_forward),
          ),
          Expanded(
            child: TextField(
              controller: _addressController,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: _submitAddress,
              decoration: const InputDecoration(
                hintText: '输入网址',
                isDense: true,
                prefixIcon: Icon(Icons.language_outlined),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            onPressed: _state.status == BrowserLoadStatus.loading
                ? _browser.stop
                : _browser.reload,
            tooltip:
                _state.status == BrowserLoadStatus.loading ? '停止加载' : '刷新网页',
            icon: Icon(_state.status == BrowserLoadStatus.loading
                ? Icons.close
                : Icons.refresh),
          ),
        ],
      );
}

class _BrowserNotice extends StatelessWidget {
  const _BrowserNotice({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF4A2721),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Color(0xFFFFAA8A)),
              const SizedBox(width: 8),
              Expanded(child: Text(message)),
              if (onRetry != null)
                IconButton(
                  onPressed: onRetry,
                  tooltip: '重试',
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
        ),
      );
}
