import Testing
@testable import HunchModels

@Suite struct ModelLoadCoordinatorStateTests {
    @Test func currentLoadCommits() {
        var s = ModelLoadCoordinatorState(availableRoot: "/m")
        let t = s.beginLoad()
        #expect(s.isCurrent(t))
        #expect(s.finishLoad(t, failure: nil) == .commit)
    }

    @Test func currentFailureIsReported() {
        var s = ModelLoadCoordinatorState(availableRoot: "/m")
        let t = s.beginLoad()
        #expect(s.finishLoad(t, failure: "boom") == .reportFailure("boom"))
    }

    @Test func unloadDuringLoadDiscards() {
        var s = ModelLoadCoordinatorState(availableRoot: "/m")
        let t = s.beginLoad()
        s.noteUnload()
        #expect(s.finishLoad(t, failure: nil) == .discard)
    }

    @Test func folderLossDuringLoadDiscardsEvenOnFailure() {
        // The unload that follows a missing folder can make the runtime report a failure; that
        // must not overwrite the "folder missing" status.
        var s = ModelLoadCoordinatorState(availableRoot: "/m")
        let t = s.beginLoad()
        s.folderChanged(availableRoot: nil)
        #expect(!s.isLatest(t))
        #expect(s.finishLoad(t, failure: "aborted") == .discard)
        #expect(s.finishLoad(t, failure: nil) == .discard)
    }

    @Test func folderComingBackDoesNotReviveStaleLoad() {
        var s = ModelLoadCoordinatorState(availableRoot: "/m")
        let t = s.beginLoad()
        s.folderChanged(availableRoot: nil)
        s.folderChanged(availableRoot: "/m")
        #expect(s.finishLoad(t, failure: nil) == .discard)
        let t2 = s.beginLoad()
        #expect(s.finishLoad(t2, failure: nil) == .commit)
    }

    @Test func rootSwitchStalesButSameRootRefreshDoesNot() {
        var s = ModelLoadCoordinatorState(availableRoot: "/a")
        let t = s.beginLoad()
        s.folderChanged(availableRoot: "/a")
        #expect(s.finishLoad(t, failure: nil) == .commit)
        s.folderChanged(availableRoot: "/b")
        #expect(s.finishLoad(t, failure: nil) == .discard)
    }

    @Test func newerLoadSupersedesOlder() {
        var s = ModelLoadCoordinatorState(availableRoot: "/m")
        let old = s.beginLoad()
        let new = s.beginLoad()
        #expect(s.finishLoad(old, failure: nil) == .discard)
        #expect(s.finishLoad(new, failure: nil) == .commit)
    }

    @Test func noFolderNeverCommits() {
        var s = ModelLoadCoordinatorState()
        let t = s.beginLoad()
        #expect(!s.isCurrent(t))
        #expect(s.finishLoad(t, failure: nil) == .discard)
    }
}
