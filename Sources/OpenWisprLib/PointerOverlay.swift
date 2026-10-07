import SwiftUI
import AppKit

public class PointerOverlayController: @unchecked Sendable {
    public static let shared = PointerOverlayController()
    private var window: NSPanel?
    private var dismissTimer: Timer?
    private var eventMonitor: Any?

    @MainActor
    public func showPointer(at axFrame: CGRect) {
        let windowRect = cgRectToNSWindowRect(axFrame)
        
        // Expand slightly to fit the shadow and glowing border
        let padding: CGFloat = 20
        let paddedRect = NSRect(
            x: windowRect.origin.x - padding,
            y: windowRect.origin.y - padding,
            width: windowRect.width + padding * 2,
            height: windowRect.height + padding * 2
        )
        
        if window == nil {
            let panel = NSPanel(
                contentRect: paddedRect,
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            window = panel
        } else {
            window?.setFrame(paddedRect, display: true)
        }
        
        let view = PointerOverlayView(padding: padding)
        let hostingView = NSHostingView(rootView: view)
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window?.contentView = hostingView
        
        window?.orderFront(nil)
        
        if eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] _ in
                DispatchQueue.main.async { self?.hide() }
            }
        }
        
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.hide() }
        }
    }
    
    @MainActor
    public func hide() {
        window?.orderOut(nil)
        dismissTimer?.invalidate()
        dismissTimer = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    private func cgRectToNSWindowRect(_ cgRect: CGRect) -> NSRect {
        // In accessibility (CG) coordinates, (0,0) is top-left of primary screen.
        // In NSWindow coordinates, (0,0) is bottom-left of primary screen.
        // `AXTreeWalker.axRectToScreenRect` does this same flip for the Ask
        // bounding-box overlay; shared here so the math lives in one place.
        AXTreeWalker.axRectToScreenRect(cgRect)
    }
}

struct PointerOverlayView: View {
    let padding: CGFloat
    
    @State private var scale: CGFloat = 1.3
    @State private var opacity: Double = 0.0
    
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.red, lineWidth: 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.red.opacity(0.15))
            )
            .shadow(color: Color.red.opacity(0.6), radius: 10, x: 0, y: 0)
            .padding(padding)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55).delay(0.05)) {
                    scale = 1.0
                    opacity = 1.0
                }
            }
    }
}
