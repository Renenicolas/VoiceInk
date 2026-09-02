# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build

.PHONY: all clean whisper setup build local check healthcheck help dev run

# Default target
all: check build

# Development workflow
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		else \
			(cd $(WHISPER_CPP_DIR) && git pull); \
		fi; \
		cd $(WHISPER_CPP_DIR) && ./build-xcframework.sh; \
	else \
		echo "whisper.xcframework already built in $(DEPS_DIR), skipping build"; \
	fi

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" build

# Build for local use without Apple Developer certificate
local: check setup
	@echo "Building VoiceInk for local use (no Apple Developer certificate required)..."
	@pkill -f "$(LOCAL_DERIVED_DATA)/Build/Products" 2>/dev/null || true
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoiceInk.app" && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Copying VoiceInk.app to ~/Downloads..."; \
		rm -rf "$$HOME/Downloads/VoiceInk.app"; \
		ditto "$$APP_PATH" "$$HOME/Downloads/VoiceInk.app"; \
		xattr -cr "$$HOME/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Build complete! App saved to: ~/Downloads/VoiceInk.app"; \
		echo "Run with: open ~/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built VoiceInk.app at $$APP_PATH"; \
		exit 1; \
	fi

# Run application
run:
	@if [ -d "$$HOME/Downloads/VoiceInk.app" ]; then \
		echo "Opening ~/Downloads/VoiceInk.app..."; \
		open "$$HOME/Downloads/VoiceInk.app"; \
	else \
		echo "Looking for VoiceInk.app in DerivedData..."; \
		APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "VoiceInk.app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "VoiceInk.app not found. Please run 'make build' or 'make local' first."; \
			exit 1; \
		fi; \
	fi

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(DEPS_DIR)
	@echo "Clean complete"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoiceInk project"
	@echo "  build              Build the VoiceInk Xcode project"
	@echo "  local              Build for local use (no Apple Developer certificate needed)"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"
# Build signed with the stable local certificate ("Nino Voice Local Signing").
#
# `make local` signs ad-hoc, which mints a NEW code-signing identity on every
# build. macOS TCC keys Microphone and Accessibility grants to that identity, so
# every ad-hoc rebuild silently revokes both and the app looks broken: hotkeys
# stop, dictation stops pasting. Signing with one stable certificate keeps the
# identity constant, so the grants survive rebuilds and only have to be given
# once. Use this target for anything that gets installed and actually used.
# A certificate WE created, in a keychain WE own, with a password stored right
# here. The old "Nino Voice Local Signing" identity lived in the login keychain
# and its private key would not release to codesign — the login keychain password
# had drifted from the account password and nobody had it. This one needs no
# password anybody has to remember.
#
# Recreate on a new Mac with: make signing-cert
NINO_SIGN_KEYCHAIN ?= nino-signing.keychain
NINO_SIGN_PASSWORD ?= ninosigning
NINO_SIGN_IDENTITY ?= Nino Code Signing

nino: check setup
	@echo "Building Nino Voice signed with '$(NINO_SIGN_IDENTITY)'..."
	@# Never rebuild under a live instance: an app running out of .local-build has
	@# its bundle replaced mid-flight and its menu bar item/resources go dark.
	@pkill -f "$(LOCAL_DERIVED_DATA)/Build/Products" 2>/dev/null || true
	@security find-identity -v -p codesigning $(NINO_SIGN_KEYCHAIN) | grep -q "$(NINO_SIGN_IDENTITY)" || \
		{ echo "No '$(NINO_SIGN_IDENTITY)' identity. Run: make signing-cert"; exit 1; }
	@security unlock-keychain -p $(NINO_SIGN_PASSWORD) $(NINO_SIGN_KEYCHAIN)
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="$(NINO_SIGN_IDENTITY)" \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGNING_REQUIRED=YES \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoiceInk.app" && \
	if [ -d "$$APP_PATH" ]; then \
		rm -rf "$$HOME/Downloads/VoiceInk.app"; \
		ditto "$$APP_PATH" "$$HOME/Downloads/VoiceInk.app"; \
		xattr -cr "$$HOME/Downloads/VoiceInk.app"; \
		codesign --force --deep --keychain $(NINO_SIGN_KEYCHAIN) --sign "$(NINO_SIGN_IDENTITY)" \
			--entitlements "$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" "$$HOME/Downloads/VoiceInk.app"; \
		echo "Signed build at ~/Downloads/VoiceInk.app"; \
		codesign -dvvv "$$HOME/Downloads/VoiceInk.app" 2>&1 | grep -E "Authority|CDHash=" | head -2; \
		codesign -dvvv "$$HOME/Downloads/VoiceInk.app" 2>&1 | grep -q "Authority=$(NINO_SIGN_IDENTITY)" || \
			{ echo "ERROR: build is NOT signed with '$(NINO_SIGN_IDENTITY)' — permissions will not persist"; exit 1; }; \
	fi

# Create the signing certificate and its keychain from scratch. Idempotent-ish:
# it deletes and recreates, so run it once per machine.
#
# WHY THIS EXISTS: `make local` signs ad-hoc, which mints a NEW code-signing
# identity on every single build. macOS keys Accessibility and Microphone grants
# to that identity, so every ad-hoc rebuild silently revokes both and the app
# looks dead — hotkeys stop with nothing in any log. That cost a whole day.
# A stable certificate means the grants are given once and survive every rebuild.
signing-cert:
	@set -e; \
	W=$$(mktemp -d); \
	printf '[ req ]\ndistinguished_name = dn\nx509_extensions = v3\nprompt = no\n[ dn ]\nCN = $(NINO_SIGN_IDENTITY)\nO = Nino\n[ v3 ]\nbasicConstraints = critical,CA:false\nkeyUsage = critical,digitalSignature\nextendedKeyUsage = critical,codeSigning\n' > $$W/openssl.cnf; \
	openssl req -x509 -newkey rsa:2048 -keyout $$W/key.pem -out $$W/cert.pem -days 3650 -nodes -config $$W/openssl.cnf 2>/dev/null; \
	openssl pkcs12 -export -inkey $$W/key.pem -in $$W/cert.pem -out $$W/nino.p12 -name "$(NINO_SIGN_IDENTITY)" \
		-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -passout pass:$(NINO_SIGN_PASSWORD); \
	security delete-keychain $(NINO_SIGN_KEYCHAIN) 2>/dev/null || true; \
	security create-keychain -p $(NINO_SIGN_PASSWORD) $(NINO_SIGN_KEYCHAIN); \
	security set-keychain-settings -lut 100000 $(NINO_SIGN_KEYCHAIN); \
	security unlock-keychain -p $(NINO_SIGN_PASSWORD) $(NINO_SIGN_KEYCHAIN); \
	security import $$W/nino.p12 -k $(NINO_SIGN_KEYCHAIN) -P $(NINO_SIGN_PASSWORD) -T /usr/bin/codesign -T /usr/bin/security >/dev/null; \
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $(NINO_SIGN_PASSWORD) $(NINO_SIGN_KEYCHAIN) >/dev/null 2>&1; \
	security add-trusted-cert -r trustRoot -k "$$HOME/Library/Keychains/$(NINO_SIGN_KEYCHAIN)-db" $$W/cert.pem; \
	security list-keychains -d user -s login.keychain-db $(NINO_SIGN_KEYCHAIN); \
	rm -rf $$W; \
	security find-identity -v -p codesigning $(NINO_SIGN_KEYCHAIN)

# Install the freshly built app where macOS expects it. Running the app out of
# .local-build or ~/Downloads is what made the menu bar icon vanish: builds
# replace those bundles, nothing relaunches them after a reboot, and no login
# item can point at them. /Applications/Nino Voice.app is the one true install.
install:
	@test -d "$$HOME/Downloads/VoiceInk.app" || { echo "No build in ~/Downloads. Run: make nino"; exit 1; }
	@pkill -x VoiceInk 2>/dev/null || true; sleep 1
	rm -rf "/Applications/Nino Voice.app"
	ditto "$$HOME/Downloads/VoiceInk.app" "/Applications/Nino Voice.app"
	open "/Applications/Nino Voice.app"
	@echo "Installed and launched /Applications/Nino Voice.app"

# Sign an already-built app with the stable certificate.
sign:
	@security unlock-keychain -p $(NINO_SIGN_PASSWORD) $(NINO_SIGN_KEYCHAIN)
	codesign --force --deep --keychain $(NINO_SIGN_KEYCHAIN) --sign "$(NINO_SIGN_IDENTITY)" \
		--entitlements "$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" "$$HOME/Downloads/VoiceInk.app"
	codesign -dvv "$$HOME/Downloads/VoiceInk.app" 2>&1 | grep -E "Authority|CDHash="
