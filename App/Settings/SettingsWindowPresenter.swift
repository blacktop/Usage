/// Orders the two operations required to present Settings from a menu-bar-only app.
///
/// `openSettings` creates the scene, but an `LSUIElement` app is not activated when its menu bar
/// extra is clicked. Activating first makes the new window key and orders it above the application
/// the user was working in instead of underneath that application's windows.
struct SettingsWindowPresenter {
    let activate: () -> Void
    let open: () -> Void

    func show() {
        activate()
        open()
    }
}
