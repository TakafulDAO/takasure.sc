
//      /**
//       * @notice This function will update all the variables needed when a member pays the contribution
//       * @param _payContribution true -> the contribution will be paid and the credit tokens will be minted
//       *                                      false -> no need to pay the contribution as it is already payed
//       */
//      function _memberPaymentFlow(
//          uint256 _contributionBeforeFee,
//          uint256 _contributionAfterFee,
//          uint256 _feeAmount,
//          address _memberWallet,
//          bool _payContribution
//      ) internal {
//          _getBenefitMultiplierFromOracle(_memberWallet);
//          _updateProFormas(_contributionAfterFee, _contributionBeforeFee);
//          _updateReserves(_contributionBeforeFee, _contributionAfterFee);
//          _updateCashMappings(_contributionAfterFee);
//          uint256 cashLast12Months = _cashLast12Months(monthReference, dayReference);
//          _updateDRR(cashLast12Months);
//          _updateBMA(cashLast12Months);
//          _updateLossRatio(reserve.totalFundCost, reserve.totalFundRevenues);
//          _mintDaoTokens(_contributionBeforeFee, _memberWallet);
//          // update ucrisk calculation ratio
//          _memberSurplus();
//          if (_payContribution) {
//              _transferAmounts(_contributionAfterFee, _feeAmount, _memberWallet);
//          }
//      }
 
 
//      /**
//       * @notice Calculate the total earned and unearned contribution reserves for all active members
//       * @dev It does not count the recently added member
//       * @dev It updates the total earned and unearned contribution reserves every time it is called
//       * @dev Members in the grace period are not considered
//       * @return totalECRes_ the total earned contribution reserve. Six decimals
//       * @return totalUCRes_ the total unearned contribution reserve. Six decimals
//       */
//      // Todo: This will need another approach to avoid DoS, for now it is mainly to be able to test the algorithm
//      function _totalECResAndUCResUnboundedLoop()
//          internal
//          returns (uint256 totalECRes_, uint256 totalUCRes_)
//      {
//          uint256 newECRes;
//          // We check for every member except the recently added
//          for (uint256 i = 1; i <= memberIdCounter - 1; ) {
//              address memberWallet = idToMemberWallet[i];
//              Member storage memberToCheck = reserve.members[memberWallet];
//              if (memberToCheck.memberState == MemberState.Active) {
//                  (uint256 memberEcr, uint256 memberUcr) = ReserveMathLib._calculateEcrAndUcrByMember(
//                      memberToCheck
//                  );
 
//                  newECRes += memberEcr;
//                  totalUCRes_ += memberUcr;
//              }
 
//              unchecked {
//                  ++i;
//              }
//          }
 
//          reserve.ECRes = newECRes;
//          reserve.UCRes = totalUCRes_;
 
//          totalECRes_ = reserve.ECRes;
//      }
 
//      /**
//       * @notice Surplus to be distributed among the members
//       * @return surplus_ in six decimals
//       */
//      function _calculateSurplus() internal returns (uint256 surplus_) {
//          (uint256 totalECRes, uint256 totalUCRes) = _totalECResAndUCResUnboundedLoop();
//          uint256 UCRisk;
 
//          UCRisk = (totalUCRes * reserve.riskMultiplier) / 100;
 
//          // surplus = max(0, ECRes - max(0, UCRisk - UCRes -  RPOOL))
//          surplus_ = uint256(
//              ReserveMathLib._maxInt(
//                  0,
//                  (int256(totalECRes) -
//                      ReserveMathLib._maxInt(
//                          0,
//                          (int256(UCRisk) - int256(totalUCRes) - int256(RPOOL))
//                      ))
//              )
//          );
 
//          reserve.surplus = surplus_;
 
//          emit TakasureEvents.OnFundSurplusUpdated(surplus_);
//      }
 
//      /**
//       * @notice Calculate the surplus for a member
//       */
//      function _memberSurplus() internal {
//          uint256 totalSurplus = _calculateSurplus();
//          uint256 userCreditTokensBalance = reserve.members[msg.sender].creditTokensBalance;
//          uint256 totalCreditTokens = daoToken.balanceOf(address(this));
//          uint256 userSurplus = (totalSurplus * userCreditTokensBalance) / totalCreditTokens;
//          reserve.members[msg.sender].memberSurplus = userSurplus;
//          emit TakasureEvents.OnMemberSurplusUpdated(
//              reserve.members[msg.sender].memberId,
//              userSurplus
//          );
//      }
