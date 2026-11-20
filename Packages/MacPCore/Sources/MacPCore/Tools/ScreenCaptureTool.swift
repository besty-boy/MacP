import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Captures the macOS main display or frontmost window silently and returns an MCP `image` content block
/// (base64 JPEG/PNG resized cleanly for LLM vision context) plus metadata.
public struct ScreenCaptureTool: MCPTool {
    public let name = "macos_capture_screen"
    public let displayName = "Capture d'écran"
    public let shortSubtitle = "Vision écran / fenêtre active"
    public let symbolName = "camera.viewfinder"
    public let category: ToolCategory = .vision
    public let description = "Captures the macOS screen (main display or frontmost app window) silently, resizes it cleanly, and returns an MCP image block for AI vision inspection."
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
                    "description": "What to capture: 'main_display' (default) or 'frontmost_window'.",
                    "enum": ["main_display", "frontmost_window"]
                ],
                "max_width": [
                    "type": "integer",
                    "description": "Maximum image width in pixels (400 to 2560, default: 1280).",
                    "minimum": 400,
                    "maximum": 2560
                ],
                "format": [
                    "type": "string",
                    "description": "Output image encoding: 'jpeg' (smaller, default) or 'png'.",
                    "enum": ["jpeg", "png"]
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

        let frontAppInfo: (name: String?, pid: pid_t?) = await MainActor.run {
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.localizedName, app?.processIdentifier)
        }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("macp-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var cliArgs = ["-x", "-t", "png"] // `-x`: silent (no shutter sound)
        var resolvedTarget = "main_display"

        if target == "frontmost_window",
           let pid = frontAppInfo.pid,
           let windowID = Self.frontmostWindowID(forPID: pid) {
            cliArgs.append(contentsOf: ["-l", String(windowID), "-o"])
            resolvedTarget = "frontmost_window"
        } else {
            cliArgs.append("-m") // main display
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

        guard let rawImageData = try? Data(contentsOf: tempFile),
              let encoded = Self.encodeAndDownscale(imageData: rawImageData, maxWidth: maxWidth, usePNG: usePNG) else {
            return .failure("Impossible d'encoder l'image capturée.")
        }

        let mimeType = usePNG ? "image/png" : "image/jpeg"
        let metadata = CaptureMetadata(
            target: resolvedTarget,
            frontmostApp: frontAppInfo.name,
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

    private static func frontmostWindowID(forPID pid: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowNumber = info[kCGWindowNumber as String] as? UInt32 else {
                continue
            }
            return CGWindowID(windowNumber)
        }
        return nil
    }

    private static func encodeAndDownscale(
        imageData: Data,
        maxWidth: Int,
        usePNG: Bool
    ) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let srcW = cgImage.width
        let srcH = cgImage.height
        let finalImage: CGImage

        if srcW > maxWidth, srcW > 0, srcH > 0 {
            let scale = Double(maxWidth) / Double(srcW)
            let dstW = maxWidth
            let dstH = max(1, Int((Double(srcH) * scale).rounded()))
            let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: dstW,
                height: dstH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
            guard let resized = ctx.makeImage() else { return nil }
            finalImage = resized
        } else {
            finalImage = cgImage
        }

        let mutableData = NSMutableData()
        let utType = usePNG ? UTType.png.identifier : UTType.jpeg.identifier
        guard let dest = CGImageDestinationCreateWithData(mutableData, utType as CFString, 1, nil) else {
            return nil
        }

        let options: [CFString: Any] = usePNG
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.78]
        CGImageDestinationAddImage(dest, finalImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return (mutableData as Data, finalImage.width, finalImage.height)
    }
}
