import SwiftUI

/// How strongly the popover leans into Liquid Glass, driven by the Settings "Liquidity" slider.
///
/// Glass must never stack on glass, and the `MenuBarExtra` window is itself a glass surface — so
/// the slider works in two zones. The lower half fades the window's own material backdrop until
/// the desktop shows through. Past the midpoint the backdrop is gone, which is exactly what makes
/// real `glassEffect` islands legitimate: they sample the desktop, not another glass surface.
/// Zero reproduces the flat legacy popover exactly.
struct LiquidGlassStyle: Equatable {
    static let storageKey = "glassLiquidity"
    static let defaultIntensity = 0.5

    let intensity: Double

    init(intensity: Double) {
        // A corrupt stored value must not push NaN into layout, so anything non-finite falls back
        // to the default rather than clamping (clamping NaN still yields NaN).
        guard intensity.isFinite else {
            self.intensity = Self.defaultIntensity
            return
        }
        self.intensity = min(max(intensity, 0), 1)
    }

    /// Controls (the refresh button) use the system glass button style only while they sit on
    /// the app's material backdrop. Once the surrounding chrome is itself glass (island mode),
    /// controls go borderless inside it — a glass button inside a glass capsule is exactly the
    /// glass-on-glass stacking this design exists to avoid.
    var usesGlassControls: Bool { intensity > 0 && !usesGlassIslands }

    /// Whether the window's stock backdrop is replaced with a fading custom one. False at Flat so
    /// the standard popover glass stays exactly as the system draws it.
    var usesCustomWindowBackdrop: Bool { intensity > 0 }

    /// Alpha of the popover window's material backdrop: fades out across the lower half of the
    /// slider so the desktop shows through.
    var backdropAlpha: Double { max(0, 1 - 2 * intensity) }

    /// Whether content islands render as real Liquid Glass. Only true once the backdrop is fully
    /// clear — glass sampling the desktop is correct; glass sampling glass is murk.
    var usesGlassIslands: Bool { intensity > 0.5 }

    /// Card corner radius grows with liquidity so higher settings read as droplets, not panels.
    var cardCornerRadius: CGFloat { 11 + 9 * intensity }

    /// The flat card fill, used until glass islands take over.
    var cardFillOpacity: Double { 0.045 - 0.03 * intensity }
}
