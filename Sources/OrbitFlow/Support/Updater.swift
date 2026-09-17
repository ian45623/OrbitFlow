import AppKit
import Foundation
import Observation
import Security

/// Self-update from GitHub Releases.
///
/// `make release` publishes a zip under the tag `build-<N>`, where N is the commit count the
/// Makefile also stamps into `CFBundleVersion`. Newer means a bigger N — no version strings to
/// bump by hand. The other Mac never needs the source or a toolchain: it downloads the zip,
/// swaps the bundle in place, and relaunches.
///
/// The download comes from URLSession, which doesn't add a quarantine flag, so Gatekeeper
/// doesn't block the relaunch. Releases are Developer ID signed and notarized, so the
/// signature's requirement stays the same from build to build and the Accessibility grant
/// carries over.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(build: Int, zip: URL)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    static let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    private static let latestRelease = URL(string: "https://api.github.com/repos/ian45623/OrbitFlow/releases/latest")!

    private struct Release: Decodable {
        struct Asset: Decodable { let browser_download_url: URL }
        let tag_name: String
        let assets: [Asset]
    }

    func check() {
        Task { await refresh() }
    }

    /// Checks at launch and every few hours after. When `Settings.autoUpdate` is on, a found
    /// build installs itself — but only once `isBusy` goes false, so a relaunch never lands
    /// in the middle of a dictation or a passage being read aloud.
    func startPeriodicChecks(isBusy: @escaping @MainActor () -> Bool) {
        guard periodicChecks == nil else { return }
        periodicChecks = Task {
            while !Task.isCancelled {
                await refresh()
                while Settings.shared.autoUpdate, case .available = phase {
                    if !isBusy() { install(); return }
                    try? await Task.sleep(for: .seconds(60))
                }
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    private var periodicChecks: Task<Void, Never>?
    private static let checkInterval = Duration.seconds(6 * 60 * 60)

    private func refresh() async {
        guard phase != .checking, phase != .installing else { return }
        phase = .checking
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.latestRelease)
            // 404 is GitHub's answer for "no releases yet", not a failure worth alarming anyone.
            if (response as? HTTPURLResponse)?.statusCode == 404 { phase = .upToDate; return }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let build = Int(release.tag_name.replacing("build-", with: "")),
                  let zip = release.assets.map(\.browser_download_url).first(where: { $0.pathExtension == "zip" })
            else {
                phase = .failed("The latest release (\(release.tag_name)) has no build number or zip.")
                return
            }
            phase = build > Self.currentBuild ? .available(build: build, zip: zip) : .upToDate
        } catch {
            phase = .failed("Couldn't reach GitHub: \(error.localizedDescription)")
        }
    }

    func install() {
        guard case .available(_, let zip) = phase else { return }
        phase = .installing
        Task {
            do {
                try await replaceAndRelaunch(from: zip)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func replaceAndRelaunch(from zip: URL) async throws {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError("Orbit Flow can't write to \(target.deletingLastPathComponent().path). "
                + "Move the app to your Applications folder and try again.")
        }

        let (downloaded, _) = try await URLSession.shared.download(from: zip)
        let work = FileManager.default.temporaryDirectory.appending(path: "OrbitFlowUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", downloaded.path, work.path])

        guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError("The download didn't contain an app.") }

        // Trust boundary: refuse anything that isn't intact or isn't this app. A Developer ID
        // copy only accepts an update signed by the same team; an ad-hoc copy can't prove who
        // built anything, so it checks only that the download is undamaged — which is also
        // what lets an ad-hoc install move onto the first Developer ID release.
        var verify = ["--verify", "--deep", "--strict"]
        if let team = Self.teamIdentifier {
            verify.append("-R=" + Self.developerIDRequirement(team: team))
        }
        try run("/usr/bin/codesign", verify + [newApp.path])
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download isn't Orbit Flow.")
        }

        // A bundle can't replace itself while it's running. A detached shell waits for this
        // process to exit, then swaps the bundle and reopens it. Paths go in as arguments,
        // never spliced into the script.
        let swap = Process()
        swap.executableURL = URL(filePath: "/bin/sh")
        swap.arguments = [
            "-c",
            #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; rm -rf "$2" && mv "$3" "$2" && open "$2"; rm -rf "$4""#,
            "sh", String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path, work.path,
        ]
        try swap.run()
        NSApp.terminate(nil)
    }

    /// The team that signed this running copy, or nil for an ad-hoc or self-signed build.
    private static let teamIdentifier: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Apple's standard Developer ID requirement, narrowed to one team: issued by Apple's
    /// Developer ID intermediate, a Developer ID Application leaf, and this team's OU.
    private static func developerIDRequirement(team: String) -> String {
        #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"#
            + #" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
            + #" and certificate leaf[subject.OU] = "\#(team)""#
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(filePath: tool).lastPathComponent) failed on the downloaded update.")
        }
    }
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
