# Infinite Remote App

[Official website](https://szhjia.github.io/infinite-remote-website/en/) · [中文版本](README.zh-CN.md)

Control macOS and your selected applications with independently installed remote model packages. Xiaomi Bluetooth Remote 2 Pro (`2717:32B8`) is the first supported model. Infinite Remote supports macOS 14 and later, and uses the system's Liquid Glass toolbar controls on macOS 26 and later.

The GitHub repository is `szhjia/infinite-remote-app`.

## Release v0.0.3

Download the DMG from [GitHub Releases](https://github.com/szhjia/infinite-remote-app/releases/tag/v0.0.3), open it, and drag Infinite Remote to Applications. The published build requires an Apple silicon Mac with macOS 14 or later. See the [release notes](RELEASE_NOTES.md) for signing details. To build a ZIP archive, run `./scripts/package-release.sh`.

Install this version manually once to enable future updates through **Check for Updates…**.

## Usage

1. Launch `dist/Infinite Remote.app`. New installations contain no real remote models. The skippable setup walks through adding a model, Input Monitoring, Accessibility, and a connection check; reopen it from Settings at any time. The interface follows the system language, with English fallback.
2. Open Library in the sidebar. Install a model from a working subscription, or choose Import ZIP to select a local ZIP directly; an unpacked model folder also works. No extraction step is needed for ZIP import. Installed models appear in the sidebar and remain available offline, even while disconnected.
3. Pair the remote in macOS Bluetooth settings and select its installed model. Start with Accessibility. If the app still cannot read buttons, grant Input Monitoring separately. Return to the app to recheck, and reopen it if macOS asks.
4. Select a single-press, double-press, or long-press action and click Save. For an unrecognized signal, select the row and choose Calibrate current key manually from the menu beside Restore Defaults. Model-supplied default actions can be saved as named configurations; user mappings and learned inputs remain separate from installed resources.
5. Pause responses from the toolbar. The workbench title bar controls the floating remote model. Use the model’s top-left button or context menu to open or close the workbench. When the workbench first opens, the menu bar icon appears and can reopen either window separately. Diagnostics report press/release events and suspend the app’s own configured actions.
6. Open Settings → Media Settings to choose up to nine local applications. With the Xiaomi package defaults, Live opens the selector; Left/Right navigate, OK opens and Back closes. The menu beside Restore Defaults provides personal configuration selection, import and export.

Settings manages HTTPS subscriptions independently of installed remotes. Refresh checks the catalog; install and update are explicit actions. A model can only be updated to a higher release from the same source, including local ZIP imports owned by the local source. Another source cannot replace it. Removing a subscription leaves its installed models in place; a failed refresh keeps the last successful catalog.

The official source URL is preconfigured as `https://raw.githubusercontent.com/szhjia/infinite-remote-hub/main/catalog.json`. The public source provides the catalog, model ZIPs and artwork independently of app releases. Refresh it in the resource library to install supported models. Local ZIP import works independently; the app build never publishes source content.

The following defaults come from the Xiaomi v2 package, rather than the application engine:

| Physical button | Default action |
| --- | --- |
| Power | Single press turns off an external display that supports DDC/CI power control and reduces the built-in display to minimum brightness. Press again to restore built-in brightness and then attempt to wake the external display. Long press locks the screen immediately. |
| Voice | Codex dictation |
| Direction | ↑ ↓ ← → |
| OK | Return |
| Back | Esc |
| Home | Bring the package’s target application to the foreground (initially Codex) |
| Volume up/down | Adjust system volume |
| Menu | Open the running-application switcher |
| Live | Media application selector |

In ChatGPT settings, set Dictation Shortcut to F5. If “Press once to dictate” is bound to Return, remove that binding. Focus the Codex input, hold the remote's microphone button while speaking, release it, and wait for the text to appear. You can configure OK as `⌘Return` to send the transcription. F5 is received directly by ChatGPT; Infinite Remote's pause and diagnostics modes only affect Infinite Remote's own actions.

“Choose system shortcut” reads only combinations currently enabled in macOS. Change a combination in System Settings, return to Infinite Remote, and refresh the selection. Buttons without an assigned action, including volume buttons, can continue to be handled by macOS. Infinite Remote listens to HID non-exclusively, so a configured action may run alongside the remote's original system behavior.

Configuration is stored in `~/Library/Application Support/RemoteDesk/configuration.json`. When migrating from an older version, the app keeps a backup of the original configuration in the same directory.

## Development and Build

Use Xcode or Command Line Tools with Swift 6:

```sh
swift build
swift test
./scripts/build-app.sh
open "dist/Infinite Remote.app"
```

The build script produces an app bundle for the local architecture. It uses ad hoc signing by default, and macOS may request Input Monitoring and Accessibility access again after the binary changes. For repeated testing with a physical remote, inspect available identities with `security find-identity -v -p codesigning`, then build with the same Apple Development identity:

```sh
REMOTEDESK_SIGNING_IDENTITY='Apple Development: Your Certificate Name' ./scripts/build-app.sh
```

You can also write only the certificate fingerprint shown by `security find-identity` to `dist/.signing-identity` for later local builds. An explicitly set environment variable takes precedence.

After switching to a fixed signature, grant permissions again on first launch. Later development builds should continue using the same signing identity and application identifier. See [Platform and input boundaries](docs/architecture.md).

## Remote Model Packages

Open “Show device guide” in the workspace's middle column to view body callouts. Click the body or a callout label to locate the corresponding button configuration. Click the NFC marker to view touch location and hardware notes.

Library → Import ZIP accepts a ZIP or local model folder. Installed resources are copied to `~/Library/Application Support/RemoteDesk/RemoteModels/`. The maintained Xiaomi model, guides and protocol documentation live in the independent Remote Hub repository; real model resources are not bundled in this app. Test-only v1 fixtures remain for backward compatibility.

- `manifest.json` v2 declares stable model/device IDs, a numeric `release`, localized model/brand/summary/capability text, optional package-local PNG logo, default actions, target bundle ID and input behavior. English is required as a fallback; Chinese translations follow system language. Legacy v1 packages remain readable.
- `layout.json` declares PNG dimensions, the visible body rectangle, key names, hotspots and capability anchors. Normalized center/size coordinates are relative to the full PNG, with the origin at the top left. Ellipse, rectangle and sector shapes are supported. Gesture flags create `-double`/`-long` action slots; package updates cannot remove slots used by saved configurations.
- `inputs.json` maps HID collection/page/usage signals to physical key IDs, with optional report/value/array rules. User calibration takes precedence. Defaults and model-specific input behavior come from validated declarations, rather than runtime brand checks.
- A ZIP contains one model folder and its resources. Installation validates paths, images, cross-file references and action declarations before replacing an installation. Downloaded packages must match the catalog hash, identity and release. Source ownership and device conflicts are checked; failed updates preserve the installed package and user configuration.

Use the independent hub’s explicit `export-source --output PATH` command to generate `catalog.json`, `packages/` and `assets/` before publishing a subscription. Building the app does not read a sibling checkout or publish that export.
The [Xiaomi 2 Pro phone guide](docs/xiaomi-2-pro-guide.md) includes body images, pairing steps, and troubleshooting, and can serve as the destination for opening a guide through NFC. The NFC guidance applies to the remote hardware. Infinite Remote does not currently integrate the original NFC tag. To test “tap to open device guide,” first inspect the original tag read-only on a phone, then write the guide's HTTPS URL to a separate removable tag and verify both phone reading and Mac input diagnostics.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=szhjia/infinite-remote-app&type=Date)](https://star-history.com/#szhjia/infinite-remote-app&Date)

## License

Copyright (C) 2026 Infinite Remote contributors.

This project is licensed under the [GNU General Public License, version 3 or (at your option) any later version](LICENSE) (`GPL-3.0-or-later`). Commercial use is permitted. When distributing the software or a derivative work, you must comply with the GPL's corresponding-source and same-license requirements.

Third-party components and artwork retain their original licenses. See the bundled [Tabler license notice](Sources/RemoteDesk/Resources/LICENSE-Tabler.txt).
