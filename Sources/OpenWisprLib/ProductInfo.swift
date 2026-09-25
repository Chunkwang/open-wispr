/// The one place user-visible product identity lives, so a rename (decision D1)
/// is a change here plus the matching values in scripts/bundle-app.sh, which
/// ProductInfoTests checks for drift.
///
/// Deliberately not renamed here: the `open-wispr` CLI/binary name and the
/// `~/.config/open-wispr` config directory. Renaming either needs a migration
/// so existing configs keep loading; that belongs with the rename itself.
public enum ProductInfo {
    /// Shown in the menu bar menu title.
    public static let displayName = "Dictation (WIP)"
    /// The .app folder name, without the extension.
    public static let bundleName = "Dictation-WIP"
    /// CFBundleIdentifier. Changing it after users exist resets their granted
    /// permissions and Keychain access, so settle it before the first notarized build.
    public static let bundleIdentifier = "com.goprimy.dictation-wip"
    /// Oldest macOS the app supports (LSMinimumSystemVersion, Package.swift platform).
    public static let minimumMacOSVersion = "13.0"
}
