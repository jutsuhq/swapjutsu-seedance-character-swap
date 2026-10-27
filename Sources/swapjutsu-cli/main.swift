import Foundation
import SwapjutsuMCP

// The binary agents run, bundled at Swapjutsu.app/Contents/Helpers/swapjutsu (project.yml). Not sandboxed: it drives
// the sandboxed app through the agent socket in their shared app group container.

let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
let location = AppConnection.locate(
    executable: executable, environment: ProcessInfo.processInfo.environment, home: .homeDirectory)
var version = "development"
if case .bundled(let app, _, _) = location,
    let bundled = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
{
    version = bundled
}

let usage = """
    Usage: swapjutsu mcp
           swapjutsu --help | --version

    Drives the Swapjutsu app from an agent.

      mcp         A Model Context Protocol server on stdin and stdout, with the tools
                  capabilities, show, prepare, clips, set_characters, prepare_again,
                  quote, render, finalize, job_action, library_search and frames. Add it to
                  Claude Code with:
                    claude mcp add swapjutsu -- /Applications/Swapjutsu.app/Contents/Helpers/swapjutsu mcp
      --version   The version of the app this binary is bundled in.
      -h, --help  Show this help.

    The app answers only while Settings › Agents › Allow agents is on. When it isn't
    running, the first call starts it in the background.

    Environment:
      \(AppConnection.socketVariable)  The socket to use instead of the bundled app's, for
                              development. Unbundled, this binary uses the socket of
                              `.build/debug/Swapjutsu -allowAgents YES`.
    """

switch CommandLine.arguments.dropFirst().first {
case "mcp":
    let connection = AppConnection(location: location)
    var server = MCPServer(version: version, stage: connection.stage(_:name:folder:)) {
        await connection.send($0)
    }
    // One JSON-RPC message per line until the client closes stdin.
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty, let reply = await server.reply(to: Data(line.utf8)) else { continue }
        FileHandle.standardOutput.write(reply)
    }
case "-h", "--help":
    FileHandle.standardOutput.write(Data((usage + "\n").utf8))
case "--version":
    FileHandle.standardOutput.write(Data((version + "\n").utf8))
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}
