#!/usr/bin/env python3
"""Pre-seed VoiceInk so it launches fully configured (skips onboarding):
- default "Dictation" mode: whisper large-v3-turbo-q5_0 ASR, AI enhancement ON,
  Ollama llama3.2:3b, using the harness-validated compact cleanup prompt
- custom prompt "Local Cleanup" (useSystemInstructions=false, tuned for 3B models)
Run AFTER build, BEFORE first launch (quit the app first if running).
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from run_harness import COMPACT_PROMPT  # single source of truth for the prompt

DOMAIN = "com.prakashjoshipax.VoiceInk"
CLEANUP_PROMPT_ID = "22222222-2222-2222-2222-222222222222"
MODE_ID = "11111111-1111-1111-1111-111111111111"

custom_prompts = [
    {
        "id": CLEANUP_PROMPT_ID,
        "title": "Local Cleanup",
        "promptText": COMPACT_PROMPT,
        "useSystemInstructions": False,
    },
]

mode_configs = [
    {
        "id": MODE_ID,
        "name": "Dictation",
        "isAIEnhancementEnabled": True,
        "selectedPrompt": CLEANUP_PROMPT_ID,
        "selectedTranscriptionModelName": "ggml-large-v3-turbo",
        "isRealtimeTranscriptionEnabled": True,
        "selectedLanguage": "en",
        "useClipboardContext": False,
        "useSelectedTextContext": False,
        "useScreenCapture": False,
        "selectedAIProvider": "Ollama",
        "selectedAIModel": "llama3.2:3b",
        "outputMode": "paste",
        "isEnabled": True,
        "isDefault": True,
    }
]


def write_data(key: str, obj) -> None:
    hexdata = json.dumps(obj).encode().hex()
    subprocess.run(["defaults", "write", DOMAIN, key, "-data", hexdata], check=True)


write_data("customPrompts", custom_prompts)
write_data("modeConfigurationsV2", mode_configs)
subprocess.run(["defaults", "write", DOMAIN, "hasCompletedOnboardingV2", "-bool", "true"], check=True)
subprocess.run(["defaults", "write", DOMAIN, "ollamaBaseURL", "-string", "http://localhost:11434"], check=True)
subprocess.run(["defaults", "write", DOMAIN, "ollamaSelectedModel", "-string", "llama3.2:3b"], check=True)
subprocess.run(["defaults", "write", DOMAIN, "selectedAIProvider", "-string", "Ollama"], check=True)
print(f"Seeded {DOMAIN}: mode 'Dictation' (whisper turbo-q5 + Ollama llama3.2:3b + Local Cleanup prompt)")
