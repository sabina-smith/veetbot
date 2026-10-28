import Foundation
import VeetbotCore

/// Veetbot's topic registry and topic-bound sessions. `VeetbotCore` predates
/// these routes, so they go through its transport directly.
struct TopicsAPI {
    let client: VeetbotAPIClient

    struct ServerTopic: Decodable, Hashable {
        let id: String
        let name: String
    }

    private struct TopicPage: Decodable {
        let items: [ServerTopic]
    }

    /// The parts of a session view the app needs, including `topic_id`.
    struct SessionBinding: Decodable {
        let id: UUID
        let topicID: String?
        let activeRunID: UUID?

        enum CodingKeys: String, CodingKey {
            case id
            case topicID = "topic_id"
            case activeRunID = "active_run_id"
        }
    }

    func list() async throws -> [ServerTopic] {
        let page: TopicPage = try await client.transport.send(
            TransportRequest(method: .get, path: "/v1/topics", retryAttempts: 3)
        )
        return page.items
    }

    func create(id: String, name: String, instructions: String = "") async throws -> ServerTopic {
        try await client.transport.send(TransportRequest(
            method: .post, path: "/v1/topics",
            body: try JSONSerialization.data(withJSONObject: ["id": id, "name": name, "instructions": instructions])
        ))
    }

    func rename(id: String, name: String) async throws -> ServerTopic {
        try await client.transport.send(TransportRequest(
            method: .patch, path: "/v1/topics/\(id)",
            body: try JSONSerialization.data(withJSONObject: ["name": name]),
            retryAttempts: 2
        ))
    }

    /// Creates a session bound to `topicID`, or to no topic (core) when nil.
    func createSession(topicID: String?, metadata: [String: String]) async throws -> SessionBinding {
        var body: [String: Any] = ["agent_id": "general", "metadata": metadata]
        if let topicID { body["topic_id"] = topicID }
        return try await client.transport.send(TransportRequest(
            method: .post, path: "/v1/sessions",
            body: try JSONSerialization.data(withJSONObject: body)
        ))
    }

    func session(_ id: UUID) async throws -> SessionBinding {
        try await client.transport.send(
            TransportRequest(method: .get, path: "/v1/sessions/\(id.uuidString)", retryAttempts: 2)
        )
    }
}
