import Foundation

/// Configuration for retry behavior
public struct RetryConfiguration: Sendable {
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public let retryableErrors: Set<URLError.Code>

    public init(
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 0.5,
        retryableErrors: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet]
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.retryableErrors = retryableErrors
    }

    public static let `default` = RetryConfiguration()
}

protocol NetworkClient: Sendable {
    func request(to endpoint: Endpoint) async throws -> (Data, HTTPURLResponse)
    func request<T>(_ type: T.Type, from url: URL, decoder: JSONDecoder) async throws -> T
    where T: Decodable
    func string(from url: URL, token: Token?) async throws -> String
}

// MARK: - Retry Support

extension NetworkClient {
    func requestWithRetry<T>(
        _ type: T.Type,
        from url: URL,
        decoder: JSONDecoder,
        configuration: RetryConfiguration = .default
    ) async throws -> T where T: Decodable {
        var lastError: Error?

        for attempt in 0..<configuration.maxRetries {
            do {
                return try await request(type, from: url, decoder: decoder)
            } catch {
                lastError = error

                guard attempt < configuration.maxRetries - 1 else { break }

                // Only retry on specific network errors
                if let urlError = error as? URLError,
                   configuration.retryableErrors.contains(urlError.code) {
                    let delay = configuration.baseDelay * pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    throw error  // Non-retryable error, fail immediately
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    func requestWithRetry(
        to endpoint: Endpoint,
        configuration: RetryConfiguration = .default
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?

        for attempt in 0..<configuration.maxRetries {
            do {
                return try await request(to: endpoint)
            } catch {
                lastError = error

                guard attempt < configuration.maxRetries - 1 else { break }

                if let urlError = error as? URLError,
                   configuration.retryableErrors.contains(urlError.code) {
                    let delay = configuration.baseDelay * pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    throw error
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    func stringWithRetry(
        from url: URL,
        token: Token?,
        configuration: RetryConfiguration = .default
    ) async throws -> String {
        var lastError: Error?

        for attempt in 0..<configuration.maxRetries {
            do {
                return try await string(from: url, token: token)
            } catch {
                lastError = error

                guard attempt < configuration.maxRetries - 1 else { break }

                if let urlError = error as? URLError,
                   configuration.retryableErrors.contains(urlError.code) {
                    let delay = configuration.baseDelay * pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    throw error
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }
}

extension URLSession: NetworkClient {
    public enum HTTPError: Error, LocalizedError, Sendable {
        case transportError(Error)
        case serverSideError(statusCode: Int)
        case clientSideError(reason: String)

        public var errorDescription: String? {
            switch self {
            case .transportError(let error):
                let error = error as NSError
                return error.localizedDescription
            case .serverSideError(let statusCode): return "Server returned \(statusCode)."
            case .clientSideError(let reason): return reason
            }
        }
    }

    func request(to endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: endpoint)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.clientSideError(reason: "Invalid response type")
        }
        if httpResponse.statusCode >= 400 && httpResponse.statusCode < 500 {
            throw HTTPError.serverSideError(statusCode: httpResponse.statusCode)
        }
        return (data, httpResponse)
    }

    func request<T>(_ type: T.Type, from url: URL, decoder: JSONDecoder) async throws -> T
    where T: Decodable {
        let (data, response) = try await data(from: url)
        if let response = response as? HTTPURLResponse, response.statusCode >= 400 {
            throw HTTPError.serverSideError(statusCode: response.statusCode)
        }
        let model = try decoder.decode(type, from: data)
        return model
    }

    func string(from url: URL, token: Token?) async throws -> String {
        var request = URLRequest(url: url)
        if let token = token { request.add(token) }
        let (data, response) = try await data(for: request)
        if let response = response as? HTTPURLResponse, response.statusCode >= 400 {
            throw HTTPError.serverSideError(statusCode: response.statusCode)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw HTTPError.clientSideError(reason: "Could not decode response as UTF-8.")
        }

        return string
    }
}
