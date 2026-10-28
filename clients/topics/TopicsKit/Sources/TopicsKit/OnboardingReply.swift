import Foundation

/// Reads the onboarding helper's replies: the Gmail scan, then the topics
/// it proposes. Each reply carries one JSON object, usually fenced.
public enum OnboardingReply {
    public enum Scan: Equatable {
        case scanned(threads: Int, areas: [String])
        case unavailable(String)
    }

    public struct Proposal: Equatable, Sendable {
        public let name: String
        public let why: String
        public let about: String
        public let onYourMind: [String]
        public let people: [String]
        public let instructions: String

        init?(_ json: [String: Any]) {
            let name = (json["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.lowercased() != "core" else { return nil }
            self.name = name
            why = json["why"] as? String ?? ""
            about = json["about"] as? String ?? ""
            onYourMind = json["on_your_mind"] as? [String] ?? []
            people = json["people"] as? [String] ?? []
            instructions = json["instructions"] as? String ?? ""
        }
    }

    public static func scan(_ reply: String) -> Scan {
        guard let json = object(in: reply) else {
            let said = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(said.isEmpty ? "Your helper couldn't read Gmail." : said)
        }
        if json["gmail"] as? String == "unavailable" {
            return .unavailable(json["error"] as? String ?? "Your helper couldn't read Gmail.")
        }
        let areas = (json["areas"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return .scanned(threads: json["threads_scanned"] as? Int ?? 0, areas: areas)
    }

    /// At most two core topics and six more.
    public static func proposals(_ reply: String) -> (core: [Proposal], more: [Proposal]) {
        let json = object(in: reply) ?? [:]
        func list(_ key: String, _ limit: Int) -> [Proposal] {
            Array((json[key] as? [[String: Any]] ?? []).compactMap(Proposal.init).prefix(limit))
        }
        return (list("core", 2), list("more", 6))
    }

    /// The first JSON object in a reply, fenced or bare.
    static func object(in reply: String) -> [String: Any]? {
        var text = reply
        if let fence = text.range(of: "```json") ?? text.range(of: "```") {
            text = String(text[fence.upperBound...])
            if let end = text.range(of: "```") { text = String(text[..<end.lowerBound]) }
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }
}
