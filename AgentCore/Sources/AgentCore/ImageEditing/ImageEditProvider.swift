import Foundation

/// What a verified edit adapter can actually do. Unsupported features are explicit; the app must
/// not silently turn a masked edit into a text-to-image request.
public struct ImageEditCapabilities: Sendable, Hashable {
    public var provider: String
    public var model: String
    public var modelVersion: String
    public var canEditSourceImage: Bool
    public var acceptsMask: Bool
    public var acceptsSeed: Bool
    public var acceptedMimeTypes: Set<String>
    public var maximumInputBytes: Int?
    public var maximumOutputBytes: Int

    public init(
        provider: String,
        model: String,
        modelVersion: String,
        canEditSourceImage: Bool,
        acceptsMask: Bool,
        acceptsSeed: Bool,
        acceptedMimeTypes: Set<String>,
        maximumInputBytes: Int? = nil,
        maximumOutputBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.provider = provider
        self.model = model
        self.modelVersion = modelVersion
        self.canEditSourceImage = canEditSourceImage
        self.acceptsMask = acceptsMask
        self.acceptsSeed = acceptsSeed
        self.acceptedMimeTypes = Set(acceptedMimeTypes.map { $0.lowercased() })
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes
    }
}

/// Request bytes are transient and must never be encoded into chat JSON or diagnostic logs.
public struct ImageEditRequest: Sendable {
    public var sourceData: Data
    public var sourceMimeType: String
    public var sourcePixelWidth: Int
    public var sourcePixelHeight: Int
    public var maskData: Data
    public var maskMimeType: String
    public var maskPixelWidth: Int
    public var maskPixelHeight: Int
    public var instruction: String
    public var seed: Int64?

    public init(
        sourceData: Data,
        sourceMimeType: String,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        maskData: Data,
        maskMimeType: String,
        maskPixelWidth: Int,
        maskPixelHeight: Int,
        instruction: String,
        seed: Int64? = nil
    ) {
        self.sourceData = sourceData
        self.sourceMimeType = sourceMimeType.lowercased()
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.maskData = maskData
        self.maskMimeType = maskMimeType.lowercased()
        self.maskPixelWidth = maskPixelWidth
        self.maskPixelHeight = maskPixelHeight
        self.instruction = instruction
        self.seed = seed
    }

    public func validate(for capabilities: ImageEditCapabilities) throws {
        guard capabilities.canEditSourceImage else { throw ImageEditProviderError.unsupported("source-image editing") }
        guard capabilities.acceptsMask else { throw ImageEditProviderError.unsupported("mask input") }
        guard sourcePixelWidth > 0, sourcePixelHeight > 0,
              sourcePixelWidth == maskPixelWidth, sourcePixelHeight == maskPixelHeight else {
            throw ImageEditProviderError.invalidInput("The source picture and mask must have identical, non-zero dimensions.")
        }
        guard !sourceData.isEmpty, !maskData.isEmpty else { throw ImageEditProviderError.invalidInput("The source picture and mask cannot be empty.") }
        if let limit = capabilities.maximumInputBytes, sourceData.count > limit || maskData.count > limit {
            throw ImageEditProviderError.inputTooLarge(maximumBytes: limit)
        }
        guard capabilities.acceptedMimeTypes.contains(sourceMimeType),
              capabilities.acceptedMimeTypes.contains(maskMimeType) else {
            throw ImageEditProviderError.unsupported("the source or mask image format")
        }
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImageEditProviderError.invalidInput("Describe the change before requesting an edit.")
        }
        if seed != nil && !capabilities.acceptsSeed { throw ImageEditProviderError.unsupported("seed input") }
    }
}

public struct ImageEditResponse: Sendable, Hashable {
    public var imageData: Data
    public var mimeType: String
    public var provider: String
    public var model: String
    public var modelVersion: String
    public var seed: Int64?
    public var cost: Double?

    public init(imageData: Data, mimeType: String, provider: String, model: String, modelVersion: String, seed: Int64? = nil, cost: Double? = nil) {
        self.imageData = imageData
        self.mimeType = mimeType.lowercased()
        self.provider = provider
        self.model = model
        self.modelVersion = modelVersion
        self.seed = seed
        self.cost = cost
    }

    public func validate(maximumOutputBytes: Int) throws {
        guard !imageData.isEmpty else { throw ImageEditProviderError.invalidResponse("The provider returned an empty image.") }
        guard imageData.count <= maximumOutputBytes else { throw ImageEditProviderError.invalidResponse("The edited picture exceeded the safe output-size limit.") }
        guard ["image/png", "image/jpeg", "image/webp"].contains(mimeType), Self.hasMatchingImageSignature(imageData, mimeType: mimeType) else {
            throw ImageEditProviderError.invalidResponse("The provider returned an unsupported or malformed image file.")
        }
        if let cost, !cost.isFinite || cost < 0 { throw ImageEditProviderError.invalidResponse("The provider returned an invalid cost value.") }
    }

    private static func hasMatchingImageSignature(_ data: Data, mimeType: String) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        switch mimeType {
        case "image/png": return bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        case "image/jpeg": return bytes.count >= 3 && bytes[0...2].elementsEqual([0xff, 0xd8, 0xff])
        case "image/webp": return bytes.count >= 12 && Array(bytes[0..<4]) == Array("RIFF".utf8) && Array(bytes[8..<12]) == Array("WEBP".utf8)
        default: return false
        }
    }
}

public protocol ImageEditProvider: Sendable {
    var capabilities: ImageEditCapabilities { get }
    func edit(_ request: ImageEditRequest) async throws -> ImageEditResponse
}

public enum ImageEditProviderError: Error, Sendable, Equatable, LocalizedError {
    case unsupported(String)
    case invalidInput(String)
    case inputTooLarge(maximumBytes: Int)
    case invalidResponse(String)
    case provider(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let feature): return "This image-edit provider does not support \(feature)."
        case .invalidInput(let message), .invalidResponse(let message), .provider(let message): return message
        case .inputTooLarge(let maximumBytes): return "The source image or mask is larger than the provider's safe input limit of \(maximumBytes) bytes."
        }
    }
}
