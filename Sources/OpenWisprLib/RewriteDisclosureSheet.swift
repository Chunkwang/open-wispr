import AppKit
import SwiftUI

/// The privacy disclosure sheet shown the first time the user tries to enable
/// the Rewrite feature. This is the ONLY code path that calls
/// `RewriteConsent.recordAcceptance()`. It explains exactly what data leaves
/// the device, to whom, and what is never sent.
///
/// Design rules (from the implementation plan, Task 5.1):
/// - Decline is as prominent as Accept
/// - Return/Enter must NOT trigger Accept
/// - The sheet records version, timestamp and account
/// - Revoking consent is always available
/// - Consent is invalidated on disclosure-version bumps and sign-out

struct RewriteDisclosureView: View {
    let onAccept: () -> Void
    let onDecline: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    private var background: Color {
        colorScheme == .dark ? BrandColor.darkBackground : BrandColor.lightBackground
    }
    private var textColor: Color {
        colorScheme == .dark ? BrandColor.darkText : BrandColor.lightText
    }
    private var secondaryText: Color {
        BrandColor.sageGray
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundColor(BrandColor.emerald)
                    .padding(.top, 32)
                
                Text("Before Rewrite can work")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(textColor)
            }
            .padding(.bottom, 20)
            
            // What is sent
            VStack(alignment: .leading, spacing: 16) {
                disclosureRow(
                    icon: "text.quote",
                    iconColor: BrandColor.emerald,
                    title: "What is sent",
                    body: "The text you just dictated — nothing else. Never your audio, never your keystrokes, never your clipboard."
                )
                
                disclosureRow(
                    icon: "building.2",
                    iconColor: BrandColor.emerald,
                    title: "To whom",
                    body: "Your text goes to our secure proxy, then to Anthropic's Claude model for rewriting. Both connections are encrypted."
                )
                
                disclosureRow(
                    icon: "trash",
                    iconColor: BrandColor.emerald,
                    title: "What is kept",
                    body: "Nothing. Our server does not log, store or retain your text. Anthropic's API does not train on it."
                )
                
                disclosureRow(
                    icon: "xmark.shield",
                    iconColor: .orange,
                    title: "If things go wrong",
                    body: "If the network or the service fails, your raw dictation is inserted instead. Nothing is lost."
                )
            }
            .padding(.horizontal, 32)
            
            Spacer()
            
            // Revoke notice
            Text("You can revoke this at any time from the menu bar.")
                .font(.system(size: 11))
                .foregroundColor(secondaryText)
                .padding(.bottom, 16)
            
            // Buttons — Decline and Accept are equally prominent
            HStack(spacing: 16) {
                Button(action: onDecline) {
                    Text("Decline")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(textColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(BrandColor.sageGray.opacity(0.2))
                )
                .keyboardShortcut(.cancelAction)
                
                Button(action: onAccept) {
                    Text("Accept")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(BrandColor.emerald)
                )
                // Deliberately NO .keyboardShortcut(.defaultAction) —
                // Return must NOT trigger Accept (plan requirement).
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .frame(width: 500, height: 480)
        .background(background)
    }
    
    @ViewBuilder
    private func disclosureRow(icon: String, iconColor: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(iconColor)
                .frame(width: 24, height: 24, alignment: .center)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(textColor)
                Text(body)
                    .font(.system(size: 13))
                    .foregroundColor(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }
}

// MARK: - Window Controller

public final class RewriteDisclosureWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var completion: ((Bool) -> Void)?
    
    /// Prevent the controller from being deallocated while the window is open.
    private static var retainedController: RewriteDisclosureWindowController?
    
    public static func present(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let controller = RewriteDisclosureWindowController()
            retainedController = controller
            controller.show(completion: completion)
        }
    }
    
    private func show(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        
        let view = RewriteDisclosureView(
            onAccept: { [weak self] in
                RewriteConsent.shared.recordAcceptance()
                self?.finish(accepted: true)
            },
            onDecline: { [weak self] in
                self?.finish(accepted: false)
            }
        )
        
        let hosting = NSHostingController(rootView: view)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Privacy Disclosure"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.delegate = self
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow
    }
    
    private func finish(accepted: Bool) {
        completion?(accepted)
        completion = nil
        window?.close()
        window = nil
        Self.retainedController = nil
    }
    
    public func windowWillClose(_ notification: Notification) {
        // Closing the window without pressing Accept = Decline
        if completion != nil {
            completion?(false)
            completion = nil
        }
        Self.retainedController = nil
    }
}
