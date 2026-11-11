#!/usr/bin/env bash
# Mutation check. Each mutant breaks one specific behaviour and names the test that must catch it.
# A mutant counts as caught only if the suite fails *and* that test is among the failures, so a
# mutant "caught" by some unrelated breakage does not count. A control mutant (a comment) runs last
# and must survive: that proves every restored file was rebuilt, i.e. no earlier mutant is still
# linked in. A pattern that does not occur exactly once, a mutant that does not compile, a survivor,
# a mutant caught by the wrong test, or a failing control fails the run.
#
#   MUTANT_TIMEOUT  seconds per test run (default 300)
#   MUTANT_LOGS     where per-mutant logs go (default /tmp/retention-mutants)
#   MUTANT_CHECK_ONLY=1  only check that every pattern occurs exactly once
set -uo pipefail
cd "$(dirname "$0")/.."
TIMEOUT="${MUTANT_TIMEOUT:-300}"
LOGS="${MUTANT_LOGS:-/tmp/retention-mutants}"
CHECK_ONLY="${MUTANT_CHECK_ONLY:-0}"
mkdir -p "$LOGS"

occurrences() {  # file pattern → how many times the literal pattern occurs
  OLD="$2" perl -0ne 'my $n = () = /\Q$ENV{OLD}\E/g; print $n' "$1"
}

if [ "$CHECK_ONLY" != "1" ]; then
  echo "Baseline: the unmutated suite must pass."
  if ! swift build --build-tests > "$LOGS/baseline-build.log" 2>&1; then
    echo "baseline does not build"; tail -40 "$LOGS/baseline-build.log"; exit 1
  fi
  if ! timeout "$TIMEOUT" swift test --skip-build > "$LOGS/baseline-test.log" 2>&1; then
    echo "baseline tests fail"; tail -40 "$LOGS/baseline-test.log"; exit 1
  fi
fi

caught=0
problems=0
current=""
# An interrupted run must not leave a mutant in the tree.
trap 'if [ -n "$current" ] && [ -f "$current.orig" ]; then mv "$current.orig" "$current"; touch "$current"; fi; exit 130' INT TERM

# Applies the mutant and runs the suite. Leaves the test exit status in $status. Exits the script
# on a harness problem (pattern count, compile error).
run_mutant() {  # name file old new
  local name="$1" file="$2" old="$3" new="$4"
  local count
  count=$(occurrences "$file" "$old")
  if [ "$count" != "1" ]; then
    echo "✗ $name: pattern occurs $count times in $file (must be exactly once)"; exit 1
  fi
  if [ "$CHECK_ONLY" = "1" ]; then status=skip; return; fi
  current="$file"
  cp "$file" "$file.orig"
  OLD="$old" NEW="$new" perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$file"
  if ! swift build --build-tests > "$LOGS/$name-build.log" 2>&1; then
    echo "✗ $name: mutant does not compile — fix the mutant"; tail -20 "$LOGS/$name-build.log"
    mv "$file.orig" "$file"; touch "$file"; exit 1
  fi
  timeout "$TIMEOUT" swift test --skip-build > "$LOGS/$name-test.log" 2>&1
  status=$?
  mv "$file.orig" "$file"
  # mv keeps the backup's older mtime; without the touch SwiftPM would keep linking the mutant.
  touch "$file"
  current=""
}

mutate() {  # name file old new expected-test
  local name="$1" expected="$5"
  run_mutant "$1" "$2" "$3" "$4"
  if [ "$status" = "skip" ]; then echo "ok  $name"; return; fi
  if [ "$status" -eq 0 ]; then
    echo "✗ SURVIVED  $name — $expected should have failed"; problems=$((problems + 1))
  elif grep -Eq "Test Case '[^']*${expected}[^']*' failed" "$LOGS/$name-test.log"; then
    echo "✓ caught    $name  ($expected)"; caught=$((caught + 1))
  else
    echo "✗ $name: the suite failed (exit $status), but not in $expected"
    grep -E "Test Case '[^']*' failed" "$LOGS/$name-test.log" | head -5
    problems=$((problems + 1))
  fi
}

control() {  # name file old new — must survive
  local name="$1"
  run_mutant "$1" "$2" "$3" "$4"
  if [ "$status" = "skip" ]; then echo "ok  $name (control)"; return; fi
  if [ "$status" -eq 0 ]; then
    echo "✓ survived  $name (control: every restored file was rebuilt)"
  else
    echo "✗ control $name failed the suite — an earlier mutant is still linked in"; problems=$((problems + 1))
  fi
}

E=Sources/RetentionEngine
C=Sources/RetentionCopy
# Engine: deadlines, idempotency, experiment, resilience.
mutate engine-no-single-flight    $E/DecisionEngine.swift 'inFlight[key] = task' '_ = task' testConcurrentDuplicatesShareOnePipelineRun
mutate holdout-skipped            $E/DecisionEngine.swift 'if arm == .holdout {' 'if arm == .holdout && false {' testHoldoutGetsControlWithoutAnyLookup
mutate lookup-ignores-reserves    $E/DecisionEngine.swift 'let deadline = budgetEnd - configuration.signingReserve - configuration.finalizeReserve' 'let deadline = budgetEnd' testHungRemoteFallsBackExactlyAtTheLookupDeadline
mutate arrival-floor-removed      $E/DecisionEngine.swift 'return min(max(receivedAt, now - EngineConfiguration.appleTimeout), now)' 'return min(receivedAt, now)' testArrivalOlderThanAppleTimeoutIsClamped
mutate breaker-probe-before-budget $E/DecisionEngine.swift \
  $'        guard now < deadline else {\n            return (.unavailable(.budgetExhausted), [.l1Miss, .l2SkippedNoBudget])\n        }\n        guard breaker.shouldAttempt(now: now) else {\n            return (.unavailable(.breakerOpen), [.l1Miss, .l2SkippedBreakerOpen])\n        }' \
  $'        guard breaker.shouldAttempt(now: now) else {\n            return (.unavailable(.breakerOpen), [.l1Miss, .l2SkippedBreakerOpen])\n        }\n        guard now < deadline else {\n            return (.unavailable(.budgetExhausted), [.l1Miss, .l2SkippedNoBudget])\n        }' \
  testExhaustedRequestDoesNotConsumeTheHalfOpenProbe
mutate timeout-counts-as-success  $E/DecisionEngine.swift \
  $'        case .timedOut:\n            breaker.recordFailure(now: clock.now())' \
  $'        case .timedOut:\n            breaker.recordSuccess()' \
  testTimeoutsOpenTheBreaker
mutate miss-counts-as-failure     $E/DecisionEngine.swift \
  $'        case .value(.none):\n            breaker.recordSuccess()' \
  $'        case .value(.none):\n            breaker.recordFailure(now: clock.now())' \
  testRemoteMissAndAbsentRemoteBothFallBack
mutate decision-id-ignores-identity $E/Decision.swift 'StableHash.contentUUID("decision:" + identity.joined(separator: "\u{1F}"))' 'StableHash.contentUUID("decision:" + request.requestIdentifier)' testSameIdentifierForADifferentSubscriberIsNotReplayed
mutate endpoint-any-app           $E/RetentionEndpoint.swift 'guard request.appAppleId == configuration.appAppleId else {' 'guard request.appAppleId == configuration.appAppleId || true else {' testOtherAppsAndEnvironmentsGetNoMessage
mutate endpoint-drops-arrival     $E/RetentionEndpoint.swift 'let decision = await engine.decide(request, receivedAt: start)' 'let decision = await engine.decide(request)' testArrivalTimeIsChargedToTheEngineBudget
mutate holdout-inclusive          $E/Experiment.swift 'bucket(for: originalTransactionId) < holdoutBasisPoints' 'bucket(for: originalTransactionId) <= holdoutBasisPoints' testHoldoutBoundaryIsExclusive
mutate lww-arrival-order          $E/Features.swift 'if other.clock > clock {' 'if true {' testMergeIsOrderIndependentAcrossAllPermutations
mutate tenure-uses-latest-purchase $E/Features.swift 'firstPurchaseDate = min(firstPurchaseDate ?? purchaseDate, purchaseDate)' 'firstPurchaseDate = max(firstPurchaseDate ?? purchaseDate, purchaseDate)' testTenureStartsAtTheEarliestPurchase
mutate cooldown-inclusive         $E/OfferPolicy.swift 'if elapsed < coolDownMilliseconds {' 'if elapsed <= coolDownMilliseconds {' testCoolDownBoundaryIsExclusive
mutate breaker-off-by-one         $E/Resilience.swift 'state = next >= failureThreshold ?' 'state = next > failureThreshold ?' testBreakerTransitions
mutate cache-evicts-reinserted    $E/Resilience.swift 'if let evicted = ring[index], storage[evicted]?.ring == index {' 'if let evicted = ring[index] {' testReinsertedKeySurvivesItsOldSlot
mutate holder-publish-noop        $E/MessageCatalog.swift 'current.withLock { $0 = catalog }' '_ = catalog' testPublishIsVisibleToTheNextSnapshot
mutate histogram-under-reports    $E/LatencyHistogram.swift 'return .microseconds(min(Self.upperBoundMicroseconds(ofBucket: index), maximum))' 'return .microseconds(index == 0 ? 0 : Self.upperBoundMicroseconds(ofBucket: index - 1) + 1)' testQuantilesMatchExactWithinOnePercentAndNeverUnderReport
mutate open-loop-from-actual-start $E/LoadHarness.swift 'let fromIntended = sample.end - sample.intendedStart' 'let fromIntended = sample.end - sample.actualStart' testOpenLoopChargesAnIssuerStallToTheRequestsItDelayed
mutate late-never-counted         $E/LoadHarness.swift 'if fromIntended > EngineConfiguration.appleTimeout { late += 1 }' 'if fromIntended > EngineConfiguration.appleTimeout { late += 0 }' testReportCountsAnswersLaterThanApple
# Offline copy pipeline.
mutate gate-counts-graphemes      $C/CopyEvalGate.swift 'let header = candidate.header.utf16.count' 'let header = candidate.header.count' testLengthLimitsCountUTF16Units
mutate gate-any-discount          $C/CopyEvalGate.swift 'guard percent == brief.offerDiscountPercent else {' 'guard percent == brief.offerDiscountPercent || true else {' testPricesAndDiscounts
mutate gate-ignores-typography    $C/CopyEvalGate.swift 'return String(scalars).folding(' 'return text.folding(' testTypographyIsNotAWayAroundThePhraseRules
mutate judge-sees-gate-failures   $C/CopyPipeline.swift 'if verdict.passed, let judge {' 'if let judge {' testJudgeCanVetoButNeverRescue
mutate fallback-approval-skipped  $C/CatalogCompiler.swift 'guard states[id] != .approved else { continue }' 'guard states[id] != .approved && false else { continue }' testFallbacksMustBeApproved
mutate ranking-crosses-kinds      $C/CatalogCompiler.swift 'cellDrafts.filter { Self.kindRank($0.brief.kind) == kindRank }.map(\.variantId)' '(kindRank == 0 ? cellDrafts : []).map(\.variantId)' testRankingNeverPutsTextAheadOfAnOffer
# Attribution.
mutate attribution-first-touch    Sources/RetentionAttribution/Attribution.swift 'let end = min(natural, next)' 'let end = natural' testLastTouchWins
mutate attribution-drops-holdout  Sources/RetentionAttribution/Attribution.swift 'for record in decisions where !record.isReplay {' 'for record in decisions where !record.isReplay && record.arm != .holdout {' testBothArmsAreAttributedAndCompared
# The demo's load rig.
mutate lab-drops-arrival          Sources/RetentionLab/LabRig.swift 'rig.endpoint.handle(body: body, receivedAt: context.intendedStart)' 'rig.endpoint.handle(body: body)' testSmallLoadComparisonNeverAnswersLaterThanApple
# Last: a comment-only change must survive.
control comment-only              $E/Primitives.swift '/// A lock-protected value.' '/// A lock-protected value. (control mutant: a comment)'

if [ "$CHECK_ONLY" = "1" ]; then echo "every pattern occurs exactly once"; exit 0; fi
echo "$caught caught, $problems problems"
[ "$problems" -eq 0 ]
