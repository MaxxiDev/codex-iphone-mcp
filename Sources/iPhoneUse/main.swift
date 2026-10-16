import Foundation

if CommandLine.arguments.dropFirst().first == "mcp" {
    MCPServer.run()
}

Application.run()
