# Light Theme (System / Light / Dark) — Design Spec

**Date:** 2026-06-16 · **Status:** approved direction, implementation in waves
**Goal:** A fully-featured, beautiful Light theme across macOS, iOS and Android, toggleable with Dark, every surface legible/clean. Default = follow system; a 3-way override (System/Light/Dark) lives in Settings.

## Decisions (the maintainer, 2026-06-16)
- **Canvas:** Warm Paper — warm off-white canvas, white cards. Keeps the "Titanium & Gold" identity warm; distinct from clinical health apps.
- **Default:** Follow system, with an explicit Light/Dark override toggle in Settings.
- **Widgets:** in scope this pass (iOS WidgetKit + Android Glance).

## Architecture

Color is centralised: `StrandPalette` (Swift, 69 tokens, 1,697 refs, ~6 bypasses) and `Palette` (Kotlin, ~91 tokens incl. gradient lists, ~1,740 refs across 46 files). Both are dark-only single-value constants today; both apps force dark.

- **iOS / macOS:** convert every token from `Color(hex:)` to a dynamic `Color(light:dark:)` backed by an `NSColor`/`UIColor` dynamic provider. All 1,697 call sites resolve automatically per active `colorScheme` — **zero call-site churn**. Drop the two `.preferredColorScheme(.dark)` locks; drive from the setting. The gradient sampler (`recoveryColor()` etc.) resolves token components at render time via `UITraitCollection.current` / `NSAppearance` — correct during SwiftUI body eval; re-samples on scheme change.
- **Android:** introduce `LocalPalette` (`compositionLocalOf`) + a `PaletteTheme` data class holding all tokens; Dark + Light instances. Convert `object Palette`'s properties to `@Composable @ReadOnlyComposable get() = LocalPalette.current.X` so composable call sites stay byte-identical. The exceptions — `Canvas`/`DrawScope` lambdas (gauges, charts, scenic hero) and the Glance widget — read colour outside composable scope and must capture colours above the draw call / take them as params. `NoopTheme` selects Dark/Light/System; persisted in `noop_prefs`.

## The Light idiom (NOT an inversion)

Dark and light raise/separate surfaces differently — these rules are as important as the palette:
1. **Raised-by-shadow, not raised-by-fill.** In dark, cards are *lighter* than canvas. In light, the canvas is warm-grey and cards are pure white, separated by a **soft drop shadow** (`0 1px 3px rgba(26,34,48,.10)`), not a lighter fill. `StrandCard`/`FrostedCardSurface` carry a per-scheme elevation treatment.
2. **Glows become shadows.** Gauge/hero blooms use additive `.plusLighter` / high-alpha white — invisible on white. On light, drop the additive bloom and use a subtle drop shadow or nothing; flip the white end-cap core to a dark accent.
3. **Deepen the accents.** Brand gold `#E8B84B` fails contrast as text/stroke on white. Gold *fills* (FAB, buttons) stay bright with dark text; gold *text/strokes/ramps* deepen to antique/bronze. Every domain ramp shifts ~1–2 stops deeper so even the peak reads on white.
4. **Scenic hero inverts.** Dark navy radial + starfield → warm light radial; stars suppressed/very faint on light.
5. **Chart alphas boost.** Fill alphas (0.28/0.04) and baseline hairlines (0.6α) vanish on light; raise alphas and deepen ramps per scheme.

## Light palette — Warm Paper (token → light / dark)

| Token | Light | Dark |
|---|---|---|
| surfaceBase | `#F4F1EA` | `#070C16` |
| surfaceRaised | `#FFFFFF` | `#111B2A` |
| surfaceOverlay | `#FFFFFF` | `#15243C` |
| surfaceInset | `#ECE7DC` | `#16202F` |
| hairline | `#E4DECF` | `#21304A` |
| hairlineStrong | `#D2C9B6` | `#2E3C57` |
| textPrimary | `#1A2230` | `#F4F6F8` |
| textSecondary | `#4C5564` | `#C8CFD8` |
| textTertiary | `#7C8696` | `#8A94A4` |
| glowAmbient | `#F0E4C0` | `#3A2D0A` |
| accent | `#B07D17` | `#E8B84B` |
| accentHover | `#946612` | `#FCEBA8` |
| accentMuted | `#F4E8C8` | `#2A2210` |
| focusRing | `#C8902F` | `#E8B84B` |
| recovery000 | `#8F6212` | `#C8902F` |
| recovery030 | `#A87718` | `#D9A23E` |
| recovery055 | `#C28E26` | `#E8B84B` |
| recovery078 | `#D2A23A` | `#F2CE6E` |
| recovery100 | `#E0B44C` | `#FCEBA8` |
| strain000 | `#7E460E` | `#9C5A14` |
| strain033 | `#A4621B` | `#C2762A` |
| strain066 | `#C2792E` | `#D98A3D` |
| strain100 | `#D89240` | `#F0A85A` |
| sleepAwake | `#97A2B2` | `#C2CCDA` |
| sleepLight | `#3A80D6` | `#4A90E2` |
| sleepDeep | `#234F9E` | `#2F6FCB` |
| sleepREM | `#5790DA` | `#6FA8E8` |
| zone1 | `#3A80D6` | `#4A90E2` |
| zone2 | `#2E92B4` | `#3FA9C9` |
| zone3 | `#C28E26` | `#E8B84B` |
| zone4 | `#C2792E` | `#D98A3D` |
| zone5 | `#C84E1E` | `#E0662F` |
| statusPositive | `#B07D17` | `#E8B84B` |
| statusWarning | `#C2792E` | `#D98A3D` |
| statusCritical | `#C84E1E` | `#E0662F` |
| metricCyan | `#2E92B4` | `#3FA9C9` |
| metricPurple | `#3A80D6` | `#4A90E2` |
| metricAmber | `#C2792E` | `#D98A3D` |
| metricRose | `#C84E1E` | `#E0662F` |
| chargeColor | `#B88421` | `#E8B84B` |
| chargeDeep | `#8F6212` | `#C8902F` |
| chargeBright | `#E0B44C` | `#FCEBA8` |
| chargeGlow | `#C8902F` | `#E8B84B` |
| effortColor | `#B26A1C` | `#D98A3D` |
| effortDeep | `#7E460E` | `#9C5A14` |
| effortBright | `#D89240` | `#F0A85A` |
| effortGlow | `#B26A1C` | `#D98A3D` |
| restColor | `#3A80D6` | `#4A90E2` |
| restDeep | `#234F9E` | `#2F6FCB` |
| restBright | `#5790DA` | `#6FA8E8` |
| restGlow | `#3A80D6` | `#4A90E2` |
| stressColor | `#B88421` | `#E8B84B` |
| stressDeep | `#3A80D6` | `#4A90E2` |
| stressBright | `#C84E1E` | `#E0662F` |
| stressGlow | `#B88421` | `#E8B84B` |
| scenicCenter | `#FBF6EA` | `#15243C` |
| scenicEdge | `#EDE6D6` | `#0A1322` |
| scenicStar | `#D8CDB6` | `#C8CFD8` |
| cardFillTop | `#FFFFFF` | `#15243C` |
| cardFillBottom | `#FAF7F0` | `#0B1424` |
| gold | `#DBA52A` | `#E8B84B` |
| goldLight | `#ECC766` | `#FCEBA8` |
| goldDeep | `#9A6B12` | `#C8902F` |
| goldDeepText | `#3A2708` | `#3A2708` |
| signalYellow | `#E8A800` | `#FFD63D` |
| titaniumTop | `#DDE1E6` | `#F1F3F5` |
| titaniumMid | `#BBC2C9` | `#C9CFD4` |
| titaniumLow | `#98A0A8` | `#969DA4` |
| titaniumDeep | `#6B737B` | `#6B737B` |

Multi-stop gradients (`recoveryStops`, `strainStops`, `*Gradient`) rebuild automatically from the dynamic tokens above. `goldDeepText` and `titaniumDeep` are intentionally scheme-invariant (text-on-gold; brushed-metal floor).

## Implementation waves
1. **iOS foundation** — dynamic `Color(light:dark:)`; convert all 69 tokens; `AppearanceMode` enum + `@AppStorage` + apply at both app roots (drop forced dark); fix gradient sampler resolution. *Build-verify.*
2. **iOS special surfaces** — `RecoveryRing`/`StrainGauge`/`BevelGauge` (bloom→shadow, deepen ramp, dark core, track), `StrandCard`/`FrostedCardSurface` (raised-by-shadow), `ScenicHeroBackground` (light radial, drop stars), charts (`TrendChart`/`OverviewHRChart`/`Sparkline`/`Hypnogram`/`YearHeatStrip`). File-disjoint → parallelisable.
3. **iOS chrome + Settings UI + WidgetKit** — appearance Picker in `SettingsView`; status bar / macOS titlebar; light WidgetKit variant.
4. **Android** — `LocalPalette` + `PaletteTheme` + `@Composable` getters; fix Canvas/Glance non-composable usages; `NoopTheme` 3-way + `noop_prefs`; `values-night`/status bar; Glance light; Components.kt + Charts.kt special-surface parity.
5. **Lockstep ship** — all three platforms, changelog, release.

Previews drop their hardcoded `.preferredColorScheme(.dark)` so the palette preview shows both schemes.
