import Foundation
import Vision

/// On-device OCR for copied images, so text inside screenshots is searchable.
nonisolated enum TextRecognizer {
  static func recognizeText(in imageData: Data) async -> String? {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    do {
      let observations = try await request.perform(on: imageData)
      let lines = observations.compactMap { $0.topCandidates(1).first?.string }
      return lines.isEmpty ? nil : lines.joined(separator: "\n")
    } catch {
      Log.capture.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }
}
