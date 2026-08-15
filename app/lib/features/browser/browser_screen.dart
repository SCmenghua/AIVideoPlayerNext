import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/providers.dart';
import '../../domain/browser/browser_models.dart';
import '../../domain/browser/browser_service.dart';
import '../../domain/player/browser_media_handoff.dart';
import '../../domain/player/player_service.dart';
import '../player/media_kit_player_service.dart';
import 'browser_view.dart';

class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  final _addressController = TextEditingController();
  StreamSubscription<BrowserPageState>? _stateSubscription;
  StreamSubscription<BrowserEvent>? _eventSubscription;
  late BrowserService _browser;
  late BrowserPageState _state;
  bool _isOpeningMedia = false;

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
      await _openBrowserMedia(handoff);
    } else if (event case BrowserUnsupportedMedia(:final reason)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(reason)));
    }
  }

  Future<void> _openBrowserMedia(BrowserMediaHandoff handoff) async {
    if (_isOpeningMedia) return;
    _isOpeningMedia = true;
    try {
      await ref.read(playerServiceProvider).open(handoff.toMediaSource());
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BrowserMediaPlayerScreen(handoff: handoff),
      ));
    } finally {
      _isOpeningMedia = false;
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
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: _addressBar(),
        actions: [
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
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (_state.status == BrowserLoadStatus.loading)
            LinearProgressIndicator(value: _state.progress / 100),
          if (_state.message != null)
            _BrowserNotice(
              message: _state.message!,
              onRetry: _state.url == null ? null : _browser.reload,
            ),
          Expanded(child: BrowserView(service: _browser)),
        ],
      ),
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

class BrowserMediaPlayerScreen extends ConsumerStatefulWidget {
  const BrowserMediaPlayerScreen({required this.handoff, super.key});

  final BrowserMediaHandoff handoff;

  @override
  ConsumerState<BrowserMediaPlayerScreen> createState() =>
      _BrowserMediaPlayerScreenState();
}

class _BrowserMediaPlayerScreenState
    extends ConsumerState<BrowserMediaPlayerScreen> {
  StreamSubscription<PlaybackSnapshot>? _subscription;
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();

  @override
  void initState() {
    super.initState();
    final player = ref.read(playerServiceProvider);
    _subscription = player.snapshots.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
    unawaited(player.play());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    unawaited(ref.read(playerServiceProvider).pause());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.read(playerServiceProvider);
    final canControl = _snapshot.source != null &&
        _snapshot.status != PlaybackStatus.loading &&
        _snapshot.status != PlaybackStatus.error;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.handoff.title),
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          tooltip: '返回浏览器',
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: player is MediaKitPlayerService
                      ? Video(
                          controller: player.videoController,
                          controls: NoVideoControls,
                        )
                      : const ColoredBox(color: Color(0xFF202427)),
                ),
              ),
            ),
            if (_snapshot.message != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _snapshot.message!,
                  style: const TextStyle(color: Color(0xFFFFAA8A)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Slider(
                    value: _snapshot.position.inMilliseconds
                        .clamp(0, _snapshot.duration.inMilliseconds)
                        .toDouble(),
                    max: _snapshot.duration > Duration.zero
                        ? _snapshot.duration.inMilliseconds.toDouble()
                        : 1,
                    onChanged: canControl && _snapshot.duration > Duration.zero
                        ? (value) =>
                            player.seek(Duration(milliseconds: value.round()))
                        : null,
                  ),
                  Row(
                    children: [
                      Text(
                          '${_format(_snapshot.position)} / ${_format(_snapshot.duration)}'),
                      const Spacer(),
                      IconButton(
                        onPressed: canControl
                            ? () => player.seek(_snapshot.position -
                                const Duration(seconds: 10))
                            : null,
                        tooltip: '后退 10 秒',
                        icon: const Icon(Icons.replay_10),
                      ),
                      IconButton.filled(
                        onPressed: canControl
                            ? _snapshot.status == PlaybackStatus.playing
                                ? player.pause
                                : player.play
                            : null,
                        tooltip: _snapshot.status == PlaybackStatus.playing
                            ? '暂停播放'
                            : '开始播放',
                        icon: Icon(_snapshot.status == PlaybackStatus.playing
                            ? Icons.pause
                            : Icons.play_arrow),
                      ),
                      IconButton(
                        onPressed: canControl
                            ? () => player.seek(_snapshot.position +
                                const Duration(seconds: 10))
                            : null,
                        tooltip: '前进 10 秒',
                        icon: const Icon(Icons.forward_10),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _format(Duration duration) =>
      '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
}
