import Testing
@testable import HunchScreen

@Test func headerLinesEndInATime() {
    #expect(ChatHeader.isHeader("Nora 10:14 AM"))
    #expect(ChatHeader.isHeader("mika  Today at 8:12 PM"))
    #expect(ChatHeader.isHeader("Yesterday at 4:06 PM"))  // name OCR missed
    #expect(ChatHeader.isHeader("10:15 AM"))
    #expect(!ChatHeader.isHeader("see you at 10:30 AM"))
    #expect(!ChatHeader.isHeader("the stream starts at 8:00 PM"))
    #expect(!ChatHeader.isHeader("ok so 7 or 9?"))
    #expect(!ChatHeader.isHeader("hello there"))
}

@Test func headerNamesSkipDecorationAndBadges() {
    #expect(ChatHeader.name("Juniper.bun\u{1F36A} ") == "Juniper.bun")
    #expect(ChatHeader.name("Nora >w< * ") == "Nora")
    #expect(ChatHeader.name("Juniper Bun") == "Juniper Bun")
    #expect(ChatHeader.name("** TessTheTerrible") == "TessTheTerrible")
    #expect(ChatHeader.name("Mika 9") == "Mika")
    #expect(ChatHeader.name("ok >w< see you tomorrow") == nil)
}
