# QuotaPulse WidgetKit Desktop Widget

QuotaPulse includes an optional native macOS WidgetKit extension (`QuotaPulseWidget`) that provides widgets for the macOS Desktop and Notification Center.

## Overview

The native widget supports two widget families:
- **System Small (`.systemSmall`)**: Highlights the most constrained ("worst") provider with its quota gauge and remaining percentage.
- **System Medium (`.systemMedium`)**: Displays all configured agent providers (Claude Code, Codex, Antigravity) with color-coded remaining quota progress bars.

Data is shared between the main menu bar app and the widget extension via an App Group container (`group.com.quotapulse.shared`) managed by `SnapshotStore`.

---

## Why Code Signing is Required

On macOS, Notification Center and Desktop widgets are managed by the system daemon `widgetkitd`. For `widgetkitd` to discover, validate, and display an app extension, the following requirements must be met:
1. **Valid Developer Team**: Both the app and widget extension must be signed with the same Apple Developer Team ID.
2. **App Groups**: Both targets must have the `group.com.quotapulse.shared` App Group entitlement enabled and provisioned on Apple's developer portal.
3. **Application Location**: macOS discovers widgets only from applications located in `/Applications` or `~/Applications`.

> [!NOTE]
> If you do not have an Apple Developer account, QuotaPulse provides a built-in floating **Desktop Widget panel** (Settings → Desktop Widget) that works immediately without any code signing or provisioning profiles.

---

## Setup & Signing Instructions

### 1. Prerequisites

Ensure Xcode and `xcodegen` are installed:
```bash
brew install xcodegen
```

### 2. Configure Your Apple Developer Team ID

Obtain your 10-character Team ID from your [Apple Developer Account](https://developer.apple.com/account).

You can supply your Team ID in one of three ways:

#### Option A: Environment Variable (Recommended for CI / CLI builds)
```bash
export QUOTAPULSE_TEAM_ID="XXXXXXXXXX"
```

#### Option B: `Config.xcconfig`
Open `Config.xcconfig` at the project root and set:
```xcconfig
QUOTAPULSE_TEAM_ID = XXXXXXXXXX
```

#### Option C: Xcode UI
1. Open `QuotaPulse.xcodeproj`.
2. Select the `QuotaPulse` target → **Signing & Capabilities** → Select your Team.
3. Select the `QuotaPulseWidget` target → **Signing & Capabilities** → Select your Team.

### 3. Register the App Group in Apple Developer Portal

1. Go to **Certificates, Identifiers & Profiles** → **Identifiers** → **App Groups**.
2. Register an App Group with identifier: `group.com.quotapulse.shared`.
3. In App IDs, edit both:
   - `com.quotapulse.app`
   - `com.quotapulse.app.widget`
4. Enable the **App Groups** capability for both and check `group.com.quotapulse.shared`.

### 4. Build and Install

Run the build script:
```bash
./scripts/build-xcode.sh
```

The script selects the **QuotaPulseApp** scheme, which builds the app and embeds the widget extension. In Xcode, select this scheme rather than the Swift package’s similarly named executable scheme.

Or build with your Team ID explicitly:
```bash
QUOTAPULSE_TEAM_ID=XXXXXXXXXX ./scripts/build-xcode.sh
```

To install to Applications:
```bash
# Locate the built app in DerivedData or export from Xcode:
cp -R ~/Library/Developer/Xcode/DerivedData/QuotaPulse-*/Build/Products/Release/QuotaPulse.app /Applications/
open /Applications/QuotaPulse.app
```

### 5. Adding the Widget to Desktop or Notification Center

1. Launch `/Applications/QuotaPulse.app` once to trigger initial quota fetch and save snapshots.
2. Right-click on your Desktop and choose **Edit Widgets...** (or click the date/time in the menu bar to open Notification Center and click **Edit Widgets** at the bottom).
3. Search for **QuotaPulse** in the widget gallery.
4. Drag either the **Small** or **Medium** widget onto your desktop or Notification Center.
