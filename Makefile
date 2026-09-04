EXEC     := OrbitFlow
CONFIG   := debug

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
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
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

.PHONY: all build test app run install clean icon

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
TESTFLAGS      := $(if $(wildcard $(CLT_FRAMEWORKS)),\
                    -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
                    -Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
                    -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) \
                    -Xlinker -rpath -Xlinker $(CLT_LIB),)

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

## Only ever targets the OrbitFlow executable — never the separate `orbitflow` app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

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
	@echo "installed to $(INSTALL_DIR)/$(APPNAME)"

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
