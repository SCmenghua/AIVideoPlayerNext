# Architecture

The application is organized around contracts in `app/lib/domain`. Platform adapters belong under `native/plugins` and are assembled in `app/lib/app`.

```text
UI -> Riverpod controllers -> domain contracts -> platform or mock adapters
                                  |
                                  +-> SubtitleTimeline
                                  +-> TranslationService
```

`SubtitleTimeline` is a pure Dart module. Recognition events carry media timestamps and a session identifier so asynchronous work can be discarded after a seek or media switch.

## Network media pipeline

All consumers of one network media file share a single loopback download
session. `SharedNetworkMediaBroker` (`app/lib/features/player`) keys one
`RecognitionMediaCacheWorker` session per remote URI; libmpv playback and the
recognition audio decoder both open `http://127.0.0.1:<port>/media.<ext>`
instead of the remote URL, and the worker injects browser authorization
headers (Referer, Cookie) upstream.

Inside the worker a single-flight filler keeps at most one upstream GET
(`bytes=N-` open-ended) at any time, streaming into a bounded segment cache
(256 MiB). Loopback clients are served from that growing cache, so a
throttled origin is asked exactly once per byte. Demands behind the live
download frontier preempt the running fill (player seeks win); stalled
upstreams resume from the last cached byte; origins without Range support
fall back to a transparent sequential proxy path. Proxied playback that
fails to start falls back to direct playback of the original URL.

The recognition controller joins the shared session via `borrowFor` and
falls back to a full-media download (completed local file) only when the
platform decoder cannot open the loopback source.

