import XCTest
import HTMLKitErrorMiddleware
import HTMLKit
@testable import Vapor

class CapturingLogger: Logger, Service {

    var enabled: [LogLevel] = []

    private(set) var message: String?
    private(set) var logLevel: LogLevel?

    func log(_ string: String, at level: LogLevel, file: String, function: String, line: UInt, column: UInt) {
        self.message = string
        self.logLevel = level
    }
}

struct TestError: Error {}

class ThrowingViewRenderer: HTMLRenderable, Service {

    private(set) var pageType: String? = nil
    private(set) var capturedContext: Any? = nil
    var worker: Worker
    var shouldThrow = false

    init(worker: Worker) {
        self.worker = worker
    }

    func renderRaw<T>(_ type: T.Type, with context: T.Context) throws -> String where T : ContextualTemplate {

        self.capturedContext = context
        self.pageType = String(reflecting: type)
        if shouldThrow {
            throw TestError()
        }
        return "Test"
    }
}


class NotFoundPage: StaticView {

    func build() -> CompiledTemplate {
        return "Test"
    }
}

class ServerErrorTemplate: ContextualTemplate {

    typealias Context = HTTPStatus

    func build() -> CompiledTemplate {
        return "Test"
    }
}



class HTMLKitErrorMiddlewareTests: XCTestCase {

    // MARK: - All tests
    static var allTests = [
        ("testLinuxTestSuiteIncludesAllTests", testLinuxTestSuiteIncludesAllTests),
        ("testThatValidEndpointWorks", testThatValidEndpointWorks),
        ("testThatRequestingInvalidEndpointReturns404View", testThatRequestingInvalidEndpointReturns404View),
        ("testThatRequestingPageThatCausesAServerErrorReturnsServerErrorView", testThatRequestingPageThatCausesAServerErrorReturnsServerErrorView),
        ("testThatErrorGetsLogged", testThatErrorGetsLogged),
        ("testThatMiddlewareFallsBackIfViewRendererFails", testThatMiddlewareFallsBackIfViewRendererFails),
        ("testThatMiddlewareFallsBackIfViewRendererFailsFor404", testThatMiddlewareFallsBackIfViewRendererFailsFor404),
        ("testMessageLoggedIfRendererThrows", testMessageLoggedIfRendererThrows),
        ("testThatRandomErrorGetsReturnedAsServerError", testThatRandomErrorGetsReturnedAsServerError),
        ("testThatUnauthorisedIsPassedThroughToServerErrorPage", testThatUnauthorisedIsPassedThroughToServerErrorPage),
        ("testThatFuture404IsCaughtCorrectly", testThatFuture404IsCaughtCorrectly),
        ("testThatFuture403IsCaughtCorrectly", testThatFuture403IsCaughtCorrectly),
    ]

    // MARK: - Properties
    var app: Application!
    var viewRenderer: ThrowingViewRenderer!
    var logger: CapturingLogger!

    let notFoundPageReflection = String(reflecting: NotFoundPage.self)
    let serverErrorReflection = String(reflecting: ServerErrorTemplate.self)

    // MARK: - Overrides
    override func setUp() {
        var config = Config.default()
        var services = Services.default()

        let worker = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        viewRenderer = ThrowingViewRenderer(worker: worker)
        logger = CapturingLogger()

        services.register(viewRenderer, as: HTMLRenderable.self)

        services.register(Logger.self) { container -> CapturingLogger in
            return self.logger
        }

        config.prefer(CapturingLogger.self, for: Logger.self)

        func routes(_ router: Router) throws {

            router.get("ok") { req in
                return "ok"
            }

            router.get("serverError") { req -> Future<Response> in
                throw Abort(.internalServerError)
            }

            router.get("unknownError") { req -> Future<Response> in
                throw TestError()
            }

            router.get("unauthorized") { req -> Future<Response> in
                throw Abort(.unauthorized)
            }

            router.get("future404") { req -> Future<Response> in
                return req.future(error: Abort(.notFound))
            }

            router.get("future403") { req -> Future<Response> in
                return req.future(error: Abort(.forbidden))
            }
        }

        let router = EngineRouter.default()
        try! routes(router)
        services.register(router, as: Router.self)

        services.register { worker in
            return HTMLKitErrorMiddleware(
                notFoundPage: NotFoundPage.self,
                serverErrorTemplate: ServerErrorTemplate.self,
                environment: worker.environment
            )
        }

        var middlewares = MiddlewareConfig()
        middlewares.use(HTMLKitErrorMiddleware<NotFoundPage, ServerErrorTemplate>.self)
        services.register(middlewares)

        app = try! Application(config: config, services: services)
    }

    // MARK: - Tests
    func testLinuxTestSuiteIncludesAllTests() {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        let thisClass = type(of: self)
        let linuxCount = thisClass.allTests.count
        let darwinCount = Int(thisClass
            .defaultTestSuite.testCaseCount)
        XCTAssertEqual(linuxCount, darwinCount, "\(darwinCount - linuxCount) tests are missing from allTests")
        #endif
    }

    func testThatValidEndpointWorks() throws {
        let response = try app.getResponse(to: "/ok")
        XCTAssertEqual(response.http.status, .ok)
    }

    func testThatRequestingInvalidEndpointReturns404View() throws {
        let response = try app.getResponse(to: "/unknown")
        XCTAssertEqual(response.http.status, .notFound)
        XCTAssertEqual(viewRenderer.pageType, notFoundPageReflection)
    }

    func testThatRequestingPageThatCausesAServerErrorReturnsServerErrorView() throws {
        let response = try app.getResponse(to: "/serverError")
        XCTAssertEqual(response.http.status, .internalServerError)
        XCTAssertEqual(viewRenderer.pageType, serverErrorReflection)
    }

    func testThatErrorGetsLogged() throws {
        _ = try app.getResponse(to: "/serverError")
        XCTAssertNotNil(logger.message)
        XCTAssertEqual(logger.logLevel!, LogLevel.error)
    }

    func testThatMiddlewareFallsBackIfViewRendererFails() throws {
        viewRenderer.shouldThrow = true
        let response = try app.getResponse(to: "/serverError")
        XCTAssertEqual(response.http.status, .internalServerError)
        XCTAssertEqual(response.http.body.string, "<h1>Internal Error</h1><p>There was an internal error. Please try again later.</p>")
    }

    func testThatMiddlewareFallsBackIfViewRendererFailsFor404() throws {
        viewRenderer.shouldThrow = true
        let response = try app.getResponse(to: "/unknown")
        XCTAssertEqual(response.http.status, .notFound)
        XCTAssertEqual(response.http.body.string, "<h1>Internal Error</h1><p>There was an internal error. Please try again later.</p>")
    }

    func testMessageLoggedIfRendererThrows() throws {
        viewRenderer.shouldThrow = true
        _ = try app.getResponse(to: "/serverError")
        XCTAssertTrue(logger.message?.starts(with: "Failed to render custom error page") ?? false)
    }

    func testThatRandomErrorGetsReturnedAsServerError() throws {
        let response = try app.getResponse(to: "/unknownError")
        XCTAssertEqual(response.http.status, .internalServerError)
        XCTAssertEqual(viewRenderer.pageType, serverErrorReflection)
    }

    func testThatUnauthorisedIsPassedThroughToServerErrorPage() throws {
        let response = try app.getResponse(to: "/unauthorized")
        XCTAssertEqual(response.http.status, .unauthorized)
        XCTAssertEqual(viewRenderer.pageType, serverErrorReflection)
        guard let httpStatusContext = viewRenderer.capturedContext as? HTTPStatus else {
            XCTFail()
            return
        }
        XCTAssertEqual(httpStatusContext.code, 401)
        XCTAssertEqual(httpStatusContext.reasonPhrase, "Unauthorized")
    }

    func testThatFuture404IsCaughtCorrectly() throws {
        let response = try app.getResponse(to: "/future404")
        XCTAssertEqual(response.http.status, .notFound)
        XCTAssertEqual(viewRenderer.pageType, notFoundPageReflection)
    }

    func testThatFuture403IsCaughtCorrectly() throws {
        let response = try app.getResponse(to: "/future403")
        XCTAssertEqual(response.http.status, .forbidden)
        XCTAssertEqual(viewRenderer.pageType, serverErrorReflection)
    }
}

extension HTTPBody {
    var string: String {
        return String(data: data!, encoding: .utf8)!
    }
}

extension Application {
    func getResponse(to path: String) throws -> Response {
        let responder = try self.make(Responder.self)
        let request = HTTPRequest(method: .GET, url: URL(string: path)!)
        let wrappedRequest = Request(http: request, using: self)
        return try responder.respond(to: wrappedRequest).wait()
    }
}

extension LogLevel: Equatable {
    public static func == (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.description == rhs.description
    }
}
