import Foundation

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
            if !stillMissingIds.isEmpty {
                let individualItems = await withTaskGroup(of: TopLevelItem?.self) { group in
                    for id in stillMissingIds {
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
                fetchedItems.append(contentsOf: individualItems)
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
    private func item(id: Int) async throws -> TopLevelItem {
        return try await networkClient.requestWithRetry(
            TopLevelItem.self, from: .algolia(id: id), decoder: decoder,
            configuration: retryConfiguration)
    }

    /// Fetch items with pagination support
    public func items(ids: [Int], page: Int, pageSize: Int = 20) async throws -> [TopLevelItem] {
        let startIndex = page * pageSize
        let endIndex = min(startIndex + pageSize, ids.count)
        guard startIndex < ids.count else { return [] }

        let pageIds = Array(ids[startIndex..<endIndex])
        return try await items(ids: pageIds)
    }

    public func items(query: String) async throws -> [TopLevelItem] {
        let queryResult = try await networkClient.requestWithRetry(
            QueryResult.self, from: .algolia(query: query), decoder: decoder,
            configuration: retryConfiguration)
        return queryResult.hits
    }

    public func itemIds(category: Category) async throws -> [Int] {
        return try await networkClient.requestWithRetry(
            [Int].self, from: .firebase(category: category), decoder: decoder,
            configuration: retryConfiguration)
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
        // Check cache first (only if not authenticated, as actions may change)
        if !forceRefresh && token == nil, let cachedPage = await cache.page(for: item.id) {
            return cachedPage
        }

        let algoliaItem = try await networkClient.requestWithRetry(
            AlgoliaItem.self, from: .algolia(id: item.id), decoder: decoder,
            configuration: retryConfiguration)
        let html = try await networkClient.stringWithRetry(
            from: .hn(id: item.id), token: token,
            configuration: retryConfiguration)
        let parser = try StoryParser(html: html)
        let children = parser.sortedCommentTree(original: algoliaItem.children)
        let actions = parser.actions()

        var updatedItem = item
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

        let page = Page(item: updatedItem, children: children, actions: actions)

        // Cache the page (only if not authenticated)
        if token == nil {
            await cache.setPage(page, for: item.id)
        }

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

    // MARK: - Cache Management

    public func clearCache() async {
        await cache.clear()
    }
}
