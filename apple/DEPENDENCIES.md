# Mac dependency and concurrency review

Review scope: the Mac app, DustpanCore manifest, Xcode project, vendored resources and linked libraries.

## Dependency surface

- **No external Swift packages, binary targets, build plugins or Xcode shell build phases.** DustpanCore
  is a local package; the clients do not download executable code or have an automatic updater.
- **Apple/system modules:** SwiftUI, AppKit, Foundation, Observation, CoreGraphics, CryptoKit, SQLite3,
  UserNotifications, ServiceManagement, UniformTypeIdentifiers and ScreenCaptureKit (Debug screenshots only).
  Framework and SQLite fixes arrive with macOS/Xcode; Dustpan does not bundle independent copies.
- **OpenTodo:** Swift adaptations of protocol and task behavior, plus the copied vocabulary and icon catalogue.
  The tested upstream tag is v0.22.0; its commit is recorded in DEPENDENCIES.json. These are checked-in source
  and data, not a server binary or dynamically fetched SDK. Existing vector tests compare expected behavior.
- **Lucide 1.48.0:** bundled icon paths, names and search metadata, under ISC with Feather MIT attribution.
  Icon SVG paths are parsed locally; scripts, fonts and external references are not loaded from the SVG data.

`DEPENDENCIES.json` records the current resource hashes and reviewed import surface. Updating it means
reviewing the new data's origin, license and content first. A hash match establishes that reviewed files
have not changed; it does not establish the trustworthiness of an upstream author or prove absence of bugs.

```sh
python3 packaging/macos/audit-dependencies.py
python3 packaging/macos/audit-dependencies.py --binary /path/to/Dustpan.app/Contents/MacOS/Dustpan
```

The audit runs in Mac CI and release packaging. It does not query vulnerability databases or claim a full
security audit. OpenTodo server security is a separate boundary; only connect a server you trust.
Tokens currently use the private configuration file, not Keychain, and task databases are not encrypted by
Dustpan. See [PRIVACY.md](../PRIVACY.md) and [SECURITY.md](../SECURITY.md).

## Concurrency review

The app model is explicitly MainActor-isolated. Store, Writer and Syncer are intentionally non-Sendable;
they stay on their caller's actor. The UI's SQLite work remains on the main actor. Network awaits yield
without moving mutable store state into detached tasks. There are no detached tasks or unchecked Sendable
conformances. The icon outline NSCache and immutable regex constants retain narrowly scoped unsafe
annotations for Foundation/standard-library types; they are not a way to share SQLite across threads.

This pass makes sync exclusion independent of the displayed status, serializes account changes, and
checks cancellation before applying a sync response. Cancelled exchanges retain their outbox for an
idempotent retry. Delayed UI tasks stop when cancelled. Live wake-ups have bounded buffering and cancelled
streams stop before processing buffered events. Polling and reminders are app-owned and stop at app quit,
so closing the main window does not stop reminders. First-launch notification permission follows the welcome.

The regression suite covers welcome persistence/upgrades and cancellation without applying a response.
Build with `SWIFT_STRICT_CONCURRENCY=complete`; finish with clean-profile notification/account-switch trials
and a large-data responsiveness check. Complete compiler checking does not prove freedom from logic races
or main-thread stalls.

Reference behavior: Swift's [cooperative cancellation](https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/)
and Apple's [view-task lifetime](https://developer.apple.com/documentation/swiftui/view/task(priority:_:)).
