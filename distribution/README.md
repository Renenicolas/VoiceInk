# Local Dictation — install guide

A fully private voice-to-text app for your Mac. Hold a key, talk, release —
clean written text appears wherever your cursor is, in about a second. Works in
every app (email, Slack, docs, browsers). **Everything runs on your own Mac**:
no cloud, no account, no subscription, and nothing you say ever leaves the machine.

Under the hood: NVIDIA's Parakeet speech model on the Neural Engine (~0.2s
transcription) + Apple Intelligence's built-in model for cleanup (~0.8s, zero
memory footprint — it removes the "um"s, fixes punctuation, keeps your meaning).

## What you need
- Apple Silicon Mac (M1 or newer)
- **macOS 26+** with **Apple Intelligence turned on**
  (System Settings → Apple Intelligence & Siri)
- ~1 GB free disk, 10 minutes

## Install (one command)

1. Open **Terminal** (`⌘ + Space`, type `terminal`, Return).
2. Paste and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/Renenicolas/VoiceInk/main/distribution/install.sh | bash
```

3. When it finishes it lists the **two permission switches**:
   - **Microphone** → click Allow on the popup
   - **Accessibility** → System Settings → Privacy & Security → Accessibility → turn **VoiceInk** on

## Using it

Cursor in any text field → **hold Right Option (⌥)** → speak naturally (ums and
uhs are fine) → **release**. Short phrases paste almost instantly; longer
dictations take about a second while the cleanup runs.

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing happens on Right Option | Privacy & Security → Accessibility → toggle VoiceInk off/on, then quit + reopen the app |
| Text pastes but with the ums left in | Apple Intelligence is off — System Settings → Apple Intelligence & Siri → turn it on |
| Words are wrong | Speak a touch louder/closer; check System Settings → Sound → Input level moves when you talk |
| Pasted into the wrong window | Click into the target text field *before* holding the key |

## Optional: "max quality" cleanup (24GB+ Macs)

`bash install.sh --with-ollama` additionally installs Ollama + a 7B cleanup
model (~5GB). Switch VoiceInk's enhancement provider to Ollama when you want
maximum fidelity on long dictations; it's slower and uses real RAM, so the
default Apple Intelligence path is right for most machines.

## Uninstall

```bash
osascript -e 'tell application "VoiceInk" to quit'
rm -rf /Applications/VoiceInk.app ~/.voiceink-local
rm -rf ~/Library/Application\ Support/FluidAudio
```
