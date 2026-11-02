import Testing
@testable import AgentCore

@Suite("Image edit provider contract (no network or provider spend)")
struct ImageEditProviderContractTests {
    private let capabilities = ImageEditCapabilities(
        provider: "Fixture",
        model: "fixture-fill",
        modelVersion: "fixture-v1",
        canEditSourceImage: true,
        acceptsMask: true,
        acceptsSeed: true,
        acceptedMimeTypes: ["image/png", "image/jpeg"],
        maximumInputBytes: 1024,
        maximumOutputBytes: 2048
    )

    private func request(
        sourceWidth: Int = 20,
        maskWidth: Int = 20,
        seed: Int64? = 55
    ) -> ImageEditRequest {
        ImageEditRequest(
            sourceData: Data([1, 2, 3]),
            sourceMimeType: "IMAGE/PNG",
            sourcePixelWidth: sourceWidth,
            sourcePixelHeight: 10,
            maskData: Data([4, 5]),
            maskMimeType: "image/png",
            maskPixelWidth: maskWidth,
            maskPixelHeight: 10,
            instruction: "paint the selected area blue",
            seed: seed
        )
    }

    @Test("A valid request preserves exact provider inputs and optional seed")
    func validRequest() throws {
        let value = request()
        try value.validate(for: capabilities)
        #expect(value.sourceData == Data([1, 2, 3]))
        #expect(value.maskData == Data([4, 5]))
        #expect(value.instruction == "paint the selected area blue")
        #expect(value.seed == 55)
    }

    @Test("Mismatched source and mask dimensions are rejected before any provider call")
    func dimensionMismatch() {
        #expect(throws: ImageEditProviderError.self) {
            try request(maskWidth: 19).validate(for: capabilities)
        }
    }

    @Test("A missing seed is allowed; unsupported seeds are not silently sent")
    func seedCapability() throws {
        try request(seed: nil).validate(for: capabilities)
        let noSeed = ImageEditCapabilities(
            provider: "Fixture", model: "fixture-fill", modelVersion: "fixture-v1",
            canEditSourceImage: true, acceptsMask: true, acceptsSeed: false,
            acceptedMimeTypes: ["image/png"]
        )
        #expect(throws: ImageEditProviderError.self) {
            try request(seed: 55).validate(for: noSeed)
        }
    }

    @Test("A provider without mask support cannot be used for a brush edit")
    func maskCapability() {
        let noMask = ImageEditCapabilities(
            provider: "Fixture", model: "text-to-image", modelVersion: "fixture-v1",
            canEditSourceImage: true, acceptsMask: false, acceptsSeed: false,
            acceptedMimeTypes: ["image/png"]
        )
        #expect(throws: ImageEditProviderError.self) {
            try request(seed: nil).validate(for: noMask)
        }
    }

    @Test("Input size and blank instructions fail before network access")
    func inputBounds() {
        var oversized = request(seed: nil)
        oversized.sourceData = Data(repeating: 7, count: 1025)
        #expect(throws: ImageEditProviderError.self) { try oversized.validate(for: capabilities) }
        var blank = request(seed: nil)
        blank.instruction = "  \n"
        #expect(throws: ImageEditProviderError.self) { try blank.validate(for: capabilities) }
    }

    @Test("Output bytes, MIME type, and cost are validated")
    func responseValidation() throws {
        let valid = ImageEditResponse(imageData: Data([0xff, 0xd8, 0xff, 0xd9]), mimeType: "image/jpeg", provider: "Fixture", model: "fixture-fill", modelVersion: "fixture-v1", seed: nil, cost: 0.05)
        try valid.validate(maximumOutputBytes: 3)
        let tooLarge = ImageEditResponse(imageData: Data(repeating: 1, count: 4), mimeType: "image/jpeg", provider: "Fixture", model: "fixture-fill", modelVersion: "fixture-v1")
        #expect(throws: ImageEditProviderError.self) { try tooLarge.validate(maximumOutputBytes: 3) }
        let badMime = ImageEditResponse(imageData: Data([1]), mimeType: "text/plain", provider: "Fixture", model: "fixture-fill", modelVersion: "fixture-v1")
        #expect(throws: ImageEditProviderError.self) { try badMime.validate(maximumOutputBytes: 3) }
        let malformed = ImageEditResponse(imageData: Data([1, 2, 3, 4]), mimeType: "image/png", provider: "Fixture", model: "fixture-fill", modelVersion: "fixture-v1")
        #expect(throws: ImageEditProviderError.self) { try malformed.validate(maximumOutputBytes: 4) }
        let badCost = ImageEditResponse(imageData: Data([1]), mimeType: "image/png", provider: "Fixture", model: "fixture-fill", modelVersion: "fixture-v1", cost: -.infinity)
        #expect(throws: ImageEditProviderError.self) { try badCost.validate(maximumOutputBytes: 3) }
    }
}
