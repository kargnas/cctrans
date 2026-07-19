import CCTransCore
import Foundation
import Testing

struct CctransAccountRequestBridgeTests {
    @Test func dispatcherRoutesNativeActionsAndRejectsUnknownAction() async {
        let dispatcher = CctransAccountRequestDispatcher(
            appleLogin: { .success(title: "Apple", message: "apple") },
            logout: { .success(title: "Logout", message: "logout") },
            refresh: { .success(title: "Refresh", message: "refresh") }
        )

        #expect(await dispatcher.response(for: .appleLogin).message == "apple")
        #expect(await dispatcher.response(for: .logout).message == "logout")
        #expect(await dispatcher.response(for: .refresh).message == "refresh")
        #expect(await dispatcher.response(for: .unknown("missing")).code == .error)
    }

    @Test func missingStoreKitHandlerReturnsTypedNotAvailableResponse() async {
        let dispatcher = CctransAccountRequestDispatcher(
            appleLogin: { .success(title: "Apple", message: "apple") },
            logout: { .success(title: "Logout", message: "logout") },
            refresh: { .success(title: "Refresh", message: "refresh") }
        )

        #expect(await dispatcher.response(for: .purchase).code == .notAvailable)
        #expect(await dispatcher.response(for: .restore).code == .notAvailable)
    }

    @Test func parserWritesResponseAndCleansRequestAndStaleFiles() throws {
        let directoryURL = temporaryDirectory()
        let requestURL = directoryURL.appendingPathComponent("req-safe-1.json")
        let staleResponseURL = directoryURL.appendingPathComponent("resp-stale.json")
        try Data(#"{"action":"logout","nonce":"safe-1","createdAt":100}"#.utf8)
            .write(to: requestURL)
        try Data("{}".utf8).write(to: staleResponseURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: staleResponseURL.path
        )

        let requests = try CctransAccountRequestFiles.pendingRequests(
            in: directoryURL,
            now: Date(timeIntervalSince1970: 110)
        )
        #expect(requests.count == 1)
        #expect(requests[0].action == .logout)
        #expect(!FileManager.default.fileExists(atPath: staleResponseURL.path))

        try CctransAccountRequestFiles.complete(
            requests[0],
            with: .success(title: "Logout", message: "Signed out."),
            in: directoryURL
        )

        let responseURL = directoryURL.appendingPathComponent("resp-safe-1.json")
        let response = try JSONDecoder().decode(
            CctransAccountActionResponse.self,
            from: Data(contentsOf: responseURL)
        )
        #expect(response.code == .success)
        #expect(!FileManager.default.fileExists(atPath: requestURL.path))
        #expect((try FileManager.default.attributesOfItem(atPath: responseURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func parserDeletesMalformedAndExpiredRequests() throws {
        let directoryURL = temporaryDirectory()
        let malformedURL = directoryURL.appendingPathComponent("req-malformed.json")
        let expiredURL = directoryURL.appendingPathComponent("req-expired.json")
        try Data("not-json".utf8).write(to: malformedURL)
        try Data(#"{"action":"refresh","nonce":"expired","createdAt":1}"#.utf8)
            .write(to: expiredURL)

        let requests = try CctransAccountRequestFiles.pendingRequests(
            in: directoryURL,
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: malformedURL.path))
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
    }

    @Test func lateHostCompletionDoesNotLeaveResponseAfterRequesterTimeout() throws {
        let directoryURL = temporaryDirectory()
        let request = CctransAccountPendingRequest(
            action: .refresh,
            nonce: "timed-out",
            requestURL: directoryURL.appendingPathComponent("req-timed-out.json")
        )

        try CctransAccountRequestFiles.complete(
            request,
            with: .success(title: "Refresh", message: "Refreshed."),
            in: directoryURL
        )

        #expect(!FileManager.default.fileExists(
            atPath: directoryURL.appendingPathComponent("resp-timed-out.json").path
        ))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctrans-account-request-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
