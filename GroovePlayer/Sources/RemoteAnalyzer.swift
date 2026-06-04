// Remote full-song analysis client: uploads an audio file to the Spark groove
// service (POST /analyze) and decodes the {stt, report} envelope into a Groove
// + SongReport. The Spark runs Demucs source separation (which the device can't
// do), so dense mixes analyze far better than the on-device path.
//
// The decode reuses MGMIO.decodeSTT, so the SAME validation the app applies to
// any .stt file guards the remote payload. One extra guard runs first:
// subdivision must be a multiple of the time-signature denominator, because a
// bad value would hit a precondition in MGMKit (slicesPerBeat) rather than a
// catchable error.
import Foundation
import MGMKit

enum RemoteAnalyzerError: LocalizedError {
    case badServerURL(String)
    case http(Int, String)
    case notJSON
    case llmEndpoint
    case missingSTT
    case badSubdivision(subdivision: Int, denominator: Int)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .badServerURL(let s): return "invalid server URL: \(s)"
        case .http(let code, let body):
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(code)" + (t.isEmpty ? "" : ": \(t.prefix(200))")
        case .notJSON: return "response was not JSON"
        case .llmEndpoint: return "that URL is the gpt-oss/vLLM API, not the groove service (use :8001)"
        case .missingSTT: return "response had no \"stt\" object"
        case .badSubdivision(let s, let d): return "subdivision \(s) is not a multiple of \(d)"
        case .decodeFailed(let m): return "could not decode .stt: \(m)"
        }
    }
}

struct RemoteResult {
    let groove: Groove
    let report: SongReport
    let engine: String
}

enum RemoteAnalyzer {

    /// POST `audio` to `{serverURL}/analyze` and decode the result. Throws a
    /// RemoteAnalyzerError on any transport/shape/validation problem so the
    /// caller can fall back to on-device analysis.
    static func analyze(audio data: Data, filename: String, serverURL: String,
                        token: String? = nil, timeout: TimeInterval = 180) async throws -> RemoteResult {
        var base = serverURL.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/analyze"), url.scheme != nil, url.host != nil else {
            throw RemoteAnalyzerError.badServerURL(serverURL)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType(for: filename))\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body

        let (respData, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw RemoteAnalyzerError.http(code, String(data: respData, encoding: .utf8) ?? "")
        }
        guard let top = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] else {
            throw RemoteAnalyzerError.notJSON
        }
        if top["choices"] != nil || (top["object"] as? String) == "chat.completion" {
            throw RemoteAnalyzerError.llmEndpoint
        }
        guard let stt = top["stt"] as? [String: Any] else { throw RemoteAnalyzerError.missingSTT }

        // crash-guard before handing to MGMKit (slicesPerBeat preconditions on this)
        if let sub = (stt["subdivision"] as? NSNumber)?.intValue,
           let ts = stt["timeSignature"] as? String,
           let denStr = ts.split(separator: "/").last, let den = Int(denStr), den != 0,
           sub % den != 0 {
            throw RemoteAnalyzerError.badSubdivision(subdivision: sub, denominator: den)
        }

        let groove: Groove
        do {
            let sttData = try JSONSerialization.data(withJSONObject: stt)
            groove = try MGMIO.decodeSTT(sttData)
        } catch {
            throw RemoteAnalyzerError.decodeFailed(String(describing: error))
        }

        let rep = top["report"] as? [String: Any] ?? [:]
        func num(_ key: String, _ fallback: Double = 0) -> Double {
            (rep[key] as? NSNumber)?.doubleValue ?? fallback
        }
        let report = SongReport(tempoBPM: num("tempoBpm"),
                                swingRatio: num("swingRatio", 0.5),
                                confidence: num("confidence"),
                                beatsDetected: Int(num("beatsDetected")),
                                onsetsUsed: Int(num("onsetsUsed")))
        let engine = (rep["engine"] as? String) ?? "remote"
        return RemoteResult(groove: groove, report: report, engine: engine)
    }

    /// Short human-readable form of an analysis error (for the status line).
    static func describe(_ error: Error) -> String {
        (error as? RemoteAnalyzerError)?.errorDescription ?? error.localizedDescription
    }

    private static func mimeType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "flac": return "audio/flac"
        case "aif", "aiff": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
