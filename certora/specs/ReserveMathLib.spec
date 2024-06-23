/*
* Verification of Reserve Math
*/

using ReserveMathLibHarness as reserveMath;

methods {
    function updateProFormaFundReserve(uint256,uint256,uint256) external returns uint256 envfree;
    function updateProFormaClaimReserve(uint256,uint256,uint8,uint256) external returns uint256 envfree;
    function calculateDynamicReserveRatioReserveShortfallMethod(uint256,uint256,uint256,uint256) external returns uint256 envfree;
    function calculateBmaInflowAssumption(uint256,uint256,uint256) external returns uint256 envfree;
    function calculateBmaCashFlowMethodNumerator(uint256,uint256,uint256,uint256) external returns uint256 envfree;
    function calculateBmaCashFlowMethodDenominator(uint256,uint256,uint256) external returns uint256 envfree;
    function calculateDaysPassed(uint256,uint256) external returns uint256 envfree;
    function calculateMonthsPassed(uint256,uint256) external returns uint256 envfree;
}

rule bma_denominator_in_cash_flow_method_is_greater_than_zero(){
    uint256 totalFundReserves;
    uint256 bmaFundReserveShares;
    uint256 proFormaClaimReserve;

    require((totalFundReserves * bmaFundReserveShares) > 100 || proFormaClaimReserve > 0);

    assert(reserveMath.calculateBmaCashFlowMethodDenominator(totalFundReserves, bmaFundReserveShares, proFormaClaimReserve) > 0);
}

rule bma_numerator_in_cash_flow_method_is_greater_than_zero(){
    uint256 totalClaimReserves;
    uint256 totalFundReserves;
    uint256 bmaFundReserveShares;
    uint256 bmaInflowAssumption;

    require(totalClaimReserves > 0 || bmaInflowAssumption > 0 || (totalFundReserves * bmaFundReserveShares) > 100);

    assert(reserveMath.calculateBmaCashFlowMethodNumerator(totalClaimReserves, totalFundReserves, bmaFundReserveShares, bmaInflowAssumption) > 0);
}

