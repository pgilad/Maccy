import CoreGraphics
import Foundation
import UniformTypeIdentifiers
@testable import MaccyCore

func makeTemporaryDirectory() -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "MaccyCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func makeStore() throws -> HistoryStore {
  try HistoryStore(directory: makeTemporaryDirectory())
}

func textClip(_ text: String, app: String? = "Notes", bundleID: String? = "com.apple.Notes", at date: Date = .now) -> CapturedClip {
  CapturedClip(
    representations: [Representation(type: PasteboardTypes.string, data: Data(text.utf8))],
    sourceBundleID: bundleID,
    sourceAppName: app,
    capturedAt: date
  )
}

func analyzed(_ text: String, app: String? = "Notes", at date: Date = .now) -> AnalyzedClip {
  ClipAnalyzer.analyze(textClip(text, app: app, bundleID: app.map { "com.example.\($0.lowercased())" }, at: date))!
}

/// A solid-color image, encoded with ImageIO.
func makeImage(width: Int, height: Int, type: UTType = .png, red: CGFloat = 1) -> Data {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.setFillColor(CGColor(red: red, green: 0.5, blue: 0, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  return ImageProcessing.encode(context.makeImage()!, as: type)!
}

@discardableResult
func insert(_ store: HistoryStore, _ text: String, app: String? = "Notes", at date: Date = .now) async throws -> UpsertResult {
  try await store.upsert(analyzed(text, app: app, at: date), thumbnail: nil, expiresAt: nil)
}

/// Random pixels. PNG cannot compress them, so the file is large.
func makeNoiseImage(width: Int, height: Int) -> Data {
  var generator = SystemRandomNumberGenerator()
  var pixels = [UInt8](repeating: 255, count: width * height * 4)
  for index in pixels.indices where index % 4 != 3 {
    pixels[index] = UInt8.random(in: 0...255, using: &generator)
  }
  let provider = CGDataProvider(data: Data(pixels) as CFData)!
  let image = CGImage(
    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
  )!
  return ImageProcessing.encode(image, as: .png)!
}

/// Fake credentials for tests, built from parts so that no token-shaped literal
/// is in the repository. GitHub push protection and secret scanners flag those.
enum FakeSecrets {
  static let awsKey = "AKIA" + "IOSFODNN7" + "EXAMPLE"
  static let otherAWSKey = "AKIA" + "IOSFODNN7" + "EXAMPLF"
  static let githubToken = "gh" + "p_" + "abcdefghijklmnopqrstuvwxyz0123456789"
  static let githubPAT = "github" + "_pat_" + "11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWX"
  static let slackToken = "xo" + "xb-" + "123456789012-abcdefghij"
  static let stripeKey = "sk" + "_live_" + "abcdefghijklmnopqrstuvwx"
  static let googleKey = "AI" + "zaSyA-" + "abcdefghijklmnopqrstuvwxyz12345"
  static let jwt = "ey" + "JhbGciOiJIUzI1NiJ9." + "ey" + "JzdWIiOiIxMjM0NTY3ODkwIn0." + "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
  static let privateKey = "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nabc"
  static let gitlabToken = "gl" + "pat-" + "abcdefghijklmnopqrst"
}
