import CCTransCore
import Foundation
import Testing

struct CctransAccountRequestBridgeTests {
    @Test func dispatcherRoutesNativeActionsAndRejectsUnknownAction() async {
        let dispatcher = CctransAccountRequestDispatcher(
            appleLogin: { _ in .success(title: "Apple", message: "apple") },
            logout: { _ in .success(title: "Logout", message: "logout") },
            refresh: { _ in .success(title: "Refresh", message: "refresh") }
        )
        let request = pendingRequest(action: .appleLogin)

        #expect(await dispatcher.response(for: request).message == "apple")
        #expect(await dispatcher.response(for: pendingRequest(action: .logout)).message == "logout")
        #expect(await dispatcher.response(for: pendingRequest(action: .refresh)).message == "refresh")
        #expect(await dispatcher.response(for: pendingRequest(action: .unknown("missing"))).code == .error)
    }

    @Test func missingStoreKitHandlerReturnsTypedNotAvailableResponse() async {
        let dispatcher = CctransAccountRequestDispatcher(
            appleLogin: { _ in .success(title: "Apple", message: "apple") },
            logout: { _ in .success(title: "Logout", message: "logout") },
            refresh: { _ in .success(title: "Refresh", message: "refresh") }
        )

        #expect(await dispatcher.response(for: pendingRequest(action: .purchase)).code == .notAvailable)
        #expect(await dispatcher.response(for: pendingRequest(action: .restore)).code == .notAvailable)
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

    @Test func claimedRequestDisappearsWhenRequesterCancelsIt() throws {
        let directoryURL = temporaryDirectory()
        let requestURL = directoryURL.appendingPathComponent("req-cancelled.json")
        try Data(#"{"action":"appleLogin","nonce":"cancelled","createdAt":100}"#.utf8)
            .write(to: requestURL)
        let request = try #require(CctransAccountRequestFiles.pendingRequests(
            in: directoryURL,
            now: Date(timeIntervalSince1970: 110)
        ).first)
        let claimed = try CctransAccountRequestFiles.claim(request)

        try FileManager.default.removeItem(at: claimed.requestURL)
        try CctransAccountRequestFiles.complete(
            claimed,
            with: .success(title: "Apple", message: "Signed in."),
            in: directoryURL
        )

        #expect(!FileManager.default.fileExists(
            atPath: directoryURL.appendingPathComponent("resp-cancelled.json").path
        ))
    }

    @Test func freshClaimedRequestFromPreviousHostReloadsCurrentAccountState() throws {
        let directoryURL = temporaryDirectory()
        let claimedURL = directoryURL.appendingPathComponent("claimed-interrupted.json")
        try Data(#"{"action":"appleLogin","nonce":"interrupted","createdAt":100}"#.utf8)
            .write(to: claimedURL)

        let requests = try CctransAccountRequestFiles.pendingRequests(
            in: directoryURL,
            now: Date(timeIntervalSince1970: 110)
        )

        let responseURL = directoryURL.appendingPathComponent("resp-interrupted.json")
        let response = try JSONDecoder().decode(
            CctransAccountActionResponse.self,
            from: Data(contentsOf: responseURL)
        )
        #expect(requests.isEmpty)
        #expect(response.code == .success)
        #expect(response.ok)
        #expect(!FileManager.default.fileExists(atPath: claimedURL.path))
    }

    @Test func claimedRequestOlderThanPendingTTLStillRespondsBeforeRequesterTimeout() throws {
        let directoryURL = temporaryDirectory()
        let claimedURL = directoryURL.appendingPathComponent("claimed-waiting.json")
        try Data(#"{"action":"refresh","nonce":"waiting","createdAt":50}"#.utf8)
            .write(to: claimedURL)

        _ = try CctransAccountRequestFiles.pendingRequests(
            in: directoryURL,
            now: Date(timeIntervalSince1970: 110)
        )

        let responseURL = directoryURL.appendingPathComponent("resp-waiting.json")
        let response = try JSONDecoder().decode(
            CctransAccountActionResponse.self,
            from: Data(contentsOf: responseURL)
        )
        #expect(response.code == .success)
        #expect(!FileManager.default.fileExists(atPath: claimedURL.path))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctrans-account-request-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pendingRequest(action: CctransAccountRequestAction) -> CctransAccountPendingRequest {
        CctransAccountPendingRequest(
            action: action,
            nonce: UUID().uuidString,
            requestURL: temporaryDirectory().appendingPathComponent("claimed-request.json")
        )
    }
}
