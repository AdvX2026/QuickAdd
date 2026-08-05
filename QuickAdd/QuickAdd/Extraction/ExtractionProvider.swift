import Foundation

struct ExtractionOutcome {
    var response: ExtractionResponse
    /// Verbatim `content`, persisted on the session for prompt debugging.
    var rawContent: String
    var modelId: String
    /// True when tier 1 failed and the salvage pass rescued the response.
    /// Worth knowing: the spike saw tier 1 succeed on all 8 calls, so a spike
    /// in this would mean something changed upstream.
    var neededSalvage: Bool
}

protocol ExtractionProviding {
    func extract(input: String) async throws -> ExtractionOutcome
}

enum ExtractionError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL(String)
    case http(status: Int, body: String)
    case emptyContent
    case truncated
    case unparseable(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "尚未设置 API Key，请到设置中填写"
        case .invalidBaseURL(let url):
            "接口地址无效：\(url)"
        case .http(let status, _):
            "服务返回错误（HTTP \(status)）"
        case .emptyContent:
            "模型返回了空内容"
        case .truncated:
            "输出被截断，内容可能过长"
        case .unparseable:
            "模型返回的内容不是有效的 JSON"
        case .transport(let message):
            "网络请求失败：\(message)"
        }
    }

    /// Retried exactly once (PRD §8.4). Empty content is a DeepSeek-acknowledged
    /// intermittent fault, and a parse failure is usually non-deterministic too.
    /// HTTP and configuration errors are not retried — they will not fix
    /// themselves and retrying only makes the user wait twice.
    var isRetryable: Bool {
        switch self {
        case .emptyContent, .truncated, .unparseable, .transport:
            true
        case .missingAPIKey, .invalidBaseURL, .http:
            false
        }
    }
}

/// Talks to any OpenAI-compatible `/chat/completions` endpoint.
///
/// One implementation rather than one per vendor: switching models means
/// changing `baseURL`, `modelId`, and the key — no code (PRD §8).
struct OpenAICompatibleProvider: ExtractionProviding {

    let settings: AppSettings
    let session: URLSession

    /// Generous because thinking tokens, when enabled, count against this same
    /// budget (PRD §8.3).
    static let maxTokens = 8000

    init(settings: AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func extract(input: String) async throws -> ExtractionOutcome {
        do {
            return try await attempt(input: input)
        } catch let error as ExtractionError where error.isRetryable {
            // Exactly one retry. No backoff, no loop: on a bad connection the
            // user is staring at a spinner, and a second silent minute is worse
            // than an error they can act on.
            return try await attempt(input: input)
        }
    }

    // MARK: - One round trip

    private func attempt(input: String) async throws -> ExtractionOutcome {
        guard let apiKey = KeychainStore.loadAPIKey() else {
            throw ExtractionError.missingAPIKey
        }
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                                     + "/chat/completions"),
              url.scheme != nil
        else {
            throw ExtractionError.invalidBaseURL(settings.baseURL)
        }

        let prompt = PromptBuilder(settings: settings)
        let body = ChatRequest(
            model: settings.modelId,
            messages: [
                .init(role: "system", content: prompt.staticSegment()),
                .init(role: "system", content: prompt.dynamicSegment()),
                .init(role: "user", content: input),
            ],
            responseFormat: .init(type: "json_object"),
            maxTokens: Self.maxTokens,
            thinking: settings.thinkingEnabled ? nil : .init(type: "disabled")
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ExtractionError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            // Body is kept for the log but never surfaced raw to the user; it
            // can echo request content.
            throw ExtractionError.http(status: status,
                                       body: String(data: data, encoding: .utf8) ?? "")
        }

        let completion = try decodeCompletion(data)
        guard let choice = completion.choices.first else {
            throw ExtractionError.emptyContent
        }

        // Checked before parsing: a truncated document fails to decode anyway,
        // but as a JSON error rather than the actionable "output too long".
        if choice.finishReason == "length" {
            throw ExtractionError.truncated
        }

        let content = choice.message.content ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.emptyContent
        }

        let (parsed, salvaged) = try parse(content)
        return ExtractionOutcome(
            response: parsed,
            rawContent: content,
            modelId: settings.modelId,
            neededSalvage: salvaged
        )
    }

    // MARK: - Parsing (PRD §8.4)

    private func parse(_ content: String) throws -> (ExtractionResponse, Bool) {
        let decoder = JSONDecoder()

        if let direct = try? decoder.decode(ExtractionResponse.self, from: Data(content.utf8)) {
            return (direct, false)
        }
        if let rescued = try? decoder.decode(ExtractionResponse.self,
                                             from: Data(Self.salvage(content).utf8)) {
            return (rescued, true)
        }
        throw ExtractionError.unparseable(content)
    }

    /// Tier 2: strip a code fence, then keep only the outermost braces.
    ///
    /// `json_object` mode makes wrapping unlikely, but the cost of trying is a
    /// few string operations against losing an entire capture.
    static func salvage(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            text = text.replacingOccurrences(
                of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(
                of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            text = String(text[first...last])
        }
        return text
    }

    private func decodeCompletion(_ data: Data) throws -> ChatCompletion {
        do {
            return try JSONDecoder().decode(ChatCompletion.self, from: data)
        } catch {
            throw ExtractionError.unparseable(String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - Wire types

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    struct ResponseFormat: Encodable {
        let type: String
    }
    struct Thinking: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let responseFormat: ResponseFormat
    let maxTokens: Int
    /// Omitted entirely when thinking stays on, since enabled is the default.
    let thinking: Thinking?

    enum CodingKeys: String, CodingKey {
        case model, messages, thinking
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
    }
}

private struct ChatCompletion: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            /// Present when thinking is enabled. Confirmed by the spike to be a
            /// sibling of `content`, never mixed into it.
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}
