import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/providers.dart';
import '../../domain/player/player_service.dart';
import '../recognition/model_import.dart';
import '../recognition/recognition_service.dart';
import '../recognition/whisper_model_store.dart';
import '../settings/app_settings.dart';
import 'subtitle_layer.dart';

class PlayerOverlayActions {
  const PlayerOverlayActions({
    required this.onTogglePlay,
    required this.onSeek,
    required this.onOpenFile,
    required this.onOpenBrowser,
    required this.onOpenSettings,
    required this.onOpenDiagnostics,
  });

  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onOpenFile;
  final VoidCallback onOpenBrowser;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenDiagnostics;
}

/// Everything drawn over the video: auto-hiding top bar and transport
/// controls, the subtitle layer, and the recognition status line. Used as the
/// `controls` builder of media_kit's [Video] so it also appears in fullscreen.
class PlayerOverlay extends ConsumerStatefulWidget {
  const PlayerOverlay({
    super.key,
    required this.videoState,
    required this.snapshot,
    required this.actions,
    required this.statusText,
    this.waitingReason,
  });

  final VideoState? videoState;
  final PlaybackSnapshot snapshot;
  final PlayerOverlayActions actions;
  final String statusText;
  final String? waitingReason;

  @override
  ConsumerState<PlayerOverlay> createState() => _PlayerOverlayState();
}

class _PlayerOverlayState extends ConsumerState<PlayerOverlay> {
  static const _hideAfter = Duration(seconds: 3);

  bool _visible = true;
  Timer? _hideTimer;
  double? _scrubFraction;
  double? _hoverFraction;
  bool _muted = false;
  double _volumeBeforeMute = 100;

  PlaybackSnapshot get _snapshot => widget.snapshot;
  bool get _playing => _snapshot.status == PlaybackStatus.playing;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(covariant PlayerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.status != widget.snapshot.status) _reveal();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _reveal() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  // Controls only auto-hide during playback; a paused player keeps them.
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_playing) return;
    _hideTimer = Timer(_hideAfter, () {
      if (!mounted || !_playing || _scrubFraction != null) return;
      setState(() => _visible = false);
    });
  }

  void _toggleVisible() {
    if (_visible) {
      if (_playing) setState(() => _visible = false);
    } else {
      _reveal();
    }
  }

  Duration get _duration => _snapshot.duration;

  Duration _fractionToPosition(double fraction) =>
      Duration(milliseconds: (_duration.inMilliseconds * fraction).round());

  Duration get _displayPosition => _scrubFraction == null
      ? _snapshot.position
      : _fractionToPosition(_scrubFraction!);

  void _seekBy(Duration offset) {
    final target = _snapshot.position + offset;
    widget.actions.onSeek(target < Duration.zero ? Duration.zero : target);
    _reveal();
  }

  void _adjustVolume(double delta) {
    final player = ref.read(playerServiceProvider);
    player.setVolume((_snapshot.volume + delta).clamp(0.0, 100.0).toDouble());
    _muted = false;
    _reveal();
  }

  void _toggleMute() {
    final player = ref.read(playerServiceProvider);
    if (_muted) {
      player.setVolume(_volumeBeforeMute);
      _muted = false;
    } else {
      _volumeBeforeMute = _snapshot.volume == 0 ? 100 : _snapshot.volume;
      player.setVolume(0);
      _muted = true;
    }
    _reveal();
  }

  void _toggleFullscreen() {
    final state = widget.videoState;
    if (state == null) return;
    state.toggleFullscreen();
    _reveal();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final store = ref.watch(transcriptStoreProvider);
    final recognition = ref.watch(recognitionServiceProvider);
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 640;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): widget.actions.onTogglePlay,
        const SingleActivator(LogicalKeyboardKey.keyK): widget.actions.onTogglePlay,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _seekBy(const Duration(seconds: -5)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _seekBy(const Duration(seconds: 5)),
        const SingleActivator(LogicalKeyboardKey.keyJ): () =>
            _seekBy(const Duration(seconds: -10)),
        const SingleActivator(LogicalKeyboardKey.keyL): () =>
            _seekBy(const Duration(seconds: 10)),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _adjustVolume(5),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _adjustVolume(-5),
        const SingleActivator(LogicalKeyboardKey.keyM): _toggleMute,
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          final state = widget.videoState;
          if (state != null && state.isFullscreen()) state.exitFullscreen();
        },
      },
      child: Focus(
        autofocus: true,
        child: MouseRegion(
          cursor: _visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
          onHover: (_) => _reveal(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _toggleVisible,
                onDoubleTapDown: (details) {
                  if (compact) {
                    final width = MediaQuery.sizeOf(context).width;
                    final dx = details.localPosition.dx;
                    if (dx < width / 3) {
                      _seekBy(const Duration(seconds: -10));
                    } else if (dx > width * 2 / 3) {
                      _seekBy(const Duration(seconds: 10));
                    } else {
                      widget.actions.onTogglePlay();
                    }
                  } else {
                    _toggleFullscreen();
                  }
                },
              ),
              SubtitleLayer(
                document: store.document,
                position: _displayPosition,
                targetLanguage: settings.translationTargetLanguage,
                displayMode: settings.subtitleDisplayMode,
                fontScale: settings.subtitleFontScale,
                bottomPadding: _visible ? 132 : 28,
              ),
              if (widget.waitingReason != null && !_playing)
                Center(
                  child: _WaitingBadge(reason: widget.waitingReason!),
                ),
              _RecognitionBanner(recognition: recognition),
              IgnorePointer(
                ignoring: !_visible,
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Column(
                    children: [
                      _topBar(context, scheme, compact),
                      const Spacer(),
                      _bottomBar(context, scheme, compact),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, ColorScheme scheme, bool compact) => Container(
        padding: EdgeInsets.fromLTRB(12, MediaQuery.paddingOf(context).top + 6, 8, 10),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xB3000000), Color(0x00000000)],
          ),
        ),
        child: Row(
          children: [
            if (widget.videoState?.isFullscreen() == true)
              IconButton(
                tooltip: '退出全屏',
                onPressed: _toggleFullscreen,
                icon: const Icon(Icons.arrow_back),
              ),
            Expanded(
              child: Text(
                _snapshot.source?.title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
              ),
            ),
            IconButton(
              tooltip: '打开本地视频',
              onPressed: widget.actions.onOpenFile,
              icon: const Icon(Icons.folder_open_outlined),
            ),
            IconButton(
              tooltip: '内置浏览器',
              onPressed: widget.actions.onOpenBrowser,
              icon: const Icon(Icons.language_outlined),
            ),
            IconButton(
              tooltip: '诊断',
              onPressed: widget.actions.onOpenDiagnostics,
              icon: const Icon(Icons.monitor_heart_outlined),
            ),
            IconButton(
              tooltip: '设置',
              onPressed: widget.actions.onOpenSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
      );

  Widget _bottomBar(BuildContext context, ColorScheme scheme, bool compact) {
    final durationMs = _duration.inMilliseconds;
    final fraction = durationMs == 0
        ? 0.0
        : (_displayPosition.inMilliseconds / durationMs).clamp(0.0, 1.0).toDouble();
    final buffered = durationMs == 0
        ? 0.0
        : (_snapshot.bufferedDuration.inMilliseconds / durationMs).clamp(0.0, 1.0).toDouble();
    return Container(
      padding: EdgeInsets.fromLTRB(12, 24, 12, MediaQuery.paddingOf(context).bottom + 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12),
                ),
              ),
              if (_snapshot.isBuffering)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 4),
          _progressBar(scheme, fraction, buffered),
          Row(
            children: [
              IconButton(
                tooltip: _playing ? '暂停 (空格)' : '播放 (空格)',
                iconSize: 30,
                onPressed: _snapshot.source == null ? null : widget.actions.onTogglePlay,
                icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              if (!compact) ...[
                IconButton(
                  tooltip: '后退 10 秒 (J)',
                  onPressed: () => _seekBy(const Duration(seconds: -10)),
                  icon: const Icon(Icons.replay_10_rounded),
                ),
                IconButton(
                  tooltip: '前进 10 秒 (L)',
                  onPressed: () => _seekBy(const Duration(seconds: 10)),
                  icon: const Icon(Icons.forward_10_rounded),
                ),
              ],
              IconButton(
                tooltip: _snapshot.volume == 0 ? '取消静音 (M)' : '静音 (M)',
                onPressed: _toggleMute,
                icon: Icon(
                  _snapshot.volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                ),
              ),
              if (!compact)
                SizedBox(
                  width: 110,
                  child: Slider(
                    value: _snapshot.volume.clamp(0.0, 100.0).toDouble(),
                    max: 100,
                    onChanged: (value) {
                      _muted = false;
                      ref.read(playerServiceProvider).setVolume(value);
                      _reveal();
                    },
                  ),
                ),
              const SizedBox(width: 8),
              Text(
                '${formatClock(_displayPosition)} / ${formatClock(_duration)}',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const Spacer(),
              _subtitleModeButton(),
              PopupMenuButton<double>(
                tooltip: '播放速度',
                initialValue: _snapshot.rate,
                onSelected: (rate) {
                  ref.read(playerServiceProvider).setRate(rate);
                  _reveal();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 0.5, child: Text('0.5×')),
                  PopupMenuItem(value: 0.75, child: Text('0.75×')),
                  PopupMenuItem(value: 1.0, child: Text('1.0×')),
                  PopupMenuItem(value: 1.25, child: Text('1.25×')),
                  PopupMenuItem(value: 1.5, child: Text('1.5×')),
                  PopupMenuItem(value: 2.0, child: Text('2.0×')),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text(
                    '${_snapshot.rate.toStringAsFixed(_snapshot.rate == _snapshot.rate.roundToDouble() ? 1 : 2)}×',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
              IconButton(
                tooltip: '全屏 (F)',
                onPressed: _toggleFullscreen,
                icon: Icon(
                  widget.videoState?.isFullscreen() == true
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _subtitleModeButton() {
    final controller = ref.read(appSettingsProvider);
    final mode = ref.watch(appSettingsProvider).subtitleDisplayMode;
    return PopupMenuButton<SubtitleDisplayMode>(
      tooltip: '字幕显示',
      initialValue: mode,
      onSelected: controller.setSubtitleDisplayMode,
      itemBuilder: (context) => const [
        PopupMenuItem(value: SubtitleDisplayMode.bilingual, child: Text('双语')),
        PopupMenuItem(value: SubtitleDisplayMode.translation, child: Text('仅译文')),
        PopupMenuItem(value: SubtitleDisplayMode.original, child: Text('仅原文')),
      ],
      icon: const Icon(Icons.subtitles_outlined),
    );
  }

  Widget _progressBar(ColorScheme scheme, double fraction, double buffered) {
    final enabled = _duration > Duration.zero && _snapshot.source != null;
    return LayoutBuilder(
      builder: (context, constraints) => MouseRegion(
        onHover: enabled
            ? (event) => setState(() {
                  _hoverFraction =
                      (event.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0).toDouble();
                })
            : null,
        onExit: (_) => setState(() => _hoverFraction = null),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: buffered,
                child: Container(
                  height: 3,
                  color: Colors.white.withValues(alpha: 0.25),
                ),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: scheme.primary,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
                thumbColor: scheme.primary,
              ),
              child: Slider(
                value: fraction,
                onChanged: enabled
                    ? (value) {
                        setState(() => _scrubFraction = value);
                        _reveal();
                      }
                    : null,
                onChangeEnd: enabled
                    ? (value) {
                        setState(() => _scrubFraction = null);
                        widget.actions.onSeek(_fractionToPosition(value));
                      }
                    : null,
              ),
            ),
            if (_hoverFraction != null && enabled)
              Positioned(
                left: (_hoverFraction! * constraints.maxWidth - 28)
                    .clamp(0.0, (constraints.maxWidth - 56).clamp(0.0, double.infinity))
                    .toDouble(),
                top: -26,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      formatClock(_fractionToPosition(_hoverFraction!)),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WaitingBadge extends StatelessWidget {
  const _WaitingBadge({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(reason, style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
}

/// Shown only when recognition cannot run: a missing model (with an install
/// button and progress) or a missing runtime.
class _RecognitionBanner extends StatelessWidget {
  const _RecognitionBanner({required this.recognition});

  final RecognitionService recognition;

  @override
  Widget build(BuildContext context) {
    final status = recognition.status;
    final spec = status.missingModel;
    final download = status.download;
    final scheme = Theme.of(context).colorScheme;
    if (status.availability == RecognitionAvailability.ready ||
        (status.availability == RecognitionAvailability.checking && download == null)) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 60, left: 16, right: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Material(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Icons.download_for_offline_outlined, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          spec == null
                              ? status.message ?? '识别不可用'
                              : download == null || download.isFailed
                                  ? '识别模型 ${spec.label} 尚未安装（${spec.sizeLabel}）'
                                  : download.phase == ModelDownloadPhase.verifying
                                      ? '正在校验 ${spec.fileName}'
                                      : '正在下载 ${spec.fileName} '
                                          '${(download.fraction * 100).toStringAsFixed(0)}% · '
                                          '${download.speedLabel}'
                                          '${download.attempt > 1 ? ' · 第 ${download.attempt} 次' : ''}'
                                          '${download.source == null ? '' : ' · ${download.source}'}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      if (spec != null && (download == null || download.isFailed)) ...[
                        TextButton(
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.maybeOf(context);
                            final message = await pickAndImportModel(recognition, expected: spec);
                            if (message != null) {
                              messenger?.showSnackBar(SnackBar(content: Text(message)));
                            }
                          },
                          child: const Text('导入文件'),
                        ),
                        FilledButton(
                          onPressed: () => recognition.installModel(spec),
                          child: Text(download == null ? '下载' : '重试'),
                        ),
                      ],
                    ],
                  ),
                  if (download != null && !download.isFailed) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: download.fraction),
                  ],
                  if (download?.error != null) ...[
                    const SizedBox(height: 6),
                    Text(download!.error!, style: TextStyle(color: scheme.error, fontSize: 12)),
                  ],
                  if (spec != null && (download == null || download.isFailed)) ...[
                    const SizedBox(height: 6),
                    Text(
                      '下载慢或失败时可在设置中切换 hf-mirror.com 镜像或填写代理，也可以从文件导入。',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String formatClock(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes % 60;
  final seconds = value.inSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}
