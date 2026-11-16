import Combine
import Foundation

/// What the sign-in flow needs from the auth layer. `AuthCoordinator` is the
/// production conformer; tests pass a fake, so the flow runs with no network and
/// no Keychain.
protocol SignInAuthenticating: Sendable {
    func requestCode(email: String) async -> Result<Void, AuthError>
    /// Verifies the code and returns the session UNSAVED, so a Keychain failure
    /// can be retried without a new code.
    func verifyWithoutSaving(email: String, code: String) async -> Result<AuthSession, AuthError>
    func save(_ session: AuthSession) -> Result<Void, AuthError>
    func logoutUnsaved(_ session: AuthSession)
}

extension AuthCoordinator: SignInAuthenticating {
    func logoutUnsaved(_ session: AuthSession) { discardUnsaved(session) }
}

/// The general pasteboard, as far as sign-in touches it.
protocol SignInPasteboard {
    func currentString() -> String?
    func clear()
}

/// A request to move keyboard focus. `id` changes on every request, so asking for
/// the same focus twice (select the digits again after a second wrong code) still
/// reaches the view.
struct SignInFocusRequest: Equatable {
    let id: Int
    let focus: SignInFocus
}

/// Runs a `SignInModel`: feeds it events, performs its effects, and delivers the
/// results of requests back as events. Owns no UI; the window renders `model` and
/// forwards user actions to `send`. Main actor only.
///
/// Late results are safe: a result that arrives after the window closed is
/// dropped by the model (its generation is stale), and a session that arrives
/// after closing is never stored, only logged out of best-effort.
@MainActor
final class SignInFlow: ObservableObject {
    @Published private(set) var model = SignInModel()
    @Published private(set) var focusRequest: SignInFocusRequest?
    /// Bumped by `tick()`, so countdown text redraws even when the model did not change.
    @Published private(set) var tickCount = 0

    private let auth: SignInAuthenticating
    private let clock: () -> Date
    private let pasteboard: SignInPasteboard
    private let isDictationInsertInFlight: () -> Bool
    private let announcer: (String, SignInAnnouncementPriority) -> Void
    private let stopTimers: () -> Void
    private let closeWindow: () -> Void
    private let sessionDidChange: () -> Void
    private var focusCounter = 0
    private var tasks: [Task<Void, Never>] = []

    init(
        auth: SignInAuthenticating,
        clock: @escaping () -> Date = Date.init,
        pasteboard: SignInPasteboard,
        isDictationInsertInFlight: @escaping () -> Bool = { false },
        announcer: @escaping (String, SignInAnnouncementPriority) -> Void = { _, _ in },
        stopTimers: @escaping () -> Void = {},
        closeWindow: @escaping () -> Void = {},
        sessionDidChange: @escaping () -> Void = {}
    ) {
        self.auth = auth
        self.clock = clock
        self.pasteboard = pasteboard
        self.isDictationInsertInFlight = isDictationInsertInFlight
        self.announcer = announcer
        self.stopTimers = stopTimers
        self.closeWindow = closeWindow
        self.sessionDidChange = sessionDidChange
    }

    var now: Date { clock() }

    func send(_ event: SignInEvent) {
        let effects = model.handle(event, now: clock())
        for effect in effects { perform(effect) }
    }

    /// What Return does: the primary button of the current screen. Nothing when
    /// that button is disabled (the model ignores the event).
    func submitPrimary() {
        switch model.state {
        case .emailEntry: send(.submitEmail)
        case .codeEntry: send(model.isCodeExpired(now: clock()) ? .resendTapped : .submitCode)
        case .signedIn: send(.closeRequested)
        case .saveFailed: send(.retrySaveTapped)
        case .sendingCode, .verifying, .saving, .closed: break
        }
    }

    /// Called once a second by the window while it is open.
    func tick() {
        send(.tick)
        tickCount &+= 1
    }

    /// Waits for every request started so far. For tests.
    func settle() async {
        while let task = tasks.popLast() { await task.value }
    }

    private func perform(_ effect: SignInEffect) {
        switch effect {
        case .requestCode(let email, let generation):
            let auth = self.auth
            tasks.append(Task { [weak self] in
                let result = await auth.requestCode(email: email)
                switch result {
                case .success: self?.send(.sendSucceeded(generation: generation))
                case .failure(let error): self?.send(.sendFailed(error, generation: generation))
                }
            })

        case .verifyCode(let email, let digits, let generation):
            let auth = self.auth
            tasks.append(Task { [weak self] in
                let result = await auth.verifyWithoutSaving(email: email, code: digits)
                self?.deliverVerify(result, generation: generation, auth: auth)
            })

        case .storeSession(let session):
            switch auth.save(session) {
            case .success:
                send(.saveSucceeded)
                sessionDidChange()
            case .failure: send(.saveFailed)
            }

        case .clearPasteboardIfItHoldsTheCode(let code):
            // Never touch the pasteboard while a dictation insert is in flight: it
            // is borrowing it, and clearing it would break the restore.
            guard !isDictationInsertInFlight(),
                  let text = pasteboard.currentString(),
                  SignInModel.pasteboardText(text, holdsCode: code)
            else { return }
            pasteboard.clear()

        case .announce(let text, let priority):
            announcer(text, priority)

        case .focus(let focus):
            focusCounter += 1
            focusRequest = SignInFocusRequest(id: focusCounter, focus: focus)

        case .logoutBestEffort(let session):
            auth.logoutUnsaved(session)

        case .stopTimers:
            stopTimers()

        case .closeWindow:
            closeWindow()
        }
    }

    private func deliverVerify(_ result: Result<AuthSession, AuthError>, generation: Int, auth: SignInAuthenticating) {
        switch result {
        case .failure(let error):
            send(.verifyFailed(error, generation: generation))
        case .success(let session):
            send(.verifySucceeded(session, generation: generation))
            // If the model did not take the session (the window closed, or the
            // result was stale), it will never be stored: end it on the server.
            if model.state != .saving && model.state != .signedIn && model.state != .saveFailed {
                auth.logoutUnsaved(session)
            }
        }
    }
}
