import Foundation
import ScreenCaptureKit
import CoreGraphics

@available(macOS 14.0, *)
public final class ScreenCapturer {
    public enum CaptureError: Error, LocalizedError {
        case permissionDenied
        case noDisplays
        case captureFailed(Error?)
        
        public var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Screen recording permission is required to capture the screen."
            case .noDisplays: return "No displays found to capture."
            case .captureFailed(let e): return "Failed to capture screen: \(e?.localizedDescription ?? "Unknown error")"
            }
        }
    }

    /// Captures a single screenshot of the primary display using ScreenCaptureKit.
    /// Sensitive apps (password managers, banking, etc.) are automatically excluded
    /// from the capture at the ScreenCaptureKit level — their windows appear as
    /// blank regions in the resulting image.
    public static func captureMainDisplay() async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.noDisplays
        }

        // Filter out windows belonging to excluded apps so their pixels
        // never enter memory, even before the coordinator-level check.
        let excludedApps = content.applications.filter { app in
            let bundleID = app.bundleIdentifier
            if !bundleID.isEmpty {
                return DefaultExcludedApps.matches(bundleID)
            }
            return DefaultExcludedApps.matchesByName(app.applicationName)
        }

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        
        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: []),
                configuration: config
            )
            return cgImage
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }
}
