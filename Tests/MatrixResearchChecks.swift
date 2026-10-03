import CryptoKit
import Foundation

final class ResearchStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, body) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct MatrixResearchChecks {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResearchStub.self]
        let session = URLSession(configuration: configuration)
        let config = MatrixResearchService.Configuration(baseURL: URL(string: "https://research.invalid")!, token: String(repeating: "test", count: 10))
        func service(wait: Duration = .seconds(3)) -> MatrixResearchService {
            MatrixResearchService(configuration: config, session: session, pollInterval: .milliseconds(5), maximumWait: wait)
        }
        func jobID(_ request: URLRequest) -> String {
            let key = request.value(forHTTPHeaderField: "Idempotency-Key")!
            return "job_" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        }
        var id = "", submits = 0, keys: [String] = [], cancelCount = 0
        ResearchStub.handler = { request in
            assert(request.url!.path.hasPrefix("/v1/research"))
            assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(config.token)")
            if request.url!.path.hasSuffix("/cancel") { cancelCount += 1; return (200, ["id": id, "status": "cancelled"]) }
            if request.httpMethod == "POST" {
                submits += 1; id = jobID(request); keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                if submits == 1 { throw URLError(.networkConnectionLost) }
                return (202, ["id": id, "status": "running"])
            }
            return (200, ["id": id, "status": "succeeded", "result": "Verified answer https://example.com"])
        }
        let success = service()
        let answer = await success.research(question: "Look it up")
        assert(answer["result"] as? String == "Verified answer https://example.com")
        assert(answer["source"] as? String == "Web research using Browser Use and Gemini")
        assert(keys.count == 2 && keys[0] == keys[1])
        assert(!success.update.isRunning && success.update.status == "Research complete")
        assert(cancelCount == 0)

        ResearchStub.handler = { _ in (503, ["error": "matrix_auth_required", "debug": "private-secret"]) }
        let auth = await service().research(question: "test")
        assert((auth["error"] as! String).contains("renew backend access"))
        assert(!String(describing: auth).contains("private-secret"))
        try await Task.sleep(for: .milliseconds(20)) // let best-effort cleanup finish before changing the stub

        var cancelled = false
        ResearchStub.handler = { request in
            if request.url!.path.hasSuffix("/cancel") { cancelled = true; return (200, ["id": id, "status": "cancelled"]) }
            if request.httpMethod == "POST" { id = jobID(request); return (202, ["id": id, "status": "queued"]) }
            return (200, ["id": id, "status": cancelled ? "cancelled" : "running"])
        }
        let active = service()
        let task = Task { await active.research(question: "slow") }
        while !active.update.isRunning { await Task.yield() }
        let duplicate = await active.research(question: "another")
        assert((duplicate["error"] as! String).contains("already running"))
        assert(active.cancel())
        let stopped = await task.value
        assert((stopped["error"] as! String).contains("cancelled"))
        assert(cancelled && !active.update.isRunning)

        cancelCount = 0
        ResearchStub.handler = { request in
            if request.url!.path.hasSuffix("/cancel") { cancelCount += 1; return (200, ["id": id, "status": "cancelled"]) }
            if request.httpMethod == "POST" { id = jobID(request); return (202, ["id": id, "status": "queued"]) }
            return (200, ["id": id, "status": "running"])
        }
        let timeout = await service(wait: .milliseconds(10)).research(question: "slow")
        assert((timeout["error"] as! String).contains("too long"))
        try await Task.sleep(for: .milliseconds(30))
        assert(cancelCount > 0)
        let resetService = service()
        let resetTask = Task { await resetService.research(question: "old session") }
        while !resetService.update.isRunning { await Task.yield() }
        resetService.reset()
        _ = await resetTask.value
        assert(resetService.update.result.isEmpty && !resetService.update.isRunning)
        assert(resetService.update.status == "Ask me to research a place or look something up.")
        try await Task.sleep(for: .milliseconds(30))
        ResearchStub.handler = { request in
            assert(request.url!.path.hasPrefix("/v1/jobs"))
            if request.httpMethod == "POST" { id = jobID(request) }
            return (200, ["id": id, "status": "succeeded", "result": "Computed 17"])
        }
        let matrixAnswer = await service().research(question: "Compute a sum", provider: .matrix)
        assert(matrixAnswer["source"] as? String == "Cloud computer task using Matrix and Codex")
        print("Matrix research checks passed: retry identity, result delivery, authentication errors, one-job limit, cancellation, timeout and stale-session suppression")
    }
}
