import LocalAuthentication

/// Thin wrapper over LocalAuthentication for the app's Face ID / Touch ID lock.
enum BiometricAuth {
    enum Kind {
        case faceID, touchID, none
        var label: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .none: return "biometrics"
            }
        }
    }

    /// What this device supports and has enrolled right now.
    static func kind() -> Kind {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch ctx.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    /// Prompt for Face ID / Touch ID, with an automatic device-passcode
    /// fallback so a failed or un-enrolled scan can still unlock. Returns true
    /// only on a successful local authentication.
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"
        var error: NSError?
        // deviceOwnerAuthentication = biometrics first, passcode as fallback.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
