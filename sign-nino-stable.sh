#!/bin/zsh
# Re-sign the installed Nino Voice with the stable local cert so macOS permissions
# persist across every rebuild. Run after any `make local` + deploy to /Applications.
set -e
KC="$HOME/Library/Keychains/nino-signing.keychain-db"
security unlock-keychain -p "ninolocal" "$KC"
codesign -f -s "Nino Voice Local Signing" --keychain "$KC" --deep \
  --entitlements "$HOME/dev/VoiceInk/VoiceInk/VoiceInk.local.entitlements" \
  /Applications/VoiceInk.app
echo "Signed with stable cert. DR:"
codesign -d -r- /Applications/VoiceInk.app 2>&1 | grep designated
