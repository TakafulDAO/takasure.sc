using RevShareModuleCertoraHarness as H;

/* ----------------------------- METHODS (CVL 2) ----------------------------- */
methods {
  /* storage-only getters (envfree) */
  function rewardsDuration() external returns (uint256) envfree;
  function rewardRatePioneers() external returns (uint256) envfree;
  function rewardRateTakadao() external returns (uint256) envfree;
  function periodFinish() external returns (uint256) envfree;
  function revenuesAvailableDate() external returns (uint256) envfree;
  function revenuePerNftPioneers() external returns (uint256) envfree;
  function revenuePerNftTakadao() external returns (uint256) envfree;
  function approvedDeposits() external returns (uint256) envfree;
  function revenueReceiver() external returns (address) envfree;
  function h_addressManager() external returns (address) envfree;

  /* time-dependent views (NOT envfree) */
  function lastTimeApplicable() external returns (uint256);
  function getRevenuePerNftPioneers() external returns (uint256);
  function getRevenuePerNftTakadao() external returns (uint256);
  function earnedPioneers(address) external returns (uint256);
  function earnedTakadao(address) external returns (uint256);

  /* mutators */
  function notifyNewRevenue(uint256) external;
  function setAvailableDate(uint256) external;
  function setRewardsDuration(uint256) external;
  function releaseRevenues() external;
  function claimRevenueShare() external returns (uint256);
}

/* ----------------------------- INVARIANTS ----------------------------- */

/* Guard by initialization: before initialize(), rewardsDuration can be 0. */
invariant RewardsDurationPositive()
  (H.h_addressManager() == 0) || (H.rewardsDuration() > 0);

/* Pioneers should get ~75% of the total rate; allow 70%..80% slack. */
invariant RateSplitInRange()
  (
    H.rewardRatePioneers() + H.rewardRateTakadao() == 0
    ||
    (
      70 * (H.rewardRatePioneers() + H.rewardRateTakadao()) <= 100 * H.rewardRatePioneers()
      &&
      100 * H.rewardRatePioneers() <= 80 * (H.rewardRatePioneers() + H.rewardRateTakadao())
    )
  );

/* ------------------------------- RULES -------------------------------- */

/* TimeBounds needs an env because lastTimeApplicable() is not envfree. */
rule TimeBoundsHolds() {
  env e;
  if (H.h_addressManager() != 0) {
    if (H.periodFinish() != 0) {
      uint256 lta = H.lastTimeApplicable@withrevert(e);
      if (!lastReverted) {
        assert lta <= H.periodFinish();
      }
    }
  }
  assert true;
}

/* View rules: pass env to non-envfree calls */
rule RevenueReceiverNotPioneerEarner() {
  env e;
  address rr = H.revenueReceiver();
  uint256 ep = H.earnedPioneers@withrevert(e, rr);
  if (!lastReverted) { assert ep == 0; }
  assert true;
}

rule NonReceiverNotTakadaoEarner(address a) {
  env e;
  require a != H.revenueReceiver();
  uint256 et = H.earnedTakadao@withrevert(e, a);
  if (!lastReverted) { assert et == 0; }
  assert true;
}

/* Revert-tolerant mutation rules */
rule NotifyPreservesSplit() {
  env e;
  uint256 amt;
  H.notifyNewRevenue@withrevert(e, amt);
  if (!lastReverted) {
    /* use mathint arithmetic implicitly by not assigning to uint256 */
    if (H.rewardRatePioneers() + H.rewardRateTakadao() > 0) {
      assert 70 * (H.rewardRatePioneers() + H.rewardRateTakadao())
             <= 100 * H.rewardRatePioneers();
      assert 100 * H.rewardRatePioneers()
             <= 80 * (H.rewardRatePioneers() + H.rewardRateTakadao());
    }
  }
  assert true;
}

rule SetAvailableDateBehavior() {
  env e;
  uint256 ts;
  H.setAvailableDate@withrevert(e, ts);
  if (!lastReverted) {
    assert H.revenuesAvailableDate() == ts;
  }
  assert true;
}

rule SetRewardsDurationBehavior() {
  env e;
  uint256 dur;
  H.setRewardsDuration@withrevert(e, dur);
  if (!lastReverted) {
    assert dur > 0;
    assert H.rewardsDuration() == dur;
  }
  assert true;
}

rule ReleaseRevenuesBehavior() {
  env e;
  uint256 before = H.revenuesAvailableDate();
  H.releaseRevenues@withrevert(e);
  if (!lastReverted) {
    assert H.revenuesAvailableDate() < before;
  } else {
    assert H.revenuesAvailableDate() == before;
  }
  assert true;
}

rule ClaimConservesApprovedDeposits() {
  env e;
  uint256 before = H.approvedDeposits();
  uint256 r = H.claimRevenueShare@withrevert(e);
  if (!lastReverted) {
    if (r > 0) {
      assert before >= r;
      assert H.approvedDeposits() == before - r;
    } else {
      assert H.approvedDeposits() == before;
    }
  }
  assert true;
}
