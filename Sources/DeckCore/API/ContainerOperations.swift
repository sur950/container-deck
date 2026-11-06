import Foundation

/// The container operations that can run over the direct API or the CLI.
/// Signatures are the ones `ContainerClient` already has, so `ContainerClient`
/// (CLI) and `ContainerBackendRouter` (direct API with CLI fallback) are
/// interchangeable for these calls.
public protocol ContainerOperations: Sendable {
    // Containers
    func listContainers(all: Bool) async throws -> [ContainerSummary]
    func inspectContainer(_ id: String) async throws -> ContainerDetail
    func inspectContainers(_ ids: [String]) async throws -> [ContainerDetail]
    func startContainer(_ id: String) async throws
    func stopContainer(_ id: String) async throws
    func killContainer(_ id: String) async throws
    func restartContainer(_ id: String) async throws
    func deleteContainer(_ id: String, force: Bool) async throws
    func runContainer(_ options: RunOptions) async throws -> String
    func logs(_ id: String, options: LogOptions) -> AsyncThrowingStream<String, Error>
    func stats(_ ids: [String]) async throws -> [ContainerStats]

    // Images
    func listImages() async throws -> [ImageSummary]
    func inspectImage(_ reference: String) async throws -> ImageDetail
    func tagImage(_ source: String, as target: String) async throws
    func deleteImage(_ reference: String) async throws

    // Volumes
    func listVolumes() async throws -> [VolumeSummary]
    func listVolumeSummaries() async throws -> [VolumeSummary]
    func createVolume(name: String, size: String?, labels: [String: String]) async throws
    func deleteVolume(_ name: String) async throws

    // Networks
    func listNetworks() async throws -> [NetworkSummary]
    func listNetworkSummaries() async throws -> [NetworkSummary]
    func createNetwork(name: String, subnet: String?, internal isInternal: Bool) async throws
    func createNetwork(name: String, subnet: String?, subnetV6: String?, internal isInternal: Bool, labels: [String: String]) async throws
    func deleteNetwork(_ name: String) async throws

    // System
    func diskUsage() async throws -> DiskUsage
}

/// The CLI client already has every method (same names, same defaults).
extension ContainerClient: ContainerOperations {}
