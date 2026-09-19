# Dictator for Windows

A hold-to-talk dictation app for Windows. It mirrors the macOS app's model: press
and hold a global hotkey, talk, release — the audio is transcribed and cleaned up by
the shared Cloudflare backend, and the final text is typed into whatever window has
focus.

This is a C# / .NET 8 background tray app (WinForms `NotifyIcon`). It reuses the exact
same backend contract, prompts, and cleanup safety net as the iOS/macOS clients.

## How it works

1. A **low-level keyboard hook** (`WH_KEYBOARD_LL`) watches for the hold-to-talk key
   system-wide. Key-down starts recording; key-up stops it. (A press shorter than
   150 ms is treated as an accidental brush and discarded.)
2. The microphone is captured with **NAudio** directly at **16 kHz / mono / 16-bit
   PCM** — Windows resamples for us, so there is no manual resampling.
3. On release the PCM is silence-trimmed, wrapped in a 44-byte WAV header, and POSTed
   as `multipart/form-data` to `POST /v1/dictate` on the backend, together with the
   cleanup **system prompt** for the selected mode and a stable `X-Device-Id` header.
4. The backend returns `{ raw, text, cleaned }`. A local **safety net**
   (`Cleaner.Reconcile`) decides whether to inject the cleaned text or fall back to
   the raw transcript (it falls back if the cleanup is empty, looks like a refusal,
   dropped too much, ballooned, or diverged from the words actually said).
5. The final text is typed into the focused window with **`SendInput`** using
   `KEYEVENTF_UNICODE` (this does **not** touch the clipboard).

### Why a low-level hook and not `RegisterHotKey`?

`RegisterHotKey` only signals a key *press* (a single `WM_HOTKEY`); it gives you no
key-up event, so you cannot measure how long a key is held. Dictator is hold-to-talk,
so it must see both the down and the up edge. `WH_KEYBOARD_LL` sees every key event
system-wide, which lets it drive start/stop the way the Mac's `CGEventTap` does. It
also lets the app optionally swallow the trigger key so the focused app never sees it.

## Backend

Base URL (from `Sources/DictationCore/Backend.swift`):

```
https://dictator-backend.jeremydirons.workers.dev
```

`POST /v1/dictate` — `multipart/form-data`:

| field           | value                                             |
| --------------- | ------------------------------------------------- |
| `file`          | the WAV (16 kHz mono PCM16), filename `audio.wav`  |
| `model`         | `whisper-large-v3-turbo`                           |
| `language`      | `en`                                              |
| `system`        | cleanup system prompt (`base + "\n\n" + mode`)    |
| `prompt`        | optional vocabulary bias (`Vocabulary: a, b, c`)  |
| `cleanup_model` | optional (not sent by v1)                          |

Header: `X-Device-Id: <stable per-install GUID>` (random, not personally identifying;
persisted in the settings file). Response JSON: `{ raw, text, cleaned }`.

## Modes

Selectable from the tray menu. Prompts are ported verbatim from `ToneProfile.swift`:

`super casual`, `Casual`, `Formal`, `Expressive`, `Emoji`, `Patois`, `Shakespearean`.

`Patois` and `Shakespearean` deliberately rewrite the speaker's *words*, so the
word-fidelity guards in the safety net are skipped for them (only the empty/refusal
guards still apply) — matching `DictationMode.transformsWording` and
`Cleaner.reconcile` on the other platforms.

## Build

Requires the .NET 8 SDK on Windows (the `net8.0-windows` target and WinForms need the
Windows Desktop targeting pack, so this builds on Windows, not Linux/macOS).

```powershell
cd windows
dotnet build

# Single-file, self-contained release (no .NET install needed on the target machine):
dotnet publish -c Release -r win-x64 --self-contained `
    -p:PublishSingleFile=true
```

Run the produced `Dictator.exe`. It starts in the system tray (no window). Hold the
hotkey (default **Right Ctrl**) to talk; release to insert the text. Right-click the
tray icon to pick a mode, toggle sounds, or quit.

## Configuration

Settings live in `%APPDATA%\Dictator\settings.json`:

- `deviceId` — the stable `X-Device-Id` (created once).
- `mode` — selected dictation mode.
- `hotkeyVk` — virtual-key code of the hold-to-talk key (default `0xA3`, Right Ctrl).
  Other handy values: `0x77` (F8), `0xA5` (Right Alt), `0x14` (Caps Lock).
- `playSounds` — start/stop cue sounds.

There is no in-app hotkey picker yet; edit `hotkeyVk` in the JSON to change the key.

## What's stubbed / limitations (v1)

- **Cloud-only transcription.** Unlike the Mac (which runs Parakeet locally), Windows
  v1 always transcribes via the backend. On-device transcription (e.g. bundling
  `whisper.cpp`) is a future add — there is no local `SpeechProvider` here yet.
- **No BYOK path.** The macOS/iOS apps can talk to Groq directly with a user-supplied
  key; Windows v1 only uses the shared backend proxy.
- **No per-app tone profiles.** The other clients infer a tone profile from the
  frontmost app's bundle id and combine it with the hand-picked mode. Windows v1 uses
  only the hand-picked mode (`base + "\n\n" + mode.instructions`). Per-app profiles
  (keyed off `GetForegroundWindow` → process name) are a future add.
- **No live level meter / floating waveform.** Feedback is the tray icon color (gray
  idle, red while recording) plus optional start/stop sounds.
- **Elevated windows.** A low-level hook and `SendInput` from a normal-integrity
  process cannot capture the hotkey in, or type into, a window owned by an elevated
  (admin) process. Running Dictator as admin would flip the problem. This is an
  inherent Windows UIPI limitation, not a bug.
- **Tray icons are generated at runtime** (a colored dot). Shipping a proper `.ico`
  is a polish TODO.

## TODOs

- Code signing (Authenticode) for distribution, so SmartScreen does not warn.
- Autostart (register under `HKCU\...\Run` or a Startup shortcut), with a toggle.
- In-app hotkey picker and a small settings window.
- Optional on-device transcription (whisper.cpp) for an offline/private tier.
- Per-app tone profiles via the foreground window's process.
- A proper app icon set.
