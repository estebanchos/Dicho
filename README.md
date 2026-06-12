# Dicho

On-device macOS dictation utility. Double-tap Ctrl, speak, and polished
text is inserted at your cursor in any app — Mail, Slack, Xcode, browser,
terminal. No network calls, ever.

## Requirements

- macOS 26 or later
- Apple Silicon Mac
- Apple Intelligence enabled

## Permissions

Dicho requests three permissions on first launch:

- **Microphone** — to capture your speech
- **Accessibility** — to monitor the hotkey and insert text via synthetic paste
- **Speech model** — on-device model downloaded via Apple's asset system

## Building

Open `Dicho.xcodeproj` in Xcode 26+, select the **Dicho** scheme, and run.

No third-party dependencies. No package resolution step needed.

## Known limitations

- Secure input fields (e.g. password fields, some terminal apps with secure
  input enabled) block synthetic paste — text lands in your clipboard instead.
- Clipboard manager apps may briefly see the dictated text during the paste
  window before the clipboard is restored.
- English (en-US) only in v0.
