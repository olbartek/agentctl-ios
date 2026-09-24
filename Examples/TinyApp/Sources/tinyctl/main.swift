// TinyApp's CLI, and the shape of every host's: an import, the app's config, one call.
//
//   swift run tinyctl run "open 2; save"
//   swift run tinyctl test
//
// A host repo normally wraps this in a script that rebuilds the binary first, and sets that wrapper's
// spelling as `HelpExamples.invocation` so the help pages name the command its users actually run.
#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AgentCtlCLI
  import TinyApp

  await AgentCtl.run(config: TinyAppConfig.appCtl)
#elseif os(macOS)
  // AgentCtl compiles out of release builds (see Package.swift), so a release build of this CLI has nothing to
  // run. Build it in debug, or pass -Xswiftc -DAGENTCTL_RELEASE.
  import Foundation

  FileHandle.standardError.write(Data("tinyctl: built in release without -DAGENTCTL_RELEASE; build it in debug\n".utf8))
  exit(3)
#endif
