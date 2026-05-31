//
//  APIClient.swift
//  Lume
//
//  Base protocol for all API clients
//

import Foundation

// MARK: - APIClient Protocol

/// Base protocol for all API client implementations
protocol APIClient {
    associatedtype Configuration

    var configuration: Configuration { get }
    var session: URLSession { get }
}

// MARK: - Default Implementations

extension APIClient {
    /// Performs a network request and decodes the response
    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let request = try endpoint.asURLRequest()

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw NetworkError.authenticationFailed
            }
            throw NetworkError.serverError(httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decodingError(error)
        }
    }

    /// Performs a network request with automatic retry logic
    func requestWithRetry<T: Decodable>(
        _ endpoint: Endpoint,
        maxRetries: Int = 3,
        backoff: RetryBackoff = .exponential
    ) async throws -> T {
        var attempt = 0
        var lastError: Error?

        while attempt < maxRetries {
            do {
                return try await request(endpoint)
            } catch let error as NetworkError {
                lastError = error

                guard error.isRetriable else {
                    throw error
                }

                attempt += 1
                if attempt < maxRetries {
                    let delay = backoff.delay(for: attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                throw error
            }
        }

        throw lastError ?? NetworkError.unknown
    }
}

// MARK: - Endpoint Protocol

/// Represents an API endpoint
protocol Endpoint {
    var baseURL: URL { get }
    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String]? { get }
    var queryItems: [URLQueryItem]? { get }
    var body: Data? { get }
    var timeout: TimeInterval { get }

    func asURLRequest() throws -> URLRequest
}

extension Endpoint {
    func asURLRequest() throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)

        if !path.isEmpty {
            if components?.path.hasSuffix("/") == false, !path.hasPrefix("/") {
                components?.path.append("/")
            }
            components?.path.append(path)
        }

        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = timeout

        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = body

        return request
    }
}

// MARK: - HTTP Method

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

// MARK: - Network Error

enum NetworkError: LocalizedError {
    case invalidURL
    case noConnection
    case timeout
    case invalidResponse
    case authenticationFailed
    case rateLimited(retryAfter: TimeInterval)
    case serverError(Int)
    case decodingError(Error)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The URL is invalid"
        case .noConnection:
            "No internet connection"
        case .timeout:
            "The request timed out"
        case .invalidResponse:
            "Invalid response from server"
        case .authenticationFailed:
            "Authentication failed. Please check your credentials."
        case let .rateLimited(retryAfter):
            "Too many requests. Please try again in \(Int(retryAfter)) seconds."
        case let .serverError(code):
            "Server error (code: \(code))"
        case let .decodingError(error):
            "Failed to decode response: \(error.localizedDescription)"
        case .unknown:
            "An unknown error occurred"
        }
    }

    var isRetriable: Bool {
        switch self {
        case .noConnection, .timeout:
            true
        case let .serverError(code):
            // Retry on 5xx server errors
            code >= 500
        case .rateLimited:
            true
        default:
            false
        }
    }
}

// MARK: - Retry Strategy

enum RetryBackoff {
    case linear
    case exponential

    func delay(for attempt: Int) -> TimeInterval {
        switch self {
        case .linear:
            TimeInterval(attempt)
        case .exponential:
            pow(2.0, Double(attempt))
        }
    }
}
