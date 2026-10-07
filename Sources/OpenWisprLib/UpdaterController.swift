import Foundation
import Sparkle

/// Wraps Sparkle's standard updater. `AppDelegate.applicationDidFinishLaunching`
/// already calls `UpdaterController.shared.start()` at launch, but `start()`
/// is a no-op (see `isConfigured` below) until the rest of the update channel
/// exists:
///   1. A Developer ID-signed, notarized build (ad-hoc signing in
///      scripts/bundle-app.sh won't pass Sparkle's own update verification).
///   2. A hosted appcast.xml (SUFeedURL) and an EdDSA keypair generated via
///      Sparkle's `generate_keys` tool (SUPublicEDKey in Info.plist).
/// Once both exist, add the SUFeedURL/SUPublicEDKey Info.plist keys to
/// scripts/bundle-app.sh's generated plist; no further AppDelegate wiring is
/// needed.
public final class UpdaterController {
    public static let shared = UpdaterController()

    private var controller: SPUStandardUpdaterController?

    private init() {}

    private var isConfigured: Bool {
        guard let info = Bundle.main.infoDictionary,
              let feedURL = info["SUFeedURL"] as? String,
              !feedURL.isEmpty else {
            return false
        }
        return true
    }

    public func start() {
        guard isConfigured else { return }
        if controller == nil {
            controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
        controller?.startUpdater()
    }

    public func checkForUpdates() {
        guard isConfigured else { return }
        if controller == nil {
            controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
        controller?.checkForUpdates(nil)
    }
}
