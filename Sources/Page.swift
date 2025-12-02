import Foundation

public struct Page: Sendable {
    // MARK: - Properties

    public var topLevelItem: TopLevelItem
    public var children: [Comment]
    public var actions: [Int: Set<Action>]

    // MARK: - Init

    init(item: TopLevelItem, children: [Comment], actions: [Int: Set<Action>]) {
        topLevelItem = item
        self.children = children
        self.actions = actions
    }
}
