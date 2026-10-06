import SwiftUI
import AppKit

public struct NormalizedBox: Equatable, Sendable {
    public let ymin: Double // 0..1000
    public let xmin: Double // 0..1000
    public let ymax: Double // 0..1000
    public let xmax: Double // 0..1000
    public let label: String?

    public init(ymin: Double, xmin: Double, ymax: Double, xmax: Double, label: String? = nil) {
        self.ymin = ymin
        self.xmin = xmin
        self.ymax = ymax
        self.xmax = xmax
        self.label = label
    }

    /// Converts normalized 0..1000 coordinates to macOS screen coordinates.
    /// In macOS screen coordinates, Y=0 is at the bottom of the screen.
    public func rect(in screenFrame: CGRect) -> CGRect {
        let width = (xmax - xmin) / 1000.0 * screenFrame.width
        let height = (ymax - ymin) / 1000.0 * screenFrame.height
        let x = screenFrame.minX + (xmin / 1000.0 * screenFrame.width)
        // Flip Y axis for macOS screen coordinates (origin at bottom-left)
        let y = screenFrame.minY + (1.0 - (ymax / 1000.0)) * screenFrame.height
        return CGRect(x: x, y: y, width: max(width, 10), height: max(height, 10))
    }
}

public struct BoxParseResult: Equatable, Sendable {
    public let cleanText: String
    public let boxes: [NormalizedBox]

    public init(cleanText: String, boxes: [NormalizedBox]) {
        self.cleanText = cleanText
        self.boxes = boxes
    }
}

public enum BoundingBoxParser {
    /// Parses `<box>ymin,xmin,ymax,xmax</box>` or `<box label="...">ymin,xmin,ymax,xmax</box>` tags.
    public static func parse(_ text: String) -> BoxParseResult {
        var boxes: [NormalizedBox] = []
        let pattern = #"<box(?:\s+label="([^"]+)")?>\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*</box>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return BoxParseResult(cleanText: text, boxes: [])
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let labelRange = match.range(at: 1)
            let label: String? = labelRange.location != NSNotFound ? nsText.substring(with: labelRange) : nil

            guard let ymin = Double(nsText.substring(with: match.range(at: 2))),
                  let xmin = Double(nsText.substring(with: match.range(at: 3))),
                  let ymax = Double(nsText.substring(with: match.range(at: 4))),
                  let xmax = Double(nsText.substring(with: match.range(at: 5))) else {
                continue
            }

            boxes.append(NormalizedBox(ymin: ymin, xmin: xmin, ymax: ymax, xmax: xmax, label: label))
        }

        let cleanText = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return BoxParseResult(cleanText: cleanText, boxes: boxes)
    }
}

public class BoundingBoxOverlayController: @unchecked Sendable {
    public static let shared = BoundingBoxOverlayController()
    private var window: NSPanel?
    private var autoDismissTimer: Timer?

    @MainActor
    public func show(boxes: [NormalizedBox], screenFrame targetFrame: CGRect? = nil) {
        hide()
        guard !boxes.isEmpty else { return }

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let frame = targetFrame ?? (screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // Completely click-through

        let hostingView = NSHostingView(rootView: BoundingBoxOverlayView(boxes: boxes, screenFrame: frame))
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
        self.window = panel

        // Auto-dismiss spotlight highlight after 7 seconds
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.hide() }
        }
    }

    @MainActor
    public func hide() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        window?.orderOut(nil)
        window = nil
    }
}

struct BoundingBoxOverlayView: View {
    let boxes: [NormalizedBox]
    let screenFrame: CGRect
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            ForEach(0..<boxes.count, id: \.self) { i in
                let box = boxes[i]
                let rect = box.rect(in: screenFrame)

                // Convert absolute screen frame coordinates to local ZStack view coordinates
                let localX = rect.origin.x - screenFrame.minX
                let localY = screenFrame.maxY - rect.origin.y - rect.height // Flip Y for SwiftUI layout

                ZStack(alignment: .topLeading) {
                    // Pulsing Glow Outline
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.cyan, lineWidth: isPulsing ? 4 : 2)
                        .shadow(color: Color.cyan.opacity(isPulsing ? 0.9 : 0.4), radius: isPulsing ? 12 : 4)

                    // Target badge icon
                    HStack(spacing: 4) {
                        Image(systemName: "scope")
                            .font(.system(size: 10, weight: .bold))
                        if let label = box.label {
                            Text(label)
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.cyan)
                    .foregroundColor(.black)
                    .cornerRadius(4)
                    .offset(x: 4, y: -24)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: localX + rect.width / 2, y: localY + rect.height / 2)
            }
        }
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
