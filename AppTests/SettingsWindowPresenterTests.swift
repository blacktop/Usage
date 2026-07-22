import Testing

@testable import Usage

@Suite("Settings window presentation")
struct SettingsWindowPresenterTests {
    @Test("the menu-bar app activates before requesting its Settings scene")
    func activatesBeforeOpening() {
        var events: [String] = []
        let presenter = SettingsWindowPresenter(
            activate: { events.append("activate") },
            open: { events.append("open") }
        )

        presenter.show()

        #expect(events == ["activate", "open"])
    }
}
