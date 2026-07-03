#!/bin/bash
# For Rene: package everything the installer downloads and publish a GitHub release.
# Assets: VoiceInk-local.zip (app), voiceink-fm-cleanup (CLI), parakeet-tdt-0.6b-v3.tar.gz (ASR model)
#
# Usage: bash make-release.sh [version-tag]     (default: local-vYYYYMMDD)
set -euo pipefail

TAG="${1:-local-v$(date +%Y%m%d)}"
FLUID_MODEL="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
CLI="$HOME/dev/VoiceInk/fm-cleanup/voiceink-fm-cleanup"

[[ -d /Applications/VoiceInk.app ]] || { echo "No /Applications/VoiceInk.app"; exit 1; }
[[ -x "$CLI" ]] || { echo "Missing $CLI — build it first (see fm-cleanup/)"; exit 1; }
[[ -d "$FLUID_MODEL" ]] || { echo "Missing Parakeet model at $FLUID_MODEL"; exit 1; }

echo "Zipping app…";        ditto -ck --keepParent /Applications/VoiceInk.app /tmp/VoiceInk-local.zip
echo "Tarring parakeet…";   tar -czf /tmp/parakeet-tdt-0.6b-v3.tar.gz -C "$(dirname "$FLUID_MODEL")" "$(basename "$FLUID_MODEL")"

echo "Creating GitHub release $TAG on Renenicolas/VoiceInk"
gh release create "$TAG" \
  "/tmp/VoiceInk-local.zip#VoiceInk-local.zip" \
  "$CLI#voiceink-fm-cleanup" \
  "/tmp/parakeet-tdt-0.6b-v3.tar.gz#parakeet-tdt-0.6b-v3.tar.gz" \
  --repo Renenicolas/VoiceInk \
  --title "Local build $TAG" \
  --notes "Fully-local dictation: Parakeet V3 ASR + Apple Intelligence cleanup. Install with distribution/install.sh — do not double-click the zip." \
  --latest

echo "Done. install.sh resolves assets from releases/latest/download/."
