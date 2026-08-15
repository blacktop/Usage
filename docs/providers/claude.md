# Claude credential contract

## Sources and precedence

| | |
|---|---|
| Credential file | `ROOT/.credentials.json` |
| Claude Code Keychain service | `Claude Code-credentials` for `HOME/.claude`; path-hashed suffix for custom roots |
| Usage Keychain service | `io.blacktop.Usage.claude-setup-token` |
| Usage Keychain account | stable configured-root ID |
| Owners | Claude Code owns the optional file and its own Keychain item; Usage owns only its setup-token item |
| Access | operation-scoped through `CredentialSource`; mutations only through explicit Settings actions |

Each enabled configured root is one independent account slot. Discovery resolves, in order: a
valid credential file; the newest row of Claude Code's own Keychain service (read-only,
attributes-only during discovery); a setup token saved against that root under Usage's own service.
The exact injected `HOME/.claude` root uses Claude Code's plain service; custom roots use the first
eight hex characters of the SHA-256 of their canonical path as a suffix. If no source is usable, an
existing but unusable file remains visible as the account's unavailable source. All three backends
share the root's logical slot, so an account keeps its history when its credential moves between
stores.

The plain `Claude Code-credentials` service is enumerated only for the exact default root. It is
never guessed for another configured directory, whose path-hashed service preserves root identity.

As a fallback when neither the file nor the Keychain item exists, create an inference-only token
with:

```fish
claude setup-token
```

Choose the intended Claude account in the browser, then paste the printed token into the key button
on that configured-root row. `setup-token` prints the token but does not save it; Usage stores it in
its own item only after that explicit action. Each root has an independent Keychain account.

### Fields read

| Source | Field | Use | Secret |
|---|---|---|---|
| Credential file | `claudeAiOauth.accessToken` | bearer token, resolved inside one fetch | yes |
| Credential file | `claudeAiOauth.subscriptionType` | plan label | no |
| Credential file | `claudeAiOauth.rateLimitTier` | plan label's `Max 20x` multiplier | no |
| Claude Code Keychain | same document shape as the credential file | bearer token and plan label, resolved inside one fetch | yes |
| Usage Keychain | setup token payload | bearer token, resolved inside one fetch | yes |

`expiresAt`, `refreshToken`, and `scopes` are not read from the credential file. The provider
response, rather than a local timestamp, is authoritative about whether its bearer remains
accepted.

### Passive reads must never raise UI

Usage-owned slot enumeration and Settings status checks return **attributes only** — no item data.
Both are forcibly wrapped in the file-Keychain no-UI suppression even when the Settings store also
permits an explicit write. Scheduled payload reads use `BackgroundInteractionPolicy` and fail
closed instead of raising an Allow/Deny or password dialog.

The setup-token payload is read only during fetch and remains inside the credential-scoped
operation. Discovery never reads it.

## What Usage never does

- Never **writes, updates, refreshes, or deletes** Claude Code's Keychain items. Reads are
  attributes-only during discovery and no-UI, fail-closed during scheduled fetches; the explicit
  Approve action is the only path that may raise the one Allow/Deny dialog.
- Never maps the plain `Claude Code-credentials` service to anything except the exact injected
  `HOME/.claude` root.
- Never writes `ROOT/.credentials.json`.
- Never persists a setup token outside Usage's own Keychain service, and never writes one without
  an explicit Save action.
- Never refreshes an OAuth token or calls `POST https://platform.claude.com/v1/oauth/token`.
- Never launches `claude` or opens a browser from a background refresh.
- Never shells out to `/usr/bin/security`.
- Never derives an identifier from a token. Account identity comes from the slot, not the secret.

## Requests

### Credential-file OAuth

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <claudeAiOauth.accessToken>
Accept: application/json
Content-Type: application/json
anthropic-beta: oauth-2025-04-20
User-Agent: claude-code/2.1.0
```

No query string, body, or `anthropic-version` header is sent.

### Gate results (sanitized)

Recorded 2026-08-14 from the working tree based on Usage commit `7ea2502` (Debug, stable
Apple Development identity), User-Agent `claude-code/2.1.0`. Output is the diagnostics' redacted
allowlist verbatim.

Post-fix Gate A (`--diagnose-claude-keychain`):

```
profile=1 match=yes status=0
profile=2 match=yes status=0
```

Pre-fix Gate B reproducer (`--diagnose-claude-usage --source claude-code`):

```
profile=1  source=claude-code credential=resolved http=401   (stale token; no recent CLI run)
profile=2  source=claude-code credential=resolved http=200 session=yes weekly=yes
```

The profile-1 401 is the failure that exposed the obsolete default-root hash lookup; it is not
post-fix success evidence. The corrected Gate A proves that the signed app now finds the default
root's plain service and the custom root's path-hashed service without reading credential payloads.
A post-fix Gate B additionally requires user-approved Keychain access and a live account request.
When authorized, a fresh Claude Code OAuth token read from either service decodes both plan windows
from `/api/oauth/usage`; a stale token answers 401, which production absorbs as rediscovery plus the
`claude` recovery instruction.

The **setup-token leg is deliberately unmeasured** (decision 2026-08-14): the owner does not use
setup tokens because the probe's header-derived report carries less information than the OAuth
usage response, and no token is saved on this host. The tier and the inference probe below remain
as implemented for a machine that has neither the file nor the Keychain item; the gate's fork —
delete the probe on a decodable 2xx, delete the tier on a measured 401/403 — reopens the moment a
setup token is actually saved and the diagnostic leg is run.

### Setup-token inference probe

```
POST https://api.anthropic.com/v1/messages
Authorization: Bearer <setup-token>
Accept: application/json
Content-Type: application/json
anthropic-beta: oauth-2025-04-20
anthropic-version: 2023-06-01
User-Agent: claude-code/2.1.0

{"model":"claude-haiku-4-5-20251001","max_tokens":1,
 "messages":[{"role":"user","content":"."}]}
```

The setup token has inference scope but not the `user:profile` scope required by
`/api/oauth/usage`. The minimal Messages request consumes a small amount of the account allowance
and returns unified 5-hour and 7-day utilization/reset headers. Setup-token reports are always
partial: they cannot expose model-specific limits or extra-usage credit.

## Mapping onto the shared model

For a setup token:

| Response header prefix | Window |
|---|---|
| `anthropic-ratelimit-unified-5h` | `plan:primary:session`, 5 h |
| `anthropic-ratelimit-unified-7d` | `plan:secondary:weekly`, 7 d |

A 429 carrying either window is still usable as a measurement. Authentication and other failures
remain errors even if they carry stale rate-limit headers.

For a credential file and `/api/oauth/usage`:

| Response | Window |
|---|---|
| `five_hour` | `plan:primary:session`, 5 h |
| `seven_day` | `plan:secondary:weekly`, 7 d |
| `seven_day_opus` / `seven_day_sonnet` | `additional:opus\|sonnet:primary:weekly` |
| `seven_day_oauth_apps` | `additional:oauth-apps:primary:weekly` |
| `seven_day_routines` | `additional:routines:primary:weekly` |
| `limits[]` where `group == "weekly"` and `kind == "weekly_scoped"` | `additional:<model-slug>:primary:weekly` |
| `extra_usage` | `CreditBalance` |

`utilization` and `percent` in the JSON response are percentages in `0…100`; they are divided by
100 and values above 1 are preserved as real over-quota states.

`extra_usage` amounts are minor units and are divided by 100 into major units. Currency defaults to
`USD` when unstated. Only `USD` and `EUR` have been observed.

**`is_active` is deliberately not read.** Enforceable scoped limits have been observed reporting
`false`, so filtering on it silently drops real limits.

An `all models` scope is skipped because it restates the plan's weekly window and would
double-count. Only `seven_day_routines` is decoded; historical aliases remain intentionally
unsupported.

## Account identity

The OAuth paths expose no non-secret canonical account identifier. Claude accounts therefore stay
slot-scoped: `AccountID.credentialSlot(provider:slot:)` is derived from the configured root's
credential-document path, independent of whether the payload comes from that file or its
root-specific Usage-owned setup-token item.

Hashing a token to derive identity is forbidden. A digest of a live secret is still secret-derived
material and would persist into history.

## Expired or missing credential

| Signal | Result |
|---|---|
| `expiresAt` in the past, or absent | ignored; the request is still sent |
| HTTP 401 or 403 | `.authenticationExpired` |
| HTTP 429 without usable unified headers | `.rateLimited`, honouring `Retry-After` |
| No `claudeAiOauth` in a credential file | `.credentialUnavailable` |
| Usage Keychain access denied or interaction required | `.interactionRequired`, no retry, no prompt |

An HTTP 429 is presented as an OAuth usage-endpoint error, not as proof that the account's Claude
quota is exhausted. Scheduled refreshes retain their account-scoped cooldown; the UI does not offer
a manual retry that could immediately repeat the rejected request.

An `mcpOAuth`-only document is a real Claude Code state, not corruption: the CLI has MCP server
tokens but no subscription login. It reports as a missing credential rather than a malformed file.

Rate-limit cooldowns are account-scoped and keyed on `AccountKey`, never on the secret.

## Keychain host behavior

Usage's setup-token payload access remains a per-host capability. Scheduled refreshes use the
background no-UI policy and fail closed rather than raising a password or Allow/Deny dialog.
Because Usage creates and reads its own item under a stable signing identity, Claude Code token
rotation and ACL rewrites no longer affect it.

The historical probe in [`../keychain-gate.md`](../keychain-gate.md) remains available only as an
explicit diagnostic of Claude Code's retired service; no ordinary provider path calls it.
