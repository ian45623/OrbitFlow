import OSLog

enum Log {
    static let audio = Logger(subsystem: "ai.pivotstudio.orbitflow", category: "audio")
    static let speech = Logger(subsystem: "ai.pivotstudio.orbitflow", category: "speech")
    static let hotkey = Logger(subsystem: "ai.pivotstudio.orbitflow", category: "hotkey")
    static let inject = Logger(subsystem: "ai.pivotstudio.orbitflow", category: "inject")
    static let app = Logger(subsystem: "ai.pivotstudio.orbitflow", category: "app")
}
