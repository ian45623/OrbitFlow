EXEC     := OrbitFlow
CONFIG   := debug

## Command Line Tools 27 default to the macOS 27 SDK, whose SwiftUI `@State` is a macro
## implemented by a SwiftUIMacros plugin that ships only with full Xcode — so every build
## fails with "plugin for module 'SwiftUIMacros' not found". Pin the 26.5 SDK while it's
## installed. An SDKROOT from the environment still wins.
# ponytail: hardcoded SDK path; drop once Xcode is installed or the CLT ships the plugin.
SDK_26 := /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
ifneq ($(wildcard $(SDK_26)),)
export SDKROOT ?= $(SDK_26)
endif

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## A file-provider synced folder (iCloud Desktop/Documents, Dropbox) mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
SCRATCH  := $(HOME)/Library/Caches/OrbitFlowBuild/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## If this tree ever sits in a file-provider synced folder, the provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/OrbitFlowBuild
APPNAME  := Orbit Flow.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## TCC keys the Accessibility grant to the code signature, so an ad-hoc signature — which
## changes on every build — makes the user re-grant after every `make`. Signing with a
## stable Developer ID keeps the identity constant and the grant sticky. Falls back to
## ad-hoc ("-") on a machine without the cert.
##
## `make cert` creates the self-signed fallback once; without either, we sign ad-hoc, whose
## cdhash changes on every build.
CERT_CN := Orbit Flow Local
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep -E "Developer ID Application|$(CERT_CN)" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

BUNDLE_ID := ai.pivotstudio.orbitflow

## An ad-hoc signature's *designated requirement* is the binary's cdhash, which changes on
## every build — so TCC's stored Accessibility row stops matching and the hotkey silently
## goes dead after each `make install`. Pinning the requirement to the bundle identifier
## alone makes it stable across rebuilds, so the grant survives.
##
## This is deliberately weaker: any binary claiming this identifier satisfies it. That's an
## acceptable trade for a locally-built unsigned app and nothing else, which is why it is
## applied ONLY on the ad-hoc fallback — a real Developer ID already has a stable
## requirement and must keep its default.
ifeq ($(SIGN_ID),-)
SIGN_REQ := -r='designated => identifier "$(BUNDLE_ID)"'
endif

.PHONY: all build test app run install clean icon cert dist dmg release

## Monotonic with no manual bumping. Uncommitted changes don't move it — `release` refuses them.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

## swift-testing on a machine with Command Line Tools but no full Xcode.
##
## `Testing.framework` does ship in the CLT, but SwiftPM never puts it on the search
## path, and the framework's own dependency `lib_TestingInterop.dylib` sits in a sibling
## directory that nothing adds to the rpath. Without all four flags you hit three
## failures in sequence, each one looking like a different problem:
##
##   1. compile:  no such module 'Testing'
##   2. dyld:     Library not loaded: @rpath/Testing.framework/Versions/A/Testing
##   3. dyld:     Library not loaded: @rpath/lib_TestingInterop.dylib
##
## Installing full Xcode also fixes it. These flags mean you don't have to, and they are
## skipped automatically when the CLT directory isn't there.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB        := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
## With the 26.5 SDK pinned above, `@Test` can't find its TestingMacros plugin either.
CLT_TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
TESTFLAGS      := $(if $(wildcard $(CLT_FRAMEWORKS)),\
                    -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
                    -Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
                    -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) \
                    -Xlinker -rpath -Xlinker $(CLT_LIB) \
                    -Xswiftc -plugin-path -Xswiftc $(CLT_TESTING_PLUGINS),)

test:
	swift test --scratch-path "$(SCRATCH)" $(TESTFLAGS)

## Regenerates AppIcon.icns from Tools/makeicon.swift. Not a dependency of `app` — the
## icon rarely changes and rendering 10 PNGs on every build is wasted time.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp $(BUILD) "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@# The commit count is the build number the in-app updater compares against.
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" $(SIGN_REQ) \
		--identifier "$(BUNDLE_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

## Runs the *installed* copy, never the staging bundle.
##
## A TCC grant and a login item both point at a path, and $(STAGE) sits under
## ~/Library/Caches — which macOS purges, and which this Makefile rewrites on every build.
## Launching from there is why permission prompts come back.
run: install

## Ad-hoc signatures change on every rebuild, which resets the Accessibility grant.
## Installing keeps the path stable and makes re-granting a one-click fix.
##
## /Applications is not writable on a managed Mac, and the failure is a bare "Permission
## denied" that looks like a build problem. ~/Applications is user-owned, is a real
## LaunchServices location, and is just as stable a path as far as TCC is concerned — so
## fall back to it rather than requiring sudo.
INSTALL_DIR := $(shell [ -w /Applications ] && echo /Applications || echo "$(HOME)/Applications")

install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@mkdir -p "$(INSTALL_DIR)"
	@# $(BUNDLE) is an absolute staging path — the destination must use $(APPNAME) alone.
	@rm -rf "$(INSTALL_DIR)/$(APPNAME)"
	@cp -R "$(BUNDLE)" "$(INSTALL_DIR)/$(APPNAME)"
	@open "$(INSTALL_DIR)/$(APPNAME)"
	@# pbs caches the Services database and does not notice a changed Info.plist on its
	@# own, so every build that touches NSServices would otherwise show stale rows.
	@/System/Library/CoreServices/pbs -flush 2>/dev/null || true
	@echo "installed to $(INSTALL_DIR)/$(APPNAME)"

## One-time: a stable self-signed code-signing identity, so the Accessibility grant sticks.
##
## Ad-hoc signing has no certificate, so TCC has nothing durable to pin the grant to and
## re-asks after builds. A self-signed cert gives the bundle a designated requirement that
## survives every rebuild. Expect two macOS prompts for your login password — import, then
## trust. Delete it with:
##   security delete-certificate -c "$(CERT_CN)" ~/Library/Keychains/login.keychain-db
##
## `-A` alone isn't enough: since Sierra a private key also carries a partition list, and
## without `apple-tool:` on it codesign pops "codesign wants to access key" on every build.
## `-name` gives the key a findable label for that step (it was "i.p12" otherwise).
##
## The PKCS#12 password is deliberately not empty: `security import` rejects an
## empty-password bundle with "MAC verification failed during PKCS12 import (wrong
## password?)". The value itself is irrelevant — the .p12 lives in $$d for two lines and
## the trap deletes it on exit.
cert:
	@set -e; \
	if security find-identity -v -p codesigning 2>/dev/null | grep -q "$(CERT_CN)"; then \
	  echo "already have \"$(CERT_CN)\" — nothing to do"; exit 0; \
	fi; \
	d=$$(mktemp -d); trap 'rm -rf "'"$$d"'"' EXIT; \
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
	  -keyout "$$d/k.pem" -out "$$d/c.pem" -subj "/CN=$(CERT_CN)" \
	  -addext "basicConstraints=critical,CA:false" \
	  -addext "keyUsage=critical,digitalSignature" \
	  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null; \
	openssl pkcs12 -export -out "$$d/i.p12" -inkey "$$d/k.pem" -in "$$d/c.pem" \
	  -name "$(CERT_CN)" -passout pass:orbitflow; \
	security import "$$d/i.p12" -k "$(HOME)/Library/Keychains/login.keychain-db" \
	  -P orbitflow -A; \
	echo "enter your login password once so codesign can use the key without asking:"; \
	security set-key-partition-list -S apple-tool:,apple: -s -l "$(CERT_CN)" \
	  "$(HOME)/Library/Keychains/login.keychain-db" >/dev/null; \
	security add-trusted-cert -r trustRoot -p codeSign \
	  -k "$(HOME)/Library/Keychains/login.keychain-db" "$$d/c.pem"; \
	echo "created \"$(CERT_CN)\" — now run: make install"

## A release build zipped for copying to another Mac. `ditto` rather than `zip` so the
## code signature and bundle metadata survive. Without a Developer ID + notarization the
## other Mac's Gatekeeper blocks the first launch — see README "Installing on another Mac".
DIST := $(HOME)/Desktop/Orbit Flow.zip

dist:
	@$(MAKE) app CONFIG=release
	@rm -f "$(DIST)"
	@ditto -c -k --keepParent "$(BUNDLE)" "$(DIST)"
	@echo "wrote $(DIST)"

## The download people click: a disk image that opens on the app, an Applications shortcut,
## and an arrow between them. A browser can't download an .app on its own — it's a folder —
## so it has to come wrapped in something, and this is the wrapper Mac users expect.
##
## Finder stores the window layout in the image's .DS_Store, and AppleScript is the only
## supported way to write one. The first run asks to let this terminal control Finder; if
## that's refused the image still works, it just opens as a plain window.
DMG      := $(HOME)/Desktop/Orbit Flow.dmg
DMG_VOL  := Install Orbit Flow

dmg:
	@$(MAKE) app CONFIG=release
	@set -e; d="$(STAGE)/dmg"; rw="$(STAGE)/rw.dmg"; \
	rm -rf "$$d" "$$rw" "$(DMG)"; mkdir -p "$$d/.background"; \
	cp -R "$(BUNDLE)" "$$d/"; ln -s /Applications "$$d/Applications"; \
	cp Resources/DMGBackground.tiff "$$d/.background/background.tiff"; \
	hdiutil detach "/Volumes/$(DMG_VOL)" -quiet 2>/dev/null || true; \
	hdiutil create -quiet -volname "$(DMG_VOL)" -srcfolder "$$d" -fs HFS+ -format UDRW "$$rw"; \
	hdiutil attach -quiet -noautoopen "$$rw"; \
	osascript \
	  -e 'tell application "Finder" to tell disk "$(DMG_VOL)"' \
	  -e 'open' \
	  -e 'set current view of container window to icon view' \
	  -e 'set toolbar visible of container window to false' \
	  -e 'set statusbar visible of container window to false' \
	  -e 'set bounds of container window to {200, 120, 800, 522}' \
	  -e 'set opts to icon view options of container window' \
	  -e 'set arrangement of opts to not arranged' \
	  -e 'set icon size of opts to 128' \
	  -e 'set text size of opts to 13' \
	  -e 'set background picture of opts to file ".background:background.tiff"' \
	  -e 'set position of item "$(APPNAME)" to {160, 190}' \
	  -e 'set position of item "Applications" to {440, 190}' \
	  -e 'update without registering applications' \
	  -e 'delay 1' \
	  -e 'close' \
	  -e 'end tell' \
	  || echo "Finder layout skipped — the image will open as a plain window"; \
	sync; hdiutil detach -quiet "/Volumes/$(DMG_VOL)" || hdiutil detach -force -quiet "/Volumes/$(DMG_VOL)"; \
	hdiutil convert -quiet "$$rw" -format UDZO -imagekey zlib-level=9 -o "$(DMG)"; \
	rm -rf "$$d" "$$rw"
	@echo "wrote $(DMG)"

## Publishes the zip and the dmg as GitHub release `build-<N>`; every installed copy's
## Settings ▸ Check for updates picks it up. Committed, pushed code only, so the number on
## a release always names real source.
release:
	@test -z "$$(git status --porcelain)" || { echo "commit your changes first"; exit 1; }
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse @{u} 2>/dev/null)" || { echo "push first"; exit 1; }
	@$(MAKE) dist
	@$(MAKE) dmg
	@# The zip is what the in-app updater looks for; the dmg is what people download.
	@gh release create "build-$(BUILD_NUMBER)" "$(DIST)" "$(DMG)" --target "$$(git rev-parse HEAD)" \
		--title "Build $(BUILD_NUMBER)" --notes "$$(git log -1 --pretty=%s)"

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
