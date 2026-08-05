import Foundation

/// The one place the app talks to the dispatch service.
///
/// Authenticated with the customer's own Supabase access token, never a shared
/// secret. An IPA is a zip file: anything in Info.plist or the binary belongs
/// to whoever downloads the app, and a dispatch key in there would let a
/// stranger book couriers and move money on any order.
///
/// The server re-checks ownership on every call, so this token grants exactly
/// what the customer already has — their own orders.
struct DispatchAPI {
    let baseURL: String
    let accessToken: String

    init(accessToken: String) {
        baseURL = Bundle.main.infoDictionary?["DISPATCH_URL"] as? String ?? ""
        self.accessToken = accessToken
    }

    var isConfigured: Bool { !baseURL.isEmpty && !accessToken.isEmpty }

    struct Failure: LocalizedError {
        let message: String
        /// The server's own name for this refusal, when it has one. Some of
        /// them need different handling rather than different words: a charge
        /// with no courier behind it is not something to retry, and the retry
        /// advice the app gives by default sends that customer at a route that
        /// will refuse them.
        var code: String? = nil
        var errorDescription: String? { message }
    }

    @discardableResult
    func post<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await send(path, body: Data("{}".utf8), as: type)
    }

    /// POST with a body.
    ///
    /// Dates go out as ISO-8601 because that is what the service reads them
    /// back as; the default encoding is a bare number of seconds since 2001,
    /// which arrives as a nonsense timestamp rather than as an error.
    @discardableResult
    func post<T: Decodable>(_ path: String, body: some Encodable, as type: T.Type) async throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try await send(path, body: try encoder.encode(body), as: type)
    }

    private func send<T: Decodable>(_ path: String, body: Data, as type: T.Type) async throws -> T {
        guard isConfigured, let url = URL(string: baseURL + path) else {
            throw Failure(message: "The app is not configured to reach Crease.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status >= 400 {
            // Surface the server's reason. A carrier refusing to cancel after
            // pickup is a real answer the customer needs to read, not a
            // generic failure to retry against.
            let failure = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw Failure(
                message: failure?.readable ?? "That didn't work (\(status)).",
                code: failure?.code
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // A proxy error page decodes as nothing and surfaces as "the data
            // couldn't be read", which tells the customer nothing and sent me
            // looking in the app rather than at the gateway. Say what arrived.
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw Failure(message: "Unexpected response from Crease (\(status)). \(body)")
        }
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let errors: [String]?
        let code: String?
        var readable: String? { error ?? errors?.joined(separator: "\n") }
    }

    struct Ack: Decodable {
        let ok: Bool?
        /// Set when the couriers were stopped but the money did not come back
        /// automatically. The customer needs to hear that, not a clean
        /// "cancelled" that implies they have been refunded.
        let refundPending: Bool?
        let message: String?
    }
}
