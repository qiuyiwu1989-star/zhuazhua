import Foundation
import Vision

// Serial background worker keeps image recognition off the UI thread.
actor CaptureOCR {
    static let shared = CaptureOCR()
    func recognize(file: String) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(url: URL(fileURLWithPath: file), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

extension CaptureRecord {
    func matchesSearch(_ query: String) -> Bool {
        let text = [name, note, tags, ocrText ?? ""].joined(separator: " ")
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
    }
    func searchExcerpt(_ query: String) -> String? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return ocrText?.components(separatedBy: .newlines).first { line in terms.contains { line.localizedCaseInsensitiveContains($0) } }
    }
}
