import Darwin
import Foundation
import Vapor

do {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = .warning
        return handler
    }
    let configuration = try Configuration(ProcessInfo.processInfo.environment)
    let backend = try Backend(configuration)
    let app = try await Application.make(.production)
    do {
        try configure(app, backend: backend, configuration: configuration)
        let server = app.http.server.shared
        let (signals, signal) = AsyncStream<Void>.makeStream()
        let sources = [SIGINT, SIGTERM].map { number in
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number)
            source.setEventHandler { signal.yield(); signal.finish() }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }

        let start: (BindAddress?) async throws -> Void = server.start(address:)
        try await start(.hostname("127.0.0.1", port: configuration.port))
        guard let port = server.localAddress?.port else {
            throw BackendError("SERVER_ADDRESS", "Unable to determine the listening port.")
        }
        let handshake = try JSONEncoder().encode(Handshake(url: "http://127.0.0.1:\(port)", token: configuration.token))
        FileHandle.standardOutput.write(handshake + Data([10]))
        for await _ in signals { break }
        let shutdown: () async -> Void = server.shutdown
        await shutdown()
        try await app.asyncShutdown()
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
} catch {
    FileHandle.standardError.write(Data(("twinsimd: " + error.localizedDescription + "\n").utf8))
    exit(EXIT_FAILURE)
}
