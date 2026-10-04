import XCTest
import Darwin
import SumibiCore
@testable import SumibiIME

final class ConversionTimeoutIntegrationTests: XCTestCase {
    /// Opt-in: actual URLSession timeout against loopback, no provider/keychain/user input.
    @MainActor
    func testRealSixtySecondTimeoutPreservesOriginalAndReportsSafeNotice() async throws {
        guard ProcessInfo.processInfo.environment["SUMIBI_RUN_TIMEOUT_TEST"] == "1" else {
            throw XCTSkip("Set SUMIBI_RUN_TIMEOUT_TEST=1 to measure the real 60-second timeout locally.")
        }
        let connected = expectation(description: "loopback server accepted connection")
        let server = try SilentLoopbackServer { connected.fulfill() }
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 65
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        let client = OpenAICompatibleClient(configuration: OpenAICompatibleConfiguration(
            endpoint: URL(string: "http://127.0.0.1:\(server.port)")!, model: "dummy-model", apiKey: "dummy-local-key"),
                                            session: network)
        let session = InputSession()
        _ = session.receive(.text("dummy-original"))
        _ = session.receive(.convert)
        _ = session.receive(.text("dummy-queued"))
        let id = session.pending!.id
        let feedback = ConversionFeedback()
        let lifecycle = ConversionLifecycle(session: session, feedback: feedback) { request in
            do { return .success(try await client.convert(request)) }
            catch let error as ConversionError { return .failure(error) }
            catch { return .failure(.network("local test failure")) }
        }
        let ready = expectation(description: "real timeout delivered")
        let began = Date()
        lifecycle.start(id: id, request: ConversionRequest(source: "dummy-original")) { _ in ready.fulfill() }
        await fulfillment(of: [connected], timeout: 5)
        await fulfillment(of: [ready], timeout: 70)
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertGreaterThanOrEqual(elapsed, 58)
        XCTAssertLessThan(elapsed, 70)
        XCTAssertEqual(feedback.notice, .failure(.timedOut))
        XCTAssertEqual(lifecycle.takeOutcome(id: id), .failure(.timedOut))
        XCTAssertEqual(session.marked, "dummy-original")
        XCTAssertEqual(session.completeFirst(id: id, result: nil), [.marked("dummy-originaldummy-queued")])
        XCTAssertEqual(feedback.indicator, .error)
        XCTAssertFalse(feedback.isConverting)
        print(String(format: "Local URLSession timeout measured: %.2f seconds (dummy data only)", elapsed))
    }
}

private final class SilentLoopbackServer {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private let release = DispatchSemaphore(value: 0)

    init(onConnect: @escaping () -> Void) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard nameResult == 0 else { close(descriptor); throw POSIXError(.EIO) }
        listener = descriptor
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async { [self] in
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection) }
            lock.lock()
            let active = !stopped
            lock.unlock()
            guard active else { return }
            onConnect()
            // Accept bytes into the TCP buffer but never send an HTTP response.
            _ = release.wait(timeout: .now() + 90)
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        shutdown(listener, SHUT_RDWR)
        close(listener)
        release.signal()
    }
}
