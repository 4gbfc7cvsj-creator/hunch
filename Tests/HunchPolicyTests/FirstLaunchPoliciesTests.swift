import Foundation
import Testing
@testable import HunchCore
@testable import HunchPolicy

/// A new install's per-app settings: only named, non-Private categories.
struct FirstLaunchPoliciesTests {
    @Test func seedDecodesAndStaysOutOfPrivate() {
        let p = FirstLaunchPolicies.patches
        #expect(p.count >= 10)
        for (key, patch) in p {
            switch key {
            case .category(let name):
                #expect(!AppCategories.same(name, CategoryNames.private))
            case .app, .domain:
                let category = AppCategories.clean(patch.appCategory)
                #expect(category != nil, "\(key) has no category")
                #expect(category.map { !AppCategories.same($0, CategoryNames.private) } ?? false)
            }
        }
        #expect(p[.app(bundleID: "com.hnc.Discord")]?.appearance?.animation == .decode)
        #expect(p[.app(bundleID: "com.liuliu.draw-things")]?.writeCustomShapeID == CustomWriteShape.aiImagePrompts.id)
    }

    @Test func aMissingFileStartsSeededAndAnExistingOneDoesNot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app-policies.json")

        let fresh = JSONPolicyStore(fileURL: url, freshPatches: FirstLaunchPolicies.patches,
                                    freshMigrations: FirstLaunchPolicies.migrations)
        #expect(fresh.userPatches == FirstLaunchPolicies.patches)
        #expect(fresh.hasRun(CategoryMigration.id))
        #expect(FileManager.default.fileExists(atPath: url.path))

        try fresh.setPatch(nil, for: .app(bundleID: "com.hnc.Discord"))
        let reopened = JSONPolicyStore(fileURL: url, freshPatches: FirstLaunchPolicies.patches)
        #expect(reopened.userPatches[.app(bundleID: "com.hnc.Discord")] == nil)
        #expect(reopened.userPatches.count == FirstLaunchPolicies.patches.count - 1)
    }
}
