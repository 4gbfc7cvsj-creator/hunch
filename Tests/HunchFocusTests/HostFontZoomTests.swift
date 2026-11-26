import CoreGraphics
import Testing
@testable import HunchFocus

@Suite struct HostFontZoomTests {
    // Menlo 11 has a cell of about 6.62 points.
    let menlo11 = HostFontConfigs.Candidate(name: "Menlo-Regular", size: 11, advance: 6.62)

    @Test func keepsProfileSizeWhenCellMatches() {
        #expect(HostFontConfigs.pointSize(of: menlo11, cellWidth: 6.62) == 11)
        #expect(HostFontConfigs.pointSize(of: menlo11, cellWidth: 6.9) == 11)
        #expect(HostFontConfigs.pointSize(of: menlo11, cellWidth: nil) == 11)
        #expect(HostFontConfigs.pointSize(of: menlo11, cellWidth: 0) == 11)
    }

    @Test func followsZoomedWindow() {
        // ⌘+ twice: Menlo 13 / 14 cells.
        #expect(HostFontConfigs.pointSize(of: menlo11, cellWidth: 7.82) == 13)
        #expect(HostFontConfigs.pointSize(of: menlo11, cellWidth: 8.43) == 14)
        // ⌘−: Menlo 9.
        #expect(HostFontConfigs.pointSize(of: menlo11, cellWidth: 5.42) == 9)
    }

    @Test func zoomedCellStillPicksClosestProfile() {
        let pro = HostFontConfigs.Candidate(name: "SFMono-Regular", size: 12, advance: 7.22)
        let chosen = HostFontConfigs.pick([menlo11, pro], cellWidth: 9.6)
        #expect(chosen == pro)
        #expect(HostFontConfigs.pointSize(of: chosen, cellWidth: 9.6) == 16)
    }
}
