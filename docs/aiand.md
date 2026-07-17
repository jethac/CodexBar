---
summary: "ai& provider: API key setup and 30-day spend from the analytics summary API."
read_when:
  - Configuring ai& usage
  - Debugging ai& analytics requests
---

# ai& Provider

CodexBar reads organization spend from ai&'s documented analytics API. ai& (aiand.com) is an OpenAI/Anthropic-compatible
inference gateway that can back Claude Code, Codex CLI, and opencode (all three have dedicated integration guides in
the ai& docs).

## Authentication

Create an API key in the [ai& console](https://console.aiand.com) (Settings → API Keys → Create). Keys use the `sk-`
prefix and are shown once at creation time. Add the key in CodexBar Settings → Providers → ai&.

You can also set the environment variable:

```bash
export AIAND_API_KEY="..."
```

Or configure it through the CLI:

```bash
printf '%s' "$AIAND_API_KEY" | codexbar config set-api-key --provider aiand --stdin
```

## Data Source

CodexBar requests:

- `GET https://api.aiand.com/analytics/summary?range=30days`

The request uses `Authorization: Bearer <AIAND_API_KEY>`. CodexBar does not read ai& browser cookies, console sessions,
request logs, or inference prompts.

## Display

The menu shows the last 30 days of organization spend in US dollars as an API-spend row. ai& bills prepaid credits with
no quota windows, so no session or weekly meters are shown. The remaining credit balance is only available in the ai&
console; the public API does not expose it.

Notes:

- ai& caches analytics responses server-side for 120 seconds, so the number can lag up to two minutes.
- API keys are organization-scoped: every key in the same organization reports the same org-wide spend.

## CLI Usage

```bash
codexbar usage --provider aiand
```

`ai&` and `ai-and` also work as provider aliases.

## Troubleshooting

- A `401` means ai& rejected the API key; create a new key in the console (keys are shown only once).
- A `402` means the organization is out of prepaid credits; top up at console.aiand.com.
- A `429` means the per-minute rate limit was hit; CodexBar retries on the next refresh cycle.

## Sources

- [Analytics Summary](https://docs.aiand.com/analytics/summary/)
- [Authentication](https://docs.aiand.com/authentication/)
- [Credits & Top-Up](https://docs.aiand.com/billing/credits/)
