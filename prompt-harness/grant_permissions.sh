#!/bin/bash
# One-shot helper: add VoiceInk to Accessibility + Input Monitoring via the
# System Settings "+" file picker (driven by keyboard, which is reliable).
# Run this with the screen AWAKE and unlocked:  bash grant_permissions.sh
# Requires Terminal to have Accessibility permission (already granted this session).
set -e
APP="/Applications/VoiceInk.app"

add_to_pane() {
  local anchor="$1" label="$2"
  echo ">>> Adding VoiceInk to $label ..."
  open "x-apple.systempreferences:com.apple.preference.security?$anchor"
  sleep 3
  osascript <<OSA
tell application "System Events"
  tell process "System Settings"
    set frontmost to true
    delay 0.5
    -- click the "+" Add button (search all buttons for the add control)
    set clicked to false
    repeat with b in (buttons of window 1)
      try
        if (description of b) contains "Add" or (title of b) is "+" then
          click b
          set clicked to true
          exit repeat
        end if
      end try
    end repeat
    delay 1.5
    -- file picker: go to exact path
    keystroke "g" using {command down, shift down}
    delay 0.6
    keystroke "$APP"
    delay 0.4
    keystroke return
    delay 0.8
    keystroke return
    delay 1.5
  end tell
end tell
OSA
}

add_to_pane "Privacy_Accessibility" "Accessibility"
add_to_pane "Privacy_ListenEvent" "Input Monitoring"

echo ">>> Restarting VoiceInk (Input Monitoring gotcha) ..."
osascript -e 'quit app "VoiceInk"' 2>/dev/null || true
sleep 2
open "$APP"
echo ">>> Done. VoiceInk should now be enabled in both lists. Trigger a dictation to grant Microphone."
