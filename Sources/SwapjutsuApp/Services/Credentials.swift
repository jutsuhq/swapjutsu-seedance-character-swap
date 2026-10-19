import Foundation
import Observation
import Security

/// The provider keys the app holds, observable so the sidebar and Settings update the moment a key is saved.
/// Views and the job store go through this instead of the Keychain. Launch only asks the Keychain whether an item
/// exists, which never decrypts it and so never prompts; the key itself is read when a render or Settings needs it.
@MainActor
@Observable
final class Credentials {
    private(set) var hasComfyKey: Bool
    private(set) var hasOwnComfyToken: Bool
    private let comfy: ComfyKeyStore
    private let ownComfy: KeychainSecret

    /// `ownComfy` defaults to an item beside the Comfy key's, with the same sharing.
    init(comfy: ComfyKeyStore = .live, ownComfy: KeychainSecret? = nil) {
        self.comfy = comfy
        self.ownComfy =
            ownComfy
            ?? KeychainSecret(service: comfy.secret.service + ".owncomfy", sharedWithTeam: comfy.secret.sharedWithTeam)
        hasComfyKey = comfy.override != nil || comfy.secret.exists()
        hasOwnComfyToken = self.ownComfy.exists()
    }

    /// The bearer token for an own ComfyUI behind a reverse proxy (Settings › Own ComfyUI).
    var ownComfyToken: String? {
        guard hasOwnComfyToken, let token = ownComfy.read(), !token.isEmpty else { return nil }
        return token
    }

    /// Saves the token, or removes it when empty.
    func saveOwnComfyToken(_ token: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try ownComfy.write(token)
        hasOwnComfyToken = !token.isEmpty
    }

    var comfyKey: String? {
        if let override = comfy.override { return override }
        if let key = comfy.secret.read(), !key.isEmpty { return key }
        return nil
    }

    /// Saves the key, or removes it when empty; state changes only after the Keychain took it.
    func saveComfyKey(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try comfy.secret.write(key)
        hasComfyKey = !key.isEmpty || comfy.override != nil
    }
}

/// Where the Comfy key lives for this build.
struct ComfyKeyStore: Equatable, Sendable {
    var secret: KeychainSecret
    /// `SWAPJUTSU_COMFY_KEY`, which a build without a team takes over the Keychain.
    var override: String?

    static let environmentKey = "SWAPJUTSU_COMFY_KEY"

    static var live: ComfyKeyStore {
        select(appGroup: AppPaths.appGroup, environment: ProcessInfo.processInfo.environment)
    }

    /// A bundle signed with a team names a group that starts with the team ID; an ad-hoc bundle's starts with "." and
    /// the `swift run` executable has none. Only a team-signed build uses the shared item, so a build that can't read
    /// it without a prompt never tries.
    static func select(appGroup: String?, environment: [String: String]) -> ComfyKeyStore {
        if let group = appGroup, !group.isEmpty, !group.hasPrefix(".") {
            return ComfyKeyStore(
                secret: KeychainSecret(service: "com.jutsustudio.swapjutsu.comfy.team", sharedWithTeam: true))
        }
        let override = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ComfyKeyStore(
            secret: KeychainSecret(service: "com.jutsustudio.swapjutsu.comfy.dev"),
            override: override?.isEmpty == false ? override : nil)
    }
}

/// A provider API key in the login (file-based) Keychain.
///
/// Its access list normally trusts only the exact signature of the build that saved it, so every rebuild prompts.
/// `sharedWithTeam` opens the access list to any app instead. The Keychain still checks the item's partition list,
/// which it sets from the signature of the saving app to its team ID, so every build signed by that team (Release,
/// Debug, the `swapjutsu` helper) reads the item without a prompt, while an ad-hoc build or another vendor's app still
/// has to ask for the password. The data protection keychain would do this by access group, but on macOS it needs a
/// provisioning profile: a Developer ID build with only the app group entitlement gets errSecMissingEntitlement.
struct KeychainSecret: Equatable, Sendable {
    let service: String
    var sharedWithTeam = false

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    /// Asks for the item's attributes only: nothing is decrypted, so no build is ever prompted.
    func exists() -> Bool {
        var item = query
        item[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(item as CFDictionary, nil) == errSecSuccess
    }

    func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        var data: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &data) == errSecSuccess, let data = data as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Updates the item in place, adding it only when there is none, so a failed write never loses the old key.
    /// An empty value removes the item.
    func write(_ value: String) throws {
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            if sharedWithTeam {
                item[kSecAttrAccess as String] = try (FileKeychain.self as any AnyAppAccess.Type).make()
            }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

/// Called through a protocol: SecAccess is deprecated with the rest of the file keychain's API, and a direct call
/// warns on every build. It is still the only way to set an item's access list, and the data protection keychain that
/// replaces it needs a provisioning profile (see `KeychainSecret`).
private protocol AnyAppAccess {
    static func make() throws -> SecAccess
}

private enum FileKeychain: AnyAppAccess {
    /// Every access list but the owner's admits any application; the partition list keeps it to the team.
    @available(macOS, deprecated: 10.10)
    static func make() throws -> SecAccess {
        var access: SecAccess?
        var status = SecAccessCreate("Swapjutsu" as CFString, nil, &access)
        guard status == errSecSuccess, let access else { throw KeychainError(status: status) }
        var lists: CFArray?
        status = SecAccessCopyACLList(access, &lists)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        for acl in lists as? [SecACL] ?? [] {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            if authorizations.contains(kSecACLAuthorizationChangeACL as String) { continue }
            status = SecACLSetContents(acl, nil, "Swapjutsu" as CFString, [])
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
        return access
    }
}

struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "The Keychain refused the key: \(reason)"
    }
}
