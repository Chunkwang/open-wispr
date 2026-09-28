import XCTest
@testable import OpenWisprLib

/// Source scanners for the sign-in rules (docs/auth-design.md section 6): nothing
/// logs an email address, a code or a token, only Keychain.swift talks to the
/// Keychain, and the production token source is the session store.
final class SignInHygieneTests: XCTestCase {
    // MARK: - logging scanner

    /// Words that name something secret or personal. An identifier is split into
    /// camel-case words, so `accessToken` and `statusCode` both match.
    static let sensitiveWords: Set<String> = [
        "email", "code", "otp", "token", "tokens", "password", "secret", "session", "body", "bearer", "apikey",
    ]

    static let logCalls = ["print(", "debugPrint(", "NSLog(", "os_log(", "dump(", "fputs(", "Logger(", "logger.", "log.debug(", "log.info(", "log.error("]

    /// Lines (1-based, of the call's first line) of logging calls whose CODE part
    /// (arguments and string interpolations, but not literal string text) mentions
    /// a sensitive identifier.
    static func sensitiveLogCalls(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        var found: [Int] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), logCalls.contains(where: { lines[index].contains($0) }) else { index += 1; continue }
            // Gather the whole call: until parentheses balance (bounded).
            var text = ""
            var depth = 0
            var end = index
            outer: while end < min(lines.count, index + 40) {
                text += lines[end] + "\n"
                for char in lines[end] {
                    if char == "(" { depth += 1 }
                    if char == ")" { depth -= 1 }
                }
                if depth <= 0 { break outer }
                end += 1
            }
            if codeIdentifiers(in: text).contains(where: { words(of: $0).contains { sensitiveWords.contains($0) } }) {
                found.append(index + 1)
            }
            index = max(end, index) + 1
        }
        return found
    }

    /// Identifiers that appear as code: outside string literals, or inside `\( )`
    /// interpolations. Literal text such as "Usage: set-language <code>" is skipped.
    static func codeIdentifiers(in text: String) -> [String] {
        var code = ""
        var inString = false
        var interpolationDepth = 0
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if interpolationDepth > 0 {
                code.append(c)
                if c == "(" { interpolationDepth += 1 }
                if c == ")" { interpolationDepth -= 1 }
            } else if inString {
                if c == "\\", i + 1 < chars.count {
                    if chars[i + 1] == "(" { interpolationDepth = 1; code.append(" "); i += 1 } else { i += 1 }
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else {
                code.append(c)
            }
            i += 1
        }
        let regex = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")
        let range = NSRange(code.startIndex..., in: code)
        return regex.matches(in: code, range: range).compactMap { Range($0.range, in: code).map { String(code[$0]) } }
    }

    /// "accessToken" -> ["access", "token"]; "over_email" -> ["over", "email"].
    static func words(of identifier: String) -> [String] {
        var words: [String] = []
        var current = ""
        for char in identifier {
            if char == "_" {
                if !current.isEmpty { words.append(current.lowercased()); current = "" }
            } else if char.isUppercase, !current.isEmpty, !(current.last?.isUppercase ?? false) {
                words.append(current.lowercased()); current = String(char)
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    func testScannerFlagsLoggingOfSensitiveValues() {
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: #"print("signed in \(session.email)")"#), [1])
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: "print(accessToken)"), [1])
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: "NSLog(\"%@\", code)"), [1])
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: "let a = 1\nprint(\n  \"x\",\n  refreshToken\n)"), [2])
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: #"debugPrint(String(describing: request.httpBody))"#), [1])
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: #"print("failed \(String(data: body, encoding: .utf8)!)")"#), [1])
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: #"print("status \(http.statusCode)")"#), [1])
    }

    func testScannerAcceptsLiteralTextAndFixedCategories() {
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: #"print("Usage: open-wispr set-language <code>")"#), [])
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: #"print("auth: verify failed (code_rejected)")"#), [])
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: #"print("Error: \(error.localizedDescription)")"#), [])
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: "// print(token)"), [])
        XCTAssertEqual(SignInHygieneTests.sensitiveLogCalls(in: "let token = 1"), [])
    }

    func testCamelCaseWordSplitting() {
        XCTAssertEqual(SignInHygieneTests.words(of: "accessToken"), ["access", "token"])
        XCTAssertEqual(SignInHygieneTests.words(of: "statusCode"), ["status", "code"])
        XCTAssertEqual(SignInHygieneTests.words(of: "over_email_send"), ["over", "email", "send"])
        XCTAssertEqual(SignInHygieneTests.words(of: "msg"), ["msg"])
    }

    private func sourceFiles() throws -> [(name: String, text: String)] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            files.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8)))
        }
        XCTAssertTrue(files.count > 10, "expected to scan the Sources tree, scanned \(files.count) files")
        return files
    }

    func testNoSourceFileLogsAnEmailACodeOrAToken() throws {
        var offenders: [String] = []
        for (name, text) in try sourceFiles() {
            for line in SignInHygieneTests.sensitiveLogCalls(in: text) { offenders.append("\(name):\(line)") }
        }
        XCTAssertEqual(offenders, [])
    }

    // MARK: - where the Keychain and the session are touched

    func testOnlyKeychainSwiftCallsTheSecItemAPI() throws {
        var offenders: [String] = []
        for (name, text) in try sourceFiles() where name != "Keychain.swift" {
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains("SecItem") {
                offenders.append("\(name):\(index + 1)")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testTheOldPasteATokenShortcutIsGone() throws {
        for (name, text) in try sourceFiles() {
            for phrase in ["dev session token", "authAccount", "Keychain.set(", "Keychain.get("] {
                XCTAssertFalse(text.contains(phrase), "\(name) still mentions \(phrase)")
            }
        }
    }

    func testTheProductionTokenSourcesReadTheSessionStore() throws {
        let files = try sourceFiles()
        let coordinator = try XCTUnwrap(files.first { $0.name == "RewriteCoordinator.swift" }).text
        XCTAssertTrue(coordinator.contains("hasToken: @escaping () -> Bool = { SessionStore().isSignedIn }"))
        let pipeline = try XCTUnwrap(files.first { $0.name == "RewritePipeline.swift" }).text
        XCTAssertTrue(pipeline.contains("store.load()"))
        let statusBar = try XCTUnwrap(files.first { $0.name == "StatusBarController.swift" }).text
        XCTAssertTrue(statusBar.contains("hasToken: SessionStore().isSignedIn"))
    }

    /// Every `URLQueryItem` in `AuthService.swift` must be one of these two fixed,
    /// non-secret literals: the sign-out scope and the refresh grant type (Task
    /// 3.5). Never an email, a code or a token: those travel only in a POST body
    /// or a bearer header, never a query string.
    func testAuthServiceOnlyPutsFixedNonSecretValuesInAQuery() throws {
        let service = try XCTUnwrap(try sourceFiles().first { $0.name == "AuthService.swift" }).text
        XCTAssertEqual(service.components(separatedBy: "URLQueryItem(").count - 1, 2)
        XCTAssertTrue(service.contains(#"URLQueryItem(name: "scope", value: "local")"#))
        XCTAssertTrue(service.contains(#"URLQueryItem(name: "grant_type", value: "refresh_token")"#))
        XCTAssertFalse(service.contains("queryItems = ") && service.contains("email") && service.contains("URLQueryItem(name: \"email\""))
    }

    /// The overrides may only ever be honoured in DEBUG builds. Unit tests run as
    /// DEBUG, so the release behaviour is pinned by reading the source.
    func testAuthOverridesAreHonouredInDebugBuildsOnly() throws {
        let config = try XCTUnwrap(try sourceFiles().first { $0.name == "AuthConfig.swift" }).text
        let expected = "#if DEBUG\n        return true\n        #else\n        return false\n        #endif"
        XCTAssertTrue(config.contains(expected))
        XCTAssertFalse(config.contains("allowOverride: true"), "no call site may force overrides on")
    }

    // MARK: - the sign-in window files (Day 4, part 2)

    private static let windowFiles = [
        "SignInCopy.swift", "SignInModel.swift", "SignInFlow.swift", "SignInMenuState.swift",
        "SignInPalette.swift", "SignInMainMenu.swift", "SignInWindow.swift",
    ]

    private func signInSources() throws -> [(name: String, text: String)] {
        let all = try sourceFiles()
        return try SignInHygieneTests.windowFiles.map { name in
            (name, try XCTUnwrap(all.first { $0.name == name }, "\(name) missing").text)
        }
    }

    /// Stricter than the scanner above: nothing in these files logs anything. They
    /// hold the email address, the code and, briefly, a session.
    func testTheSignInFilesDoNotLogAtAll() throws {
        for (name, text) in try signInSources() {
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for call in SignInHygieneTests.logCalls {
                    XCTAssertFalse(line.contains(call), "\(name):\(index + 1) calls \(call)")
                }
            }
        }
    }

    /// The logic (model, flow, copy) has no UI imports, so it runs in a test with
    /// no window and no application.
    func testTheStateMachineAndItsHelpersImportNoUI() throws {
        for (name, text) in try signInSources()
        where ["SignInCopy.swift", "SignInModel.swift", "SignInFlow.swift", "SignInMenuState.swift"].contains(name) {
            XCTAssertFalse(text.contains("import AppKit"), name)
            XCTAssertFalse(text.contains("import SwiftUI"), name)
        }
    }

    /// The entered email and code live in memory only: nothing here writes them to
    /// `UserDefaults`, the config file, a file, or the pasteboard (other than the
    /// one guarded clear).
    func testTheSignInFilesPersistNothing() throws {
        for (name, text) in try signInSources() {
            for phrase in ["UserDefaults", "Config.load", "Config.save", ".write(to", "FileManager", "setString(", "setData("] {
                XCTAssertFalse(text.contains(phrase), "\(name) uses \(phrase)")
            }
        }
        let window = try XCTUnwrap(try signInSources().first { $0.name == "SignInWindow.swift" }).text
        XCTAssertEqual(window.components(separatedBy: "clearContents()").count - 1, 1, "one pasteboard clear, behind the flow's guard")
    }

    func testTheWindowDoesNotChangeTheActivationPolicyOrHideOnDeactivate() throws {
        for (name, text) in try signInSources() {
            XCTAssertFalse(text.contains("setActivationPolicy"), name)
            XCTAssertFalse(text.contains("hidesOnDeactivate = true"), name)
        }
        let window = try XCTUnwrap(try signInSources().first { $0.name == "SignInWindow.swift" }).text
        XCTAssertTrue(window.contains("hidesOnDeactivate = false"))
        XCTAssertTrue(window.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertFalse(window.contains("window.appearance"), "the window follows the system appearance")
        XCTAssertFalse(window.contains(".appearance ="))
    }

    /// Every colour on the window comes from `SignInPalette`, so the contrast test
    /// covers every pair on screen.
    func testTheWindowReadsColoursOnlyFromThePalette() throws {
        let window = try XCTUnwrap(try signInSources().first { $0.name == "SignInWindow.swift" }).text
        for literal in ["Color(hex", "Color(red", "Color(white", "Color.white", "Color.black", "Color.red", "Color.green",
                        ".foregroundColor(.white", ".foregroundColor(.black", ".foregroundColor(.red", "BrandColor."] {
            XCTAssertFalse(window.contains(literal), "SignInWindow.swift uses \(literal)")
        }
    }

    /// Release builds have no sign-in menu items until Day 16: their text is inside
    /// `#if DEBUG` in the copy file, and every use in the status bar is too.
    func testTheMenuTitlesAreDebugOnly() throws {
        func insideDebug(_ source: String, containing needle: String) -> (inside: Int, outside: Int) {
            var depth = 0
            var debugDepths: [Int] = []
            var inside = 0, outside = 0
            for line in source.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if") {
                    depth += 1
                    if trimmed == "#if DEBUG" { debugDepths.append(depth) }
                } else if trimmed.hasPrefix("#endif") {
                    if debugDepths.last == depth { debugDepths.removeLast() }
                    depth -= 1
                } else if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") {
                    continue
                } else if line.contains(needle) {
                    if debugDepths.isEmpty { outside += 1 } else { inside += 1 }
                }
            }
            return (inside, outside)
        }
        let files = try sourceFiles()
        let copy = try XCTUnwrap(files.first { $0.name == "SignInCopy.swift" }).text
        for title in ["\"Sign in\u{2026}\"", "\"Sign out\"", "\"Sign-in status unavailable\"", "func menuSignedInAs"] {
            let result = insideDebug(copy, containing: title)
            XCTAssertGreaterThan(result.inside + result.outside, 0, "\(title) is missing from SignInCopy.swift")
        }
        let statusBar = try XCTUnwrap(files.first { $0.name == "StatusBarController.swift" }).text
        for use in ["SignInCopy.menu", "SignInWindowController", "SignOutFeedback", "SignInMenuState"] {
            let result = insideDebug(statusBar, containing: use)
            XCTAssertGreaterThan(result.inside + result.outside, 0, use)
        }
    }
}
