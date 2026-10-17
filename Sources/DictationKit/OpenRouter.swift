import Foundation

/// Uploads a finished WAV for transcription (OpenRouterClient; a fake in tests).
protocol TranscriptionClient {
    @discardableResult
    func transcribe(wav: URL, model: String, apiKey: String,
                    completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask?
}

/// What every OpenRouter call shares (speech and polish).
enum OpenRouter {
    /// A POST to `url` with the API key and the app's name.
    static func request(_ url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("DictationApp", forHTTPHeaderField: "X-Title")
        return request
    }

    /// A response body as a JSON object, or nil.
    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The `error.message` OpenRouter puts in a failed response.
    static func errorMessage(_ json: [String: Any]?) -> String? {
        (json?["error"] as? [String: Any])?["message"] as? String
    }
}

/// Minimal client for OpenRouter's speech-to-text endpoint (multipart WAV upload).
final class OpenRouterClient: TranscriptionClient {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    @discardableResult
    func transcribe(wav: URL, model: String, apiKey: String,
                    completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask? {
        guard let audio = try? Data(contentsOf: wav) else {
            completion(.failure(TranscriptionError.message("Couldn't read the recording.")))
            return nil
        }
        let (body, boundary) = Self.multipart(model: model, audio: audio, filename: wav.lastPathComponent)
        var request = OpenRouter.request(Self.endpoint, apiKey: apiKey)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: request, from: body) { data, response, error in
            let result: Result<String, Error>
            if let error = error {
                result = .failure(TranscriptionError.message("Network error: \(error.localizedDescription)"))
            } else {
                result = Self.parse(data: data ?? Data(), status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }

    static func multipart(model: String, audio: Data, filename: String) -> (Data, String) {
        let boundary = "DictationApp-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(audio)
        add("\r\n--\(boundary)--\r\n")
        return (body, boundary)
    }

    static func parse(data: Data, status: Int) -> Result<String, Error> {
        let json = OpenRouter.json(data)
        if (200..<300).contains(status), let text = json?["text"] as? String {
            return .success(cleanup(text))
        }
        let apiMessage = OpenRouter.errorMessage(json)
        switch status {
        case 401: return .failure(TranscriptionError.message("The cloud service rejected the API key — check it in Settings."))
        case 402: return .failure(TranscriptionError.message("The cloud account is out of credits."))
        case 403: return .failure(TranscriptionError.message("The cloud account needs to be set up before this model can be used."))
        default: return .failure(TranscriptionError.message(apiMessage ?? "Transcription failed (HTTP \(status))."))
        }
    }

    /// Tidies model quirks, e.g. "meeting??" / "meeting?." → "meeting?".
    static func cleanup(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"([?!？！])[.。]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([.?!。？！])\1+"#, with: "$1", options: .regularExpression)
        return s
    }
}
