import AppKit
import Foundation
import Observation

/// Self-update from GitHub Releases.
///
/// `make release` publishes a zip under the tag `build-<N>`, where N is the commit count the
/// Makefile also stamps into `CFBundleVersion`. Newer means a bigger N — no version strings to
/// bump by hand. The other Mac never needs the source or a toolchain: it downloads the zip,
/// swaps the bundle in place, and relaunches.
///
/// The download comes from URLSession, which doesn't add a quarantine flag, so Gatekeeper
/// doesn't block the relaunch. The ad-hoc signature's requirement is pinned to the bundle ID
/// (see the Makefile), so the Accessibility grant also carries over to the new build.
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
        guard phase != .checking, phase != .installing else { return }
        phase = .checking
        Task {
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
        try run("/usr/bin/ditto", "-x", "-k", downloaded.path, work.path)

        guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError("The download didn't contain an app.") }

        // Trust boundary: refuse anything that isn't intact or isn't this app. Ad-hoc signing
        // can't prove who built it — only that it wasn't damaged and claims to be Orbit Flow.
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", newApp.path)
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

    private func run(_ tool: String, _ arguments: String...) throws {
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
