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
        function calculateBmaCashFlowMethodDenominator(uint256,uint256,uint256) external returns uint256 envfree;
        function calculateDaysPassed(uint256,uint256) external returns uint256 envfree;
        function calculateMonthsPassed(uint256,uint256) external returns uint256 envfree;
    }