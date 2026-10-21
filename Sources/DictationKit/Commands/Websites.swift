import AppKit

/// The open-website command: a listed site, or ("other") the one named in what was said — its
/// address when it's one ("weather.com", "gmail dot com"), else DuckDuckGo's first result for it.
enum Websites {
    struct Site: Equatable {
        let value: String
        let name: String
        let url: URL

        /// "Hacker News (news.ycombinator.com)": the name, and the address for the decider.
        var meaning: String { "\(name) (\(url.host() ?? url.absoluteString))" }
    }

    static let sites: [Site] = [
        ("hacker-news", "Hacker News", "https://news.ycombinator.com"), ("google", "Google", "https://www.google.com"),
        ("youtube", "YouTube", "https://www.youtube.com"), ("github", "GitHub", "https://github.com"),
        ("wikipedia", "Wikipedia", "https://www.wikipedia.org"), ("reddit", "Reddit", "https://www.reddit.com"),
        ("twitter", "X", "https://x.com"), ("bbc", "BBC News", "https://www.bbc.com/news"),
        ("nytimes", "The New York Times", "https://www.nytimes.com"), ("amazon", "Amazon", "https://www.amazon.com"),
        ("stackoverflow", "Stack Overflow", "https://stackoverflow.com"), ("gmail", "Gmail", "https://mail.google.com"),
        ("maps", "Google Maps", "https://maps.google.com"), ("weather", "weather.gov", "https://www.weather.gov"),
        ("chatgpt", "ChatGPT", "https://chatgpt.com"),
    ].map { Site(value: $0.0, name: $0.1, url: URL(string: $0.2)!) }

    /// The choice for a site that isn't listed: what was said names it.
    static let other = "other"

    @MainActor
    static func open(_ choice: String?, said: String, opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> CommandResult {
        guard let (name, url) = destination(choice, said: said) else { return CommandResult(ok: false, message: "Which website?") }
        guard opener(url) else { return CommandResult(ok: false, message: "Couldn't open \(name)", details: url.absoluteString) }
        return CommandResult(ok: true, message: "Opened \(name)")
    }

    /// Where a choice goes, and what to call it; nil when nothing names a site.
    static func destination(_ choice: String?, said: String) -> (name: String, url: URL)? {
        if let site = sites.first(where: { $0.value == choice }) { return (site.name, site.url) }
        guard choice == other else { return nil }
        let named = query(said)
        guard !named.isEmpty else { return nil }
        if let address = address(named), let url = URL(string: "https://" + address) { return (address, url) }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: "!ducky " + named)]  // !ducky: the first result
        return search.url.map { ("the first result for “\(named)”", $0) }
    }

    /// What was said, without the words that asked: "Go to the Swift forums website." → "Swift forums".
    static func query(_ said: String) -> String {
        let asking = try! NSRegularExpression(
            pattern: #"^\W*(please\s+|帮我|请)?(open( up)?|go to|take me to|show me|launch|打开|去|进入)(\s+the)?\s*|\s*(website|web site|site|page|网站|网页)\W*$"#,
            options: .caseInsensitive)
        var text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<2 {  // the asking words at the start, then the end
            text = asking.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " ，,。.的!?！？"))
    }

    /// The site's address, when that's what was said: "weather.com", "Gmail dot com", "docs.swift.org".
    static func address(_ named: String) -> String? {
        let address = named.lowercased()
            .replacingOccurrences(of: #"\s*(\bdot\b|\.)\s*"#, with: ".", options: .regularExpression)
        return address.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/\S*)?$"#, options: .regularExpression) != nil ? address : nil
    }
}
