import Foundation

/// `DictationApp vocabulary …`: your terms, listed and changed from a shell. Changes go to
/// vocabulary.json, which the running app re-reads at its next dictation (or when the Vocabulary
/// tab is shown), so there's nothing to notify.
///
///   DictationApp vocabulary [list] [--json]
///   DictationApp vocabulary add <term> [--heard a,b]   a term, or more variants for one you have
///   DictationApp vocabulary remove <term>
///
/// A term can be several words, quoted or not. Exit status: 0 done, 1 no such term, 2 bad usage.
enum VocabularyCommand {
    struct IO {
        var out: (String) -> Void = { print($0) }
        var err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    }

    /// Runs the command and returns its exit status when the app was started as `DictationApp vocabulary …`;
    /// nil otherwise (start the app).
    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.dropFirst().first == "vocabulary" else { return nil }
        // The same file AppServices.live() reads.
        return run(Array(arguments.dropFirst(2)), store: VocabularyStore())
    }

    static func run(_ arguments: [String], store: VocabularyStore, io: IO = IO()) -> Int32 {
        let json = arguments.contains("--json")
        var args = arguments.filter { $0 != "--json" }
        var heard: [String] = []
        if let flag = args.firstIndex(of: "--heard") {
            guard flag + 1 < args.count else { io.err(usage); return 2 }
            heard = VocabularyEntry.variants(from: args[flag + 1])
            args.removeSubrange(flag...(flag + 1))
        }
        let term = args.dropFirst().joined(separator: " ")
        switch args.first {
        case nil, "list" where args.count == 1 && heard.isEmpty:
            list(store.entries, json: json, io: io)
            return 0
        case "add" where !term.isEmpty:
            let existed = store.entries.contains { $0.term.caseInsensitiveCompare(term) == .orderedSame }
            guard let entry = store.add(term: term, heardAs: heard) else { io.err(usage); return 2 }
            io.out((existed ? "updated " : "added ") + line(entry))
            return 0
        case "remove" where !term.isEmpty && heard.isEmpty:
            guard store.remove(term: term) else {
                io.err("no term \"\(term)\"; `DictationApp vocabulary` lists them")
                return 1
            }
            io.out("removed \(term)")
            return 0
        case "help", "--help", "-h":
            io.out(usage)
            return 0
        default:
            io.err(usage)
            return 2
        }
    }

    static let usage = """
        usage: DictationApp vocabulary [list] [--json]
               DictationApp vocabulary add <term> [--heard a,b]
               DictationApp vocabulary remove <term>
        """

    /// "GeForce Now  (heard as: G Four Snow, g force now) · used 9 times · off".
    private static func line(_ entry: VocabularyEntry) -> String {
        var parts = [entry.term + (entry.heardAs.isEmpty ? "" : "  (heard as: \(entry.heardAs.joined(separator: ", ")))")]
        if entry.uses > 0 { parts.append("used \(entry.uses) time\(entry.uses == 1 ? "" : "s")") }
        if entry.source == .learned { parts.append("learned") }
        if !entry.enabled { parts.append("off") }
        return parts.joined(separator: " · ")
    }

    private static func list(_ entries: [VocabularyEntry], json: Bool, io: IO) {
        if json {
            let data = (try? JSONFile.prettyEncoder.encode(entries)) ?? Data("[]".utf8)
            io.out(String(decoding: data, as: UTF8.self))
            return
        }
        for entry in entries { io.out(line(entry)) }
    }
}
