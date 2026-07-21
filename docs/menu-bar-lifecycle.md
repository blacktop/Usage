# MenuBarExtra content lifecycle spike (Phase 0)

## Why this exists

`RefreshPolicy` wants an "is the popover observably present?" input so it can drop from a 5-minute
idle cadence to a 60-second cadence while the user is looking at the popover. SwiftUI's
`MenuBarExtra` does not expose presentation state directly, so the only candidate signal is
`onAppear` / `onDisappear` on the content view.

The plan's decision table makes this a gate: if the callbacks do not pair up reliably, `popoverOpen`
is removed from `RefreshPolicy` and the 5-minute cadence is used unconditionally. An AppKit
`NSStatusItem` shell is **not** introduced without first revising the decision table.

## Instrumentation

`App/MenuBar/MenuLifecycleRecorder.swift` holds two counters and writes one unified-log line per
transition:

- subsystem `dev.blacktop.Usage`
- category `menu-lifecycle`
- messages `popover-appear appearances=<n> disappearances=<n>` and
  `popover-disappear appearances=<n> disappearances=<n>`

`App/Popover/PopoverRoot.swift` calls `recordAppear()` from `.onAppear` and `recordDisappear()` from
`.onDisappear`, and renders the running counters plus a `balanced` / `unbalanced` marker so a human
running the spike can read the result without a terminal.

The counter type itself is unit-tested in `AppTests/MenuLifecycleRecorderTests.swift`; those tests
prove the accounting, **not** the SwiftUI callback behavior. Only the runtime procedure below can
answer the actual question.

## Method

```fish
just run
```

Then, in a second terminal, note the start time and stream the log:

```fish
log stream --predicate 'subsystem == "dev.blacktop.Usage"' --style compact
```

Or replay after the fact:

```fish
log show --predicate 'subsystem == "dev.blacktop.Usage"' --last 10m --style compact
```

Cycles to perform, recording the counter pair after each group:

1. **Ten open/close cycles.** Click the menu bar icon, wait for the popover, click elsewhere to
   dismiss. Repeat ten times. Expect exactly 10 `popover-appear` and 10 `popover-disappear` lines,
   strictly alternating, ending `balanced`.
2. **Settings presentation.** Open the popover, click `Settings…`, then dismiss the popover.
   Record whether the Settings window causes an extra appear/disappear pair, and whether the popover
   is dismissed by the `SettingsLink` activation.
3. **Sleep/wake.** Open the popover, sleep the Mac (`pmset sleepnow`), wake it. Record whether a
   `popover-disappear` was emitted during sleep and whether a matching appear follows on wake.
4. **Relaunch.** Quit from the popover's `Quit` button, `just run` again, confirm the icon returns
   and counters restart at zero.

Counting from the log — **scope the predicate to the running app's pid**, because
`UsageAppTests` runs inside the `Usage` app as its test host and the recorder unit tests emit the
same subsystem/category lines. An unscoped `log show` mixes test output into the spike data:

```fish
set app_pid (pgrep -x Usage)
log show --predicate "subsystem == 'dev.blacktop.Usage' AND processIdentifier == $app_pid" --last 10m --style compact | grep -c popover-appear
log show --predicate "subsystem == 'dev.blacktop.Usage' AND processIdentifier == $app_pid" --last 10m --style compact | grep -c popover-disappear
```

## Pass criteria

- Ten open/close cycles produce ten balanced transitions, strictly alternating.
- No appear without a following disappear once the popover is dismissed.
- Sleep/wake and Settings presentation do not desynchronize the counters.

If any criterion fails, remove `popoverOpen` from `RefreshPolicy` and use the flat 5-minute cadence.

## Results

**Status: OPEN/CLOSE DATA NOT COLLECTED — this spike needs a human at the machine.**

The measurement requires physically clicking the menu bar status item. The agent that built this
phase could not drive it:

```
$ osascript -e 'tell application "System Events" to tell process "Usage" \
    to get count of menu bar items of menu bar 1'
64:101: execution error: System Events got an error: osascript is not allowed
assistive access. (-1719)
```

Accessibility (TCC) permission for the driving process cannot be granted non-interactively, and
posting synthetic clicks at unverified screen coordinates was out of bounds. So the appear/disappear
pairing question is **unanswered**.

What *was* verified mechanically on 2026-07-20 (macOS 27.0, Xcode 27.0, Swift 6.4):

| Check | Result |
|---|---|
| App builds warning-free and is ad-hoc signed (`flags=0x2(adhoc)`) | pass |
| Built `Info.plist` has `LSUIElement = true` | pass |
| Built `Info.plist` has `LSMultipleInstancesProhibited = true` | pass |
| `open`ed bundle stays resident and LaunchServices reports `type="UIElement"` | pass |
| No `menu-lifecycle` event is emitted merely by the scene existing | pass (0 events for the live pid before any click) |
| `MenuLifecycleRecorder` counter accounting | pass (4 unit tests) |
| `onAppear`/`onDisappear` pairing across real open/close cycles | **not measured** |

Two incidental findings worth keeping:

- Because the app test bundle uses the app as its test host, `UsageAppTests` emits
  `dev.blacktop.Usage / menu-lifecycle` lines too. Any log query for spike data must be scoped by
  process identifier.
- `LSMultipleInstancesProhibited = true` makes LaunchServices refuse to start the test host while a
  copy of the app is running: `Failed to install or launch the test runner … The LaunchServices
  launcher has returned an error.` `just test-app` therefore retires any live instance first. The
  same exclusion is what Phase 7 relies on for single-writer history.

Fill in the table below when the spike is run by a human.

| Scenario | appearances | disappearances | balanced? | notes |
|---|---|---|---|---|
| 10 × open/close | | | | |
| Settings presentation | | | | |
| Sleep/wake with popover open | | | | |
| Relaunch | | | | |

**Decision (pending data):** `RefreshPolicy` must not depend on `popoverOpen` until this table is
filled in and shows balanced pairing. Phase 4 implements the flat cadence by default and only adds
the open-aware branch if the data supports it.

## Phase 4 status

Presence is an *input* to the pure policy (`AccountRefreshInput.isPopoverPresent`), not something
the policy observes, so the unanswered question above changed nothing about how scheduling is
computed or tested: the idle and present cadences are both unit-tested from literal inputs.

The app currently feeds that input from the same `onAppear`/`onDisappear` pair this spike is about:
`PopoverRoot` calls `AppModel.setPopoverPresent(_:)`. The exposure is bounded on purpose —

- a missed `onDisappear` leaves the account on the 60-second cadence rather than 5 minutes, and
  never below it, because `RefreshCoordinator` still clamps every deadline to any active
  `Retry-After` cooldown;
- a missed `onAppear` costs nothing but the faster cadence.

If the table above is ever filled in and shows unbalanced pairing, the fix is to delete the two
`setPopoverPresent` calls in `App/Popover/PopoverRoot.swift`. No policy, coordinator, or test
change is required, and no AppKit status-item shell is introduced.
