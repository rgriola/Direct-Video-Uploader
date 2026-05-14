Yes — batch uploads are tracked, but purely client-side. Here's the trace and the reason your wiped-Mux state didn't clear the chat bubble.

How the Batch Queue card stays alive
Identity & persistence

When a multi-clip selection turns into a batch, BatchStateTransitionService.makeStagedBatchSession mints a client-side currentBatchId = UUID().uuidString. Each item carries the per-asset assetId.
That snapshot (VideoBatch) is written to Documents/pending-batches/<batchId>.json via PendingBatchStore.save, with a latest-batch-id.txt pointer alongside it. Every state transition re-saves it — persistBatchState() is called from ~12 spots in ChatViewModel.swift:1487.
What renders the card

var hasActiveBatch: Bool { currentBatchId != nil && !batchItems.isEmpty } — see ChatViewModel.swift:40.
showsBatchBubbleInTimeline = hasActiveBatch. Pure local state. Zero server reconciliation.
When the JSON gets cleared
Look at BatchRunExecutionService.completionState:

And BatchStateTransitionService.makeRunCompletionState:

So with Failed 2 the run finishes as .partialFailed, the JSON is intentionally re-saved (so Retry Failed works after relaunch), and PendingBatchStore.clear is never called.

On launch / re-open ChatViewModel.swift:1502 only auto-clears when pending.state == .complete. .partialFailed is restored verbatim — currentBatchId + batchItems are repopulated, the card re-renders, and Retry Failed is enabled.

Why the server wipe didn't help
The Mux/DB nuke deletes server-side assets rows. The Archive list now returns 0 — correct. But:

The server has no batch concept at all. There's no batch_id on the server, no batch endpoint, nothing to invalidate.
iOS reads its batch UI exclusively from the local pending-batches/<id>.json and in-memory currentBatchId / batchItems.
There is no reconciliation pass at startup that asks "do these assetIds still exist on the server?" — if there were, it would notice all of them are 404 and clear the batch.
So the bubble will keep showing Done 7/9 • Failed 2 until one of the following happens:

User taps Retry Failed and the 2 fails eventually succeed → failedCount == 0 → clear.
resetBatchState(clearDisk: true) runs (only happens on certain explicit reset paths in ChatViewModel.swift:1582).
The app container is wiped (delete app, or Simulator → Device → Erase All Content).
TL;DR answer
Tracked locally only, by client-minted batchId UUID, persisted in Documents/pending-batches/. The card is driven purely by that local state. A server-side wipe doesn't touch it because nothing on iOS ever asks the server "is this batch still real?" The .partialFailed state is deliberately sticky so users can retry — that's the design, not a bug. The gap is the missing startup reconciliation that would notice all the assetIds are 404 and self-clean.

Two cleanup options if/when you want to fix this (separate ticket — not touching it now):

.. > this is what we need.
Cheap: in restorePendingBatchState, also clear if pending.state == .partialFailed AND pending.createdAt is older than N days.
Correct: in restorePendingBatchState, fire a single GET /api/assets?ids=... reconciliation — if the server returns zero hits for the batch's assetIds, drop the batch and the card.
