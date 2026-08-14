# Architecture

The application is organized around contracts in `app/lib/domain`. Platform adapters belong under `native/plugins` and are assembled in `app/lib/app`.

```text
UI -> Riverpod controllers -> domain contracts -> platform or mock adapters
                                  |
                                  +-> SubtitleTimeline
                                  +-> TranslationService
```

`SubtitleTimeline` is a pure Dart module. Recognition events carry media timestamps and a session identifier so asynchronous work can be discarded after a seek or media switch.
