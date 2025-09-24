using RevShareModuleCertoraHarness as harness;

/*//////////////////////////////////////////////////////////////
                                METHODS
//////////////////////////////////////////////////////////////*/
methods {
  /* storage-only getters (envfree) */
  function rewardsDuration() external returns (uint256) envfree;
  function rewardRatePioneersScaled() external returns (uint256) envfree;
  function rewardRateTakadaoScaled() external returns (uint256) envfree;
  function periodFinish() external returns (uint256) envfree;
  function revenuesAvailableDate() external returns (uint256) envfree;
  function revenuePerNftOwnedByPioneers() external returns (uint256) envfree;
  function takadaoRevenueScaled() external returns (uint256) envfree;
  function approvedDeposits() external returns (uint256) envfree;
  function revenueReceiver() external returns (address) envfree;

  /* time-dependent views (NOT envfree) */
  function lastTimeApplicable() external returns (uint256);
  function getRevenuePerNftOwnedByPioneers() external returns (uint256);
  function getTakadaoRevenueScaled() external returns (uint256);
  function earnedByPioneers(address) external returns (uint256);
  function earnedByTakadao(address) external returns (uint256);

  /* mutators */
  function notifyNewRevenue(uint256) external;
  function setAvailableDate(uint256) external;
  function setRewardsDuration(uint256) external;
  function releaseRevenues() external;
  function claimRevenueShare() external returns (uint256);
  function emergencyWithdraw() external;
}


/*//////////////////////////////////////////////////////////////
                            INVARIANTS
//////////////////////////////////////////////////////////////*/

// duration must be positive once a period exists, unless the module is fully halted (both rates are zero)
invariant RewardsDurationPositiveOrHalted()
    (harness.periodFinish() == 0)
    || (harness.rewardsDuration() > 0)
    || (harness.rewardRatePioneersScaled() == 0 && harness.rewardRateTakadaoScaled() == 0);

/*//////////////////////////////////////////////////////////////
                              RULES
//////////////////////////////////////////////////////////////*/

// TimeBounds needs an env because lastTimeApplicable() is non-envfree.
rule TimeBoundsHolds() {
  env e;
  if (harness.periodFinish() != 0) {
    uint256 lta = harness.lastTimeApplicable@withrevert(e);
    if (!lastReverted) {
      assert lta <= harness.periodFinish();
    }
  }
  assert true;
}

// Views with env
rule RevenueReceiverNotPioneerEarner() {
  env e;
  address rr = harness.revenueReceiver();
  uint256 ep = harness.earnedByPioneers@withrevert(e, rr);
  if (!lastReverted) { assert ep == 0; }
  assert true;
}

rule NonReceiverNotTakadaoEarner(address a) {
  env e;
  require a != harness.revenueReceiver();
  uint256 et = harness.earnedByTakadao@withrevert(e, a);
  if (!lastReverted) { assert et == 0; }
  assert true;
}

/* ---- Split rule when there is NO leftover from a previous stream ----
   We enforce "period finished" by checking lta == periodFinish under env e. */
rule NotifyPreservesSplit_NoLeftover() {
  env e;

  // ensure no active period: lta == periodFinish implies now >= periodFinish
  uint256 lta = harness.lastTimeApplicable@withrevert(e);
  if (!lastReverted && harness.periodFinish() != 0 && lta == harness.periodFinish()) {
    uint256 amt; // unconstrained
    harness.notifyNewRevenue@withrevert(e, amt);
    if (!lastReverted) {
      mathint rp = harness.rewardRatePioneersScaled();
      mathint rt = harness.rewardRateTakadaoScaled();
      mathint diff = (rp >= 3*rt) ? (rp - 3*rt) : (3*rt - rp);
      assert diff <= 4;  // rounding tolerance
    }
  }
  assert true;
}

// Rewards duration setter behavior (assert only on success)
rule SetRewardsDurationBehavior() {
  env e;
  uint256 dur;
  harness.setRewardsDuration@withrevert(e, dur);
  if (!lastReverted) {
    assert dur > 0;
    assert harness.rewardsDuration() == dur;
  }
  assert true;
}

// setAvailableDate round-trip on success
rule SetAvailableDateBehavior() {
  env e;
  uint256 ts;
  harness.setAvailableDate@withrevert(e, ts);
  if (!lastReverted) {
    assert harness.revenuesAvailableDate() == ts;
  }
  assert true;
}

// releaseRevenues: success => date decreases; revert => unchanged
rule ReleaseRevenuesBehavior() {
  env e;
  uint256 before = harness.revenuesAvailableDate();
  harness.releaseRevenues@withrevert(e);
  if (!lastReverted) {
    assert harness.revenuesAvailableDate() < before;
  } else {
    assert harness.revenuesAvailableDate() == before;
  }
  assert true;
}

// Claims keep approvedDeposits non-negative and subtract exactly on success
rule ClaimConservesApprovedDeposits() {
  env e;
  uint256 before = harness.approvedDeposits();
  uint256 r = harness.claimRevenueShare@withrevert(e);
  if (!lastReverted) {
    if (r > 0) {
      assert before >= r;
      assert harness.approvedDeposits() == before - r;
    } else {
      assert harness.approvedDeposits() == before;
    }
  }
  assert true;
}

// On success, stream is halted and accounting reset
rule EmergencyWithdrawHaltsStream() {
  env e;
  harness.emergencyWithdraw@withrevert(e);
  if (!lastReverted) {
    assert harness.rewardRatePioneersScaled() == 0;
    assert harness.rewardRateTakadaoScaled() == 0;
    assert harness.approvedDeposits() == 0;

    uint256 lta = harness.lastTimeApplicable@withrevert(e);
    if (!lastReverted) {
      assert lta == harness.periodFinish();
    }
  }
  assert true;
}
