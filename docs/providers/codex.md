# Codex — read-only credential contract

## What Usage reads

| | |
|---|---|
| Credential | `ROOT/auth.json`, or the root-scoped direct Keychain row |
| Owner | the `codex` CLI |
| Access | read-only, through the injected `ProviderFileSystem` and `CredentialSource` |
| Keychain | service `Codex Auth`, account `cli\|<first 16 hex of SHA-256(canonical ROOT)>` |

The file locator is
`CredentialLocator(kind: .file, identifier: "ROOT/auth.json", path: ["tokens", "access_token"])`.
The Keychain locator carries the enumerated row's persistent reference and the same JSON path. A
locator names where the bearer token lives; it never carries the token. Roots come only from the
shared configured-root store.

### Root-scoped Keychain lookup

Codex's direct Keychain backend serializes the same `auth.json` document into a generic-password
item. Its account attribute is derived from the canonical `CODEX_HOME`, which lets Usage match an
enumerated row to one configured root without reading the payload. A file takes precedence when it
exists; Usage enumerates the service only when at least one configured root has no file.

Discovery returns attributes and a persistent reference only. During fetch, the payload is parsed
inside the credential-scoped operation so `tokens.account_id` still addresses the correct ChatGPT
workspace. Tests pin the root hash, multi-root matching, file precedence, discovery-without-payload,
and the scoped parse.

### Fields read

| JSON path | Use | Secret |
|---|---|---|
| `tokens.access_token` | bearer token, resolved inside one fetch | yes |
| `tokens.refresh_token` | presence only — proves this is an OAuth login | yes |
| `tokens.account_id` | `ChatGPT-Account-Id` header, canonical `AccountID` input | no |
| `tokens.id_token` | claim source for the account id, plan, and display email | mixed |
| `last_refresh` | staleness hint only | no |

Everything else in the file — including `auth_mode` and `OPENAI_API_KEY` — is ignored.

**`OPENAI_API_KEY` is deliberately not honoured.** The Codex CLI's own parser returns the API key
before it looks at `tokens`, but an API key is not a valid bearer for the usage endpoint, so
accepting one turns "signed in with an API key" into a 401 that reads like an expired login. A file
holding only an API key is reported as a discovered but `.unavailable` account.

The `id_token` payload is base64url-decoded and read. **Its signature is never verified**, and must
not be: this is a local read of a file the user already owns, used to label an account — not an
authorization decision.

## What Usage never does

- Never writes, replaces, truncates, or `chmod`s `auth.json`. `ProviderFileSystem` has no write
  member, so the capability does not exist to be misused.
- Never creates, updates, or deletes a `Codex Auth` Keychain item.
- Never calls `POST https://auth.openai.com/oauth/token`. Refreshing means rewriting `auth.json`,
  and atomic replacement alone cannot prevent a lost update against a concurrently running Codex
  CLI.
- Never launches the `codex` binary.
- Never copies the token anywhere. It is resolved inside one `withCredential` scope, stamped onto
  the outbound request, and discarded. It never reaches `ProviderAccount`, the store, the
  coordinator, history, or a log.

## Request

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <tokens.access_token>
Accept: application/json
User-Agent: Usage/<version>
ChatGPT-Account-Id: <tokens.account_id>      # omitted entirely when unknown
```

No query string, no body.

`ChatGPT-Account-Id` is omitted rather than sent empty when no account id can be resolved. Whether
the server then infers a default account is unverified; for a user in several ChatGPT workspaces
that is the difference between correct and silently-wrong numbers.

**Divergence from the plan.** The plan lists `OpenAI-Beta: codex-1` and `originator: Codex Desktop`
on this request. The reference sends neither here — they belong to the reset-credits route. Whether
the usage route requires, ignores, or rejects them cannot be settled without a live probe, so the
known-working header set is sent.

## Mapping onto the shared model

| Response | Window |
|---|---|
| `rate_limit.primary_window` / `secondary_window` | `plan:primary:session` / `plan:secondary:weekly` |
| `additional_rate_limits[].rate_limit.*_window` | `additional:<feature>:<slot>:<period>` |
| `credits.balance` | `CreditBalance.remaining`, provider-defined unit |
| `plan_type` | `UsageReport.plan`, verbatim |

Window role follows the window **length**, not its position: a `free` plan sends its weekly window
in `primary_window` with no secondary. Classification is tolerant — up to a day is a session, six
days or more is weekly — and an unclassifiable pair keeps the payload's own ordering rather than
guessing.

`reset_at == 0` and `limit_window_seconds == 0` mean "not stated" and become `nil`, not
1970-01-01 and not a zero-length window.

`individual_limit` is **not** mapped. It appears at two nesting levels, in two spellings, and
nothing in the payload states whether it is a monthly spend cap, an org per-seat cap, or something
else. Rendering a guess is worse than omitting it.

## Expired or missing credential

| Signal | Result |
|---|---|
| HTTP 401 or 403 | `.authenticationExpired`, carrying `codex login` |
| `auth.json` absent | the matching root-scoped Keychain account is consulted |
| `auth.json` present without OAuth tokens | account discovered, `.unavailable` |
| credential no longer resolvable at fetch time | `.credentialUnavailable`, carrying `codex login` |
| HTTP 429 | `.rateLimited`, honouring `Retry-After` in both delta-seconds and HTTP-date form |
| transport failure | `.network`, with **no** sign-in instruction |

**Action the user takes**, carried on the error as `ReauthAction` and rendered by both the app and
the CLI:

> Sign in to Codex again, then refresh. Run: `codex login`

It is attached only to `.authenticationExpired` and `.credentialUnavailable`. A rate limit, an
offline machine, and an unreadable response are left alone — telling someone to sign in again when
the network is down sends them to fix the wrong thing.

Usage performs no remediation. A 401/403 is not retried — it is not transient. Rate-limit cooldowns
are **account-scoped**: nothing in the reference or in the endpoint's shape is evidence that
`wham/usage` throttling is shared across accounts, and the plan's default without positive evidence
is account scope.

## CLI surface

`usage list` renders one row per window plus a credits table; `usage json` emits the versioned
`UsageOutputV1` envelope, where a failure carries `reauth.summary` and `reauth.command`. Neither
prints a credential path: an account with no provider-supplied display label is shown as the first
twelve hex digits of its identity digest.

Exit status is the collection outcome — `0` every requested provider answered, `2` some did, `1`
none did. An unknown `--provider` is an argument error and uses swift-argument-parser's own exit.

## Known risks

- The endpoint is undocumented and unversioned. Every field is optional and every array is
  per-element lossy, so a shape change degrades to a partial report rather than a failure.
- `plan_type` is passed through verbatim and never matched against a closed set.
- `credits.balance` arrives as a JSON number on some accounts and a quoted string on others. It is
  parsed through `Decimal`, never `Double`, so a balance cannot accumulate binary-float error.
- The `chatgpt_base_url` override in `config.toml` is **not** supported. Honouring it would let a
  config file redirect a bearer token to an arbitrary host.
