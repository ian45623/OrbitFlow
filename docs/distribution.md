# Distribution: packaging, updates, and Developer ID signing

How Orbit Flow gets from this repo onto another Mac, and the remaining work to sign and
notarize it with a Developer ID.

## Status

| Piece | State |
|---|---|
| `make dist` — release build zipped to `~/Desktop/Orbit Flow.zip` | Done |
| In-app **Settings ▸ Updates ▸ Check for updates** | Done |
| `make release` — notarized zip + dmg as GitHub release `build-<N>` | Written, never run |
| Developer ID signing + notarization (Makefile, updater Team ID check) | Done — trial run notarized and passed Gatekeeper; first real release pending |

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
- Signs the app: a Developer ID if one is in the keychain (always preferred), then the
  self-signed `Orbit Flow Local` from `make cert`, otherwise ad-hoc. Ad-hoc signing pins the
  designated requirement to the bundle ID, so the Accessibility grant survives rebuilds.
- With a Developer ID, `make notarize` submits the app to Apple, waits, and staples the ticket
  onto the bundle. On rejection it prints Apple's log and stops. Without one it warns and
  carries on, so `make dist` still works for your own Macs.
- Zips the stapled bundle with `ditto` (not `zip`), so the signature and ticket survive.
- `make dmg` builds the disk image from the same stapled bundle, then signs, notarizes and
  staples the image too.

**Don't rebuild between notarizing and packaging.** A rebuild re-signs the app and discards
the ticket. `zip` and `dmg-image` package the staged bundle as it is for this reason.

The target Mac needs macOS 26+ and Apple silicon. A notarized download opens with macOS's
ordinary "downloaded from the Internet" prompt. An ad-hoc one is blocked on first launch:
System Settings ▸ Privacy & Security ▸ **Open Anyway**.

### Updates — `make release` and the Settings button

- `make release` refuses uncommitted changes, unpushed commits, or a keychain with no
  Developer ID. It builds once, notarizes, packages the zip and dmg, and runs
  `make verify-release` (`spctl` must report `source=Notarized Developer ID` for both, and
  both tickets must validate). Only then does it run `gh release create build-<N>`. It needs
  `gh auth login`.
- The app (`Sources/OrbitFlow/Support/Updater.swift`) reads
  `api.github.com/repos/ian45623/OrbitFlow/releases/latest`. It compares the tag's number
  with its own `CFBundleVersion`. A 404 means there are no releases yet, which it shows as
  "up to date".
- Install downloads the zip and unpacks it with `ditto`. It then runs
  `codesign --verify --deep --strict` and checks that the bundle ID matches. A copy that is
  itself Developer ID signed also requires the download to be signed by **the same team**.
  It reads its own Team ID at runtime, so nothing is hardcoded. A detached
  `/bin/sh` waits for the app to quit, swaps the bundle in place, and reopens it.
- URLSession downloads carry no quarantine flag, so the swapped-in app launches without a
  Gatekeeper prompt.
- If the app's folder isn't writable, the updater says to move the app to Applications.

**Known gap, closes itself:** an ad-hoc copy can only check that the download is intact and
claims to be Orbit Flow, not who built it. That's also what lets it move onto the first
Developer ID release. From then on, the team check applies.

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

## Developer ID: first release checklist

1. Finish the setup above. Check that `security find-identity -v -p codesigning` lists
   `Developer ID Application: …` and that
   `xcrun notarytool history --keychain-profile orbitflow` runs without an error.
2. Commit, push, then `make release`. Notarization usually takes a few minutes per file, and
   it runs twice (app, then dmg).
3. On another Mac, download the dmg **with a browser** so it's quarantined like a real user's
   copy, then open it. You should get only the plain "downloaded from the Internet" prompt.

**Side effect:** macOS ties the Accessibility grant to the signature. The first Developer ID
build on each Mac may ask for Accessibility once more; after that it stays.

A different profile name works too: `make release NOTARY_PROFILE=<name>`.
