import Foundation

/// Which wire format a provider speaks.
///
/// This is the fact the whole tier rests on: every provider in scope speaks one of two
/// formats, so five providers cost one HTTP client with a two-case branch rather than
/// five clients.
public enum Dialect: Sendable {
    case anthropic
    case openAI
}

/// A cloud LLM the user can point the rewrite tier at, using their own API key.
public enum AIProvider: String, CaseIterable, Sendable {
    case anthropic
    case openAI
    case openRouter
    case gemini
    case deepSeek

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .gemini: "Gemini"
        case .deepSeek: "DeepSeek"
        }
    }

    public var dialect: Dialect {
        self == .anthropic ? .anthropic : .openAI
    }

    /// Force-unwrapped because these are compile-time literals. If one is malformed the
    /// crash is at first use in development, which is where you want it.
    public var baseURL: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1")!
        case .openAI: URL(string: "https://api.openai.com/v1")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
        case .deepSeek: URL(string: "https://api.deepseek.com/v1")!
        }
    }

    /// Pre-filled into the model field before the first fetch.
    ///
    /// Haiku 4.5 rather than a larger model because this runs while the user waits for
    /// text to appear — speed is the requirement, and the picker makes a slower, stronger
    /// model one click away for anyone who wants it. The reverse default would make every
    /// user pay for a choice most of them didn't ask for.
    ///
    /// Empty for everyone but Anthropic on purpose. Model lists are fetched from
    /// `GET {base}/models`, and pinning a current model ID for the other four at
    /// authoring time is a guess with a shelf life of a few months.
    public var defaultModel: String {
        self == .anthropic ? "claude-haiku-4-5" : ""
    }

    /// Where the user goes to create a key. The most likely first-run failure is not
    /// having one, and a link is cheaper than a support conversation.
    public var keyURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .openRouter: URL(string: "https://openrouter.ai/keys")!
        case .gemini: URL(string: "https://aistudio.google.com/app/apikey")!
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
        }
    }

    /// The rewrite call.
    ///
    /// Both bodies carry only what the API requires. Optional tuning fields are where
    /// providers and models diverge, and on this path a 400 is invisible — it degrades to
    /// the rule-based pass and the user concludes the feature does nothing.
    ///
    /// The OpenAI-dialect body is deliberately minimal — no `temperature`, no
    /// `max_tokens`. Those two fields are exactly where OpenAI-compatible providers
    /// diverge (newer OpenAI reasoning models reject `temperature` outright and want
    /// `max_completion_tokens`), and a rejected field is a 400, which on the dictation
    /// path is a silent fallback the user reads as "the feature doesn't work". Runaway
    /// length is bounded by the timeout and by `RewriteGuard` instead.
    ///
    // ponytail: minimal body for maximum cross-provider compatibility. If a
    // per-provider override is ever genuinely needed, add it to this switch rather
    // than branching in the caller.
    public func rewriteRequest(
        model: String,
        key: String,
        system: String,
        text: String
    ) -> URLRequest {
        var request: URLRequest
        let body: [String: Any]

        switch dialect {
        case .anthropic:
            request = URLRequest(url: baseURL.appending(path: "messages"))
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                // Required by this API. A ceiling, not a spend — a dictation-length
                // rewrite never approaches it, and thinking tokens share the budget.
                "max_tokens": 8000,
                "system": system,
                "messages": [["role": "user", "content": text]],
                // No `output_config`. An earlier draft sent {"effort": "low"} to cut
                // latency on thinking-by-default models — but Haiku 4.5 *rejects* that
                // field with a 400, and Haiku is the default here precisely because it
                // is the fast one. The field would have broken the fast path while
                // helping only the model most users won't pick. Omitting it also means
                // no per-model capability list to keep current.
            ]

        case .openAI:
            request = URLRequest(url: baseURL.appending(path: "chat/completions"))
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": text],
                ],
            ]
        }

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // .sortedKeys so the golden-body tests are deterministic.
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys]
        )
        return request
    }

    /// `GET {base}/models`. Both dialects expose it and both return `{"data":[{"id":…}]}`,
    /// which is why the model picker is fetched rather than five hardcoded lists that go
    /// stale. It doubles as the "Test connection" check: models back means the key, the
    /// base URL, and the network all work.
    public func modelsRequest(key: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.httpMethod = "GET"
        switch dialect {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
