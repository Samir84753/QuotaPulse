# AGY-02 – Native WidgetKit desktop widget (optional Xcode target)

The SwiftPM app already has a floating "desktop widget" panel. Add a real Notification Center / desktop
WidgetKit widget without breaking the SwiftPM build.

1. If `xcodegen` is missing, `brew install xcodegen`.
2. Create `project.yml` (XcodeGen) producing `QuotaPulse.xcodeproj` with:
   - app target `QuotaPulse` (sources `Sources/QuotaPulse`, Info.plist `Resources/Info.plist`,
     depends on local package product `QuotaCore`),
   - widget extension `QuotaPulseWidget` (`Widget/` folder) depending on `QuotaCore`,
   - App Group `group.com.quotapulse.shared` entitlements for both (matches `SnapshotStore.appGroupID`),
   - `DEVELOPMENT_TEAM` left as a build setting the user fills in (`QUOTAPULSE_TEAM_ID` env / xcconfig).
3. `Widget/QuotaPulseWidget.swift`: `StaticConfiguration`, timeline provider reading `SnapshotStore.load()`,
   refresh every 15 min; `.systemSmall` (worst provider + gauge) and `.systemMedium` (all providers with bars).
   Follow `.claude/skills/generators/widget-generator`.
4. `scripts/build-xcode.sh`: `xcodegen generate && xcodebuild -scheme QuotaPulse -configuration Release build`.
   Verify it builds with `CODE_SIGNING_ALLOWED=NO` at least; document signing steps in `docs/WIDGET.md`
   (widgets only appear when the app is signed with a team + App Group).
5. `swift build` (SwiftPM) must still succeed. Add `*.xcodeproj` to `.gitignore`.
