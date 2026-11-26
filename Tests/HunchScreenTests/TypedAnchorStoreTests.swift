import Foundation
import Testing
@testable import HunchScreen

private let chrome = TypedAnchorStore.Key(bundleID: "com.google.Chrome", height: 24)

@Test func typedAnchorStoreRoundTripsThroughFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-anchor-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("typed-anchors.json")
    let saved = TypedTextAnchor(startOffset: 0.5, baselineOffset: 6.8, pointSize: 14.5, rightLimitMargin: -2)
    TypedAnchorStore(fileURL: url).set(saved, for: chrome)

    let reloaded = TypedAnchorStore(fileURL: url)
    #expect(reloaded.anchors == [chrome: saved])
    // A relaunch's book places the caret from the saved anchor before any look.
    let book = TypedAnchorBook(anchors: reloaded.anchors)
    #expect(book.anchor(for: chrome) == saved)
    #expect(book.anchor(for: .init(bundleID: "com.google.Chrome", height: 30)) == nil)
}

@Test func typedAnchorStoreForgetsRemovedAnchors() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-anchor-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("typed-anchors.json")
    let store = TypedAnchorStore(fileURL: url)
    store.set(TypedTextAnchor(startOffset: 1, baselineOffset: 7, pointSize: 14), for: chrome)
    store.set(nil, for: chrome)
    #expect(store.anchors.isEmpty)
    #expect(TypedAnchorStore(fileURL: url).anchors.isEmpty)
}

@Test func typedAnchorStoreDropsDamagedEntries() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-anchor-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("typed-anchors.json")
    let store = TypedAnchorStore(fileURL: url)
    store.set(TypedTextAnchor(startOffset: 1, baselineOffset: 7, pointSize: 0), for: chrome)
    #expect(TypedAnchorStore(fileURL: url).anchors.isEmpty)
    try Data("not json".utf8).write(to: url)
    #expect(TypedAnchorStore(fileURL: url).anchors.isEmpty)
}

@Test func typedAnchorStoreKeepsNewestWithinCapacity() {
    let store = TypedAnchorStore(fileURL: nil)
    let base = Date(timeIntervalSince1970: 0)
    for i in 0...TypedAnchorStore.capacity {
        store.set(TypedTextAnchor(startOffset: CGFloat(i), baselineOffset: 7, pointSize: 14),
                  for: .init(bundleID: "app\(i)", height: 24), at: base + Double(i))
    }
    #expect(store.anchors.count == TypedAnchorStore.capacity)
    #expect(store.anchors[.init(bundleID: "app0", height: 24)] == nil)
}

@Test func seededBookStillForgetsAStaleAnchor() {
    var book = TypedAnchorBook(anchors: [chrome: TypedTextAnchor(startOffset: 1, baselineOffset: 7, pointSize: 14)])
    for _ in 1..<TypedAnchorBook<TypedAnchorStore.Key>.missesToForget {
        let forgot = book.noteMissed(for: chrome)
        #expect(!forgot)
    }
    let forgot = book.noteMissed(for: chrome)
    #expect(forgot)
    #expect(book.anchor(for: chrome) == nil)
}
