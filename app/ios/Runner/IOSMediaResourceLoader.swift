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
/// Bandwidth discipline: AVFoundation routinely asks for "all data to the end
/// of resource". Serving those reads as open-ended upstream ranges made every
/// sequential read pin a full tail download (device logs showed a 2 MB clip
/// pulled roughly ten times its size). Upstream fetches are therefore bounded
/// to fixed windows and chained while the reader still wants more; superseded
/// reads are finished promptly; the Dart proxy caches every window that passes
/// through it, so repeated reads are served locally instead of upstream.
///
/// Discipline required by AVFoundation: every loading request answered with
/// `true` here must eventually receive exactly one finishLoading call, and
/// must never be touched again after didCancel. Both are enforced through the
/// pending map plus the per-record `finished` flag and `isFinished` check.
final class IOSMediaResourceLoader: NSObject {
  /// Serial queue owning all mutable state. Resource-loader and URLSession
  /// delegate callbacks are both hopped onto this queue, so no additional
  /// locking is required. One loader instance lives for exactly one decoder
  /// open() generation; the bridge invalidates it in stop().
  private let queue = DispatchQueue(label: "aivp.media.resourceloader", qos: .userInitiated)
  private var session: URLSession!
  private let targetURL: URL
  private let headers: [String: String]

  /// Upstream fetch granularity. Chained windows keep a superseded or stalled
  /// read from pinning an unbounded tail download.
  private static let fetchWindowBytes: Int64 = 2 * 1024 * 1024

  /// respond(with:) copies into AVFoundation immediately; bounded chunks keep
  /// peak memory flat.
  private static let respondChunkBytes = 128 * 1024

  /// Keyed by ObjectIdentifier of the loading request. Only accessed on queue.
  private var pending: [ObjectIdentifier: RequestRecord] = [:]

  private final class RequestRecord {
    init(loadingRequest: AVAssetResourceLoadingRequest) {
      self.loadingRequest = loadingRequest
    }

    let loadingRequest: AVAssetResourceLoadingRequest
    /// Exclusive end of the byte range this loading request wants; nil means
    /// "all data to the end of the resource".
    var windowEndExclusive: Int64?
    var dataTask: URLSessionDataTask?
    var statusCode = 0
    /// Absolute offset the in-flight fetch must resume from when the upstream
    /// answers with an undifferentiated 200 instead of honoring Range.
    var requestSkipTo: Int64 = 0
    /// Bytes dropped from the head of a 200 response so far.
    var skippedBytes = 0
    /// Offset the in-flight upstream fetch started at.
    var fetchStart: Int64 = 0
    /// Media bytes received within the in-flight fetch, excluding any skipped
    /// 200-prefix. Chaining resumes from fetchStart + mediaReceived.
    var mediaReceived: Int64 = 0
    /// The next-window fetch started early while this one is still streaming,
    /// so its TTFB overlaps this window's transfer instead of serializing
    /// behind it. Guarded against double-start.
    var prefetchStarted = false
    /// The in-flight next-window task, if prefetch has fired.
    var prefetchTask: URLSessionDataTask?
    /// Bytes already received from the prefetch window, replayed to the
    /// reader once the main window completes and the prefetch is adopted.
    var prefetchBuffer: [UInt8] = []
    /// The prefetch response is a 206 whose bytes provably start at
    /// `prefetchStart`; cleared by any prefetch failure or cancellation.
    /// Completion alone does not clear it: the prefetch may finish before
    /// the main window, and its buffer must survive until adoption.
    var prefetchUsable = false
    /// Absolute offset the prefetch window starts at.
    var prefetchStart: Int64 = 0
    /// Bytes received within the currently streaming fetch (main or
    /// prefetch-drain), used to time the half-window prefetch trigger.
    var receivedThisFetch = 0
    var finished = false

    /// AVFoundation may have cancelled this request before our queued block
    /// runs; finishing a cancelled request crashes, so defer to isFinished.
    func finish(with error: NSError? = nil) {
      guard !finished, !loadingRequest.isFinished else {
        finished = true
        return
      }
      finished = true
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
    // Hard cap for one fetch window's lifetime.
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
        record.dataTask?.cancel()
      }
      self.session.invalidateAndCancel()
    }
  }

  // MARK: - Fetch plumbing

  private func record(for task: URLSessionTask) -> RequestRecord? {
    pending.values.first { $0.dataTask === task || $0.prefetchTask === task }
  }

  private func remove(_ record: RequestRecord) {
    pending.removeValue(forKey: ObjectIdentifier(record.loadingRequest))
  }

  private func finishAndRemove(
    _ record: RequestRecord, error: NSError? = nil, cancelTask: Bool = true
  ) {
    record.finish(with: error)
    remove(record)
    if cancelTask {
      record.dataTask?.cancel()
      record.prefetchTask?.cancel()
    }
    record.dataTask = nil
    record.prefetchTask = nil
  }

  private func upstreamRequest(range: String) -> URLRequest {
    var request = URLRequest(url: targetURL)
    request.httpMethod = "GET"
    request.setValue(range, forHTTPHeaderField: "Range")
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  /// Starts one bounded upstream window beginning at `offset`.
  private func beginFetch(_ record: RequestRecord, from offset: Int64) {
    record.fetchStart = offset
    record.mediaReceived = 0
    record.skippedBytes = 0
    record.requestSkipTo = offset
    record.receivedThisFetch = 0
    let endInclusive: Int64
    if let windowEnd = record.windowEndExclusive {
      endInclusive = min(windowEnd - 1, offset + Self.fetchWindowBytes - 1)
    } else {
      endInclusive = offset + Self.fetchWindowBytes - 1
    }
    let task = session.dataTask(
      with: upstreamRequest(range: "bytes=\(offset)-\(endInclusive)"))
    record.dataTask = task
    task.resume()
  }

  /// Starts the next window while the current one is still streaming.
  ///
  /// Serial chaining paid the full upstream TTFB (2.5-4 s measured on real
  /// sites) between every 2 MB window. Issuing the next window once the
  /// current one has delivered half its bytes hides that latency behind the
  /// ongoing transfer: by the time the main window finishes, the next one is
  /// already streaming through — and being cached by — the Dart proxy, so
  /// chaining adopts it instead of paying a fresh TTFB.
  private func maybeBeginPrefetch(_ record: RequestRecord) {
    guard !record.prefetchStarted, record.prefetchTask == nil,
      let task = record.dataTask else { return }
    // Only overlap while the current fetch is actually streaming; a finished
    // or failed task chains through advanceAfterCompletedFetch instead.
    guard task.state == .running else { return }
    if let windowEnd = record.windowEndExclusive,
      record.fetchStart + Self.fetchWindowBytes >= windowEnd {
      return
    }
    let plannedEnd: Int64
    if let windowEnd = record.windowEndExclusive {
      plannedEnd = min(windowEnd - 1, record.fetchStart + Self.fetchWindowBytes - 1)
    } else {
      plannedEnd = record.fetchStart + Self.fetchWindowBytes - 1
    }
    let received = Int64(record.receivedThisFetch)
    let expected = plannedEnd - record.fetchStart + 1
    guard received * 2 >= expected else { return }
    record.prefetchStarted = true
    let nextOffset = record.fetchStart + Self.fetchWindowBytes
    record.prefetchStart = nextOffset
    record.prefetchUsable = false
    let prefetchTask = session.dataTask(
      with: upstreamRequest(range: "bytes=\(nextOffset)-\(nextOffset + Self.fetchWindowBytes - 1)"))
    record.prefetchTask = prefetchTask
    prefetchTask.resume()
  }

  /// Metadata-only probes fetch exactly two bytes: the Content-Range tail
  /// carries the total length, and the tiny response still warms the Dart
  /// proxy's container-head cache. HEAD is avoided because it never writes
  /// the proxy cache.
  private func beginProbe(_ record: RequestRecord) {
    record.fetchStart = 0
    record.mediaReceived = 0
    record.skippedBytes = 0
    record.requestSkipTo = 0
    let task = session.dataTask(with: upstreamRequest(range: "bytes=0-0"))
    record.dataTask = task
    task.resume()
  }

  /// Chains the next window after a fully received one, or finishes the
  /// record when the media really ended.
  private func advanceAfterCompletedFetch(_ record: RequestRecord) {
    guard let dataRequest = record.loadingRequest.dataRequest else {
      finishAndRemove(record)
      return
    }
    let plannedEnd: Int64
    if let windowEnd = record.windowEndExclusive {
      plannedEnd = min(windowEnd - 1, record.fetchStart + Self.fetchWindowBytes - 1)
    } else {
      plannedEnd = record.fetchStart + Self.fetchWindowBytes - 1
    }
    let expected = plannedEnd - record.fetchStart + 1
    if record.mediaReceived < expected {
      // Upstream ended before the planned window: this is the end of media.
      finishAndRemove(record)
      return
    }
    if let windowEnd = record.windowEndExclusive,
      dataRequest.currentOffset >= windowEnd {
      finishAndRemove(record)
      return
    }
    let nextOffset = record.fetchStart + record.mediaReceived
    if record.prefetchUsable, nextOffset == record.prefetchStart {
      // Adopt the prefetched window as the new main window: its TTFB was
      // paid during the previous transfer, so chaining is latency-free.
      // Buffered bytes are replayed to the reader first; any still-in-flight
      // prefetch task becomes the main data task.
      record.dataTask?.cancel()
      record.dataTask = record.prefetchTask
      record.prefetchTask = nil
      record.fetchStart = nextOffset
      record.skippedBytes = 0
      record.requestSkipTo = nextOffset
      record.statusCode = 206
      record.receivedThisFetch = 0
      record.prefetchStarted = false
      record.prefetchUsable = false
      let buffered = record.prefetchBuffer
      record.prefetchBuffer = []
      record.mediaReceived = Int64(buffered.count)
      if !buffered.isEmpty {
        var sent = 0
        while sent < buffered.count {
          var remaining = Int64.max
          if let windowEnd = record.windowEndExclusive {
            remaining = windowEnd - dataRequest.currentOffset
          }
          if remaining <= 0 { break }
          let chunkLength = min(
            Self.respondChunkBytes, buffered.count - sent, Int(remaining))
          dataRequest.respond(with: Data(buffered[sent..<sent + chunkLength]))
          sent += chunkLength
        }
        maybeBeginPrefetch(record)
        if let windowEnd = record.windowEndExclusive,
          dataRequest.currentOffset >= windowEnd {
          finishAndRemove(record)
          return
        }
      }
      if record.dataTask == nil {
        // The adopted prefetch had already completed before the main window,
        // so no completion callback will fire for this window; drive the
        // chain forward right now (bounded by media length).
        advanceAfterCompletedFetch(record)
      }
      return
    }
    // Adoption did not apply (no usable prefetch or offset mismatch): drop
    // the leftover prefetch so the fresh fetch does not race a duplicate of
    // the same range.
    record.prefetchTask?.cancel()
    record.prefetchTask = nil
    record.prefetchBuffer = []
    record.prefetchUsable = false
    beginFetch(record, from: nextOffset)
  }

  /// Finishes reads that the newest read head has provably moved past.
  ///
  /// Bounded windows ending at/below the new offset are done by definition.
  /// Older open-ended crawlers starting at/below the new offset are redundant:
  /// the newest request reflects AVFoundation's current position, and the
  /// bytes they would still deliver were already streamed through (and cached
  /// by) the Dart proxy. Leaving them running multiplied upstream traffic.
  private func supersedeStaleRecords(newOffset: Int64, keep: RequestRecord) {
    for (key, other) in pending where other !== keep && !other.finished {
      let stale: Bool
      if let windowEnd = other.windowEndExclusive {
        stale = windowEnd <= newOffset
      } else {
        stale = other.fetchStart <= newOffset
      }
      if stale {
        remove(other)
        other.finish()
        other.dataTask?.cancel()
        other.prefetchTask?.cancel()
        other.dataTask = nil
        other.prefetchTask = nil
      }
    }
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
  /// falling back to Content-Length only for a plain 200. Never guesses: a
  /// wrong length breaks tail probing or hangs the reader.
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
    info.isByteRangeAccessSupported = true
    info.contentType = contentTypeIdentifier(from: response)
    // Leave contentLength untouched when unknown rather than guessing: a wrong
    // length breaks tail probing or hangs the reader.
    if let length = Self.totalLength(from: response, rangeRequested: response.statusCode == 206) {
      info.contentLength = length
    }
  }
}

extension IOSMediaResourceLoader: AVAssetResourceLoaderDelegate {
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    let record = RequestRecord(loadingRequest: loadingRequest)

    if let data = loadingRequest.dataRequest {
      record.windowEndExclusive = data.requestsAllDataToEndOfResource
        ? nil : data.requestedOffset + Int64(data.requestedLength)
      pending[ObjectIdentifier(loadingRequest)] = record
      supersedeStaleRecords(newOffset: data.currentOffset, keep: record)
      beginFetch(record, from: data.currentOffset)
    } else if loadingRequest.contentInformationRequest != nil {
      pending[ObjectIdentifier(loadingRequest)] = record
      beginProbe(record)
    } else {
      // Nothing answerable; do not strand AVFoundation waiting.
      record.finish()
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
      record.prefetchTask?.cancel()
      record.dataTask = nil
      record.prefetchTask = nil
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
      if dataTask === record.prefetchTask {
        // A prefetch failure must not tear down the live loading request.
        guard let http = response as? HTTPURLResponse else {
          completionHandler(.cancel)
          record.prefetchUsable = false
          record.prefetchBuffer = []
          return
        }
        record.prefetchUsable = http.statusCode == 206
        completionHandler(.allow)
        return
      }
      guard let http = response as? HTTPURLResponse else {
        completionHandler(.cancel)
        finishAndRemove(
          record,
          error: NSError(
            domain: "AIVPMediaResourceLoader", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "流式代理响应不是 HTTP 响应"]
          ))
        return
      }
      record.statusCode = http.statusCode
      fillContentInformation(record, response: http)
      if record.loadingRequest.dataRequest == nil {
        // Metadata-only request satisfied by the response headers.
        completionHandler(.cancel)
        finishAndRemove(record)
        return
      }
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    queue.async { [weak self] in
      guard let self, let record = self.record(for: dataTask), !record.finished else { return }
      if dataTask === record.prefetchTask {
        // Buffer the prefetch window; it is replayed to the reader when the
        // main window completes and the prefetch is adopted as the next one.
        record.prefetchBuffer.append(contentsOf: data)
        return
      }
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
        payload.removeFirst(need)
        record.skippedBytes += need
      }
      record.mediaReceived += Int64(payload.count)
      record.receivedThisFetch += payload.count
      var sent = 0
      while sent < payload.count {
        var remaining = Int64.max
        if let windowEnd = record.windowEndExclusive {
          remaining = windowEnd - dataRequest.currentOffset
        }
        if remaining <= 0 { break }
        let chunkLength = min(Self.respondChunkBytes, payload.count - sent, Int(remaining))
        dataRequest.respond(with: Data(payload[sent..<sent + chunkLength]))
        sent += chunkLength
      }
      maybeBeginPrefetch(record)
      if let windowEnd = record.windowEndExclusive,
        dataRequest.currentOffset >= windowEnd {
        // The reader has everything this loading request asked for; stop the
        // upstream window instead of draining it to EOF.
        finishAndRemove(record)
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    queue.async { [weak self] in
      guard let self, let record = self.record(for: task) else { return }
      if task === record.prefetchTask {
        // A failed prefetch is dropped: chaining falls back to a fresh
        // beginFetch. A clean completion keeps the buffer and usability flag
        // intact because the prefetch may legitimately finish before the
        // main window; adoption happens in advanceAfterCompletedFetch.
        record.prefetchTask = nil
        if let error {
          record.prefetchUsable = false
          record.prefetchBuffer = []
        }
        return
      }
      if let error {
        finishAndRemove(record, error: Self.enrichedError(error))
        return
      }
      advanceAfterCompletedFetch(record)
    }
  }
}
