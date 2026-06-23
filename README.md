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
