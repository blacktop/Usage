# Keychain feasibility gate

> **Production retired this path, 2026-07-28.** Claude discovery and refresh never enumerate or
> read `Claude Code-credentials` or its per-root variants. The app accepts an inference-only token
> printed by `claude setup-token` through an explicit Settings action and stores it under Usage's
> own `io.blacktop.Usage.claude-setup-token` service. The probe below remains only as a historical,
> explicitly invoked diagnostic; ordinary app and CLI paths do not call it.
>
> **Superseded scope, 2026-07-21.** This experiment measured the legacy host-wide Claude service
> `Claude Code-credentials`. It did not measure the current per-root OAuth services
> `Claude Code-credentials-<root hash>`, and it said nothing about Codex's direct Keychain backend.
> Production now uses only verified addresses derived from explicitly configured roots: file first,
> then the matching Keychain row. The historical measurements below remain useful evidence about
> the legacy service and ad-hoc signing, but they no longer gate provider registration.

## Why this exists

Claude Code stores its credential as a Keychain generic-password item under service
`Claude Code-credentials`. Keychain access is a **per-host capability**: an item's ACL names the
programs allowed to read it, so the `Usage.app` bundle and the standalone `usage` CLI are two
different askers with two different answers. An ad-hoc re-signature changes the app's code identity
and invalidates whatever the ACL recorded about it.

Until this gate is run and recorded, Claude-in-this-host is unproven. `ProviderRegistry.commandLine`
and `AppModel.live()` therefore hold no `ClaudeProvider`, so neither host reads the item or contacts
`api.anthropic.com` at all. Re-adding Claude to a host's registry is the step that records the gate
as passed **for that host**.

The production reader, `KeychainCredentialSource`, cannot answer the gate's question. It collapses
every enumeration failure into "nothing is visible", which is correct for a refresh — a locked
optional source must not fail a provider's whole discovery — and useless as a measurement. The gate
uses `KeychainProbe`, which sends the *same* queries, built by `KeychainCredentialSource` and
policed by the same `KeychainNoUIPolicy`, and reports the `OSStatus` production throws away.

## Protocol

Read all of this before running anything.

1. **No-UI legs first, always.** The tool runs the no-UI enumeration leg, then the no-UI payload
   leg, before anything else. Under this policy every query carries `LAContext.interactionNotAllowed`
   and the legacy `kSecUseAuthenticationUIFail` marker, so it is structurally incapable of
   prompting.
2. **If anything prompts during a no-UI leg, stop.** Dismiss the dialog, run nothing further, and
   record what appeared in the notes column. A prompt under the no-UI policy is a finding about the
   no-UI policy — it is not a step to click through.
3. **User-initiated legs second, and only after the no-UI results are written down.** They run only
   with the explicit `--allow-ui` flag. They are the only legs that can raise an Allow/Deny or
   password dialog, and raising one is the measurement.
4. **Claude service only.** Do not pass `--allow-any-service`. The gate is scoped to
   `Claude Code-credentials`; probing anything else is a different question and is out of scope
   here.
5. **Every value is discarded.** The probe reads a payload and drops it at the read. Record only
   host, policy, leg, category, `OSStatus`, and item count. The tool cannot print an account name, a
   service attribute, a persistent reference, a payload, or a payload length — there is no field for
   any of them. Do not add one to the table by hand.
6. **Change nothing.** No Keychain item is created, edited, or deleted. No ACL is edited, and
   "Always Allow" is not clicked on any dialog the user-initiated leg raises — Allow once, or Deny;
   both are valid answers, and neither should be accompanied by a permanent grant. No credential is
   refreshed, rewritten, or copied. No provider is added to any registry until the results below are
   filled in and reviewed.
7. **Repeat the app leg after every ad-hoc rebuild.** Re-signing produces a new code identity, and
   an earlier `success` says nothing about the new binary.
8. **App and CLI approval are independent.** A pass on one host clears that host only. If the CLI
   cannot read without weakening the no-UI policy, Claude stays unavailable in the CLI and may still
   be enabled in the app.

## Commands

### CLI host

From the repository root:

```fish
swift run --package-path Core --only-use-versions-from-resolved-file usage diagnose keychain
```

Then, only after recording those two rows, the legs that may prompt:

```fish
swift run --package-path Core --only-use-versions-from-resolved-file usage diagnose keychain --allow-ui
```

`--json` emits the same run as one line, for pasting:

```fish
swift run --package-path Core --only-use-versions-from-resolved-file usage diagnose keychain --json
```

The command exits `0` whenever the probe ran, whatever the `OSStatus`. An
`errSecInteractionNotAllowed` is a successful measurement, not a tool failure. A nonzero exit means
the probe could not run — a rejected `--service`, for instance.

### App host

Build the bundle, then run its executable directly so stdout lands in the terminal:

```fish
just build
build/DerivedData/Build/Products/Debug/Usage.app/Contents/MacOS/Usage --diagnose-keychain
```

And, second, the legs that may prompt:

```fish
build/DerivedData/Build/Products/Debug/Usage.app/Contents/MacOS/Usage --diagnose-keychain --allow-ui
```

A diagnostic launch prints the table and exits before a `MenuBarExtra`, an `AppModel`, a
`RefreshCoordinator`, or any network work exists, so it neither shows a menu bar item nor collides
with a copy already running.

The same table also goes to the unified log, which is where to read it if the bundle was started by
LaunchServices rather than from a terminal:

```fish
log show --predicate 'subsystem == "io.blacktop.Usage" AND category == "keychain-gate"' --last 5m --style compact
```

For a release bundle, substitute `just app` and `build/Usage.app/Contents/MacOS/Usage`. Record which
build was measured, because the ACL follows the signature.

## Reading the output

```
HOST  POLICY  LEG          CATEGORY  OSSTATUS  ITEMS
```

| Column | Meaning |
|---|---|
| `HOST` | `cli` or `app` — the asker whose capability is being measured |
| `POLICY` | `no-ui` or `user-initiated` |
| `LEG` | `enumeration` (attributes only, never `kSecReturnData`) or `payload` (the real read) |
| `CATEGORY` | `success`, `itemNotFound`, `interactionNotAllowed`, `authFailed`, `userCanceled`, `other` |
| `OSSTATUS` | the raw status, reported alongside the category so an `other` is still exact |
| `ITEMS` | matched row count, enumeration leg only; `-` on the payload leg |

A payload row whose status came from a failed enumeration means the payload query was never issued:
there was no row to address.

## Results

**Status: RUN 2026-07-21**, under the user's explicit diagnostic-only approval, in the prescribed
order: both no-UI legs first, then the legs permitted to prompt. No value was retained; no Keychain
item, ACL, credential, or registry was modified.

| Date | Host | Build | Policy | Leg | Category | OSStatus | Items | Notes |
|---|---|---|---|---|---|---|---|---|
| 2026-07-21 | cli | `swift run`, unsigned | no-ui | enumeration | success | 0 | 2 | no dialog |
| 2026-07-21 | cli | `swift run`, unsigned | no-ui | payload | userCanceled | -128 | - | no dialog; failed closed |
| 2026-07-21 | cli | `swift run`, unsigned | user-initiated | enumeration | success | 0 | 2 | no dialog |
| 2026-07-21 | cli | `swift run`, unsigned | user-initiated | payload | userCanceled | -128 | - | **no dialog offered** |
| 2026-07-21 | app | Debug .app, adhoc | no-ui | enumeration | success | 0 | 2 | no dialog |
| 2026-07-21 | app | Debug .app, adhoc | no-ui | payload | userCanceled | -128 | - | no dialog; failed closed |
| 2026-07-21 | app | Debug .app, adhoc | user-initiated | enumeration | success | 0 | 2 | no dialog |
| 2026-07-21 | app | Debug .app, adhoc | user-initiated | payload | userCanceled | -128 | - | **no dialog offered** |
| 2026-07-21 | app | Debug .app, adhoc, **rebuilt** | both | both | *identical to above* | | | re-check after re-signature |

**Did any no-UI leg raise a dialog?** No. Both hosts returned immediately.

**Did any user-initiated leg raise a dialog, and what did it ask for?** No. Neither host was offered
an Allow/Deny dialog. Both returned `errSecUserCanceled` immediately, with no user interaction.

### What this means

Enumeration is not the problem. Both hosts see the service and count its 2 items, so the query
shape, the service name, and discovery all work.

The payload read is refused, and refused *the same way under both policies*. That is the load-bearing
observation, and it is not an artifact of an inert policy: `KeychainProbeTests` asserts the
background leg carries both no-UI markers and the user-initiated leg drops both, and those tests
pass. A query that was fully permitted to prompt still got `-128` without a prompt.

The likely cause is code identity. Both hosts are ad-hoc signed (`Signature=adhoc`,
`TeamIdentifier=not set`). An ad-hoc signature has no stable designated requirement, so there is no
identity macOS could persistently add to the item's ACL even if a dialog were answered — and the
system appears to deny outright rather than offer a dialog it could not honour durably. The
post-rebuild re-check is consistent with that: a fresh signature changed nothing, because neither
signature was ever a candidate for the ACL.

**This interacts directly with the "local/personal only, ad-hoc signed" distribution decision.** If
that reading is right, Claude-over-Keychain is not reachable from an ad-hoc build at all, and no
amount of policy tuning inside Usage changes it. Untested alternatives, in rough order of cost:
sign with a stable Developer ID; or read the documented `~/.claude/.credentials.json` fallback,
which is a plain file read and needs no ACL. Neither has been measured.

## 2026-07-24: the no-UI policy was not actually suppressing dialogs

Protocol item 2 says a prompt during a no-UI leg is a finding about the no-UI policy. That prompt
happened — reported from ordinary use, not from a leg: an Allow/Deny panel appeared during a
scheduled background refresh, with nobody clicking anything.

Why it did not show up in the run above: on 2026-07-21 both hosts were ad-hoc, so macOS refused
outright (`-128`) and never offered a dialog at all. `Config/Local.xcconfig` then gave the app a
stable Apple Development identity — which is what the item's ACL needs in order to record a
durable grant, and therefore also what makes the dialog worth offering. Fixing the identity is
what unmasked the prompt.

The markers were the wrong instrument. `LAContext.interactionNotAllowed` and
`kSecUseAuthenticationUI` are **data-protection-keychain** controls, and every agent credential
here lives in the **file-based** login keychain, reached through the SecItem shim. Chromium
documents the same gap and still carries the deprecated call for it
(`crypto/apple/scoped_keychain_user_interaction_allowed.cc`, Apple feedback FB16959400).

The control that does apply to the file-based keychain is `SecKeychainSetUserInteractionAllowed`,
now used by `KeychainUserInteraction.suppressed(_:)` around every background
`SecItemCopyMatching`. This *strengthens* the no-UI guarantee rather than weakening it, so it does
not violate "do not weaken the no-UI policy to make a leg pass" below. The explicit approval path
(`UserInitiatedInteractionPolicy`) deliberately skips the suppression — it is the one read that is
supposed to prompt.

Both hosts are now stably signed: `Usage.app` via `Config/Local.xcconfig`, and the CLI via
`just build-cli`, which signs the SwiftPM binary with the same identity. `just check-signing`
fails when either lands ad-hoc. Re-run the legs below with `just build-cli` rather than
`swift run`, which rebuilds unsigned and is a different asker on every invocation.

## Historical decision (superseded)

**Claude stays disabled on both hosts.** The gate measured a refusal, not a pass.

- `ProviderRegistry.commandLine` holds Codex only.
- `AppModel.live()` holds Codex and the preview provider only.
- `ProviderRegistry.agents` keeps every implementation, because that is what the contract tests
  enumerate — implemented is not the same as enabled.

Do not weaken the no-UI policy to make a leg pass. The no-UI leg failing closed is correct behaviour,
and the user-initiated leg failing is a fact about code identity, not about our query.

Re-run this gate after any change to the app's signing identity, and record the new rows rather than
editing these. Copilot is a **separate** gate with no Keychain dependency; nothing here applies to it.

## Current decision (superseded 2026-08-14, kept for the record)

Claude and Codex are enabled for configured roots. Claude uses a valid sign-in file first, then a
per-root setup token in Usage's own Keychain service. Its discovery never touches Claude Code's
mutable Keychain item. Background reads of Usage-owned token payloads retain the no-UI policy and
fail closed if the current signing identity is not permitted.

## 2026-08-14: Claude Code's hashed per-root item becomes credential tier 2 (superseded)

Gate A (`Usage --diagnose-claude-keychain`, enumeration-only) matched the derived service
`Claude Code-credentials-<first 8 hex of SHA-256(canonical root path)>` for both configured roots
with `status=0`. Gate B (`Usage --diagnose-claude-usage --source claude-code`) resolved that item
through the production `KeychainCredentialSource` under `UserInitiatedInteractionPolicy` and read
`/api/oauth/usage` with a decodable 2xx on the root whose token was fresh; the stale root answered
401, which is the rotation behaviour the 401-rediscovery path absorbs. Sanitized rows live in
`docs/providers/claude.md`.

Decision at the time: Claude discovery resolved usable file → newest row of the hashed per-root
service → Usage setup token. This incorrectly treated the default root's plain service as legacy;
the correction below supersedes that addressing decision. The read-only, no-UI, fail-closed, and
stable-signing constraints remain in force.

### Default-root service correction

Claude Code's current macOS storage behavior
([anthropics/claude-code#78020](https://github.com/anthropics/claude-code/issues/78020)) addresses
the exact `HOME/.claude` root through the plain
`Claude Code-credentials` service. Only custom configuration roots use
`Claude Code-credentials-<first 8 hex of SHA-256(canonical root path)>`. The earlier Gate A matched
an obsolete hashed item for the default root, and Gate B's profile-1 401 came from its stale token;
logging out and back in targets the plain item instead. The corrected signed Gate A now matches
the default plain service and the custom hashed service, both with `status=0`.

Current decision: Claude discovery resolves usable file → newest row of the root's Claude Code
service → Usage setup token. The plain service is addressable only for the exact injected
`HOME/.claude` root and is never guessed for a custom directory. Reads of Claude Code's item are
attributes-only in discovery and no-UI, fail-closed in scheduled fetches; there is no write,
update, refresh, or delete surface. The operative constraints from the 2026-07-21 `-128` rows and
the 2026-07-24 suppression note stand: a stable signing identity from `Config/Local.xcconfig` is
required, and an unavailable suppression lever fails background reads closed rather than running
unsuppressed. Re-run both gates after any signing-identity change, appending new rows rather than
editing these.

## 2026-08-19: Claude Code resets its item's ACL on every write; the mirror self-refreshes

Root cause of the recurring re-approvals, extracted from the Claude Code CLI binary itself
(`strings` on `@anthropic-ai/claude-code/bin/claude.exe`, v2.1.235):

```
add-generic-password -U -a "${account}" -s "${service}" -X "${hexPayload}"
```

Claude Code writes its credential through the `security` command-line tool on **every token
write**. `-U` updates the row in place — `cdat` is preserved, which is why the recreation checks
above kept answering "unchanged" — but the write resets the item's access control, revoking any
Always-Allow grant Usage held. A durable grant on Claude Code's item is therefore impossible by
construction; the observed grant lifetimes match the item's `mdat` history exactly (a grant on the
DDB item survived precisely the two-day window in which that root ran no `claude` session).

Decision: the mirror now stores the **refresh token and expiry** alongside the access token, and
`ClaudeTokenRefresh` exchanges it directly against `https://platform.claude.com/v1/oauth/token`
with Claude Code's public client identifier — the same mechanism CodexBar ships
(`ClaudeOAuthCredentials.refreshAccessTokenCore`), which is the actual reason CodexBar does not
re-prompt. One approval captures the credential; Usage then mints its own access tokens until the
provider answers `invalid_grant`, which deletes the row and surfaces one fresh approval. This
supersedes the 2026-08-16 access-token-only redaction and, deliberately, the "Usage never
refreshes the OAuth token" posture: the exchange is confined to `ClaudeTokenRefresh`, the tokens
never leave the Usage-owned row's flow, and CodexBar's fleet demonstrates that Anthropic's
refresh grants tolerate a second client without invalidating Claude Code's own session.

## 2026-08-16: ACL preflight, fetch-time re-addressing, and the redacted mirror

Claude Code recreated its plain `Claude Code-credentials` item on 2026-08-15 (observed via `cdat`),
which voids the per-item "Always Allow" grant and produced the recurring re-approval reports.
Three changes, modelled on CodexBar's keychain handling, absorb that behaviour:

1. **ACL preflight** (`KeychainACLPreflight`): background payload reads first judge the row's
   decrypt ACL — attributes-only, incapable of prompting — and skip the payload query entirely
   when it is provably going to be refused. The suppressed fail-closed read remains for the
   undetermined case.
2. **Fetch-time re-addressing** (`ClaudeProvider.freshKeychainLocator`): keychain fetches
   re-resolve the newest row of the root's service, so a recreated item heals in the same wave
   instead of failing once on the dangling persistent reference.
3. **Redacted credential mirror** (`ClaudeCredentialMirror`, service
   `io.blacktop.Usage.claude-mirror`): after a 2xx keychain-backed fetch the app stores a
   redacted copy — access token and plan fields, never the refresh token — in a Usage-owned item,
   and a fetch blocked by a voided grant serves full-resolution data from that copy until the
   provider rejects its token, at which point the copy is deleted and the approval error
   surfaces. This is a deliberate, documented exception to the earlier "no write surface"
   posture: the write is into Usage's own service only, through the one reviewed
   `Credential.persistRedactedCopy` escape. The CLI's context carries no mirror store — the app
   and CLI are distinct code identities, and either one's mirror rows would be approval-gated
   for the other.

**2026-08-14, later the same day:** the bundle identifier moved from `dev.blacktop.Usage` to
`io.blacktop.Usage` and the app adopted Hardened Runtime, arm64e, and the Enhanced Security
hard-mode entitlements (`just verify-security` audits all of it). The identifier is part of the
designated requirement, so every Keychain grant recorded for the old identity is void: expect one
fresh Allow/Deny per Claude account on the next explicit Approve, and re-run Gates A and B against
the new identity. The setup-token service was renamed to `io.blacktop.Usage.claude-setup-token`
with no migration — no token had ever been saved. Configured profile roots migrate automatically:
the store copies the legacy `dev.blacktop.Usage.shared` defaults payload forward on first load and
never clears it.
