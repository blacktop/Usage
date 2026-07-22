import AppKit
import SwiftUI

/// Switches the `MenuBarExtra` window's stock glass to the clear style so the desktop shows
/// through, letting the SwiftUI content draw — and fade — its own backdrop.
///
/// The stock backdrop cannot be faded or removed from the view hierarchy: the window's
/// `NSGlassFrameView` draws nothing in process and composites everything through a companion
/// `_NSGlassTrackingWindow`. See `BackdropTuningView.apply()` for the one knob that works.
struct PopoverWindowBackdrop: NSViewRepresentable {
    let alpha: Double

    func makeNSView(context: Context) -> BackdropTuningView {
        BackdropTuningView()
    }

    func updateNSView(_ view: BackdropTuningView, context: Context) {
        view.backdropAlpha = alpha
    }
}

final class BackdropTuningView: NSView {
    var backdropAlpha: Double = 1 {
        didSet { apply() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private var originalStyle: NSGlassEffectView.Style?

    /// The stock backdrop is an `NSGlassEffectView` in a companion tracking window, reached via
    /// the frame's private `backingGlassView` accessor; the popover's content is composited
    /// *inside* it, so its alpha must never change (alpha zero blanks the whole popover). The
    /// public `style` property is the correct knob: `.clear` removes the blur entirely while the
    /// content keeps rendering, and the SwiftUI content's own fading material takes over as the
    /// backdrop. The private accessor is guarded by `responds(to:)` and fails soft to the stock
    /// look if it disappears in a future build.
    private func apply() {
        guard let window else { return }
        guard let glassView = Self.backingGlassView(of: window) as? NSGlassEffectView else {
            return
        }
        glassView.alphaValue = 1
        if originalStyle == nil {
            originalStyle = glassView.style
        }
        if backdropAlpha >= 1 {
            if let originalStyle {
                glassView.style = originalStyle
            }
        } else {
            glassView.style = .clear
        }
    }

    /// The frame's private glass backing view, or nil when the hierarchy no longer matches.
    private static func backingGlassView(of window: NSWindow) -> NSView? {
        guard var frameView = window.contentView else { return nil }
        while let superview = frameView.superview {
            frameView = superview
        }
        let accessor = NSSelectorFromString("backingGlassView")
        guard frameView.responds(to: accessor) else { return nil }
        return frameView.perform(accessor)?.takeUnretainedValue() as? NSView
    }
}
