import Foundation

public enum DeckError: LocalizedError, Equatable {
    case launchFailed(String, String)
    case commandFailed(String)
    case notInstalled
    case noInstallerFound
    case signatureInvalid(String)
    case network(String)
    case notImplemented(String)
    case parse(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let reason):
            return "Could not start \(path). \(reason)"
        case .commandFailed(let message):
            return message
        case .notInstalled:
            return "Apple's container tool is not installed."
        case .noInstallerFound:
            return "No installer package was found in the latest release of apple/container."
        case .signatureInvalid(let details):
            return "The installer package is not signed by Apple, so it was not installed. \(details)"
        case .network(let message):
            return "Network problem: \(message)"
        case .notImplemented(let what):
            return "\(what) is not built yet."
        case .parse(let what):
            return "Could not read the output of \(what)."
        }
    }
}

public extension CommandResult {
    /// Throws when the command did not succeed.
    @discardableResult
    func orThrow() throws -> CommandResult {
        guard succeeded else { throw DeckError.commandFailed(failureMessage) }
        return self
    }
}
