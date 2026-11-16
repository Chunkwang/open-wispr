import AppKit
import Combine
import SwiftUI

// The sign-in window (docs/design/sign-in.md). Everything with logic lives in
// `SignInModel` and `SignInFlow`; this file only draws the model and forwards
// what the user does to it. None of it has been seen on screen yet.

// MARK: - Fields

enum SignInFieldKind {
    case email
    case code
}

/// Finds the two text fields so the flow's focus requests can reach them. A
/// request for a field that does not exist yet (the code field, right after the
/// code was sent) waits and is applied when the field is put into the window.
@MainActor
final class SignInFieldRegistry {
    private weak var email: SignInNSTextField?
    private weak var code: SignInNSTextField?
    private var pending: (kind: SignInFieldKind, selectAll: Bool)?

    func register(_ field: SignInNSTextField, kind: SignInFieldKind) {
        switch kind {
        case .email: email = field
        case .code: code = field
        }
    }

    func request(_ kind: SignInFieldKind, selectAll: Bool) {
        pending = (kind, selectAll)
        applyPending()
    }

    func fieldDidAttach() { applyPending() }

    private func applyPending() {
        guard let request = pending else { return }
        let field = request.kind == .email ? email : code
        guard let field = field, let window = field.window else { return }
        pending = nil
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() else { return }
        if request.selectAll {
            editor.selectAll(nil)
        } else {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    func clearPending() { pending = nil }
}

/// A borderless, transparent text field: the window draws the rounded box around
/// it. It switches off every text service that could change or leak what is
/// typed (autocorrect, replacement, completion, data detectors).
final class SignInNSTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    var onAttach: (() -> Void)?
    /// Extra space between characters for the code field.
    var kern: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach?() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            configureEditor()
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    private func configureEditor() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.allowsUndo = true
        if kern != 0 { editor.typingAttributes[.kern] = kern }
    }
}

struct SignInTextField: NSViewRepresentable {
    let kind: SignInFieldKind
    let text: String
    let placeholder: String
    let isReadOnly: Bool
    let palette: SignInPalette
    let label: String
    let hint: String
    let registry: SignInFieldRegistry
    /// Gets every edit (typed or pasted) and returns the text the model now holds,
    /// so the field can show the filtered value at once.
    let onEdit: (String) -> String
    let onSubmit: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SignInNSTextField {
        let field = SignInNSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.alignment = kind == .code ? .center : .left
        field.kern = kind == .code ? 2 : 0
        field.onAttach = { [weak registry] in
            Task { @MainActor in registry?.fieldDidAttach() }
        }
        registry.register(field, kind: kind)
        return field
    }

    func updateNSView(_ field: SignInNSTextField, context: Context) {
        context.coordinator.parent = self
        field.onFocusChange = onFocusChange
        let font: NSFont = kind == .code
            ? NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .regular)
            : NSFont.systemFont(ofSize: 15, weight: .regular)
        field.font = font
        field.textColor = NSColor(palette.text)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor(palette.mutedText), .font: NSFont.systemFont(ofSize: 15, weight: .regular)]
        )
        // Read-only, not dimmed: the box keeps its look and the caret is hidden.
        field.isEditable = !isReadOnly
        field.isSelectable = true
        if field.stringValue != text { field.stringValue = text }
        field.setAccessibilityLabel(label)
        field.setAccessibilityHelp(hint)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SignInTextField
        init(_ parent: SignInTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let accepted = parent.onEdit(field.stringValue)
            if field.stringValue != accepted {
                field.stringValue = accepted
                field.currentEditor()?.selectedRange = NSRange(location: (accepted as NSString).length, length: 0)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                // Esc closes the window, whichever control has focus.
                control.window?.performClose(nil)
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Buttons

enum SignInButtonKind {
    case primary
    case secondary
}

/// The onboarding button look (plain, filled, corner radius 6, 13 pt medium) in
/// the states of section 2.1. Still a real `Button`, so it is focusable, has the
/// button role and answers to Space.
private struct SignInButtonStyle: ButtonStyle {
    let kind: SignInButtonKind
    let palette: SignInPalette

    func makeBody(configuration: Configuration) -> some View {
        SignInButtonBody(configuration: configuration, kind: kind, palette: palette)
    }
}

private struct SignInButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SignInButtonKind
    let palette: SignInPalette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    private var fill: Color {
        switch kind {
        case .primary:
            if !isEnabled { return palette.disabledFill }
            return configuration.isPressed ? palette.buttonFillPressed : palette.buttonFill
        case .secondary:
            return configuration.isPressed ? palette.fieldStroke.opacity(0.15) : Color.clear
        }
    }

    private var label: Color {
        switch kind {
        case .primary: return isEnabled ? palette.buttonLabel : palette.disabledLabel
        case .secondary: return isEnabled ? palette.text : palette.mutedText
        }
    }

    private var stroke: Color {
        kind == .secondary ? palette.fieldStroke.opacity(isEnabled ? 1 : 0.4) : Color.clear
    }

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(stroke, lineWidth: 1))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused && isEnabled ? palette.focusStroke : Color.clear, lineWidth: 2)
                    .padding(-4)
            )
            .contentShape(Rectangle())
    }
}

private struct SignInButton: View {
    let title: String
    let busyTitle: String
    let isBusy: Bool
    let isEnabled: Bool
    let kind: SignInButtonKind
    let hint: String
    let palette: SignInPalette
    let action: () -> Void

    var body: some View {
        Button(action: { if !isBusy { action() } }) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                        // The spinner on the emerald fill is white; on an outlined button it follows the appearance.
                        .environment(\.colorScheme, kind == .primary ? .dark : (palette.isDark ? .dark : .light))
                        .accessibilityHidden(true)
                }
                Text(isBusy ? busyTitle : title)
            }
        }
        .buttonStyle(SignInButtonStyle(kind: kind, palette: palette))
        // Busy is not disabled: the button keeps its colour and ignores clicks.
        .disabled(!isEnabled && !isBusy)
        .accessibilityLabel(Text(isBusy ? busyTitle : title))
        .accessibilityHint(Text(hint))
    }
}

// MARK: - View

struct SignInView: View {
    @ObservedObject var flow: SignInFlow
    let registry: SignInFieldRegistry
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fieldHasFocus = false

    private static let contentWidth: CGFloat = 340

    var body: some View {
        // Reading `tickCount` makes the once-a-second tick redraw the countdowns.
        let _ = flow.tickCount
        let palette = SignInPalette(colorScheme)
        let now = flow.now
        let model = flow.model

        ZStack(alignment: .top) {
            palette.background
            switch model.state {
            case .emailEntry, .sendingCode(.email):
                entryScreen(model: model, palette: palette, now: now, isCode: false)
            case .codeEntry, .sendingCode(.resend), .verifying:
                entryScreen(model: model, palette: palette, now: now, isCode: true)
            case .signedIn:
                signedInScreen(model: model, palette: palette)
            case .saveFailed, .saving:
                saveFailedScreen(model: model, palette: palette)
            case .closed:
                EmptyView()
            }
        }
        .frame(width: 420, height: 372)
    }

    // MARK: entry screens (email and code share one grid, so nothing moves)

    private func entryScreen(model: SignInModel, palette: SignInPalette, now: Date, isCode: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)
            Text(isCode ? SignInCopy.codePrompt : SignInCopy.emailPrompt)
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(palette.text)
                .multilineTextAlignment(.center)
                .frame(width: Self.contentWidth, height: 44, alignment: .top)
                .accessibilityAddTraits(.isHeader)
            Spacer().frame(height: 6)
            subLine(model: model, palette: palette, isCode: isCode)
                .frame(width: Self.contentWidth, height: 32, alignment: .top)
            Spacer().frame(height: 12)
            Text(isCode ? SignInCopy.codeFieldLabel : SignInCopy.emailFieldLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(palette.mutedText)
                .frame(width: Self.contentWidth, height: 16, alignment: .leading)
                .accessibilityHidden(true)
            Spacer().frame(height: 6)
            field(model: model, palette: palette, isCode: isCode)
            Spacer().frame(height: 8)
            statusRow(model: model, palette: palette, now: now)
            Spacer().frame(height: 16)
            primaryButton(model: model, palette: palette, now: now, isCode: isCode)
            Spacer().frame(height: 12)
            secondaryRow(model: model, palette: palette, now: now, isCode: isCode)
            Spacer().frame(height: 6)
            caption(model: model, palette: palette, now: now, isCode: isCode)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func subLine(model: SignInModel, palette: SignInPalette, isCode: Bool) -> some View {
        let text = isCode ? SignInCopy.codeSentTo(model.email) : SignInCopy.emailPrivacyNote
        Text(text)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(palette.mutedText)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.middle)
            // The full text, never truncated, for VoiceOver and the tooltip.
            .accessibilityLabel(Text(text))
            .help(text)
    }

    private func field(model: SignInModel, palette: SignInPalette, isCode: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return ZStack {
            shape.fill(palette.fieldFill)
            // The focused stroke is 2 pt in the same outer size, so nothing moves.
            shape.strokeBorder(fieldHasFocus ? palette.focusStroke : palette.fieldStroke, lineWidth: fieldHasFocus ? 2 : 1)
            SignInTextField(
                kind: isCode ? .code : .email,
                text: isCode ? model.digits : model.email,
                placeholder: isCode ? SignInCopy.codePlaceholder : SignInCopy.emailPlaceholder,
                isReadOnly: model.isBusy,
                palette: palette,
                label: isCode ? SignInCopy.codeFieldLabel : SignInCopy.emailFieldLabel,
                hint: isCode ? SignInCopy.voCodeFieldHint : SignInCopy.voEmailFieldHint,
                registry: registry,
                onEdit: { text in
                    flow.send(isCode ? .codeEdited(text) : .emailEdited(text))
                    return isCode ? flow.model.digits : flow.model.email
                },
                onSubmit: { flow.submitPrimary() },
                onFocusChange: { focused in fieldHasFocus = focused }
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
        }
        .frame(width: Self.contentWidth, height: 44)
    }

    @ViewBuilder
    private func statusRow(model: SignInModel, palette: SignInPalette, now: Date) -> some View {
        let status = model.statusRow(now: now)
        let text = status.map { SignInCopy.text(for: $0, now: now) }
        ZStack(alignment: .topLeading) {
            if let status = status, let text = text {
                let isNote = status.isCooldownNote
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isNote ? "clock" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isNote ? palette.mutedText : palette.errorText)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(isNote ? palette.mutedText : palette.errorText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(isNote ? SignInCopy.voStatusPrefix : SignInCopy.voErrorPrefix): \(text)"))
                .transition(.opacity)
            }
        }
        .frame(width: Self.contentWidth, height: 36, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: text)
    }

    @ViewBuilder
    private func primaryButton(model: SignInModel, palette: SignInPalette, now: Date, isCode: Bool) -> some View {
        Group {
            if !isCode {
                SignInButton(
                    title: SignInCopy.sendCodeButton, busyTitle: SignInCopy.sendingCode,
                    isBusy: model.state == .sendingCode(.email), isEnabled: model.canSendCode(now: now),
                    kind: .primary, hint: SignInCopy.voSendCodeHint, palette: palette,
                    action: { flow.send(.submitEmail) }
                )
            } else if model.isCodeExpired(now: now) {
                // The only useful action is a new code, so it is the primary one.
                SignInButton(
                    title: SignInCopy.resendCodeButton, busyTitle: SignInCopy.sendingCode,
                    isBusy: model.state == .sendingCode(.resend), isEnabled: model.canResend(now: now),
                    kind: .primary, hint: SignInCopy.voResendHint, palette: palette,
                    action: { flow.send(.resendTapped) }
                )
            } else {
                SignInButton(
                    title: SignInCopy.signInButton, busyTitle: SignInCopy.verifyingCode,
                    isBusy: model.state == .verifying, isEnabled: model.canSubmitCode(now: now),
                    kind: .primary, hint: SignInCopy.voSignInHint, palette: palette,
                    action: { flow.send(.submitCode) }
                )
            }
        }
        .frame(width: Self.contentWidth, height: 36)
    }

    @ViewBuilder
    private func secondaryRow(model: SignInModel, palette: SignInPalette, now: Date, isCode: Bool) -> some View {
        Group {
            if !isCode {
                if model.canOfferHaveCode(now: now) {
                    SignInButton(
                        title: SignInCopy.haveCodeButton, busyTitle: SignInCopy.haveCodeButton,
                        isBusy: false, isEnabled: true, kind: .secondary,
                        hint: SignInCopy.voHaveCodeHint, palette: palette,
                        action: { flow.send(.haveCodeTapped) }
                    )
                    .frame(width: Self.contentWidth, height: 28)
                } else {
                    Color.clear.frame(width: Self.contentWidth, height: 28)
                }
            } else {
                HStack(spacing: 12) {
                    if model.isCodeExpired(now: now) {
                        Color.clear.frame(width: 164, height: 28)
                    } else {
                        SignInButton(
                            title: SignInCopy.resendCodeButton, busyTitle: SignInCopy.sendingCode,
                            isBusy: model.state == .sendingCode(.resend), isEnabled: model.canResend(now: now),
                            kind: .secondary, hint: SignInCopy.voResendHint, palette: palette,
                            action: { flow.send(.resendTapped) }
                        )
                        .frame(width: 164, height: 28)
                    }
                    SignInButton(
                        title: SignInCopy.changeEmailButton, busyTitle: SignInCopy.changeEmailButton,
                        isBusy: false, isEnabled: model.canChangeEmail, kind: .secondary,
                        hint: SignInCopy.voChangeEmailHint, palette: palette,
                        action: { flow.send(.changeEmailTapped) }
                    )
                    .frame(width: 164, height: 28)
                }
            }
        }
    }

    @ViewBuilder
    private func caption(model: SignInModel, palette: SignInPalette, now: Date, isCode: Bool) -> some View {
        Group {
            if isCode, let until = model.captionCooldownUntil(now: now) {
                let text = SignInCopy.text(for: .resendCooldown(until: until), now: now)
                HStack(spacing: 6) {
                    Image(systemName: "clock").accessibilityHidden(true)
                    Text(text)
                }
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(palette.mutedText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(text))
            } else {
                Color.clear
            }
        }
        .frame(width: Self.contentWidth, height: 16)
    }

    // MARK: signed in and save-failed screens

    private func signedInScreen(model: SignInModel, palette: SignInPalette) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(palette.successGlyph)
                .accessibilityHidden(true)
            Spacer().frame(height: 16)
            Text(SignInCopy.signedIn)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(palette.text)
                .accessibilityAddTraits(.isHeader)
            Spacer().frame(height: 6)
            Text(SignInCopy.signedInAs(model.signedInEmail))
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(palette.mutedText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: Self.contentWidth, height: 36, alignment: .top)
                .help(SignInCopy.signedInAs(model.signedInEmail))
            Spacer().frame(height: 60)
            SignInButton(
                title: SignInCopy.doneButton, busyTitle: SignInCopy.doneButton,
                isBusy: false, isEnabled: true, kind: .primary,
                hint: SignInCopy.voDoneHint, palette: palette,
                action: { flow.send(.closeRequested) }
            )
            .frame(width: Self.contentWidth, height: 36)
            Spacer(minLength: 0)
        }
    }

    private func saveFailedScreen(model: SignInModel, palette: SignInPalette) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(palette.errorText)
                .accessibilityHidden(true)
            Spacer().frame(height: 20)
            // Body text in the normal colour: the icon and the words carry the meaning.
            Text(SignInCopy.storageFailed)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(palette.text)
                .multilineTextAlignment(.center)
                .frame(width: Self.contentWidth, height: 60, alignment: .top)
            Spacer().frame(height: 76)
            SignInButton(
                title: SignInCopy.retrySaveButton, busyTitle: SignInCopy.savingSession,
                isBusy: model.state == .saving, isEnabled: true, kind: .primary,
                hint: SignInCopy.voRetrySaveHint, palette: palette,
                action: { flow.send(.retrySaveTapped) }
            )
            .frame(width: Self.contentWidth, height: 36)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Window

/// Esc closes the window whichever control has focus, and Return, when no text
/// field took it, presses the primary button (the window's default button).
final class SignInWindow: NSWindow {
    var onReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }

    override func keyDown(with event: NSEvent) {
        // Return (main and keypad). Only these two key codes are looked at, and
        // nothing about the key is stored or logged.
        if event.keyCode == 36 || event.keyCode == 76, let onReturn = onReturn {
            onReturn()
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct SystemSignInPasteboard: SignInPasteboard {
    func currentString() -> String? { NSPasteboard.general.string(forType: .string) }
    func clear() { NSPasteboard.general.clearContents() }
}

/// Shows the sign-in window: one instance, raised by "Sign in…" when it is
/// already open. Main thread only.
@MainActor
final class SignInWindowController: NSObject, NSWindowDelegate {
    static let shared = SignInWindowController()

    /// Called when a session was saved, so the menu can rebuild. The status bar
    /// sets it.
    var sessionDidChange: () -> Void = {}

    private var window: SignInWindow?
    private var flow: SignInFlow?
    private var registry = SignInFieldRegistry()
    private var focusSink: AnyCancellable?
    private var timer: Timer?
    private var isClosing = false

    var isShowing: Bool { window != nil }

    func show() {
        // The main menu that makes Command-V, -A, -C and -W work in an accessory
        // app has to exist before the first window.
        SignInMainMenu.installIfNeeded()

        if let window = window {
            activate(window)
            return
        }

        let coordinator = (NSApp.delegate as? AppDelegate)?.authCoordinator ?? AuthCoordinator(didChangeSession: {})
        let registry = SignInFieldRegistry()
        self.registry = registry
        isClosing = false

        let flow = SignInFlow(
            auth: coordinator,
            pasteboard: SystemSignInPasteboard(),
            isDictationInsertInFlight: { (NSApp.delegate as? AppDelegate)?.isDictationInsertInFlight ?? false },
            announcer: { [weak self] text, priority in self?.announce(text, priority: priority) },
            stopTimers: { [weak self] in self?.stopTimer() },
            closeWindow: { [weak self] in self?.closeWindowFromModel() },
            sessionDidChange: { [weak self] in self?.sessionDidChange() }
        )
        self.flow = flow

        let hosting = NSHostingController(rootView: SignInView(flow: flow, registry: registry))
        let newWindow = SignInWindow(contentViewController: hosting)
        newWindow.title = SignInCopy.windowTitle
        newWindow.styleMask = [.titled, .closable]
        newWindow.setContentSize(NSSize(width: 420, height: 372))
        newWindow.isReleasedWhenClosed = false
        newWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        newWindow.hidesOnDeactivate = false
        newWindow.delegate = self
        newWindow.onReturn = { [weak flow] in flow?.submitPrimary() }
        newWindow.center()
        window = newWindow

        focusSink = flow.$focusRequest
            .compactMap { $0 }
            .sink { [weak self] request in
                // After the view has had its turn to build the new step.
                DispatchQueue.main.async { self?.apply(request.focus) }
            }

        startTimer()
        activate(newWindow)
        // Focus in the same turn as ordering the window front is lost.
        DispatchQueue.main.async { [weak self] in self?.registry.request(.email, selectAll: false) }
    }

    private func activate(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func apply(_ focus: SignInFocus) {
        switch focus {
        case .email(let selectAll): registry.request(.email, selectAll: selectAll)
        case .code(let selectAll): registry.request(.code, selectAll: selectAll)
        case .done, .retry:
            registry.clearPending()
            window?.makeFirstResponder(nil)
        }
    }

    // MARK: closing

    /// The model asked to close (Done, or any close it handled itself).
    private func closeWindowFromModel() {
        guard !isClosing else { return }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        // Esc, Cmd-W and the close button all arrive here. The model drops the
        // entered email and digits and, on the save-failure screen, ends the
        // unsaved server session.
        flow?.send(.closeRequested)
        stopTimer()
        focusSink = nil
        registry.clearPending()
        window?.delegate = nil
        window = nil
        flow = nil
    }

    // MARK: timer and announcements

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flow?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func announce(_ text: String, priority: SignInAnnouncementPriority) {
        SignInAnnouncer.post(text, priority: priority, element: window)
    }
}

/// Speaks a sentence through VoiceOver (a no-op for anyone not using it).
enum SignInAnnouncer {
    static func post(_ text: String, priority: SignInAnnouncementPriority, element: Any? = nil) {
        let level: NSAccessibilityPriorityLevel = priority == .high ? .high : .medium
        NSAccessibility.post(
            element: element ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: text,
                NSAccessibility.NotificationUserInfoKey.priority: level.rawValue,
            ]
        )
    }
}
