import Foundation

/// Uploads a finished WAV for transcription (OpenRouterClient; a fake in tests).
protocol TranscriptionClient {
    @discardableResult
    func transcribe(wav: URL, model: SpeechRoute, apiKey: String,
                    completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask?
}

/// Minimal client for OpenRouter's speech-to-text endpoint (multipart WAV upload). With hosts named on
/// the model's route, only those are used (OpenRouter honours `provider` here too).
final class OpenRouterClient: TranscriptionClient {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    private let session: URLSession
    /// Every request's outcome: model, HTTP status, seconds, and the API's error (`CloudLog`).
    private let log: CloudLog

    init(session: URLSession = URLSession.shared, log: CloudLog = .speech) {
        self.session = session
        self.log = log
    }

    @discardableResult
    func transcribe(wav: URL, model route: SpeechRoute, apiKey: String,
                    completion: @escaping (Result<String, Error>) -> Void) -> URLSessionTask? {
        guard let audio = try? Data(contentsOf: wav) else {
            completion(.failure(TranscriptionError.message("Couldn't read the recording.")))
            return nil
        }
        let (body, boundary) = Self.multipart(model: route, audio: audio, filename: wav.lastPathComponent)
        var request = OpenRouter.request(Self.endpoint, apiKey: apiKey)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let started = Date(), log = log, model = route.name  // as the log names it
        let task = session.uploadTask(with: request, from: body) { data, response, error in
            let result: Result<String, Error>
            let took = CloudLog.seconds(Date().timeIntervalSince(started))
            if let error = error {
                result = .failure(TranscriptionError.message("Network error: \(error.localizedDescription)"))
                if (error as? URLError)?.code == .cancelled {
                    log.info("\(model): cancelled after \(took) (another model answered first)")
                } else {
                    log.error("\(model): network error after \(took): \(error.localizedDescription)")
                }
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = Self.parse(data: data ?? Data(), status: status)
                switch result {
                case .success: log.info("\(model): HTTP \(status) in \(took)")
                case .failure(let failure): log.error("\(model): HTTP \(status) in \(took): \(failure.localizedDescription)")
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }

    static func multipart(model: SpeechRoute, audio: Data, filename: String) -> (Data, String) {
        let boundary = "DictationApp-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        func field(_ name: String, _ value: String) {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", model.id)
        if let hosts = model.pinned, let pin = try? JSONSerialization.data(withJSONObject: OpenRouter.provider(hosts), options: .sortedKeys) {
            field("provider", String(decoding: pin, as: UTF8.self))
        }
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
