import FileWorkspace
import Foundation
import SwiftUI
import TerminalUI
#if HCG_UNLEASHED_BUILD
import UnleashedIntegration
#endif

@main
struct HCGTerminalApp: App {
    @State private var model = AppComposition.makeModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

/// Composition root. The standard target never compiles the Unleashed branch and does not
/// link the Unleashed modules (see docs/DISTRIBUTION.md).
@MainActor
enum AppComposition {
    static func makeModel() -> TerminalAppModel {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let supportDirectory = support.appendingPathComponent("HCGTerminal", isDirectory: true)
        let workspace: FileWorkspace
        do {
            workspace = try FileWorkspace.appContainerDefault()
        } catch {
            // Fall back to a temporary workspace rather than failing to launch.
            workspace = try! FileWorkspace(rootURL: fileManager.temporaryDirectory.appendingPathComponent("Workspace", isDirectory: true))
        }
        #if HCG_UNLEASHED_BUILD
        let dependencies = UnleashedIntegration.dependencies(workspace: workspace, supportDirectory: supportDirectory)
        #else
        let dependencies = AppDependencies.standard(workspace: workspace, supportDirectory: supportDirectory)
        #endif
        return TerminalAppModel(dependencies: dependencies)
    }
}
