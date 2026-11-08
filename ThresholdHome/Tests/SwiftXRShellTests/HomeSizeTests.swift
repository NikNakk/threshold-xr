import Testing
@testable import SwiftXRShell

@Suite("Home panel size")
struct HomeSizeTests {
    @Test func widthSettingIsClampedToASensibleRange() {
        #expect(ShellSettings.clampedHomeWidth(nil) == 3.0)
        #expect(ShellSettings.clampedHomeWidth(3.4) == 3.4)
        #expect(ShellSettings.clampedHomeWidth(0.2) == 1.5)
        #expect(ShellSettings.clampedHomeWidth(12) == 5.0)
        #expect(ShellSettings.clampedHomeWidth(.nan) == 3.0)
    }
}
