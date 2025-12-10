import Foundation

// MARK: - Array Chunking Extension

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// URLSession delegate that blocks redirects, used for login flow
private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        return nil
    }
}

public actor APIClient {
    // MARK: - Error

    public enum APIError: Error, LocalizedError, Sendable {
        case loginFailed
        case unknown

        public var errorDescription: String? {
            switch self {
            case .loginFailed: return "Login Failed."
            case .unknown: return "Unknown Error."
            }
        }
    }

    // MARK: - Properties

    private let networkClient: any NetworkClient
    private let networkClientWithoutRedirection: any NetworkClient
    private let decoder: JSONDecoder
    private let cache: Cache
    private let retryConfiguration: RetryConfiguration

    /// Tracks in-flight item requests to prevent duplicate network calls
    private var inFlightItems: [Int: Task<TopLevelItem, Error>] = [:]

    // MARK: - Init

    public init(
        cacheConfiguration: Cache.Configuration = .default,
        retryConfiguration: RetryConfiguration = .default
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 100
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0.3 Safari/605.1.15"
        ]
        self.networkClient = URLSession(configuration: configuration)

        let noRedirectConfiguration = URLSessionConfiguration.ephemeral
        noRedirectConfiguration.httpShouldSetCookies = false
        let delegate = RedirectBlockingDelegate()
        self.networkClientWithoutRedirection = URLSession(
            configuration: noRedirectConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder

        self.cache = Cache(configuration: cacheConfiguration)
        self.retryConfiguration = retryConfiguration
    }

    // MARK: - Top Level Items

    private struct QueryResult: Decodable, Sendable { var hits: [TopLevelItem] }

    public func items(ids: [Int]) async throws -> [TopLevelItem] {
        // Check cache for existing items
        let cachedItems = await cache.items(for: ids)
        let missingIds = ids.filter { cachedItems[$0] == nil }

        var fetchedItems: [TopLevelItem] = []
        if !missingIds.isEmpty {
            // First, try the batch search endpoint (works for stories but not jobs)
            let queryResult = try await networkClient.requestWithRetry(
                QueryResult.self, from: .algolia(ids: missingIds), decoder: decoder,
                configuration: retryConfiguration)
            fetchedItems = queryResult.hits

            // Check for any IDs still missing (likely jobs, which don't have story_<id> tags)
            let fetchedIds = Set(fetchedItems.map { $0.id })
            let stillMissingIds = missingIds.filter { !fetchedIds.contains($0) }

            // Fetch missing items individually using /items/<id> endpoint
            // Chunk into batches of 20 to avoid connection pool exhaustion
            if !stillMissingIds.isEmpty {
                for chunk in stillMissingIds.chunked(into: 20) {
                    let chunkResults = await withTaskGroup(of: TopLevelItem?.self) { group in
                        for id in chunk {
                            group.addTask {
                                try? await self.item(id: id)
                            }
                        }
                        var results: [TopLevelItem] = []
                        for await item in group {
                            if let item = item {
                                results.append(item)
                            }
                        }
                        return results
                    }
                    fetchedItems.append(contentsOf: chunkResults)
                }
            }

            // Cache the fetched items
            await cache.setItems(fetchedItems)
        }

        // Combine cached and fetched items, maintaining original order
        let allItems = cachedItems.merging(
            Dictionary(uniqueKeysWithValues: fetchedItems.map { ($0.id, $0) })
        ) { _, new in new }

        return ids.compactMap { allItems[$0] }
    }

    /// Fetch a single item by ID using the /items/<id> endpoint
    /// Uses in-flight deduplication to prevent redundant network requests
    private func item(id: Int) async throws -> TopLevelItem {
        // Check for existing in-flight request to deduplicate
        if let existingTask = inFlightItems[id] {
            return try await existingTask.value
        }

        // Create new task and track it
        let task = Task {
            try await networkClient.requestWithRetry(
                TopLevelItem.self, from: .algolia(id: id), decoder: decoder,
                configuration: retryConfiguration)
        }
        inFlightItems[id] = task

        do {
            let result = try await task.value
            inFlightItems.removeValue(forKey: id)
            return result
        } catch {
            inFlightItems.removeValue(forKey: id)
            throw error
        }
    }

    /// Fetch items with pagination support
    public func items(ids: [Int], page: Int, pageSize: Int = 20) async throws -> [TopLevelItem] {
        let startIndex = page * pageSize
        let endIndex = min(startIndex + pageSize, ids.count)
        guard startIndex < ids.count else { return [] }

        let pageIds = Array(ids[startIndex..<endIndex])
        return try await items(ids: pageIds)
    }

    public func items(query: String, forceRefresh: Bool = false) async throws -> [TopLevelItem] {
        // Check cache first
        if !forceRefresh, let cachedResults = await cache.searchResults(for: query) {
            return cachedResults
        }

        let queryResult = try await networkClient.requestWithRetry(
            QueryResult.self, from: .algolia(query: query), decoder: decoder,
            configuration: retryConfiguration)

        await cache.setSearchResults(queryResult.hits, for: query)
        return queryResult.hits
    }

    public func itemIds(category: Category, forceRefresh: Bool = false) async throws -> [Int] {
        // Check cache first
        if !forceRefresh, let cachedIds = await cache.categoryIds(for: category) {
            return cachedIds
        }

        let ids = try await networkClient.requestWithRetry(
            [Int].self, from: .firebase(category: category), decoder: decoder,
            configuration: retryConfiguration)

        await cache.setCategoryIds(ids, for: category)
        return ids
    }

    // MARK: - Page

    private struct AlgoliaItem: Decodable, Sendable {
        var children: [Comment]
        var title: String
        var points: Int

        var commentCount: Int { children.reduce(0, { $0 + $1.commentCount }) }

        enum CodingKeys: CodingKey {
            case children
            case title
            case points
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            children = try container.decode([Comment].self, forKey: .children)
                .filter { !$0.isDeleted }
            title = try container.decode(String.self, forKey: .title)
            points = try container.decode(Int.self, forKey: .points)
        }
    }

    public func page(item: TopLevelItem, token: Token? = nil, forceRefresh: Bool = false) async throws -> Page {
        // Check full page cache first (only if not authenticated, as actions may change)
        if !forceRefresh && token == nil, let cachedPage = await cache.page(for: item.id) {
            return cachedPage
        }

        // Check if we have cached comments (works for both authenticated and unauthenticated)
        let cachedComments = forceRefresh ? nil : await cache.comments(for: item.id)
        let needsComments = cachedComments == nil

        // Fetch data based on what we need
        let children: [Comment]
        var updatedItem = item

        if needsComments {
            // Need to fetch both Algolia (comments) and HTML (actions) concurrently
            async let algoliaItemTask = networkClient.requestWithRetry(
                AlgoliaItem.self, from: .algolia(id: item.id), decoder: decoder,
                configuration: retryConfiguration)
            async let htmlTask = networkClient.stringWithRetry(
                from: .hn(id: item.id), token: token,
                configuration: retryConfiguration)
            let (algoliaItem, html) = try await (algoliaItemTask, htmlTask)

            let parser = try StoryParser(html: html)
            children = parser.sortedCommentTree(original: algoliaItem.children)
            let actions = parser.actions()

            // Update item metadata from Algolia response
            switch item {
            case .job(var job):
                job.title = algoliaItem.title
                updatedItem = .job(job)
            case .story(var story):
                story.title = algoliaItem.title
                story.points = algoliaItem.points
                story.commentCount = algoliaItem.commentCount
                updatedItem = .story(story)
            }

            // Cache comments separately (regardless of auth state)
            await cache.setComments(children, for: item.id)

            let page = Page(item: updatedItem, children: children, actions: actions)

            // Cache full page only if not authenticated
            if token == nil {
                await cache.setPage(page, for: item.id)
            }

            return page
        } else {
            // Have cached comments - only need to fetch HTML for actions
            children = cachedComments!

            let html = try await networkClient.stringWithRetry(
                from: .hn(id: item.id), token: token,
                configuration: retryConfiguration)
            let parser = try StoryParser(html: html)
            let actions = parser.actions()

            let page = Page(item: updatedItem, children: children, actions: actions)

            // Cache full page only if not authenticated
            if token == nil {
                await cache.setPage(page, for: item.id)
            }

            return page
        }
    }

    /// Fetches a page using only HTML parsing (no Algolia API).
    /// This is faster as it makes a single network request instead of two.
    /// Falls back to the regular page() method if HTML parsing fails.
    public func pageFromHTML(item: TopLevelItem, token: Token? = nil, forceRefresh: Bool = false) async throws -> Page {
        let overallStart = CFAbsoluteTimeGetCurrent()

        // Check full page cache first (only if not authenticated, as actions may change)
        if !forceRefresh && token == nil, let cachedPage = await cache.page(for: item.id) {
            print("⏱️ [APIClient] pageFromHTML: cache hit")
            return cachedPage
        }

        // Check if we have cached comments
        if !forceRefresh, let cachedComments = await cache.comments(for: item.id) {
            // Have cached comments - only need to fetch HTML for actions
            let html = try await networkClient.stringWithRetry(
                from: .hn(id: item.id), token: token,
                configuration: retryConfiguration)
            let parser = try StoryParser(html: html)
            let actions = parser.actions()

            let page = Page(item: item, children: cachedComments, actions: actions)

            if token == nil {
                await cache.setPage(page, for: item.id)
            }

            print("⏱️ [APIClient] pageFromHTML: comments cache hit, fetched actions only")
            return page
        }

        // Fetch HTML and parse everything from it
        let fetchStart = CFAbsoluteTimeGetCurrent()
        let html = try await networkClient.stringWithRetry(
            from: .hn(id: item.id), token: token,
            configuration: retryConfiguration)
        let fetchTime = CFAbsoluteTimeGetCurrent() - fetchStart
        print("⏱️ [APIClient] HTML fetch: \(String(format: "%.3f", fetchTime))s (\(html.count) chars)")

        let parseStart = CFAbsoluteTimeGetCurrent()
        let parser = try StoryParser(html: html)
        let parserInitTime = CFAbsoluteTimeGetCurrent() - parseStart
        print("⏱️ [APIClient] StoryParser init (SwiftSoup): \(String(format: "%.3f", parserInitTime))s")

        let commentsStart = CFAbsoluteTimeGetCurrent()
        let children = parser.commentsFromHTML()
        let commentsTime = CFAbsoluteTimeGetCurrent() - commentsStart
        print("⏱️ [APIClient] commentsFromHTML: \(String(format: "%.3f", commentsTime))s (\(children.count) top-level)")

        let actionsStart = CFAbsoluteTimeGetCurrent()
        let actions = parser.actions()
        let actionsTime = CFAbsoluteTimeGetCurrent() - actionsStart
        print("⏱️ [APIClient] actions: \(String(format: "%.3f", actionsTime))s")

        // Cache comments
        await cache.setComments(children, for: item.id)

        let page = Page(item: item, children: children, actions: actions)

        // Cache full page only if not authenticated
        if token == nil {
            await cache.setPage(page, for: item.id)
        }

        let overallTime = CFAbsoluteTimeGetCurrent() - overallStart
        print("⏱️ [APIClient] pageFromHTML total: \(String(format: "%.3f", overallTime))s")

        return page
    }

    /// Executes an action and returns an updated Page with modified actions
    @discardableResult
    public func execute(action: Action, token: Token, page: Page) async throws -> Page {
        _ = try await networkClient.request(to: Endpoint(url: action.url, token: token))

        var updatedPage = page
        if let (id, actionSet) = page.actions.first(where: { $0.value.contains(action) }) {
            var newActionSet = actionSet
            newActionSet.remove(action)
            // FIXME: This should be encapsulated properly
            switch action {
            case .upvote, .downvote:
                for existingAction in actionSet {
                    switch existingAction {
                    case .upvote, .downvote: newActionSet.remove(existingAction)
                    default: break
                    }
                }
            default: break
            }
            newActionSet.remove(action)
            for inverseAction in action.inverseSet { newActionSet.insert(inverseAction) }
            updatedPage.actions[id] = newActionSet
        }
        return updatedPage
    }

    // MARK: - Authentication

    public func login(userName: String, password: String) async throws -> Token {
        let (_, response) = try await networkClientWithoutRedirection.request(
            to: .hn(userName: userName, password: password)
        )

        let headerFields = response.allHeaderFields as! [String: String]
        let base = URL(string: "https://news.ycombinator.com/")!
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: base)

        guard let token = cookies.first(where: { $0.name == "user" }) else {
            throw APIError.loginFailed
        }
        return token
    }

    // MARK: - Commenting

    public func reply(to commentable: some Commentable, text: String, token: Token) async throws {
        try await reply(toID: commentable.id, text: text, token: token)
    }

    private func reply(toID id: Int, text: String, token: Token) async throws {
        let (data, _) = try await networkClient.request(to: .hn(replyToID: id, token: token))
        let html = String(data: data, encoding: .utf8)!
        let parser = try CommentConfirmationParser(html: html)

        guard let hmac = parser.hmac() else {
            throw APIError.unknown
        }

        _ = try await networkClient.request(
            to: .hn(replyToID: id, token: token, hmac: hmac, text: text)
        )
    }

    // MARK: - User

    public func user(username: String, forceRefresh: Bool = false) async throws -> User {
        // Check cache first
        if !forceRefresh, let cachedUser = await cache.user(for: username) {
            return cachedUser
        }

        let user = try await networkClient.requestWithRetry(
            User.self, from: .firebase(user: username), decoder: decoder,
            configuration: retryConfiguration)

        await cache.setUser(user)
        return user
    }

    /// Fetch user submissions (stories only) with optional limit
    public func userStories(for user: User, limit: Int = 10) async throws -> [TopLevelItem] {
        guard let submitted = user.submitted else { return [] }
        let ids = Array(submitted.prefix(limit))
        return try await items(ids: ids)
    }

    // MARK: - Story Actions (Lightweight)

    /// Fetches available actions for a story without loading all comments.
    /// This is a lightweight alternative to `page(item:token:)` for when you only need voting actions.
    public func storyActions(id: Int, token: Token) async throws -> Set<Action> {
        let html = try await networkClient.stringWithRetry(
            from: .hn(id: id), token: token,
            configuration: retryConfiguration)
        let parser = try StoryParser(html: html)
        let actions = parser.actions()
        return actions[id] ?? []
    }

    /// Executes an action without requiring a Page object.
    /// Returns the updated set of actions for the item after the action is executed.
    public func execute(action: Action, token: Token, forItemId id: Int) async throws -> Set<Action> {
        _ = try await networkClient.request(to: Endpoint(url: action.url, token: token))
        return action.inverseSet
    }

    // MARK: - Cache Management

    public func clearCache() async {
        await cache.clear()
    }
}
