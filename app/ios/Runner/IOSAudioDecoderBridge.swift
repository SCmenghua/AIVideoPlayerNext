import AVFoundation
import Flutter
import Foundation

/// AVFoundation media audio bridge for recognition.
///
/// The reader emits bounded Float32 mono/stereo PCM chunks with the media
/// timeline so Dart can reuse the window planner and session guards. Network
/// assets receive the browser handoff headers (for example Cookie and
/// Referer) through AVURLAsset's resource-loading options.
final class IOSAudioDecoderBridge: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private let lock = NSLock()
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var worker: DispatchWorkItem?
  private var sessionID = ""
  private var sourceURL: URL?
  private var sourceHeaders: [String: String] = [:]
  private var accepting = false
  private var generation = 0
  private let inflightLock = NSLock()
  private var inflightSends = 0
  private var securityScopedURL: URL?
  private var securityScopeActive = false

  func register(with registrar: FlutterApplicationRegistrar) {
    let methods = FlutterMethodChannel(
      name: "ai_video_player/ios_audio",
      binaryMessenger: registrar.messenger()
    )
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "DISPOSED", message: "音频解码器已释放", details: nil)); return }
      do {
        switch call.method {
        case "open":
          guard let args = call.arguments as? [String: Any],
                let session = args["sessionId"] as? String else {
            throw BridgeError.message("缺少媒体地址或会话 ID")
          }
          let uri = args["uri"] as? String
          let path = args["path"] as? String
          let headers = args["headers"] as? [String: String] ?? [:]
          guard let source = Self.sourceURL(uri: uri, path: path) else {
            throw BridgeError.message("媒体地址无效")
          }
          Task {
            do {
              try await self.open(url: source, headers: headers, sessionID: session)
              result(nil)
            } catch let error as BridgeError {
              result(FlutterError(code: "AUDIO", message: error.description, details: nil))
            } catch {
              result(FlutterError(code: "AUDIO", message: error.localizedDescription, details: nil))
            }
          }
        case "start": self.start(); result(nil)
        case "pause": self.pause(); result(nil)
        case "seek":
          let args = call.arguments as? [String: Any]
          Task {
            do {
              try await self.seek(milliseconds: args?["positionMs"] as? Int ?? 0)
              result(nil)
            } catch let error as BridgeError {
              result(FlutterError(code: "AUDIO", message: error.description, details: nil))
            } catch {
              result(FlutterError(code: "AUDIO", message: error.localizedDescription, details: nil))
            }
          }
        case "stop": self.stop(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      } catch let error as BridgeError {
        result(FlutterError(code: "AUDIO", message: error.description, details: nil))
      } catch {
        result(FlutterError(code: "AUDIO", message: error.localizedDescription, details: nil))
      }
    }

    let events = FlutterEventChannel(
      name: "ai_video_player/ios_audio_events",
      binaryMessenger: registrar.messenger()
    )
    events.setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func open(
    url: URL,
    headers: [String: String],
    sessionID: String,
    startMilliseconds: Int = 0
  ) async throws {
    stop()
    lock.lock()
    let openToken = generation
    lock.unlock()
    var assetURL = url
    var keepSecurityScope = false
    if url.isFileURL {
      guard let readableURL = acquireReadableURL(path: url.path) else {
        throw BridgeError.message("本地媒体文件不存在")
      }
      assetURL = readableURL
      keepSecurityScope = true
    }
    defer {
      if !keepSecurityScope {
        releaseSecurityScopedAccess()
      }
    }
    var options: [String: Any] = [:]
    if !headers.isEmpty && !url.isFileURL {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: assetURL, options: options.isEmpty ? nil : options)
    let tracks = try await loadTracks(asset)
    lock.lock()
    let stillCurrent = generation == openToken
    lock.unlock()
    guard stillCurrent else { throw BridgeError.message("媒体会话已切换") }
    guard let track = tracks.first(where: { $0.mediaType == .audio }) else {
      throw BridgeError.message("媒体没有可读取的音频轨道")
    }
    let reader = try AVAssetReader(asset: asset)
    if startMilliseconds > 0 {
      let start = CMTime(value: Int64(startMilliseconds), timescale: 1000)
      reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: false,
      AVLinearPCMIsBigEndianKey: false,
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw BridgeError.message("无法建立音频读取器") }
    reader.add(output)
    self.reader = reader
    self.output = output
    self.sessionID = sessionID
    self.sourceURL = url
    self.sourceHeaders = headers
    self.accepting = false
    self.generation += 1
    keepSecurityScope = true
  }

  /// A document-picker URL may be security-scoped. Keep access alive for the
  /// complete decoder session so a later seek can reopen the same file.
  private func acquireReadableURL(path: String) -> URL? {
    let directURL = URL(fileURLWithPath: path)
    var candidates = [directURL]
    if let decodedPath = path.removingPercentEncoding,
       decodedPath != path {
      candidates.append(URL(fileURLWithPath: decodedPath))
    }

    for candidate in candidates {
      let acquired = candidate.startAccessingSecurityScopedResource()
      if FileManager.default.fileExists(atPath: candidate.path) {
        securityScopedURL = candidate
        securityScopeActive = acquired
        return candidate
      }
      if acquired { candidate.stopAccessingSecurityScopedResource() }
    }
    return nil
  }

  private func start() {
    lock.lock()
    guard let reader, let output, !sessionID.isEmpty else { lock.unlock(); return }
    generation += 1
    let token = generation
    let session = sessionID
    accepting = true
    lock.unlock()
    if reader.status == .unknown {
      guard reader.startReading() else {
        let message = reader.error?.localizedDescription ?? "iOS 媒体读取器启动失败"
        self.send(["type": "error", "sessionId": session, "message": message])
        self.lock.lock(); self.accepting = false; self.lock.unlock()
        return
      }
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      // Recognition is an independent sequential consumer: read ahead at full
      // decode speed and let the bounded Dart recognition queue and its
      // watermarks apply backpressure. Pacing output to wall-clock playback
      // here would lock recognition into permanently trailing the player.
      while true {
        self.lock.lock(); let active = self.accepting && self.generation == token; self.lock.unlock()
        if !active { break }
        guard let sample = output.copyNextSampleBuffer() else {
          self.lock.lock(); let stillActive = self.accepting && self.generation == token; self.accepting = false; self.lock.unlock()
          if stillActive {
            if reader.status == .failed {
              self.send(["type": "error", "sessionId": session,
                         "message": reader.error?.localizedDescription ?? "iOS 媒体读取失败"])
            } else {
              self.sendTail(sessionID: session, ended: true)
            }
          }
          break
        }
        self.send(sampleBuffer: sample, sessionID: session)
        CMSampleBufferInvalidate(sample)
        // Full-speed reading must not flood the platform thread: pause calls
        // from Dart share it with these dispatches, so yield once too many
        // chunk sends are still in flight.
        while self.currentInflightSends() > 16 {
          self.lock.lock(); let stillActive = self.accepting && self.generation == token; self.lock.unlock()
          if !stillActive { break }
          Thread.sleep(forTimeInterval: 0.005)
        }
      }
    }
    worker = work
    DispatchQueue.global(qos: .userInitiated).async(execute: work)
  }

  private func pause() {
    lock.lock()
    let session = sessionID
    let shouldFlush = accepting && !session.isEmpty
    accepting = false
    generation += 1
    lock.unlock()
    if shouldFlush { sendTail(sessionID: session, ended: false) }
  }

  private func seek(milliseconds: Int) async throws {
    guard let sourceURL, !sessionID.isEmpty else {
      throw BridgeError.message("iOS 音频解码器尚未打开")
    }
    let session = sessionID
    try await open(
      url: sourceURL,
      headers: sourceHeaders,
      sessionID: session,
      startMilliseconds: milliseconds
    )
  }

  private func stop() {
    lock.lock(); accepting = false; generation += 1; lock.unlock()
    worker?.cancel(); worker = nil
    reader?.cancelReading(); reader = nil; output = nil
    sessionID = ""
    sourceURL = nil
    sourceHeaders = [:]
    releaseSecurityScopedAccess()
  }

  private func loadTracks(_ asset: AVAsset) async throws -> [AVAssetTrack] {
    try await withCheckedThrowingContinuation { continuation in
      asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
        var error: NSError?
        let status = asset.statusOfValue(forKey: "tracks", error: &error)
        switch status {
        case .loaded:
          continuation.resume(returning: asset.tracks(withMediaType: .audio))
        case .failed, .cancelled:
          continuation.resume(throwing: error ?? BridgeError.message("网络媒体音频轨道加载失败"))
        default:
          continuation.resume(throwing: BridgeError.message("网络媒体音频轨道尚未就绪"))
        }
      }
    }
  }

  private static func sourceURL(uri: String?, path: String?) -> URL? {
    if let uri, let parsed = URL(string: uri), parsed.scheme != nil {
      return parsed
    }
    if let path, path.hasPrefix("/") {
      return URL(fileURLWithPath: path)
    }
    return nil
  }

  private func releaseSecurityScopedAccess() {
    if securityScopeActive {
      securityScopedURL?.stopAccessingSecurityScopedResource()
    }
    securityScopedURL = nil
    securityScopeActive = false
  }

  private func send(sampleBuffer: CMSampleBuffer, sessionID: String) {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var length = 0; var pointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
          let pointer else { return }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    send(["sessionId": sessionID, "mediaStartMs": Int((timestamp.seconds * 1000).rounded()),
          "sampleRate": Int(asbd.mSampleRate), "channels": Int(asbd.mChannelsPerFrame),
          "samples": FlutterStandardTypedData(bytes: Data(bytes: pointer, count: length)), "isLast": false])
  }

  private func sendTail(sessionID: String, ended: Bool) {
    send(["sessionId": sessionID, "isLast": true, "ended": ended])
  }

  private func send(_ value: [String: Any]) {
    inflightLock.lock()
    inflightSends += 1
    inflightLock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.eventSink?(value)
      self.inflightLock.lock()
      self.inflightSends -= 1
      self.inflightLock.unlock()
    }
  }

  private func currentInflightSends() -> Int {
    inflightLock.lock()
    defer { inflightLock.unlock() }
    return inflightSends
  }
}

private enum BridgeError: Error, CustomStringConvertible {
  case message(String)
  var description: String { if case let .message(value) = self { return value }; return "音频桥接失败" }
}
