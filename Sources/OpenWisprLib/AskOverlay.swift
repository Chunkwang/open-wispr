import SwiftUI
import AppKit

public enum AskOverlayState: Equatable, Sendable {
    case hidden
    case listening
    case processing
    case answered(String)
    case error(String)
}

public class AskOverlayController: @unchecked Sendable {
    public static let shared = AskOverlayController()
    private var window: NSPanel?
    private var eventMonitor: Any?
    
    /// - Parameter windowFrame: the on-screen frame (AppKit/`NSScreen`
    ///   coordinates) of the window Ask's screenshot was scoped to, when there
    ///   was one (`RewriteOutcome.capturedWindowFrame`). Used only for
    ///   `.answered`, to place any `<box>` tag inside that window rather than
    ///   guessing at the full display under the cursor.
    @MainActor
    public func show(state: AskOverlayState, windowFrame: CGRect? = nil) {
        if state == .hidden {
            hide()
            return
        }
        
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 350, height: 100),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false // Shadow is managed by SwiftUI view
            window = panel
        }
        
        var effectiveState = state
        if case .answered(let rawAnswer) = state {
            let parseResult = BoundingBoxParser.parse(rawAnswer)
            var cleanText = parseResult.cleanText
            if cleanText.isEmpty {
                if let firstLabel = parseResult.boxes.first?.label {
                    cleanText = Copy.askHighlightedLabel(firstLabel)
                } else if !parseResult.boxes.isEmpty {
                    cleanText = Copy.askHighlightedElement
                } else {
                    let trimmed = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                    cleanText = trimmed.isEmpty ? Copy.askNoResponseText : trimmed
                }
            }
            effectiveState = .answered(cleanText)
            if !parseResult.boxes.isEmpty {
                BoundingBoxOverlayController.shared.show(boxes: parseResult.boxes, screenFrame: windowFrame)
            }
        }
        
        let view = AskOverlayView(state: effectiveState, onClose: { [weak self] in
            DispatchQueue.main.async {
                self?.hide()
            }
        })
        
        let hostingView = NSHostingView(rootView: view)
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window?.contentView = hostingView
        
        if !(window?.isVisible ?? false) {
            // Position near mouse cursor
            let mouseLoc = NSEvent.mouseLocation
            let offset: CGFloat = 16
            let windowFrame = window!.frame
            
            var newX = mouseLoc.x + offset
            var newY = mouseLoc.y - windowFrame.height - offset
            
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) }) {
                if newX + windowFrame.width > screen.visibleFrame.maxX {
                    newX = screen.visibleFrame.maxX - windowFrame.width - offset
                }
                if newY < screen.visibleFrame.minY {
                    newY = screen.visibleFrame.minY + offset
                }
            }
            
            window?.setFrameOrigin(NSPoint(x: newX, y: newY))
            window?.orderFront(nil)
            
            if eventMonitor == nil {
                // Monitor for ESC key globally
                eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 { // ESC key
                        DispatchQueue.main.async { self?.hide() }
                    }
                }
            }
        }
    }
    
    @MainActor
    public func hide() {
        BoundingBoxOverlayController.shared.hide()
        window?.orderOut(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

struct AskOverlayView: View {
    let state: AskOverlayState
    let onClose: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .hidden:
                EmptyView()
            case .listening:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(Copy.askListening)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                }
            case .processing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(Copy.askProcessing)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                }
            case .answered(let answer):
                ScrollView {
                    Text(answer)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled) 
                }
                .frame(maxHeight: 400)
                
                HStack {
                    Button(action: {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(answer, forType: .string)
                        onClose()
                    }) {
                        Label(Copy.askCopyDismiss, systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            case .error(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 350)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.2), radius: 15, x: 0, y: 5)
        .padding(20) // Give space for the shadow
    }
}
