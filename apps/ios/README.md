# Native iOS client

A SwiftUI client that starts with the supplied Messages references. It has a conversation list,
pinned conversations, search, swipe actions, context previews, chat, a native keyboard, reactions,
attachment cards, and contact details. The minimum deployment target is iOS 26.

## Run

Use the installed Xcode, XcodeGen and the pinned Bun version (1.4.2). From the repository root:

```sh
bun install --frozen-lockfile
xcodegen generate --spec apps/ios/project.yml
open apps/ios/OpenBotNative.xcodeproj
```

The Xcode build bundles `Transport/team-peer.ts` with Bun. Set `BUN_BINARY` if Bun is not on
Xcode's path. On this Mac the script also checks the local, ignored native tooling directory.

For a simulator, choose the `OpenBotNativeSimulator` scheme and the exact leased device below.
Its Simulator configuration uses `com.gerardomaruotti.openbot.native.simulator`. For this Mac's
personal iPhone installation, choose `OpenBotNative` with Debug configuration. The working device
setup uses team `X826DMJQDP`, Manual signing with profile `OpenBot Native Development` for the main
app, and Automatic signing for `OpenBotNotificationService`. Apply those local settings in Signing
& Capabilities after generation: `project.yml` defaults to Automatic and does not pin the team or
profile. Keep the existing app identifier `com.gerardomaruotti.openbot.native` and extension
identifier ending in `.NotificationService`.
Connect and unlock the iPhone, select it in Xcode, then use Run to build and install. Keep the
same team and identifiers when updating an existing personal installation; do not uninstall it
to resolve a signing error. This local development path does not upload or distribute a build.

On this Mac, acquire the shared simulator pool lease before a build or device session:

```sh
simpool run --device pro -- xcodebuild \
  -project apps/ios/OpenBotNative.xcodeproj \
  -scheme OpenBotNativeSimulator -configuration Simulator \
  -destination '{destination}' \
  -derivedDataPath .openbot-build/native-ios/DerivedData build
```

Run that build command from the repository root after generating the project. For an Xcode Run
or manual inspection, hold a `simpool hold --device pro` lease throughout the session and select
its exact device ID. The lease can return a private clone when the normal device is busy.
Release the lease after closing your device session. Do not use another session's simulator.
Keep normal simulator signing enabled: the account session needs Keychain access.

## Connect to the Mac

Open **Edit → Mac Connection**, then sign in to the same OpenBot account as the Mac.
Enter the fresh email code, or use the Mac's Mobile Connect link. The Mac must be running,
signed in and available. Choose a Mac if the account has more than one.

`AgentConnection` owns account and host state. `ConversationStore` projects the host's agents,
the most recent messages per opened conversation and streamed message updates into the native
views. Sending queues a real agent turn on that host. Provider authentication, tools and routines
continue to run on the Mac. This client does not ask for a provider API key.

`HostTransport` embeds the bundled, shared Team WebRTC client in a nonpersistent `WKWebView`.
All visible UI is SwiftUI. Account requests use an origin-scoped native `URLSession`; credentials
cannot follow an off-origin redirect. Release builds require HTTPS. Debug builds also allow
localhost and canonical private IPv4 addresses for the development account service.
`OPENBOT_NATIVE_ACCOUNT_URL` defaults to `https://api.openbot.run` at build time.

The account session, pinned host keys and AES-256-GCM workspace key stay in Keychain. Recent
conversations and the text outbox are encrypted in Application Support, excluded from backup,
and bound to account, host and membership. A warm start opens the last cached chat before the
network connects. The Mac database remains authoritative for delivered conversations.
Sign-out and account expiry delete the cache/outbox and key. A successful directory refresh
removes copies for hosts and memberships that the account can no longer access.

Unsent text drafts and their reply targets are saved per conversation in the same encrypted
workspace. Each user edit triggers an immediate encrypted write; streamed history updates use a
separate 350 ms batch. Navigating back also flushes the draft. Sending clears its text and target in the
same durable write that accepts the outgoing message. A failed durable write blocks dispatch.
An explicit failed Send shows **Something went wrong.** and keeps the draft.
Sign-out always confirms removal of saved chats, drafts and all unsent messages on this device,
including other Macs. Local credentials, cache, notification keys and the embedded network context
are cleared without waiting for the account service. A separate account-session revocation attempt
has a three-second limit; an unconfirmed explicit sign-out shows the same generic error and is
never saved for retry.

Sending first saves a stable client ID and text in the encrypted outbox. It shows **Waiting to
send** while offline and dispatches in chat order when the foreground app reconnects. An
interrupted send can retry automatically only with the same membership, the host's deduplication
capability and the original attempt time less than 12 hours ago. Reconnect never creates a fresh
ID for that retry. This is bounded retry protection, not an unlimited exactly-once guarantee.
Confirmed host message IDs replace pending rows without matching message text. Long-press an
unsent row to cancel it. An unconfirmed row has a separate removal action that explains that
the Mac might already have received it.

Blank text and commentary are not reply bubbles. Unknown streamed IDs wait for host metadata;
all message metadata and revisions remain available for reconciliation. Commentary is selected
by its type, never by matching its words.

Live mode supports text, files and photos, older conversation pages, command/file/permission approvals,
and interactive questions. Full unresolved question text is recovered from host history before a
response can be sent. Choice, multiple-choice, free-text and private answers are transient; they are
never queued or written to the workspace cache. A response rechecks the current host request and is
sent once. Stop response rechecks the current turn before interrupting it.

Action confirmations recover the complete normalized host block, including its full preview,
fields, choices, named actions and danger/hold requirements. The whole block is checked again
before submission. Unsupported rich blocks, missing confirmation blocks and bounded fallback
questions require review on the Mac. Ordinary short questions remain available on the phone;
private answers are never draft text. Confirmation previews preserve complete plain text, including
any Markdown syntax.

The native interface keeps background connection, synchronization and routine failures quiet.
It has no passive technical banners, failure cards or failure badges. Explicit failed actions on
the current screen use **Something went wrong.** in English and **Qualcosa è andato storto.** in
Italian. A failed ordinary chat task observed in the active conversation uses the same generic
text; restoring an old failure does not show it again. Routine history hides failed, interrupted,
cancelled and attention-needed runs. Internal failure states, recovery guards and diagnostics remain.
Ordinary user and assistant content is preserved, including technical text requested in a chat.

Delivery to the Mac and successful execution remain separate states. **Waiting to send**, **Sent**,
**Not Sent** and neutral **Pending** keep their existing delivery meanings. Raw provider errors and
page contents are not retained in the native workspace. Browser sign-in requests remain because
they require a user action. Browser requests
can be opened or cancelled on the phone after fresh exact-request checks. Supported hosts share
JPEG frames and accept touch, scroll and keyboard input. Password/code responses are transient;
they are not drafts and never enter the workspace cache. Closing, backgrounding or changing the
account/host releases the viewer and clears frames and input. Unsupported hosts retain the Mac
handoff. Browser requests recover after reconnect and are not an offline status promise.

Files use the existing authenticated peer transfer with its digest validation, up to ten files and
10 MiB per file. Upload requires an online host. Once a message is saved, its host draft IDs are
part of the encrypted outbox and use the same stable message ID on retry. File bytes remain on the
host; the app keeps only metadata. Expired or unavailable drafts can fail and must be selected again.
Downloaded previews are protected, excluded from backup and removed when closed, when the chat or
account changes, or on the next app start after a crash. Native Files and Photos pickers grant
access only to selected content. Camera capture re-encodes a bounded still without location metadata
and adds it as a draft attachment after the person accepts the photo; sending remains separate.

Load earlier messages reads the host's opaque cursor and keeps the current scroll position.
Earlier pages remain in memory; the encrypted restart cache keeps only the newest 50 and the
matching cursor. Live roster previews and local read/pin state update the conversation list.
Long-press a message to react, copy it or open Select Text. The native menu owns this gesture in
both live and sample conversations. The selection sheet keeps the
complete answer available for native text selection. HTTP/HTTPS links open from the bubble.
Bot and message context previews use bounded viewports so long text keeps a readable width.
Short message previews keep their natural height, and file metadata remains visible.
Normal long-press menu text and icons use neutral colors; destructive actions use red.

Swipe from the leading screen edge to return to the bot list with the native interactive transition.
Reply swipes must start outside the leading 24 points. Cancelled drags reset without selecting a reply.
Swipe a delivered message to the right away from that edge, or choose Reply from its menu, to open its replies above
the blurred conversation. The focused view shows the original message and its loaded replies
above the native Reply composer. Send keeps that view open. Close replies keeps unsent text,
removes its reply target and sends nothing; the text then becomes an ordinary message draft.
Delivered replies use outlined original-message bubbles, reply counts and connecting rules in the
main conversation. Only consecutive messages with the same reply root share a group, so unrelated
messages keep their order. Counts cover loaded replies, including an associated assistant answer;
Load earlier messages can add older replies. An assistant answer joins a group only when host turn
metadata proves the turn's start and all its user inputs refer to the same root. Mixed or incomplete
turns are not guessed from time or message position.

Reply targets stay with encrypted drafts and stable-ID outbox records, including offline sends.
The host's existing reply context reaches the agent. A missing or cross-chat target fails before
submission; the app does not silently turn it into an ordinary message. Referenced original text
outside the newest fifty cached messages is retained in a bounded encrypted reference set.

The Edit menu and agent details open native agent and routine management. Agent creation has an
explicit first message; edits and removal recheck current permissions and revisions. Routine editors
support all nine schedule kinds, preserve untouched schedules and interval anchors, and expose
capability-gated run locations and recovery policies. Manual execution shows actual run history; an
unconfirmed mutation requires review before another attempt. Live reactions and member-owned mute
settings use the existing host routes. A mute does not disable notifications for other members.

The composer microphone offers on-device dictation where the device/language supports it. Audio is
not stored or uploaded. Stop leads to review; Use Text appends to the current draft without sending.
Camera and dictation permission requests happen only after the person chooses the feature. Cancel,
background and account/chat changes discard transient capture. Provider installation/sign-in and
system permissions stay on the Mac. Existing agents can perform tasks from chat. The signed simulator journey tests native messaging
against a real account, Signal and host service with a deterministic provider. This is separate
from real model quality, physical-device behavior and everyday off-LAN hosting.

## Notifications

The native app includes notification permission, a local alert check, APNs registration callbacks,
per-account/host/membership keys shared through Keychain with a Notification Service Extension,
and verified notification-tap routing. The extension opens the existing host seal locally. The app
verifies the seal again on tap and refreshes host access before opening a conversation. Invalid or
unavailable keys show generic text and do not select a conversation. Sign-out and host removal
remove notification keys; account credentials are not shared with the extension.

**Edit → Mac Connection → Notifications** requests permission only when you choose it. **Send Test
Alert** tests the iPhone notification UI only; its footer states that it does not test delivery from
the Mac. The app suppresses remote alerts for the chat on screen. Registration updates are serialized,
and **Turn Off Alerts** unregisters this app from APNs before host cleanup. The scoped notification
keys stay available for a later opt-in; sign-out and loss of membership delete them. Permission and
opt-out actions cannot overlap. Registration updates send the current foreground state,
and the app sends `away` before pausing its peer. The host's existing held-event policy handles an
app that suspends before this update reaches it. Side-thread replies are turned off because this
native client does not yet open side-thread chats.

Remote registration is disabled by default. `OPENBOT_NATIVE_PUSH_RELAY_TOPIC` must match the app's
actual bundle ID only after its **private account relay** is configured for that topic and an APNs
key of the same Apple team. The public upstream relay uses `run.openbot.mobile`; it cannot deliver
to this app's topic. Do not redirect all iOS registrations or bypass the account service's per-send
session, membership and logout checks. Private development IDs and a sandbox key have been configured
for this personal build. The public account relay and the existing account have not been migrated.

The app and extension have separate identities and share only their notification Keychain group.
The app retains its original default Keychain group, so existing account and workspace keys remain
in that group. `OPENBOT_NATIVE_APNS_ENVIRONMENT` defaults to `development` for personal device
builds; configure it to match the provisioning profile when signing a distribution build. At runtime,
physical-device registration reads the signed profile's `aps-environment`; it does not infer the
value from Debug/Release. A build without a readable profile does not register. App Store distribution
is outside this development setup and needs a verified environment source before use.

Permission, local-alert and decoder checks alone do not prove APNs delivery or service-extension
execution. A separate test on this Mac's supported iOS simulator uses an own-topic sandbox key,
a private account relay and real Apple APNs. An Apple HTTP 200 response plus the decrypted
background notification verifies that path. This does not establish physical-iPhone behavior,
production APNs or everyday off-LAN hosting. Offline outbox delivery still resumes on foreground
reconnect.

Run `apptest run native-notifications` for the isolated notification delivery check. It uses the
real Team API registration, agent engine, host notification service, account session validation and
native decoder; its final Apple transport is simulated. It verifies foreground suppression, removal
and rejection after account-side session revocation. `notification-payload-e2e.ts` also checks the
host-to-Swift seal and malformed/tampered inputs. Results are written below `.openbot-build/native-ios`.
The native app suppresses authenticated failure notifications while it is in the foreground.
The extension converts failure alerts from older senders to neutral, silent, passive content.
This does not prove complete background suppression or live APNs delivery for the current source.

## Sample mode

A fresh install starts with an empty connection screen. **Edit → Restore Sample Conversations**
opens the local reference demo. `ConversationStore` saves demo edits in this app's preferences.
Sample sends stay on this device. The attachment cards have no original files, and
the read receipts are fixture content. Unavailable sample actions use the generic action error.
Live mode hides sample actions that do not have a host implementation.

Open **Edit → Restore Sample Conversations** to return to the reference state. The compose button
includes the sample phone conversation used for keyboard and reaction checks.

The existing Expo client remains available. No released Team API adapter or desktop database
schema is changed by this client.

## Haptic feedback

App feedback is enabled by default. **Edit → Mac Connection → Haptic Feedback** turns it off.
The setting persists on this device. Native controls retain the feedback set by iOS.

Accepted sends use one soft impact at intensity 0.45. This confirms local acceptance, including
offline queueing; it does not confirm delivery. Reply selection, reaction choices, pin changes,
custom question choices, ready attachment drafts and inserted dictation use selection feedback.
Confirmed agent/routine changes use the system success pattern. A routine run or an accepted
answer uses a soft acknowledgment, not a task-completed success. Unconfirmed changes use a warning.
Failed local send storage uses the system error pattern.

The scene owns one SwiftUI feedback host. Async UI actions check their originating visible screen
and workspace before giving feedback. Streamed text, typing, ordinary navigation, scrolling,
reconnection, incoming events and native toggles/pickers add no app pulse. Camera and microphone
capture retain their system behavior; recording haptics remain disabled.

The policy follows [Apple's haptic guidance](https://developer.apple.com/design/human-interface-guidelines/playing-haptics).
The soft impact value is a restrained starting point. Simulator checks verify the interface and
action paths; physical intensity and the interaction with iPhone system settings require a device test.

## Focused checks

### Keep the original engine current

Keep the personal SwiftUI client in `apps/ios` and its catalog in `packages/i18n/native`.
It uses the original host and shared Team client. Original engine updates can be merged without
rebuilding every desktop feature as a phone screen; new phone controls remain an explicit choice.

`upstream` is the original OpenBot repository and `origin` is the personal fork.
Run `python3 apps/ios/scripts/sync-upstream.py` to fetch and list incoming commits.
After reviewing and committing personal work, use `--merge` from the personal feature branch.
The command stops before a merge if the working copy is dirty. It does not stash, reset, commit,
push or publish. Resolve any merge conflict and run the affected checks before committing the merge.
Use `--no-fetch` to inspect the already fetched reference without a network request.

### Autonomous simulator journeys

Run one lane at a time from the repository root, for example
`~/.local/bin/apptest run native-ui --device pro`. Replace `native-ui` with the needed lane below.
Each invocation starts a fresh isolated fixture and app identity; the lanes do not share
mutable test state.

| Lane | Selected journey | Main scope |
| --- | --- | --- |
| `native-ui` | `NativeMessagingJourney` | Sign-in, messaging/streaming, approvals/questions, outbox recovery, drafts, history and files. |
| `native-agents-ui` | `NativeAssistantFeaturesJourney/testNativeAgentManagement` | Member-only alert preferences and synthetic agent creation, editing and removal. |
| `native-routines-ui` | `NativeAssistantFeaturesJourney/testNativeRoutineReview` | Synthetic routine editing, pause/resume, manual execution, history and lost-receipt review. |
| `native-replies-ui` | `NativeAssistantFeaturesJourney/testNativeReplies` | Reactions, native selection/copy, swipe replies, retained drafts, offline target delivery and reply groups. |
| `native-persistence-ui` | `NativePersistenceJourney` | Actual file-write failure, durable queue recovery after writes resume, one host delivery and unsent draft preservation. |
| `native-sample-ui` | `NativeSampleJourney/testSampleReactionAndRestart` | Sample reactions across restart, reaction removal, local send and unchanged host transcript. |
| `native-context-ui` | `NativeSampleJourney/testContextPreviewAndEdgeNavigation` | Cancelled and completed edge-back, retained drafts, interior swipe Reply, bounded long previews and edge-back immediately after menu dismissal. |
| `native-assistant-ui` | `NativeAssistantFeaturesJourney/testNativeAssistantFeatures` | Browser input/cancellation, capture cancellation with draft retention, and sign-out/restart. |
| `native-permission-recovery-ui` | `NativePermissionRecoveryJourney` | Definite access refusal, preserved drafts and safe recovery after access returns. |
| `native-receipt-recovery-ui` | `NativeReceiptRecoveryJourney` | Lost delivery confirmation, app restart and one host delivery. |
| `native-quiet-ui` | `NativeQuietInterfaceJourney` | Quiet passive routine failure, preserved technical chat content, generic explicit Send failure and draft retention. |

The shared runner leases the approved simulator, builds a separate **OpenBot Simulator** app,
and stores the Xcode result bundle and host logs in the printed evidence directory. Each run has
a new app identifier, Keychain scope and host profile. It does not replace the iPhone app or use
the production account, saved agents, routines, provider credentials or model credits.
The runner installs its unique app and performs one normal restart of its exclusively leased
simulator before testing. This lets iOS create the fresh app's notification client at boot. It
preserves simulator data and does not override notification permission or the banner assertion.

The fixture starts the real account service domain, Signal process, SQLite agent store, Team API,
host WebRTC renderer in headless Chrome, and native app transport. The provider executable emits
deterministic app-server replies and requests; it uses no model credits or real provider account.
Assertions read actual host records and outcomes as well as native UI. A failed or empty Xcode
test run fails the command. The table describes intended coverage; it is not a current pass report.

The local fixture needs an installed Chrome or Playwright headless Chrome. Set
`OPENBOT_NATIVE_CHROME` to its executable if discovery does not find it. The Bun fallback from
`scripts/build-transport.sh` is also used by the test runner. Generated databases and credentials
stay in the run's fixture folder; the runner stops its services when the check ends.

For a subsequent Device panel inspection, set `OPENBOT_NATIVE_INSPECT_AFTER_TESTS=1` on the same
command. After the automated journey passes, `inspection.json` gives the exact leased device,
app identifier and completion-file path. Use the device tools to inspect the app, close that device
session, then create the completion file. The shared runner keeps the lease and isolated host until
that step ends, with a ten-minute limit.

A passing run verifies the selected native path against a deterministic provider. It does not
test model quality, production routing, TURN relay, background delivery, APNs or physical iPhone
behavior. Offline sending still resumes when the app is active and connects to its host.

The persistence fixture changes only the fresh run's registered UUID app container. It resolves
the current data container after Xcode installation, preserves the workspace during the fault,
and restores it during fixture cleanup. It does not replace the product storage implementation.

### Native performance benchmark

`scripts/performance-app.swift` is a separate simulator-only entry using the production native
model and encrypted disk code. It is not linked into the iPhone app. It creates a unique app and
synthetic account with no network connection. The projection workload uses 50, 500 and 1,500 rows,
two warmups and seven measured samples. It checks returned data as well as elapsed time.

Hold a shared pool lease throughout preparation, measurement and cleanup. From the repository root:

```sh
python3 apps/ios/scripts/performance-e2e.py prepare baseline <leased-device-id>
```

Use the device tools to open the printed bundle. Attach Time Profiler to that app's PID before
pressing **Run Projection** once; press **Run Storage** separately after the trace ends. Then run
`python3 apps/ios/scripts/performance-e2e.py collect baseline <leased-device-id>`. Use a separate
`fixed` stage for changed code. Close the device session, remove each owned app with the runner's
`cleanup` action, then release the lease. Metadata and reports stay below
`.openbot-build/native-ios/performance-audit`.

The benchmark reports model/projection and file-boundary time, not scrolling FPS, keyboard latency,
battery use or physical iPhone speed. Cached reads exclude rebuilding; Time Profiler records the
whole workload, including page decoding and cache creation. Reply projections rebuild on message
metadata/visibility changes; text-only deltas update indexed rows. Scope changes clear the cache.

`bun apps/ios/scripts/assistant-features-e2e.ts` is a separate host/transport check. It verifies
DTO and revision guards, exact reply targets, completed synthetic routine delivery and browser DOM
input through the real host services. Its browser target is a labelled, network-blocked local
Chromium page behind BrowserViewGateway, Team API and WebRTC. This is not a real website or sign-in,
SwiftUI rendering, VoiceOver or physical-device evidence. The native capture journey checks opening
and cancelling the capture flow; real camera capture and on-device speech recognition still need
physical-device checks. None of these fixtures sends real email, books a reservation or opens a
real support ticket.

Accepted sends use the receipt's recipient delivery ID, which is the ID of the host's chat row.
Fresh host history also retires acknowledged placeholders from earlier native builds that stored
the mailbox ID. Queued and uncertain sends keep their original IDs and recovery limits.

### Native approvals

Live chats show command, file and permission approvals from the host. **Allow once** and **Decline**
use the existing Team API. The app refreshes current attention and checks the request identity and
details before sending a decision. It never queues or automatically retries that decision.
Shortened snapshot details disable Allow; the full request must be reviewed on the Mac. Approvals
remain transient and are recovered from the host after reconnect, rather than saved in the chat cache.

From the repository root:

```sh
bun node_modules/typescript/bin/tsc --noEmit -p apps/ios/Transport/tsconfig.json
bun apps/ios/scripts/network-boundary-e2e.ts
bun apps/ios/scripts/workspace-recovery-e2e.ts
bun apps/ios/scripts/confirmation-context-e2e.ts
```

The network script runs the real Foundation client against loopback HTTP fixtures. It checks
same-origin redirects, credential isolation, the response size limit and Release HTTPS policy.
It writes `.openbot-build/native-ios/network-e2e/report.json`. These checks and an Xcode build
do not prove that a real agent reply or reconnect works on iPhone.

The workspace script writes an actual encrypted file, exits, and starts a second process to
check interrupted sends, retry expiry, ordering, receipt settlement, membership isolation,
tamper rejection, removed-host cleanup and reply filtering. Its report is
`.openbot-build/native-ios/recovery-e2e/report.json`. It does not simulate WebRTC delivery.
The confirmation script starts an isolated real host and checks complete action context,
rejection before submission when context changes, named actions, cancellation and exact browser
handoff cancellation. Its provider and browser target are synthetic. An optional `--baseline`
argument takes a saved old transport HTML file for the clipped-preview regression comparison.
The sanitized report is `.openbot-build/native-ios/confirmation-context-e2e/report.json`.
`scripts/workspace-fixture-app.swift` is a separate simulator-only installer used to verify the
real app against a synthetic, unreachable host. It is not part of the product target and refuses
to replace an existing account or workspace.

## Visual references and text

`AppIcon.icon` is the editable Icon Composer source. It contains separate open-loop and reply-stroke
SVG layers. Icon Composer supplies Default, Dark, Clear Light/Dark and Tinted Light/Dark appearances;
the six renditions are exported for design generations 26 and 27. The build compiles the layered
source directly. Static exports and asset compilation are separate from native Home Screen checks.

The avatar crops come from the user-supplied reference screenshots. The UI uses system typography,
SF Symbols, native glass, native menus, and the native keyboard. Status bar content, Dynamic
Island activity, and keyboard language belong to iOS. The app uses OpenBot branding and does not
claim to be iMessage or show an unsupported encryption status.

Native interface text is in `packages/i18n/native/Localizable.xcstrings`, with English and Italian.
Xcode includes that catalog directly. Conversation names, messages, dates and file metadata in
`SampleConversations` are example content.
