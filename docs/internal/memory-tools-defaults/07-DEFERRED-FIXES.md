# Deferred Fixes — Design Notes for Follow-Up PRs

> Team doc: four issues flagged during the Phase E deep edge-case audit
> that were intentionally not shipped on `feat/memory-tools-defaults`.
> Each entry is a complete design document — symptom, code evidence,
> tradeoff analysis, recommended fix, implementation sketch, test plan,
> scope estimate. Written so someone (likely tpae or rcn) can pick an
> item up in a follow-up PR without having to re-derive the context.
>
> **Nothing here is a blocker for shipping `feat/memory-tools-defaults`.**
> Every item is a quality-of-life improvement, not a correctness bug.
> The 🔴 must-fix from the audit (test coverage) and three 🟡 items
> (chip override persistence, partial-save messaging, cache width
> constraint) already shipped as Phases E.7 and E.8.
>
> **Branch**: `feat/memory-tools-defaults` at commit `53132792`.
> **Audit source**: the edge-case pass summarized at the end of the
> Phase E.8 commit message and in the conversation transcript.

---

## Table of contents

1. [DF-1: Disk cache readout staleness](#df-1-disk-cache-readout-staleness)
2. [DF-2: Cache changes mid-generation don't apply until reload](#df-2-cache-changes-mid-generation-dont-apply-until-reload)
3. [DF-3: SettingsStepperField silently resets invalid input](#df-3-settingsstepperfield-silently-resets-invalid-input)
4. [DF-4: Localization inconsistency in memorySettingsSection](#df-4-localization-inconsistency-in-memorysettingssection)
5. [Priority ranking and suggested PR grouping](#priority-ranking-and-suggested-pr-grouping)

---

## DF-1: Disk cache readout staleness

**Severity**: 🟡 minor
**Source**: deep edge-case audit §6 "Disk cache readout accuracy"
**Audit line**: "`diskCacheUsageBytes` is read once on view appear. If the user saves config changes that would re-populate the cache, opens a long conversation, or keeps Settings open for a while, the displayed number is stale."

### Symptom

The Cache Engine subsection displays the current disk KV cache usage
(e.g., "Disk cache: 1.2 GB") as a read-only label with a "Clear"
button next to it. The number is captured once into
`diskCacheUsageBytes` when the Settings view loads (or when
`loadConfiguration()` runs) and is never refreshed.

Failure scenarios:

1. **Keep Settings open during a long generation** — the cache is
   actively growing on disk, but the displayed number stays frozen at
   whatever it was when Settings opened.
2. **Change config that re-enables disk cache** — user toggles
   `enableDiskCache` from `.disabled` to `.auto`, saves, and watches
   the readout — which still says "0 B" because it hasn't been
   re-read since Settings opened.
3. **Clear the cache, then let generation re-populate** — after
   clicking Clear, the number correctly drops to 0 and the button
   becomes disabled. But as the next generation fills the cache back
   up, the display stays at 0 and the button stays disabled until
   Settings is closed and reopened.

### Code evidence

**File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`

The state variable is hydrated in `loadConfiguration()`:

```swift
// ConfigurationView.swift — in loadConfiguration()
diskCacheUsageBytes = OsaurusPaths.diskKVCacheUsageBytes()
```

The display is rendered in `cacheEngineSubsection`:

```swift
// Disk cache usage readout + clear button (Stack 4 status)
HStack(spacing: 8) {
    Image(systemName: "externaldrive")
    Text("Disk cache: \(formatBytes(diskCacheUsageBytes))")
    Spacer()
    Button {
        _ = OsaurusPaths.clearDiskKVCache()
        diskCacheUsageBytes = OsaurusPaths.diskKVCacheUsageBytes()
        showSuccess("Disk cache cleared")
    } label: { Text("Clear", bundle: .module) }
    .disabled(diskCacheUsageBytes == 0)
}
```

There's exactly one refresh path: the Clear button re-reads the size
*after* clearing, which is why clearing works but nothing else does.

### Why deferred

The "correct" fix depends on a design decision the team hasn't made
yet: should the readout **poll** (live, automatic) or **refresh on
user action** (explicit button)?

Polling is simpler to implement but introduces a background timer
that runs while Settings is open — wasteful on a section the user
may scroll past without reading. A refresh button is cheap and
obvious but requires the user to know they need to tap it.

Also, a truly live readout would need to subscribe to
`CacheCoordinator` write events — but `CacheCoordinator` lives in
`vmlx-swift-lm` and doesn't currently post write notifications. Adding
one is a package-level change, not an osaurus-level change, so it's
out of scope for a UI polish PR.

### Fix options

| Option | Implementation | Pros | Cons |
|--------|---------------|------|------|
| **A. Refresh button** | One new button in the disk-cache row. Wired to a `refreshDiskCacheUsage()` helper that re-reads the byte count and updates the `@State`. | Simple, obvious, zero background cost. | User has to know to tap it. |
| **B. Timer-based poll** | `Timer.publish(every: 2)` while the Settings view is visible. Updates `diskCacheUsageBytes` on every tick. | Live, automatic, matches user expectation. | Burns CPU for a value the user is rarely looking at. Needs cleanup on view disappear. |
| **C. Refresh on `.appConfigurationChanged`** | Add an `onReceive(NotificationCenter...)` that refreshes whenever Settings save fires. | Solves the common "I just saved, why is the number still old?" case without background cost. | Doesn't help the long-streaming case. |
| **D. `CacheCoordinator` write notification** | vmlx package change: post a notification when `storeAfterGeneration` writes to disk. Settings observes it. | Most "correct" — always live, zero polling. | Out-of-scope package change. Cross-repo coordination. |

### Recommended fix: **A + C combined**

Ship a Refresh button **and** an `onReceive` observer on
`.appConfigurationChanged`. The button handles the long-streaming
case (user taps it if they care). The observer handles the common
"I just changed settings" case for free.

**Why this combination**: both pieces are cheap (a button + one
`onReceive`), together they cover the two likely user flows (explicit
inspection vs. post-save verification), and neither introduces
background work. Defer the package-level notification (option D) until
`CacheCoordinator` gains a usage-API for other reasons.

### Implementation sketch

```swift
// Add helper near showSaveError / formatBytes
private func refreshDiskCacheUsage() {
    diskCacheUsageBytes = OsaurusPaths.diskKVCacheUsageBytes()
}

// In cacheEngineSubsection's disk-cache HStack, insert a refresh
// button BEFORE the Clear button:
HStack(spacing: 8) {
    Image(systemName: "externaldrive")
    Text("Disk cache: \(formatBytes(diskCacheUsageBytes))")
    Spacer()
    Button(action: refreshDiskCacheUsage) {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 11))
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help("Refresh disk cache size")
    Button { /* existing clear action */ } label: {
        Text("Clear", bundle: .module)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(diskCacheUsageBytes == 0)
}

// Attach an observer somewhere on the outer ConfigurationView body
// (e.g. after the existing .onAppear):
.onReceive(NotificationCenter.default.publisher(for: .appConfigurationChanged)) { _ in
    refreshDiskCacheUsage()
}
```

**Note on the `disabled` state**: the Clear button is currently
disabled when `diskCacheUsageBytes == 0`. After this fix, if the user
taps Refresh and the cache has grown, the button re-enables
automatically. Works without extra logic.

### Test plan

- Open Settings, note the displayed size (X bytes)
- Send a generation in another window that fills the cache
- Tap Refresh — expect the number to grow
- Tap Clear — expect the number to drop to 0, button to become disabled
- Save a config change that toggles `enableDiskCache` — expect the
  onReceive path to fire a refresh (manual visual check)

### Scope estimate

~15 lines of UI code. One helper method. No model changes, no test
fixture changes. **Fits in a 50-line PR.**

---

## DF-2: Cache changes mid-generation don't apply until reload

**Severity**: 🟡 minor (documentation / UX clarity)
**Source**: deep edge-case audit §3 "State sync + concurrency"
**Audit line**: "User clicks Save in Settings while a streaming response is in-flight using the old cache config. Settings save completes, but the model is still mid-response with CacheCoordinatorConfig from the pre-save load. Changes to stacks 2–4 won't take effect until the model reloads."

### Symptom

User opens Settings, tweaks a Cache Engine field that maps to a
`CacheCoordinatorConfig` knob (e.g. `maxCacheBlocks` from 1000 to
1500), saves, and expects the next generation to reflect the change.
Because `CacheCoordinator` is constructed once per model load in
`ModelRuntime.installCacheCoordinator` and is immutable afterward,
the currently-loaded model keeps using the old config until the user
either switches models or restarts Osaurus.

Stacks 1 (prefillStepSize) and 5 (kvQuantMode etc.) **do** take
effect on the next request — they flow through `GenerateParameters`
per generation. The split is already documented in the
`ServerCacheConfig` doc comment and briefly mentioned in the
subsection help text:

> "Stacks 1 and 5 take effect on next generation; stacks 2, 3, 4, 6
> take effect on next model load."

But the help text doesn't tell the user **what to do** about it.
There's no instruction "switch models to apply" and no visual
indication that a saved change hasn't applied yet.

### Code evidence

**File**: `Packages/OsaurusCore/Services/ModelRuntime.swift`

```swift
private func installCacheCoordinator(on holder: SessionHolder) async {
    let serverCfg = await ServerConfigurationStore.load() ?? .default
    let cacheConfig = Self.buildCacheCoordinatorConfig(
        modelName: holder.name,
        overrides: serverCfg.cacheConfig
    )
    holder.container.enableCaching(config: cacheConfig)
    // ...
}
```

This runs exactly once per `loadContainer` call. There's no
`reconfigureCache` path.

**File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`

The Cache Engine subsection help text:

```swift
Text(
    "Tune the 6-stack KV cache engine. Every control defaults to Auto — osaurus ships with TurboQuant enabled and sensible RAM-scaled defaults. Stacks 1 and 5 take effect on next generation; stacks 2, 3, 4, 6 take effect on next model load.",
    bundle: .module
)
```

Correct but passive. Doesn't tell the user how to trigger a reload.

### Why deferred

Three possible fixes, each with a real cost:

1. Adding a "Reload current model" button in Settings requires
   wiring into `ModelRuntime.shared.unloadModel(name:)` and
   understanding the consequences of doing it mid-stream.
2. Auto-reload on save is a correctness cliff — if the user is
   streaming, auto-reload kills the stream.
3. Adding a "pending reload" banner requires tracking which specific
   `ServerCacheConfig` fields changed and determining whether any
   are `CacheCoordinatorConfig` fields (vs. `GenerateParameters`
   fields).

None of these are hard, but together they're a UX design decision
the team should make deliberately.

### Fix options

| Option | Implementation | Pros | Cons |
|--------|---------------|------|------|
| **A. Help text enhancement** | Append one sentence: "To apply Stack 2/3/4/6 changes immediately, switch to another model and back, or restart Osaurus." | Zero risk, ships now. | Still passive — user has to read it. |
| **B. Post-save "pending reload" banner** | After save, detect if any stack-2/3/4/6 field changed. If yes, set a `@State pendingModelReload: Bool = true`. Render a banner at the top of the subsection. Clear when the user next loads a model (observe `ModelRuntime` notification). | Obvious to the user. Self-dismissing. | Requires tracking previous config state, touching `ModelRuntime` for the clear signal. |
| **C. Explicit "Apply Now (Reload Model)" button** | Button in the subsection that calls `ModelRuntime.shared.unloadModel(current)` and lets the next request re-trigger `installCacheCoordinator`. | Gives power users explicit control. | Dangerous if clicked during streaming. Needs a confirmation dialog or a disable-while-streaming state. |
| **D. Automatic deferred reload** | Set a flag on `ModelRuntime` that the current coordinator is stale. On next request, tear down and rebuild before generating. | Fully automatic. | Adds first-request latency (rebuild cost). Hidden side effect. |

### Recommended fix: **A + B combined**

Ship the enhanced help text immediately (option A) and add a
post-save banner (option B) as the cohesive UX fix. Reject C and D:
C is footgun territory, D hides the cost.

**Why A + B**: A is a one-line edit that partially solves the
problem for anyone who reads help text. B is the proper UX fix for
users who don't — a contextual banner that appears exactly when it's
relevant and dismisses itself. Together they cover both reading
styles without risking streams.

### Implementation sketch

**File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`

```swift
// 1. Enhanced help text — update the existing Text at the top of
//    cacheEngineSubsection:
Text(
    "Tune the 6-stack KV cache engine. Every control defaults to Auto — osaurus ships with TurboQuant enabled and sensible RAM-scaled defaults. Stacks 1 and 5 take effect on next generation; stacks 2, 3, 4, 6 take effect on next model load. To apply stack 2/3/4/6 changes to a currently-loaded model, switch models or restart Osaurus.",
    bundle: .module
)

// 2. Add state for the pending-reload banner
@State private var pendingCacheReload: Bool = false

// 3. In saveConfiguration, after building the new ServerCacheConfig,
//    compare against previousServerCfg.cacheConfig and detect changes
//    to coordinator-level fields:
let coordinatorFieldsChanged =
    previousServerCfg.cacheConfig.usePagedCache != configuration.cacheConfig.usePagedCache
    || previousServerCfg.cacheConfig.maxCacheBlocks != configuration.cacheConfig.maxCacheBlocks
    || previousServerCfg.cacheConfig.pagedBlockSize != configuration.cacheConfig.pagedBlockSize
    || previousServerCfg.cacheConfig.enableDiskCache != configuration.cacheConfig.enableDiskCache
    || previousServerCfg.cacheConfig.diskCacheMaxGB != configuration.cacheConfig.diskCacheMaxGB
    || previousServerCfg.cacheConfig.ssmMaxEntries != configuration.cacheConfig.ssmMaxEntries

if coordinatorFieldsChanged {
    pendingCacheReload = true
}

// 4. Render the banner at the top of the cacheEngineSubsection when
//    pendingCacheReload == true:
if pendingCacheReload {
    HStack(spacing: 8) {
        Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundColor(.orange)
        Text("Some changes apply on next model load")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.primaryText)
        Spacer()
    }
    .padding(8)
    .background(
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.orange.opacity(0.1))
    )
}

// 5. Clear the banner when a model (re)loads. Observe the existing
//    ModelRuntime notification (or add one if there isn't one).
//    Fallback: clear after a 30-second timeout as a safety net.
```

**On the "clear when model reloads"**: `ModelRuntime` doesn't
currently post a notification on model load. The cheapest path is
**not** to add one — just clear the banner when the user dismisses
it or when `saveConfiguration` is called again with no coordinator
changes. Or include a small "Dismiss" button on the banner.

### Test plan

- Open Settings with a model loaded
- Change `maxCacheBlocks` from Auto to 1500
- Save — expect the banner to appear
- Send a message — verify (via logs or debug print) that the old
  `CacheCoordinator` is still in use (the banner is accurate)
- Switch to another model — the banner should clear on next save, or
  via the timeout/dismiss button
- Change only a Stack 1 or Stack 5 field (e.g. `prefillStepSize`) —
  banner should NOT appear because those apply per-request

### Scope estimate

~30 lines of UI code plus state tracking. No model changes, no test
fixture changes. **Fits in a 100-line PR.**

---

## DF-3: SettingsStepperField silently resets invalid input

**Severity**: 🟡 minor (cross-cutting UX)
**Source**: deep edge-case audit §2 "Input validation"
**Audit line**: "SettingsStepperField and SettingsSliderField fall back to `defaultValue` on parse failure (empty or non-numeric input); users never see validation error, just silent reset to default."

### Symptom

User types "abc" into `tempCacheMaxBlocks`, or "99999" (outside the
100–4000 range), or "-500". The stepper component silently resets
the field to the default value with no visual indication that the
input was rejected.

The impact isn't limited to Cache Engine fields — `SettingsStepperField`
is used across **every** numeric input in Settings: temperature, max
tokens, context length, top-p, max tool attempts, agent iterations,
toast timeout, toast max visible, toast max concurrent, etc. A fix
to `SettingsStepperField` benefits the entire Settings surface.

### Code evidence

**File**: likely `Packages/OsaurusCore/Views/Settings/` — search for
`struct SettingsStepperField` and `struct SettingsSliderField`.

Example call sites from the new Cache Engine work:

```swift
SettingsStepperField(
    label: "Cache Block Pool",
    help: "Max number of paged blocks in the L1 pool. Leave blank for Auto (...)",
    text: $tempCacheMaxBlocks,
    range: 100 ... 4000,
    step: 100,
    defaultValue: 1000
)
```

The component presumably does something like
`Int(text) ?? defaultValue` with an `.onChange` or `.onSubmit` that
clamps to `range` — that's the source of the silent reset.

### Why deferred

1. **Cross-cutting**. A fix touches every call site of
   `SettingsStepperField` and `SettingsSliderField` across the Settings
   view. Every existing behavior has to be preserved.
2. **Component refactor**. The fix is a proper component evolution —
   adding validation state, error styling, accessibility hooks. That's
   the kind of thing that deserves its own PR so it can be reviewed
   in isolation.
3. **Design decisions**. How should invalid input be surfaced? Red
   border? Inline error text? Shake animation? Toast? Focus-trap? The
   team should pick one pattern and apply it everywhere.

### Fix options

| Option | Implementation | Pros | Cons |
|--------|---------------|------|------|
| **A. Red border on invalid** | Add a computed `isValid: Bool` property. Border color is red when `!isValid`. | Subtle, non-intrusive, familiar pattern. | User may miss the color change. No explanation of why. |
| **B. Inline error text below field** | Show "Must be between 100 and 4000" when `!isValid`. | Explains the rule. Persistent. | Adds vertical space. Can clutter dense forms. |
| **C. Placeholder with valid range** | Show "100-4000" as the placeholder when empty; hide when valid. | Pre-empts the problem. Zero error state. | Doesn't help if the user types out-of-range value. |
| **D. Toast on blur** | When the field loses focus with invalid input, fire a toast. | Non-blocking, visible. | Disruptive. Easy to miss if user blurs fast. |

### Recommended fix: **A + B + C combined as a `SettingsValidatedField` component**

Build one validated field component that does all three: shows the
valid range as placeholder when empty, red-borders on out-of-range
input, and shows an inline error explaining the rule. Use it to
replace `SettingsStepperField` and `SettingsSliderField` everywhere.

**Why combine all three**: each option on its own solves part of the
problem; together they cover the discovery, feedback, and
explanation aspects of input validation. And since this component is
used everywhere, doing it once right is cheaper than three half-fixes
spread across future PRs.

### Implementation sketch

```swift
struct SettingsValidatedField: View {
    let label: String
    let help: String
    @Binding var text: String
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    let formatString: String

    // Computed validation state from the current text
    private enum ValidationState {
        case empty       // nil → auto / default
        case valid
        case unparseable // user typed non-numeric
        case outOfRange  // value is outside range
    }

    private var validationState: ValidationState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        guard let value = Double(trimmed) else { return .unparseable }
        if !range.contains(value) { return .outOfRange }
        return .valid
    }

    private var errorMessage: String? {
        switch validationState {
        case .empty, .valid: return nil
        case .unparseable: return "Must be a number"
        case .outOfRange:
            return "Must be between \(range.lowerBound, specifier: formatString) and \(range.upperBound, specifier: formatString)"
        }
    }

    private var borderColor: Color {
        switch validationState {
        case .empty, .valid: return .clear
        case .unparseable, .outOfRange: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField(
                "\(range.lowerBound, specifier: formatString)–\(range.upperBound, specifier: formatString)",
                text: $text
            )
            .textFieldStyle(.roundedBorder)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1)
            )
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            } else {
                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }
}
```

Migration strategy:

1. Land `SettingsValidatedField` as a new component, unused.
2. Migrate Cache Engine fields to use it first (scoped to the Phase E
   area so it's easy to roll back).
3. Migrate the rest of Settings field by field in follow-up commits.
4. Eventually delete `SettingsStepperField` / `SettingsSliderField`.

### Test plan

- Type "abc" in a validated field — expect red border + "Must be a number" error
- Type "-500" in a 100..4000 field — expect red border + "Must be between 100 and 4000"
- Type "2500" in a 100..4000 field — expect valid state, no error
- Clear the field — expect placeholder "100-4000" visible, no error
- Save while a field is in an error state — expect the save to either
  fall back to default (with a toast?) or block (with an error). Pick
  one deliberately.

### Scope estimate

New component file (~100 lines). Gradual migration across call sites.
**Fits in a multi-commit PR — component + cache migration first, then
sweep-up commits for the rest of Settings. Roughly 300-500 lines
total.**

---

## DF-4: Localization inconsistency in memorySettingsSection

**Severity**: 🟢 cosmetic
**Source**: deep edge-case audit §1 "Visual/layout edge cases"
**Audit line**: "Memory settings section in AgentDetailView renders with `L()` localization wrapper but help text uses `bundle: .module` inline — inconsistent localization pattern."

### Symptom

`memorySettingsSection` in `Packages/OsaurusCore/Views/Agent/AgentsView.swift`
mixes two localization idioms within a single section:

- The section title uses `L("Memory Settings")` — the osaurus
  `L()` helper that wraps `NSLocalizedString`.
- The help text and subtitle use `Text("...", bundle: .module)` —
  the SwiftUI direct-bundle pattern.

Both work. But the file is expected to use one style consistently,
and AgentsView already uses `L()` for most strings (see
`AgentDetailSection(title: L("Working Memory"), ...)` just a few
lines below `memorySettingsSection`).

### Code evidence

**File**: `Packages/OsaurusCore/Views/Agent/AgentsView.swift`

The section I added (Phase E.4) looks like this:

```swift
private var memorySettingsSection: some View {
    AgentDetailSection(
        title: L("Memory Settings"),                               // ← L()
        icon: "brain.head.profile",
        subtitle: memoryOverride == .followGlobal ? nil : memoryOverride.rawValue
    ) {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Override the global memory setting for this agent. ...",
                bundle: .module                                    // ← bundle: .module
            )
            // ...
            Text(memoryOverride.helpText)                          // ← no wrapper at all
                .font(.system(size: 11))
            // ...
        }
    }
}
```

Three different string-handling patterns in one view. Pick one.

### Why deferred

Pure cosmetic consistency — zero user-visible impact. Touching it
during Phase E.4 would have added noise to a commit whose purpose
was landing the `Agent.memoryEnabled` editor UI.

### Fix

Pick the `L()` pattern (consistent with the rest of the file) and
rewrite both the help text and `memoryOverride.helpText` usage to
route through it.

```swift
// Before
Text(
    "Override the global memory setting for this agent. ...",
    bundle: .module
)

// After
Text(L("Override the global memory setting for this agent. ..."))
```

And move the `AgentMemoryOverride.helpText` strings through `L()`
at their declaration site (at the top of `AgentsView.swift`):

```swift
var helpText: String {
    switch self {
    case .followGlobal:
        return L("Memory follows the global Settings → Chat → Memory toggle. ...")
    // ...
    }
}
```

### Test plan

Visual check — open the Memory tab of any custom agent, verify the
picker and help text still render exactly as before. No behavioral
change expected.

### Scope estimate

Three string sites. **Fits in a 10-line PR.** Could also be absorbed
into a larger "localization audit" sweep-up PR that fixes the whole
AgentsView file at once.

---

## Priority ranking and suggested PR grouping

### If the team has one follow-up PR slot

**Ship DF-1** (disk cache readout refresh). Smallest scope, highest
user value, solves a visible annoyance in the newly-shipped Cache
Engine UI. ~50 lines.

### If the team has two follow-up PR slots

Add **DF-2** (cache changes mid-generation clarity). Medium scope,
improves understanding of the hot-reload split that Phase E.3
introduced. ~100 lines.

### If the team has three follow-up PR slots

Add **DF-3** (SettingsValidatedField). Larger scope but
highest-leverage — benefits every numeric field across the Settings
surface, not just the new Cache Engine section. Should be its own PR
and own review cycle. ~300-500 lines. Don't bundle with DF-1 or DF-2.

### DF-4 should ride along with whichever PR touches AgentsView next

Low value on its own, not worth a dedicated PR, but worth landing
next time someone edits the Agent Memory tab for any reason.

### Suggested grouping

| PR | Items | Scope | Dependencies |
|----|-------|-------|--------------|
| `feat/cache-readout-polish` | DF-1 + DF-2 | ~150 lines | None — both touch `ConfigurationView.saveConfiguration` and the cache subsection |
| `feat/settings-validated-field` | DF-3 | ~300-500 lines | None |
| (opportunistic) | DF-4 | ~10 lines | Ride along with any AgentsView PR |

---

**Document status**: ready for team review alongside the other
`docs/internal/memory-tools-defaults/` team docs.

**Last updated**: at Phase E.8 commit `53132792` on branch
`feat/memory-tools-defaults`, after the deep edge-case audit pass
landed fixes for chip override persistence, partial-save messaging,
cache width constraint, and core logic test coverage.
