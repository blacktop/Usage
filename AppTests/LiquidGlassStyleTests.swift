import Foundation
import Testing

@testable import Usage

@Suite("Liquid glass style")
@MainActor
struct LiquidGlassStyleTests {
    @Test("Intensity is clamped to the unit interval")
    func clampsIntensity() {
        #expect(LiquidGlassStyle(intensity: -0.5).intensity == 0)
        #expect(LiquidGlassStyle(intensity: 1.5).intensity == 1)
        #expect(LiquidGlassStyle(intensity: 0.25).intensity == 0.25)
    }

    @Test("A non-finite stored value falls back to the default instead of reaching layout")
    func nonFiniteFallsBackToDefault() {
        #expect(
            LiquidGlassStyle(intensity: .nan).intensity == LiquidGlassStyle.defaultIntensity
        )
        #expect(
            LiquidGlassStyle(intensity: .infinity).intensity
                == LiquidGlassStyle.defaultIntensity
        )
    }

    @Test("Zero liquidity reproduces the flat legacy popover exactly")
    func zeroIsFlat() {
        let flat = LiquidGlassStyle(intensity: 0)
        #expect(!flat.usesGlassControls)
        #expect(!flat.usesGlassIslands)
        #expect(!flat.usesCustomWindowBackdrop)
        #expect(flat.backdropAlpha == 1)
        #expect(flat.cardCornerRadius == 11)
        #expect(flat.cardFillOpacity == 0.045)
    }

    @Test("The lower half of the slider only fades the backdrop, never adding glass islands")
    func lowerHalfFadesBackdropOnly() {
        let quarter = LiquidGlassStyle(intensity: 0.25)
        #expect(quarter.usesCustomWindowBackdrop)
        #expect(quarter.backdropAlpha == 0.5)
        #expect(!quarter.usesGlassIslands)
        #expect(quarter.usesGlassControls)
    }

    @Test("A control never renders glass inside glass chrome: island mode drops the glass button")
    func glassControlsYieldToGlassChrome() {
        #expect(LiquidGlassStyle(intensity: 0.4).usesGlassControls)
        #expect(!LiquidGlassStyle(intensity: 0.75).usesGlassControls)
        #expect(!LiquidGlassStyle(intensity: 1).usesGlassControls)
    }

    @Test("Glass islands begin only once the backdrop is fully clear")
    func islandsRequireClearBackdrop() {
        #expect(LiquidGlassStyle(intensity: 0.5).backdropAlpha == 0)
        #expect(!LiquidGlassStyle(intensity: 0.5).usesGlassIslands)
        let liquid = LiquidGlassStyle(intensity: 0.75)
        #expect(liquid.backdropAlpha == 0)
        #expect(liquid.usesGlassIslands)
    }
}
