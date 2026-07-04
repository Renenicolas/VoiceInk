#!/bin/bash
# ============================================================
#  Local Dictation — one-command installer (v2)
#
#  Fully private Wispr Flow alternative:
#    ASR      NVIDIA Parakeet V3 on the Neural Engine (~0.2s)
#    Cleanup  Apple Intelligence on-device model (~0.8s, 0 RAM)
#  Nothing you say ever leaves this Mac. No accounts, no cloud.
#
#  Requirements: Apple Silicon, macOS 26+, Apple Intelligence ON.
#  Usage:  bash install.sh            (safe to re-run)
#          bash install.sh --with-ollama   optional 7B "max quality"
#                                          cleanup for 24GB+ Macs
# ============================================================
set -euo pipefail

RELEASE_BASE="${RELEASE_BASE:-https://github.com/Renenicolas/VoiceInk/releases/latest/download}"
DOMAIN="com.prakashjoshipax.VoiceInk"
TOOLS_DIR="$HOME/.voiceink-local"
FLUID_DIR="$HOME/Library/Application Support/FluidAudio/Models"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m%s\033[0m\n' "$*"; exit 1; }

# ---------- 0. Preflight ----------
step "1/6 Checking this Mac"
[[ "$(uname -m)" == "arm64" ]] || die "Requires an Apple Silicon Mac (M1 or newer)."
OSMAJOR=$(sw_vers -productVersion | cut -d. -f1)
[[ "$OSMAJOR" -ge 26 ]] || die "Requires macOS 26 or newer (you have $(sw_vers -productVersion)). Update in System Settings → General → Software Update."
echo "Apple Silicon + macOS $(sw_vers -productVersion) ✓"

# ---------- 1. The app ----------
step "2/6 VoiceInk app"
if [[ ! -d "/Applications/VoiceInk.app" ]]; then
  curl -L --progress-bar -o /tmp/VoiceInk-local.zip "$RELEASE_BASE/VoiceInk-local.zip"
  ditto -xk /tmp/VoiceInk-local.zip /Applications/
  rm -f /tmp/VoiceInk-local.zip
  xattr -cr /Applications/VoiceInk.app 2>/dev/null || true
  echo "Installed /Applications/VoiceInk.app"
else
  echo "VoiceInk.app already installed (leaving it alone)."
fi

# ---------- 2. Apple Intelligence cleanup CLI ----------
step "3/6 Cleanup engine (Apple Intelligence, on-device)"
mkdir -p "$TOOLS_DIR"
curl -L --progress-bar -o "$TOOLS_DIR/voiceink-fm-cleanup" "$RELEASE_BASE/voiceink-fm-cleanup"
chmod +x "$TOOLS_DIR/voiceink-fm-cleanup"
xattr -c "$TOOLS_DIR/voiceink-fm-cleanup" 2>/dev/null || true
# Availability probe: with Apple Intelligence off, the CLI falls back and says so on stderr.
PROBE_ERR=$(VOICEINK_SYSTEM_PROMPT="Return the user text unchanged." \
            VOICEINK_USER_PROMPT=$'\n<USER_MESSAGE>\nprobe\n</USER_MESSAGE>' \
            "$TOOLS_DIR/voiceink-fm-cleanup" 2>&1 >/dev/null || true)
if echo "$PROBE_ERR" | grep -q "apple-intelligence-unavailable"; then
  bold "⚠️  Apple Intelligence is not enabled on this Mac."
  bold "   Turn it on: System Settings → Apple Intelligence & Siri → Apple Intelligence."
  bold "   Dictation will still work, but transcripts won't be cleaned up until it's on."
else
  echo "Apple Intelligence cleanup responding ✓"
fi

# ---------- 3. Speech model (Parakeet V3, ~470MB) ----------
step "4/6 Speech-recognition model"
if [[ ! -d "$FLUID_DIR/parakeet-tdt-0.6b-v3" ]]; then
  mkdir -p "$FLUID_DIR"
  curl -L --progress-bar -o /tmp/parakeet-v3.tar.gz "$RELEASE_BASE/parakeet-tdt-0.6b-v3.tar.gz"
  tar -xzf /tmp/parakeet-v3.tar.gz -C "$FLUID_DIR/"
  rm -f /tmp/parakeet-v3.tar.gz
  echo "Parakeet V3 installed."
else
  echo "Parakeet V3 already present."
fi

# ---------- 4. Configuration ----------
step "5/6 Configuration"
osascript -e 'tell application "VoiceInk" to quit' >/dev/null 2>&1 || true
sleep 1

PROMPT_FILE="$HERE/cleanup-prompt.txt"
[[ -f "$PROMPT_FILE" ]] || { curl -fsSL -o /tmp/cleanup-prompt.txt "https://raw.githubusercontent.com/Renenicolas/VoiceInk/main/distribution/cleanup-prompt.txt"; PROMPT_FILE=/tmp/cleanup-prompt.txt; }

/usr/bin/python3 - "$PROMPT_FILE" "$TOOLS_DIR/voiceink-fm-cleanup" <<'PYEOF'
import json, subprocess, sys

prompt_text = open(sys.argv[1]).read().strip()
cli_path = sys.argv[2]
DOMAIN = "com.prakashjoshipax.VoiceInk"
PROMPT_ID = "22222222-2222-2222-2222-222222222222"
MODE_ID = "11111111-1111-1111-1111-111111111111"

CASUAL_PROMPT_ID = "33333333-3333-3333-3333-333333333333"
PRO_PROMPT_ID    = "44444444-4444-4444-4444-444444444444"
CASUAL_MODE_ID   = "55555555-5555-5555-5555-555555555555"
PRO_MODE_ID      = "66666666-6666-6666-6666-666666666666"

import os, urllib.request
def fetch_variant(name, fallback):
    local = os.path.join(os.path.dirname(sys.argv[1]), name)
    if os.path.exists(local):
        return open(local).read().strip()
    try:
        return urllib.request.urlopen(
            "https://raw.githubusercontent.com/Renenicolas/VoiceInk/main/distribution/" + name,
            timeout=15).read().decode().strip()
    except Exception:
        return fallback

casual_text = fetch_variant("cleanup-prompt-casual.txt", prompt_text)
pro_text = fetch_variant("cleanup-prompt-professional.txt", prompt_text)

custom_prompts = [
    {"id": PROMPT_ID, "title": "Local Cleanup", "promptText": prompt_text, "useSystemInstructions": False},
    {"id": CASUAL_PROMPT_ID, "title": "Casual Cleanup", "promptText": casual_text, "useSystemInstructions": False},
    {"id": PRO_PROMPT_ID, "title": "Professional Cleanup", "promptText": pro_text, "useSystemInstructions": False},
]

base_mode = {
    "isAIEnhancementEnabled": True,
    "selectedTranscriptionModelName": "parakeet-tdt-0.6b-v3",
    "isRealtimeTranscriptionEnabled": False,   # batch = full 0.6B accuracy; finalize is ~0.2s anyway
    "selectedLanguage": "en",
    "useClipboardContext": False, "useSelectedTextContext": False, "useScreenCapture": False,
    "selectedAIProvider": "Local CLI",
    "outputMode": "paste", "isEnabled": True,
}
mode_configs = [
    dict(base_mode, id=MODE_ID, name="Dictation", selectedPrompt=PROMPT_ID, isDefault=True),
    dict(base_mode, id=CASUAL_MODE_ID, name="Casual", selectedPrompt=CASUAL_PROMPT_ID, isDefault=False,
         appConfigs=[{"id":"55555555-0000-4000-8000-000000000001","bundleIdentifier":"com.apple.MobileSMS","appName":"Messages"},
                     {"id":"55555555-0000-4000-8000-000000000002","bundleIdentifier":"net.whatsapp.WhatsApp","appName":"WhatsApp"}],
         urlConfigs=[{"id":"55555555-0000-4000-9000-000000000001","url":"web.whatsapp.com"}]),
    dict(base_mode, id=PRO_MODE_ID, name="Professional", selectedPrompt=PRO_PROMPT_ID, isDefault=False,
         appConfigs=[{"id":"66666666-0000-4000-8000-000000000001","bundleIdentifier":"com.tinyspeck.slackmacgap","appName":"Slack"},
                     {"id":"66666666-0000-4000-8000-000000000002","bundleIdentifier":"com.apple.mail","appName":"Mail"}],
         urlConfigs=[{"id":"66666666-0000-4000-9000-000000000001","url":"mail.google.com"},
                     {"id":"66666666-0000-4000-9000-000000000002","url":"linkedin.com"}]),
]

def wd(key, obj):
    subprocess.run(["defaults","write",DOMAIN,key,"-data",json.dumps(obj).encode().hex()], check=True)

wd("customPrompts", custom_prompts)
wd("modeConfigurationsV2", mode_configs)
# Right Option, hold-to-talk
hot = json.dumps({"kind":"modifierOnly","keyCode":61,"modifierFlagsRawValue":524288})
subprocess.run(["defaults","write",DOMAIN,"Shortcut_primaryRecording","-data",hot.encode().hex()], check=True)
subprocess.run(["defaults","write",DOMAIN,"primaryRecordingShortcutMode","-string","pushToTalk"], check=True)
subprocess.run(["defaults","write",DOMAIN,"hasCompletedOnboardingV2","-bool","true"], check=True)
subprocess.run(["defaults","write",DOMAIN,"selectedAIProvider","-string","Local CLI"], check=True)
subprocess.run(["defaults","write",DOMAIN,"localCLICommandTemplate","-string",cli_path], check=True)
subprocess.run(["defaults","write",DOMAIN,"localCLITimeoutSeconds","-float","10"], check=True)
# short utterances skip the LLM entirely — instant paste
subprocess.run(["defaults","write",DOMAIN,"SkipShortEnhancement","-bool","true"], check=True)
subprocess.run(["defaults","write",DOMAIN,"ShortEnhancementWordThreshold","-int","6"], check=True)
print("Configured: Parakeet V3 (batch) + Apple Intelligence cleanup + hold Right-Option")
PYEOF

# ---------- 5. Optional: Ollama 7B "max quality" mode ----------
if [[ "${1:-}" == "--with-ollama" ]]; then
  step "Optional: Ollama + qwen2.5:7b quality mode (~5GB, for 24GB+ Macs)"
  if ! command -v brew >/dev/null 2>&1; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  command -v ollama >/dev/null 2>&1 || brew install ollama
  brew services start ollama >/dev/null 2>&1 || true
  sleep 3
  ollama pull qwen2.5:7b
  TMPMF="$(mktemp)"
  printf 'FROM qwen2.5:7b\nPARAMETER temperature 0.2\nPARAMETER top_p 0.9\nPARAMETER num_ctx 4096\n' > "$TMPMF"
  ollama create voiceink-cleanup-7b -f "$TMPMF"; rm -f "$TMPMF"
  bold "Quality mode installed. Switch provider to Ollama + voiceink-cleanup-7b:latest in VoiceInk → Settings when wanted."
fi

# ---------- 6. Launch ----------
step "6/6 Launch + login item"
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/VoiceInk.app", hidden:false}' >/dev/null 2>&1 || true
open -a /Applications/VoiceInk.app

bold "
============================================================
 INSTALLED. Two permission switches and you're dictating:
============================================================
 1. Microphone popup → click Allow.
    (Or: System Settings → Privacy & Security → Microphone
     → enable VoiceInk.)
 2. System Settings → Privacy & Security → Accessibility
    → toggle VoiceInk ON. (Lets it type the text for you.)

 Then: cursor in any text box, HOLD RIGHT OPTION (⌥), talk,
 release. Clean text appears in about a second.

 100% on-device: no cloud, no account, no subscription.
============================================================"
