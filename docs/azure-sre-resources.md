# Azure SRE Agent — Reference Resources

Curated links Microsoft maintains for the Azure SRE Agent product. Use these to extend this showcase with additional patterns or to verify any approach against the official guidance.

## Primary product pages

| Resource | Link |
|---|---|
| Product home page | https://www.azure.com/sreagent |
| Documentation hub | https://sre.azure.com/docs/overview |
| Portal (create & manage agents) | https://sre.azure.com / https://aka.ms/sreagent |
| Pricing & billing | https://aka.ms/sreagent/pricing |
| Tech Community discussions | https://aka.ms/sreagent/discussions |
| GitHub — official community hub | https://github.com/microsoft/sre-agent |
| GitHub — official plugins | https://github.com/Azure/sre-agent-plugins |
| Hands-on lab repo | https://github.com/dm-chelupati/sre-agent-lab |

## Concepts we use in this showcase

| Concept | Microsoft doc | What we do |
|---|---|---|
| Custom agents (subagents) | https://sre.azure.com/docs/concepts/subagents | YAML specs in `sre-config/agents/` |
| Response plans | https://sre.azure.com/docs/capabilities/incident-response-plans | (planned) routes alerts → subagents |
| Connectors | https://sre.azure.com/docs/concepts/connectors | GitHub OAuth + Azure Monitor + LAW + App Insights |
| Memory & knowledge | https://sre.azure.com/docs/concepts/memory | `knowledge-base/*.md` uploaded via data plane |
| Skills (MCP) | https://sre.azure.com/docs/concepts/skills | (planned) MCP extensions for customer-specific tools |
| Incident platforms | https://sre.azure.com/docs/concepts/incident-platforms | AzMonitor (already wired on {YOUR_SRE_AGENT_NAME}) |
| Permissions | https://sre.azure.com/docs/tutorials/agent-config/manage-permissions | UAMI roles documented in `docs/runbook.md` |

## Post-GA blog posts worth incorporating

These are patterns Microsoft has published that we could add as future demos in this showcase:

| Blog post | Idea for this showcase |
|---|---|
| [Event-Driven IaC Operations: Terraform Drift Detection via HTTP Triggers](https://techcommunity.microsoft.com/blog/appsonazureblog/event-driven-iac-operations-with-azure-sre-agent-terraform-drift-detection-via-h/4512233) | Add a 5th scenario: a Terraform drift detector that triggers `{YOUR_SRE_AGENT_NAME}` when a `terraform plan` diff appears |
| [Multi-Tenant Azure Resources with SRE Agent and Lighthouse](https://techcommunity.microsoft.com/blog/appsonazureblog/managing-multi%E2%80%91tenant-azure-resource-with-sre-agent-and-lighthouse/4511789) | Add an YourOrg sub-tenant via Lighthouse so the agent monitors {CUSTOMER_RG} too |
| [Log Analytics + App Insights MCP-backed Connectors](https://techcommunity.microsoft.com/blog/appsonazureblog/new-in-azure-sre-agent-log-analytics-and-application-insights-connectors/4509649) | Wire the `YOUR_LOG_ANALYTICS_WS` LAW + `YOUR_APP_INSIGHTS` to `{YOUR_SRE_AGENT_NAME}` so it can correlate app failures with Azure infrastructure events |
| [Autonomous Alert Investigation + Intelligent Merging](https://techcommunity.microsoft.com/blog/appsonazureblog/azure-monitor-in-azure-sre-agent-autonomous-alert-investigation-and-intelligent-/4509069) | Configure an Azure Monitor alert on the storm scenario (CPU >80%); let the agent investigate end-to-end |
| [3 Ways to Get More from Azure SRE Agent](https://techcommunity.microsoft.com/blog/appsonazureblog/3-ways-to-get-more-from-azure-sre-agent/4508993) | Token-based billing tips, "new thread per scheduled run" pattern, push/batch over polling |
| [Customer Zero: How Microsoft Uses SRE Agent](https://techcommunity.microsoft.com/blog/appsonazureblog/how-we-build-and-use-azure-sre-agent-with-agentic-workflows/4508753) | Reference architecture for embedding agents across an SDLC |
| [GA Announcement](https://aka.ms/sreagent/ga) | Confirms 1,300+ Microsoft-internal agents, 35K+ incidents mitigated, 20K+ eng hours saved |
| [What's New in GA Release](https://aka.ms/sreagent/blog/whatsnewGA) | Code interpreter, memory, skills, subagents, Python tools, agent hooks, MCP connectors |
| [Agent Investigating Itself (SRE4SRE)](https://aka.ms/sreagent/blogs/sre4sre) | Inspirational use case: the agent does its own incident response |
| [Deep Context — Building Expertise](https://aka.ms/sreagent/blogs/deepcontextblog) | Background analysis that runs when nobody's asking — useful for daily morning-briefing patterns |
| [PagerDuty Incident Management](https://www.youtube.com/watch?v=5wrArcKzUaI) | Reference integration pattern for PagerDuty |
| [Agentic DevOps + GitHub Copilot Coding Agent](https://www.youtube.com/watch?v=ZrpxNkUQ0C8) | Demonstrates the SRE Agent handing off to GitHub Copilot for code fixes — complements our `code-analyzer` subagent |

## Key product capabilities (reference)

From https://sre.azure.com/docs/overview, four outcome categories:

1. **Autonomous Incident Response** — alerts → context + RCA + mitigation suggest/execute
2. **Lightning-fast Root Cause Analysis** — multi-signal correlation across logs, metrics, traces, deployments
3. **Extensible Automation with Built-in and MCP Connectors** — Teams, Outlook, PagerDuty, ServiceNow built-in; everything else via MCP
4. **Persistent Knowledge** — every investigation captured, learns team patterns, ramps new on-call

Built-in connectors today: Azure Monitor, Log Analytics, Application Insights, Microsoft Teams, Outlook, Azure Resource Graph, GitHub OAuth, PagerDuty, ServiceNow.

Built-in subagent tools today:
- `SearchMemory` — query the knowledge base
- `RunAzCliReadCommands` / `RunAzCliWriteCommands` / `GetAzCliHelp`
- `QueryLogAnalyticsByWorkspaceId` — KQL against a LAW
- `QueryAppInsightsByResourceId` — KQL against App Insights
- `ExecutePythonCode` — code interpreter for charts, calculations, file processing

## Pricing model

Per the [active flow billing blog](https://aka.ms/sreagent/pricing/blog):
- **Always-on**: 4 AAUs per agent-hour (unchanged)
- **Active flows**: token-based (was time-based), per-model-provider AAU rates
- See https://aka.ms/sreagent/pricing for current rates

This is relevant for budgeting demos at scale — the showcase scenarios consume minimal AAUs because the agent only runs during investigations, not continuously.

## Patterns we're NOT yet using (next-iteration ideas)

- **Response Plans** — automated routing from incident filter → subagent. Today the user has to invoke a subagent via `/agent` in chat. With response plans, an Azure Monitor alert on `ogedemo-storm-vmss` could automatically invoke `reliability-fixer` without human typing.
- **MCP servers** — extend with Slack, Jira, Datadog, or a custom MCP server that exposes domain-specific telemetry.
- **Scheduled tasks** — "daily morning briefing on {YOUR_RG}" matches the sister Cloud Weather Operations platform pattern.
- **Defender for Cloud integration** — pull security recommendations directly into `security-fixer`'s context.
- **Lighthouse multi-tenant** — let one `{YOUR_SRE_AGENT_NAME}` instance manage both {YOUR_RG} and a customer-side RG.
