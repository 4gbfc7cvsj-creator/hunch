import Testing
@testable import HunchPolicy

@Suite struct TraditionalMarkerTests {
    @Test func traditionalAndSimplifiedPasswordLabelsBothMatch() {
        for label in ["請輸入密碼", "请输入密码", "驗證碼", "验证码", "動態碼"] {
            #expect(SensitiveMarkers.matches(label), "\(label)")
        }
        #expect(!SensitiveMarkers.matches("今天天氣很好"))
    }
}
