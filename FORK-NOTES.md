# FORK-NOTES.md — read this before AGENTS.md

`AGENTS.md` is upstream's guide and is accurate about the *code*. It is not accurate about
*this fork's relationship to it*. Four things in it will actively mislead you here.

## 1. What this branch is

`apollo-max` merges `ryanbr/noop` (≈3,134 commits) into a fork that had diverged 13 commits off
`9bd45a93`. The resolution rule was **pipelines take upstream, presentation stays ours**:

| taken from upstream | kept from this fork |
| --- | --- |
| `Packages/{WhoopProtocol,WhoopStore,StrandAnalytics}` | `Strand/{App,Screens,Onboarding,MenuBar,System}` |
| `Strand/{BLE,Collect,Data}`, `docs/`, `android/` | app icons, `Info.plist`, `README.md` |

So: **the decode and analytics layers are upstream's and should stay that way.** If upstream has
solved something, port it rather than reinventing it. The screens are this fork's and are the
reason it exists — do not "align them with upstream" unless asked.

## 2. `origin/main` is not this fork

- `origin` (`mitchellfgibson/noop`) — a **mirror of ryanbr**, frozen ~2026-07-10.
- `backup` (`mitchellfgibson/apollo-hacked`) — the fork. `main` is the pre-merge line; this branch
  is the merged one.
- `ryanbr` — upstream proper.

`origin/main` and local `main` share only the `9bd45a93` ancestor. Never treat them as the same
branch.

## 3. The carried-helper seam — do not "clean this up"

Upstream declares helpers *inside* screens this fork replaced, and its other files call them
through `TodayView.…` / `SleepView.…`. They are carried verbatim into:

```
Strand/Screens/TodayViewStatics.swift        42 statics LiquidTodayView + hosted cards call
Strand/Screens/SleepViewStatics.swift        13 statics the sleep model + cards call
Strand/Screens/SleepViewHelpers.swift        8 pure helpers SleepModel.swift calls
Strand/Screens/LiveViewStatics.swift         shouldShowStandardHRNote
Strand/Screens/UpstreamScreenHelpers.swift   file-scope types + free functions
Strand/Data/TodayCaches.swift                the two Repository snapshot types
```

These look like dead duplication. They are not — deleting them breaks `LiquidTodayView`,
`AICoach` and the sleep cards. When re-merging upstream, re-extract them and note two traps that
both produce code which compiles and is still wrong:

- **Dedupe by name drops overloads.** `skinTempCardValue` has a `Double` and a
  `SkinTempDisplay.Reading` form; keeping one silently changes behaviour at call sites.
- **Bound extraction to the screen's own declaration.** These files hold other top-level types;
  scooping every `static` collides unrelated members (two PreferenceKeys' `defaultValue`).

## 4. The migration collision

This fork once shipped its own `v10`/`v11` creating `ppgWaveform` / `imuFeature`. Upstream's
`v10`/`v11` create `stepSample` and `dailyMetric.steps`/`activeKcalEst` — **same identifiers,
different DDL**. GRDB keys applied migrations by identifier, so a database migrated by the old
fork build skips upstream's two forever.

`v11b-apollo-reconcile` (in `Packages/WhoopStore/.../Database.swift`, registered before `v12`)
creates only what is missing. It is a no-op on a normally-migrated database. **Do not reorder or
remove it**, and do not renumber migrations.

## 5. Where upstream's #1 rule does not apply

`AGENTS.md` opens with a Swift↔Kotlin parity contract. This fork deliberately steps outside it in
two places, and three upstream tests were removed for it — see
`StrandTests/README-fork-divergences.md`:

- the condensed 7-item macOS nav (upstream has a grouped sidebar)
- `ExploreRange` (this fork has W/M/3M/6M/1Y/ALL; upstream added 2W/3W)

Everything else — decoders, analytics formulas, stored values — should still match Kotlin.

## Build

```sh
xcodegen generate

# macOS
xcodebuild -project Strand.xcodeproj -scheme Strand \
  -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

# iOS device (needs the iOS platform installed: xcodebuild -downloadPlatform iOS)
xcodebuild -project Strand.xcodeproj -scheme StrandiOS \
  -configuration Debug -destination 'id=<device-udid>' -allowProvisioningUpdates build
```

**Signing.** `Config/BundleIdSecrets.xcconfig` is gitignored and absent from a clean checkout.
Copy `Config/BundleIdSecrets.example.xcconfig` and set `BUNDLE_ID_PREFIX` and `DEVELOPMENT_TEAM`
to your own. Every identifier derives from the prefix, so no tracked file needs editing — this is
what makes a TestFlight build under someone else's team a one-file change.

**Known-failing tests.** The suite is 2,238 tests with **2 failures**:
`SkinTempAbsoluteDisplayTests.testTheSecondaryLeadsTheCaptionSoItSitsUnderTheValue` and
`SleepCarriedStampTests.testPriorDayValueIsCarriedAndStamped`. Both fail identically on a pristine
`ryanbr/main` worktree on the same machine — they are environment-sensitive upstream tests, not
regressions. A third failure would be real.

## Known-stale

`README.md` still leads on `OffloadEngine` as an engineering highlight. That file was deleted in
the merge as superseded by upstream's offload path, along with `RespRateAnalyzer`,
`PPGPulseAnalyzer`, `ImuFeatures` and `BackgroundBLETransport`. The README needs rewriting.
