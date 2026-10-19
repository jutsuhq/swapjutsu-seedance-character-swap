import Foundation
import Testing

@testable import SwapjutsuApp

/// Which Keychain item a build uses and the environment override. Every item
/// here is a throwaway this test process saves under a random service, so it reads back without a prompt and the
/// person's real items are never touched.
@MainActor
struct CredentialsTests {
    private static func secret(sharedWithTeam: Bool = false) -> KeychainSecret {
        KeychainSecret(service: "com.jutsustudio.swapjutsu.tests.\(UUID().uuidString)", sharedWithTeam: sharedWithTeam)
    }

    @Test func aTeamSignedBuildUsesTheTeamItemAndIgnoresTheEnvironment() {
        let store = ComfyKeyStore.select(
            appGroup: "ABCDE12345.com.jutsustudio.swapjutsu", environment: [ComfyKeyStore.environmentKey: "env"])
        #expect(store.secret == KeychainSecret(service: "com.jutsustudio.swapjutsu.comfy.team", sharedWithTeam: true))
        #expect(store.override == nil)
    }

    @Test(arguments: [".com.jutsustudio.swapjutsu", nil])
    func aBuildWithoutATeamUsesTheDevItemOrTheEnvironment(appGroup: String?) {
        let dev = KeychainSecret(service: "com.jutsustudio.swapjutsu.comfy.dev")
        let plain = ComfyKeyStore.select(appGroup: appGroup, environment: [:])
        #expect(plain == ComfyKeyStore(secret: dev))
        let blank = ComfyKeyStore.select(appGroup: appGroup, environment: [ComfyKeyStore.environmentKey: " \n"])
        #expect(blank.override == nil)
        let set = ComfyKeyStore.select(appGroup: appGroup, environment: [ComfyKeyStore.environmentKey: " env-key\n"])
        #expect(set == ComfyKeyStore(secret: dev, override: "env-key"))
    }

    @Test func theEnvironmentKeyWinsOverTheKeychain() throws {
        let secret = Self.secret()
        defer { try? secret.write("") }
        try secret.write("saved")
        let credentials = Credentials(comfy: ComfyKeyStore(secret: secret, override: "env-key"))
        #expect(credentials.hasComfyKey && credentials.comfyKey == "env-key")
        try credentials.saveComfyKey("")
        #expect(credentials.hasComfyKey && credentials.comfyKey == "env-key")
    }

    @Test(arguments: [false, true])
    func aSavedKeyIsReplacedInPlaceAndRemovedWhenEmpty(sharedWithTeam: Bool) throws {
        let secret = Self.secret(sharedWithTeam: sharedWithTeam)
        defer { try? secret.write("") }
        let credentials = Credentials(comfy: ComfyKeyStore(secret: secret))
        try credentials.saveComfyKey("  first \n")
        #expect(secret.read() == "first" && secret.exists() && credentials.hasComfyKey)
        try credentials.saveComfyKey("second")
        #expect(credentials.comfyKey == "second")
        try credentials.saveComfyKey("")
        #expect(secret.read() == nil && !secret.exists() && !credentials.hasComfyKey)
    }
}
