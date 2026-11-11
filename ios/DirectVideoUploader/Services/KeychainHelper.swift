import Darwin
import Foundation
import Security

nonisolated enum CredentialStoreError: Error, Equatable {
    case unavailable
    case invalidRecord
    case keychain(Int32)
}

nonisolated struct BoundAuthSession: Codable, Equatable, Sendable {
    let version: Int
    let token: String
    let server: String
    let userId: String
}

nonisolated enum DurableFile {
    static func synchronize(_ url: URL, directory: Bool) throws {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0)
        let descriptor = url.path.withCString { Darwin.open($0, flags) }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            if Darwin.close(descriptor) != 0 {
                Log.error("Could not close a synchronized file", logger: Log.app)
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

@MainActor
protocol AuthCredentialStorage {
    func load() throws -> BoundAuthSession?
    func save(_ session: BoundAuthSession) throws
    func remove() throws
    func removeLegacy() throws -> Bool
}

@MainActor
protocol AuthRestoreBarrier {
    func isActive() throws -> Bool
    func activate() throws
    func clear() throws
}

nonisolated enum KeychainHelper {
    private static let service = "com.directvideo.uploader"

    static func load(forKey key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw CredentialStoreError.invalidRecord }
        return data
    }

    static func save(_ data: Data, forKey key: String) throws {
        let query = baseQuery(key)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
            } else {
                try check(addStatus)
            }
        } else {
            try check(status)
        }
    }

    @discardableResult
    static func delete(forKey key: String) throws -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    private static func baseQuery(_ key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        if status == errSecInteractionNotAllowed || status == errSecNotAvailable {
            throw CredentialStoreError.unavailable
        }
        throw CredentialStoreError.keychain(status)
    }
}

@MainActor
struct KeychainAuthCredentialStorage: AuthCredentialStorage {
    private let key = "dvu_auth_session_v2"

    func load() throws -> BoundAuthSession? {
        guard let data = try KeychainHelper.load(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(BoundAuthSession.self, from: data)
        } catch {
            throw CredentialStoreError.invalidRecord
        }
    }

    func save(_ session: BoundAuthSession) throws {
        try KeychainHelper.save(JSONEncoder().encode(session), forKey: key)
    }

    func remove() throws {
        try KeychainHelper.delete(forKey: key)
    }

    func removeLegacy() throws -> Bool {
        try KeychainHelper.delete(forKey: UserDefaultsKeys.authToken)
    }
}

@MainActor
struct FileAuthRestoreBarrier: AuthRestoreBarrier {
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AuthRestoreBarrier", isDirectory: true)
    ) {
        self.directory = directory
    }

    func isActive() throws -> Bool {
        try prepareDirectory()
        do {
            _ = try FileManager.default.attributesOfItem(atPath: marker.path)
            return true
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        } catch let error as POSIXError where error.code == .ENOENT {
            return false
        }
    }

    func activate() throws {
        try prepareDirectory()
        let descriptor = marker.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        if descriptor < 0 {
            if errno == EEXIST {
                let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CredentialStoreError.invalidRecord
                }
                try protect(marker)
                try DurableFile.synchronize(marker, directory: false)
                try DurableFile.synchronize(directory, directory: true)
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var closed = false
        defer {
            if !closed {
                do {
                    try file.close()
                } catch {
                    Log.error("Could not close the sign-out barrier: \(Log.describe(error))", logger: Log.auth)
                }
            }
        }
        try protect(marker)
        try file.synchronize()
        try file.close()
        closed = true
        try DurableFile.synchronize(directory, directory: true)
    }

    func clear() throws {
        try prepareDirectory()
        do {
            try FileManager.default.removeItem(at: marker)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
        } catch let error as POSIXError where error.code == .ENOENT {
        }
        try DurableFile.synchronize(directory, directory: true)
    }

    private var marker: URL { directory.appendingPathComponent("do-not-restore") }

    private func prepareDirectory() throws {
        var missing: [URL] = []
        var ancestor = directory
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            missing.append(ancestor)
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { throw CredentialStoreError.invalidRecord }
            ancestor = parent
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CredentialStoreError.invalidRecord
            }
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.none])
        try protect(directory)
        for item in missing.reversed() {
            try DurableFile.synchronize(item.deletingLastPathComponent(), directory: true)
        }
    }

    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #if targetEnvironment(simulator)
        if attributes[.protectionKey] == nil {
            Log.debug("Simulator cannot report sign-out barrier protection", logger: Log.auth)
        } else if attributes[.protectionKey] as? String != FileProtectionType.none.rawValue {
            throw CredentialStoreError.invalidRecord
        }
        #else
        guard attributes[.protectionKey] as? String == FileProtectionType.none.rawValue else {
            throw CredentialStoreError.invalidRecord
        }
        #endif
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        guard try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw CredentialStoreError.invalidRecord
        }
    }
}
