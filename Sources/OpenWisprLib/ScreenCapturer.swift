import Foundation
import ScreenCaptureKit
import CoreGraphics

@available(macOS 14.0, *)
public final class ScreenCapturer {
    public enum CaptureError: Error, LocalizedError {
        case permissionDenied
        case noWindow
        case excludedWindow
        case captureFailed(Error?)

        public var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Screen recording permission is required to capture the screen."
            case .noWindow: return "No matching window found to capture."
            case .excludedWindow: return "This app's window is excluded from capture to protect your privacy."
            case .captureFailed(let e): return "Failed to capture screen: \(e?.localizedDescription ?? "Unknown error")"
            }
        }
    }

    /// One window's screenshot, with the frame that was actually captured so a
    /// caller can map coordinates back onto it (the Ask bounding-box overlay).
    public struct WindowCapture {
        public let image: CGImage
        /// `SCWindow.frame` for the captured window: Accessibility/Quartz
        /// screen coordinates (origin top-left of the primary display, Y
        /// increasing downward) — the same space `AXTreeWalker`'s frames use,
        /// and what was passed in as `windowFrame` to find this window, not
        /// necessarily identical to it (the window may have moved between the
        /// AX read and the capture; this is the frame the pixels actually
        /// match). Convert with `AXTreeWalker.axRectToScreenRect` before using
        /// it with AppKit/NSScreen coordinates.
        public let frame: CGRect
    }

    /// Captures a single screenshot of one window — the frontmost one the
    /// caller is asking about, identified by `pid` and (when available)
    /// `windowFrame` — using ScreenCaptureKit, instead of the whole display.
    /// Scoping to one window is itself the privacy boundary: `SCContentFilter
    /// (desktopIndependentWindow:)` only ever rasterizes that window's own
    /// pixels, so no other app's or window's content can appear in the image,
    /// with no `excludingApplications` list needed to blank anything out.
    ///
    /// `windowFrame` (in the same coordinate space `SCWindow.frame` uses —
    /// see `AXTreeWalker.frontmostWindowFrame`) disambiguates when `pid` owns
    /// more than one on-screen window; without a frame match, or when
    /// `windowFrame` is `nil`, the frontmost on-screen window for `pid` is
    /// used (`SCShareableContent.windows` is already front-to-back ordered).
    ///
    /// Defense in depth: if the matched window's own app turns out to be on
    /// the exclusion list (it should already have been refused upstream, by
    /// `AskCoordinator`'s own check, before this is ever called), this throws
    /// rather than capturing it — the same protection the old full-display
    /// capture's `excludingApplications` gave other apps, now applied to the
    /// one window being captured.
    public static func captureFrontmostWindow(pid: Int32, windowFrame: CGRect? = nil) async throws -> WindowCapture {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.current

        guard let window = Self.matchingWindow(in: content.windows, pid: pid, targetFrame: windowFrame) else {
            throw CaptureError.noWindow
        }

        if let bundleID = window.owningApplication?.bundleIdentifier, !bundleID.isEmpty,
           DefaultExcludedApps.matches(bundleID) {
            throw CaptureError.excludedWindow
        }
        if let appName = window.owningApplication?.applicationName,
           DefaultExcludedApps.matchesByName(appName) {
            throw CaptureError.excludedWindow
        }

        let config = SCStreamConfiguration()
        config.width = max(Int(window.frame.width), 1)
        config.height = max(Int(window.frame.height), 1)
        config.showsCursor = false

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config
            )
            return WindowCapture(image: cgImage, frame: window.frame)
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }

    /// Picks the window `frontmostWindowFrame` was looking at out of
    /// `SCShareableContent`'s list: windows this `pid` owns and that are
    /// currently on screen, preferring one whose frame matches `targetFrame`
    /// (within a small tolerance, since a resize or move between the AX read
    /// and this lookup is possible) and otherwise falling back to the
    /// frontmost normal-layer window for that pid — `windows` is documented as
    /// front-to-back ordered, so the first such match is the topmost one.
    static func matchingWindow(in windows: [SCWindow], pid: Int32, targetFrame: CGRect?) -> SCWindow? {
        let candidates = windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen }
        guard !candidates.isEmpty else { return nil }

        if let targetFrame {
            let tolerance: CGFloat = 2
            if let exact = candidates.first(where: { $0.frame.isApproximatelyEqual(to: targetFrame, tolerance: tolerance) }) {
                return exact
            }
        }

        return candidates.first(where: { $0.windowLayer == 0 }) ?? candidates.first
    }
}

private extension CGRect {
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) < tolerance
            && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance
            && abs(height - other.height) < tolerance
    }
}
