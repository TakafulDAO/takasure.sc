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

invariant bma_numerator_in_cash_flow_method_is_greater_than_zero(uint256 a, uint256 b, uint256 c, uint256 d)
    calculateBmaCashFlowMethodNumerator(a, b, c, d) > 0
    {
        preserved {
            require(a > 0 && b > 0 && c > 0 && d > 0);
        }
    }

invariant bma_denominator_in_cash_flow_method_is_greater_than_zero(uint256 x, uint256 y, uint256 z)
    calculateBmaCashFlowMethodDenominator(x, y, z) > 0
    {
        preserved {
            require(x > 0 && y > 0 && z > 0);
        }
    }