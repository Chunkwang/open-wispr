import AppKit
import SwiftUI

struct ContextConsentView: View {
    let onAccept: () -> Void
    let onDecline: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    private var background: Color {
        colorScheme == .dark ? BrandColor.darkBackground : BrandColor.lightBackground
    }
    private var textColor: Color {
        colorScheme == .dark ? BrandColor.darkText : BrandColor.lightText
    }
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Enable Screen Context")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(textColor)
                .padding(.top, 32)
            
            Text("To edit selected text with your voice, Murmur needs permission to read it.")
                .font(.system(size: 15))
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("**What is sent:** Only the text you have highlighted and the frontmost window's title.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("**To whom:** Our secure proxy, then to the AI model. It is never stored.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("**Safety:** Password fields and secure apps are automatically ignored.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13))
            .foregroundColor(BrandColor.sageGray)
            .padding(.horizontal, 32)
            .padding(.vertical, 8)
            
            Spacer()
            
            HStack(spacing: 16) {
                Button(action: onDecline) {
                    Text("Decline")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(BrandColor.sageGray.opacity(0.2))
                .cornerRadius(6)
                
                Button(action: onAccept) {
                    Text("Accept")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(BrandColor.emerald)
                .cornerRadius(6)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .frame(width: 480, height: 340)
        .background(background)
    }
}

public final class ContextConsentWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var completion: ((Bool) -> Void)?
    
    public static func present(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let controller = ContextConsentWindowController()
            controller.show(completion: completion)
        }
    }
    
    private func show(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        
        let view = ContextConsentView(
            onAccept: { [weak self] in
                #if DEBUG
                ContextConsent.shared.recordTextAcceptance()
                #endif
                self?.completion?(true)
                self?.close()
            },
            onDecline: { [weak self] in
                self?.completion?(false)
                self?.close()
            }
        )
        
        let hosting = NSHostingController(rootView: view)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Screen Context Permission"
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
        // If they close the window without pressing accept, treat as decline
        completion?(false)
        completion = nil
    }
}
