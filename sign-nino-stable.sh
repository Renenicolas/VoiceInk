#!/bin/zsh
# Re-sign installed Nino Voice with the stable local cert so macOS permissions
# persist across every rebuild. Run after manually copying a build anywhere.
# (make nino already signs with this cert; make install preserves it.)
set -e
KC="$HOME/Library/Keychains/nino-signing.keychain-db"
APP="${1:-/Applications/Nino Voice.app}"
security unlock-keychain -p "ninosigning" "$KC"
codesign -f -s "Nino Code Signing" --keychain "$KC" --deep \
  --entitlements "$HOME/dev/VoiceInk/VoiceInk/VoiceInk.local.entitlements" "$APP"
echo "Signed. DR:"; codesign -d -r- "$APP" 2>&1 | grep designated
