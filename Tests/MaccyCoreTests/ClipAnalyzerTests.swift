import Foundation
import Testing
@testable import MaccyCore

@Suite struct ClipAnalyzerTests {
  @Test func plainTextBecomesTextItem() throws {
    let clip = try #require(ClipAnalyzer.analyze(textClip("  hello\n\tworld  ")))
    #expect(clip.kind == .text)
    #expect(clip.title == "hello world")
    #expect(clip.text == "  hello\n\tworld  ")
    #expect(clip.hasRichText == false)
    #expect(clip.detectedSecret == nil)
  }

  @Test func whitespaceOnlyTextIsSkipped() {
    #expect(ClipAnalyzer.analyze(textClip(" \n\t ")) == nil)
    #expect(ClipAnalyzer.analyze(CapturedClip(representations: [])) == nil)
  }

  @Test(arguments: ["https://example.com/a?b=c", "www.apple.com", "mailto:me@example.com"])
  func singleLinkBecomesLinkItem(_ text: String) throws {
    let clip = try #require(ClipAnalyzer.analyze(textClip(text)))
    #expect(clip.kind == .link)
  }

  @Test(arguments: ["see https://example.com", "https://nodot", "example.com"])
  func textWithLinkStaysText(_ text: String) throws {
    let clip = try #require(ClipAnalyzer.analyze(textClip(text)))
    #expect(clip.kind == .text)
  }

  @Test(arguments: ["#ff9900", "#F90", "rgb(255, 153, 0)", "rgba(255 153 0 / 50%)"])
  func colorBecomesColorItem(_ text: String) throws {
    let clip = try #require(ClipAnalyzer.analyze(textClip(text)))
    #expect(clip.kind == .color)
  }

  @Test func colorParserNormalizesHex() throws {
    #expect(ParsedColor.parse("#f90")?.hex == "#FF9900")
    #expect(ParsedColor.parse("rgb(255, 153, 0)")?.hex == "#FF9900")
    #expect(ParsedColor.parse("#ff990080")?.hex == "#FF990080")
    #expect(ParsedColor.parse("#ggg") == nil)
    #expect(ParsedColor.parse("rgb(300, 0, 0)") == nil)
    #expect(ParsedColor.parse("rgbx(1, 2, 3)") == nil)
    #expect(ParsedColor.parse("rgba(1, 2, 3, 0.5)")?.alpha == 0.5)
  }

  @Test func htmlOnlyIsConvertedWithoutWebKit() throws {
    let html = "<html><head><style>p{}</style></head><body><p>Hello&nbsp;<b>bold</b> &amp; more</p><p>Line&#x32;</p></body></html>"
    let clip = try #require(ClipAnalyzer.analyze(CapturedClip(
      representations: [Representation(type: PasteboardTypes.html, data: Data(html.utf8))]
    )))
    #expect(clip.kind == .text)
    #expect(clip.hasRichText)
    #expect(clip.text == "Hello bold & more\nLine2")
  }

  @Test func rtfOnlyIsConverted() throws {
    let rtf = #"{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}\f0\pard Hello {\b RTF}\par}"#
    let clip = try #require(ClipAnalyzer.analyze(CapturedClip(
      representations: [Representation(type: PasteboardTypes.rtf, data: Data(rtf.utf8))]
    )))
    #expect(clip.kind == .text)
    #expect(clip.title == "Hello RTF")
  }

  @Test func imageKeepsOneRepresentationAndConvertsTIFF() throws {
    let tiff = makeImage(width: 40, height: 20, type: .tiff)
    let png = makeImage(width: 40, height: 20, type: .png)
    let clip = try #require(ClipAnalyzer.analyze(CapturedClip(representations: [
      Representation(type: PasteboardTypes.tiff, data: tiff),
      Representation(type: PasteboardTypes.png, data: png),
    ])))
    #expect(clip.kind == .image)
    #expect(clip.title == "Image (40×20)")
    #expect(clip.representations.map(\.type) == [PasteboardTypes.png])
    #expect(clip.primaryImage == png)

    let tiffOnly = try #require(ClipAnalyzer.analyze(CapturedClip(representations: [
      Representation(type: PasteboardTypes.tiff, data: tiff)
    ])))
    #expect(tiffOnly.representations.map(\.type) == [PasteboardTypes.png])
    #expect(tiffOnly.imageWidth == 40)
  }

  @Test func imageWithRealTextIsText() throws {
    let clip = try #require(ClipAnalyzer.analyze(CapturedClip(representations: [
      Representation(type: PasteboardTypes.string, data: Data("A paragraph with a picture".utf8)),
      Representation(type: PasteboardTypes.rtf, data: Data(#"{\rtf1 A paragraph}"#.utf8)),
      Representation(type: PasteboardTypes.png, data: makeImage(width: 4, height: 4)),
    ])))
    #expect(clip.kind == .text)
    #expect(clip.primaryImage == nil)
  }

  @Test func attachmentPlaceholderWithImageIsImage() throws {
    // Notes, Mail and chat apps put U+FFFC in the text for each attachment.
    let red = try #require(ClipAnalyzer.analyze(imageWithText("\u{FFFC}", red: 1)))
    let blue = try #require(ClipAnalyzer.analyze(imageWithText(" \u{FFFC}\n", red: 0)))
    #expect(red.kind == .image)
    #expect(red.title == "Image (8×8)")
    #expect(red.primaryImage != nil)
    #expect(red.contentHash != blue.contentHash)
  }

  @Test func textWithAttachmentPlaceholderHashesTheImage() throws {
    let red = try #require(ClipAnalyzer.analyze(imageWithText("See \u{FFFC}", red: 1)))
    let blue = try #require(ClipAnalyzer.analyze(imageWithText("See \u{FFFC}", red: 0)))
    #expect(red.kind == .text)
    #expect(red.contentHash != blue.contentHash)
    // Without the placeholder, the same text is the same item, whatever image comes with it.
    let plainRed = try #require(ClipAnalyzer.analyze(imageWithText("See this", red: 1)))
    let plainBlue = try #require(ClipAnalyzer.analyze(imageWithText("See this", red: 0)))
    #expect(plainRed.contentHash == plainBlue.contentHash)
  }

  private func imageWithText(_ text: String, red: CGFloat) -> CapturedClip {
    CapturedClip(representations: [
      Representation(type: PasteboardTypes.string, data: Data(text.utf8)),
      Representation(type: PasteboardTypes.png, data: makeImage(width: 8, height: 8, red: red)),
    ])
  }

  @Test func filesBecomeFileItem() throws {
    let urls = ["/Users/me/a report.pdf", "/Users/me/b.txt"].map { URL(filePath: $0) }
    let clip = try #require(ClipAnalyzer.analyze(CapturedClip(representations: urls.enumerated().map {
      Representation(itemIndex: $0.offset, type: PasteboardTypes.fileURL, data: $0.element.dataRepresentation)
    })))
    #expect(clip.kind == .file)
    #expect(clip.fileCount == 2)
    #expect(clip.title == "2 files: a report.pdf, b.txt")
    #expect(clip.text.contains("/Users/me/a report.pdf"))
  }

  @Test func sameTextHasSameHashAcrossFormats() throws {
    let plain = try #require(ClipAnalyzer.analyze(textClip("same")))
    let rich = try #require(ClipAnalyzer.analyze(CapturedClip(representations: [
      Representation(type: PasteboardTypes.string, data: Data("same".utf8)),
      Representation(type: PasteboardTypes.html, data: Data("<b>same</b>".utf8)),
    ])))
    #expect(plain.contentHash == rich.contentHash)
    #expect(plain.contentHash != ClipAnalyzer.analyze(textClip("other"))?.contentHash)
  }

  @Test func objectReplacementCharacterIsRemovedFromTitle() throws {
    let clip = try #require(ClipAnalyzer.analyze(textClip("Привет \u{FFFC}\u{FFFC} мир")))
    #expect(!clip.title.unicodeScalars.contains("\u{FFFC}"))
    #expect(clip.title == "Привет мир")
  }

  @Test func longTextIsCappedForIndex() throws {
    let text = String(repeating: "a", count: ClipAnalyzer.maxIndexedTextLength + 10)
    let clip = try #require(ClipAnalyzer.analyze(textClip(text)))
    #expect(clip.text.count == ClipAnalyzer.maxIndexedTextLength)
    #expect(clip.isTextTruncated)
    #expect(clip.title.count == 300)
  }

  @Test func universalClipboardShowsICloud() throws {
    var captured = textClip("from phone")
    captured.isUniversalClipboard = true
    #expect(ClipAnalyzer.analyze(captured)?.sourceAppName == "iCloud")
  }
}

@Suite struct SecretDetectorTests {
  @Test(arguments: [
    FakeSecrets.awsKey,
    "token: " + FakeSecrets.githubToken,
    FakeSecrets.githubPAT,
    FakeSecrets.slackToken,
    FakeSecrets.stripeKey,
    FakeSecrets.googleKey,
    FakeSecrets.jwt,
    FakeSecrets.privateKey,
    FakeSecrets.gitlabToken,
    FakeSecrets.gitlabTokenEndingInDash,
    FakeSecrets.googleKeyEndingInDash,
    FakeSecrets.openAIProjectKey,
    FakeSecrets.openAILegacyKey,
    FakeSecrets.anthropicKey,
    FakeSecrets.npmToken,
    FakeSecrets.slackAppToken,
    FakeSecrets.slackConfigToken,
    FakeSecrets.slackWebhook,
    FakeSecrets.azureConnectionString,
    FakeSecrets.pgpPrivateKey,
    FakeSecrets.encryptedPrivateKey,
    "key=" + FakeSecrets.googleKey + ";",
  ])
  func detectsSecrets(_ text: String) {
    #expect(SecretDetector.detect(in: text) != nil)
  }

  @Test(arguments: [
    "hello world",
    "AKIA is a prefix",
    "https://github.com/pgilad/Maccy",
    "sk-short",
    "git checkout sk-1234-add-retry-logic-to-payment-webhook",
    "sk-proj-cleanup",
    "-----BEGIN PUBLIC KEY-----",
    "-----BEGIN CERTIFICATE-----",
    "AIza is how Google keys start",
    "eyJhbGciOiJIUzI1NiJ9 alone is a header, not a token",
  ])
  func ignoresNormalText(_ text: String) {
    #expect(SecretDetector.detect(in: text) == nil)
  }

  @Test func anthropicKeyIsNotNamedOpenAI() {
    #expect(SecretDetector.detect(in: FakeSecrets.anthropicKey) == "Anthropic key")
    #expect(SecretDetector.detect(in: FakeSecrets.openAIProjectKey) == "OpenAI key")
  }

  @Test func secretDeepInLargeTextIsDetected() {
    let log = String(repeating: "INFO request served in 12 ms\n", count: 5_000)
    #expect(log.utf16.count > 100_000)
    #expect(SecretDetector.detect(in: log + FakeSecrets.privateKey) == "Private key")
  }

  @Test func secretsAreMarkedOnTextItems() throws {
    let clip = try #require(ClipAnalyzer.analyze(textClip(FakeSecrets.awsKey)))
    #expect(clip.detectedSecret == "AWS access key")
  }

  @Test func invalidIgnorePatternDoesNotStopOthers() {
    let patterns = IgnorePatterns(["([unclosed", "^secret"])
    #expect(patterns.invalidPatterns == ["([unclosed"])
    #expect(patterns.evaluate("secret value") == .match)
    #expect(patterns.evaluate("public value") == .noMatch)
  }

  @Test func slowIgnorePatternStopsAtTheTimeLimit() {
    // `.*password` with no match takes quadratic time: minutes on 200,000 characters.
    let patterns = IgnorePatterns([".*password"])
    let text = String(repeating: "a", count: 200_000)
    let start = ContinuousClock.now
    #expect(patterns.evaluate(text, timeLimit: .milliseconds(50)) == .timedOut)
    #expect(ContinuousClock.now - start < .seconds(2))
    #expect(patterns.evaluate("my password", timeLimit: .milliseconds(50)) == .match)
  }
}

@Suite struct TextUtilitiesTests {
  @Test func statistics() {
    let stats = TextUtilities.statistics(of: "one two\nthree")
    #expect(stats.characters == 13)
    #expect(stats.words == 3)
    #expect(stats.lines == 2)
  }

  @Test func entities() {
    #expect(TextUtilities.decodeEntities("a &lt;b&gt; &#65;&#x42; &unknown; &") == "a <b> AB &unknown; &")
  }

  @Test func titleNeverEndsWithASpace() {
    let text = String(repeating: "a", count: 299) + " b"
    let title = TextUtilities.title(from: text)
    #expect(title.count == 299)
    #expect(title.last == "a")
  }

  @Test func htmlElementsAreRemoved() {
    let html = "<SCRIPT type=x>alert(1)</script><styles>kept</styles> a  \n<b>b</b><style>p{}</style>"
    #expect(TextUtilities.plainText(fromHTML: html) == "kept a\nb")
    // An unclosed element keeps its text, as before.
    #expect(TextUtilities.plainText(fromHTML: "<script>never closed <p>text</p>") == "never closed text")
  }

  @Test func malformedHTMLTakesLinearTime() {
    // Each input took seconds (the spaces 30 s) with the old regular expressions.
    let inputs = [
      "<p>x</p>" + String(repeating: "a < b ", count: 10_000),
      "<p>x</p>" + String(repeating: " ", count: 60_000) + "y",
      String(repeating: "<script>", count: 10_000),
    ]
    let start = ContinuousClock.now
    for html in inputs {
      _ = TextUtilities.plainText(fromHTML: html)
    }
    #expect(ContinuousClock.now - start < .seconds(1))
    #expect(TextUtilities.plainText(fromHTML: inputs[0]).hasSuffix("a < b"))
  }
}
