import Foundation

/// The real teacher: a model through OpenRouter. The app's tuner (`LearnController.appTuner`) and the
/// teacher bake-off (`TeacherBakeoffTests`) both ask it this way.
extension PromptTuner {
    /// `model` thinking at `reasoning`, its answer and what the call used and cost.
    static func openRouterTeacher(model: String, apiKey: String, reasoning: [String: Any] = ["effort": "medium"],
                                  session: URLSession = .shared) -> Teacher {
        { request in
            let (data, status) = try await OpenRouter.send(teacherURLRequest(request, model: model, apiKey: apiKey, reasoning: reasoning),
                                                           session: session)
            let json = OpenRouter.json(data)
            guard let text = OpenRouter.content(json, status: status) else {
                throw PolishError.failed(OpenRouter.problem(json, status: status))
            }
            return TeacherAnswer(text: text, usage: OpenRouter.Usage(json))
        }
    }

    /// A fold's lens call (it has a `cacheKey`) marks its shared part cacheable where the model needs a
    /// breakpoint, and names the fold as its `session_id`: OpenRouter then routes the fold's later calls
    /// to the provider that served the first, which holds the cache (without one, routing sticks only
    /// after a cache hit). The final call is a plain request.
    static func teacherURLRequest(_ request: TeacherRequest, model: String, apiKey: String, reasoning: [String: Any]) -> URLRequest {
        guard let key = request.cacheKey else {
            return OpenRouter.chat(model: model, system: request.system, user: request.user, apiKey: apiKey, reasoning: reasoning)
        }
        return OpenRouter.chat(model: model, system: request.system,
                               userContent: OpenRouter.content(caching: request.prefix, then: request.task, model: model),
                               apiKey: apiKey, reasoning: reasoning, extra: ["session_id": key])
    }
}
