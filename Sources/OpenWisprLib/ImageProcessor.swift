import Foundation
import CoreGraphics
import Vision
import AppKit

public struct ProcessedImage: Sendable {
    public let jpegData: Data
    public let recognizedText: String
}

public enum ImageProcessorError: Error, LocalizedError {
    case encodingFailed
    case ocrFailed(Error?)
    
    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to compress or encode the image in memory."
        case .ocrFailed(let e): return "Text recognition failed: \(e?.localizedDescription ?? "Unknown error")"
        }
    }
}

public final class ImageProcessor {
    
    /// Downscales the image, encodes it to JPEG in memory, and extracts text using Vision.
    public static func process(cgImage: CGImage) async throws -> ProcessedImage {
        // 1. Downscale the image if it's too large (max 1920x1080 bounding box)
        let maxDimension: CGFloat = 1920
        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)
        
        var targetWidth = originalWidth
        var targetHeight = originalHeight
        
        if originalWidth > maxDimension || originalHeight > maxDimension {
            let ratio = min(maxDimension / originalWidth, maxDimension / originalHeight)
            targetWidth = originalWidth * ratio
            targetHeight = originalHeight * ratio
        }
        
        // Resize context
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        // Use standard bitmap info for context to prevent unsupported pixel format errors
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let context = CGContext(data: nil,
                                      width: Int(targetWidth),
                                      height: Int(targetHeight),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            throw ImageProcessorError.encodingFailed
        }
        
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        guard let resizedCGImage = context.makeImage() else {
            throw ImageProcessorError.encodingFailed
        }
        
        // 2. Encode to JPEG (Memory only)
        let bitmapRep = NSBitmapImageRep(cgImage: resizedCGImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ImageProcessorError.encodingFailed
        }
        
        // 3. Extract text using Vision OCR (we pass the original full-res image for better OCR accuracy)
        let recognizedText = try await extractText(from: cgImage)
        
        return ProcessedImage(jpegData: jpegData, recognizedText: recognizedText)
    }
    
    private static func extractText(from cgImage: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: ImageProcessorError.ocrFailed(error))
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                
                let text = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")
                
                continuation.resume(returning: text)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: ImageProcessorError.ocrFailed(error))
            }
        }
    }
}
