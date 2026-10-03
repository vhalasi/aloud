import Foundation

@main
struct SceneReviewChecks {
    static func main() {
        var cadence = SceneReviewCadence()
        func ready(_ now: Double, frame: Double? = nil, greeting: Bool = true,
                   model: Bool = false, playback: Bool = false, queue: Int = 0) -> Bool {
            cadence.beginIfReady(now: now, frameTime: frame ?? now, greetingComplete: greeting,
                                 modelBusy: model, playbackBusy: playback, queuedMessages: queue)
        }
        assert(!ready(1, greeting: false))
        assert(!ready(2, frame: 0)) // Never review an old frame.
        assert(!ready(3, model: true))
        assert(!ready(3, playback: true)) // Server completion precedes speaker completion.
        assert(!ready(3, queue: 5))
        assert(ready(3))
        assert(!ready(100)) // A slow/silent turn must not cause piled-up prompts.
        cadence.turnFinished(now: 100)
        assert(!ready(100.5))
        cadence.noteInput(now: 101)
        assert(!ready(102))
        assert(ready(102.3))
        cadence.turnFinished(now: 102.5)
        assert(!ready(104)) // Enforce three-second cadence even after a fast response.
        assert(ready(105.4))
        cadence.turnFinished(now: 106)
        let speech = Data(repeating: 0x20, count: 2048)
        cadence.observeAudio(speech, now: 109)
        assert(!ready(109.5)) // Defer before delayed server transcription arrives.
        cadence.observeAudio(Data(repeating: 0, count: 2048), now: 110)
        assert(ready(110.3))
        cadence = SceneReviewCadence() // New sessions do not inherit pending reviews.
        cadence.noteInput(now: 1, quietPeriod: 3)
        assert(!ready(3))
        assert(ready(4)) // A late transcript does not permanently latch the turn busy.
        cadence = SceneReviewCadence()
        assert(ready(1))
        let review = LiveProtocol.sceneReview()
        assert(review["clientContent"] == nil)
        assert((review["realtimeInput"] as? [String: String])?["text"]?.hasPrefix("SCENE_REVIEW:") == true)
        let call = LiveProtocol.ToolCall(id: "scene-1", name: "scene_review_complete", arguments: [:])
        let reply = LiveProtocol.toolResponse(call, result: ["acknowledged": true], scheduling: "SILENT")
        let response = ((reply["toolResponse"] as! [String: Any])["functionResponses"] as! [[String: Any]])[0]
        assert(response["scheduling"] as? String == "SILENT")
        assert((response["response"] as! [String: Any])["scheduling"] == nil)
        print("Scene review checks passed: fresh frames, one in flight, speech/playback deferral, cadence and silent acknowledgement.")
    }
}
