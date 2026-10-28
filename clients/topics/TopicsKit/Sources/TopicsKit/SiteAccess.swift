import Foundation

/// How far a booking site (Resy, Booksy) has climbed for this owner. With
/// no record the helper can only check what's open; `link` means the owner
/// books it themselves from the helper's link; `signedIn` means the owner
/// signed in once through Veetbot, so the helper can book after their OK.
/// Veetbot keeps the signed-in session; only its id is kept here, never a
/// password.
public struct SiteAccess: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable { case link, signedIn = "signed_in" }

    /// The site's host without `www.`, e.g. "resy.com".
    public var site: String
    public var name: String?
    public var level: Level
    /// Veetbot's browser profile holding the signed-in session.
    public var profileID: UUID?
    public var updatedAt: Date
}

/// Every site's rung, shared by all topics, in one JSON file.
public final class SiteAccessStore {
    private let url: URL
    private var sites: [String: SiteAccess]

    public init(url: URL) throws {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sites = Dictionary(uniqueKeysWithValues: try decoder.decode([SiteAccess].self, from: data).map { ($0.site, $0) })
        } else {
            sites = [:]
        }
    }

    /// "https://www.resy.com/cities/sf" → "resy.com"; nil when it isn't a site.
    public static func site(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let host = URLComponents(string: candidate)?.host?.lowercased(),
            host.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public func access(for siteOrURL: String) -> SiteAccess? {
        Self.site(of: siteOrURL).flatMap { sites[$0] }
    }

    public var all: [SiteAccess] { sites.values.sorted { $0.site < $1.site } }

    /// Sets the site's rung to the owner's latest choice and saves.
    public func record(_ siteOrURL: String, level: SiteAccess.Level, profileID: UUID? = nil, name: String? = nil) throws {
        guard let site = Self.site(of: siteOrURL) else {
            throw ProposalError(message: "\(siteOrURL) isn't a website.")
        }
        sites[site] = SiteAccess(
            site: site, name: name ?? sites[site]?.name, level: level,
            profileID: level == .signedIn ? profileID : nil, updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(all).write(to: url, options: .atomic)
    }

    /// One line per site, for the helper.
    public var summary: String {
        guard !sites.isEmpty else { return "(none yet)" }
        return all.map { access in
            "- \(access.site)\(access.name.map { " (\($0))" } ?? ""): "
                + (access.level == .signedIn ? "the owner signed in" : "the owner books from your link")
        }.joined(separator: "\n")
    }
}
