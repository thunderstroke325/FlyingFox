//
//  HTTPServer.swift
//  FlyingFox
//
//  Created by Simon Whitty on 13/02/2022.
//  Copyright © 2022 Simon Whitty. All rights reserved.
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/swhitty/FlyingFox
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

public final actor HTTPServer {

    private let port: UInt16
    private let timeout: TimeInterval
    private var socket: AsyncSocket?
    private var handlers: [(route: HTTPRoute, handler: HTTPHandler)]

    public init(port: UInt16, timeout: TimeInterval = 15, handlers: [(route: HTTPRoute, handler: HTTPHandler)] = []) {
        self.port = port
        self.timeout = timeout
        self.handlers = []
    }

    public func appendHandler(for route: HTTPRoute, handler: HTTPHandler) {
        handlers.append((route, handler))
    }

    public func appendHandler(for route: HTTPRoute, closure: @escaping (HTTPRequest) async throws -> HTTPResponse) {
        handlers.append((route, ClosureHTTPHandler(closure)))
    }

    public func start() async throws {
        guard socket == nil else {
            throw Error("Already started")
        }

        let socket = try Socket()
        try socket.enableOption(.enableLocalAddressReuse)
        try socket.enableOption(.enableNoSIGPIPE)
        try socket.bindIP6(port: port)
        try socket.listen()

        let pool = PollingSocketPool()
        let asyncSocket = try AsyncSocket(socket: socket, pool: pool)
        self.socket = asyncSocket
        print("starting server port:", port)

        do {
            try await start(on: asyncSocket, pool: pool)
        } catch {
            print("server error: ", error.localizedDescription)
            try? asyncSocket.close()
            throw error
        }
    }

    private func start(on socket: AsyncSocket, pool: AsyncSocketPool) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await pool.run()
            }
            group.addTask {
                try await self.listenForConnections(on: socket)
            }
            try await group.waitForAll()
        }
    }

    private func listenForConnections(on socket: AsyncSocket) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for try await socket in socket.sockets {
                group.addTask {
                    try await self.handleConnection(HTTPConnection(socket: socket))
                }
            }
            group.cancelAll()
        }
    }

    func handleConnection(_ connection: HTTPConnection) async throws {
        print("open connection", connection.hostname)
        do {
            for try await request in connection.requests {
                let response = await handleRequest(request)
                try connection.sendResponse(response)
                guard response.shouldKeepAlive else { break }
            }
        } catch {
            print("connection error", error)
        }
        try connection.close()
        print("close connection", connection.hostname)
    }

    func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        var response = await handleRequest(request, timeout: timeout)
        if request.shouldKeepAlive {
            response.headers[.connection] = request.headers[.connection]
        }
        return response
    }

    func handleRequest(_ request: HTTPRequest, timeout: TimeInterval) async -> HTTPResponse {
        guard let handler = handlers.first(where: { $0.route ~= request })?.handler else {
            return HTTPResponse(statusCode: .notFound)
        }

        do {
            return try await withThrowingTimeout(seconds: timeout) {
                try await handler.handleRequest(request)
            }
        } catch {
            print("handler error", error)
            return HTTPResponse(statusCode: .serverError)
        }
    }
}

extension HTTPServer {

    struct Error: LocalizedError {
        var errorDescription: String?

        init(_ description: String) {
            self.errorDescription = description
        }
    }
}