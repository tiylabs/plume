import Darwin
import Foundation
import PlumeAgent
import PlumeKit

/// The socket, the handshake and the helper's client, in one process: a server over a temporary
/// runtime directory and an `AgentClient` pointed at it.
@MainActor
func runAgentIPCTests() {

    /// Runs `body` on a background thread while the main run loop turns — the server answers
    /// requests on the main actor, so a client blocking the main thread would wait forever.
    @MainActor
    func offMain<T: Sendable>(timeout: TimeInterval = 15, _ body: @escaping @Sendable () -> T) -> T {
        let box = OffMainBox<T>()
        Thread { box.value = body() }.start()
        let deadline = Date().addingTimeInterval(timeout)
        while box.value == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard let value = box.value else { fatalError("background body did not finish") }
        return value
    }

    final class Launches: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func record() { lock.withLock { count += 1 } }
    }

    struct Fixture {
        let runtime: AgentRuntimeDirectory
        let location: AgentInstallLocation
        let server: AgentSocketServer

        func client(token: String? = "secret", launcher: @escaping AgentClient.Launcher = { _ in false }) -> AgentClient {
            AgentClient(location: location, runtime: runtime, token: token, clientLabel: "test", launcher: launcher)
        }
    }

    func fixture(instance: String? = nil, start: Bool = true, permission: AgentPermission = .readWrite) -> Fixture {
        let short = String(UUID().uuidString.prefix(8))
        let runtime = AgentRuntimeDirectory(directory: AgentRuntimeDirectory.userTemporaryDirectory().appendingPathComponent("pat-\(short)"))
        let bundle = URL(fileURLWithPath: "/Applications/Plume Dev \(short).app")
        let location = AgentInstallLocation(appBundle: bundle, profile: .dev, appVersion: "1.0")
        let server = AgentSocketServer(runtime: runtime, identity: .init(
            profile: .dev, instance: instance ?? location.instance, appVersion: "1.0", bundlePath: bundle.path
        ))
        server.authenticate = { token in
            guard permission != .off else { return .failure(AgentFailure(.accessDisabled, "off")) }
            guard AgentAccessStore.matches(token, "secret") else { return .failure(AgentFailure(.authFailed, "bad")) }
            return .success(.init(permission: permission, generation: "g1"))
        }
        server.onRequest = { client, _, method, params, reply in
            if method == "create_note" {
                // Slow on purpose, so a test can take the app away while the write is in flight.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { reply(.success(.object(["slow": .bool(true)]))) }
            } else {
                reply(.success(.object(["method": .string(method), "params": params, "generation": .string(client.generation)])))
            }
        }
        if start {
            try! server.start()
            server.readiness = .ready
        }
        return Fixture(runtime: runtime, location: location, server: server)
    }

    func code(_ body: () throws -> Void) -> AgentErrorCode? {
        do { try body(); return nil } catch let f as AgentFailure { return f.code } catch { return nil }
    }

    Check.mainSuite("Agent IPC · socket and handshake") {

        Check.mainTest("the runtime directory is private, short, and from confstr") {
            let f = fixture()
            defer { f.server.stop() }
            let mode = (try! FileManager.default.attributesOfItem(atPath: f.runtime.directory.path)[.posixPermissions] as! NSNumber).intValue
            Check.equal(mode & 0o777, 0o700)
            let socketMode = (try! FileManager.default.attributesOfItem(atPath: f.runtime.socketURL.path)[.posixPermissions] as! NSNumber).intValue
            Check.equal(socketMode & 0o777, 0o600)
            Check.equal(f.runtime.socketStatus(), .ours)
            let standard = AgentRuntimeDirectory.standard(profile: .release)
            Check.expect(standard.socketURL.path.utf8.count < 104, "socket path must fit sun_path: \(standard.socketURL.path)")
            Check.notEqual(standard, AgentRuntimeDirectory.standard(profile: .dev), "release and dev never share a socket")
            Check.expect(!standard.directory.path.contains("Application Support"))
        }

        Check.mainTest("one owner per profile; a stale socket is replaced, a foreign file is not") {
            let f = fixture()
            let second = AgentSocketServer(runtime: f.runtime, identity: f.server.identity)
            do { try second.start(); Check.expect(false, "second owner started") } catch let e as AgentSocketServer.StartError {
                Check.equal(e, .ownedElsewhere)
            } catch {}
            f.server.stop()
            // A crashed run leaves its socket file; the next owner clears it.
            let fd = try! IPCSocket.listen(at: f.runtime.socketURL)
            close(fd)
            Check.equal(f.runtime.socketStatus(), .ours)
            try! second.start()
            Check.equal(second.isRunning, true)
            second.stop()
            try! Data("not a socket".utf8).write(to: f.runtime.socketURL)
            do { try second.start(); Check.expect(false) } catch let e as AgentSocketServer.StartError {
                Check.equal(e, .pathOccupied)
            } catch {}
        }

        Check.mainTest("no credential: AUTH_FAILED at once, and the app is not launched") {
            let f = fixture(start: false)
            let launches = Launches()
            let client = f.client(token: nil) { _ in launches.record(); return true }
            Check.equal(code { try client.connect() }, .authFailed)
            Check.equal(launches.value, 0)
        }

        Check.mainTest("app not running: launched once in the background; refusal until the deadline is CONNECTION_BLOCKED") {
            let f = fixture(start: false)
            let launches = Launches()
            let refused = f.client { _ in launches.record(); return false }
            Check.equal(code { try refused.connect() }, .connectionBlocked)
            Check.expect(launches.value > 1, "a refused launch is retried before giving up")

            // LaunchServices refuses `open -g` for a moment after the app exits (-600); a refusal
            // followed by a launch that works must connect, launching exactly once successfully.
            let flaky = Launches()
            let server = f.server
            let retried = f.client { _ in
                flaky.record()
                guard flaky.value >= 3 else { return false }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    try? server.start()
                    server.readiness = .ready
                }
                return true
            }
            Check.equal(offMain { try? retried.connect() }, .readWrite)
            Check.equal(flaky.value, 3)
            f.server.stop()

            // The launcher "starts the app": the client waits for it to come up.
            let starting = f.client { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    try? server.start()
                    server.readiness = .ready
                }
                return true
            }
            let permission = offMain { try? starting.connect() }
            Check.equal(permission, .readWrite)
            f.server.stop()
        }

        Check.mainTest("wrong credential, access off, another installed copy, vault missing, still starting") {
            let f = fixture()
            Check.equal(code { try f.client(token: "wrong").connect() }, .authFailed)
            f.server.stop()

            let off = fixture(permission: .off)
            Check.equal(code { try off.client().connect() }, .accessDisabled)
            off.server.stop()

            let other = fixture(instance: "someone-else")
            let failure = (try? other.client().connect()) == nil
            Check.expect(failure)
            Check.equal(code { try other.client().connect() }, .appInstanceMismatch)
            other.server.stop()

            let missing = fixture()
            missing.server.readiness = .vaultUnavailable
            let started = Date()
            Check.equal(code { try missing.client().connect() }, .vaultUnavailable)
            Check.expect(Date().timeIntervalSince(started) < 1, "the helper hears it at once, not after a timeout")
            missing.server.stop()

            let starting = fixture()
            starting.server.readiness = .starting
            let launches = Launches()
            Check.equal(code { try starting.client { _ in launches.record(); return true }.connect() }, .appNotReady)
            Check.equal(launches.value, 0, "a running app is not launched again")
            starting.server.stop()
        }

        Check.mainTest("strict frames: wrong IPC major, malformed JSON and oversized frames are refused") {
            let f = fixture()
            defer { f.server.stop() }
            func handshakeReply(_ data: Data, raw: Bool = false) -> IPCMessage? {
                guard case .success(let socket) = IPCSocket.connect(to: f.runtime.socketURL) else { return nil }
                if raw {
                    _ = data.withUnsafeBytes { send(socket.fd, $0.baseAddress!, data.count, 0) }
                } else {
                    try? socket.writeFrame(data)
                }
                guard let frame = try? socket.readFrame(timeout: 2) else { return nil }
                return try? IPCMessage.decode(frame)
            }
            var hello = IPCMessage.hello(profile: "dev", instance: f.location.instance, appVersion: "1", token: "secret", clientLabel: nil)
            hello.ipcMajor = 99
            Check.equal(handshakeReply(try! AgentJSON.encoder.encode(hello))?.error?.code, .protocolMismatch)
            Check.equal(handshakeReply(Data("{not json".utf8))?.error?.code, .protocolMismatch)
            var huge = UInt32(AgentLimits.ipcMaxFrameBytes + 1).bigEndian
            Check.equal(handshakeReply(Data(bytes: &huge, count: 4), raw: true)?.error?.code, .protocolMismatch)
        }

        Check.mainTest("requests are multiplexed, permission changes are pushed, a lost app fails the waiters") {
            let f = fixture()
            let client = f.client()
            final class Seen: @unchecked Sendable { var permission: AgentPermission? }
            let seen = Seen()
            client.onPermissionChanged = { seen.permission = $0 }
            let results = offMain { () -> [String] in
                let group = DispatchGroup()
                let out = OffMainBox<[String]>()
                out.value = []
                let lock = NSLock()
                for i in 0..<5 {
                    group.enter()
                    DispatchQueue.global().async {
                        let value = try? client.call(.searchNotes, params: .object(["query": .string("q\(i)")]), timeout: 5, id: nil)
                        lock.withLock { out.value?.append(value?["params"]?["query"]?.stringValue ?? "fail") }
                        group.leave()
                    }
                }
                group.wait()
                return (out.value ?? []).sorted()
            }
            Check.equal(results, ["q0", "q1", "q2", "q3", "q4"])
            f.server.broadcast(.permissionChanged(.readOnly))
            _ = offMain { Thread.sleep(forTimeInterval: 0.2); return true }
            Check.equal(seen.permission, .readOnly)
            Check.equal(client.permission, .readOnly)

            // The app goes away mid-request: the caller is told, and told to check its write.
            let lost = offMain { () -> AgentFailure? in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { f.server.stop() }
                do {
                    _ = try client.call(.createNote, params: .object(["request_id": .string("abc")]), timeout: 5, id: nil)
                    return nil
                } catch { return error as? AgentFailure }
            }
            Check.equal(lost?.code, .requestTimeout)
        }

        Check.mainTest("a write that times out says it may have been saved and names its request") {
            let failure = AgentClientProbe.timedOut(.createNote, ["request_id": "r-1"])
            Check.equal(failure.code, .requestTimeout)
            Check.equal(failure.requestID, "r-1")
            Check.expect(failure.message.contains("get_operation"))
            Check.equal(AgentClient.timeout(for: .readNote, params: .object(["download": .bool(true)])), AgentLimits.downloadTimeout)
            Check.equal(AgentClient.timeout(for: .readNote, params: .object([:])), AgentLimits.requestTimeout)
        }

        Check.mainTest("end to end: client → socket → handler → vault, and back") {
            let f = fixture(start: false)
            let rig = AgentRig()
            let handler = rig.handler!
            let generation = rig.access.access.generation
            f.server.authenticate = { _ in .success(.init(permission: .readWrite, generation: generation)) }
            f.server.onRequest = { client, _, method, params, reply in
                DispatchQueue.main.async {
                    _ = MainActor.assumeIsolated {
                        Task { @MainActor in
                            reply(await handler.handle(method: method, params: params, caller: .init(generation: client.generation, clientLabel: client.clientLabel)))
                        }
                    }
                }
            }
            try! f.server.start()
            f.server.readiness = .ready
            defer { f.server.stop() }
            let client = f.client()
            let id = uuid()
            let created = offMain { try? client.call(.createNote, params: .object(["markdown": .string("# Over the socket\n"), "request_id": .string(id)]), timeout: 5, id: nil) }
            let write = try? created?.decode(WriteResult.self)
            Check.equal(write?.state, .saved)
            Check.equal(rig.noteFiles.count, 1)
            let status = offMain { try? client.call(.getOperation, params: .object(["request_id": .string(id)]), timeout: 5, id: nil) }
            Check.equal(status?["state"]?.stringValue, "saved")
            Check.equal(rig.journal.all().first?.clientLabel, "test")
        }
    }

    Check.suite("Agent helper · install location") {

        func bundle(_ identifier: String?, scratch: Bool = false) -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)")
            let app = root.appendingPathComponent("Plume Dev.app")
            let macOS = app.appendingPathComponent("Contents/MacOS")
            try! FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            var plist: [String: Any] = ["CFBundleShortVersionString": "0.6.0"]
            if let identifier { plist["CFBundleIdentifier"] = identifier }
            if scratch { plist[BuildProfile.infoKey] = true }
            try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            try! Data("#!/bin/sh\n".utf8).write(to: macOS.appendingPathComponent("plume-agent"))
            return app
        }
        func helper(_ app: URL) -> String { app.appendingPathComponent("Contents/MacOS/plume-agent").path }

        Check.test("the app's own Info.plist decides the profile") {
            Check.equal(try? AgentInstallLocation.resolve(executablePath: helper(bundle("com.tiylabs.plume"))).profile, .release)
            Check.equal(try? AgentInstallLocation.resolve(executablePath: helper(bundle("com.tiylabs.plume.dev"))).profile, .dev)
            Check.equal(try? AgentInstallLocation.resolve(executablePath: helper(bundle("com.tiylabs.plume", scratch: true))).profile, .dev)
            Check.equal(try? AgentInstallLocation.resolve(executablePath: helper(bundle("com.tiylabs.plume"))).appVersion, "0.6.0")
        }

        Check.test("an unknown or missing identifier is refused, never read as release") {
            for identifier in [nil, "com.example.other"] {
                do {
                    _ = try AgentInstallLocation.resolve(executablePath: helper(bundle(identifier)))
                    Check.expect(false, "accepted \(identifier ?? "nil")")
                } catch let problem as AgentInstallLocation.Problem {
                    if case .unknownBundle = problem {} else { Check.expect(false, "\(problem)") }
                } catch {}
            }
        }

        Check.test("outside a bundle it refuses; through a symlink it resolves to the bundle") {
            let loose = FileManager.default.temporaryDirectory.appendingPathComponent("loose-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
            let copy = loose.appendingPathComponent("plume-agent")
            try! Data().write(to: copy)
            do {
                _ = try AgentInstallLocation.resolve(executablePath: copy.path)
                Check.expect(false, "a loose binary must not run")
            } catch let problem as AgentInstallLocation.Problem {
                if case .notInAppBundle = problem {} else { Check.expect(false) }
            } catch {}

            let app = bundle("com.tiylabs.plume.dev")
            let link = loose.appendingPathComponent("linked-plume-agent")
            try! FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: helper(app))
            let resolved = try? AgentInstallLocation.resolve(executablePath: link.path)
            Check.equal(resolved?.profile, .dev)
            Check.equal(resolved?.appBundle.lastPathComponent, "Plume Dev.app")

            let wrongLink = app.appendingPathComponent("Contents/MacOS/plume-agent-link")
            try! FileManager.default.createSymbolicLink(atPath: wrongLink.path, withDestinationPath: copy.path)
            Check.expect((try? AgentInstallLocation.resolve(executablePath: wrongLink.path)) == nil, "a link inside a bundle to a loose copy is still loose")
        }

        Check.test("translocated paths are impermanent; instances differ per installed copy") {
            Check.equal(AgentInstallLocation.impermanence(of: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Plume.app")), .translocated)
            Check.equal(AgentInstallLocation.impermanence(of: FileManager.default.temporaryDirectory), nil)
            Check.notEqual(AgentInstance.identifier(bundleURL: URL(fileURLWithPath: "/Applications/Plume.app")),
                           AgentInstance.identifier(bundleURL: URL(fileURLWithPath: "/Users/x/Downloads/Plume.app")))
        }
    }
}

final class OffMainBox<T>: @unchecked Sendable {
    var value: T?
}

/// Reaches the client's internal timeout wording.
enum AgentClientProbe {
    static func timedOut(_ tool: AgentTool, _ params: [String: String]) -> AgentFailure {
        AgentClient.describeTimeout(tool, params: .object(params.mapValues(JSONValue.string)))
    }
}
