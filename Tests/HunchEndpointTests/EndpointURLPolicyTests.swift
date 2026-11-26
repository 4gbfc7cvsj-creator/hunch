import Foundation
import Testing
@testable import HunchEndpoint

@Suite struct EndpointURLPolicyTests {
    private func check(_ s: String, allow: Bool = false) -> EndpointError? {
        do { try EndpointURLPolicy.validate(URL(string: s)!, allowNonLoopback: allow); return nil }
        catch { return error as? EndpointError }
    }

    @Test func loopbackAccepted() {
        for s in ["http://localhost:11434/v1", "http://127.0.0.1:11434", "http://127.5.6.7/v1", "http://[::1]:8080/v1",
                  "https://localhost/v1", "http://LOCALHOST:1"] {
            #expect(check(s) == nil, "\(s)")
        }
    }

    @Test func remoteAlwaysRejectedEvenWhenAllowed() {
        for s in ["http://10.0.0.5:11434", "https://192.168.1.2", "https://api.example.com/v1",
                  "http://api.example.com"] {
            #expect(check(s) == .nonLoopbackNotAllowed, "\(s)")
            #expect(check(s, allow: true) == .nonLoopbackNotAllowed, "\(s)")
        }
    }

    @Test func lookalikesRejected() {
        for s in ["http://127.0.0.1.evil.com", "http://localhost.evil.com", "http://128.0.0.1", "http://1270.0.0.1",
                  "http://x.localhost", "http://localhost.", "http://127.1", "http://[::ffff:127.0.0.1]",
                  "http://[::2]", "http://0.0.0.0"] {
            #expect(check(s, allow: true) == .nonLoopbackNotAllowed, "\(s)")
        }
        #expect(EndpointURLPolicy.isLoopbackHost("::ffff:127.0.0.1") == false)
        #expect(EndpointURLPolicy.isLoopbackHost("x.localhost") == false)
        #expect(EndpointURLPolicy.isLoopbackHost("[::1]"))
        #expect(EndpointURLPolicy.isLoopbackHost("0:0:0:0:0:0:0:1"))
    }

    @Test func badSchemesAndHosts() {
        #expect(check("ftp://localhost") == .unsupportedScheme)
        #expect(check("file:///tmp/x") == .invalidURL)
    }
}
