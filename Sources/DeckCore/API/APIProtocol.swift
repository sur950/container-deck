//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//
//
// Adapted for Container Deck from apple/container 1.6.1:
// Sources/ContainerXPC/XPCMessage.swift, Sources/Services/ContainerAPIService/Client/XPC+.swift,
// Sources/Services/ContainerImagesService/Client/ImageServiceXPC{Routes,Keys}.swift.
// Only the wire names (service names, route names, message keys) are kept.
// The wire format is the same from 1.4.0 through 1.6.1 for every route used here.

import Foundation

/// Mach service names of Apple's container daemons.
public enum APIService {
    /// `container-apiserver`: containers, networks, volumes, disk usage, health.
    public static let apiServer = "com.apple.container.apiserver"
    /// `container-core-images`: image store and content store.
    public static let images = "com.apple.container.core.container-core-images"
}

/// Message keys. Values are strings, bools, numbers or JSON data.
public enum APIKey {
    public static let route = "com.apple.container.xpc.route"
    public static let error = "com.apple.container.xpc.error"

    // Containers (apiserver)
    public static let id = "id"
    public static let processIdentifier = "processIdentifier"
    public static let containers = "containers"
    public static let listFilters = "listFilters"
    public static let stopOptions = "stopOptions"
    public static let forceDelete = "forceDelete"
    public static let signal = "signal"
    public static let logs = "logs"
    public static let statistics = "statistics"
    public static let dynamicEnv = "dynamicEnv"

    // Health
    public static let appRoot = "appRoot"
    public static let installRoot = "installRoot"
    public static let logRoot = "logRoot"
    public static let apiServerVersion = "apiServerVersion"
    public static let apiServerCommit = "apiServerCommit"
    public static let apiServerBuild = "apiServerBuild"
    public static let apiServerAppName = "apiServerAppName"

    // Networks
    public static let networkId = "networkId"
    public static let networkConfig = "networkConfig"
    public static let networkResource = "networkResource"
    public static let networkResources = "networkResources"

    // Volumes
    public static let volume = "volume"
    public static let volumes = "volumes"
    public static let volumeName = "volumeName"
    public static let volumeDriver = "volumeDriver"
    public static let volumeDriverOpts = "volumeDriverOpts"
    public static let volumeLabels = "volumeLabels"

    // Disk usage
    public static let diskUsageStats = "diskUsageStats"

    // Images (images service)
    public static let imageReference = "imageReference"
    public static let imageNewReference = "imageNewReference"
    public static let imageDescription = "imageDescription"
    public static let imageDescriptions = "imageDescriptions"
    public static let garbageCollect = "garbageCollect"
    public static let digest = "digest"
    public static let digests = "digests"
    public static let contentPath = "contentPath"
    public static let imageSize = "imageSize"
}

/// Route names.
public enum APIRoute {
    // apiserver
    public static let ping = "ping"
    public static let containerList = "containerList"
    public static let containerBootstrap = "containerBootstrap"
    public static let containerStartProcess = "containerStartProcess"
    public static let containerStop = "containerStop"
    public static let containerKill = "containerKill"
    public static let containerDelete = "containerDelete"
    public static let containerLogs = "containerLogs"
    public static let containerStats = "containerStats"
    public static let networkCreate = "networkCreate"
    public static let networkDelete = "networkDelete"
    public static let networkList = "networkList"
    public static let volumeCreate = "volumeCreate"
    public static let volumeDelete = "volumeDelete"
    public static let volumeList = "volumeList"
    public static let systemDiskUsage = "systemDiskUsage"

    // images service
    public static let imageList = "imageList"
    public static let imageTag = "imageTag"
    public static let imageDelete = "imageDelete"
    public static let imageCleanupOrphanedBlobs = "imageCleanupOrphanedBlobs"
    public static let contentGet = "contentGet"
}

/// Label keys and values the daemon uses.
public enum APILabel {
    /// `ResourceLabelKeys.plugin`. Machines carry "machine".
    public static let plugin = "com.apple.container.plugin"
    /// `ContainerListFilters.exclude("machine")`: a regex the daemon matches against the label.
    public static let excludeMachines = "^(?!machine$)"
    /// Network plugin `container network create` uses by default.
    public static let defaultNetworkPlugin = "container-network-vmnet"
    /// OCI annotation with the name of a locally built image.
    public static let imageName = "com.apple.containerization.image.name"
}

/// Per call time limits. Reads are quick, so 5 s means something is wrong.
/// Changes wait for the daemon (a stop waits for the process to exit).
public enum APITimeouts {
    public static let standard: Duration = .seconds(5)
    public static let ping: Duration = .seconds(2)
    /// Booting the VM and starting the init process.
    public static let start: Duration = .seconds(120)
    /// Added to the stop grace period.
    public static let stopMargin: Duration = .seconds(30)
    public static let delete: Duration = .seconds(60)
    public static let create: Duration = .seconds(60)
}
