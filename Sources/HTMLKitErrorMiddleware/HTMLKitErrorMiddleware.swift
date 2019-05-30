import Vapor
import HTMLKit

/// Captures all errors and transforms them into an internal server error.
public final class HTMLKitErrorMiddleware<F: StaticView, S: ContextualTemplate>: Middleware, Service where S.Context == HTTPStatus {

    /// The environment to respect when presenting errors.
    let environment: Environment

    /// Create a new ErrorMiddleware for the supplied environment.
    public init(notFoundPage: F.Type, serverErrorTemplate: S.Type, environment: Environment) {
        self.environment = environment
    }

    /// See `Middleware.respond`
    public func respond(to req: Request, chainingTo next: Responder) throws -> Future<Response> {
        do {
            return try next.respond(to: req).flatMap(to: Response.self) { res in
                if res.http.status.code >= HTTPResponseStatus.badRequest.code {
                    return try self.handleError(for: req, status: res.http.status)
                } else {
                    return try res.encode(for: req)
                }
                }.catchFlatMap { error in
                    switch (error) {
                    case let abort as AbortError:
                        return try self.handleError(for: req, status: abort.status)
                    default:
                        return try self.handleError(for: req, status: .internalServerError)
                    }
            }
        } catch {
            return try handleError(for: req, status: HTTPStatus(error))
        }
    }

    private func handleError(for req: Request, status: HTTPStatus) throws -> Future<Response> {
        let renderer = try req.make(HTMLRenderable.self)

        if status == .notFound {
            do {
                return try renderer.render(F.self).encode(for: req).map(to: Response.self) { res in
                    res.http.status = status
                    return res
                    }.catchFlatMap { _ in
                        return try self.renderServerErrorPage(for: status, request: req, renderer: renderer)
                }
            } catch {
                return try renderServerErrorPage(for: status, request: req, renderer: renderer)
            }
        }

        return try renderServerErrorPage(for: status, request: req, renderer: renderer)
    }

    private func renderServerErrorPage(for status: HTTPStatus, request: Request, renderer: HTMLRenderable) throws -> Future<Response> {

        let logger = try request.make(Logger.self)
        logger.error("Internal server error. Status: \(status.code) - path: \(request.http.url)")

        do {
            return try renderer.render(S.self, with: status).encode(for: request).map(to: Response.self) { res in
                res.http.status = status
                return res
                }.catchFlatMap { error -> Future<Response> in
                    return try self.presentDefaultError(status: status, request: request, error: error)
            }
        } catch let error {
            return try presentDefaultError(status: status, request: request, error: error)
        }
    }

    private func presentDefaultError(status: HTTPStatus, request: Request, error: Error) throws -> Future<Response> {
        let body = "<h1>Internal Error</h1><p>There was an internal error. Please try again later.</p>"
        let logger = try request.make(Logger.self)
        logger.error("Failed to render custom error page - \(error)")
        return try body.encode(for: request)
            .map(to: Response.self) { res in
                res.http.status = status
                res.http.headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
                return res
        }
    }
}

extension HTTPStatus {
    internal init(_ error: Error) {
        if let abort = error as? AbortError {
            self = abort.status
        } else {
            self = .internalServerError
        }
    }
}
