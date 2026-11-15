# Personal SwiftUI client

The user explicitly chose this native SwiftUI iPhone client. `apps/mobile` remains the original
upstream mobile client. Apply personal iPhone UI changes here; do not port them into the upstream
mobile app or redesign desktop/web surfaces for a phone. This is the user-authorized exception to
the root phone-directory default.

Use the existing host, released Team API and shared Team client. Do not copy engine services into
this app. Merge original engine updates through `upstream`; add native screens only for features
the user selects. Preserve app identity, signing and existing device data.

Keep background technical failures quiet. Failed requested actions use the generic localized
error. Keep delivery states, internal recovery, security approvals and ordinary chat content.
Normal long-press menu text/icons are neutral; destructive actions are red.

Follow the root check rules and the shared simulator pool. Keep checks serial and source frozen
through each AppTesting run. Feature and bugfix changes stay local and uncommitted unless the user
explicitly requests a commit or delivery. A repository update does not authorize a live host upgrade.
