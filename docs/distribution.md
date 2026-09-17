# Distribution: packaging, updates, and Developer ID signing

How Orbit Flow gets from this repo onto another Mac, and the remaining work to sign and
notarize it with a Developer ID.

## Status

| Piece | State |
|---|---|
| `make dist` — release build zipped to `~/Desktop/Orbit Flow.zip` | Done |
| In-app **Settings ▸ Updates ▸ Check for updates** | Done |
| `make release` — publishes the zip as GitHub release `build-<N>` | Written, never run |
| Developer ID signing + notarization | **Not started — waiting on the setup below** |

## Picking this up on a new computer

1. `git clone https://github.com/ian45623/OrbitFlow.git && cd OrbitFlow`
2. Install the Command Line Tools: `xcode-select --install`. Full Xcode isn't needed.
3. `make install` builds the app, installs it to Applications, and launches it.

**Build tools gotcha.** Command Line Tools 27 default to the macOS 27 SDK, whose SwiftUI
needs a macro plugin that ships only with full Xcode. Every build fails with
`plugin for module 'SwiftUIMacros' not found`. The Makefile pins
`MacOSX26.5.sdk` when it exists. If a fresh install doesn't include that SDK, either install
full Xcode or point `SDKROOT` at a 26.x SDK you do have
(`ls /Library/Developer/CommandLineTools/SDKs/`).

## How it works today

### Packaging — `make dist`

- Builds in release mode and assembles `Orbit Flow.app` in `~/Library/Caches/OrbitFlowBuild`.
- Stamps `CFBundleVersion` with the git commit count (`git rev-list --count HEAD`), so build
  numbers go up with no manual bumping.
- Signs the app: Developer ID if one is in the keychain, otherwise ad-hoc. Ad-hoc signing pins
  the designated requirement to the bundle ID, so the Accessibility grant survives rebuilds.
- Zips with `ditto` (not `zip`), so the signature survives.

The target Mac needs macOS 26+ and Apple silicon. While the app is ad-hoc signed, the first
launch is blocked: System Settings ▸ Privacy & Security ▸ **Open Anyway**.

### Updates — `make release` and the Settings button

- `make release` refuses uncommitted changes or unpushed commits, runs `make dist`, then runs
  `gh release create build-<N>` with the zip attached. It needs `gh auth login`.
- The app (`Sources/OrbitFlow/Support/Updater.swift`) reads
  `api.github.com/repos/ian45623/OrbitFlow/releases/latest`. It compares the tag's number
  with its own `CFBundleVersion`. A 404 means there are no releases yet, which it shows as
  "up to date".
- Install downloads the zip and unpacks it with `ditto`. It then runs
  `codesign --verify --deep --strict` and checks that the bundle ID matches. A detached
  `/bin/sh` waits for the app to quit, swaps the bundle in place, and reopens it.
- URLSession downloads carry no quarantine flag, so the swapped-in app launches without a
  Gatekeeper prompt.
- If the app's folder isn't writable, the updater says to move the app to Applications.

**Known gap:** ad-hoc signing only proves the download is intact and claims to be Orbit Flow,
not who built it. Anyone who can publish releases on the repo can push an update. Developer
ID closes this (see below).

**One-time step:** any Mac with a build from before the Updates section existed needs one
manual install of a newer zip. After that, updates come through the button.

## Developer ID: setup (you, once)

None of these secrets go into the repo or a chat.

### 1. Developer ID Application certificate

Only the developer account's **Account Holder** can create one.

1. Keychain Access ▸ Certificate Assistant ▸ **Request a Certificate From a Certificate
   Authority**. Enter your email, choose **Saved to disk**.
2. developer.apple.com ▸ Certificates ▸ **+** ▸ **Developer ID Application**. Upload the
   request, then download the `.cer`.
3. Double-click the `.cer` to add it to the login keychain.
4. Check: `security find-identity -v -p codesigning` lists `Developer ID Application: …`.

The certificate's private key lives only in the keychain of the Mac that made the request.
To build on another Mac, export it from Keychain Access (My Certificates ▸ right-click ▸
Export, `.p12`) and import it there.

### 2. Notarization login

1. appleid.apple.com ▸ Sign-In and Security ▸ **App-Specific Passwords**. Create one
   called "notarytool".
2. In Terminal:
   ```bash
   xcrun notarytool store-credentials orbitflow --apple-id <Apple ID email> --team-id <TEAM ID>
   ```
   Paste the password when prompted. It's saved in the keychain under the profile name
   `orbitflow`, which is all the Makefile references. Repeat on each Mac that builds releases.

### 3. Team ID

The 10-character code at developer.apple.com ▸ Account ▸ Membership details. It isn't
secret, so it can live in the Makefile.

## Developer ID: remaining code changes

These are ready to make once the setup above is done:

1. **Makefile `app`:** use `--timestamp` instead of `--timestamp=none` when `SIGN_ID` is a
   Developer ID. Notarization rejects builds without a secure timestamp. Keep
   `--options runtime`, which it also requires.
2. **Makefile `dist`:** after zipping, run
   `xcrun notarytool submit "$(DIST)" --keychain-profile orbitflow --wait`, then
   `xcrun stapler staple "$(BUNDLE)"`, then zip again so the shipped app carries the
   notarization ticket.
3. **Updater:** add a Team ID check to the verify step, so only apps signed by this team
   install:
   `codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[subject.OU] = "<TEAM ID>"'`.
4. **README / this doc:** drop the "Open Anyway" instructions once builds are notarized.

**Side effect:** macOS ties the Accessibility grant to the signature. The first Developer ID
build on each Mac asks for Accessibility once more; after that it stays.
