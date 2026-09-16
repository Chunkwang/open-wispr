import AppKit
import SwiftUI

/// First-run onboarding + pre-permission explainer window.
/// Copy is sourced verbatim from the brand voice guide's v1 sample copy —
/// do not paraphrase; permission-request tone must stay "maximally plain."
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case microphone
    case accessibility

    var body: String {
        switch self {
        case .welcome:
            return "Hold the key, say what you want written. It stays on this Mac unless you tell it otherwise."
        case .microphone:
            return "We need microphone access to hear what you dictate. Audio is processed on this device and never saved or sent anywhere for the free tier."
        case .accessibility:
            return "Accessibility access lets the app place your dictated text wherever your cursor is. It doesn't let the app read anything you haven't dictated."
        }
    }

    var buttonLabel: String {
        switch self {
        case .welcome: return "Get Started"
        case .microphone: return "Allow Microphone Access"
        case .accessibility: return "Allow Accessibility Access"
        }
    }
}

struct BrandColor {
    static let forestGreen = Color(hex: 0x1B4332)
    static let emerald = Color(hex: 0x2D8659)
    static let darkBackground = Color(hex: 0x0D1210)
    static let lightBackground = Color(hex: 0xF7F9F7)
    static let darkText = Color(hex: 0xE8EDE9)
    static let lightText = Color(hex: 0x14201B)
    static let sageGray = Color(hex: 0x8A9A92)
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var step: OnboardingStep = .welcome
    @Environment(\.colorScheme) private var colorScheme

    private var background: Color {
        colorScheme == .dark ? BrandColor.darkBackground : BrandColor.lightBackground
    }
    private var textColor: Color {
        colorScheme == .dark ? BrandColor.darkText : BrandColor.lightText
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(step.body)
                .font(.system(size: 17, weight: .regular, design: .default))
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? BrandColor.emerald : BrandColor.sageGray.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
            }
            Button(action: advance) {
                Text(step.buttonLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(BrandColor.emerald)
            .cornerRadius(6)
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 480, height: 320)
        .background(background)
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            onFinish()
            return
        }
        step = next
    }
}

/// Shows the onboarding window on first run only (no config file yet),
/// blocking the caller until the user has clicked through every step —
/// mirrors the existing synchronous-permission-wait pattern in AppDelegate/Permissions
/// so the OS permission prompts that follow always have this context shown first.
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var completion: (() -> Void)?

    /// Caller is responsible for only invoking this on first run — checking
    /// Config.configFile's existence here would race Config.load(), which
    /// creates that file as a side effect the moment it's called.
    public static func presentIfFirstRun(completion: @escaping () -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let controller = OnboardingWindowController()
            controller.show {
                semaphore.signal()
            }
        }
        semaphore.wait()
        completion()
    }

    private func show(onDismiss: @escaping () -> Void) {
        completion = onDismiss

        let view = OnboardingView(onFinish: { [weak self] in
            self?.close()
        })
        let hosting = NSHostingController(rootView: view)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Welcome"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.delegate = self
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow
    }

    private func close() {
        window?.close()
        window = nil
    }

    public func windowWillClose(_ notification: Notification) {
        completion?()
        completion = nil
    }
}
