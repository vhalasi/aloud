import Foundation

/// Opt-in network check using the same Swift service as the iPhone. No credentials in arguments/output.
/// swiftc Aloud/MatrixResearchService.swift Tests/MatrixResearchLiveCheck.swift -o /tmp/aloud-research-live
/// /tmp/aloud-research-live backend/.secrets.json 'Research question'
@main struct MatrixResearchLiveCheck {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Expected secrets-file path and question") }
        let secrets = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]
        let service = MatrixResearchService(configuration: .init(baseURL: URL(string: "https://aloud-matrix-api.max-766.workers.dev")!, token: secrets["API_TOKEN"]!))
        let result = await service.research(question: CommandLine.arguments[2])
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
        if result["error"] != nil { exit(1) }
    }
}
