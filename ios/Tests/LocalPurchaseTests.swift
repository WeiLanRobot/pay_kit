import Flutter
import StoreKit
import StoreKitTest
import XCTest

private final class EventRecorder: NSObject {
    var updates: [[String: Any]] = []
    @objc(invokeMethod:arguments:)
    func receive(_ method: String, arguments: Any?) {
        if method == "updated", let batch = arguments as? [String: Any], let items = batch["transactions"] as? [[String: Any]] {
            updates.append(contentsOf: items)
        }
    }
}

@MainActor
final class LocalPurchaseTests: XCTestCase {
    let plugin = PayKitTransactionPlugin()
    private let recorder = EventRecorder()
    private static var processOwner: PayKitTransactionPlugin?
    let writer = UUID().uuidString.lowercased()
    let sku = "test.coins"

    func call(_ method: String, _ args: [String: Any] = [:]) async throws -> Any? {
        var arguments = args
        arguments["writer"] = writer
        let reply: Any? = await withCheckedContinuation { continuation in
            plugin.handle(FlutterMethodCall(methodName: method, arguments: arguments)) {
                continuation.resume(returning: $0)
            }
        }
        if let error = reply as? FlutterError {
            throw NSError(domain: error.code, code: 1)
        }
        return reply
    }

    func items(_ method: String = "snapshot") async throws -> [[String: Any]] {
        if method == "start" { plugin.setValue(recorder, forKey: "channel") }
        let batch = try await call(method) as? [String: Any]
        return try XCTUnwrap(batch?["transactions"] as? [[String: Any]])
    }

    func waitForItem(_ status: String, _ token: String) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            let entries = recorder.updates
            if let entry = entries.first(where: {
                $0["status"] as? String == status && $0["token"] as? String == token
            }) { return entry }
            if let failed = SKPaymentQueue.default().transactions.first(where: { $0.transactionState == .failed }),
               status == "paid", let error = failed.error as NSError? {
                XCTFail("Test payment failed: \(error.domain) \(error.code) \(error.localizedDescription) \(error.userInfo[NSUnderlyingErrorKey] as Any)")
                throw error
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        let observed = try await items().map { [$0["status"], $0["token"], $0["transactionId"]] }
        XCTFail("Missing local StoreKit state \(status), observed \(observed)")
        throw NSError(domain: "missing_item", code: 1)
    }

    func finish(_ item: [String: Any]) async throws {
        let args = ["handle": try XCTUnwrap(item["handle"]), "status": try XCTUnwrap(item["status"])]
        let first = try await call("finish", args) as? String
        XCTAssertEqual(first, "finished")
        let replay = try await call("finish", args) as? String
        XCTAssertTrue(["finished", "removed"].contains(replay ?? ""))
        let deadline = Date().addingTimeInterval(8)
        while !(try await items()).isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let remaining = try await items()
        XCTAssertTrue(remaining.isEmpty)
    }

    private func withSession(_ body: (SKTestSession) async throws -> Void) async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        defer {
            plugin.stopObserving()
            session.resetToDefaultState()
            session.clearTransactions()
        }
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        // A confirmed test setting gates all store operations when the CLI
        // fails to provision StoreKitTest on a simulator.
        guard session.disableDialogs else {
            throw NSError(domain: "local_storekit_session_unavailable", code: 1)
        }
        try await body(session)
    }

    func testPreparationRejectsSubscriptionAndProductOutsideConsumableCatalog() async throws {
        try await withSession { _ in
            _ = try await items("start")
            for product in ["test.monthly", "test.unlock"] {
                do {
                    _ = try await call("prepare", ["productId": product])
                    XCTFail("Prepared an unsupported product")
                } catch {
                    XCTAssertEqual((error as NSError).domain, "unsupported_product_type")
                }
                do {
                    _ = try await call("purchase", ["productId": product, "token": UUID().uuidString])
                    XCTFail("Cached an unsupported product")
                } catch {
                    XCTAssertEqual((error as NSError).domain, "invalid_payment")
                }
            }
            let remaining = try await items()
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testCanceledPayment() async throws {
        try await withSession { session in
            try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
            _ = try await items("start")
            _ = try await call("prepare", ["productId": sku])
            let token = UUID().uuidString.lowercased()
            _ = try await call("purchase", ["productId": sku, "token": token])
            let canceled = try await waitForItem("canceled", token)
            try await finish(canceled)
        }
    }

    func testPurchaseAndRepeatAfterFinish() async throws {
        try await withSession { session in
            _ = try await items("start")
            _ = try await call("prepare", ["productId": sku])
            for _ in 0..<2 {
                let token = UUID().uuidString.lowercased()
                _ = try await call("purchase", ["productId": sku, "token": token])
                let paid = try await waitForItem("paid", token)
                let stableId = try XCTUnwrap(paid["transactionId"] as? String)
                let snapshot = try await call("start") as? [String: Any]
                XCTAssertFalse((snapshot?["receipt"] as? String ?? "").isEmpty)
                let replay = try await waitForItem("paid", token)
                XCTAssertEqual(paid["handle"] as? String, replay["handle"] as? String)
                XCTAssertEqual(paid["queueId"] as? String, stableId)
                do {
                    _ = try await call("purchase", ["productId": sku, "token": UUID().uuidString])
                    XCTFail("Unfinished product was enqueued twice")
                } catch {
                    XCTAssertEqual((error as NSError).domain, "duplicate_product")
                }
                try await finish(paid)
            }
            XCTAssertEqual(session.allTransactions().filter { $0.productIdentifier == sku && $0.state == .purchased }.count, 2)
        }
    }

    func testReplayAfterProcessTermination() async throws {
        let environment = ProcessInfo.processInfo.environment
        let run = try XCTUnwrap(environment["PAYKIT_RESTART_NONCE"])
        _ = try XCTUnwrap(UUID(uuidString: run), "Expected a fresh run UUID")
        let phase = try XCTUnwrap(environment["PAYKIT_RESTART_PHASE"])
        let prefs = UserDefaults.standard
        let key = "paykitRestartEvidence"
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit"))
        if phase == "recover" {
            let previous = try XCTUnwrap(prefs.dictionary(forKey: key), "Missing seeded purchase evidence")
            guard previous["nonce"] as? String == run else {
                return XCTFail("Purchase evidence belongs to a different replay run")
            }
            defer { plugin.stopObserving() }
            let oldPid = try XCTUnwrap(previous["pid"] as? NSNumber)
            guard oldPid.int32Value != getpid() else { return XCTFail("Recovery reused the seed process") }
            let stable = try XCTUnwrap(previous["transaction"] as? String)
            let oldHandle = try XCTUnwrap(previous["handle"] as? String)
            let product = try XCTUnwrap(previous["product"] as? String)
            let token = try XCTUnwrap(previous["token"] as? String)
            guard !stable.isEmpty, !oldHandle.isEmpty, product == sku, UUID(uuidString: token) != nil else {
                return XCTFail("Invalid seeded transaction identity")
            }
            // Reattach the test-only client to the same local catalog. Do not
            // reset settings or clear transactions in the recovering process.
            let session = try SKTestSession(contentsOf: url)
            let recorded = session.allTransactions().contains {
                String($0.identifier) == stable && $0.productIdentifier == product && $0.state == .purchased
            }
            guard recorded else {
                return XCTFail("StoreKitTest has no record of the original purchase \(stable)")
            }
            _ = try await items("start")
            let deadline = Date().addingTimeInterval(15)
            repeat {
                let observed = try await items() + recorder.updates
                if let replay = observed.first(where: { $0["transactionId"] as? String == stable && $0["status"] as? String == "paid" }) {
                    guard replay["productId"] as? String == product else { return XCTFail("Replay SKU mismatch") }
                    if let observedToken = replay["token"] as? String, observedToken.lowercased() != token {
                        return XCTFail("Replay purchase UUID mismatch")
                    }
                    let handle = try XCTUnwrap(replay["handle"] as? String)
                    guard !handle.isEmpty, oldHandle != handle else { return XCTFail("Invalid recovery handle") }
                    try await finish(replay)
                    XCTContext.runActivity(named: "Recovered \(run) transaction \(stable)") { _ in }
                    prefs.removeObject(forKey: key)
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while Date() < deadline
            let queueCount = (try await items()).count
            XCTFail("StoreKitTest retained the purchase; SK1 returned \(queueCount) queue entries and \(recorder.updates.count) observer updates in the new process")
            return
        }
        guard phase == "seed" else { return XCTFail("Unknown replay test phase \(phase)") }
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        guard session.disableDialogs else { throw NSError(domain: "local_storekit_session_unavailable", code: 1) }
        _ = try await items("start")
        _ = try await call("prepare", ["productId": sku])
        let token = UUID().uuidString.lowercased()
        _ = try await call("purchase", ["productId": sku, "token": token])
        let paid = try await waitForItem("paid", token)
        Self.processOwner = plugin // Match the production lifetime until the OS terminates this process.
        let stable = try XCTUnwrap(paid["transactionId"] as? String)
        let handle = try XCTUnwrap(paid["handle"] as? String)
        guard !stable.isEmpty, !handle.isEmpty, paid["productId"] as? String == sku else {
            return XCTFail("Invalid seeded StoreKit item")
        }
        prefs.set(["nonce": run, "pid": getpid(), "transaction": stable, "product": sku,
                   "token": token, "handle": handle], forKey: key)
        XCTAssertTrue(prefs.synchronize())
        XCTContext.runActivity(named: "Seeded \(run) transaction \(stable)") { _ in }
    }
}
