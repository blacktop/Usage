/// Build identity shared by the app, the CLI, and every outbound provider request.
public enum UsageKitInfo {
    public static let version = "0.1.0"

    /// Value sent as `User-Agent` on every provider request.
    public static var userAgent: String { "Usage/\(version)" }
}
