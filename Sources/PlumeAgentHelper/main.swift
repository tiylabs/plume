import Foundation
import PlumeAgent
import PlumeKit

// plume-cli: the helper Plume ships inside its bundle. See `HelperCommand` for the commands and
// `AgentClient` for how it reaches the running app. stdout is protocol or result JSON only;
// everything else goes to stderr.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("plume-cli: " + message + "\n").utf8))
    exit(code)
}

let command: HelperCommand
do {
    command = try HelperCommand.parse(Array(CommandLine.arguments.dropFirst())) { path in
        if let path {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        return FileHandle.standardInput.readDataToEndOfFile()
    }
} catch let error as HelperCommand.UsageError {
    fail("\(error.description)\n\(HelperCommand.usage)", code: 2)
} catch {
    fail("cannot read the input: \(error.localizedDescription)", code: 2)
}

if command == .help {
    print(HelperCommand.usage)
    exit(0)
}

let location: AgentInstallLocation
do {
    location = try AgentInstallLocation.resolve(executablePath: AgentInstallLocation.currentExecutablePath())
} catch {
    fail(String(describing: error), code: 2)
}

if command == .version {
    print("plume-cli \(location.appVersion) (\(location.profile.displayName), api \(AgentAPI.apiVersion), ipc \(AgentAPI.ipcMajorVersion))")
    exit(0)
}

let token = ProcessInfo.processInfo.environment[AgentAPI.tokenEnvironmentKey]

switch command {
case .mcp:
    let stdout = FileHandle.standardOutput
    let writeLock = NSLock()
    // The client label is the MCP client's own name, once `initialize` has told us; until then the
    // generic one. It is a label shown in Plume's recent writes, not an identity.
    let client = AgentClient(location: location, token: token, clientLabel: "MCP client")
    let server = MCPServer(backend: client, serverVersion: location.appVersion) { line in
        writeLock.withLock { stdout.write(Data((line + "\n").utf8)) }
    }
    server.run()
    exit(0)
case .call(let tool, let params, let compact):
    let client = AgentClient(location: location, token: token, clientLabel: "plume-cli CLI")
    let status = HelperCommand.run(tool, params, compact: compact, backend: client) { print($0) }
    exit(status)
case .help, .version:
    exit(0)
}
