import XCTest
import HunchCore
@testable import HunchText

final class URLGuardTests: XCTestCase {
    private func run(_ before: String, _ raw: String, allowsURLs: Bool = false) -> PostOutcome {
        DefaultPostProcessor().process(raw, meanLogProb: nil,
            context: PostContext(before: before, after: "", requiredPrefix: "", allowNewlines: false,
                                 maxWords: 20, allowsURLs: allowsURLs))
    }

    func testURLShapes() {
        for url in ["https://example.com", "http://x.io/a", "www.google.com", "google.com/search?q=a+b",
                    "google.com", "mail.google.com", "(github.com/owner/repo).", "localhost.dev:8080",
                    "example.tw/路徑", "news.ycombinator.com?", "WWW.EXAMPLE.ORG"] {
            XCTAssertTrue(URLShape.isURL(url), url)
        }
        for word in ["Node.js", "e.g.", "i.e.", "U.S.", "a.m.", "hello", "3.14", "file.txt", "v1.2.3",
                     "vince@example.com", "and/or", "Mr.", "你好.com"] {
            XCTAssertFalse(URLShape.isURL(word), word)
        }
    }

    func testRemovingURLs() {
        XCTAssertEqual(URLShape.removingURLs("see https://a.com/x for details"), "see for details")
        XCTAssertEqual(URLShape.removingURLs("nothing  to   remove"), "nothing  to   remove")
        XCTAssertEqual(URLShape.removingURLs("google.com/search?q=Alex+Morgan"), "")
    }

    /// The reported bug: "goo" in a chat box got a full Google search address.
    func testCompletingTypedWordIntoAddressIsSuppressed() {
        XCTAssertEqual(run("goo", "gle.com/search?q=Alex+Morgan&oq=Alex+Morgan&aqs=chrome..69"),
                       .suppress(.webAddress))
        XCTAssertEqual(run("Check out ", "https://example.com"), .suppress(.webAddress))
        XCTAssertEqual(run("Check out www", ".example.com today"), .suppress(.webAddress))
    }

    func testAddressLaterInCompletionCutsBeforeIt() {
        XCTAssertEqual(run("I found it on ", "the wiki at wiki.example.com/page"), .show("the wiki at"))
        XCTAssertEqual(run("Read ", "(https://example.com) later"), .suppress(.webAddress))
    }

    func testOrdinaryTextIsUntouched() {
        XCTAssertEqual(run("goo", "d morning, Alex."), .show("d morning, Alex."))
        XCTAssertEqual(run("I wrote it in Node", ".js last year."), .show(".js last year."))
        XCTAssertEqual(run("We met at 3 p", ".m. on Friday."), .show(".m. on Friday."))
    }

    func testSearchFieldsKeepAddresses() {
        XCTAssertEqual(run("goo", "gle.com", allowsURLs: true), .show("gle.com"))
        XCTAssertTrue(PostContext.allowsURLs(on: .search))
        XCTAssertTrue(PostContext.allowsURLs(on: .code))   // fetch("https://...") in an editor
        XCTAssertFalse(PostContext.allowsURLs(on: .chat))
    }

    func testTraditionalChineseUntouched() {
        XCTAssertEqual(run("我們明天", "在台北見面。"), .show("在台北見面。"))
    }
}

final class ShellPostProcessingTests: XCTestCase {
    private func run(_ before: String, _ raw: String) -> PostOutcome {
        DefaultPostProcessor().process(raw, meanLogProb: nil,
            context: PostContext(before: before, after: "", requiredPrefix: "", allowNewlines: false,
                                 maxWords: 6, allowsURLs: true, surface: .shell))
    }

    func testFirstLineOnlyAndNoProseRules() {
        XCTAssertEqual(run("me@mac ~ % git st", "atus --short\nOn branch main"), .show("atus --short"))
        // Command words are not typos, quotes stay straight, URLs stay.
        XCTAssertEqual(run("me@mac ~ % ", "grpe -rn 'x' . && curl -O https://example.com/a.zip"),
                       .show("grpe -rn 'x' . && curl -O https://example.com/a.zip"))
        XCTAssertEqual(run("me@mac ~ % ls ", " -la"), .show("-la"))
    }

    func testEmptyOrEndedLineIsSuppressed() {
        XCTAssertEqual(run("me@mac ~ % make", "\nmake: Nothing to be done"), .suppress(.empty))
        XCTAssertEqual(run("me@mac ~ % make", "   "), .suppress(.empty))
    }

    func testAllowsURLsInShell() {
        XCTAssertTrue(PostContext.allowsURLs(on: .shell))
    }
}
