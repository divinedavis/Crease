import Foundation

/// The one place the app talks to the dispatch service.
///
/// Everything that moves money or a courier lives behind this: the client can
/// read its own orders through Supabase under RLS, but it can never dispatch,
/// charge or refund directly. Centralised so the shared secret has exactly one
/// home rather than being pasted into each caller.
struct DispatchAPI {
    let baseURL: String
    let key: String

    init() {
        let info = Bundle.main.infoDictionary
        baseURL = info?["DISPATCH_URL"] as? String ?? ""
        key = info?["DISPATCH_KEY"] as? String ?? ""
    }

    var isConfigured: Bool { !baseURL.isEmpty && !key.isEmpty }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    func post<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard isConfigured, let url = URL(string: baseURL + path) else {
            throw Failure(message: "The app is not configured to reach Crease.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-crease-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status >= 400 {
            // Surface the server's reason. A carrier refusing to cancel after
            // pickup is a real answer the customer needs to read, not a
            // generic failure to retry against.
            let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.readable
            throw Failure(message: reason ?? "That didn't work (\(status)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let errors: [String]?
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
