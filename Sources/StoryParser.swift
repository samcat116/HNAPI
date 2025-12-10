import Foundation
import SwiftSoup

class StoryParser {
    // MARK: - Properties

    var document: Document

    lazy var fatItemEl: Element? = try! document.select(".fatitem").first()
    lazy var aThingEls: Elements = try! document.select(".athing")
    lazy var ids: [Int] = aThingEls.compactMap { Int($0.id()) }
    lazy var storyID: Int? = ids.first

    // MARK: - Init

    init(html: String) throws { document = try Parser.parse(html, "https://news.ycombinator.com/") }

    // MARK: - Methods

    func aThingEl(id: Int) -> Element? { return aThingEls.first(where: { $0.id() == "\(id)" }) }

    func commTextEl(id: Int) -> Element? {
        let aThingEl = self.aThingEl(id: id)
        let commTextEl = try! aThingEl?.select(".commtext").array().first
        return commTextEl
    }

    func commentColors() -> [Int: Comment.Color] {
        var commentColors: [Int: Comment.Color] = [:]
        for id in ids {
            guard let commTextEl = self.commTextEl(id: id) else { continue }
            for color in Comment.Color.allCases {
                if commTextEl.hasClass(color.rawValue) {
                    commentColors[id] = color
                    break
                }
            }
        }
        return commentColors
    }

    func voteLinkEls(id: Int) -> [Element] {
        let aThingEl = self.aThingEl(id: id)
        let voteLinkEls =
            try! aThingEl?.select(".votelinks a:has(.votearrow):not(.nosee)").array() ?? []
        return voteLinkEls
    }

    func unvoteLinkEl(id: Int) -> Element? {
        let containerEl: Element?
        if id == storyID { containerEl = fatItemEl } else { containerEl = self.aThingEl(id: id) }
        let unvoteLinkEl = try! containerEl?.select("[id^=unv] > a").first()
        return unvoteLinkEl
    }

    func actions() -> [Int: Set<Action>] {
        var actions: [Int: Set<Action>] = [:]
        let base = URL(string: "https://news.ycombinator.com")!
        for id in ids {
            var actionSet: Set<Action> = []
            let voteLinkEls = self.voteLinkEls(id: id)
            for voteLinkEl in voteLinkEls {
                let href = try! voteLinkEl.attr("href")
                guard var components = URLComponents(string: href) else { continue }
                if components.queryItems?.contains(where: { $0.name == "auth" }) == false {
                    continue
                }
                components.queryItems?.removeAll(where: { $0.name == "goto" })
                guard let url = components.url(relativeTo: base) else { continue }
                guard let voteArrowEl = try! voteLinkEl.select(".votearrow").array().first else {
                    continue
                }
                let title = try! voteArrowEl.attr("title")
                switch title {
                case "upvote": actionSet.insert(.upvote(url))
                case "downvote": actionSet.insert(.downvote(url))
                default: break
                }
            }
            if let unvoteLinkEl = self.unvoteLinkEl(id: id) {
                let href = try! unvoteLinkEl.attr("href")
                if let url = URL(string: href, relativeTo: base) {
                    let text = try! unvoteLinkEl.text()
                    switch text {
                    case "unvote": actionSet.insert(.unvote(url))
                    case "undown": actionSet.insert(.undown(url))
                    default: break
                    }
                }
            }
            actions[id] = actionSet
        }
        return actions
    }

    func sortedCommentTree(original: [Comment], colors: [Int: Comment.Color]? = nil) -> [Comment] {
        let colors = colors ?? self.commentColors()
        let sortedTree = original.sorted { left, right in
            guard let leftIndex = ids.firstIndex(of: left.id) else { return false }
            guard let rightIndex = ids.firstIndex(of: right.id) else { return true }
            return leftIndex < rightIndex
        }
        return sortedTree.map { comment in
            var updatedComment = comment
            // TODO: Decide whether color should be given for ones that aren't found. cdd, perhaps.
            if let color = colors[comment.id] { updatedComment.color = color }
            updatedComment.children = sortedCommentTree(original: comment.children, colors: colors)
            return updatedComment
        }
    }

    // MARK: - HTML-Only Comment Parsing

    /// Intermediate struct for flat comment data before tree building
    struct FlatComment {
        let id: Int
        let author: String
        let text: String
        let creation: Date
        let depth: Int
        let color: Comment.Color
    }

    /// Parse comments directly from HTML without needing Algolia API.
    /// Returns a flat list of comments with depth information.
    func parseComments() -> [FlatComment] {
        var comments: [FlatComment] = []

        // Get all comment table rows (skip first which is the story)
        let commentRows = aThingEls.dropFirst()

        for el in commentRows {
            guard let id = Int(el.id()) else { continue }

            // Get the indent level from the spacer image's parent td
            // HTML structure: <td class="ind" indent="N">
            let depth: Int
            if let indentTd = try? el.select("td.ind").first(),
               let indentAttr = try? indentTd.attr("indent"),
               let indentValue = Int(indentAttr) {
                depth = indentValue
            } else {
                depth = 0
            }

            // Get author from .hnuser
            let author: String
            if let hnuserEl = try? el.select(".hnuser").first() {
                author = (try? hnuserEl.text()) ?? ""
            } else {
                // Deleted comment - skip it
                continue
            }

            // Get timestamp from .age title attribute (has Unix epoch)
            let creation: Date
            if let ageEl = try? el.select(".age").first(),
               let title = try? ageEl.attr("title") {
                // Title format: "2024-12-09T06:44:05 1733726645"
                let parts = title.split(separator: " ")
                if parts.count >= 2, let epoch = TimeInterval(parts[1]) {
                    creation = Date(timeIntervalSince1970: epoch)
                } else {
                    creation = Date()
                }
            } else {
                creation = Date()
            }

            // Get comment text HTML from .commtext
            let text: String
            let color: Comment.Color
            if let commTextEl = try? el.select(".commtext").first() {
                text = (try? commTextEl.html()) ?? ""
                // Check for color class
                color = Comment.Color.allCases.first { commTextEl.hasClass($0.rawValue) } ?? .c00
            } else {
                text = ""
                color = .c00
            }

            comments.append(FlatComment(
                id: id,
                author: author,
                text: text,
                creation: creation,
                depth: depth,
                color: color
            ))
        }

        return comments
    }

    /// Build a nested comment tree from a flat list with depth information.
    /// Uses a stack-based O(n) algorithm.
    func buildCommentTree(from flatComments: [FlatComment]) -> [Comment] {
        guard !flatComments.isEmpty else { return [] }

        // Stack holds (comment, depth) - we'll attach children as we go
        var stack: [(comment: Comment, depth: Int)] = []
        var roots: [Comment] = []

        for flat in flatComments {
            let comment = Comment(
                id: flat.id,
                creation: flat.creation,
                author: flat.author,
                text: flat.text,
                color: flat.color,
                children: []
            )

            // Pop stack until we find the parent (depth = flat.depth - 1)
            while !stack.isEmpty && stack.last!.depth >= flat.depth {
                let (child, _) = stack.removeLast()
                if stack.isEmpty {
                    roots.append(child)
                } else {
                    stack[stack.count - 1].comment.children.append(child)
                }
            }

            stack.append((comment, flat.depth))
        }

        // Flush remaining stack
        while !stack.isEmpty {
            let (child, _) = stack.removeLast()
            if stack.isEmpty {
                roots.append(child)
            } else {
                stack[stack.count - 1].comment.children.append(child)
            }
        }

        return roots
    }

    /// Convenience method to parse and build comment tree in one call.
    func commentsFromHTML() -> [Comment] {
        let flatComments = parseComments()
        return buildCommentTree(from: flatComments)
    }
}
