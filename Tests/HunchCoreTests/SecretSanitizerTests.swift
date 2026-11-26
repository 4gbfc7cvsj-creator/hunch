import Testing
@testable import HunchCore

/// Synthetic fixtures only: each matches a pattern's shape and is assembled from pieces, so no
/// literal in this file is a usable (or scanner-tripping) credential.
enum SecretFixtures {
    static let aws = "AKIA" + "FAKEFAKEFAKEFAKE"
    static let stripe = "sk_" + "test_" + "FAKEfake0000FAKEfake"
    static let openAI = "sk-" + "proj-FAKEfake0000FAKEfake0000"
    static let github = "ghp_" + String(repeating: "FaKe", count: 9)
    static let githubPAT = "github_pat_" + "FAKE0000fake_FAKE0000fake"
    static let google = "AIza" + String(repeating: "FaKe", count: 8) + "x_y"
    static let slack = "xoxb-" + "0000-0000-FAKEfakeFAKE"
    static let jwt = "eyJ" + "hbGciOiJub25lIn0" + ".eyJ" + "zdWIiOiJmYWtlIn0" + ".ZmFrZXNpZw"
    static let pem = "-----BEGIN " + "RSA PRIVATE KEY-----\nFAKEFAKEFAKE\nfakefakefake\n-----END RSA PRIVATE KEY-----"
    static let iban = "DE00" + " 1234 5678 9012 3456 78"
    static let ibanCompact = "GB00" + "FAKE12345678901234"

    /// Bare tokens, one per key family: each must vanish completely.
    static let tokens = [aws, stripe, openAI, github, githubPAT, google, slack, jwt, pem, iban, ibanCompact]
}

@Suite struct SecretSanitizerTests {
    @Test(arguments: SecretFixtures.tokens)
    func redactsEveryKeyFamily(_ secret: String) {
        let text = "Before \(secret) after."
        #expect(SecretSanitizer.containsSecret(text))
        #expect(SecretSanitizer.redact(text) == "Before [redacted] after.")
    }

    @Test func credentialsInURLKeepSchemeAndHost() {
        let out = SecretSanitizer.redact("Clone https://alice:" + "hunter2fake@git.example.com/repo.git now")
        #expect(out == "Clone https://[redacted]@git.example.com/repo.git now")
    }

    @Test func keyValuePairsKeepTheKey() {
        #expect(SecretSanitizer.redact("password: hunter2fake") == "password: [redacted]")
        #expect(SecretSanitizer.redact("my Passwort = Sommer2026 ok") == "my Passwort = [redacted] ok")
        #expect(SecretSanitizer.redact("Kennwort: geheim99") == "Kennwort: [redacted]")
        #expect(SecretSanitizer.redact(#"{"api_key": "fake-value-0000"}"#) == #"{"api_key": [redacted]"#)
        #expect(SecretSanitizer.redact("client_secret=fakeSecretValue&x=1") == "client_secret=[redacted]")
    }

    @Test func environmentAssignments() {
        let text = "export BUILD_FLAVOR=releasecandidate\nSERVICE_URL=fakehost.internal"
        #expect(SecretSanitizer.redact(text) == "export BUILD_FLAVOR=[redacted]\nSERVICE_URL=[redacted]")
        // On a code surface such lines are ordinary code.
        #expect(SecretSanitizer.redact(text, surface: .code) == text)
        #expect(!SecretSanitizer.containsSecret(text, surface: .code))
        // Short values are not secrets.
        #expect(SecretSanitizer.redact("DEBUG=1\nLEVEL=info") == "DEBUG=1\nLEVEL=info")
    }

    @Test func codeSurfaceStillRedactsKeys() {
        let line = "let key = \"\(SecretFixtures.openAI)\""
        #expect(SecretSanitizer.redact(line, surface: .code) == "let key = \"[redacted]\"")
    }

    @Test func signedURLSignatures() {
        let url = "https://bucket.example.com/f.png?X-Amz-Date=20260101&X-Amz-Signature=" + "fa4e0000fake&x=1"
        #expect(SecretSanitizer.redact(url)
                == "https://bucket.example.com/f.png?X-Amz-Date=20260101&X-Amz-Signature=[redacted]&x=1")
        #expect(SecretSanitizer.redact("https://cdn.example.com/a?sig=" + "FAKE0000")
                == "https://cdn.example.com/a?sig=[redacted]")
    }

    @Test func unterminatedPrivateKeyIsRedactedToTheEnd() {
        let text = "Here:\n-----BEGIN " + "PRIVATE KEY-----\nFAKEFAKE\nfakefake"
        #expect(SecretSanitizer.redact(text) == "Here:\n[redacted]")
    }

    @Test(arguments: [
        "Thanks for the notes, I will send the secretary the tokens list by 10:30 tomorrow.",
        "The ratio is 3:4 and the score was 2-1 in overtime.",
        "See https://example.com/path?q=1&page=2#top and http://localhost:8080/docs for details.",
        "Use #FF5733 for the header and #00ff00 for links; rgb(12, 34, 56) for the border.",
        "Fixed in JIRA-1234 and PR #42, order AB12CD ships with SKU X-200.",
        "Email sam@example.com about the task-runner and the design sign-off.",
        "我们明天上午十点开会，请带上笔记。",
        "for (key, value) in pairs where value != nil { print(key) }",
    ])
    func ordinaryTextIsUnchanged(_ text: String) {
        #expect(SecretSanitizer.redact(text) == text)
        #expect(!SecretSanitizer.containsSecret(text))
    }

    @Test func surroundingTextIsPreserved() {
        let text = "Hi Sam,\nthe key is \(SecretFixtures.aws) and the token: \(SecretFixtures.slack)\nCheers"
        #expect(SecretSanitizer.redact(text) == "Hi Sam,\nthe key is [redacted] and the token: [redacted]\nCheers")
    }

    @Test func redactionIsIdempotent() {
        let text = "a \(SecretFixtures.github) b password=fakefake c\nAPI_TOKEN=\(SecretFixtures.stripe)"
        let once = SecretSanitizer.redact(text)
        #expect(SecretSanitizer.redact(once) == once)
        #expect(!once.contains(SecretFixtures.github) && !once.contains(SecretFixtures.stripe))
    }

    @Test func exactSuffixIsUntouched() {
        let tail = " the new key \(SecretFixtures.aws) here"
        let text = "Old key \(SecretFixtures.google), " + String(repeating: "filler words ", count: 30) + tail
        let out = SecretSanitizer.redact(text, keepingLast: tail.count)
        #expect(out.hasSuffix(tail))
        #expect(!out.contains(SecretFixtures.google))
        // Shorter than the kept suffix: returned as is.
        #expect(SecretSanitizer.redact(tail, keepingLast: 200) == tail)
    }

    @Test func matchReachingIntoTheSuffixIsRedactedUpToIt() {
        let secret = SecretFixtures.openAI
        let text = "Note " + secret + " end"
        let keep = 10   // the last 6 characters of the key plus " end"
        let out = SecretSanitizer.redact(text, keepingLast: keep)
        #expect(out == "Note [redacted]" + String(text.suffix(keep)))
    }
}

@Suite struct OnlyRedactedTests {
    @Test func secretOnlyTextIsOnlyRedacted() {
        #expect(SecretSanitizer.isOnlyRedacted(SecretSanitizer.redact(SecretFixtures.pem)))
        #expect(SecretSanitizer.isOnlyRedacted(SecretSanitizer.redact("  \(SecretFixtures.jwt)\n\(SecretFixtures.aws) ")))
    }

    @Test func anythingElseIsKept() {
        #expect(!SecretSanitizer.isOnlyRedacted(""))
        #expect(!SecretSanitizer.isOnlyRedacted("   \n"))
        #expect(!SecretSanitizer.isOnlyRedacted("Plain copied text."))
        #expect(!SecretSanitizer.isOnlyRedacted(SecretSanitizer.redact("Key: \(SecretFixtures.aws)")))
    }
}
