import Foundation
import SwiftSoup

public struct Comment: Decodable, Sendable {
    public enum Color: String, CaseIterable, Sendable {
        case c00
        case c5a
        case c73
        case c82
        case c88
        case c9c
        case cae
        case cbe
        case cce
        case cdd
    }

    // MARK: - Properties

    public let id: Int
    public let creation: Date
    public let author: String
    public let text: String
    let isDeleted: Bool
    public var color: Color
    public var children: [Comment]
    public var commentCount: Int { children.reduce(1, { $0 + $1.commentCount }) }

    // MARK: - Decodable

    enum CodingKeys: String, CodingKey {
        case id
        case creation = "created_at_i"
        case author
        case text
        case children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        creation = try container.decode(Date.self, forKey: .creation)

        // Handle deleted comments that may be missing text/author
        let decodedText = try? container.decode(String.self, forKey: .text)
        let decodedAuthor = try? container.decode(String.self, forKey: .author)

        if let text = decodedText, let author = decodedAuthor {
            self.text = text
            self.author = author
            isDeleted = false
        } else {
            self.text = ""
            self.author = ""
            isDeleted = true
        }

        children = try container.decode([Comment].self, forKey: .children).filter { !$0.isDeleted }
        color = .c00
    }
}
