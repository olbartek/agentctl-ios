import AgentCtlCLI
import AgentShopCtl

// The whole host-side integration: AgentShop's config, handed to the CLI.
await AgentCtl.run(config: AgentShopConfig.appCtl)
