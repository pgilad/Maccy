import Foundation
import Testing
@testable import MaccyCore

@Suite struct ReleaseTests {
  @Test(arguments: [("v3.0.2", [3, 0, 2]), ("3.0.2", [3, 0, 2]), ("3.1", [3, 1]), ("10", [10]), (" v1.2.3.4 ", [1, 2, 3, 4])])
  func versionParses(_ text: String, _ components: [Int]) throws {
    #expect(try #require(AppVersion(text)).components == components)
  }

  @Test(arguments: ["", "v", "3..1", "3.0.", ".3", "3.0.2-beta", "abc", "1.2.3.4.5", "３.0", "-1.0", "+1.0", "V3.0", "__VERSION__"])
  func versionRejects(_ text: String) {
    #expect(AppVersion(text) == nil)
  }

  @Test func versionCompares() throws {
    func version(_ text: String) throws -> AppVersion { try #require(AppVersion(text)) }
    #expect(try version("3.0.10") > version("3.0.9"))
    #expect(try version("3.1") > version("3.0.9"))
    #expect(try version("4") > version("3.9.9"))
    #expect(try version("3.0") == version("3.0.0"))
    #expect(try !(version("3.0.2") < version("v3.0.2")))
    #expect(try version("v3.0.2").description == "3.0.2")
  }

  @Test func releaseDecodesTheUsedFields() throws {
    let json = Data("""
      {"tag_name": "v3.0.2", "name": "Maccy 3.0.2", "draft": false, "prerelease": false,
       "html_url": "https://github.com/pgilad/Maccy/releases/tag/v3.0.2", "assets": []}
      """.utf8)
    let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
    #expect(release.version?.description == "3.0.2")
    #expect(release.pageURL?.absoluteString == "https://github.com/pgilad/Maccy/releases/tag/v3.0.2")
  }

  @Test(arguments: [
    "http://github.com/pgilad/Maccy/releases/tag/v3.0.2",
    "https://github.com.example.net/pgilad/Maccy",
    "https://example.net/github.com",
    "file:///Applications/Maccy.app",
    "not a url",
  ])
  func releasePageMustBeOnGitHub(_ url: String) {
    #expect(GitHubRelease(tagName: "v3.0.2", htmlURL: url).pageURL == nil)
  }
}
