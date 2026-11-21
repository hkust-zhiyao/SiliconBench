# Handle external resets during DMA operation

The reset manager's external-reset inputs are currently unused. Complete their handling for source, destination, and, when enabled, scatter-gather domains. Assertion must reset the affected domain immediately; release must be synchronized to that domain's clock. An external reset aborts the active DMA operation: stop admitting new requests, allow the other domains to acknowledge shutdown, then run the existing full reset sequence before restarting. A brief external reset must not be lost, and the manager must wait for every participating external reset to be released before restarting. Ignore the scatter-gather reset when that domain is disabled.

Preserve the existing enable, pause and reset sequencing when external resets stay released. The input clocks continue running throughout this sequence. The existing reset chain and enable/acknowledge interfaces provide the integration context.
