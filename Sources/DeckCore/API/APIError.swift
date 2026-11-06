import Foundation

/// Errors from the direct API. The router decides from the kind whether to
/// retry a call through the CLI, report the service as stopped, or show it.
public enum APIError: Error, Equatable, LocalizedError {
    /// `Connection invalid`: the service is not registered (daemon not started).
    case serviceUnavailable(route: String)
    /// `Connection interrupted`: unknown route on this daemon, or the daemon died mid call.
    case interrupted(route: String)
    case timeout(route: String, seconds: Double)
    /// The service answered with an error (`{"code", "message"}`).
    case server(code: String, message: String)
    /// A reply we could not read (missing key, unexpected JSON).
    case malformedReply(String)
    /// We could not build the request.
    case malformedRequest(String)
    /// Something only the CLI handles or explains well (an unknown image name,
    /// a missing mount source). Not a failure of the API.
    case needsCLI(String)

    public var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "The container services are not running."
        case .interrupted(let route):
            return "The container services stopped answering (\(route))."
        case .timeout(let route, let seconds):
            return "The container services did not answer in \(Int(seconds.rounded())) seconds (\(route))."
        case .server(_, let message):
            return message.isEmpty ? "The container services reported an error." : message
        case .malformedReply(let what):
            return "Could not read the reply from the container services (\(what))."
        case .malformedRequest(let what):
            return "Could not build the request for the container services (\(what))."
        case .needsCLI(let why):
            return why
        }
    }

    /// The daemon rejected the request itself because it could not read it.
    /// Means our encoding does not match this daemon, so the CLI should handle it.
    public var isRequestRejected: Bool {
        guard case .server(let code, let message) = self else { return false }
        let text = message.lowercased()
        let decodeWords = ["decod", "keynotfound", "typemismatch", "datacorrupted", "valuenotfound", "the data couldn"]
        if decodeWords.contains(where: text.contains) { return true }
        // An empty required key reads as "... cannot be empty" or "missing ...".
        return code == "invalidArgument" && (text.hasPrefix("missing ") || text.hasPrefix("empty "))
    }

    /// Problems with the API path itself. Safe to retry a read through the CLI.
    public var isTransportFailure: Bool {
        switch self {
        case .interrupted, .timeout, .malformedReply, .malformedRequest: return true
        case .server: return isRequestRejected
        case .serviceUnavailable, .needsCLI: return false
        }
    }

    /// Failures after which a change can be retried through the CLI.
    /// An unknown route answers `interrupted` at once, so that counts. A daemon
    /// crash in the middle of a change also reads `interrupted`, and the changes we
    /// send (start, stop, kill, delete, create and delete of volumes and networks)
    /// are safe to repeat or fail cleanly. A timeout is not one: the change may
    /// still be running.
    public var requestNotApplied: Bool {
        switch self {
        case .malformedRequest, .interrupted: return true
        case .server: return isRequestRejected
        default: return false
        }
    }
}
