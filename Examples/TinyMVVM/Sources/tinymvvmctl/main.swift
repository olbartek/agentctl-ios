#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AgentCtlCLI
  import TinyMVVM

  await AgentCtl.run(config: TinyMVVMConfig.appCtl)
#endif
