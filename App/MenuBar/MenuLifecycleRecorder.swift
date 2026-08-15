import Observation
import os

/// Counts `MenuBarExtra` content appearance callbacks for the Phase 0 lifecycle spike.
///
/// Every transition is mirrored into the unified log under subsystem `io.blacktop.Usage`,
/// category `menu-lifecycle`, so an open/close session can be replayed with
/// `log show --predicate 'subsystem == "io.blacktop.Usage"'`.
@Observable
final class MenuLifecycleRecorder {
    private(set) var appearances = 0
    private(set) var disappearances = 0

    @ObservationIgnored
    private let logger = Logger(subsystem: "io.blacktop.Usage", category: "menu-lifecycle")

    var isBalanced: Bool { appearances == disappearances }

    func recordAppear() {
        appearances += 1
        logger.notice(
            """
            popover-appear appearances=\(self.appearances, privacy: .public) \
            disappearances=\(self.disappearances, privacy: .public)
            """
        )
    }

    func recordDisappear() {
        disappearances += 1
        logger.notice(
            """
            popover-disappear appearances=\(self.appearances, privacy: .public) \
            disappearances=\(self.disappearances, privacy: .public)
            """
        )
    }
}
