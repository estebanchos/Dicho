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

## Installing

Dicho is distributed as a notarized, Developer ID-signed app via direct
download (not the Mac App Store — the sandbox prohibits the global event
tap and synthetic paste the core loop depends on).

1. Download `Dicho.zip` and unzip it.
2. Drag **Dicho.app** into `/Applications`.
3. Launch Dicho. Because the build is notarized, Gatekeeper opens it without
   the right-click-to-open workaround.
4. The onboarding window walks you through the three required permissions
   (Microphone, Accessibility, Speech model). The app is functional once all
   three are green.

Dicho lives in the menu bar (there is no Dock icon). Double-tap **Ctrl** to
start dictating, tap **Ctrl** once to stop, **Esc** to cancel.

## Privacy

Dicho makes **no network calls**. All transcription (Apple
SpeechAnalyzer / SpeechTranscriber) and cleanup (Apple Foundation Models)
runs entirely on-device. Dictated audio and text never leave your Mac and
are never persisted or logged — only your settings are saved (in
`UserDefaults`). The only network activity Dicho can trigger is the
operating system's own one-time download of the on-device speech model,
performed by macOS (not by Dicho) via Apple's asset system.

## Building

Open `Dicho.xcodeproj` in Xcode 26+, select the **Dicho** scheme, and run.

No third-party dependencies. No package resolution step needed.

## Dictation tips

Dicho's cleanup pass is powered by Apple's on-device Foundation Models.
The model handles natural prose well but is most reliable when given
explicit, deliberate markers for self-corrections. Two correction phrases
work consistently across all apps:

- **"no wait"** — *"Let's meet Tuesday, no wait, Friday"* → *"Let's meet Friday."*
- **"correction"** — *"The meeting is Tuesday, correction, the meeting is Wednesday"* → *"The meeting is Wednesday."*

A third deliberate marker is also recognized in the prompt; it works in many
cases but less consistently than the two above:

- **"scratch that"** — *"Buy milk, scratch that, buy bread"* → *"Buy bread."*

Other natural self-corrections (a bare *"X, no Y"*, or *"X, actually Y"*)
are not reliably detected by the current on-device model. If a correction
isn't applied, re-dictate with one of the markers above.

Cleanup is also context-aware: Dicho passes a one-sentence hint about the
frontmost app to the model (e.g. *"this is a screenwriting app, preserve
scene headings"*, *"this is a code editor, preserve identifiers"*). The
hint is advisory — on the current on-device model the prose categories
(messaging, email, notes) see the strongest benefit; the code/terminal
hints are weaker. You can bypass cleanup entirely with **Raw mode** in
the menu-bar menu or Settings.

## Known limitations

- Secure input fields (e.g. password fields, some terminal apps with secure
  input enabled) block synthetic paste — text lands in your clipboard instead.
- Clipboard manager apps may briefly see the dictated text during the paste
  window before the clipboard is restored.
- English (en-US) only in v0.
- Some browser text areas (Gmail compose, Notion, Linear, etc.) don't
  expose the standard accessibility roles Dicho expects; in those cases
  the dictation lands on the clipboard for manual paste.
