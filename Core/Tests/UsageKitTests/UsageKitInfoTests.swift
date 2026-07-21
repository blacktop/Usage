import Testing

@testable import UsageKit

@Test("User-Agent embeds the package version in the documented Usage/<version> shape")
func userAgentMatchesVersion() {
    #expect(UsageKitInfo.userAgent == "Usage/\(UsageKitInfo.version)")
    #expect(UsageKitInfo.userAgent.hasPrefix("Usage/"))
}

@Test("Version is a three-component numeric identifier")
func versionIsSemanticTriple() {
    let components = UsageKitInfo.version.split(separator: ".", omittingEmptySubsequences: false)
    #expect(components.count == 3)
    #expect(components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
}
