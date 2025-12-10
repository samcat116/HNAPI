import Foundation

/// Thread-safe LRU cache with optional TTL support
public actor Cache {
    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let maxItems: Int
        public let maxPages: Int
        public let maxUsers: Int
        public let maxCategories: Int
        public let maxSearchResults: Int
        public let maxCommentTrees: Int
        public let ttl: TimeInterval?

        public init(
            maxItems: Int = 200,
            maxPages: Int = 50,
            maxUsers: Int = 50,
            maxCategories: Int = 10,
            maxSearchResults: Int = 20,
            maxCommentTrees: Int = 50,
            ttl: TimeInterval? = 300
        ) {
            self.maxItems = maxItems
            self.maxPages = maxPages
            self.maxUsers = maxUsers
            self.maxCategories = maxCategories
            self.maxSearchResults = maxSearchResults
            self.maxCommentTrees = maxCommentTrees
            self.ttl = ttl
        }

        public static let `default` = Configuration()
    }

    // MARK: - Cache Entry

    private struct Entry<T: Sendable>: Sendable {
        let value: T
        let timestamp: Date

        func isValid(ttl: TimeInterval?) -> Bool {
            guard let ttl = ttl else { return true }
            return Date().timeIntervalSince(timestamp) < ttl
        }
    }

    // MARK: - Properties

    private let configuration: Configuration
    private var items: [Int: Entry<TopLevelItem>] = [:]
    private var itemAccessOrder: [Int] = []
    private var pages: [Int: Entry<Page>] = [:]
    private var pageAccessOrder: [Int] = []
    private var users: [String: Entry<User>] = [:]
    private var userAccessOrder: [String] = []
    private var categoryIds: [Category: Entry<[Int]>] = [:]
    private var categoryAccessOrder: [Category] = []
    private var searchResults: [String: Entry<[TopLevelItem]>] = [:]
    private var searchAccessOrder: [String] = []
    private var commentTrees: [Int: Entry<[Comment]>] = [:]
    private var commentTreeAccessOrder: [Int] = []

    // MARK: - Init

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Items

    public func item(for id: Int) -> TopLevelItem? {
        guard let entry = items[id], entry.isValid(ttl: configuration.ttl) else {
            items.removeValue(forKey: id)
            return nil
        }
        updateAccessOrder(id: id, in: &itemAccessOrder)
        return entry.value
    }

    public func setItem(_ item: TopLevelItem) {
        let id = item.id
        items[id] = Entry(value: item, timestamp: Date())
        updateAccessOrder(id: id, in: &itemAccessOrder)
        evictIfNeeded(cache: &items, order: &itemAccessOrder, maxSize: configuration.maxItems)
    }

    public func items(for ids: [Int]) -> [Int: TopLevelItem] {
        var result: [Int: TopLevelItem] = [:]
        for id in ids {
            if let item = item(for: id) {
                result[id] = item
            }
        }
        return result
    }

    public func setItems(_ newItems: [TopLevelItem]) {
        for item in newItems {
            setItem(item)
        }
    }

    // MARK: - Pages

    public func page(for id: Int) -> Page? {
        guard let entry = pages[id], entry.isValid(ttl: configuration.ttl) else {
            pages.removeValue(forKey: id)
            return nil
        }
        updateAccessOrder(id: id, in: &pageAccessOrder)
        return entry.value
    }

    public func setPage(_ page: Page, for id: Int) {
        pages[id] = Entry(value: page, timestamp: Date())
        updateAccessOrder(id: id, in: &pageAccessOrder)
        evictIfNeeded(cache: &pages, order: &pageAccessOrder, maxSize: configuration.maxPages)
    }

    // MARK: - Users

    public func user(for username: String) -> User? {
        guard let entry = users[username], entry.isValid(ttl: configuration.ttl) else {
            users.removeValue(forKey: username)
            return nil
        }
        updateAccessOrder(id: username, in: &userAccessOrder)
        return entry.value
    }

    public func setUser(_ user: User) {
        users[user.id] = Entry(value: user, timestamp: Date())
        updateAccessOrder(id: user.id, in: &userAccessOrder)
        evictIfNeeded(cache: &users, order: &userAccessOrder, maxSize: configuration.maxUsers)
    }

    // MARK: - Category IDs

    public func categoryIds(for category: Category) -> [Int]? {
        guard let entry = categoryIds[category], entry.isValid(ttl: configuration.ttl) else {
            categoryIds.removeValue(forKey: category)
            return nil
        }
        updateAccessOrder(id: category, in: &categoryAccessOrder)
        return entry.value
    }

    public func setCategoryIds(_ ids: [Int], for category: Category) {
        categoryIds[category] = Entry(value: ids, timestamp: Date())
        updateAccessOrder(id: category, in: &categoryAccessOrder)
        evictIfNeeded(cache: &categoryIds, order: &categoryAccessOrder, maxSize: configuration.maxCategories)
    }

    // MARK: - Search Results

    public func searchResults(for query: String) -> [TopLevelItem]? {
        guard let entry = searchResults[query], entry.isValid(ttl: configuration.ttl) else {
            searchResults.removeValue(forKey: query)
            return nil
        }
        updateAccessOrder(id: query, in: &searchAccessOrder)
        return entry.value
    }

    public func setSearchResults(_ items: [TopLevelItem], for query: String) {
        searchResults[query] = Entry(value: items, timestamp: Date())
        updateAccessOrder(id: query, in: &searchAccessOrder)
        evictIfNeeded(cache: &searchResults, order: &searchAccessOrder, maxSize: configuration.maxSearchResults)
    }

    // MARK: - Comment Trees

    public func comments(for itemId: Int) -> [Comment]? {
        guard let entry = commentTrees[itemId], entry.isValid(ttl: configuration.ttl) else {
            commentTrees.removeValue(forKey: itemId)
            return nil
        }
        updateAccessOrder(id: itemId, in: &commentTreeAccessOrder)
        return entry.value
    }

    public func setComments(_ comments: [Comment], for itemId: Int) {
        commentTrees[itemId] = Entry(value: comments, timestamp: Date())
        updateAccessOrder(id: itemId, in: &commentTreeAccessOrder)
        evictIfNeeded(cache: &commentTrees, order: &commentTreeAccessOrder, maxSize: configuration.maxCommentTrees)
    }

    // MARK: - Clear

    public func clear() {
        items.removeAll()
        itemAccessOrder.removeAll()
        pages.removeAll()
        pageAccessOrder.removeAll()
        users.removeAll()
        userAccessOrder.removeAll()
        categoryIds.removeAll()
        categoryAccessOrder.removeAll()
        searchResults.removeAll()
        searchAccessOrder.removeAll()
        commentTrees.removeAll()
        commentTreeAccessOrder.removeAll()
    }

    // MARK: - Private Helpers

    private func updateAccessOrder<K: Hashable>(id: K, in order: inout [K]) {
        if let index = order.firstIndex(of: id) {
            order.remove(at: index)
        }
        order.append(id)
    }

    private func evictIfNeeded<K: Hashable, V>(cache: inout [K: Entry<V>], order: inout [K], maxSize: Int) {
        while order.count > maxSize {
            let oldestKey = order.removeFirst()
            cache.removeValue(forKey: oldestKey)
        }
    }
}
