# Why `MoreListParityTests` is not in this fork

Upstream's `MoreListParityTests` pins its sidebar's navigation contract (#805/#811): that
`NavItem.smartAlarm` exists with the exact SF Symbol the iPhone More list mirrors, and that
`RootView.initialExpandedGroups` matches upstream's `NavGroup` layout.

This fork keeps its own `RootView`, whose `NavItem` is a deliberately condensed seven-item nav —
Today merges Today + Live, Intelligence merges Intelligence + Stress, and the old Data page lives
inside Settings. There is no `NavGroup` and no `smartAlarm` destination, so the upstream test
cannot compile here, let alone pass.

It was removed rather than adapted because it guards a *cross-shell parity* contract (macOS sidebar
vs iPhone More list vs the Android More list) that this fork's navigation intentionally steps
outside of. If this fork ever adopts upstream's grouped sidebar, restore the test from upstream
rather than rewriting it:

    git show ryanbr/main:StrandTests/MoreListParityTests.swift > StrandTests/MoreListParityTests.swift

Nothing else in the suite depends on the navigation model.

# Also removed: `ExploreRangeGatingTests` and `StepsDetailDensityIntegrationTests`

Both pin upstream's Explore range model, which added `.twoWeeks` / `.threeWeeks` cases and a
steps-density bucket (`StepsDetailRange` / `StepsDetailBucket`) keyed off them. This fork's
`ExploreRange` is the original W / M / 3M / 6M / 1Y / ALL set, so `ExploreRangeGating` and
`MetricDetailSteps` have nothing to gate here and were not carried across.

Nothing in the app referenced either helper — only these two tests did. Restore them together with
upstream's wider `ExploreRange` if this fork ever adopts the shorter ranges.
