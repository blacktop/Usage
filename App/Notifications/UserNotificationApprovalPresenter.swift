import Foundation
import UsageKit
import UserNotifications
import os

/// Shows banners even while the app is frontmost.
///
/// Without a delegate the notification center silently drops presentations from the active app —
/// and a menu bar app is active exactly when its popover is open, which is when a refresh is most
/// likely to hit the broken credential. Stateless, so one shared instance serves every alert.
private nonisolated final class ForegroundPresentationDelegate: NSObject,
    UNUserNotificationCenterDelegate, Sendable
{
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Delivers credential-approval alerts through the platform notification center.
///
/// Constructed only by `AppModel.live()`: `UNUserNotificationCenter.current()` requires a real
/// bundle identity, which a test process does not have, so tests inject their own presenter and
/// the notification center is never touched off the shipped path.
///
/// The refresh pipeline awaits `present`, so it must never park a wave behind user interaction:
/// when authorization is still undetermined, the system permission dialog and the delivery it
/// gates run in their own task and the pipeline moves on.
///
/// `nonisolated` opts out of the target's MainActor default: the notifier calling in is an actor
/// and everything here talks to the notification center, so nothing needs the main thread.
nonisolated struct UserNotificationApprovalPresenter: CredentialApprovalPresenter {
    private static let logger = Logger(subsystem: "io.blacktop.Usage", category: "notifications")
    private static let foregroundPresentation = ForegroundPresentationDelegate()

    func present(_ alert: CredentialApprovalAlert) async {
        let center = UNUserNotificationCenter.current()
        center.delegate = Self.foregroundPresentation
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            Task { await Self.requestAuthorizationThenPost(alert) }
        case .denied:
            Self.logger.info("credential-approval alert suppressed: authorization denied")
        default:
            await Self.post(alert, to: center)
        }
    }

    func withdraw(for accountKey: AccountKey) async {
        let center = UNUserNotificationCenter.current()
        let identifier = Self.identifier(for: accountKey)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private static func requestAuthorizationThenPost(_ alert: CredentialApprovalAlert) async {
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                logger.info("credential-approval alert suppressed: authorization denied")
                return
            }
        } catch {
            logger.error(
                "notification authorization failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        await post(alert, to: center)
    }

    private static func post(
        _ alert: CredentialApprovalAlert,
        to center: UNUserNotificationCenter
    ) async {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.accountName) needs approval"
        content.body =
            "Its credential was rotated and can no longer be read in the background. "
            + "Open Usage in the menu bar and click Approve."
        content.sound = .default
        do {
            // A stable identifier per account replaces any alert still sitting in Notification
            // Center instead of stacking a second copy for the same broken credential.
            try await center.add(
                UNNotificationRequest(
                    identifier: identifier(for: alert.accountKey),
                    content: content,
                    trigger: nil
                )
            )
        } catch {
            logger.error(
                "credential-approval alert failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func identifier(for accountKey: AccountKey) -> String {
        "credential-approval:\(accountKey.accountID.rawValue)"
    }
}
