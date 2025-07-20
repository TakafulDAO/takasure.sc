## Apply to benefit

1. Coupon redeemer calls `SubscriptionModule::paySubscriptionOnBehalfOf` to allow the user to join the association
2. If there is a valid parent `SubscriptionModule`, calls `ReferralRewardsModule::calculateReferralRewards` to calculate and store the referral rewards
3. The payment is transfered to `SubscriptionModule` and the referral reserve amount is transfered to `ReferralRewardsModule`
4. KYC provider calls `KYCModule::approveKYC` to approve the user
5. If there were any parent waiting for rewards, this is the moment when they are paid `KYCModule` calls `ReferralRewardsModule::rewardParents` to pay the rewards to the parents. This reward is only for the 25USDC amount to pay the subscription
6. If the user wants to apply to a benefit then has to interact with the corresponding `BenefitModule`
7. The user calls `BenefitModule::joinBenefit` or the coupon redeemer calls `BenefitModule::joinBenefitOnBehalfOf` to apply for a benefit
8. This will create the member, transfer the contribution to the reserve, run algorithms, and reward the parent if needed. Thhe reward is similar to the ones combined from steps 2 and 5, but this time is for the benefit contribution
9. The backend will set the Benefit Multiplier for the user

## Dont apply to benefit

1. Coupon redeemer calls `SubscriptionModule::paySubscriptionOnBehalfOf` to allow the user to join
2. If there is a valid parent `SubscriptionModule`, calls `ReferralRewardsModule::calculateReferralRewards` to calculate and store the referral rewards
3. The payment is transfered to `SubscriptionModule` and the referral reserve amount is transfered to `ReferralRewardsModule`
4. KYC provider calls `KYCModule::approveKYC` to approve the user
5. If there were any parent waiting for rewards, this is the moment when they are paid `KYCModule` calls `ReferralRewardsModule::rewardParents` to pay the rewards to the parents. This reward is only for the 25USDC amount to pay the subscription
6. After the corresponding time, the operator calls `SubscriptionModule::transferDonationsToReserve` and this calls `RevenueModule::depositRevenue` to deposit the association subscription amount to the reserve as a donation
