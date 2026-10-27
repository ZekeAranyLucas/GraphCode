import Foundation
import GraphcodeKit
import Testing

/// `graphcode workspaces`: the CLI's way to find the support directories that
/// `GRAPHCODE_SUPPORT_DIR` can point every other verb at.
@Suite
struct GraphcodeWorkspacesCommandTests {
  @Test
  func workspacesTakesNoArguments() throws {
    #expect(try GraphcodeCommand.parse(["workspaces"]) == .listWorkspaces)
    #expect(throws: GraphcodeCommand.ParseError.unknownOption("--json")) {
      try GraphcodeCommand.parse(["workspaces", "--json"])
    }
  }

  @Test
  func askingWorkspacesForHelpShowsHelp() throws {
    #expect(try GraphcodeCommand.parse(["workspaces", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["workspaces", "-h"]) == .help)
  }

  @Test
  func eachWorkspacePrintsItsNameAndPathWithTheCurrentOneMarked() {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    let main = Workspace(slug: "", url: home.appendingPathComponent(".graphcode"))
    let work = Workspace(slug: "work", url: home.appendingPathComponent(".graphcode-work"))

    #expect(
      GraphcodeCommand.render([main, work], current: work)
        == "  Default  /Users/me/.graphcode\n* work  /Users/me/.graphcode-work")
  }

  @Test
  func theHelpNamesTheVerb() {
    #expect(GraphcodeCommand.helpText.contains("graphcode workspaces"))
  }
}
