import Foundation
import XPC

// Small XPC client for Apple's container services. No dependencies.
// A message is an XPC dictionary: the route name under `APIKey.route` plus
// string, bool, number and data (JSON) values. Replies use the same keys.
// Values are copied into Swift types right away, so nothing XPC leaves this file.

// MARK: - Values

/// One value in a request or reply.
public enum XPCValue: Sendable {
    case string(String)
    case data(Data)
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    /// Nanoseconds since 1970, as XPC stores dates.
    case date(Int64)
    case fileDescriptor(OwnedFileDescriptor)
    case fileDescriptors([OwnedFileDescriptor])
    /// A type we do not read (dictionaries, endpoints). Only the type name is kept.
    case other(String)
}

/// A file descriptor we own. Closed when the last reference goes away.
public final class OwnedFileDescriptor: @unchecked Sendable {
    public let rawValue: Int32
    private let lock = NSLock()
    private var isClosed = false

    public init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit { close() }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(rawValue)
    }

}

/// A message to send: route plus values.
public struct XPCRequest: Sendable {
    public var route: String
    public var values: [String: XPCValue] = [:]

    public init(route: String) {
        self.route = route
    }

    public mutating func set(_ key: String, _ value: String) { values[key] = .string(value) }
    public mutating func set(_ key: String, _ value: Bool) { values[key] = .bool(value) }
    public mutating func set(_ key: String, _ value: Int64) { values[key] = .int64(value) }
    public mutating func set(_ key: String, _ value: UInt64) { values[key] = .uint64(value) }
    public mutating func set(_ key: String, data: Data) { values[key] = .data(data) }

    /// JSON with Apple's default `JSONEncoder` settings (dates as seconds since 2001).
    public mutating func set<T: Encodable>(_ key: String, json value: T) throws {
        do {
            values[key] = .data(try JSONEncoder().encode(value))
        } catch {
            throw APIError.malformedRequest("\(route) \(key)")
        }
    }

    public func string(_ key: String) -> String? {
        if case .string(let value)? = values[key] { return value }
        return nil
    }

    public func data(_ key: String) -> Data? {
        if case .data(let value)? = values[key] { return value }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let value)? = values[key] { return value }
        return nil
    }
}

/// A reply from a service.
public struct XPCReply: Sendable {
    public var values: [String: XPCValue]

    public init(_ values: [String: XPCValue] = [:]) {
        self.values = values
    }

    public func string(_ key: String) -> String? {
        if case .string(let value)? = values[key] { return value }
        return nil
    }

    public func data(_ key: String) -> Data? {
        if case .data(let value)? = values[key] { return value }
        return nil
    }

    public func bool(_ key: String) -> Bool {
        if case .bool(let value)? = values[key] { return value }
        return false
    }

    /// Numbers read like `xpc_dictionary_get_uint64`: missing or other types give 0.
    public func uint64(_ key: String) -> UInt64 {
        switch values[key] {
        case .uint64(let value)?: return value
        case .int64(let value)?: return value >= 0 ? UInt64(value) : 0
        default: return 0
        }
    }

    public func int64(_ key: String) -> Int64 {
        switch values[key] {
        case .int64(let value)?: return value
        case .uint64(let value)?: return value <= UInt64(Int64.max) ? Int64(value) : Int64.max
        default: return 0
        }
    }

    public func fileDescriptors(_ key: String) -> [OwnedFileDescriptor]? {
        switch values[key] {
        case .fileDescriptors(let list)?: return list
        case .fileDescriptor(let one)?: return [one]
        default: return nil
        }
    }

    /// The error Apple's services put under `APIKey.error`: JSON `{"code", "message"}`.
    public func serverError() -> APIError? {
        guard let data = data(APIKey.error) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformedReply("error payload")
        }
        let code = object["code"] as? String ?? "unknown"
        let message = object["message"] as? String ?? ""
        return .server(code: code, message: message)
    }
}

// MARK: - Transport

/// Sends one message and calls back once with the reply. `XPCConnection` talks
/// to the real service. Tests use a fake.
public protocol XPCTransport: Sendable {
    var serviceName: String { get }
    func send(_ request: XPCRequest, completion: @escaping @Sendable (Result<XPCReply, APIError>) -> Void)
}

extension XPCTransport {
    /// Sends and waits for the reply. Fails with `.timeout` after `timeout`, with
    /// `CancellationError` when the task is cancelled, and with `.server` when the
    /// service answered with an error. A late reply after a timeout is dropped.
    public func call(_ request: XPCRequest, timeout: Duration = APITimeouts.standard) async throws -> XPCReply {
        try Task.checkCancellation()
        let gate = ReplyGate<XPCReply>()
        let route = request.route
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<XPCReply, Error>) in
                gate.install(continuation)
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                    gate.finish(.failure(APIError.timeout(route: route, seconds: seconds)))
                }
                send(request) { result in
                    switch result {
                    case .success(let reply):
                        if let error = reply.serverError() {
                            gate.finish(.failure(error))
                        } else {
                            gate.finish(.success(reply))
                        }
                    case .failure(let error):
                        gate.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}

/// Resumes a continuation exactly once, whichever of reply, timeout or cancel comes first.
final class ReplyGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var isDone = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early {
            isDone = true
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !isDone else { lock.unlock(); return }
        guard let continuation else {
            if early == nil { early = result }
            lock.unlock()
            return
        }
        isDone = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

// MARK: - Real connection

/// One long lived connection to a mach service. Replies arrive on a serial queue.
/// When the service goes away (`Connection invalid`) the connection is dropped and
/// the next send opens a new one, so a restarted daemon is picked up.
public final class XPCConnection: XPCTransport, @unchecked Sendable {
    public let serviceName: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connection: xpc_connection_t?

    public init(serviceName: String) {
        self.serviceName = serviceName
        self.queue = DispatchQueue(label: "\(AppConfig.bundleID).xpc.\(serviceName)")
    }

    deinit {
        if let connection { xpc_connection_cancel(connection) }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: XPCConnection] = [:]

    /// The shared connection for a service, so the whole app uses one per service.
    public static func shared(_ serviceName: String) -> XPCConnection {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[serviceName] { return existing }
        let created = XPCConnection(serviceName: serviceName)
        registry[serviceName] = created
        return created
    }

    /// Drops the connection. The next send connects again.
    public func reset() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        if let old { xpc_connection_cancel(old) }
    }

    private func currentConnection() -> xpc_connection_t {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let created = xpc_connection_create_mach_service(serviceName, queue, 0)
        xpc_connection_set_event_handler(created) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            if xpc_equal(event, XPC_ERROR_CONNECTION_INVALID) {
                self?.dropIfCurrent(created)
            }
        }
        xpc_connection_activate(created)
        connection = created
        return created
    }

    private func dropIfCurrent(_ candidate: xpc_connection_t) {
        lock.lock()
        let matches = connection.map { $0 === candidate } ?? false
        if matches { connection = nil }
        lock.unlock()
        if matches { xpc_connection_cancel(candidate) }
    }

    public func send(_ request: XPCRequest, completion: @escaping @Sendable (Result<XPCReply, APIError>) -> Void) {
        let connection = currentConnection()
        let message = Self.makeMessage(request)
        let route = request.route
        xpc_connection_send_message_with_reply(connection, message, queue) { [weak self] reply in
            if xpc_get_type(reply) == XPC_TYPE_DICTIONARY {
                completion(.success(XPCReply(Self.readDictionary(reply))))
                return
            }
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                if xpc_equal(reply, XPC_ERROR_CONNECTION_INVALID) {
                    self?.dropIfCurrent(connection)
                    completion(.failure(.serviceUnavailable(route: route)))
                } else if xpc_equal(reply, XPC_ERROR_CONNECTION_INTERRUPTED) {
                    completion(.failure(.interrupted(route: route)))
                } else {
                    let text = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) } ?? "XPC error"
                    completion(.failure(.malformedReply("\(route): \(text)")))
                }
                return
            }
            completion(.failure(.malformedReply("\(route): unexpected reply type")))
        }
    }

    // MARK: Encoding

    static func makeMessage(_ request: XPCRequest) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, APIKey.route, request.route)
        for (key, value) in request.values {
            switch value {
            case .string(let text):
                xpc_dictionary_set_string(message, key, text)
            case .data(let data):
                // Like Apple's client, empty data leaves the key out.
                data.withUnsafeBytes { buffer in
                    if let base = buffer.baseAddress {
                        xpc_dictionary_set_data(message, key, base, data.count)
                    }
                }
            case .bool(let flag):
                xpc_dictionary_set_bool(message, key, flag)
            case .int64(let number):
                xpc_dictionary_set_int64(message, key, number)
            case .uint64(let number):
                xpc_dictionary_set_uint64(message, key, number)
            case .double(let number):
                xpc_dictionary_set_double(message, key, number)
            case .date(let nanoseconds):
                xpc_dictionary_set_date(message, key, nanoseconds)
            case .fileDescriptor, .fileDescriptors, .other:
                // We never send descriptors (no attached stdio).
                continue
            }
        }
        return message
    }

    // MARK: Decoding

    static func readDictionary(_ dictionary: xpc_object_t) -> [String: XPCValue] {
        var values: [String: XPCValue] = [:]
        xpc_dictionary_apply(dictionary) { key, value in
            values[String(cString: key)] = readValue(value)
            return true
        }
        return values
    }

    static func readValue(_ value: xpc_object_t) -> XPCValue {
        let type = xpc_get_type(value)
        if type == XPC_TYPE_STRING {
            return .string(xpc_string_get_string_ptr(value).map { String(cString: $0) } ?? "")
        }
        if type == XPC_TYPE_DATA {
            let length = xpc_data_get_length(value)
            guard length > 0, let bytes = xpc_data_get_bytes_ptr(value) else { return .data(Data()) }
            return .data(Data(bytes: bytes, count: length))
        }
        if type == XPC_TYPE_BOOL { return .bool(xpc_bool_get_value(value)) }
        if type == XPC_TYPE_INT64 { return .int64(xpc_int64_get_value(value)) }
        if type == XPC_TYPE_UINT64 { return .uint64(xpc_uint64_get_value(value)) }
        if type == XPC_TYPE_DOUBLE { return .double(xpc_double_get_value(value)) }
        if type == XPC_TYPE_DATE { return .date(xpc_date_get_value(value)) }
        if type == XPC_TYPE_FD {
            let fd = xpc_fd_dup(value)
            return fd >= 0 ? .fileDescriptor(OwnedFileDescriptor(fd)) : .other("fd")
        }
        if type == XPC_TYPE_ARRAY {
            var descriptors: [OwnedFileDescriptor] = []
            let count = xpc_array_get_count(value)
            for index in 0..<count {
                let fd = xpc_array_dup_fd(value, index)
                if fd >= 0 { descriptors.append(OwnedFileDescriptor(fd)) }
            }
            return descriptors.count == count && count > 0 ? .fileDescriptors(descriptors) : .other("array")
        }
        if type == XPC_TYPE_DICTIONARY { return .other("dictionary") }
        return .other("unknown")
    }
}
