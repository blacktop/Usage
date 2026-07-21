# GitHub Copilot — read-only credential contract

## What Usage reads

| | |
|---|---|
| Credential | `~/.config/github-copilot/{apps.json, hosts.json, oauth.json}` |
| Owner | the Copilot editor plugin (`apps.json`, `hosts.json`) and the Copilot CLI (`oauth.json`) |
| Access | read-only, through the injected `ProviderFileSystem` and `CredentialSource` |
| Keychain | none. Usage issues no Keychain query for Copilot |

Each file is a JSON object of entries. Entries are read in sorted-key order so discovery is
deterministic, and one GitHub host produces at most one account: `apps.json` beats `hosts.json`
beats `oauth.json`, matching the order the tools migrated through.

`CredentialLocator(kind: .file, identifier: "<home>/.config/github-copilot/apps.json", path: ["<clientID>:<host>", "oauth_token"])`.

### Fields read

| JSON path | Use | Secret |
|---|---|---|
| `<entry>.oauth_token` / `.access_token` / `.token` | bearer token, resolved inside one fetch | yes |
| `<entry>.user` / `.login` / `.github_user` | display label only | no |
| the entry's own map key | slot identity, and the GitHub host | no |

`apps.json` keys are `<githubAppClientID>:<host>`, so the host is the part after the last `:`. The
other two files are keyed by host alone. `github.com` is served from `api.github.com`; an
enterprise host `octocorp.ghe.com` from `api.octocorp.ghe.com`.

### Shape tolerance

These files belong to tools that version independently of Usage, and **their internal key names are
not part of any published contract**. The parser therefore accepts three spellings of the token
member and three of the login, decodes entry by entry, and contributes zero accounts rather than an
error when a file's shape is unrecognised. `oauth.json` in particular is a best-effort source: its
structure is inferred, not verified, and whether the token it holds is even accepted by
`/copilot_internal/user` is unknown.

`XDG_CONFIG_HOME` is not honoured. Providers read no ambient process state; the home directory
arrives through `ProviderFileSystem`.

## What Usage never does

- Never writes any file under `~/.config/github-copilot`.
- Never runs a device flow. There is no `POST /login/device/code` and no
  `POST /login/oauth/access_token`.
- Never writes or deletes a Keychain item.
- Never reads browser cookies. The dollar-denominated GitHub *spending* budgets are only reachable
  by scraping `github.com` session cookies and an HTML nonce; that needs a third-party dependency
  and a browser-credential read, so it is out of scope. "Monthly budget" is satisfied from
  `monthly_quotas` / `limited_user_quotas` in the API response instead.
- Never derives an identifier from a token — not the raw value, not a prefix, not a hash.

`gho_` tokens issued to the editor's GitHub App have no refresh token, so there would be nothing to
refresh even if Usage wanted to.

## Request

```
GET https://api.github.com/copilot_internal/user
Authorization: token <oauth_token>
Accept: application/json
Editor-Version: vscode/1.96.2
Editor-Plugin-Version: copilot-chat/0.26.7
User-Agent: GitHubCopilotChat/0.26.7
X-GitHub-Api-Version: 2025-04-01
```

No query string, no body. An enterprise host is addressed as
`https://api.<host>/copilot_internal/user`.

Authorization uses GitHub's `token` scheme, **not** `Bearer`, and carries the raw OAuth token rather
than an exchanged short-lived Copilot token.

The editor identity triple is a deliberate spoof: this is an editor-internal endpoint and its
behaviour under a truthful `Usage/<version>` agent is unknown and untestable offline. Those pinned
versions will age out; expect this endpoint to break before the Codex or Claude ones do.

## Mapping onto the shared model

Every quota becomes its own named window keyed by the feature GitHub reports —
`additional:<feature>:primary:monthly` — rather than being forced into fixed "premium" and "chat"
slots. That removes the reference's substring-matching heuristic, which would silently present a
future `code_review` quota as the premium-request meter.

| Response | Result |
|---|---|
| `quota_snapshots.<feature>` | one window per metered feature |
| `monthly_quotas` / `limited_user_quotas` | derived window, only where the direct snapshot is absent or unlimited |
| `quota_reset_date` | `resetsAt` on every window; a calendar day is anchored at UTC midnight |
| `copilot_plan` | `UsageReport.plan`, capitalised |

`usedFraction` is `(100 - percent_remaining) / 100`, derived from the remaining count when the
percentage is absent. Values above 1 are real over-quota states and are preserved.

A quota is **omitted** when `unlimited` is true, when it is a placeholder
(`entitlement == 0 && remaining == 0`, which GitHub returns for token-based-billing seats and which
would otherwise render as a healthy untouched allowance), or when no percentage can be derived.

**A 200 with zero renderable meters is a success, not an error.** Token-based-billing and fully
unlimited plans legitimately report nothing to meter; the report carries the plan label and no
windows. Only a 200 whose shape is entirely unrecognised is a decode failure.

## Account identity

Identity is the credential slot: `copilot.<fileName>` plus the entry's own map key. That is derived
from a filename and a public GitHub App client ID, contains no token material, is stable across
launches, and keeps two accounts in the same file distinct.

Promotion to GitHub's canonical `github:user:<id>` — the stable, immutable, rename-proof identifier
from `GET /user` — is **deferred**. It needs a second request per account and only becomes useful
once the identity alias map exists, so it is not implemented rather than half-implemented.

## Expired or missing credential

| Signal | Result |
|---|---|
| HTTP 401 | `.authenticationExpired` |
| HTTP 403 with `Retry-After` or `x-ratelimit-remaining: 0` | `.rateLimited` |
| HTTP 403 otherwise | `.authenticationExpired` |
| HTTP 429 | `.rateLimited`, honouring `Retry-After` in both forms |
| Token missing or empty in the file | that entry contributes no account |

GitHub overloads 403 across a revoked token, a seat without Copilot, and secondary rate limiting.
Telling a throttled user to sign in again is advice they cannot act on, so a 403 carrying a
rate-limit signal is classified as throttling. Only response **headers** are inspected; the body is
never read for classification and never retained.

**Action the user takes** — in the tool that owns the file, never in Usage:

- from `apps.json` or `hosts.json`: re-authenticate in the editor — run **GitHub Copilot: Sign In**
  from the Command Palette, or use the Copilot status icon.
- from `oauth.json`: re-authenticate in the GitHub Copilot CLI.
- on an enterprise host: sign in against that host specifically.

The message renders the GitHub login and host, never the token, never a token prefix, never a byte
count.

Rate-limit cooldowns are **account-scoped**. GitHub's REST limits are documented as per
authenticated user, so two Copilot accounts carry two distinct tokens belonging to two distinct
users and therefore two distinct buckets. The per-source-IP secondary limit would be machine-wide,
but it is not distinguishable from an account limit in the response and so is not modelled.
