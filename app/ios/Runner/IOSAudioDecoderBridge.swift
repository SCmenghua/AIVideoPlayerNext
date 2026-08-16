import AVFoundation
import Flutter
import Foundation

/// Local-file media audio bridge for Phase 6.5.
///
/// The bridge deliberately does not read microphone input or network URLs. The
/// reader emits bounded Float32 mono/stereo PCM chunks with the media timeline
/// so Dart can reuse the Phase 6 window planner and session guards.
final class IOSAudioDecoderBridge: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private let lock = NSLock()
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var worker: DispatchWorkItem?
  private var sessionID = ""
  private var sourcePath = ""
  private var accepting = false
  private var generation = 0

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
                let path = args["path"] as? String,
                let session = args["sessionId"] as? String else {
            throw BridgeError.message("缺少本地媒体路径或会话 ID")
          }
          try self.open(path: path, sessionID: session)
          result(nil)
        case "start": self.start(); result(nil)
        case "pause": self.pause(); result(nil)
        case "seek":
          let args = call.arguments as? [String: Any]
          self.seek(milliseconds: args?["positionMs"] as? Int ?? 0)
          result(nil)
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

  private func open(path: String, sessionID: String, startMilliseconds: Int = 0) throws {
    stop()
    guard path.hasPrefix("/") else { throw BridgeError.message("iOS 识别目前只支持本地文件") }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else { throw BridgeError.message("本地媒体文件不存在") }
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else {
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
    self.sourcePath = path
    self.accepting = false
    self.generation += 1
  }

  private func start() {
    lock.lock()
    guard let reader, let output, !sessionID.isEmpty else { lock.unlock(); return }
    generation += 1
    let token = generation
    let session = sessionID
    accepting = true
    lock.unlock()
    if reader.status == .unknown { reader.startReading() }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      var firstPresentationTime: CMTime?
      let wallClockStart = Date()
      while true {
        self.lock.lock(); let active = self.accepting && self.generation == token; self.lock.unlock()
        if !active { break }
        guard let sample = output.copyNextSampleBuffer() else {
          self.lock.lock(); let stillActive = self.accepting && self.generation == token; self.accepting = false; self.lock.unlock()
          if stillActive { self.sendTail(sessionID: session, ended: true) }
          break
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        if firstPresentationTime == nil { firstPresentationTime = presentationTime }
        if let firstPresentationTime,
           !self.waitForTimeline(
             presentationTime: presentationTime,
             firstPresentationTime: firstPresentationTime,
             wallClockStart: wallClockStart,
             token: token
           ) {
          CMSampleBufferInvalidate(sample)
          break
        }
        self.send(sampleBuffer: sample, sessionID: session)
        CMSampleBufferInvalidate(sample)
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

  private func seek(milliseconds: Int) {
    guard !sourcePath.isEmpty, !sessionID.isEmpty else { return }
    let path = sourcePath
    let session = sessionID
    do {
      try open(path: path, sessionID: session, startMilliseconds: milliseconds)
    } catch {
      send(["type": "error", "message": error.localizedDescription])
    }
  }

  private func stop() {
    lock.lock(); accepting = false; generation += 1; lock.unlock()
    worker?.cancel(); worker = nil
    reader?.cancelReading(); reader = nil; output = nil
  }

  private func waitForTimeline(
    presentationTime: CMTime,
    firstPresentationTime: CMTime,
    wallClockStart: Date,
    token: Int
  ) -> Bool {
    let target = CMTimeSubtract(presentationTime, firstPresentationTime).seconds
    while Date().timeIntervalSince(wallClockStart) < target {
      lock.lock(); let active = accepting && generation == token; lock.unlock()
      if !active { return false }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return true
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

  private func send(_ value: [String: Any]) { DispatchQueue.main.async { [weak self] in self?.eventSink?(value) } }
}

private enum BridgeError: Error, CustomStringConvertible {
  case message(String)
  var description: String { if case let .message(value) = self { return value }; return "音频桥接失败" }
}
