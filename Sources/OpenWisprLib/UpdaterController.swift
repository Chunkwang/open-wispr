import Foundation
import Sparkle

/// Wraps Sparkle's standard updater. NOT wired into AppDelegate yet —
/// deliberately, because it can't do anything useful until two things exist:
///   1. A Developer ID-signed, notarized build (ad-hoc signing in
///      scripts/bundle-app.sh won't pass Sparkle's own update verification).
///   2. A hosted appcast.xml (SUFeedURL) and an EdDSA keypair generated via
///      Sparkle's `generate_keys` tool (SUPublicEDKey in Info.plist).
/// Once both exist, call `UpdaterController.shared.start()` from
/// AppDelegate.applicationDidFinishLaunching and add the Info.plist keys to
/// scripts/bundle-app.sh's generated plist.
public final class UpdaterController {
    public static let shared = UpdaterController()

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private init() {}

    public func start() {
        controller.startUpdater()
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
