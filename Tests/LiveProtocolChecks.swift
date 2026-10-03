import Foundation

@main
struct LiveProtocolChecks {
    static func main() throws {
        let setup = LiveProtocol.setup()["setup"] as! [String: Any]
        assert(setup["model"] as? String == "models/gemini-3.8-live")
        assert((setup["generationConfig"] as? [String: Any])?["responseModalities"] as? [String] == ["AUDIO"])
        _ = try JSONSerialization.data(withJSONObject: LiveProtocol.setup())
        assert(tryParse(#"{"setupComplete":{}}"#).ready)

        // All PCM parts must play, irrespective of intervening text or malformed payloads.
        let event = tryParse(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQACAA=="}},{"text":"hello"},{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AwA="}},{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQ=="}},{"inlineData":{"mimeType":"image/jpeg","data":"AQACAA=="}}]},"inputTranscription":{"text":"What is here?"},"outputTranscription":{"text":"A chair."},"turnComplete":true}}"#)
        assert(event.audio == [Data([1, 0, 2, 0]), Data([3, 0])])
        assert(event.inputText == "What is here?" && event.outputText == "A chair.")
        assert(event.turnComplete)
        assert(tryParse(#"{"serverContent":{"interrupted":true}}"#).interrupted)
        assert(tryParse(#"{"goAway":{"timeLeft":"30s"}}"#).goingAway)
        assert(tryParse(#"{"error":{"code":403,"message":"Do not expose server error text"}}"#).errorCode == 403)
        assert(tryParse(#"{"usageMetadata":{"totalTokenCount":23}}"#).audio.isEmpty)
        do {
            _ = try LiveProtocol.parse(Data("[]".utf8))
            assertionFailure("Invalid root accepted")
        } catch {}
        let packet = LiveProtocol.media(Data([0, 1, 2, 3]), mimeType: "image/jpeg", kind: "video")
        let video = (packet["realtimeInput"] as! [String: Any])["video"] as! [String: String]
        assert(video["mimeType"] == "image/jpeg")
        assert(Data(base64Encoded: video["data"]!) == Data([0, 1, 2, 3]))
        assert((LiveProtocol.describe()["clientContent"] as! [String: Any])["turnComplete"] as? Bool == true)
        let enabled = LiveProtocol.setup(placesEnabled: true)["setup"] as! [String: Any]
        let declarations = ((enabled["tools"] as! [[String: Any]])[0]["functionDeclarations"] as! [[String: Any]])
        assert(declarations.count == 5)
        let baseline = ((setup["tools"] as! [[String: Any]])[0]["functionDeclarations"] as! [[String: Any]])
        assert(baseline.count == 3 && baseline[0]["name"] as? String == "get_current_location")
        let locationCall = tryParse(#"{"toolCall":{"functionCalls":[{"id":"gps-1","name":"get_current_location","args":{}}]}}"#).toolCalls[0]
        assert(locationCall.name == "get_current_location" && locationCall.arguments.isEmpty)
        let toolEvent = tryParse(#"{"toolCall":{"functionCalls":[{"id":"search-1","name":"find_nearby_places","args":{"category":"restaurant","radius_metres":800}},{"name":"missing_id"}]}}"#)
        assert(toolEvent.toolCalls.count == 1)
        let call = toolEvent.toolCalls[0]
        assert(call.id == "search-1" && call.arguments["category"] as? String == "restaurant")
        let reply = LiveProtocol.toolResponse(call, result: ["places": [], "source": "Google Maps"])
        let response = ((reply["toolResponse"] as! [String: Any])["functionResponses"] as! [[String: Any]])[0]
        assert(response["id"] as? String == "search-1" && response["name"] as? String == "find_nearby_places")
        assert(tryParse(#"{"toolCallCancellation":{"ids":["search-1"]}}"#).cancelledToolIDs == ["search-1"])
        _ = try JSONSerialization.data(withJSONObject: LiveProtocol.setup(placesEnabled: true))
        _ = try JSONSerialization.data(withJSONObject: reply)
        let researchSetup = LiveProtocol.setup(placesEnabled: true, researchEnabled: true)["setup"] as! [String: Any]
        let researchDeclarations = (researchSetup["tools"] as! [[String: Any]])[0]["functionDeclarations"] as! [[String: Any]]
        assert(researchDeclarations.count == 10)
        let gmail = researchDeclarations.first { $0["name"] as? String == "read_gmail" }!
        assert((gmail["parameters"] as! [String: Any])["required"] as? [String] == ["question"])
        assert(!baseline.contains { $0["name"] as? String == "read_gmail" })
        assert(researchDeclarations.filter { ($0["name"] as? String)?.contains("research") == true }.allSatisfy { $0["behavior"] as? String == "NON_BLOCKING" })
        assert(researchDeclarations.contains { $0["name"] as? String == "run_matrix_task" })
        assert(baseline.contains { $0["name"] as? String == "get_proximity_status" })
        let sensor = LiveProtocol.proximity(["status": "measured", "distance_metres": 0.5])
        assert((sensor["realtimeInput"] as! [String: String])["text"]!.hasPrefix("PROXIMITY_SENSOR_UPDATE "))
        assert(sensor["clientContent"] == nil)
        let researchCall = LiveProtocol.ToolCall(id: "research-1", name: "research_surroundings", arguments: [:])
        let researchReply = LiveProtocol.toolResponse(researchCall, result: ["result": "Sourced answer"], scheduling: "WHEN_IDLE")
        let functionReply = ((researchReply["toolResponse"] as! [String: Any])["functionResponses"] as! [[String: Any]])[0]
        assert(functionReply["scheduling"] as? String == "WHEN_IDLE")
        assert((functionReply["response"] as! [String: Any])["scheduling"] == nil)
        assert(tryParse(#"{"serverContent":{"interimInputTranscription":{"text":"Wait"}}}"#).inputActivity)
        _ = try JSONSerialization.data(withJSONObject: researchSetup)
        print("Live protocol checks passed")
    }

    static func tryParse(_ json: String) -> LiveProtocol.Event {
        try! LiveProtocol.parse(Data(json.utf8))
    }
}
