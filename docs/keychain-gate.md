# Keychain feasibility gate

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
log show --predicate 'subsystem == "dev.blacktop.Usage" AND category == "keychain-gate"' --last 5m --style compact
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

## Current decision

Claude and Codex are enabled for configured roots. Discovery is attributes-only and cannot prompt;
payload reads retain the background no-UI policy and fail closed if the current signing identity is
not permitted. A sign-in file still takes precedence when both stores contain a credential.
