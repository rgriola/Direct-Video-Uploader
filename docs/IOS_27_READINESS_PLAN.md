# iOS 27 Readiness Plan

**Created:** October 28, 2026  
**Status:** Planning; 0 of 7 execution phases accepted  
**Owners:** Unassigned; assign in P0  
**Goal:** A reliable native field-upload release, validated on iOS 27.

## Scope and platform policy

Prioritize the native field workflow over cosmetic dashboard expansion. Keep
essential authentication, Mux processing/reconciliation, clip sharing, and
deployment reliability in scope. This plan does not authorize implementation
changes by itself.

This is **iOS 27-ready, not automatically iOS 27-only**:

| Dimension | Policy |
|---|---|
| Xcode/compiler | Select a supported release; record exact compiler, SDK, and host macOS versions. |
| SDK | Build with a verified toolchain containing the iOS 27 SDK. |
| Swift language mode | Swift 6 is already configured. Focus on compiler compatibility and concurrency correctness, not a presumed Swift 5 migration. |
| Deployment minimum | Provisionally retain the iOS 17 goal, subject to toolchain support and fleet decisions. Resolve conflicting target settings before claiming compatibility. |
| Runtime validation | Exercise iOS 27, the approved minimum, and an intermediate supported fleet OS on physical devices. |

Recheck [Apple releases](https://developer.apple.com/news/releases/) and
[Xcode support](https://developer.apple.com/support/xcode/) in P0. Do not infer
compiler versions, deployment compatibility, or submission requirements from
product version names. Use availability checks and functional fallbacks for
newer APIs when supporting older systems.

**Excluded unless separately approved or a release blocker:** dashboard redesign,
photo-pipeline implementation, multiclip/external-camera expansion, live
streaming, new AI backends, broad enterprise-auth expansion, and framework
rewrites. Security and data-loss blockers cannot be excluded as cosmetic work.

## Source baseline, not runtime certification

Checked items below mean source was inspected; they do not mean release testing
passed.

- [x] [XcodeGen configuration](../ios/project.yml) selects Swift `6.0`, iOS `17.0`, and Xcode `16.0` metadata.
- [x] The [checked-in project](../ios/DirectVideoUploader.xcodeproj/project.pbxproj) contains project-level iOS `17.0` settings and app-target Debug/Release overrides of `18.6`. Effective iOS 17 support is not established.
- [x] XcodeGen has a target-level placeholder signing-team override; generated-project signing needs reconciliation.
- [x] [VideoUploadService](../ios/DirectVideoUploader/Services/VideoUploadService.swift) implements file-backed background uploads with UUID-derived session identifiers and a 600-second resource timeout.
- [x] [TranscriptionService](../ios/DirectVideoUploader/Services/TranscriptionService.swift) attempts cloud recognition before on-device fallback and contains unchecked Sendable continuation state requiring review.
- [x] Inspected project definitions have no native test target; [CI](../.github/workflows/ci.yml) has no native compile/test job.
- [x] [PhotosView](../ios/DirectVideoUploader/Views/Photos/PhotosView.swift) presents an unfinished "Coming Soon" surface.

Background-session reattachment, cancellation propagation, and callback safety
require investigation and tests. Source observations are not reproduced failure
reports. Historical completion percentages and build results are not current
readiness evidence.

## Tracking rules

1. Use stable IDs below in issues, PRs, and evidence.
2. Check an execution item only after its acceptance evidence is recorded.
3. Record owner, reviewer, revision/PR, environment, date, and evidence location.
4. Leave blocked work unchecked; record the blocker, dependency, and next action.
5. A phase closes only after its gate is accepted. Record dated scope decisions
   separately; a waiver is not a passed test.
6. Store sanitized evidence in an access-controlled location. Do not attach
   credentials, personal footage, transcripts, phone numbers, or precise GPS.

Copy a row for each active item:

| Item ID | Owner / reviewer | Status / blocker | Revision / PR | Environment | Evidence / date | Next action |
|---|---|---|---|---|---|---|
| P0-01 | Unassigned | Not started | - | - | - | Assign owners |

### Phase dashboard

Estimates are provisional engineering effort, not elapsed-time commitments.
Re-estimate after P0; allow separately for reviews and distribution waits.

| Phase | Dependency | Estimate | Gate |
|---|---|---|---|
| P0: Baseline and decisions | None | 1-2 days | Not started |
| P1: Toolchain and native test foundation | P0 | 2-4 days | Not started |
| P2: Lifecycle, concurrency, recovery | P1 | 5-10 days | Not started |
| P3: Essential backend integration | P0 contracts; final integration after P2 | 3-6 days | Not started |
| P4: Privacy, accessibility, release surface | Start after P0; close after P2/P3 | 3-6 days | Not started |
| P5: Physical-device qualification | P1-P4 accepted | 3-5 days | Not started |
| P6: TestFlight and release | P5 accepted | 2-4 days | Not started |

Total initial allowance: **19-37 engineer-days**, depending on findings. Backend
preparation and early privacy/accessibility work can run in parallel. This is
more conservative than an initial 2-5 week pilot estimate because it includes
explicit test infrastructure, review, and release gates.

## P0: Establish baseline and make release decisions

- [ ] **P0-01:** Assign implementation, review, QA, operations, and release owners; record source revision and evidence location.
- [ ] **P0-02:** Approve the supported device/OS fleet and toolchain. Resolve iOS 17 configuration versus app-target 18.6 overrides before changing either.
- [ ] **P0-03:** Decide distribution/signing, speech-processing policy, unfinished Photos-tab treatment, maximum media size/duration, cellular policy, and interruption/recovery promises.
- [ ] **P0-04:** Record a real-device baseline: login -> selection -> trim/metadata -> upload -> form -> Mux READY -> viewer/sharing -> archive; include speech when enabled.
- [ ] **P0-05:** Identify authoritative staging/production environments, representative test media, measurable quality thresholds, and rollback owner.
- [ ] **P0-GATE:** Decisions and owners are recorded, test devices are available, and baseline outcomes, including failures, are captured.

## P1: Modernize toolchain and establish native tests

- [ ] **P1-01:** Record exact Xcode, compiler, SDK, host macOS, runner, and dependency versions; verify the approved minimum OS is supported.
- [ ] **P1-02:** Reconcile XcodeGen/generated settings and signing in an approved implementation change. Explain generated differences and preserve unrelated work.
- [ ] **P1-03:** Add a native test target and deterministic test seams for transport, authentication, callback handling, and lifecycle; obtain testing-specialist review.
- [ ] **P1-04:** Add native build/test CI while retaining existing server, admin, and launch-screen checks. Cover minimum/latest supported simulator runtimes where available.
- [ ] **P1-GATE:** Generation is reproducible; Debug and Release compile; native tests pass. Unsupported toolchain/runtime combinations return to P0 rather than being silently dropped.

## P2: Prove lifecycle, concurrency, and recovery

- [ ] **P2-01:** Define durable session/task/asset/clip ownership, recoverable session identity, background-event handoff, and exactly-once completion semantics.
- [ ] **P2-02:** Specify persistence and source/temporary-file lifetime through suspension, system termination, reconciliation, cancellation, and confirmed cleanup.
- [ ] **P2-03:** Link cancellation to underlying network, speech, and export work; distinguish cancellation, errors, and no-speech results.
- [ ] **P2-04:** Obtain concurrency-specialist review of continuation state, unchecked Sendable usage, callback isolation, task ownership, and late callbacks.
- [ ] **P2-05:** Verify the actual upload transport and retry/resume contract rather than assuming documentation describes every path. Evaluate the 600-second timeout against approved media/network requirements.
- [ ] **P2-GATE:** Deterministic success/error/cancel/late-callback tests pass without double completion or orphaned active work. Initial device recovery tests reconcile correctly without duplicate logical results or premature file deletion.

## P3: Preserve essential backend and sharing behavior

- [ ] **P3-01:** Verify authentication/organization boundaries, expiry, relogin, logout, and their effects on pending uploads.
- [ ] **P3-02:** Exercise duplicate, reordered, and missing Mux events, reconciliation, and cleanup.
- [ ] **P3-03:** Verify idempotency across creation, retries, expired upload URLs, completion, form submission, and intended sharing side effects.
- [ ] **P3-04:** Verify viewer access/privacy and copy/share links match the approved sharing model; preserve older supported client compatibility.
- [ ] **P3-05:** Review the active deployment path, migration safety, restart recovery, and rollback using the [operations runbook](../HOME_SERVER_RUNBOOK.md). If the [Cloud Build path](../cloudbuild.yaml) is active, resolve its data-loss-accepting schema push before release use.
- [ ] **P3-GATE:** Repeated/reordered requests and restarts converge to one logical result per intended operation; unauthorized requests remain denied and accepted work is not lost.

## P4: Privacy, accessibility, and release surfaces

- [ ] **P4-01:** Align speech behavior, consent, permission copy, offline behavior, and privacy descriptions with the approved cloud/on-device policy.
- [ ] **P4-02:** Obtain security-specialist review of credentials, transcripts, GPS, media, logs, temporary files, retention, and deletion; resolve sensitive logging findings.
- [ ] **P4-03:** Review release ATS/HTTPS policy, development exceptions, privacy manifests, required-reason declarations where applicable, usage descriptions, and App Store privacy answers.
- [ ] **P4-04:** Hide/defer the unfinished Photos surface or separately approve a functional implementation. Check iOS 27 layout/API compatibility without broad redesign.
- [ ] **P4-05:** Obtain SwiftUI review for view changes and accessibility review after implementation. Validate VoiceOver labels/traits/focus, progress/error announcements, largest accessibility text, contrast, light/dark appearance, and reduced motion.
- [ ] **P4-GATE:** No unresolved release-blocking privacy, security, or accessibility findings; the primary workflow is operable with VoiceOver and contains no misleading speech/Photos promises.

Required reviews are future execution gates, not completed reviews: testing in
P1; concurrency before accepting concurrent changes; security before accepting
sensitive-data changes; accessibility after UI changes; App Review before
submission. Obtain performance-specialist review if measured problems require
optimization.

## P5: Qualify the integrated app on physical devices

- [ ] **P5-01:** Run the approved matrix on iOS 27 hardware, the approved minimum OS/device class, and an intermediate fleet OS. Simulators supplement device evidence.
- [ ] **P5-02:** Test short media, media of at least 1 GB and 10 minutes, the approved fleet maximum, and a transfer lasting more than 600 seconds. Approve or replace these proposed fixtures in P0.
- [ ] **P5-03:** Repeat each critical interruption scenario below at least three times on iOS 27 and the approved minimum.
- [ ] **P5-04:** Record duration, bytes, outcome, sanitized identifiers, error state, memory observations, and recovery behavior. Include limited/denied permissions, low storage, and representative battery/thermal conditions.
- [ ] **P5-GATE:** Zero crashes, hangs, lost accepted work, duplicate logical assets, or unintended shares in qualification runs. Every run reaches the correct terminal state or a truthful recoverable action.

| Critical scenario | Required behavior/evidence |
|---|---|
| Lock, background, suspension | Record transfer/reconciliation behavior; no premature source-file cleanup. |
| OS termination and relaunch | Use a documented mechanism distinct from user force-quit; record event handoff and recovered identity/state. |
| User force-quit | Do not promise automatic relaunch or continued transfer. Manual reopening reconciles completed/pending work and explains recovery. |
| Wi-Fi/cellular transitions and offline/online | Follow cellular policy, wait/retry correctly, and avoid duplicate logical results. |
| Cancel during preparation/upload/speech or near completion | Stop underlying work where cancellable; late callbacks cannot resurrect cancelled UI state or duplicate completion. |
| Retry, timeout, expired URL, auth expiry | Show a clear action, bound retries, and preserve idempotency. |
| Completion during WebSocket disconnect | Foreground/reconnect reconciliation restores authoritative state. |
| Permission denial/limited library/low storage | Provide an honest error/recovery path without crashes or accidental disclosure. |

**Proposed recovery threshold:** reconcile local state within 120 seconds after
foregrounding with connectivity restored in controlled staging. Measure external
Mux processing separately. Approve or replace the threshold in P0, not after
seeing qualification failures.

## P6: TestFlight, controlled release, and operations

- [ ] **P6-01:** Produce a reproducible signed archive; inspect built signing, entitlements, deployment minimum, ATS, and privacy declarations.
- [ ] **P6-02:** Validate TestFlight fresh install and upgrade, including settings, permissions, and pending-upload state.
- [ ] **P6-03:** Complete app-review-guardian review, distribution requirements, release notes, tester guidance, and support instructions.
- [ ] **P6-04:** Demonstrate compatible backend/client rollback and safe data handling. Do not assume users can downgrade an installed app or rely on untested schema reversal.
- [ ] **P6-05:** Approve rollout cohorts and minimum sample size. Proposed observation windows: 24-hour pilot, then 48-hour expanded cohort. Assign monitoring and stop triggers for lost uploads, duplicates, crashes, or privacy/security incidents.
- [ ] **P6-GATE:** Blocking findings are closed, evidence is complete, rollback/on-call ownership is confirmed, and the release owner records go/no-go.

## Product decision log

Resolve these during P0; documentation can proceed while decisions are pending.

| Decision | Owner role | Due | Provisional direction |
|---|---|---|---|
| Minimum OS and supported fleet | Product + Swift lead | P0 | Retain iOS 17 goal pending evidence; reconcile 18.6 overrides. |
| Toolchain/SDK/compiler | Swift lead + CI owner | P0/P1 | Supported iOS 27 toolchain; verify exact compatibility. |
| Distribution and signing | Product + release owner | P0 | Resolve before signing changes. |
| Maximum media, cellular, retry/resume, force-quit UX | Product + transport owner | P0/P2 | Truthful, tested recovery promises. |
| Cloud speech versus strict on-device | Product + privacy owner | P0/P4 | Explicit policy and accurate descriptions. |
| Photos tab | Product | P0/P4 | Hide/defer rather than expand release scope. |
| Thresholds, rollout size, evidence retention, environment | QA + operations | P0/P6 | Approve before qualification and release. |

## Release evidence checklist

- [ ] Source revision, approved PRs, generated-project parity.
- [ ] Exact toolchain/SDK/compiler, language mode, minimum OS, signing, archive configuration.
- [ ] Native CI and lifecycle/cancellation tests; essential backend regression results.
- [ ] Per-device OS/build, media bytes/duration, network conditions, repetitions, sanitized results.
- [ ] Separate suspension, OS-termination/relaunch, and user-force-quit reports.
- [ ] Retry/idempotency and missing/reordered completion evidence.
- [ ] Speech policy, consent, privacy declarations, retention, security review.
- [ ] Manual accessibility evidence and reviewer acceptance.
- [ ] Dated testing, concurrency, security, accessibility, and App Review sign-offs.
- [ ] TestFlight install/upgrade results, release/support notes, rollback/on-call instructions.
- [ ] Release-owner decision, rollout metrics, post-release follow-up.

## Companion plans and resumption

Use the existing [UI/UX plan](IOS_UI_UX_PHASED_PLAN.md),
[stability plan](STABILITY_PLAN.md), [testing plan](TESTING_PLAN.md),
[upload transport checklist](IOS_UPLOAD_TRANSPORT_MODES_CHECKLIST.md),
[speech implementation notes](APPLE_SPEECH_IMPLEMENTATION.md),
[release notes](IOS_UI_UX_PHASE4_RELEASE_NOTES.md),
[rollback guidance](IOS_UI_UX_PHASE4_ROLLBACK.md), and
[project tasks](../TASKS.md) as context, not fresh qualification evidence.

**Resume:** Read this plan and current revision; select the earliest unchecked,
unblocked item; confirm owner and decisions; implement the approved slice;
attach acceptance evidence; update its checkbox and phase gate.
