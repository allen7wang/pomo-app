# HabiticaPomodoroAndroid fixture harness

Offline compile-and-run harness for the Top3 cloud-sync engine. It compiles the
**real production sources** against **stub plumbing** and compiles the selected behavior
cases together. Each case runs in its own JVM, printing `CASE <name> EXIT=<code>` per case. It is deliberately NOT
wired into Gradle (no plugins, no test dependencies in build files) — it lives
beside the module as plain source + one Python script.

## Run

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
python3 HabiticaPomodoroAndroid/fixtures/run.py            # full suite (from repo root)
python3 run.py --only d1_03_markerless_consumption_retires # single case
python3 run.py --list                                      # list cases
python3 run.py --fresh                                     # wipe work dir first
```

Exit code: 0 = all cases pass, 1 = at least one case failed (a case that fails
to **compile** also counts as `EXIT=1` — that is the RED signal for TDD cases
targeting not-yet-existing production API).

Requirements: a JDK **17–21** (`JAVA_HOME` or `java` on PATH) and Python 3.
JDK 22+ is NOT supported: kotlin-compiler-embeddable 2.0.21 crashes on newer
class-file versions (`IllegalArgumentException: 27` from `JavaVersion.parse`).
No network is needed when the toolchain jars resolve from the local Gradle cache;
otherwise run.py downloads them once (pinned versions) into the toolchain dir.

## What gets compiled

Production (real files, unmodified):

- `app/src/main/java/com/habitica/pomodoro/data/Models.kt`
- `app/src/main/java/com/habitica/pomodoro/data/BlockModels.kt`
- `app/src/main/java/com/habitica/pomodoro/data/TopThreeCloudSync.kt`
- `app/src/main/java/com/habitica/pomodoro/data/HabiticaRequestBudget.kt` (per-account
  rolling budget + server headers; injectable clocks)
- `app/src/main/java/com/habitica/pomodoro/data/HabiticaGate.kt` (connection epochs,
  dispatch admission, read coalescing, strict Habits/Dailies parsing, feedback order)
- `app/src/main/java/com/habitica/pomodoro/data/UnfinishedTasks.kt`
- `app/src/main/java/com/habitica/pomodoro/data/LocalStore.kt`
- `app/src/main/java/com/habitica/pomodoro/data/FocusReview.kt`
- `app/src/main/java/com/habitica/pomodoro/engine/PomodoroViewModel.kt`

Substituted plumbing (`stubs/`, HTTP 0 by construction — there is no networking
code in the harness at all):

- `habitica_api_stub.kt` — `data.HabiticaAPI` replaced by a scriptable in-memory
  substitute (cloud todo list, delete/create/tag outcomes, recorded call log).
  Like production, every stub call goes through the REAL `HabiticaGate` (epochs,
  shared budget, coalescing), so `calls` lists only requests that were actually
  dispatched. Extra knobs: `replyFor` (HTTP status/headers/raw body/transport
  loss per call name), `defaultHeaders`, `taskListBodies` (raw list JSON parsed
  by the real strict parser), `profile`, and one-shot `hold(name)` to keep a
  dispatched call in flight until the case completes it (slow responses,
  account switches mid-request).
- `service_stubs.kt` — `PomodoroTimerService` / `BlockReminderReceiver` no-ops
  with call logs.
- `android_stubs.kt`, `android_app_stubs.kt`, `android_log_stub.kt` — minimal
  `Context`/`Application`/`SharedPreferences`/`Log`.
- `androidx_lifecycle.kt` — `AndroidViewModel` + `viewModelScope` backed by
  `Dispatchers.Unconfined`, so every VM coroutine (sync, delete, retry) runs
  **synchronously and deterministically** inside the calling case.

Real libraries used from the pinned toolchain: `kotlin-stdlib 2.0.21`,
`kotlinx-coroutines-core-jvm 1.7.3`, **real `org.json:json:20240303`** (JSON
semantics identical to the app's declared dependency), compiled with
`kotlin-compiler-embeddable 2.0.21` (`K2JVMCompiler`).

The Compose UI (`ui/*.kt`) is NOT compiled here. Per repo convention the UI is
thin over `StateFlow` state: cases assert on VM state (counts, store contents,
error fields), not rendering. UI edits are additionally compile-checkable
against the cached Compose jars + compose compiler plugin outside this harness.

## Cases

`cases/Support.kt` provides fake fixture credentials, temp app dirs, JSON
seeding, `newVm(...)` (resets all stubs, then constructs the VM — init runs the
full loadAll cycle synchronously) and assertion helpers. Each other `*.kt` file
is one case with a `fun main()`; uncaught `AssertionError` = `EXIT=1`.

Suites:

- `smoke_harness_selftest` — plumbing self-test.
- `d1_01..d1_17` — the D1 suite (deletedCloudIdMarkers association fix):
  marker lifecycle (enqueue → unique-match link → retirement), marker-less
  queue consumption retiring the linked marker atomically, both enqueue points
  (deleteTask + lost-POST binding), archive-copy exemption, delete protection,
  quarantine block/exempt, merge bind/ambiguity, JSON round-trip of all four
  bookkeeping collections, owner partition isolation, tombstone-before-delete
  ordering, transient-failure recovery loop.
- `fix1_*` — P0 manual cleanup of orphaned create markers
  (`clearQuarantinedCreateMarkers`): clears markers+links for the current owner
  partition only; queue/origins/history/other partitions untouched; unblocks
  quarantine afterwards.
- `fix2_*` — D2 write-failure visibility: blocked data dir surfaces
  `UiState.persistenceError` (Top3 + settings paths), successful save clears it.
- `fix3_*` — D4 error clearing: clean successful refresh clears a stale
  `topThreeSyncError`; guards keep it while quarantine conflict, pending
  markers, delete protection or a persistence failure is active.
- `fix4_01` — D3 characterization pin: legacy first-owner adoption of
  deletedCloudIds/origins (documented decision, comment-only change).
- `fr_01..fr_03` — 专注复盘 (focus review), a pure-Kotlin port of Apple
  `FocusReview.swift` plus the paging/selection rules of `FocusReviewView.swift`:
  `fr_01` runs the exact dataset of the Apple `focus_review` fixture (windows,
  totals, block/plant projection, earliest record, 30/90-day boundaries) and
  compares the 7- and 30-day CSV with bytes captured from the Apple
  implementation (text + SHA-256); `fr_02` pins window paging from a fixed
  anchor, back/forward enablement, range reset, default day and the opened
  window/pick surviving midnight; `fr_03` feeds legacy `pomo_count` data
  through the real `LocalStore` migration and checks that unknown minutes stay
  unknown (excluded from time totals, empty CSV cell) plus the footer summary.
  The Compose screen itself (`ui/FocusReviewScreen.kt`) is not compiled here.
- `rl_01..rl_05` — Habitica request budget (Apple v2.1.2): 24 requests / rolling
  60 s shared by every feature; `X-RateLimit-Remaining/Reset`, `Retry-After`
  (seconds, fractional, HTTP-date, epoch, malformed, oversized), out-of-order
  replies; HTTP 429 stops a manual batch, nothing is sent or replayed during the
  cooldown, manual retry continues afterwards; the budget is per UID + API root
  and survives token rotation, reconnect and A→B→A; confirmed deletes are not
  re-sent while their tombstones block stale re-imports (also after restart).
- `cr_01..cr_04` — create recovery (v2.1.3): 401/429 or blocked-at-dispatch
  releases only that attempt's marker and keeps the task pending (manual retry
  creates once); dispatched-but-unknown outcomes (400/500/loss/2xx without id)
  keep the marker and reconcile instead of re-POSTing; legacy markers stay;
  deletion or account switch during a refused POST only touches the original
  owner's UUID/attempt. `cr_05` checks that a failed local save blocks
  creation and deletion until their markers can be persisted.
- `tl_01` — Habits/Dailies: malformed JSON/envelope, missing id/text, duplicate
  ids, HTTP errors and transport loss keep the shown list; a legal empty list
  clears it.
- `ep_01..ep_02` — connection epochs (v2.1.4): UID/token/connect/API-root change
  retires in-flight reads; switching back re-reads (never joins/adopts the
  retired read, nor sends a compound read's second leg); preference edits and
  equivalent API roots keep reads coalesced; sent writes return their real
  outcome for the original account; a retired 429 still updates that budget.
- `ro_01..ro_02` — response order (v2.1.4): slow success vs later error (lists,
  Task page), older failure vs newer error, stale profile vs newer 401, fresh
  refresh clears old errors, retired profile after A→B→A.
- `uf_01..uf_03` — unfinished tasks (v2.1.0): logical-day selection (newest
  first, one row per UUID, archives/completed/blank/future excluded), move to
  today's original category with the full-category hint (Work/MyOwn 3, Chores
  unlimited), archive copy retained, existing todo re-dated; delete with cloud
  tombstone semantics and stale-target rejection.

## Invariants the suite pins

1. Explicit delete intents are sacred: `deletedCloudIds` /
   `deletedCloudTaskOrigins` are only drained by a confirmed (404 read-back)
   cloud delete — never by cleanup or merge paths.
2. A queue entry consumed without a marker must still retire its linked
   `deletedCreateMarkers` entry in the same atomic save (via
   `deletedCloudIdMarkers`), or the marker orphans forever (D1).
3. Tombstone persists BEFORE the network delete is attempted.
4. Delete protection: a queued id bound to an active local task is never
   deleted; the archive copy (original UUID, `movedToToday`) is exempt.
5. Quarantine: inbound todos matching a pending create-marker signature are
   neither imported nor bound while the marker lives; known (bound) ids are
   exempt; confirmed cleanup unblocks them.
6. Ambiguous create matches never bind and never re-POST.
7. Owner partitions (UID + canonical HTTPS API root) never leak queues,
   markers, links or history into each other.
8. Store JSON round-trips losslessly through the real LocalStore/org.json.
9. Disk write failures must surface in `UiState.persistenceError` (D2);
   `topThreeSyncError` clears only on a clean successful cycle (D4) that was
   dispatched after the error was shown.
10. Nothing is dispatched for a retired connection or an exhausted/cooling
    budget; refused scores/creates are never replayed automatically.
11. Confirmed deletions move from `deletedCloudIds` (pending queue) to
    `confirmedDeletedCloudIds` (tombstones): never re-sent, never re-imported.
12. Focus review is read-only and matches Apple: same calendar-day windows and
    totals, CSV `date,pomodoros,minutes,completed_blocks,shrubs,trees,wilted`
    with CRLF (trailing CRLF, UTF-8, no BOM). Legacy count-only minutes are
    never fabricated: the only Android-specific output is an empty minutes cell
    for such days, which Apple data cannot contain.

## Layout / hygiene

- Work + logs: `--work DIR`, else `$POMO_FIXTURES_WORK`, else
  `$TMPDIR/pomo-fixtures-work`, else `fixtures/.work/` (gitignored). JVM tmpdir
  is pinned under the work dir; nothing is ever written to `/tmp` or to real
  user data (`~/Documents/.habitica-pomodoro`, device data).
- Toolchain jars: `--toolchain DIR`, else `fixtures/.toolchain/` (gitignored),
  else `~/.gradle/caches/modules-2/files-2.1`, else `~/.m2/repository`, else
  Maven Central download (pinned). Per-case compile+run logs land in
  `<work>/logs/<case>.log`.
- Fake credentials only (`Support.kt`); cases must never print or use real
  UID/token values.
