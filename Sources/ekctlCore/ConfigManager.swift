import Darwin
import Foundation

// Darwin also imports the POSIX `struct flock`; binding the function once
// avoids that name collision when calls are module-qualified in Swift.
private let systemFlock: (Int32, Int32) -> Int32 = flock

/// Errors produced while validating or persisting ekctl's configuration.
public enum ConfigStoreError: Error, LocalizedError {
    case invalidRoot(String)
    case unsafeEntry(path: String, reason: String)
    case invalidOwner(path: String)
    case invalidPermissions(path: String, expected: String)
    case configTooLarge(actual: Int64, maximum: Int)
    case corrupted(String)
    case unsupportedVersion(Int)
    case invalidAliasName(String)
    case invalidAliasID(String)
    case tooManyAliases(maximum: Int)
    case invalidCalendarList(String)
    case lockTimedOut(path: String, seconds: Int)
    case io(operation: String, path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let path):
            return "Config directory must be a narrowly scoped absolute file-system path: \(path)"
        case .unsafeEntry(let path, let reason):
            return "Unsafe config entry at \(path): \(reason)"
        case .invalidOwner(let path):
            return "Config entry is not owned by the current user: \(path)"
        case .invalidPermissions(let path, let expected):
            return "Could not secure config entry \(path) with permissions \(expected)"
        case .configTooLarge(let actual, let maximum):
            return "Config file is too large (\(actual) bytes; maximum \(maximum) bytes)"
        case .corrupted(let reason):
            return "Config file is invalid: \(reason)"
        case .unsupportedVersion(let version):
            return "Unsupported config version: \(version)"
        case .invalidAliasName(let reason):
            return "Invalid alias name: \(reason)"
        case .invalidAliasID(let reason):
            return "Invalid alias ID: \(reason)"
        case .tooManyAliases(let maximum):
            return "Config contains more than \(maximum) aliases"
        case .invalidCalendarList(let reason):
            return "Invalid calendar list: \(reason)"
        case .lockTimedOut(let path, let seconds):
            return "Timed out after \(seconds) seconds waiting for config lock: \(path)"
        case .io(let operation, let path, let code):
            let message = String(cString: strerror(code))
            return "Config \(operation) failed for \(path): \(message)"
        }
    }
}

/// Secure, injectable persistence for calendar and reminder-list aliases.
///
/// Reads are side-effect-free and use atomic replacement for coherent snapshots.
/// Mutations hold an in-process lock and an advisory file lock across the complete
/// read-modify-write sequence so concurrent processes cannot lose alias updates.
public struct ConfigStore {
    public static let maximumConfigSize = 1_048_576
    public static let maximumAliasCount = 10_000
    public static let lockTimeoutSeconds = 5

    private static let supportedVersion = 1
    private static let processLock = NSLock()

    public let directoryURL: URL
    public let configFileURL: URL

    private let lockFileName = "config.lock"
    private let configFileName = "config.json"
    private let repairExistingPermissions: Bool

    private struct Config: Codable {
        var aliases: [String: String]
        var version: Int

        init(aliases: [String: String] = [:], version: Int = supportedVersion) {
            self.aliases = aliases
            self.version = version
        }
    }

    /// Creates a store rooted at `rootURL`. The directory is created lazily.
    public init(rootURL: URL) throws {
        try self.init(rootURL: rootURL, repairExistingPermissions: false)
    }

    private init(rootURL: URL, repairExistingPermissions: Bool) throws {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
            throw ConfigStoreError.invalidRoot(rootURL.path)
        }

        let standardized = rootURL.standardizedFileURL
        // This directory is permission-repaired during mutations. Never allow
        // the filesystem root to become that repair target, including through
        // paths such as `/tmp/..` that standardize to `/`.
        guard standardized.path != "/" else {
            throw ConfigStoreError.invalidRoot(standardized.path)
        }
        self.directoryURL = standardized
        self.configFileURL = standardized.appendingPathComponent(configFileName, isDirectory: false)
        self.repairExistingPermissions = repairExistingPermissions
    }

    /// The production location. `EKCTL_CONFIG_DIR` is an optional absolute-path
    /// override intended for isolated integrations and end-to-end tests.
    public static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ConfigStore {
        if let override = environment["EKCTL_CONFIG_DIR"] {
            guard !override.isEmpty, override.hasPrefix("/") else {
                throw ConfigStoreError.invalidRoot(override)
            }
            let store = try ConfigStore(
                rootURL: URL(fileURLWithPath: override, isDirectory: true))
            try store.validateOverrideRootScope()
            return store
        }

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ekctl", isDirectory: true)
        // Only the canonical, narrowly scoped ~/.ekctl location is eligible
        // for legacy permission repair. Arbitrary injected/override roots must
        // already be private and are never chmod'd as a side effect.
        return try ConfigStore(rootURL: root, repairExistingPermissions: true)
    }

    /// An environment typo must not turn a broad directory (home, a temp
    /// root, or the working tree) into an ekctl config store. Existing override
    /// directories are accepted only when empty or already contain solely the
    /// two entries managed by this store.
    private func validateOverrideRootScope() throws {
        let standardizedPath = directoryURL.standardizedFileURL.path
        let forbiddenPaths: Set<String> = [
            "/",
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
            FileManager.default.temporaryDirectory.standardizedFileURL.path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .standardizedFileURL.path,
            "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp",
        ]
        guard !forbiddenPaths.contains(standardizedPath) else {
            throw ConfigStoreError.invalidRoot(standardizedPath)
        }

        var info = stat()
        if standardizedPath.withCString({ Darwin.lstat($0, &info) }) != 0 {
            let code = errno
            if code == ENOENT { return }
            throw ConfigStoreError.io(
                operation: "inspect override directory",
                path: standardizedPath,
                code: code
            )
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            let reason = info.st_mode & S_IFMT == S_IFLNK
                ? "symbolic links are not allowed"
                : "not a directory"
            throw ConfigStoreError.unsafeEntry(path: standardizedPath, reason: reason)
        }

        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: standardizedPath)
        } catch let error as CocoaError {
            throw ConfigStoreError.unsafeEntry(
                path: standardizedPath,
                reason: "could not inspect directory contents (\(error.code.rawValue))"
            )
        }
        let managedEntries: Set<String> = [configFileName, lockFileName]
        let unexpected = entries.filter { !managedEntries.contains($0) }.sorted()
        guard unexpected.isEmpty else {
            throw ConfigStoreError.unsafeEntry(
                path: standardizedPath,
                reason: "contains entries not managed by ekctl: \(unexpected.joined(separator: ", "))"
            )
        }
    }

    // MARK: - Alias operations

    public func setAlias(name: String, id: String) throws {
        try Self.validateAlias(name: name, id: id)
        try withLockedDirectory { directoryFD in
            var config = try loadLocked(directoryFD: directoryFD)
            config.aliases[name] = id
            guard config.aliases.count <= Self.maximumAliasCount else {
                throw ConfigStoreError.tooManyAliases(maximum: Self.maximumAliasCount)
            }
            try saveLocked(config, directoryFD: directoryFD)
        }
    }

    public func removeAlias(name: String) throws -> Bool {
        try Self.validateAliasName(name)
        return try withLockedDirectory { directoryFD in
            var config = try loadLocked(directoryFD: directoryFD)
            guard config.aliases.removeValue(forKey: name) != nil else {
                return false
            }
            try saveLocked(config, directoryFD: directoryFD)
            return true
        }
    }

    public func getAliases() throws -> [String: String] {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        return try loadReadOnly().aliases
    }

    public func resolveAlias(_ nameOrID: String) throws -> String {
        let aliases = try getAliases()
        return aliases[nameOrID] ?? nameOrID
    }

    public func resolveCalendarIDs(_ list: String) throws -> [String] {
        let components = list.split(
            separator: ",",
            omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespaces) }

        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else {
            throw ConfigStoreError.invalidCalendarList("entries must not be empty")
        }

        let aliases = try getAliases()
        return components.map { aliases[$0] ?? $0 }
    }

    // MARK: - Validation

    private static func validateConfig(_ config: Config) throws {
        guard config.version == supportedVersion else {
            throw ConfigStoreError.unsupportedVersion(config.version)
        }
        guard config.aliases.count <= maximumAliasCount else {
            throw ConfigStoreError.tooManyAliases(maximum: maximumAliasCount)
        }
        for (name, id) in config.aliases {
            do {
                try validateAlias(name: name, id: id)
            } catch ConfigStoreError.invalidAliasName {
                throw ConfigStoreError.corrupted("contains an invalid alias name")
            } catch ConfigStoreError.invalidAliasID {
                throw ConfigStoreError.corrupted("contains an invalid alias ID")
            }
        }
    }

    /// Validates an alias without touching the file system. This is used by
    /// dry-run command paths before they request permissions or write config.
    public static func validateAlias(name: String, id: String) throws {
        try validateAliasName(name)
        try validateAliasID(id)
    }

    /// Validates an alias name without reading or writing config.
    public static func validateAliasName(_ name: String) throws {
        guard !name.isEmpty else {
            throw ConfigStoreError.invalidAliasName("must not be empty")
        }
        guard name.count <= 128 else {
            throw ConfigStoreError.invalidAliasName("must be at most 128 characters")
        }
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ConfigStoreError.invalidAliasName("must not have surrounding whitespace")
        }
        guard !name.contains(",") else {
            throw ConfigStoreError.invalidAliasName("must not contain a comma")
        }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ConfigStoreError.invalidAliasName("must not contain control characters")
        }
    }

    private static func validateAliasID(_ id: String) throws {
        guard !id.isEmpty else {
            throw ConfigStoreError.invalidAliasID("must not be empty")
        }
        guard id.count <= 1_024 else {
            throw ConfigStoreError.invalidAliasID("must be at most 1024 characters")
        }
        guard id == id.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ConfigStoreError.invalidAliasID("must not have surrounding whitespace")
        }
        guard !id.contains(",") else {
            throw ConfigStoreError.invalidAliasID("must not contain a comma")
        }
        guard id.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ConfigStoreError.invalidAliasID("must not contain control characters")
        }
    }

    // MARK: - Locked file-system access

    private func withLockedDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let directoryFD = try openSecureDirectory()
        defer { Darwin.close(directoryFD) }

        let lockFD = try openRegularFile(
            named: lockFileName,
            in: directoryFD,
            flags: O_RDWR | O_CREAT | O_NONBLOCK,
            mode: 0o600,
            path: directoryURL.appendingPathComponent(lockFileName).path,
            allowCreate: true
        )
        defer { Darwin.close(lockFD) }

        try acquireExclusiveLock(lockFD)
        defer { _ = systemFlock(lockFD, LOCK_UN) }

        return try body(directoryFD)
    }

    private func openSecureDirectory() throws -> Int32 {
        var createdDirectory = false
        var info = stat()
        if directoryURL.path.withCString({ Darwin.lstat($0, &info) }) != 0 {
            let code = errno
            guard code == ENOENT else {
                throw ConfigStoreError.io(
                    operation: "inspect directory", path: directoryURL.path, code: code)
            }

            if directoryURL.path.withCString({ Darwin.mkdir($0, 0o700) }) != 0 {
                let mkdirCode = errno
                guard mkdirCode == EEXIST else {
                    throw ConfigStoreError.io(
                        operation: "create directory", path: directoryURL.path, code: mkdirCode)
                }
            } else {
                createdDirectory = true
            }
        } else {
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR else {
                let reason = type == S_IFLNK ? "symbolic links are not allowed" : "not a directory"
                throw ConfigStoreError.unsafeEntry(path: directoryURL.path, reason: reason)
            }
        }

        let directoryFD = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else {
            let code = errno
            if code == ELOOP {
                throw ConfigStoreError.unsafeEntry(
                    path: directoryURL.path, reason: "symbolic links are not allowed")
            }
            throw ConfigStoreError.io(
                operation: "open directory", path: directoryURL.path, code: code)
        }

        do {
            try secureDescriptor(
                directoryFD,
                expectedType: S_IFDIR,
                permissions: 0o700,
                path: directoryURL.path,
                requireSingleLink: false,
                repairPermissions: createdDirectory || repairExistingPermissions
            )
            return directoryFD
        } catch {
            Darwin.close(directoryFD)
            throw error
        }
    }

    private func openRegularFile(
        named name: String,
        in directoryFD: Int32,
        flags: Int32,
        mode: mode_t,
        path: String,
        allowCreate: Bool
    ) throws -> Int32 {
        let effectiveFlags = flags | O_NOFOLLOW | O_CLOEXEC
        var createdFile = false
        let fd: Int32
        if allowCreate, flags & O_CREAT != 0, flags & O_EXCL == 0 {
            // Learn whether this invocation created the file without a racy
            // preflight check. New files may be fchmod'd to counteract umask;
            // existing files follow the store's narrowly scoped repair policy.
            let createFD = Darwin.openat(directoryFD, name, effectiveFlags | O_EXCL, mode)
            if createFD >= 0 {
                fd = createFD
                createdFile = true
            } else if errno == EEXIST {
                fd = Darwin.openat(
                    directoryFD,
                    name,
                    effectiveFlags & ~O_CREAT & ~O_EXCL
                )
            } else {
                fd = createFD
            }
        } else if allowCreate {
            fd = Darwin.openat(directoryFD, name, effectiveFlags, mode)
            createdFile = fd >= 0 && flags & O_CREAT != 0 && flags & O_EXCL != 0
        } else {
            fd = Darwin.openat(directoryFD, name, effectiveFlags)
        }

        guard fd >= 0 else {
            let code = errno
            if code == ELOOP {
                throw ConfigStoreError.unsafeEntry(path: path, reason: "symbolic links are not allowed")
            }
            throw ConfigStoreError.io(operation: "open", path: path, code: code)
        }

        do {
            try secureDescriptor(
                fd,
                expectedType: S_IFREG,
                permissions: mode,
                path: path,
                requireSingleLink: true,
                repairPermissions: createdFile || repairExistingPermissions
            )
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func secureDescriptor(
        _ fd: Int32,
        expectedType: mode_t,
        permissions: mode_t,
        path: String,
        requireSingleLink: Bool,
        repairPermissions: Bool
    ) throws {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else {
            throw ConfigStoreError.io(operation: "inspect", path: path, code: errno)
        }

        guard info.st_mode & S_IFMT == expectedType else {
            throw ConfigStoreError.unsafeEntry(path: path, reason: "unexpected file type")
        }
        guard info.st_uid == geteuid() else {
            throw ConfigStoreError.invalidOwner(path: path)
        }
        if requireSingleLink, info.st_nlink != 1 {
            throw ConfigStoreError.unsafeEntry(path: path, reason: "multiple hard links are not allowed")
        }

        // POSIX mode bits do not describe macOS extended ACL grants. Even a
        // 0600 file can be readable or writable by another principal through
        // an ACL, so fail closed instead of trying to interpret or silently
        // rewrite policy that belongs to the user/system administrator.
        try rejectExtendedACL(on: fd, path: path)

        if info.st_mode & 0o7777 != permissions, repairPermissions {
            guard Darwin.fchmod(fd, permissions) == 0 else {
                throw ConfigStoreError.io(operation: "set permissions", path: path, code: errno)
            }
            guard Darwin.fstat(fd, &info) == 0 else {
                throw ConfigStoreError.io(operation: "verify permissions", path: path, code: errno)
            }
            guard info.st_mode & 0o7777 == permissions else {
                throw ConfigStoreError.invalidPermissions(
                    path: path,
                    expected: String(format: "%04o", permissions)
                )
            }
        }
        guard info.st_mode & 0o7777 == permissions else {
            throw ConfigStoreError.invalidPermissions(
                path: path,
                expected: String(format: "%04o", permissions)
            )
        }
    }

    private func rejectExtendedACL(on fd: Int32, path: String) throws {
        errno = 0
        if let acl = Darwin.acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            Darwin.acl_free(UnsafeMutableRawPointer(acl))
            throw ConfigStoreError.unsafeEntry(
                path: path,
                reason: "extended ACLs are not allowed"
            )
        }

        let code = errno
        // acl_get_fd_np uses ENOENT to report that no extended ACL exists.
        guard code == ENOENT else {
            throw ConfigStoreError.io(
                operation: "inspect extended ACL",
                path: path,
                code: code
            )
        }
    }

    private func acquireExclusiveLock(_ fd: Int32) throws {
        let timeout = UInt64(Self.lockTimeoutSeconds) * 1_000_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeout
        while systemFlock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK || code == EAGAIN {
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    throw ConfigStoreError.lockTimedOut(
                        path: directoryURL.appendingPathComponent(lockFileName).path,
                        seconds: Self.lockTimeoutSeconds
                    )
                }
                usleep(50_000)
                continue
            }
            throw ConfigStoreError.io(
                operation: "lock",
                path: directoryURL.appendingPathComponent(lockFileName).path,
                code: code
            )
        }
    }

    // MARK: - Decode / encode

    /// Reads never create, lock, chmod, or otherwise modify file-system state.
    /// Atomic replacement makes an already-open regular-file descriptor a
    /// coherent snapshot even while another process publishes a new config.
    private func loadReadOnly() throws -> Config {
        var info = stat()
        if directoryURL.path.withCString({ Darwin.lstat($0, &info) }) != 0 {
            let code = errno
            if code == ENOENT { return Config() }
            throw ConfigStoreError.io(
                operation: "inspect directory", path: directoryURL.path, code: code)
        }

        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR else {
            let reason = type == S_IFLNK ? "symbolic links are not allowed" : "not a directory"
            throw ConfigStoreError.unsafeEntry(path: directoryURL.path, reason: reason)
        }

        let directoryFD = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else {
            let code = errno
            if code == ELOOP {
                throw ConfigStoreError.unsafeEntry(
                    path: directoryURL.path, reason: "symbolic links are not allowed")
            }
            throw ConfigStoreError.io(
                operation: "open directory", path: directoryURL.path, code: code)
        }
        defer { Darwin.close(directoryFD) }

        try secureDescriptor(
            directoryFD,
            expectedType: S_IFDIR,
            permissions: 0o700,
            path: directoryURL.path,
            requireSingleLink: false,
            repairPermissions: false
        )
        return try loadExistingConfig(directoryFD: directoryFD, repairPermissions: false)
    }

    private func loadLocked(directoryFD: Int32) throws -> Config {
        try loadExistingConfig(
            directoryFD: directoryFD,
            repairPermissions: repairExistingPermissions
        )
    }

    private func loadExistingConfig(
        directoryFD: Int32,
        repairPermissions: Bool
    ) throws -> Config {
        let fd = Darwin.openat(
            directoryFD,
            configFileName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return Config() }
            if code == ELOOP {
                throw ConfigStoreError.unsafeEntry(
                    path: configFileURL.path, reason: "symbolic links are not allowed")
            }
            throw ConfigStoreError.io(operation: "open", path: configFileURL.path, code: code)
        }
        defer { Darwin.close(fd) }

        try secureDescriptor(
            fd,
            expectedType: S_IFREG,
            permissions: 0o600,
            path: configFileURL.path,
            requireSingleLink: true,
            repairPermissions: repairPermissions
        )

        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else {
            throw ConfigStoreError.io(operation: "inspect", path: configFileURL.path, code: errno)
        }
        guard info.st_size <= Self.maximumConfigSize else {
            throw ConfigStoreError.configTooLarge(
                actual: info.st_size,
                maximum: Self.maximumConfigSize
            )
        }

        let data = try readData(from: fd)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigStoreError.corrupted("malformed JSON")
        }
        guard let dictionary = object as? [String: Any] else {
            throw ConfigStoreError.corrupted("top level must be an object")
        }
        let expectedKeys: Set<String> = ["aliases", "version"]
        guard Set(dictionary.keys) == expectedKeys else {
            throw ConfigStoreError.corrupted("unexpected or missing top-level fields")
        }

        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigStoreError.corrupted("schema does not match the supported format")
        }
        try Self.validateConfig(config)
        return config
    }

    private func readData(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while true {
            let count: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { return data }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw ConfigStoreError.io(operation: "read", path: configFileURL.path, code: code)
            }
            guard data.count + count <= Self.maximumConfigSize else {
                throw ConfigStoreError.configTooLarge(
                    actual: Int64(data.count + count),
                    maximum: Self.maximumConfigSize
                )
            }
            data.append(buffer, count: count)
        }
    }

    private func saveLocked(_ config: Config, directoryFD: Int32) throws {
        try Self.validateConfig(config)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        guard data.count <= Self.maximumConfigSize else {
            throw ConfigStoreError.configTooLarge(
                actual: Int64(data.count),
                maximum: Self.maximumConfigSize
            )
        }

        let temporaryName = ".config.json.tmp.\(getpid()).\(UUID().uuidString)"
        let temporaryPath = directoryURL.appendingPathComponent(temporaryName).path
        let temporaryFD = try openRegularFile(
            named: temporaryName,
            in: directoryFD,
            flags: O_WRONLY | O_CREAT | O_EXCL,
            mode: 0o600,
            path: temporaryPath,
            allowCreate: true
        )

        var renamed = false
        defer {
            Darwin.close(temporaryFD)
            if !renamed {
                _ = Darwin.unlinkat(directoryFD, temporaryName, 0)
            }
        }

        try writeData(data, to: temporaryFD, path: temporaryPath)
        guard Darwin.fsync(temporaryFD) == 0 else {
            throw ConfigStoreError.io(operation: "sync temporary file", path: temporaryPath, code: errno)
        }

        guard Darwin.renameat(directoryFD, temporaryName, directoryFD, configFileName) == 0 else {
            throw ConfigStoreError.io(operation: "replace", path: configFileURL.path, code: errno)
        }
        renamed = true

        guard Darwin.fsync(directoryFD) == 0 else {
            throw ConfigStoreError.io(
                operation: "sync directory", path: directoryURL.path, code: errno)
        }
    }

    private func writeData(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw ConfigStoreError.io(operation: "write", path: path, code: code)
                }
                guard count > 0 else {
                    throw ConfigStoreError.io(operation: "write", path: path, code: EIO)
                }
                offset += count
            }
        }
    }
}

/// Compatibility facade for existing CLI call sites. New code should depend on
/// an injected `ConfigStore` and use its throwing read methods directly.
public struct ConfigManager {
    private static func productionStore() throws -> ConfigStore {
        try ConfigStore.production()
    }

    public static func setAlias(name: String, id: String) throws {
        try productionStore().setAlias(name: name, id: id)
    }

    public static func removeAlias(name: String) throws -> Bool {
        try productionStore().removeAlias(name: name)
    }

    public static func validateAlias(name: String, id: String) throws {
        try ConfigStore.validateAlias(name: name, id: id)
    }

    public static func validateAliasName(_ name: String) throws {
        try ConfigStore.validateAliasName(name)
    }

    /// Throwing read API for fail-closed command paths.
    public static func getAliasesThrowing() throws -> [String: String] {
        try productionStore().getAliases()
    }

    /// Throwing alias resolution for fail-closed command paths.
    public static func resolveAliasThrowing(_ nameOrID: String) throws -> String {
        try productionStore().resolveAlias(nameOrID)
    }

    /// Throwing multi-calendar resolution for fail-closed command paths.
    public static func resolveCalendarIDsThrowing(_ list: String) throws -> [String] {
        try productionStore().resolveCalendarIDs(list)
    }

    /// Temporary non-throwing adapter retained until CLI commands accept an
    /// injected ConfigStore. It never writes after a failed read.
    public static func getAliases() -> [String: String] {
        do {
            return try productionStore().getAliases()
        } catch {
            return [:]
        }
    }

    /// Temporary non-throwing adapter retained for source compatibility.
    public static func resolveAlias(_ nameOrID: String) -> String {
        do {
            return try productionStore().resolveAlias(nameOrID)
        } catch {
            return nameOrID
        }
    }

    /// Temporary non-throwing adapter retained for source compatibility.
    public static func resolveCalendarIDs(_ list: String) -> [String] {
        do {
            return try productionStore().resolveCalendarIDs(list)
        } catch {
            return list.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
    }

    public static func configPath() -> String {
        do {
            return try productionStore().configFileURL.path
        } catch {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ekctl/config.json").path
        }
    }
}
