# STD — Speed Test

A minimal, dark-themed **download speed tester** built with Flutter. Uses multi-threaded HTTP streaming to measure your real-world download bandwidth.

---

## Features

- **Multi-threaded download** — 1 to 32 parallel threads for accurate measurement
- **Live speed gauge** — real-time Mbps updated every 500ms
- **Stats panel** — Live, Peak, and Average speed displayed simultaneously
- **Configurable test duration** — 5s to 30s with quick presets
- **Data usage counter** — shows total bytes downloaded during the test
- **Dark UI** — clean, minimal interface with red accent colors

---

## Tech Stack

| Layer       | Details                              |
|-------------|--------------------------------------|
| Framework   | Flutter 3.44+                        |
| Language    | Dart 3.8+                            |
| HTTP        | `package:http` (streaming)           |
| Test server | Hetzner public speed test endpoint   |
| Target      | Android (arm64-v8a), iOS, Web, Desktop |

---

## Getting Started

### Prerequisites

- Flutter **3.44.1** or later ([install guide](https://docs.flutter.dev/get-started/install))
- Dart SDK **3.8.0+** (bundled with Flutter)
- Android Studio / Xcode for mobile targets

### Run locally

```bash
git clone https://github.com/devfahim00/STD.git
cd STD
flutter pub get
flutter run
```

### Build release APK (Android arm64)

```bash
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

Output: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

---

## GitHub Actions — Build Workflow

The repo includes a manual workflow to build a signed-debug release APK.

**Trigger:** Go to **Actions → Build Android APK (arm64-v8a) → Run workflow**

| Input          | Default | Description                     |
|----------------|---------|---------------------------------|
| `version_name` | `1.0.0` | Version string shown in the APK |
| `version_code` | `1`     | Integer version code            |

The built APK is uploaded as a workflow artifact and kept for **30 days**.

> **Note:** The workflow requires Flutter **3.44.1** (Dart 3.8+). Older Flutter versions will fail at `flutter pub get` because `flutter_lints: ^6.0.0` requires Dart `^3.8.0`.

---

## Project Structure

```
lib/
└── main.dart          # Entire app — SpeedController + UI widgets

android/               # Android platform config
assets/
└── logo.png           # App logo

.github/workflows/
└── build.yml          # CI: manual APK build workflow
```

---

## How It Works

1. On test start, `SpeedController` spawns N parallel `http.Client` instances.
2. Each client streams `100MB.bin` from Hetzner's public speed endpoint in a continuous loop until the timer ends.
3. Every 500ms, a ticker samples the total bytes downloaded and calculates the current Mbps: `(delta_bytes × 8) / 500_000`.
4. On finish, average speed is computed as `(total_bytes × 8) / (duration_seconds × 1_000_000)`.

---

## Dependencies

```yaml
dependencies:
  flutter:
    sdk: flutter
  http: ^1.2.1          # HTTP streaming

dev_dependencies:
  flutter_lints: ^6.0.0 # Lint rules (requires Dart ^3.8.0)
```

---

## License

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE) for details.
