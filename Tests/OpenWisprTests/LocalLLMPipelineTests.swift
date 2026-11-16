import XCTest
@testable import OpenWisprLib

final class LocalLLMPipelineTests: XCTestCase {
    // MARK: - validatedURL (Day 3 hardening, finding 7)
    //
    // `localLLMEnabled` is a bypass every gate uses to skip the paid-tier
    // `hasToken()` check, on the premise the request never leaves the device.
    // `config.localLLMURL` used to be trusted as-is with no loopback check, so a
    // remote host there would have both skipped the token check AND sent a
    // request off-device. These tests pin down the fail-safe behaviour: a
    // non-loopback URL must return nil, not the remote host.

    func testNilConfiguredURLUsesTheDefaultLoopbackAddress() {
        XCTAssertEqual(LocalLLMPipeline.validatedURL(from: nil), LocalLLMPipeline.defaultOllamaURL)
    }

    func testEmptyConfiguredURLUsesTheDefaultLoopbackAddress() {
        XCTAssertEqual(LocalLLMPipeline.validatedURL(from: ""), LocalLLMPipeline.defaultOllamaURL)
    }

    func testLoopbackHostnamesAreAccepted() {
        XCTAssertEqual(LocalLLMPipeline.validatedURL(from: "http://127.0.0.1:11434")?.host, "127.0.0.1")
        XCTAssertEqual(LocalLLMPipeline.validatedURL(from: "http://localhost:11434")?.host, "localhost")
        XCTAssertEqual(LocalLLMPipeline.validatedURL(from: "http://[::1]:11434")?.host, "::1")
    }

    func testHttpsToLoopbackIsAccepted() {
        XCTAssertNotNil(LocalLLMPipeline.validatedURL(from: "https://127.0.0.1:11434"))
    }

    func testRemoteHostIsRejectedNotSilentlyUsed() {
        // The exact failure this finding is about: a configured remote host must
        // never come back as "the" URL to use.
        XCTAssertNil(LocalLLMPipeline.validatedURL(from: "http://evil.example.com:11434"))
        XCTAssertNil(LocalLLMPipeline.validatedURL(from: "http://93.184.216.34:11434"))
    }

    func testNonHttpSchemeIsRejectedEvenToLoopback() {
        XCTAssertNil(LocalLLMPipeline.validatedURL(from: "ftp://127.0.0.1:11434"))
    }

    func testUnparsableStringIsRejected() {
        XCTAssertNil(LocalLLMPipeline.validatedURL(from: "not a url"))
    }

    func testLocalLLMPipelineUrlFormatting() async {
        let pipeline = LocalLLMPipeline(
            baseURL: URL(string: "http://127.0.0.1:59999")!,
            model: "llama3.2",
            timeout: 1
        )
        // Without an active Ollama server, request should fail gracefully as offline/unreachable
        let result = await pipeline.rewrite(transcript: "hello world test")
        switch result {
        case .failure(let error):
            XCTAssertTrue(error == .offline || error == .timedOut || error == .unreachable)
        case .success:
            XCTFail("Expected failure when no local LLM server is running")
        }
    }

    func testLocalLLMPipelineMockSessionSuccess() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockLocalLLMProtocol.self]
        let session = URLSession(configuration: config)

        MockLocalLLMProtocol.requestHandler = { request in
            let responseData = """
            {
              "response": "Hello World. This is a clean test."
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        let pipeline = LocalLLMPipeline(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "llama3.2",
            timeout: 5,
            session: session
        )

        let result = await pipeline.rewrite(transcript: "hello world this is a test")
        switch result {
        case .success(let rewritten):
            XCTAssertEqual(rewritten, "Hello World. This is a clean test.")
        case .failure(let error):
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLocalLLMPipelineEditSuccess() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockLocalLLMProtocol.self]
        let session = URLSession(configuration: config)

        MockLocalLLMProtocol.requestHandler = { request in
            let responseData = """
            {
              "response": "- Item 1\\n- Item 2"
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        let pipeline = LocalLLMPipeline(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "llama3.2",
            timeout: 5,
            session: session
        )

        let result = await pipeline.edit(instruction: "make bulleted", contextText: "Item 1 Item 2", contextTitle: "Notes")
        switch result {
        case .success(let edited):
            XCTAssertEqual(edited, "- Item 1\n- Item 2")
        case .failure(let error):
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class MockLocalLLMProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockLocalLLMProtocol.requestHandler else {
            XCTFail("Handler is not set.")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
