# Repository Guidelines

## Project Structure

Infinite Remote is a Swift 6 macOS app targeting macOS 14 and later.

- `Sources/RemoteCore/` holds Foundation-only configuration, input state, and media grid logic.
- `Sources/RemoteDesk/` contains the SwiftUI and AppKit app, HID monitoring, system actions, and Codex dictation. Its `Resources/` directory holds asset catalogs and remote model packages. Use `RemoteModels/xiaomi-2-pro/` within that directory as the model package reference.
- `Tests/RemoteCoreTests/` and `Tests/RemoteDeskTests/` mirror the SwiftPM targets. See `docs/` for platform and device guides, `designs/` for prototypes and icon sources, and `scripts/` for app packaging.

## Build, Test, and Run

Use Xcode or Command Line Tools with Swift 6. Run these commands from the repository root.

- `swift build` compiles the debug targets.
- `swift test` runs both test targets. Use `swift test --filter RemoteDeskTests` for app tests.
- `./scripts/build-app.sh` builds, signs, and verifies the release app in `dist/`.
- `open "dist/Infinite Remote.app"` launches the packaged app for desktop checks.

For repeated hardware testing, use a consistent `REMOTEDESK_SIGNING_IDENTITY` to retain macOS privacy grants across rebuilds. HID listening requires Input Monitoring. System shortcuts and accessibility-driven actions require Accessibility access.

## Coding Style

Use four-space indentation, UpperCamelCase types, and lowerCamelCase properties and methods. Keep AppKit, SwiftUI, and IOKit dependencies in `RemoteDesk`. Reuse shared views and handle page layout in their containers. Preserve shared components’ fields, layout, and behavior unless the change explicitly calls for updating their contract.

## Testing

Use Swift Testing with `@Test`, `#expect`, and descriptive names such as `heldKeysDoNotRetriggerAndReleasesKeepThePressedValue`. Mark tests that interact with main-actor app state `@MainActor`. Cover changed input and configuration behavior in the owning target, including migration when persisted data changes. For HID changes, also verify the affected press and release behavior with a paired remote.

## Commits and Pull Requests

Use short imperative commit subjects, following examples such as “Add remote model packages and refine remote interactions.” In pull requests, describe the behavior change, link related issues when available, and list automated and manual checks performed. Include screenshots for visible changes.
