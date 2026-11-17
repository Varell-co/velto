import Foundation
import Security
import VeltoCore

/// Source secrets live in the login Keychain, one generic password per source id. Only the app reads
/// them; the CLI works from the snapshot and never needs them.
enum Secrets {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Store.bundleID,
         kSecAttrAccount as String: id.uuidString]
    }

    static func read(_ id: UUID) -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty value deletes the item, so clearing the field in Settings really clears the secret.
    static func write(_ value: String, for id: UUID) {
        guard !value.isEmpty else { return delete(id) }
        let data = Data(value.utf8)
        if SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query(id)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Velto source secret"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(_ id: UUID) { SecItemDelete(query(id) as CFDictionary) }

    static func credentials(for source: Source) async throws -> Credentials {
        switch source.auth {
        case .none: Credentials()
        case .bearer: Credentials(token: read(source.id))
        case .basic: Credentials(password: read(source.id))
        case .command: Credentials(token: try await run(source.tokenCommand))
        }
    }

    /// Runs the token command in a login shell, so tools like `az` or `gcloud` are on PATH even though
    /// a menu bar app starts without the user's shell environment. Gives up after 20 s.
    static func run(_ command: String) async throws -> String {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { throw FetchError.credentials("Token command is empty") }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { process in
                timeout.cancel()
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: FetchError.credentials("Token command timed out after 20s"))
                } else if process.terminationStatus != 0 || out.isEmpty {
                    // stderr's first line names the problem ("Please run 'az login'") without echoing a token.
                    let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .split(separator: "\n").first.map { ": " + $0.prefix(120) } ?? ""
                    continuation.resume(throwing: FetchError.credentials("Token command failed (exit \(process.terminationStatus))\(detail)"))
                } else {
                    continuation.resume(returning: out)
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
            } catch {
                continuation.resume(throwing: FetchError.credentials("Token command could not start"))
            }
        }
    }
}
