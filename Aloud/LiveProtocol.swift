import Foundation

/// The wire format is kept independent of AVFoundation for fixture checks.
enum LiveProtocol {
    static let model = "gemini-3.8-live"

    static func setup() -> [String: Any] {
        ["setup": [
            "model": "models/\(model)",
            "generationConfig": ["responseModalities": ["AUDIO"]],
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:],
            "contextWindowCompression": ["slidingWindow": [:]],
            "systemInstruction": ["parts": [["text": """
                You are Aloud, a calm visual companion for a blind person. Images come from the
                iPhone FRONT camera, pointed away from the user toward their surroundings.
                Describe only what is visible in the latest images. Speak concisely, usually
                one or two sentences. Answer spoken questions naturally. After an initial
                description, occasionally mention a significant visible change; avoid repetitive
                narration. Respect requests for quiet and let the user interrupt.
                If the view is obstructed, dark, blurry or stale, say so. Do not invent objects,
                read illegible text, estimate precise distances, or claim that a path is safe.
                Never tell the user it is safe to cross a street or move forward. This prototype
                provides descriptions, not mobility guidance. Local depth sensing independently
                controls vibration; you cannot feel or control those vibrations. Do not infer
                left/right from a mirrored selfie: frames are unmirrored camera views.
                """]]]
        ]]
    }

    static func media(_ data: Data, mimeType: String, kind: String) -> [String: Any] {
        ["realtimeInput": [kind: ["mimeType": mimeType, "data": data.base64EncodedString()]]]
    }

    static func describe() -> [String: Any] {
        ["clientContent": ["turns": [["role": "user", "parts": [["text":
            "Briefly describe what the front camera is pointing at now. If no usable image is available, say so."]]]], "turnComplete": true]]
    }

    struct Event {
        var ready = false
        var interrupted = false
        var turnComplete = false
        var audio: [Data] = []
        var inputText: String?
        var outputText: String?
        var errorCode: Int?
        var goingAway = false
    }

    static func parse(_ data: Data) throws -> Event {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var event = Event()
        event.ready = root["setupComplete"] != nil
        event.goingAway = root["goAway"] != nil
        if let error = root["error"] as? [String: Any] {
            event.errorCode = error["code"] as? Int ?? -1
        }
        guard let content = root["serverContent"] as? [String: Any] else { return event }
        event.interrupted = content["interrupted"] as? Bool ?? false
        event.turnComplete = content["turnComplete"] as? Bool ?? false
        event.inputText = (content["inputTranscription"] as? [String: Any])?["text"] as? String
        event.outputText = (content["outputTranscription"] as? [String: Any])?["text"] as? String
        let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        for part in parts {
            guard let inline = part["inlineData"] as? [String: Any],
                  let mime = inline["mimeType"] as? String, mime.hasPrefix("audio/pcm"),
                  let encoded = inline["data"] as? String,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { continue }
            event.audio.append(bytes)
        }
        return event
    }
}
