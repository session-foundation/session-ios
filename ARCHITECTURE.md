# Session iOS — High-Level Architecture

> A Decentralised, Onion-Routed, Private Messenger  
> Source: [github.com/session-foundation/session-ios](https://github.com/session-foundation/session-ios)  
> April 2026

---

## Table of Contents

1. [Overview](#1-overview)
2. [Glossary](#2-glossary)
3. [Architectural Principles](#3-architectural-principles)
4. [System Context](#4-system-context)
5. [Module Structure](#5-module-structure)
6. [Build and Distribution](#6-build-and-distribution)
7. [Core Architectural Patterns](#7-core-architectural-patterns)
8. [Config System and Cross-Device Sync](#8-config-system-and-cross-device-sync)
9. [Networking](#9-networking)
10. [Message Ingress, Processing, and Egress](#10-message-ingress-processing-and-egress)
11. [Pollers and Background Sync](#11-pollers-and-background-sync)
12. [Notifications](#12-notifications)
13. [Pro Architecture](#13-pro-architecture)
14. [Persistence](#14-persistence)
15. [Cryptography and Identity](#15-cryptography-and-identity)
16. [UI Architecture](#16-ui-architecture)
17. [Dependency Injection](#17-dependency-injection)
18. [Key Dependencies](#18-key-dependencies)
19. [Testing](#19-testing)
20. [End-to-End Flow Summaries](#20-end-to-end-flow-summaries)
21. [Practical Notes for New Developers](#21-practical-notes-for-new-developers)
22. [Future Work](#22-future-work)

---

## 1. Overview

Session is an open-source, end-to-end encrypted messaging application that eliminates reliance on centralised servers. Unlike conventional messengers, Session requires no phone number or email address for registration. Instead, users are identified by a cryptographic public key (Session ID). All messages are routed through a decentralised network of Session Nodes using onion routing, concealing both message content and metadata - including users' IP addresses - from any single node in the network.

The iOS client is written primarily in Swift, with performance-critical and cross-platform logic delegated to a shared C++ library (libSession). The codebase is organised as a modular monorepo: a thin main application target sits on top of several focused Swift framework modules and two Apple app extensions.

---

## 2. Glossary

| Term | Meaning |
|---|---|
| **Snode** | A Session Network service node. |
| **Swarm** | The subset of snodes responsible for a given account or group. |
| **Config** | An encrypted, native libSession object used for cross-device state sync. |
| **Closed group** | An encrypted group backed by swarm storage and group config objects. |
| **Community / open group** | A server-hosted public chat (SOGS), polled separately from swarm DMs. |
| **SOGS** | Session Open Group Server — independently operated HTTP server hosting community conversations. |
| **Job** | A unit of work persisted to the database before execution, providing reliable retry and crash-recovery semantics. |
| **libSession** | Cross-platform C/C++ library implementing cryptographic primitives, config serialisation, snode cache management, and onion path construction. |

---

## 3. Architectural Principles

- **No central servers.** Messages are stored on and relayed by a distributed, Sybil-resistant network of Session Nodes. No single entity can read, censor, or correlate user traffic.
- **No phone number or email.** Identity is a 66-character Ed25519 public key (Session ID), generated on-device.
- **Onion routing via libQuic.** All network traffic passes through a chain of three Session Nodes. Each hop re-encrypts the payload, ensuring that no node knows both the sender and the destination.
- **End-to-end encryption.** Messages are encrypted using the Session Protocol (built upon the widely audited libsodium cryptographic library) for 1-1 conversations and a double-ratchet variant for closed groups, implemented in libSession.
- **Cross-platform parity via libSession.** A shared C++ library handles cryptographic primitives, config message handling, snode cache management, and network path building, ensuring behavioural consistency across iOS, Android, and Desktop clients.
- **Layered module separation.** Strict boundaries between networking, messaging, UI, and utilities reduce coupling and simplify independent testing of each layer.

---

## 4. System Context

The Session iOS app interacts with two categories of external infrastructure, plus a small set of dedicated server-backed APIs.

### 4.1 Session Node Network (Swarms)

Session Nodes are the backbone of the network. They form "swarms" - subsets of nodes collectively responsible for storing messages destined for a given Session ID. The iOS client polls its assigned swarm for new messages and sends outbound messages via onion-routed requests that terminate at the destination swarm.

### 4.2 Session Open Group Servers (SOGS)

Community (open group) conversations are hosted on SOGS - independently operated HTTP servers. The client polls SOGS for community messages and sends posts via onion-routed HTTP requests. SOGS operators cannot read 1-1 or closed group messages, which never touch their servers.


### 4.3 Dedicated Server-Backed APIs

Some features use conventional server APIs rather than swarm storage. There are four centralised servers the app communicates with:

- **Push Notification Server** - handles push registration and delivers encrypted push payloads to devices.
- **File Server** - stores and serves user-uploaded content such as profile avatars and attachments, also used to retrieve app version information.
- **Token Server** - provides Session Network and SENT token data (price, network size, staking requirement, market cap) displayed in the Session Network screen. Requests are authenticated using a version-blinded Ed25519 key pair.
- **Session Pro Server** - provides entitlement, proof, and revocation APIs for the Pro subscription.

---

## 5. Module Structure

The repository is organised as a collection of in-project Swift frameworks plus a main application target and two Apple extensions. The dependency graph flows strictly downward — upper layers import lower layers; lower layers never import upper layers.

| Module | Responsibility |
|---|---|
| **Session** (App Target) | Root application target. Contains app delegate, scene lifecycle, top-level UIKit view controllers/SwiftUI views (conversation list, settings, onboarding) and view models, audio/video call infrastructure, generated emoji structure, notification handling, and the job scheduler. It imports all framework modules. |
| **SessionMessagingKit** | Core messaging logic: message model types, send/receive pipelines, job queue, polling orchestration for swarms and SOGS, attachment handling, and config-message application. The largest and most central module. |
| **SessionNetworkingKit** | Abstracts all network I/O. Interacts with [libSession](https://github.com/session-foundation/libsession-util) for request routing and transport, defines API interactions, and retry logic. Consumed by SessionMessagingKit. |
| **SessionUIKit** | Shared, reusable SwiftUI/UIKit components and screens: themed colours, typography, custom cells, media viewers, reaction pickers, and other UI primitives. Has no knowledge of Session-specific business logic. |
| **SessionUtilitiesKit** | Cross-cutting utilities: type extensions, threading helpers, dependency injection container, UserDefaults wrappers (including App Group access), logging infrastructure, and shared test utilities. |
| **SignalUtilitiesKit** | The subset of the original Signal iOS codebase retained during Session's fork. Provides certain media handling utilities, and legacy protocol glue. Being progressively replaced by native Session code. |
| **libSession** (C++ / SPM) | A cross-platform C++ library consumed via Swift Package Manager. Implements Ed25519 key management, the Session Protocol double-ratchet, config-message serialisation (protobuf), snode swarm cache, onion-path construction, and libQuic bindings. Source at [github.com/session-foundation/libsession-util](https://github.com/session-foundation/libsession-util). |

### 5.1 App Extensions

| Extension | Purpose |
|---|---|
| **SessionNotificationServiceExtension** | Processes incoming APNs push notifications in the background. Decrypts the push payload with the full message, and displays a local notification — all without launching the main app. |
| **SessionShareExtension** | Implements the iOS Share Sheet entry point, allowing users to send media and text to Session conversations from other apps. Builds a minimal network stack (single onion path) to submit the shared content. |

### 5.2 Dependency Graph

```
Session (App Target)
│
├──► SessionMessagingKit
│         ├──► SessionNetworkingKit
│         │          │
│         │          ├──► SessionUtilitiesKit 
│         │          │
│         │          └──► libSession (C++ via SPM)
│         │
│         ├──► SessionUIKit
│         │
│         ├──► SessionUtilitiesKit 
│         │
│         ├──► SignalUtilitiesKit 
│         │
│         └──► libSession (C++ via SPM - for cryptography and config messages)
│
├──► SessionUIKit
│
├──► SessionUtilitiesKit
│
└──► SignalUtilitiesKit

SessionShareExtension
│
├──► SessionNetworkingKit
│
├──► SessionMessagingKit
│
├──► SessionUIKit
│
├──► SessionUtilitiesKit
│
└──► SignalUtilitiesKit

SessionNotificationServiceExtension
│
├──► SessionNetworkingKit
│
├──► SessionMessagingKit
│
├──► SessionUtilitiesKit
│
└──► SessionUIKit

```

---

## 6. Build and Distribution

- **Xcode project:** `Session.xcodeproj`. Minimum deployment target is currently set to iOS 15, building against the iOS 26 SDK.
- **libSession via SPM:** An optional scheme (`Session_CompileLibSession`) supports building it from source for contributors working on the C++ layer.
- **Three signed targets:** The main Session app, `SessionShareExtension`, and `SessionNotificationServiceExtension`. All share a single App Group container.
- **Signed releases:** Release IPA files are GPG-signed by the Session Technology Foundation release key. SHA-256 checksums and signatures are published alongside each GitHub release for reproducibility verification.
- **CI:** Drone is used for automated build and test runs on pull requests (see `.drone.jsonnet`).

---

## 7. Core Architectural Patterns

Several patterns repeat across the entire app.

### 7.1 Observation-Driven Reactivity

The dominant reactivity model in iOS is event observation. State is primarily propagated through the [`ObservationManager`](https://github.com/session-foundation/session-ios/blob/master/SessionUtilitiesKit/Observations/ObservationManager.swift) and observed reactively at the UI and service layer:

- The code sends events to the `ObservationManager`.
- View models register for events by specifying a set of `ObservableKey`'s (which get updated after every query.
- The `ObservationManager` notifies any subscribers whenever events come through, triggering a re-query of the state (which may or may not involve fetching data from the database).
- SwiftUI and UIKit views subscribe to the view model's published state and re-render reactively.

This gives consistency across the app: most features are built as reactive observation pipelines rather than imperative refresh logic. One-shot UI events use separate mechanisms (e.g. callbacks or PassthroughSubject) with no replay.

**Note:** Previously we were using GRDB's `ValueObservation` and `DatabaseRegionObservation` to drive these UI updates (and still are in some places), but this is being deprecated and replaced with the `ObservationManager` to help de-couple the UI from the database state (as the plan is to shift more business logic across to `libSession` which may need to drive events itself).

### 7.2 Config-First Shared State

Shared user state (contacts, group membership, conversation metadata, profile) is not authored directly in SQLite tables. It is authored in config objects backed by libSession, then projected into local GRDB tables for queryability and UI rendering.

The important ownership boundaries are:

- **Config objects** are the source of truth for cross-device user state.
- **SQLite/GRDB tables** are local projections optimised for queries, joins, and UI rendering.
- **UserDefaults** store local-only application settings that are not synced across devices.

If something should sync across devices, it belongs in config first and only then in relational storage.

### 7.3 Persistent Job Queue

Reliable send, upload, download, and sync work is handled through `JobRunner`, a persistent in-app job system backed by GRDB. Key characteristics:

- Jobs are written to the database before execution, providing crash-recovery guarantees.
- Different job categories (message send, attachment upload/download, config sync, etc.) are dispatched on separate queues to prevent one slow job type from blocking another.
- Failures retry with exponential backoff.
- Pending jobs are resumed from the database on next launch.

The job queue is a core reliability mechanism and should not be treated as an implementation detail. Any work that must eventually complete - even across app restarts or network outages - should be modelled as a job.

### 7.4 Dependency Injection via `Dependencies`

The `Dependencies` struct (in `SessionUtilitiesKit`) acts as an explicit dependency container threaded through most of the app. Rather than relying on singletons, callers receive a `Dependencies` instance and resolve concrete services from it. This pattern makes it straightforward to inject test doubles and enables environment-level overrides in debug builds without touching production paths.

**Note:** Currently this container uses `@ThreadSafeObject` extensively to provide renentrant read-write locks to each dependency, this is performant and works for the most part but is also custom code and somewhat convoluted to maintain. Ideally we would rework this to be `Actor` based but will likely need to have the code fully converted to MVVM to deal with async access of `Dependencies`. Doing so could also create other issues (eg. calling actor functions from within database queries which are not async) so it's possible other solutions may be required (eg. reworking to a simpler initialisation `NSLock` for `Dependencies` but leaving it a class, having each dependency be an `Actor` so they are thread safe).

---

## 8. Config System and Cross-Device Sync

The config system is one of the most important pieces of the app. It is how Session keeps user state consistent across devices without a central plaintext server.

### 8.1 What Lives in Config

| Config domain | Content |
|---|---|
| **User Profile** | Display name, avatar URL/key, Pro-related profile flags |
| **Contacts** | Contact list and per-contact metadata such as block state |
| **Convo Info Volatile** | Per-conversation metadata such as last-read timestamps |
| **User Groups** | Membership in closed groups and communities |
| **Group Info / Members / Keys** | Closed-group admin state, member list, and group encryption keys |

### 8.2 Ownership Model

libSession owns the native config objects. The Swift layer interacts with them through the `LibSession` namespace, which provides:

- lazy initialisation of per-account and per-group config instances
- thread-safe read and write access
- serialisation of config state to `ConfigDump` rows in GRDB
- emission of change notifications that trigger downstream reconciliation

There are two write patterns:

- Normal mutation: Swift callers use the provided mutating accessors under the `LibSession` namespace, which handle locking, persistence, and notification.
- Lower-level flows (e.g. merging incoming config messages) use more direct accessors with manual lifecycle management.

### 8.3 Source-of-Truth Boundaries

Config objects are the source of truth for cross-device state. GRDB tables are local projections. Shared preferences store local-only settings. This means:

- When a contact is blocked, that change goes into the Contacts config first.
- The GRDB `Contact` table row is updated as a consequence of config reconciliation, not as the primary action.
- If the two diverge (e.g. after a crash mid-sync), the config wins on next reconciliation.

### 8.4 Config Upload Path

A background job watches for config mutations and network path availability. When both conditions are met it pushes the serialised config delta to the user's swarm via an onion-routed store request. Upload is debounced to coalesce rapid local changes. Retries follow the standard job retry policy.

Group config upload is admin-only. Group keys are pushed before group info/members because downstream configs depend on the key material.

### 8.5 Reconciliation Back into the Database

A reconciliation layer listens to incoming config merges and keeps the GRDB model in sync. Its responsibilities include:

- ensuring GRDB thread/conversation rows exist for all config-backed conversations
- applying last-read timestamps from `ConvoInfoVolatile` config
- pruning GRDB rows when conversations disappear from config
- cleaning up community - and group-specific local state when configs remove them

This means the GRDB database is not a peer source of truth; it is a materialised local view derived from config plus message history.

### 8.6 Direct Merge Paths

Not all config changes arrive through periodic polling. Incoming push payloads can carry closed-group config updates directly. In those cases the push handling path can merge incoming group config messages into libSession immediately, before the normal periodic reconciliation pass updates GRDB.

---

## 9. Networking

All outbound traffic uses onion routing. `SessionNetworkingKit` coordinates with libSession to select a three-hop path of Session Nodes. Each hop is contacted over QUIC (via libQuic bindings in libSession), replacing the earlier HTTP/1.1-based transport. QUIC reduces round-trip latency and improves resilience on mobile networks.

### 9.1 Session Network Stack

The core request flow for swarm and snode traffic is:

```
Business API (typed operations)
  -> Retry wrapper (exponential-backoff retry of retryable failures)
  -> Batch coalescing (combines batch-compatible requests)
  -> Snode/Swarm targeting (adds swarm targeting and stale-node handling)
  -> Onion path selection and encryption (three-hop path via PathManager in libSession)
  -> libQuic transport (QUIC connection to guard node)
```

Responsibilities by layer:

- **Business APIs:** typed operations such as store/retrieve/delete message, signed with the account's Ed25519 key before leaving the app.
- **Retry wrapper:** handles retriable failures with backoff; each layer classifies errors and communicates retry intent upward so policy stays centralised.
- **Batch coalescing:** combines compatible requests into a single `/batch` call within a short window to reduce round-trips.
- **Swarm targeting:** resolves the correct swarm for a given Session ID and handles the case where a targeted node is no longer in the swarm (equivalent to Android's 421-handling).
- **Onion encryption:** libSession selects the three-hop path from its snode cache, wraps the payload with layered encryption, and hands it to the transport.
- **libQuic transport:** performs the actual network I/O over QUIC to the guard node.

Path building, snode cache management, and reachability detection are handled inside libSession to ensure cross-platform consistency. The iOS layer uses a thin Swift wrapper around the C++ API.

### 9.2 Dedicated Server APIs

Pro entitlement/proof/revocation, push registration, and app-version APIs use a separate server-API stack rather than swarm storage. These are still typed and injected, and are normally sent through the onion transport, but the backend authority and data model are server-backed. The same retry and error classification conventions apply.

### 9.3 Error Handling

Error handling is layered. Each level classifies failures and communicates retry intent upward. This means retry policy stays centralised and individual business APIs do not need to re-implement backoff logic.

---

## 10. Message Ingress, Processing, and Egress

### 10.1 Incoming Message Sources

Messages can enter through several paths:

- DM swarm polling
- closed-group swarm polling
- open-group/community SOGS polling
- decrypted APNs push notifications (via `SessionNotificationServiceExtension`)

The transport differs, but the app converges on shared parsing and processing stages as quickly as possible.

### 10.2 Message Parsing

`MessageReceiver` (in `SessionMessagingKit`) handles the initial parsing stage. It is responsible for:

- envelope decoding for 1-1, closed-group, and community messages
- delegating decryption to libSession
- signature and timestamp validation
- block-state checks
- self-send and duplicate detection
- extraction of Pro metadata carried in the envelope

The output is a typed, decrypted message ready for processing.

### 10.3 Message Processing

After parsing, messages are handed to the processing stage which:

- serialises work per conversation thread to prevent race conditions on shared thread state
- creates conversation threads when appropriate
- dispatches to message-type-specific handlers (visible messages, read receipts, typing indicators, call messages, group updates, unsend requests, etc.)
- updates thread read state after processing
- applies community reaction updates
- triggers disappearing-message scheduling for after-read expiry modes

The key design point is that parsing is not persistence. The processing stage is where transport data becomes durable app state in GRDB.

### 10.4 Outgoing Message Path

Outgoing work is handled through `JobRunner` (see §8.3). Key characteristics:

- send/upload/download jobs are persisted to GRDB before execution
- different job categories are dispatched on separate queues (message send, attachment upload, config sync, open group posting, etc.)
- community work is further partitioned by community address to avoid cross-community head-of-line blocking
- failures retry with exponential backoff
- pending jobs resume from GRDB after a crash or restart

This queue is the primary reliability mechanism for outbound delivery. Any message that needs to eventually reach its destination, even after an app restart or network outage, must go through a job.

### 10.5 Optimistic Message Sending

Outgoing messages are inserted into the UI immediately before the corresponding database write completes in order to provide the user immediate feedback regardless of what else is going on in the database (ie. other potentially blocking long write queries). When the user sends a message, `ConversationViewModel` generates an `OptimisticMessageData` containing a temporary negative `Int64` ID and a locally-construction `Interaction`, then emits it as an `updateScreen` event so the UI renders it instantly.

Once the database write succeeds, `associate(_:optimisticMessageId:to:)` records the mapping between the temporary ID and the real `interactinoId`. When the GRDB-backed state next updates, the optimistic entry is removed and replaced by the real record. If the write fails, the optimistic message is updated in-place to a `.failed` state rather than being removed, allowing the user to retry.

The temporary IDs are always negative (derived as `-Int64.max + sentTimestampMs`) to ensure they never collide with real database row IDs, and the ordering logic in `orederedIdsIncludingOptimisticMessages` merges them into the correct chronological position alongside real messages.

When debugging send failures it is worth checking both the optimistic state (still present with a negative ID?) and the job queue state (was the `SendMessageJob` persisted and dispatched?), as a failure in either layer produces different visible symptoms.

---

## 11. Pollers and Background Sync

The app has multiple poller types because different conversation types have different transport semantics. There is no single "poller" - the architecture intentionally separates DM swarm polling, group polling, community server polling, and periodic background wake-ups.

### 11.1 DM Poller

The DM poller is a session-lifetime service that polls the logged-in user's own swarm for incoming 1-1 messages and config updates. It is active while the app is in the foreground or has a background task. It exposes a `pollOnce()` API used by background workers and recovery flows.

### 11.2 Group Pollers

A closed-group poller manager derives the active set of closed-group pollers from login presence, network availability, and the User Groups config state. It creates and tears down individual `GroupPoller` instances automatically when group membership changes. Each group gets its own poller running on its own dispatch queue to prevent head-of-line blocking.

### 11.3 Community Pollers

`CommunityManager` is a session-lifetime service that watches the user's community config and maintains one poller per community server base URL - not per room. A single server poller can therefore service multiple rooms hosted on the same SOGS instance, which reduces redundant round-trips.

### 11.4 Background Fallback Polling

Push is not the only wake-up mechanism. When the app moves to the background a `BackgroundPoller` is registered to fire on a timer or in response to a background app refresh grant from iOS. It can trigger manual polls for:

- 1-1 DMs
- closed groups
- communities

Additionally this background poll will attempt to resucscribe for push notifications to ensure the current subscription doesn't expire (PN subscriptions automatically expire after 14 days).

This is the fallback path that keeps the app progressing when push delivery is unavailable or delayed, and when the process is backgrounded.

### 11.5 Why There Are Multiple Systems

When debugging message-delivery issues, identifying which polling path is responsible is usually the first step. The separation is intentional - each conversation type has different storage semantics, different namespaces on the network, and different failure modes. A failure in one path should not stall delivery in another.

---

## 12. Notifications

### 12.1 Notification Categories

iOS notification categories are managed at startup. The current categories are:

- one-to-one messages
- group messages
- community messages
- calls

Channel creation also handles locale-driven recreation so that user-visible category names stay correctly translated when the device locale changes.

### 12.2 Push Provider Wiring

The iOS app exclusively uses APNs for push delivery, the `SessionNotificationServiceExtension` handles all incoming push payloads without launching the main app.

### 12.3 Push Registration Flow

Push registration is a session-lifetime reactive service that watches:

- group config changes (groups that should receive push)
- push-enabled preference state
- current APNs device token availability

It computes the desired registration set (the logged-in account plus any closed group configured for push) and synchronises the actual backend registrations, enqueueing registration work as jobs to ensure reliable delivery even across network interruptions.

### 12.4 Push Receipt and Decryption

`SessionNotificationServiceExtension` is the common entry point for all incoming push payloads. It:

- unwraps and decrypts the push payload using the stored push notification key (a per-device key held in the Keychain, separate from the message encryption key)
- distinguishes between DM, group-message, group-config, and revoked-group payloads
- performs duplicate detection
- writes the decrypted message to an encrypted file in the App Group directory (rather than directly to GRDB, as part of the database relocation work described in §23)
- displays a `UNUserNotification` to the user

When the main app next enters the foreground it reads the encrypted notification files and saves them into GRDB.

A fallback generic notification is shown when a push payload carries a wake-up signal but no decryptable content.

### 12.5 Notification Display Policy

`NotificationPresenter` is the service responsible for deciding what to show in a notification. It respects the user's privacy preference and delegates to different display modes:

- show name and message content
- show name only
- show neither name nor content (generic "New Message")

Current notification semantics are intentionally reactive:

- A message is "new" if `dateSent > thread.lastRead`.
- Dismissing a notification does not mark the thread as read.
- Advancing `lastRead` (by opening the conversation) causes stale notifications to be removed automatically.

### 12.6 Read-State Side Effects

Read-receipt sending and disappearing-message timer starts (for after-read expiry modes) are triggered explicitly rather than reactively. `markAsReadIfNeeded` is called directly from scroll events and view lifecycle callbacks in `ConversationVC`, throttled to `100ms` to avoid hammering the database during fast scrolling. The method checks visible cells to determine the newest on-screen message, marks everything older as read, and sends read receipts and starts expiry timers as a direct consequence of that write - not as a downstream reactive effect.

---

## 13. Pro Architecture

Session Pro is a separate architecture slice layered on top of the rest of the app.

### 13.1 High-Level Model

Pro combines:

- a conventional backend for entitlement, proof, and revocation APIs
- platform subscription provider (App Store in-app purchase on iOS)
- local storage in GRDB
- mirrored config state in the user's profile config (so Pro status propagates to other devices and is visible to message recipients)

### 13.2 Subscription Provider

On iOS, the subscription provider is the App Store (StoreKit). The billing layer is therefore platform-dependent, separate from message transport. A no-op provider can be injected for non-Pro builds or test environments.

### 13.3 Entitlement Refresh

A background job talks to the Pro backend and updates local state. It:

- fetches entitlement details from the backend
- stores the result locally in GRDB
- mirrors expiry or removal state into the user's profile config
- schedules proof generation when appropriate

### 13.4 Proof Generation

A proof-generation job generates a rotating private key, requests a proof from the Pro backend, and stores the resulting proof and rotating key in the user's profile config. This is important because Pro is not only a local entitlement check - some Pro state is propagated through config and later attached to messages and profile rendering.

### 13.5 Revocation Polling

A revocation polling job keeps a local revocation list in sync with the backend. It appends future polling work based on the server-provided retry interval and prunes expired revocations from local storage.

### 13.6 Runtime Status Aggregation

`ProManager` (or equivalent runtime aggregator) combines:

- profile-config badge visibility
- locally cached Pro details
- debug overrides
- post-Pro launch state

It exposes a reactive publisher consumed by UI and other services and is responsible for scheduling revocation polling while Pro is active.

### 13.7 Message and Profile Effects

Pro is not only a settings page concern. It also affects:

- which profile features are shown in recipient views
- whether inbound message Pro metadata is accepted and surfaced
- feature flags stored in message records for later UI use

When debugging Pro issues, check both backend/job state and config/profile propagation into normal message and recipient models.

---

## 14. Persistence

### 14.1 Primary Database

The majority of persistent app data lives in a single SQLCipher-encrypted SQLite database managed via GRDB (`Storage`). The database is currently stored in the App Group container directory (see §23 for the ongoing relocation effort).

### 14.2 Database Security

- The SQLCipher key is generated at account creation and sealed in the iOS Keychain, tagged for the main application only.
- Login identity (Session ID and associated keys) is also stored in the Keychain.
- The push notification decryption key and the extension helper encryption key are stored as separate Keychain entries.

### 14.3 Schema Ownership

GRDB migrations are owned by the `Storage` layer in `SessionMessagingKit`. Migration records are stored in the database itself, and the migration runner is invoked at startup before any other database access.

### 14.4 Major Persistent Areas

| Area | Purpose |
|---|---|
| **Threads** | Conversation threads; tracks `lastRead`, `lastInteraction`, notification preferences |
| **Interactions** | All messages (visible, control, info) for all conversation types |
| **Attachments** | Attachment metadata and download state |
| **Contacts / Recipients** | Per-recipient settings and profile cache |
| **ClosedGroups / GroupMembers** | Closed group membership and admin state |
| **OpenGroups / OpenGroupCapabilities** | Community server metadata, rooms, polling state |
| **ConfigDump** | Serialised libSession config dumps per config domain |
| **Jobs** | Persisted job queue records for `JobRunner` |
| **SnodeReceivedMessageInfo** | Duplicate detection for incoming payloads |
| **BlindedIdLookup** | Cached blinded-ID mappings for community message attribution |
| **Pro state / Revocations** | Pro entitlement cache and revocation list |
| **Snode / Path / Server state** | Swarm, path, and polling state |
| **Profile images (App Group)** | Display pictures duplicated in App Group directory for extension access |

Not everything lives in SQLite:

- Local UI and behaviour preferences remain in `UserDefaults`.
- Encryption keys (database, push notification, extension helper) live in the Keychain.
- Decrypted notification payloads are temporarily written as encrypted files in the App Group directory by the notification extension before the main app ingests them.

---

## 15. Cryptography and Identity

- **AccountID (Session ID)** — A 66-character hex-encoded Ed25519 public key, generated entirely on-device at account creation with no registration required.
- **1-1 message encryption** — Double-ratchet (Session Protocol variant) implemented in libSession, providing forward secrecy and break-in recovery.
- **Closed groups** — A dedicated group key agreement protocol in libSession distributes a shared encryption key to members; each member re-encrypts with individual recipient keys.
- **Communities (SOGS)** — Messages are encrypted only at the transport layer (via onion routing). Community content is readable by all members.
- **Config messages** — User profile, contact list, and conversation settings are propagated across devices via encrypted configuration messages stored on the user swarm, synchronised by libSession's merge/diff logic.
- **Push notification key** — A per-device key stored in the Keychain used to add an additional encryption layer over push notification payloads, minimising metadata visible to the APNs intermediary.
- **No metadata server** — Because Session IDs are public keys, the network requires no central directory service. Snode swarms are looked up by hashing the Session ID.

---

## 16. UI Architecture

The UI is mid-migration from legacy UIKit/`SessionTableViewController` patterns to SwiftUI (`SessionListScreen`).

### 16.1 Migration Strategy

- New screens are generally written in SwiftUI.
- Legacy `SessionTableViewController`-based screens are retained until rewritten.
- The conversation screen (`ConversationVC`) is the most complex migration surface due to the interleaving of UI and business logic.
- Most settings screens are close to being ready to migrate, after which `SessionTableViewController` and `PagedDatabaseObserver` can be deprecated and removed.

### 16.2 Design System

`SessionUIKit` provides a shared design system for both SwiftUI and UIKit surfaces:

- Semantic colour palettes supporting multiple themes.
- A custom typography scale.
- Shared spacing, icon (Lucide font), and shape constants.
- Shared components: buttons, text fields, avatars, sheets, tab rows, app bars, media viewers, reaction pickers.

This keeps individual screens thin and ensures visual consistency across the app.

---

## 17. Dependency Injection

`Dependencies` (in `SessionUtilitiesKit`) is the application-wide dependency container. It is an explicit struct threaded through most of the codebase rather than a global singleton registry.

Important conventions:

- Long-lived managers are held inside `Dependencies` and expose reactive state via Combine publishers or GRDB observations.
- Test doubles are injected by constructing a `Dependencies` instance with mock implementations — no global state needs to be patched.
- Debug builds can inject alternative implementations (e.g. a dev/staging Pro backend) without modifying production code.

The most important architectural convention is not just "use `Dependencies`", but "inject long-lived managers via `Dependencies` and let them expose reactive state that the rest of the app observes".

---

## 18. Key Dependencies

| Dependency | Role |
|---|---|
| **CocoaLumberjack** | Structured, high-performance logging with persistent file-based log support. |
| **DeviceKit** | Simplifies retrieval of device metadata (model, system version), used for diagnostics and log exports. |
| **DifferenceKit** | High-performance diffing for `UITableView` and other collection-based UI. |
| **GRDB** | Type-safe SQLite toolkit with SQLCipher integration for full database encryption. The primary persistence layer. |
| **KeychainSwift** | Lightweight Keychain wrapper for securely storing sensitive data. |
| **LibSessionUtil** | Internal C/C++ library containing shared Session logic (see libSession above). |
| **Nimble** | Matcher framework providing a declarative DSL for unit test assertions. |
| **NVActivityIndicatorView** | Configurable loading indicators for consistent activity feedback in the UI. |
| **Punycode** | Unicode-to-ASCII encoding utility for ONS/SNS usage. |
| **Quick** | Behaviour-driven testing framework for structured, nested test definitions. |
| **SDWebImage** | Image loading and caching, used primarily for WebP decoding and rendering support. |
| **SDWebImageWebPCoder** | WebP-specific codec plugin for SDWebImage. |
| **Lucide** | Icon library packaged as a font, providing a lightweight and scalable icon set. |
| **SwiftProtobuf** | Swift Protocol Buffers implementation, used for cross-platform message serialisation. |
| **WebRTC** | Real-time communication framework for peer-to-peer audio and video calling. |

---

## 19. Testing

Each framework module has a corresponding test target (e.g. `SessionMessagingKitTests`, `SessionNetworkingKitTests`, `SessionUtilitiesKitTests`). A shared `TestUtilities` target provides a mocking system, database helpers, and fixtures reused across test targets.

Unit tests focus on message serialisation/deserialisation, job queue logic, encryption round-trips, and GRDB query correctness. The `Dependencies` injection pattern means most components can be tested in isolation by constructing a `Dependencies` with mock implementations - no global state patching required.

CI is configured using Drone (see `.drone.jsonnet`) and runs on each pull request to the `master` branch.

---

## 20. End-to-End Flow Summaries

### 20.1 App Startup and Login

```
AppDelegate.application(_:didFinishLaunchingWithOptions:)
  -> process-wide initialisation
     -> SQLCipher/GRDB setup
     -> libSession initialisation
     -> Dependencies container setup
     -> notification channel registration
     -> JobRunner starts process-lifetime jobs
  -> login state observed
     -> if logged in: session-lifetime services started
        -> config upload/sync
        -> DM poller
        -> group pollers
        -> push registration
        -> Pro services
        -> other session-lifetime managers
```

### 20.2 Config Synchronisation

```
Local feature changes config via LibSession accessor
  -> libSession persists ConfigDump to GRDB
  -> change notification emitted
  -> config sync job enqueued via JobRunner
  -> job pushes config delta to swarm when path is available
  -> other devices merge config messages on next poll
  -> reconciliation layer updates GRDB tables from merged config state
```

### 20.3 Incoming Message Delivery

```
Poller or push extension receives encrypted envelope
  -> MessageReceiver parses and decrypts via libSession
  -> typed message written to GRDB in transaction
  -> Observable events are emitted
  -> ViewModels update published state
  -> SwiftUI/UIKit views re-render
  -> NotificationPresenter updates or dismisses notifications as needed
```

### 20.4 Outgoing Message Delivery

```
User action triggers send
  -> JobRunner persists SendMessageJob to GRDB
  -> job serialises and encrypts message via libSession
  -> SessionNetworkingKit constructs onion request
  -> libQuic delivers to guard node
  -> payload relayed hop-by-hop to destination swarm
  -> on success: GRDB interaction status updated
  -> reactive observation refreshes UI
```

---

## 21. Practical Notes for New Developers

The highest-value mental model for a new developer is:

- **Shared state starts in config, not SQLite.** If you want to change something that should be visible on another device, start with the libSession config accessor, not the GRDB table.
- **Most runtime behaviour is implemented as session-lifetime reactive services.** Long-running services start when the app is opened and stop on backvground/close. They expose state via Combine publishers or the ObservationManager rather than explicit callbacks.
- **Login state controls a large set of background services.** A surprising number of things silently do nothing until a valid identity is present.
- **Polling and notifications are tightly coupled.** Message delivery debugging almost always involves identifying which of the four polling paths (DM, group, community, background fallback) is responsible.
- **Pro is a separate server-backed subsystem that feeds back into core profile/message state.** Pro bugs can appear in message display or profile rendering, not just in the Pro settings screen.
- **The job queue is a reliability primitive, not an optimisation.** Removing or bypassing it breaks crash-recovery and retry guarantees.
- **ObservationManage is the primary UI reactivity mechanism.** If a UI is not updating when you expect it to, check whether the relevant `ObservableKey` is being observed and emitted correctly.

When changing behaviour, identify which layer owns it first:

1. build/scheme configuration
2. app lifecycle / session-lifetime service
3. config source of truth (libSession)
4. GRDB relational projection
5. decentralised Session Network stack (`SessionNetworkingKit`)
6. conventional server-backed API stack
7. job queue
8. UI observation layer

That framing will usually narrow the relevant code faster than searching by feature name alone.

---

## 22. Future Work

#### Session Pro

Session Pro was in the final stages of testing and bugfixing on iOS, with Android and Desktop having already received approval. Once the remaining issues were resolved the next phase was cross-platform testing before a general release.

#### Database Relocation

iOS is very strict about processes accessing files while in the background - if any file is still being accessed when the process transitions to the background state it results in a `0xDEAD10CC` exception killing the process. The database is notorious for this when stored in the App Group container (as it currently is). iOS relaxes this constraint for databases stored in the app's Documents directory, but that location is inaccessible to the extensions.

After trying numerous approaches to work around this, the decision was made to move the database to the Documents directory and remove the possibility of the exception entirely. As part of this work:

- The `SessionNotificationServiceExtension` has already been "de-databased": it writes decrypted notification files to the App Group directory and the main app reads and ingests them on next foreground launch.
- The `SessionShareExtension` also needs to be updated to avoid direct database access, using similar file-based mechanisms for outgoing messages and a libSession-populated conversation list for its UI (**Note:** The conversation sort order and display pictures will need to be replicated to the App Group container so this UI can match the main app).
- Message deduplication mechanisms that previously relied on the database need to be recreated in the extension layer.

#### SwiftUI Refactor

We are slowly going through and refactoring the UI from using UIKit to using SwiftUI, a lot of work has been done for this and we are at the point where the majority of settings screens in the app should be able to swapped over (resulting in the `SessionTableViewController` and `PagedDatabaseObserver` being able to be deprecated and removed shortly after). The most difficult screen to refactor will be the `ConversationVC` as it is incredibly complex and mixes both UI and logic at the moment.

#### Removing SignalUtilitiesKit

`SignalUtilitiesKit` is a holdover from the original Signal codebase. It is currently dependent on all other frameworks and primarily contains attachment editing and viewing UI. Once these are refactored into SwiftUI within `SessionUIKit`, the framework can be removed entirely, improving build times and reducing intra-framework dependencies.

#### Migrating logic to libSession

[libSession](https://github.com/session-foundation/libsession-util) is our cross platform C/C++ library which manages a number of complicated processes for Session. In the past each client (iOS, Android & Desktop) implemented every bit of logic natively, unfortunately this resulted in much slower progress as it required implementing, testing and "solving" complicated mechanisms (like our cryptography) 3 times.

By shifting this logic into `libSession` we can implement the complex logic once and the clients can just wrap a more developer-friendly interface in order to use it. At the moment `libSession` is still relatively low-level in that it exposes direct cryptography functions that the clients call/use but we are slowly adding higher-level functions to migrate more business logic over - an example of this is the relatively new `encode`/`decode` functions for messages which allow libSession to decide *which* encryption/decryption should be used for a certain message depending on the type of conversation it belongs to (rather than the application needing to decide).

iOS has been using libSession for networking for a while (with it managing Onion Routing and swapping to `libQuic` as we did), eventually the plan would be fore `libSession` to acstract the polling mechanism the clients currently use which would allow us to eventually swap to a push-based mechanism in the future with minimal impact to the clients.

---

*Session Technology Foundation — High-Level Architecture Document*

