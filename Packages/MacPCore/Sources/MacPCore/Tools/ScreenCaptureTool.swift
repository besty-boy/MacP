import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Captures the macOS main display or frontmost user window silently and returns an MCP `image` content block
/// (base64 JPEG/PNG downscaled via low-memory ImageIO thumbnailing) plus compact metadata.
public struct ScreenCaptureTool: MCPTool {
    public let name = "macos_capture_screen"
    public let displayName = "Capture d'écran"
    public let shortSubtitle = "Vision écran / fenêtre active"
    public let symbolName = "camera.viewfinder"
    public let category: ToolCategory = .vision
    public let description = "Silently captures the main display or frontmost window and returns a resized base64 image + metadata."
    public let sensitivity: ToolSensitivity = .critical
    public let permissionReason = "Un client IA souhaite capturer une image de votre écran macOS. Vérifiez qu'aucune donnée confidentielle n'est affichée avant d'accepter."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Capturer l'écran macOS",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: false
        )
    }

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "target": [
                    "type": "string",
                    "description": "'main_display' (default) or 'frontmost_window'.",
                    "enum": ["main_display", "frontmost_window"]
                ],
                "max_width": [
                    "type": "integer",
                    "description": "Max image width in px (400-2560, default: 1280).",
                    "minimum": 400,
                    "maximum": 2560
                ],
                "format": [
                    "type": "string",
                    "description": "'jpeg' (default, smaller) or 'png'.",
                    "enum": ["jpeg", "png"]
                ],
                "quality": [
                    "type": "integer",
                    "description": "JPEG quality 40-95 (default: 72).",
                    "minimum": 40,
                    "maximum": 95
                ]
            ],
            "additionalProperties": false
        ]
    }

    private struct CaptureMetadata: Codable {
        let target: String
        let frontmostApp: String?
        let width: Int
        let height: Int
        let mimeType: String
        let encodedBytes: Int
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        let target = arguments["target"]?.stringValue ?? "main_display"
        let maxWidth = min(max(arguments["max_width"]?.intValue ?? 1280, 400), 2560)
        let format = (arguments["format"]?.stringValue ?? "jpeg").lowercased()
        let usePNG = (format == "png")
        let quality = Double(min(max(arguments["quality"]?.intValue ?? 72, 40), 95)) / 100.0

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("macp-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var cliArgs = ["-x", "-t", "png"] // `-x`: silent (no shutter sound)
        var resolvedTarget = "main_display"
        var capturedAppName: String?

        if target == "frontmost_window",
           let windowMatch = Self.frontmostUserWindow() {
            cliArgs.append(contentsOf: ["-l", String(windowMatch.windowID), "-o"])
            resolvedTarget = "frontmost_window"
            capturedAppName = windowMatch.ownerName
        } else {
            cliArgs.append("-m") // main display
            if let owner = Self.frontmostUserWindow()?.ownerName {
                capturedAppName = owner
            } else {
                capturedAppName = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
            }
        }
        cliArgs.append(tempFile.path)

        let res = try await NativeProcessRunner.run(
            executablePath: "/usr/sbin/screencapture",
            arguments: cliArgs,
            timeoutSeconds: 15
        )

        guard res.exitCode == 0, FileManager.default.fileExists(atPath: tempFile.path) else {
            return .failure("Échec de la capture d'écran (vérifiez Réglages Système > Confidentialité > Enregistrement de l'écran pour MacP) : \(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        guard let encoded = Self.encodeAndDownscale(
            fileURL: tempFile,
            maxWidth: maxWidth,
            usePNG: usePNG,
            jpegQuality: quality
        ) else {
            return .failure("Impossible d'encoder l'image capturée.")
        }

        let mimeType = usePNG ? "image/png" : "image/jpeg"
        let metadata = CaptureMetadata(
            target: resolvedTarget,
            frontmostApp: capturedAppName,
            width: encoded.width,
            height: encoded.height,
            mimeType: mimeType,
            encodedBytes: encoded.data.count
        )
        let metaJSON = try ToolOutputFormatter.encodeJSON(metadata)

        return MCPCallToolResult(
            content: [
                .image(base64Data: encoded.data.base64EncodedString(), mimeType: mimeType),
                .text(metaJSON)
            ],
            isError: false
        )
    }

    /// Finds the topmost on-screen user window while skipping MacP itself (so capturing right after approving
    /// MacP's `NSAlert` targets the user's real active window instead of MacP).
    private static func frontmostUserWindow() -> (windowID: CGWindowID, ownerName: String?)? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != selfPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowNumber = info[kCGWindowNumber as String] as? UInt32 else {
                continue
            }

            if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: boundsDict),
               (rect.width < 40 || rect.height < 40) {
                continue
            }

            let ownerName = info[kCGWindowOwnerName as String] as? String
            return (CGWindowID(windowNumber), ownerName)
        }
        return nil
    }

    /// Single-pass ImageIO downscale & encode directly from the file URL (minimizes peak RAM on 5K/6K Retina displays).
    private static func encodeAndDownscale(
        fileURL: URL,
        maxWidth: Int,
        usePNG: Bool,
        jpegQuality: Double
    ) -> (data: Data, width: Int, height: Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let srcW = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let srcH = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0

        let finalImage: CGImage
        if srcW > maxWidth, srcW > 0, srcH > 0 {
            // Compute maxPixelSize so the width equals `maxWidth` even for portrait windows (tall > wide).
            let scale = Double(maxWidth) / Double(srcW)
            let scaledHeight = Int((Double(srcH) * scale).rounded())
            let maxPixelSize = max(maxWidth, scaledHeight)

            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            finalImage = thumbnail
        } else {
            guard let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            finalImage = fullImage
        }

        let mutableData = NSMutableData()
        let utType = usePNG ? UTType.png.identifier : UTType.jpeg.identifier
        guard let dest = CGImageDestinationCreateWithData(mutableData, utType as CFString, 1, nil) else {
            return nil
        }

        let options: [CFString: Any] = usePNG
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(dest, finalImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return (mutableData as Data, finalImage.width, finalImage.height)
    }
}
