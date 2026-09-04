import Foundation

/// Why a cloud round-trip didn't produce usable text.
///
/// Every case degrades to the rule-based formatter at the call site — this type exists to
/// make the *reason* legible in the log and in the Settings "Test" result, because the
/// cases mean very different things: `http(401)` is a bad key the user must fix,
/// `timedOut` is a slow network that may work next time, and `rejected` is the model
/// misbehaving on content that was probably fine.
public enum RewriteFailure: Error, Equatable {
    case timedOut
    case http(status: Int, message: String?)
    case unreadableResponse
    case rejected(Rejection)

    /// Safe to log. Never contains the API key — the key is not a member of this type and
    /// must never be interpolated into one of these strings.
    public var summary: String {
        switch self {
        case .timedOut:
            "timed out"
        case .http(let status, let message):
            "HTTP \(status)" + (message.map { ": \($0)" } ?? "")
        case .unreadableResponse:
            "unreadable response"
        case .rejected(let reason):
            "rejected — \(reason.summary)"
        }
    }
}

/// One round-trip to a cloud provider: build, send, parse, guard.
///
/// The transport is injected so the entire path is testable without a network. The
/// default is `URLSession.shared`.
public struct CloudRewriter: Sendable {
    /// How a request is actually sent. Injected so every path here — success, HTTP error,
    /// timeout, guard rejection — is testable with no network and no mock framework.
    ///
    /// **A transport MUST honor Task cancellation.** The timeout is a task-group race, and
    /// a task group does not return to its caller until every child task has finished —
    /// including the one that lost. A transport that ignores cancellation therefore makes
    /// `rewrite` and `models` hang past the timeout no matter what the timeout says, which
    /// breaks the one guarantee the caller relies on: that this always completes, so a
    /// stalled network costs the user a fallback rather than the sentence they just spoke.
    /// The default satisfies this — `URLSession` propagates cancellation to its task.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let provider: AIProvider
    private let key: String
    private let timeout: Duration
    private let transport: Transport

    /// - Parameter timeout: 8 seconds by default. Longer than the on-device formatter's
    ///   4s because a network round-trip is in play; short enough that the caller's
    ///   fallback fires before the user gives up on the paste.
    public init(
        provider: AIProvider,
        key: String,
        timeout: Duration = .seconds(8),
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.provider = provider
        self.key = key
        self.timeout = timeout
        self.transport = transport
    }

    public func rewrite(
        _ text: String,
        model: String,
        mode: RewriteMode
    ) async throws -> String {
        try await rewrite(text, model: model, system: mode.systemPrompt, checking: mode)
    }

    /// - Parameters:
    ///   - system: The whole system prompt. Callers with a user-written instruction build
    ///     it with `RewriteMode.customSystemPrompt`, which keeps the shared preamble.
    ///   - mode: The mode whose guard to apply, or `nil` to skip the guard. Only skip it
    ///     where the result is shown to the user rather than typed into their document:
    ///     an instruction like "make this three bullets" legitimately blows the length
    ///     band, and there is no way to tell that from a model that went off the rails.
    public func rewrite(
        _ text: String,
        model: String,
        system: String,
        checking mode: RewriteMode?
    ) async throws -> String {
        let request = provider.rewriteRequest(
            model: model, key: key, system: system, text: text
        )
        let data = try await send(request)

        guard let raw = AIResponse.text(from: data, dialect: provider.dialect) else {
            throw RewriteFailure.unreadableResponse
        }
        let output = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let mode,
           let reason = RewriteGuard.rejection(original: text, output: output, mode: mode) {
            throw RewriteFailure.rejected(reason)
        }
        return output
    }

    /// Doubles as the connection test: models back means the key, the base URL, and the
    /// network all work. An empty list is a failure so that Test can't report success on
    /// a response it didn't understand.
    public func models() async throws -> [String] {
        let data = try await send(provider.modelsRequest(key: key))
        let ids = AIResponse.modelIDs(from: data)
        guard !ids.isEmpty else { throw RewriteFailure.unreadableResponse }
        return ids.sorted()
    }

    /// Races the request against the timeout. Same shape as `FoundationModelFormatter`'s
    /// timeout race, for the same reason: a stalled model must never cost the user an
    /// utterance they already spoke.
    private func send(_ request: URLRequest) async throws -> Data {
        let transport = self.transport
        let timeout = self.timeout

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (data, response) = try await transport(request)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw RewriteFailure.http(
                        status: http.statusCode,
                        message: AIResponse.errorMessage(from: data)
                    )
                }
                return data
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RewriteFailure.timedOut
            }
            // Whichever finishes first wins. On this path we cancel the loser explicitly;
            // on the throwing path the group cancels it implicitly at scope exit. Either
            // way the loser's own error is discarded, which is what we want — a late
            // failure from a request we already gave up on is not the user's problem.
            guard let first = try await group.next() else { throw RewriteFailure.timedOut }
            group.cancelAll()
            return first
        }
    }
}
