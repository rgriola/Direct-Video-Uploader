# Upload Setups — PM Ticket Board (Sprint 2)
- Last updated: May 9, 2026 - 11:09pm - GPT-5.3-Codex

Status: Draft for leadership review

Sprint goal:
- Harden large-batch reliability (chunk resume path) and bootstrap reusable photo pipeline foundations.

Assumptions:
- Sprint length: 2 weeks
- Sprint 1 multiclip queue shipped and stable

## Ticket Table

| Ticket ID | Setup | Ticket | Owner | Estimate | Depends On | Demo Criteria |
|---|---|---|---|---|---|---|
| UPL-S2-01 | Transport Mode | Build upload session APIs for chunk resume workflow | Server | 2d | Sprint 1 complete | Session create, offset query, chunk patch, and finalize endpoints pass integration tests |
| UPL-S2-02 | Transport Mode | Add iOS chunk coordinator and resume-from-offset logic | iOS | 2.5d | UPL-S2-01 | Mid-file interruption resumes from last acknowledged offset |
| UPL-S2-03 | SD Card Offload | Add SD detach/reattach blocked-state recovery | iOS | 1.5d | UPL-S2-02 | Queue pauses on detach and can continue matching files on reattach |
| UPL-S2-04 | SD Card Offload | Add adaptive concurrency and backpressure strategy | iOS | 1.5d | UPL-S2-02 | Throughput improves on good network and backs off on error bursts |
| UPL-S2-05 | Admin Visibility | Add grouped upload batch visibility in admin surfaces | Server + Admin | 2d | UPL-S2-01 | Admin can inspect batch summary plus per-file outcomes with org scope enforced |
| UPL-S2-06 | Camera Library Photos | Add photo domain models and queue scaffolding shared with video pattern | iOS | 1.5d | Sprint 1 complete | Photo batch models compile and queue state persists |
| UPL-S2-07 | Camera Library Photos | Add photo project MVP routes and schema updates | Server | 2d | UPL-S2-06 | End-to-end photo project create, upload, and complete flow works in dev |
| UPL-S2-08 | Program/QA | Run 100GB-160GB soak suite and publish reliability report | QA + PM | 1.5d | UPL-S2-01..UPL-S2-07 | Report includes resume rate, failure rate, and known limits |

## Demo Script (Sprint Review)

1. Start large batch and interrupt network.
2. Resume upload from checkpoint without restarting completed chunks.
3. Remove and reconnect SD source during queue run.
4. Show admin batch status for completed and failed items.
5. Create photo project MVP and upload sample set with grouped context.
6. Present soak report with final reliability metrics.

## Exit Metrics

1. Resume success rate after interruption.
2. Percent of files requiring full restart.
3. Mean time to recover from disconnect.
4. End-to-end success rate for 100GB+ runs.

## Risks and Mitigations

1. Risk: Chunk temp storage growth.
- Mitigation: Add TTL cleanup and abandoned-session sweeper.

2. Risk: Source handle invalidation after long idle period.
- Mitigation: Persist source references and add explicit user rebind flow.

3. Risk: Scope creep from photo pipeline.
- Mitigation: Keep photo scope at MVP routes/models and defer advanced metadata tooling.

## Decision Gate at Sprint End

Promote chunk resume as default only if:

1. Resume and soak metrics meet target.
2. Operational cleanup jobs are verified in staging.
3. Admin visibility is sufficient for support workflows.
