import Foundation

public struct User: Decodable, Sendable, Hashable {
    public let id: String
    public let created: Date
    public let karma: Int
    public let about: String?
    public let submitted: [Int]?

    enum CodingKeys: String, CodingKey {
        case id
        case created
        case karma
        case about
        case submitted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        karma = try container.decodeIfPresent(Int.self, forKey: .karma) ?? 0
        about = try container.decodeIfPresent(String.self, forKey: .about)
        submitted = try container.decodeIfPresent([Int].self, forKey: .submitted)

        // Firebase returns created as Unix timestamp (seconds since 1970)
        let timestamp = try container.decode(Int.self, forKey: .created)
        created = Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    // MARK: - Computed Properties

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    public var createdDate: String {
        Self.dateFormatter.string(from: created)
    }

    public var accountAge: String {
        let now = Date()
        let interval = now.timeIntervalSince(created)

        let days = Int(interval / 86400)
        if days < 30 {
            return "\(days) days"
        } else if days < 365 {
            let months = days / 30
            return "\(months) months"
        } else {
            let years = days / 365
            return "\(years) years"
        }
    }
}
