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
        print("Live protocol checks passed")
    }

    static func tryParse(_ json: String) -> LiveProtocol.Event {
        try! LiveProtocol.parse(Data(json.utf8))
    }
}
