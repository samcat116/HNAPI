import Foundation

public struct Job: Decodable, Sendable, Hashable, Identifiable {
    // MARK: - Error

    enum Error: Swift.Error { case decodingFailed }

    // MARK: - Properties

    public var id: Int
    public var title: String
    public let creation: Date
    public let content: Content

    // MARK: - Decodable

    enum CodingKeys: String, CodingKey {
        case objectID      // search endpoint (String)
        case id            // items endpoint (Int)
        case title
        case creation = "created_at_i"
        case url
        case storyText = "story_text"  // search endpoint
        case text                       // items endpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try objectID first (search endpoint), then id (items endpoint)
        if let objectID = try? container.decode(String.self, forKey: .objectID),
           let parsedId = Int(objectID) {
            self.id = parsedId
        } else if let directId = try? container.decode(Int.self, forKey: .id) {
            self.id = directId
        } else {
            throw Error.decodingFailed
        }

        title = try container.decode(String.self, forKey: .title)
        creation = try container.decode(Date.self, forKey: .creation)

        if let url = try? container.decode(URL.self, forKey: .url) {
            content = .url(url)
        } else if let text = try? container.decode(String.self, forKey: .storyText) {
            content = .text(text)
        } else if let text = try? container.decode(String.self, forKey: .text) {
            content = .text(text)
        } else {
            // Fallback to HN URL
            let url = URL(string: "https://news.ycombinator.com/item?id=\(id)")!
            content = .url(url)
        }
    }
}
