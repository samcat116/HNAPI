import Foundation

public enum TopLevelItem: Sendable, Hashable, Identifiable {
    case story(Story)
    case job(Job)

    public var id: Int {
        switch self {
        case let .story(story): return story.id
        case let .job(job): return job.id
        }
    }

    public var url: URL {
        // FIXME: Don't hardcode this string
        URL(string: "https://news.ycombinator.com/item?id=\(id)")!
    }

    public var story: Story? {
        switch self {
        case let .story(story): return story
        case .job: return nil
        }
    }

    public var job: Job? {
        switch self {
        case let .job(job): return job
        case .story: return nil
        }
    }

    // MARK: - Convenience Properties for Views

    public var title: String {
        switch self {
        case .story(let s): return s.title
        case .job(let j): return j.title
        }
    }

    public var author: String? {
        switch self {
        case .story(let s): return s.author
        case .job: return nil
        }
    }

    public var points: Int? {
        story?.points
    }

    public var commentCount: Int {
        story?.commentCount ?? 0
    }

    public var creation: Date {
        switch self {
        case .story(let s): return s.creation
        case .job(let j): return j.creation
        }
    }

    public var content: Content {
        switch self {
        case .story(let s): return s.content
        case .job(let j): return j.content
        }
    }

    public var contentURL: URL? {
        content.url
    }

    public var contentText: String? {
        content.text
    }

    public var timeAgo: String {
        let now = Date()
        let interval = now.timeIntervalSince(creation)

        let hours = Int(interval / 3600)
        if hours < 1 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if hours < 24 {
            return "\(hours)h ago"
        } else {
            let days = hours / 24
            return "\(days)d ago"
        }
    }

    public var domain: String? {
        guard let url = contentURL, let host = url.host else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    public var hackerNewsURL: URL {
        url
    }
}

// MARK: - Decodable

extension TopLevelItem: Decodable {
    // MARK: - Error

    enum Error: Swift.Error { case decodingFailed }

    enum CodingKeys: String, CodingKey {
        case tags = "_tags"
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try _tags first (search endpoint format)
        if let tags = try? container.decode([String].self, forKey: .tags) {
            if tags.contains("story") {
                let story = try decoder.singleValueContainer().decode(Story.self)
                self = .story(story)
                return
            } else if tags.contains("job") {
                let job = try decoder.singleValueContainer().decode(Job.self)
                self = .job(job)
                return
            }
        }

        // Fall back to type field (items endpoint format)
        if let type = try? container.decode(String.self, forKey: .type) {
            if type == "story" {
                let story = try decoder.singleValueContainer().decode(Story.self)
                self = .story(story)
                return
            } else if type == "job" {
                let job = try decoder.singleValueContainer().decode(Job.self)
                self = .job(job)
                return
            }
        }

        throw Error.decodingFailed
    }
}
