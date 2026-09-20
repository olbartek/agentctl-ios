// TinyApp's CLI, and the shape of every host's: an import, the app's config, one call.
//
//   swift run tinyctl run "open 2; save"
//   swift run tinyctl test
//
// A host repo normally wraps this in a script that rebuilds the binary first, and sets that wrapper's
// spelling as `HelpExamples.invocation` so the help pages name the command its users actually run.
#if os(macOS)
  import AgentCtlCLI
  import TinyApp

  await AgentCtl.run(config: TinyAppConfig.appCtl)
#endif
