import CCTransCore
import DeviceCheck
import Foundation

/// macOS App Attest implementation of `CctransAttesting` backed by `DCAppAttestService`.
///
/// Usable only in a properly signed build on a Mac with a Secure Enclave. Unsigned dev
/// builds report `isSupported == false`; the managed client then falls back to the dev
/// token path, so this type is never exercised there. The keyID is persisted to the
/// shared app-data dir so the app attests exactly once per install (each attestation
/// burns a Secure-Enclave key + a server registration).
final class CctransAppAttestor: CctransAttesting {
    static let shared = CctransAppAttestor()

    // Computed, not stored: DCAppAttestService is not Sendable, and storing it would
    // break this type's Sendable conformance. `.shared` is itself a process singleton.
    private var service: DCAppAttestService { DCAppAttestService.shared }
    // Plain file (not Keychain): the keyID is an opaque, non-secret handle — losing it
    // only forces a re-attest, and it must resolve to the SAME shared dir the Tauri
    // helper uses, which Keychain access groups would complicate.
    private let keyIDFileName = "cctrans-managed-keyid.txt"

    var isSupported: Bool { service.isSupported }

    func loadKeyID() -> String? {
        guard let data = try? Data(contentsOf: SharedAppStorage.fileURL(keyIDFileName)),
              let id = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return nil
        }
        return id
    }

    func saveKeyID(_ keyID: String) {
        do {
            try SharedAppStorage.ensureDirectoryExists()
            try Data(keyID.utf8).write(to: SharedAppStorage.fileURL(keyIDFileName), options: .atomic)
        } catch {
            // Loud, not silent: without persistence every launch re-attests, burning an
            // attestation and a server registration each time. Surface so it gets noticed.
            print("CCTrans Cloud: failed to persist App Attest keyID: \(error)")
        }
    }

    func generateKey() async throws -> String {
        try await service.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}
