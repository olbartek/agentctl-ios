#if DEBUG || AGENTCTL_RELEASE
  import AgentCtlCLI
  import AgentShopCtl

  // The whole host-side integration: AgentShop's config, handed to the CLI.
  await AgentCtl.run(config: AgentShopConfig.appCtl)
#else
  // AgentCtl compiles out of release builds; the wrapper passes -DAGENTCTL_RELEASE when it builds in release.
  import Foundation

  FileHandle.standardError.write(Data("shopctl: built in release without -DAGENTCTL_RELEASE; build it in debug\n".utf8))
  exit(3)
#endif
