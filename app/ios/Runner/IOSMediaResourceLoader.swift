import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Feeds AVFoundation from the recognition loopback proxy.
///
/// The iOS experimental streaming path hands AVURLAsset a custom-scheme URL
/// (`aivpmedia://127.0.0.1:<port>/media.mp4`). AVFoundation's own HTTP stack
/// rejected the plain http loopback source on device ("Operation Stopped"
/// after ~7 s), so this loader takes over: every AVAssetResourceLoadingRequest
/// becomes a ranged URLSession request against the same Dart HttpServer, and
/// the received bytes are responded back to AVFoundation. The Dart proxy,
/// cache, priority and diagnostics infrastructure is unchanged.
///
/// Discipline required by AVFoundation: every loading request answered with
/// `true` here must eventually receive exactly one finishLoading call, and
/// must never be touched again after didCancel. Both are enforced through the
/// pending map plus the per-record `finished` flag.
final class IOSMediaResourceLoader: NSObject {
  /// Serial queue owning all mutable state. Resource-loader and URLSession
  /// delegate callbacks are both hopped onto this queue, so no additional
  /// locking is required. One loader instance lives for exactly one decoder
  /// open() generation; the bridge invalidates it in stop().
  private let queue = DispatchQueue(label: "aivp.media.resourceloader", qos: .userInitiated)
  private var session: URLSession!
  private let targetURL: URL
  private let headers: [String: String]

  /// Keyed by ObjectIdentifier of the loading request. Only accessed on queue.
  private var pending: [ObjectIdentifier: RequestRecord] = [:]

  private final class RequestRecord {
    init(loadingRequest: AVAssetResourceLoadingRequest) {
      self.loadingRequest = loadingRequest
    }

    let loadingRequest: AVAssetResourceLoadingRequest
    var dataTask: URLSessionDataTask?
    var statusCode = 0
    /// Bytes dropped from the head of a 200 response so far (the upstream
    /// ignored our Range header).
    var skippedBytes = 0
    /// Offset this fetch must resume from when the upstream answers with an
    /// undifferentiated 200 instead of honoring Range.
    var requestSkipTo: Int64 = 0
    var respondedBytes = 0
    var finished = false

    func finish(with error: NSError? = nil) {
      guard !finished else { return }
      finished = true
      dataTask?.cancel()
      if let error {
        loadingRequest.finishLoading(with: error)
      } else {
        loadingRequest.finishLoading()
      }
    }
  }

  init(customURL: URL, headers: [String: String]) {
    self.targetURL = customURL
    self.headers = headers
    super.init()
    let configuration = URLSessionConfiguration.default
    // Idle timeout between received bytes; also covers connect + TTFB. The
    // loopback hop itself is sub-100 ms, the bottleneck is the upstream site.
    configuration.timeoutIntervalForRequest = 15
    // Hard cap for one fetch's total lifetime.
    configuration.timeoutIntervalForResource = 120
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: nil
    )
  }

  /// Must be called before the asset's tracks are first loaded.
  func attach(to asset: AVURLAsset) {
    asset.resourceLoader.setDelegate(self, queue: queue)
  }

  /// Cancels every outstanding task and finishes pending loading requests.
  /// Called by the bridge on stop/seek/media change and after failed opens.
  func invalidate() {
    queue.async { [weak self] in
      guard let self else { return }
      let records = Array(self.pending.values)
      self.pending.removeAll()
      for record in records {
        record.finish(
          with: NSError(
            domain: "AIVPMediaResourceLoader", code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "解码器已停止，流式读取已取消"]
          )
        )
      }
      self.session.invalidateAndCancel()
    }
  }

  private func record(for task: URLSessionTask) -> RequestRecord? {
    pending.values.first { $0.dataTask === task }
  }

  /// Continuation reads must resume from currentOffset, not requestedOffset:
  /// responding advances currentOffset within one loading request.
  private static func rangeHeader(for data: AVAssetResourceLoadingDataRequest) -> String {
    let offset = data.currentOffset
    if data.requestsAllDataToEndOfResource {
      return "bytes=\(offset)-"
    }
    let end = data.requestedOffset + Int64(data.requestedLength) - 1
    return "bytes=\(offset)-\(max(offset, end))"
  }

  private func startFetch(_ record: RequestRecord, range: String) {
    var request = URLRequest(url: targetURL)
    request.httpMethod = "GET"
    request.setValue(range, forHTTPHeaderField: "Range")
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    let task = session.dataTask(with: request)
    record.dataTask = task
    task.resume()
  }

  /// Wraps an upstream error with its domain/code chain so the Dart log shows
  /// actionable detail instead of a bare localized description.
  private static func enrichedError(_ error: Error) -> NSError {
    let ns = error as NSError
    var description =
      "流式读取失败 domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
    var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
    var depth = 0
    while let current = underlying, depth < 2 {
      description +=
        "; underlying=\(current.domain)/\(current.code) \(current.localizedDescription)"
      underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
      depth += 1
    }
    return NSError(
      domain: "AIVPMediaResourceLoader", code: ns.code,
      userInfo: [
        NSLocalizedDescriptionKey: description,
        NSUnderlyingErrorKey: ns,
      ]
    )
  }

  /// Parses the total length out of a Content-Range tail (`bytes x-y/total`),
  /// falling back to Content-Length only when it can only be valid. Never
  /// guesses: a wrong length breaks tail probing or hangs the reader.
  private static func totalLength(from response: HTTPURLResponse, rangeRequested: Bool) -> Int64? {
    if let contentRange = response.value(forHTTPHeaderField: "Content-Range") {
      let slash = contentRange.lastIndex(of: "/")
      if let slash {
        let tail = contentRange[contentRange.index(after: slash)...]
        if tail != "*", let total = Int64(tail), total > 0 {
          return total
        }
      }
      return nil
    }
    // Content-Length only describes the whole resource for a plain 200.
    if !rangeRequested && response.expectedContentLength > 0 {
      return response.expectedContentLength
    }
    return nil
  }

  private func contentTypeIdentifier(from response: HTTPURLResponse?) -> String {
    if let mimeType = response?.mimeType, let fromMime = UTType(mimeType: mimeType) {
      return fromMime.identifier
    }
    // The proxy path carries a real container extension (/media.mp4) exactly
    // so this hint resolves; Phase 9.9 showed AVFoundation needs it.
    if !targetURL.pathExtension.isEmpty,
      let fromExtension = UTType(filenameExtension: targetURL.pathExtension) {
      return fromExtension.identifier
    }
    return UTType.data.identifier
  }

  private func fillContentInformation(
    _ record: RequestRecord, response: HTTPURLResponse
  ) {
    guard let info = record.loadingRequest.contentInformationRequest else { return }
    info.isByteRangeSupported = true
    info.contentType = Self.contentTypeIdentifier(from: response)
    info.contentLength = Self.totalLength(
      from: response,
      rangeRequested: response.statusCode == 206
    )
  }
}

extension IOSMediaResourceLoader: AVAssetResourceLoaderDelegate {
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    let record = RequestRecord(loadingRequest: loadingRequest)
    pending[ObjectIdentifier(loadingRequest)] = record

    if let data = loadingRequest.dataRequest {
      // Where the body must resume if the upstream answers with an
      // undifferentiated 200 instead of honoring Range.
      record.requestSkipTo = data.currentOffset
      startFetch(record, range: Self.rangeHeader(for: data))
    } else if loadingRequest.contentInformationRequest != nil {
      // Metadata-only probing. Use GET bytes=0-0 instead of HEAD: the ranged
      // response carries the total length in Content-Range and lets the Dart
      // proxy warm/caches the container head, which HEAD never writes.
      startFetch(record, range: "bytes=0-0")
    } else {
      // Nothing answerable; do not strand AVFoundation waiting.
      record.finish()
      pending.removeValue(forKey: ObjectIdentifier(loadingRequest))
    }
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    queue.async { [weak self] in
      guard
        let self,
        let record = self.pending.removeValue(forKey: ObjectIdentifier(loadingRequest))
      else { return }
      record.dataTask?.cancel()
      // loadingRequest belongs to AVFoundation now; never touch it again.
    }
  }
}

extension IOSMediaResourceLoader: URLSessionDataDelegate {
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    queue.async { [weak self] in
      guard let self, let record = self.record(for: dataTask), !record.finished else {
        completionHandler(.cancel)
        return
      }
      guard let http = response as? HTTPURLResponse else {
        completionHandler(.cancel)
        record.finish(
          with: NSError(
            domain: "AIVPMediaResourceLoader", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "流式代理响应不是 HTTP 响应"]
          )
        )
        pending.removeValue(forKey: ObjectIdentifier(record.loadingRequest))
        return
      }
      record.statusCode = http.statusCode
      fillContentInformation(record, response: http)
      if record.loadingRequest.dataRequest == nil {
        // Metadata-only request satisfied by the response headers.
        completionHandler(.cancel)
        record.finish()
        pending.removeValue(forKey: ObjectIdentifier(record.loadingRequest))
        return
      }
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    queue.async { [weak self] in
      guard let self, let record = self.record(for: dataTask), !record.finished else { return }
      guard let dataRequest = record.loadingRequest.dataRequest else { return }
      var payload = Array(data)
      if record.statusCode == 200 && record.skippedBytes < record.requestSkipTo {
        // Upstream answered a ranged request with the full 200 body: drop
        // everything before the requested offset.
        let need = Int(record.requestSkipTo - Int64(record.skippedBytes))
        if payload.count <= need {
          record.skippedBytes += payload.count
          return
        }
        payload = Array(payload.dropFirst(need))
        record.skippedBytes = Int(record.requestSkipTo)
      }
      var sent = 0
      var offset = 0
      // Cap the response at requestedLength: responding beyond it raises an
      // NSInvalidArgumentException inside AVFoundation.
      let respondCap: Int =
        dataRequest.requestsAllDataToEndOfResource
        ? Int.max
        : max(
          0,
          Int(
            dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
            - dataRequest.currentOffset)
        )
      while offset < payload.count && sent < respondCap {
        // Bounded chunks keep peak memory flat; respond copies into
        // AVFoundation immediately.
        let chunkLength = min(128 * 1024, payload.count - offset, respondCap - sent)
        dataRequest.respond(with: payload.subdata(in: offset..<offset + chunkLength))
        record.respondedBytes += chunkLength
        sent += chunkLength
        offset += chunkLength
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    queue.async { [weak self] in
      guard let self, let record = self.record(for: task) else { return }
      defer { pending.removeValue(forKey: ObjectIdentifier(record.loadingRequest)) }
      if let error {
        record.finish(with: Self.enrichedError(error))
        return
      }
      // Normal EOF. A short body is acceptable: AVFoundation issues follow-up
      // requests or treats the position as the media end on its own.
      record.finish()
    }
  }
}
