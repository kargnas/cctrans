import CCTransCore
import CryptoKit
import Foundation
import Testing

@Suite(.serialized)
struct CctransAccountTests {
    @Test func loginStoresTokenSeparatelyFromSummary() async throws {
        let tokenStore = MockAccountTokenStore()
        let summaryURL = temporarySummaryURL()
        let summaryStore = CctransAccountSummaryStore(fileURL: summaryURL)
        let client = CctransAccountClient(
            session: makeAccountSession { request in
                #expect(request.url?.path.hasSuffix("/auth/login") == true)
                return .response(200, accountSessionJSON(token: "secret-sanctum-token"))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore),
            appTransactionProvider: { "signed-app-transaction" }
        )

        let session = try await client.login(email: "user@example.com", password: "password")

        #expect(session.token == "secret-sanctum-token")
        #expect(try tokenStore.load() == "secret-sanctum-token")
        #expect(try summaryStore.load()?.uuid == accountUUID)
        let storedJSON = try String(contentsOf: summaryURL, encoding: .utf8)
        #expect(!storedJSON.contains("secret-sanctum-token"))
        #expect(!storedJSON.contains("token"))
    }

    @Test func loginPropagatesTokenSaveFailureWithoutReplacingSummary() async throws {
        let tokenStore = MockAccountTokenStore(token: "previous-token", saveError: .saveFailed)
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let client = CctransAccountClient(
            session: makeAccountSession { _ in
                .response(200, accountSessionJSON(
                    token: "replacement-token",
                    name: "Replacement",
                    email: "replacement@example.com"
                ))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore)
        )

        await #expect(throws: MockAccountTokenStoreError.saveFailed) {
            try await client.login(email: "replacement@example.com", password: "password")
        }

        #expect(tokenStore.storedToken == "previous-token")
        #expect(try summaryStore.load() == accountSummary)
    }

    @Test func pendingReplaceTransactionCompletesSummaryFromStoredToken() throws {
        let directoryURL = temporaryAccountDirectory()
        let summaryStore = CctransAccountSummaryStore(
            fileURL: directoryURL.appendingPathComponent("account-summary.json")
        )
        try summaryStore.save(accountSummary)
        let tokenStore = MockAccountTokenStore(token: "replacement-token")
        let transactionURL = directoryURL.appendingPathComponent("account-session-transaction.json")
        try json([
            "kind": "replace",
            "token_sha256": tokenSHA256("replacement-token"),
            "account": accountObject(
                plan: "lifetime",
                lifetime: true,
                name: "Replacement",
                email: "replacement@example.com"
            ),
            "previous_token_sha256": tokenSHA256("previous-token"),
            "previous_account": accountObject(plan: "pro", lifetime: false),
        ]).write(to: transactionURL)
        let coordinator = CctransAccountSessionCoordinator(
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore)
        )

        #expect(try coordinator.loadToken() == "replacement-token")
        #expect(try summaryStore.load()?.email == "replacement@example.com")
        #expect(!FileManager.default.fileExists(atPath: transactionURL.path))
    }

    @Test func pendingClearTransactionRemovesSummaryWhenTokenIsMissing() throws {
        let directoryURL = temporaryAccountDirectory()
        let summaryStore = CctransAccountSummaryStore(
            fileURL: directoryURL.appendingPathComponent("account-summary.json")
        )
        try summaryStore.save(accountSummary)
        let transactionURL = directoryURL.appendingPathComponent("account-session-transaction.json")
        try json([
            "kind": "clear",
            "previous_token_sha256": tokenSHA256("previous-token"),
            "previous_account": accountObject(plan: "pro", lifetime: false),
        ]).write(to: transactionURL)
        let coordinator = CctransAccountSessionCoordinator(
            tokenStore: MockAccountTokenStore(),
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore)
        )

        #expect(try coordinator.loadToken() == nil)
        #expect(try summaryStore.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: transactionURL.path))
    }

    @Test func corruptedGenerationLengthsAreRejectedBeforeNetworkRequest() async throws {
        for length in [7, 9] {
            let directoryURL = temporaryAccountDirectory()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data(repeating: 0, count: length).write(
                to: directoryURL.appendingPathComponent("account-session.generation")
            )
            let summaryStore = CctransAccountSummaryStore(
                fileURL: directoryURL.appendingPathComponent("account-summary.json")
            )
            let captured = AccountRequestCapture()
            let client = CctransAccountClient(
                session: makeAccountSession { request in
                    captured.record(request)
                    return .response(200, accountSessionJSON(token: "unused-token"))
                },
                tokenStore: MockAccountTokenStore(),
                summaryStore: summaryStore,
                lockFileURL: accountLockURL(for: summaryStore)
            )

            do {
                _ = try await client.login(email: "user@example.com", password: "password")
                Issue.record("손상된 generation 파일을 거부해야 합니다.")
            } catch let error as CocoaError {
                #expect(error.code == .fileReadCorruptFile)
            }
            #expect(captured.lastRequest == nil)
        }
    }

    @Test func generationUsesSharedLittleEndianUInt64Contract() async throws {
        let directoryURL = temporaryAccountDirectory()
        let summaryStore = CctransAccountSummaryStore(
            fileURL: directoryURL.appendingPathComponent("account-summary.json")
        )
        let client = CctransAccountClient(
            session: makeAccountSession { _ in
                .response(200, accountSessionJSON(token: "stored-token"))
            },
            tokenStore: MockAccountTokenStore(),
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore)
        )

        _ = try await client.login(email: "user@example.com", password: "password")

        let generation = try Data(contentsOf: directoryURL.appendingPathComponent(
            "account-session.generation"
        ))
        #expect(generation == Data([1, 0, 0, 0, 0, 0, 0, 0]))
    }

    @Test func summaryPreservesAccountDisplayContractWithoutToken() throws {
        let summary = try JSONDecoder().decode(
            CctransAccountSummary.self,
            from: json([
                "uuid": accountUUID.uuidString.lowercased(),
                "name": "CCTrans User",
                "email": "user@example.com",
                "email_verified": true,
                "apple_linked": true,
                "plan": "pro",
                "source": "storekit",
                "pro_until": "2030-01-02T03:04:05Z",
                "lifetime": false,
                "syncing": true,
            ])
        )

        #expect(summary.uuid == accountUUID)
        #expect(summary.plan == .pro)
        #expect(summary.source == .storeKit)
        #expect(summary.expiresAt != nil)
        #expect(summary.lifetime == false)
        #expect(summary.syncing == true)
    }

    @Test func exclusiveFileLockIsOwnerOnlyAndBlocksChildProcess() throws {
        let directoryURL = temporaryAccountDirectory()
        let lockURL = directoryURL.appendingPathComponent("account-session.lock")
        let markerURL = directoryURL.appendingPathComponent("child-acquired")
        let lock = CctransAccountFileLock(fileURL: lockURL)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [
            "-MFcntl=:flock",
            "-e",
            "open(my $lock, '>>', $ARGV[0]) or die $!; flock($lock, LOCK_EX) or die $!; open(my $marker, '>', $ARGV[1]) or die $!; print $marker 'acquired';",
            lockURL.path,
            markerURL.path,
        ]

        try lock.withExclusiveLock {
            try child.run()
            Thread.sleep(forTimeInterval: 0.1)
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        }
        child.waitUntilExit()

        #expect(child.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func separateCoordinatorsSerializeSessionCommitsWithSharedFileLock() async throws {
        let directoryURL = temporaryAccountDirectory()
        let summaryStore = CctransAccountSummaryStore(
            fileURL: directoryURL.appendingPathComponent("account-summary.json")
        )
        let lockURL = directoryURL.appendingPathComponent("account-session.lock")
        let saveGate = BlockingTokenSaveGate()
        let tokenStore = BlockingAccountTokenStore(blockingToken: "token-a", gate: saveGate)
        let coordinatorA = CctransAccountSessionCoordinator(
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: lockURL
        )
        let coordinatorB = CctransAccountSessionCoordinator(
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: lockURL
        )
        let sequence = AccountRequestSequence()
        let session = makeAccountSession { _ in
            if sequence.next() == 1 {
                return .response(200, accountSessionJSON(
                    token: "token-a",
                    name: "Account A",
                    email: "a@example.com"
                ))
            }
            return .response(200, accountSessionJSON(
                token: "token-b",
                name: "Account B",
                email: "b@example.com"
            ))
        }
        let clientA = CctransAccountClient(session: session, sessionCoordinator: coordinatorA)
        let clientB = CctransAccountClient(session: session, sessionCoordinator: coordinatorB)

        let loginA = Task { try await clientA.login(email: "a@example.com", password: "password") }
        await saveGate.waitUntilBlocked()
        let loginB = Task { try await clientB.login(email: "b@example.com", password: "password") }
        try await Task.sleep(for: .milliseconds(50))

        #expect(tokenStore.storedToken == "token-a")
        #expect(try summaryStore.load() == nil)
        saveGate.open()
        _ = try await loginA.value
        _ = try await loginB.value

        #expect(tokenStore.storedToken == "token-b")
        #expect(try summaryStore.load()?.email == "b@example.com")
    }

    @Test func separateCoordinatorsRejectEarlierNetworkResponseThatArrivesLast() async throws {
        let directoryURL = temporaryAccountDirectory()
        let summaryStore = CctransAccountSummaryStore(
            fileURL: directoryURL.appendingPathComponent("account-summary.json")
        )
        let lockURL = directoryURL.appendingPathComponent("account-session.lock")
        let tokenStore = MockAccountTokenStore()
        let coordinatorA = CctransAccountSessionCoordinator(
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: lockURL
        )
        let coordinatorB = CctransAccountSessionCoordinator(
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: lockURL
        )
        let gate = AccountRequestGate()
        let sequence = AccountRequestSequence()
        let session = makeAccountSession { _ in
            if sequence.next() == 1 {
                await gate.markStartedAndWait()
                return .response(200, accountSessionJSON(
                    token: "token-a",
                    name: "Account A",
                    email: "a@example.com"
                ))
            }
            return .response(200, accountSessionJSON(
                token: "token-b",
                name: "Account B",
                email: "b@example.com"
            ))
        }
        let clientA = CctransAccountClient(session: session, sessionCoordinator: coordinatorA)
        let clientB = CctransAccountClient(session: session, sessionCoordinator: coordinatorB)

        let loginA = Task { try await clientA.login(email: "a@example.com", password: "password") }
        await gate.waitUntilStarted()
        let loginB = try await clientB.login(email: "b@example.com", password: "password")
        await gate.open()

        #expect(loginB.token == "token-b")
        await #expect(throws: CctransAccountError.operationSuperseded) {
            try await loginA.value
        }
        #expect(tokenStore.storedToken == "token-b")
        #expect(try summaryStore.load()?.email == "b@example.com")
    }

    @Test func cancelledAppleRequestDoesNotCommitReturnedSession() async throws {
        let tokenStore = MockAccountTokenStore()
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        let client = CctransAccountClient(
            session: makeAccountSession { _ in
                .response(200, accountSessionJSON(token: "unused-token"))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore)
        )

        await #expect(throws: CctransAccountError.operationSuperseded) {
            try await client.signInWithApple(
                identityToken: "identity-token",
                nonce: "nonce",
                shouldCommit: { false }
            )
        }

        #expect(tokenStore.storedToken == nil)
        #expect(try summaryStore.load() == nil)
    }

    @Test func separateCoordinatorsSerializeClearAgainstNewLogin() async throws {
        let directoryURL = temporaryAccountDirectory()
        let summaryStore = CctransAccountSummaryStore(
            fileURL: directoryURL.appendingPathComponent("account-summary.json")
        )
        try summaryStore.save(accountSummary)
        let lockURL = directoryURL.appendingPathComponent("account-session.lock")
        let deleteGate = BlockingTokenDeleteGate()
        let tokenStore = BlockingDeleteAccountTokenStore(token: "token-a", gate: deleteGate)
        let coordinatorA = CctransAccountSessionCoordinator(
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: lockURL
        )
        let coordinatorB = CctransAccountSessionCoordinator(
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: lockURL
        )
        let clientB = CctransAccountClient(
            session: makeAccountSession { _ in
                .response(200, accountSessionJSON(
                    token: "token-b",
                    name: "Account B",
                    email: "b@example.com"
                ))
            },
            sessionCoordinator: coordinatorB
        )

        let clearA = Task { try coordinatorA.clearIfTokenMatches("token-a") }
        await deleteGate.waitUntilBlocked()
        let loginB = Task { try await clientB.login(email: "b@example.com", password: "password") }
        try await Task.sleep(for: .milliseconds(50))

        #expect(tokenStore.storedToken == "token-a")
        #expect(try summaryStore.load() == accountSummary)
        deleteGate.open()
        try await clearA.value
        _ = try await loginB.value

        #expect(tokenStore.storedToken == "token-b")
        #expect(try summaryStore.load()?.email == "b@example.com")
    }

    @Test func refreshSendsBearerAndStoresLatestSummary() async throws {
        let tokenStore = MockAccountTokenStore(token: "stored-token")
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        let captured = AccountRequestCapture()
        let client = CctransAccountClient(
            session: makeAccountSession { request in
                captured.record(request)
                return .response(200, accountSummaryJSON(plan: "lifetime", lifetime: true))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore),
            appTransactionProvider: { "signed-app-transaction" }
        )

        let summary = try #require(try await client.refresh())

        #expect(summary.plan == .lifetime)
        #expect(summary.lifetime)
        let request = try #require(captured.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stored-token")
        #expect(request.value(forHTTPHeaderField: "X-Cctrans-App-Transaction") == "signed-app-transaction")
        #expect(try summaryStore.load() == summary)
    }

    @Test func unauthorizedRefreshClearsTokenAndSummary() async throws {
        let tokenStore = MockAccountTokenStore(token: "expired-token")
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let client = CctransAccountClient(
            session: makeAccountSession { _ in
                .response(401, json(["ok": false, "error": "invalid_token"]))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore),
            appTransactionProvider: { "signed-app-transaction" }
        )

        await #expect(throws: CctransAccountError.api(status: 401, code: .invalidToken)) {
            try await client.refresh()
        }

        #expect(try tokenStore.load() == nil)
        #expect(try summaryStore.load() == nil)
    }

    @Test func unauthorizedRefreshPropagatesTokenDeleteFailureAndKeepsSession() async throws {
        let tokenStore = MockAccountTokenStore(token: "expired-token", deleteError: .deleteFailed)
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let client = CctransAccountClient(
            session: makeAccountSession { _ in
                .response(401, json(["ok": false, "error": "invalid_token"]))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore),
            appTransactionProvider: { "signed-app-transaction" }
        )

        await #expect(throws: MockAccountTokenStoreError.deleteFailed) {
            try await client.refresh()
        }

        #expect(tokenStore.storedToken == "expired-token")
        #expect(try summaryStore.load() == accountSummary)
    }

    @Test func networkFailureKeepsLastSummary() async throws {
        let tokenStore = MockAccountTokenStore(token: "stored-token")
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let client = CctransAccountClient(
            session: makeAccountSession { _ in .failure(URLError(.notConnectedToInternet)) },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore),
            appTransactionProvider: { "signed-app-transaction" }
        )

        await #expect(throws: URLError.self) {
            try await client.refresh()
        }

        #expect(try tokenStore.load() == "stored-token")
        #expect(try summaryStore.load() == accountSummary)
    }

    @Test func logoutAlwaysClearsLocalSession() async throws {
        let tokenStore = MockAccountTokenStore(token: "stored-token")
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let captured = AccountRequestCapture()
        let client = CctransAccountClient(
            session: makeAccountSession { request in
                captured.record(request)
                return .response(200, json(["ok": true]))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore)
        )

        try await client.logout()

        #expect(captured.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer stored-token")
        #expect(try tokenStore.load() == nil)
        #expect(try summaryStore.load() == nil)
    }

    @Test func logoutPropagatesTokenDeleteFailureWithoutClaimingSuccess() async throws {
        let tokenStore = MockAccountTokenStore(token: "stored-token", deleteError: .deleteFailed)
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let captured = AccountRequestCapture()
        let client = CctransAccountClient(
            session: makeAccountSession { request in
                captured.record(request)
                return .response(200, json(["ok": true]))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore)
        )

        await #expect(throws: MockAccountTokenStoreError.deleteFailed) {
            try await client.logout()
        }

        #expect(captured.lastRequest == nil)
        #expect(tokenStore.storedToken == "stored-token")
        #expect(try summaryStore.load() == accountSummary)
    }

    @Test func tokenLoadFailureDoesNotBecomeAnonymousRefresh() async throws {
        let tokenStore = MockAccountTokenStore(token: "stored-token", loadError: .loadFailed)
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let captured = AccountRequestCapture()
        let client = CctransAccountClient(
            session: makeAccountSession { request in
                captured.record(request)
                return .response(200, accountSummaryJSON(plan: "pro", lifetime: false))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore)
        )

        await #expect(throws: MockAccountTokenStoreError.loadFailed) {
            try await client.refresh()
        }

        #expect(captured.lastRequest == nil)
        #expect(try summaryStore.load() == accountSummary)
    }

    @Test func laterLoginWinsWhenEarlierResponseArrivesLast() async throws {
        let tokenStore = MockAccountTokenStore()
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        let gate = AccountRequestGate()
        let sequence = AccountRequestSequence()
        let client = CctransAccountClient(
            session: makeAccountSession { _ in
                if sequence.next() == 1 {
                    await gate.markStartedAndWait()
                    return .response(200, accountSessionJSON(
                        token: "token-a",
                        name: "Account A",
                        email: "a@example.com"
                    ))
                }
                return .response(200, accountSessionJSON(
                    token: "token-b",
                    name: "Account B",
                    email: "b@example.com"
                ))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore)
        )

        let loginA = Task {
            try await client.login(email: "a@example.com", password: "password")
        }
        await gate.waitUntilStarted()
        let loginB = try await client.login(email: "b@example.com", password: "password")
        await gate.open()

        #expect(loginB.token == "token-b")
        await #expect(throws: CctransAccountError.operationSuperseded) {
            try await loginA.value
        }
        #expect(tokenStore.storedToken == "token-b")
        #expect(try summaryStore.load()?.email == "b@example.com")
    }

    @Test func logoutPreventsInFlightRefreshFromResurrectingSummary() async throws {
        let tokenStore = MockAccountTokenStore(token: "stored-token")
        let summaryStore = CctransAccountSummaryStore(fileURL: temporarySummaryURL())
        try summaryStore.save(accountSummary)
        let gate = AccountRequestGate()
        let client = CctransAccountClient(
            session: makeAccountSession { request in
                if request.url?.path.hasSuffix("/account") == true {
                    await gate.markStartedAndWait()
                    return .response(200, accountSummaryJSON(plan: "lifetime", lifetime: true))
                }
                return .response(200, json(["ok": true]))
            },
            tokenStore: tokenStore,
            summaryStore: summaryStore,
            lockFileURL: accountLockURL(for: summaryStore),
            appTransactionProvider: { "signed-app-transaction" }
        )

        let refresh = Task { try await client.refresh() }
        await gate.waitUntilStarted()
        try await client.logout()
        await gate.open()

        await #expect(throws: CctransAccountError.operationSuperseded) {
            try await refresh.value
        }
        #expect(tokenStore.storedToken == nil)
        #expect(try summaryStore.load() == nil)
    }
}

private let accountUUID = UUID(uuidString: "5D0BBD71-10D3-4F2C-B034-C5860B076E11")!
private let accountSummary = CctransAccountSummary(
    uuid: accountUUID,
    name: "CCTrans User",
    email: "user@example.com",
    emailVerified: true,
    appleLinked: false,
    plan: .pro,
    source: .stripe,
    proUntil: Date(timeIntervalSince1970: 1_900_000_000),
    lifetime: false,
    syncing: false
)

private enum MockAccountTokenStoreError: Error {
    case loadFailed
    case saveFailed
    case deleteFailed
}

private final class MockAccountTokenStore: CctransAccountTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private let loadError: MockAccountTokenStoreError?
    private var saveError: MockAccountTokenStoreError?
    private let deleteError: MockAccountTokenStoreError?

    init(
        token: String? = nil,
        loadError: MockAccountTokenStoreError? = nil,
        saveError: MockAccountTokenStoreError? = nil,
        deleteError: MockAccountTokenStoreError? = nil
    ) {
        self.token = token
        self.loadError = loadError
        self.saveError = saveError
        self.deleteError = deleteError
    }

    var storedToken: String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func load() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let loadError {
            throw loadError
        }
        return token
    }

    func save(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let saveError {
            self.saveError = nil
            throw saveError
        }
        self.token = token
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        if let deleteError {
            throw deleteError
        }
        token = nil
    }
}

private final class BlockingAccountTokenStore: CctransAccountTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private let blockingToken: String
    private let gate: BlockingTokenSaveGate

    init(blockingToken: String, gate: BlockingTokenSaveGate) {
        self.blockingToken = blockingToken
        self.gate = gate
    }

    var storedToken: String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func load() throws -> String? {
        storedToken
    }

    func save(_ token: String) throws {
        lock.lock()
        self.token = token
        lock.unlock()
        if token == blockingToken {
            gate.block()
        }
    }

    func delete() throws {
        lock.lock()
        token = nil
        lock.unlock()
    }
}

private final class BlockingTokenSaveGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isOpen = false

    func block() {
        condition.lock()
        isBlocked = true
        condition.broadcast()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked() async {
        while !readBlocked() {
            await Task.yield()
        }
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    private func readBlocked() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return isBlocked
    }
}

private final class BlockingDeleteAccountTokenStore: CctransAccountTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private let gate: BlockingTokenDeleteGate

    init(token: String, gate: BlockingTokenDeleteGate) {
        self.token = token
        self.gate = gate
    }

    var storedToken: String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    func load() throws -> String? {
        storedToken
    }

    func save(_ token: String) throws {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func delete() throws {
        gate.block()
        lock.lock()
        token = nil
        lock.unlock()
    }
}

private final class BlockingTokenDeleteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isBlocked = false
    private var isOpen = false

    func block() {
        condition.lock()
        isBlocked = true
        condition.broadcast()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked() async {
        while !readBlocked() {
            await Task.yield()
        }
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    private func readBlocked() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return isBlocked
    }
}

private final class AccountRequestSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

private actor AccountRequestGate {
    private var started = false
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWait() async {
        started = true
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private enum AccountStubResult {
    case response(Int, Data)
    case failure(Error)
}

private final class AccountRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return request
    }

    func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
    }
}

private func makeAccountSession(
    handler: @escaping @Sendable (URLRequest) async -> AccountStubResult
) -> URLSession {
    CctransAccountStubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CctransAccountStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class CctransAccountStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async -> AccountStubResult)?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "kargn.as"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let protocolInstance = self
        Task { @Sendable in
            let result = await Self.handler?(request) ?? .response(500, Data())
            protocolInstance.finish(result, request: request)
        }
    }

    override func stopLoading() {}

    private func finish(_ result: AccountStubResult, request: URLRequest) {
        switch result {
        case let .response(status, data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

private func accountSessionJSON(
    token: String,
    name: String = "CCTrans User",
    email: String = "user@example.com"
) -> Data {
    json([
        "ok": true,
        "token": token,
        "account": accountObject(plan: "pro", lifetime: false, name: name, email: email),
    ])
}

private func accountSummaryJSON(plan: String, lifetime: Bool) -> Data {
    json(["ok": true, "account": accountObject(plan: plan, lifetime: lifetime)])
}

private func accountObject(
    plan: String,
    lifetime: Bool,
    name: String = "CCTrans User",
    email: String = "user@example.com"
) -> [String: Any] {
    [
        "uuid": accountUUID.uuidString.lowercased(),
        "name": name,
        "email": email,
        "email_verified": true,
        "apple_linked": false,
        "plan": plan,
        "pro_until": lifetime ? NSNull() : "2030-01-02T03:04:05Z",
        "lifetime": lifetime,
    ]
}

private func temporarySummaryURL() -> URL {
    temporaryAccountDirectory()
        .appendingPathComponent("account-summary.json", isDirectory: false)
}

private func temporaryAccountDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cctrans-account-tests-\(UUID().uuidString)", isDirectory: true)
}

private func accountLockURL(for summaryStore: CctransAccountSummaryStore) -> URL {
    summaryStore.fileURL.deletingLastPathComponent()
        .appendingPathComponent("account-session.lock", isDirectory: false)
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func tokenSHA256(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}
