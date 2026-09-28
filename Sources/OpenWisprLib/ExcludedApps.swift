import Foundation

/// Apps whose windows the context reader never looks into, by bundle identifier:
/// password managers and the system credential apps, plus this app itself. The
/// reader does not make a single Accessibility call against an app on this list.
///
/// The identifiers are from memory of each vendor's published bundle ids and have
/// NOT been checked against installed copies (see docs/context-reader-notes.md).
/// A wrong or missing entry fails open for that one app, so the prefixes are kept
/// broad on purpose: an extra match only means less context, never more.
enum DefaultExcludedApps {
    /// Matched as the whole identifier, case-insensitively.
    static let exactIdentifiers: Set<String> = [
        // ── Password managers ──
        "com.1password.1password",          // 1Password 8
        "com.agilebits.onepassword7",       // 1Password 7
        "com.agilebits.onepassword-osx",    // 1Password 4 to 6
        "com.bitwarden.desktop",            // Bitwarden
        "com.dashlane.dashlanephonefinal",  // Dashlane
        "com.lastpass.lastpass",            // LastPass
        "in.sinew.enpass-desktop",          // Enpass
        "org.keepassxc.keepassxc",          // KeePassXC
        "com.apple.keychainaccess",         // Keychain Access
        "com.apple.passwords",              // Passwords (macOS 15+)

        // ── Banking & finance ──
        "com.chase.sig.mac",                // Chase
        "com.bankofamerica.bofa",           // Bank of America
        "com.wellsfargo.wf",                // Wells Fargo
        "com.citibank.citi",                // Citi
        "com.capitalone.enterprisedesktop", // Capital One
        "com.usaa.mobile",                  // USAA
        "com.schwab.schwabmobile",          // Charles Schwab
        "com.fidelity.fidelity",            // Fidelity
        "com.tdameritrade.ToS",             // TD Ameritrade / thinkorswim
        "com.interactivebrokers.tws",       // Interactive Brokers TWS
        "com.robinhood.Robinhood",          // Robinhood

        // ── Cryptocurrency wallets ──
        "com.coinbase.wallet",              // Coinbase Wallet
        "io.metamask.desktop",              // MetaMask
        "com.ledger.live",                  // Ledger Live
        "com.exodus.eden",                  // Exodus

        // ── System security & privacy ──
        "com.apple.systempreferences",      // System Preferences (pre-Ventura)
        "com.apple.systemsettings",         // System Settings (Ventura+)
        "com.apple.SecurityAgent",          // macOS auth dialogs
        "com.apple.keychaincircle",         // iCloud Keychain
        "com.apple.ScreenSharing",          // Screen Sharing (contains other people's data)

        // ── Healthcare ──
        "com.apple.Health",                 // Apple Health (if ever on Mac)
        "epic.MyChart.mac",                 // MyChart (Epic)

        // ── VPN & networking (credentials visible) ──
        "com.wireguard.macos",              // WireGuard
        "com.tailscale.ipn.macos",          // Tailscale
    ]

    /// An identifier equal to one of these, or starting with one plus ".",
    /// is excluded (covers helpers, mini windows and vendor variants).
    static let identifierPrefixes: [String] = [
        // Password managers
        "com.1password",
        "com.agilebits",
        "com.bitwarden",
        "com.dashlane",
        "com.lastpass",
        "in.sinew.enpass",
        "org.keepassxc",
        "com.keepassxc",
        "me.proton.pass",
        "com.nordsec.nordpass",
        "com.markmcguill.strongbox",
        "com.apple.keychainaccess",
        "com.apple.passwords",

        // Banking & finance (prefix catches sub-apps and helpers)
        "com.chase",
        "com.bankofamerica",
        "com.wellsfargo",
        "com.citibank",
        "com.capitalone",
        "com.usaa",
        "com.schwab",
        "com.fidelity",
        "com.tdameritrade",
        "com.robinhood",
        "com.interactivebrokers",
        "com.paypal",

        // Cryptocurrency
        "com.coinbase",
        "io.metamask",
        "com.ledger",
        "com.exodus",
        "com.trezor",

        // System security
        "com.apple.SecurityAgent",
        "com.apple.keychaincircle",

        // VPN
        "com.wireguard",
        "com.tailscale",
        "com.nordvpn",
        "com.privateinternetaccess",
        "com.expressvpn",
    ]

    /// App names that should be excluded even if we don't know their bundle ID,
    /// matched case-insensitively against the frontmost app's localized name.
    static let sensitiveAppNames: Set<String> = [
        "keychain access",
        "passwords",
        "security agent",
        "screen sharing",
    ]

    static func matches(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        if exactIdentifiers.contains(id) { return true }
        return identifierPrefixes.contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    /// Name-based fallback for apps whose bundle ID is unknown.
    static func matchesByName(_ appName: String) -> Bool {
        sensitiveAppNames.contains(appName.lowercased())
    }
}

/// The exclusion policy the reader applies: the built-in list, this app itself,
/// and a seam for the user's own list.
///
/// SEAM: a later task adds a config key (proposed name `contextExcludedApps`, an
/// optional array of bundle identifiers, absent in old configs) and passes its
/// value as `userIdentifiers`. That key is NOT added yet, so today the user list
/// is always empty. Add it as an optional field with a default and a test that an
/// old config still loads, as every other config field does.
struct ExcludedApps: Equatable, Sendable {
    let userIdentifiers: Set<String>
    let ownBundleIdentifier: String

    init(
        userIdentifiers: Set<String> = [],
        ownBundleIdentifier: String = ProductInfo.bundleIdentifier
    ) {
        self.userIdentifiers = Set(userIdentifiers.map { $0.lowercased() })
        self.ownBundleIdentifier = ownBundleIdentifier.lowercased()
    }

    /// nil when the app may be read. An empty identifier is not readable either:
    /// the caller treats a missing bundle id as "unidentified" before asking.
    func reason(forBundleID bundleID: String) -> ContextSnapshot.ExclusionReason? {
        let id = bundleID.lowercased()
        if id == ownBundleIdentifier { return .appItself }
        if DefaultExcludedApps.matches(id) { return .defaultList }
        if userIdentifiers.contains(id) { return .userList }
        return nil
    }
}
