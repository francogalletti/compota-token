// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { Compota } from "../src/Compota.sol";
import { IERC20Extended } from "@mzero-labs/interfaces/IERC20Extended.sol";
import { ICompota } from "../src/intefaces/ICompota.sol";
import { ERC20 } from "solmate/tokens/ERC20.sol";
import { IUniswapV2Pair } from "../src/intefaces/IUniswapV2Pair.sol";
import "forge-std/console.sol";

contract CompotaTest is Test {
    Compota token;
    address owner = address(1);
    address alice = address(2);
    address bob = address(3);
    MockLPToken lpToken1;
    MockLPToken lpToken2;

    uint256 constant SCALE_FACTOR = 10_000;
    uint256 constant INITIAL_SUPPLY = 1000 * 10e6;
    uint256 constant BURN_AMOUNT = 400 * 10e6;
    uint256 constant TRANSFER_AMOUNT = 300 * 10e6;
    uint256 constant INSUFFICIENT_AMOUNT = 0;
    uint16 constant INTEREST_RATE = 1000; // 10% APY in BPS
    uint32 constant TIME_THRESHOLD = 365 days;
    uint32 constant MULTIPLIER_MAX = 2e6; // Max multiplier (scaled by 1e6)

    function setUp() external {
        vm.prank(owner);
        token = new Compota(INTEREST_RATE, 1 days, 1_000_000_000e6);
        lpToken1 = new MockLPToken(
            address(token),
            address(0) // ETH as token1
        );
        lpToken2 = new MockLPToken(
            address(token),
            address(0) // ETH as token1
        );
    }

    function testInitialization() external view {
        assertEq(token.owner(), owner);
        assertEq(token.name(), "Compota Token");
        assertEq(token.symbol(), "COMPOTA");
        assertEq(token.yearlyRate(), 1e3);
        assertEq(token.rewardCooldownPeriod(), 1 days);
    }

    function testMintingByOwner() external {
        _mint(owner, alice, INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY);
    }

    function testMintingFailsByNonOwner() external {
        // Alice tries to mint tokens
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        token.mint(alice, INITIAL_SUPPLY);
    }

    function testMintingByNewOwnerAfterTransfer() external {
        vm.prank(owner);
        // Transfer ownership to alice
        token.transferOwnership(alice);

        // owner should not be able to mint tokens anymore
        vm.expectRevert("UNAUTHORIZED");
        token.mint(bob, INITIAL_SUPPLY);

        // alice should be able to mint tokens now
        _mint(alice, bob, INITIAL_SUPPLY);
        assertEq(token.balanceOf(bob), INITIAL_SUPPLY);
    }

    function testMintingInvalidRecipient() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Extended.InvalidRecipient.selector, address(0)));
        token.mint(address(0), INITIAL_SUPPLY);
    }

    function testMintingInsufficientAmount() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Extended.InsufficientAmount.selector, INSUFFICIENT_AMOUNT));
        token.mint(alice, INSUFFICIENT_AMOUNT);
    }

    function testBurningTokensCorrectly() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        _burn(alice, BURN_AMOUNT);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - BURN_AMOUNT);
        _burn(alice, BURN_AMOUNT / 2);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - (BURN_AMOUNT + (BURN_AMOUNT / 2)));
    }

    function testBurningMoreThanBalance() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 valueToBurn = INITIAL_SUPPLY + BURN_AMOUNT;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICompota.InsufficientBalance.selector, valueToBurn));
        token.burn(valueToBurn);
    }

    function testBurningFailsWithInsufficientAmount() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Extended.InsufficientAmount.selector, INSUFFICIENT_AMOUNT));
        token.burn(INSUFFICIENT_AMOUNT);
    }

    function testBurningAllTokens() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        _burn(alice, INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testBurningTokensAfterTransfer() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        _transfer(alice, bob, TRANSFER_AMOUNT);
        _burn(alice, BURN_AMOUNT);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - TRANSFER_AMOUNT - BURN_AMOUNT);
        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
    }

    function testInterestAccrualAfterOneYear() external {
        vm.prank(owner);
        vm.expectEmit();
        emit ICompota.StartedEarningRewards(alice);
        token.mint(alice, INITIAL_SUPPLY);

        vm.warp(block.timestamp + 365 days);

        uint interest = (INITIAL_SUPPLY * INTEREST_RATE * 365 days) / (SCALE_FACTOR * 365 days);
        uint256 expectedFinalBalance = INITIAL_SUPPLY + interest;
        assertEq(token.balanceOf(alice), expectedFinalBalance);
    }

    function testInterestAccrualWithMultipleMints() external {
        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 balanceRaw = INITIAL_SUPPLY;

        vm.warp(block.timestamp + 180 days);

        // Update rewards to calculate interest for the first 180 days
        uint256 firstPeriodInterest = (balanceRaw * INTEREST_RATE * 180 days) / (SCALE_FACTOR * 365 days);
        uint256 expectedBalance = balanceRaw + firstPeriodInterest;

        _mint(owner, alice, INITIAL_SUPPLY);
        balanceRaw += INITIAL_SUPPLY + firstPeriodInterest;
        expectedBalance += INITIAL_SUPPLY;

        vm.warp(block.timestamp + 185 days);

        // Update rewards to calculate interest for the next 185 days with updated balance
        uint256 secondPeriodInterest = (balanceRaw * INTEREST_RATE * 185 days) / (SCALE_FACTOR * 365 days);
        expectedBalance += secondPeriodInterest;

        assertEq(token.balanceOf(alice), expectedBalance);
    }

    function testInterestAccrualWithRateChange() external {
        uint16 initialRate = 1000; // 10% APY
        uint16 newRate = 500; // 5% APY

        vm.prank(owner);
        token.setYearlyRate(initialRate);

        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 balanceRaw = INITIAL_SUPPLY;
        vm.warp(block.timestamp + 180 days);

        vm.prank(alice);
        token.claimRewards();
        uint256 firstPeriodInterest = (balanceRaw * initialRate * 180 days) / (SCALE_FACTOR * 365 days);
        balanceRaw += firstPeriodInterest;

        vm.prank(owner);
        token.setYearlyRate(newRate);

        uint256 tokensToMint = 500 * 10e6;
        _mint(owner, alice, tokensToMint);
        balanceRaw += tokensToMint;

        vm.warp(block.timestamp + 30 days);

        // Claim rewards again after the next 30 days with the new rate
        vm.prank(alice);
        token.claimRewards();
        uint256 secondPeriodInterest = (balanceRaw * newRate * 30 days) / (SCALE_FACTOR * 365 days);
        balanceRaw += secondPeriodInterest;

        uint256 expectedFinalBalance = balanceRaw;
        assertEq(token.balanceOf(alice), expectedFinalBalance);
    }

    function testInterestAccrualWithoutBalanceChange() external {
        uint256 tokensToMint = 10e3;
        _mint(owner, alice, tokensToMint);
        uint256 balanceRaw = tokensToMint;
        vm.warp(block.timestamp + 10 days);

        uint256 firstPeriodInterest = (balanceRaw * INTEREST_RATE * 10 days) / (SCALE_FACTOR * 365 days);
        assertEq(token.balanceOf(alice), balanceRaw + firstPeriodInterest);

        vm.warp(block.timestamp + 18 days);

        uint256 secondPeriodInterest = (balanceRaw * INTEREST_RATE * 18 days) / (SCALE_FACTOR * 365 days);
        uint256 expectedFinalBalance = balanceRaw + firstPeriodInterest + secondPeriodInterest;
        assertEq(token.balanceOf(alice), expectedFinalBalance);
    }

    function testSetYearlyRate() public {
        // Only the owner should be able to set the yearly rate within the valid range
        vm.prank(owner);
        token.setYearlyRate(500);
        assertEq(token.yearlyRate(), 500);

        // Expect revert if non-owner tries to set the yearly rate
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        token.setYearlyRate(100);

        vm.prank(owner);
        // Test with invalid rate below minimum
        vm.expectRevert(abi.encodeWithSelector(ICompota.InvalidYearlyRate.selector, 99));
        token.setYearlyRate(99);

        vm.prank(owner);
        // Test with invalid rate above maximum
        vm.expectRevert(abi.encodeWithSelector(ICompota.InvalidYearlyRate.selector, 40001));
        token.setYearlyRate(40001);
    }

    function testConstructorInitializesYearlyRate() public {
        Compota newToken = new Compota(500, 1 days, 1_000_000_000e6);
        assertEq(newToken.yearlyRate(), 500);
    }

    function testConstructorRevertsOnInvalidYearlyRate() public {
        vm.expectRevert(abi.encodeWithSelector(ICompota.InvalidYearlyRate.selector, 0));
        new Compota(0, 1 days, 1_000_000_000e6);

        vm.expectRevert(abi.encodeWithSelector(ICompota.InvalidYearlyRate.selector, 50000));
        new Compota(50000, 1 days, 1_000_000_000e6);
    }

    function testInterestAccumulationAfterTransfer() external {
        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 aliceBalanceRaw = INITIAL_SUPPLY;
        vm.warp(block.timestamp + 180 days);

        uint256 firstPeriodInterestAlice = (aliceBalanceRaw * INTEREST_RATE * 180 days) / (SCALE_FACTOR * 365 days);

        _transfer(alice, bob, TRANSFER_AMOUNT);
        aliceBalanceRaw -= TRANSFER_AMOUNT;
        uint256 bobBalanceRaw = TRANSFER_AMOUNT;

        vm.prank(alice);
        token.claimRewards();

        uint256 aliceTotalBalance = aliceBalanceRaw + firstPeriodInterestAlice;

        vm.warp(block.timestamp + 185 days);

        vm.prank(alice);
        token.claimRewards();
        vm.prank(bob);
        token.claimRewards();

        uint256 secondPeriodInterestAlice = (aliceTotalBalance * INTEREST_RATE * 185 days) / (SCALE_FACTOR * 365 days);
        uint256 secondPeriodInterestBob = (bobBalanceRaw * INTEREST_RATE * 185 days) / (SCALE_FACTOR * 365 days);

        uint256 expectedFinalBalanceAlice = aliceTotalBalance + secondPeriodInterestAlice;
        uint256 expectedFinalBalanceBob = bobBalanceRaw + secondPeriodInterestBob;

        assertEq(token.balanceOf(alice), expectedFinalBalanceAlice);
        assertEq(token.balanceOf(bob), expectedFinalBalanceBob);
    }

    function testTotalSupplyWithUnclaimedRewards() external {
        uint256 aliceInitialMint = 1000 * 10e6;
        uint256 bobInitialMint = aliceInitialMint * 2;

        _mint(owner, alice, aliceInitialMint);
        _mint(owner, bob, bobInitialMint);

        uint256 totalSupply = aliceInitialMint + bobInitialMint;
        assertEq(token.totalSupply(), totalSupply);

        vm.warp(block.timestamp + 180 days);

        uint256 expectedRewards = (totalSupply * INTEREST_RATE * 180 days) / (SCALE_FACTOR * 365 days);

        assertEq(token.totalSupply(), totalSupply + expectedRewards);
    }

    function testClaimRewardsRewardCooldownPeriodNotCompleted() public {
        vm.prank(owner);
        token.mint(alice, 1000 * 10e6);

        vm.prank(alice);

        uint256 balancePreClaim = token.balanceOf(alice);
        token.claimRewards();
        uint256 balancePostClaim = token.balanceOf(alice);
        assertEq(balancePreClaim, balancePostClaim);
    }

    function testClaimRewardsWithCooldownPeriod() public {
        _mint(owner, alice, INITIAL_SUPPLY);

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        token.claimRewards();

        vm.prank(alice);
        uint256 balancePreClaim = token.balanceOf(alice);
        token.claimRewards();
        uint256 balancePostClaim = token.balanceOf(alice);
        assertEq(balancePreClaim, balancePostClaim);

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        token.claimRewards();
    }

    function testDynamicCooldownPeriodChange() public {
        _mint(owner, alice, INITIAL_SUPPLY);

        vm.prank(owner);
        token.setRewardCooldownPeriod(12 hours);
        assertEq(token.rewardCooldownPeriod(), 12 hours);

        vm.warp(block.timestamp + 15 days);

        vm.prank(alice);
        token.claimRewards();

        vm.warp(block.timestamp + 13 hours);

        vm.prank(alice);
        token.claimRewards();
    }

    function testClaimFailsAfterCooldownIncrease() public {
        _mint(owner, alice, INITIAL_SUPPLY);

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        token.claimRewards();

        vm.prank(owner);
        token.setRewardCooldownPeriod(3 days);
        assertEq(token.rewardCooldownPeriod(), 3 days);

        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);

        uint256 balancePreClaim = token.balanceOf(alice);
        token.claimRewards();
        uint256 balancePostClaim = token.balanceOf(alice);
        assertEq(balancePreClaim, balancePostClaim);
    }

    function testCooldownDoesNotAffectMintingOrBurning() public {
        _mint(owner, alice, INITIAL_SUPPLY);

        _mint(owner, alice, 500 * 10e6);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY + (500 * 10e6));

        _burn(alice, 200 * 10e6);
        assertEq(token.balanceOf(alice), (INITIAL_SUPPLY + (500 * 10e6)) - (200 * 10e6));
    }

    function testCooldownDoesNotAffectTransfer() public {
        _mint(owner, alice, INITIAL_SUPPLY);

        uint256 aliceBalanceRaw = INITIAL_SUPPLY;
        vm.warp(block.timestamp + 10 days);

        uint256 interest = (aliceBalanceRaw * INTEREST_RATE * 10 days) / (SCALE_FACTOR * 365 days);

        _transfer(alice, bob, 200 * 10e6);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY + interest - 200 * 10e6);
        assertEq(token.balanceOf(bob), 200 * 10e6);
    }

    function testSetCooldownPeriodByNonOwnerFails() public {
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        token.setRewardCooldownPeriod(12 hours);
    }

    function testSetCooldownPeriodToZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICompota.InvalidRewardCooldownPeriod.selector, 0));
        token.setRewardCooldownPeriod(0);
    }

    function testMintCannotExceedMaxTotalSupply() public {
        uint224 maxSupply = 1_000_000 * 10e6;
        vm.prank(owner);
        token = new Compota(INTEREST_RATE, 1 days, maxSupply);

        uint256 mintable = 900_000 * 10e6;
        _mint(owner, alice, mintable);

        uint256 remaining = maxSupply - mintable;
        _mint(owner, bob, remaining);

        _mint(owner, bob, 1);
        assertEq(token.totalSupply(), maxSupply);

        vm.warp(block.timestamp + 100 days);
        assertEq(token.totalSupply(), maxSupply);
    }

    function testMintPartialWhenNearMaxTotalSupply() public {
        uint224 maxSupply = 1_000_000 * 10e6;
        vm.prank(owner);
        token = new Compota(INTEREST_RATE, 1 days, maxSupply);

        uint256 mintable = 999_999 * 10e6;
        _mint(owner, alice, mintable);

        uint256 remaining = maxSupply - mintable;

        vm.prank(owner);
        token.mint(bob, 2 * 10e6);

        assertEq(token.balanceOf(bob), remaining);
        assertEq(token.totalSupply(), maxSupply);
    }

    function testInterestAccrualRespectsMaxTotalSupply() external {
        uint224 maxSupply = 600 * 10e6;
        vm.prank(owner);
        token = new Compota(INTEREST_RATE, 1 days, maxSupply);

        uint256 initialMint = 300 * 10e6;
        _mint(owner, alice, initialMint);

        uint256 balanceRaw = initialMint;

        uint256 timeElapsed = 180 days;
        vm.warp(block.timestamp + timeElapsed);

        uint256 firstPeriodInterest = (balanceRaw * INTEREST_RATE * timeElapsed) / (SCALE_FACTOR * 365 days);
        uint256 expectedSupply = balanceRaw + firstPeriodInterest;

        uint256 totalSupplyAfterInterest = token.totalSupply();
        assertEq(totalSupplyAfterInterest, expectedSupply, "Total supply after interest mismatch");
        assertTrue(totalSupplyAfterInterest <= maxSupply, "Total supply exceeded maxTotalSupply");

        uint256 additionalMint = 400 * 10e6;
        uint256 remainingSupply = maxSupply - token.totalSupply();
        uint256 adjustedMint = additionalMint > remainingSupply ? remainingSupply : additionalMint;
        _mint(owner, alice, adjustedMint);

        expectedSupply += adjustedMint;
        assertEq(token.totalSupply(), expectedSupply, "Total supply should equal maxTotalSupply");

        timeElapsed = 185 days;
        vm.warp(block.timestamp + timeElapsed);

        assertEq(token.totalSupply(), maxSupply, "Total supply should not exceed maxTotalSupply");
        assertEq(token.balanceOf(alice), maxSupply, "Alice's balance should match maxTotalSupply");
    }

    function testOwnerCanAddMultiplePools() external {
        vm.startPrank(owner);
        token.addStakingPool(address(lpToken1), 2e6, 365 days);
        token.addStakingPool(address(lpToken2), 3e6, 180 days);
        vm.stopPrank();

        (address poolLp1, uint256 multiplierMax1, uint256 timeThreshold1) = getPoolData(0);
        assertEq(poolLp1, address(lpToken1));
        assertEq(multiplierMax1, 2e6);
        assertEq(timeThreshold1, 365 days);

        (address poolLp2, uint256 multiplierMax2, uint256 timeThreshold2) = getPoolData(1);
        assertEq(poolLp2, address(lpToken2));
        assertEq(multiplierMax2, 3e6);
        assertEq(timeThreshold2, 180 days);
    }

    function testStakeInSinglePool() external {
        vm.startPrank(owner);
        token.addStakingPool(address(lpToken1), 2e6, 365 days);
        vm.stopPrank();

        lpToken1.mint(alice, 1000e6);

        vm.startPrank(alice);
        lpToken1.approve(address(token), 500e6);
        token.stakeLiquidity(0, 500e6);
        vm.stopPrank();

        (uint32 startTs, uint224 staked) = token.stakes(0, alice);
        assertEq(staked, 500e6, "Staked amount should be recorded");
        assertTrue(startTs > 0, "Start timestamp should be set");
    }

    function testStakeInMultiplePools() external {
        vm.startPrank(owner);
        token.addStakingPool(address(lpToken1), 2e6, 365 days);
        token.addStakingPool(address(lpToken2), 3e6, 180 days);
        vm.stopPrank();

        lpToken1.mint(alice, 1000e6);
        vm.startPrank(alice);
        lpToken1.approve(address(token), 1000e6);
        token.stakeLiquidity(0, 300e6);
        vm.stopPrank();

        lpToken2.mint(alice, 2000e6);
        vm.startPrank(alice);
        lpToken2.approve(address(token), 2000e6);
        token.stakeLiquidity(1, 500e6);
        vm.stopPrank();

        (, uint224 staked0) = token.stakes(0, alice);
        (, uint224 staked1) = token.stakes(1, alice);

        assertEq(staked0, 300e6, "Staked in pool 0 should match");
        assertEq(staked1, 500e6, "Staked in pool 1 should match");
    }

    function testUnstakePartially() external {
        vm.startPrank(owner);
        token.addStakingPool(address(lpToken1), 1e6, 365 days);

        lpToken1.mint(alice, 1000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        lpToken1.approve(address(token), 1000e6);
        token.stakeLiquidity(0, 300e6);

        (, uint224 staked) = token.stakes(0, alice);
        assertEq(staked, 300e6, "Should have 300e6 left staked");

        token.unstakeLiquidity(0, 200e6);

        assertEq(lpToken1.balanceOf(alice), 1000e6 - 300e6 + 200e6, "Alice should get back some LP");
    }

    function testUnstakeAll() external {
        vm.startPrank(owner);
        token.addStakingPool(address(lpToken1), 1e6, 365 days);

        lpToken1.mint(alice, 1000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        lpToken1.approve(address(token), 1000e6);
        token.stakeLiquidity(0, 300e6);

        (, uint224 staked) = token.stakes(0, alice);
        assertEq(staked, 300e6, "Should have 300e6 left staked");

        token.unstakeLiquidity(0, 300e6);

        assertEq(lpToken1.balanceOf(alice), 1000e6, "Alice should get back some LP");
    }

    function testUnstakeMoreThanStakedReverts() external {
        vm.startPrank(owner);
        token.addStakingPool(address(lpToken1), 1e6, 365 days);

        lpToken1.mint(alice, 1000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        lpToken1.approve(address(token), 1000e6);
        token.stakeLiquidity(0, 300e6);

        (, uint224 staked) = token.stakes(0, alice);
        assertEq(staked, 300e6, "Should have 300e6 left staked");

        vm.expectRevert("Not enough staked");
        token.unstakeLiquidity(0, 400e6);
    }

    function testUnstakeZeroAmountReverts() external {
        vm.startPrank(owner);
        token.addStakingPool(address(lpToken1), 1e6, 365 days);

        lpToken1.mint(alice, 1000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        lpToken1.approve(address(token), 1000e6);
        token.stakeLiquidity(0, 300e6);

        vm.expectRevert("amount=0");
        token.unstakeLiquidity(0, 0);
    }

    function testUnstakeWithoutStakeReverts() external {
        vm.startPrank(owner);
        token.addStakingPool(address(lpToken1), 1e6, 365 days);

        lpToken1.mint(alice, 1000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        lpToken1.approve(address(token), 1000e6);
        token.stakeLiquidity(0, 300e6);

        vm.startPrank(bob);
        vm.expectRevert("Not enough staked");
        token.unstakeLiquidity(0, 100e6);
    }

    // function testRewardsCalculation() external {
    //     // Add LP pool to Compota
    //     vm.startPrank(owner);
    //     token.addStakingPool(address(lpToken1), MULTIPLIER_MAX, TIME_THRESHOLD);

    //     // Mint and transfer tokens for testing
    //     WETH weth = new WETH();
    //     token.mint(alice, 10_000e6); // Alice starts with 10,000 COMPOTA tokens
    //     weth.mint(alice, 10e18); // Alice has 10 WETH
    //     lpToken1.mint(alice, 100e18); // Mint LP tokens for Alice

    //     // Set reserves for the mock LP token
    //     lpToken1.setReserves(1000e6, 1 ether); // 1000 COMPOTA, 1 ETH

    //     vm.stopPrank();

    //     // Approve tokens for the LP pool
    //     vm.startPrank(alice);
    //     token.approve(address(lpToken1), type(uint256).max);
    //     weth.approve(address(lpToken1), type(uint256).max);

    //     // Approve LP tokens for Compota
    //     lpToken1.approve(address(token), type(uint256).max);

    //     // Alice stakes 10 LP tokens in the Compota contract
    //     uint256 lpAmount = 10e18; // 10 LP tokens
    //     token.stakeLiquidity(0, lpAmount); // Stake in poolId = 0

    //     // Fast forward 10 days
    //     vm.warp(block.timestamp + 10 days);

    //     // Calculate expected base rewards
    //     uint256 timeElapsed = 10 days;
    //     uint256 baseRewards = (10_000e6 * SCALE_FACTOR * timeElapsed) / (10_000 * 31_536_000);

    //     // Calculate expected staking rewards
    //     uint256 timeStaked = timeElapsed;
    //     uint256 cubicMultiplier = 1e6 + (((MULTIPLIER_MAX - 1e6) * (timeStaked ** 3)) / (uint256(TIME_THRESHOLD) ** 3));
    //     uint256 lpTotalSupply = lpToken1.totalSupply();
    //     uint112 reserveCompota = lpToken1.reserve0(); // Assuming token0 is COMPOTA
    //     uint256 compotaShare = (lpAmount * reserveCompota) / lpTotalSupply;
    //     uint256 stakingRewards = (compotaShare * SCALE_FACTOR * timeElapsed * cubicMultiplier) /
    //         (1e6 * 31_536_000 * 10_000);

    //     // Claim rewards and verify balances

    //     uint256 totalExpectedRewards = baseRewards + stakingRewards;
    //     uint256 aliceBalance = token.balanceOf(alice);

    //     console.log(baseRewards);
    //     console.log(stakingRewards);
    //     console.log(totalExpectedRewards);

    //     token.claimRewards();
    //     vm.stopPrank();

    //     // Verify base rewards
    //     assertApproxEqAbs(baseRewards, baseRewards, 1, "Base rewards mismatch");

    //     // Verify staking rewards
    //     assertApproxEqAbs(stakingRewards, stakingRewards, 1, "Staking rewards mismatch");

    //     // Verify total rewards
    //     assertApproxEqAbs(aliceBalance, 10_000e6 + totalExpectedRewards, 1, "Total rewards mismatch");
    // }

    /* ============ Helper functions ============ */

    function getPoolData(
        uint256 poolId
    ) internal view returns (address lpTokenAddr, uint32 multiplierMax, uint32 timeThreshold) {
        (lpTokenAddr, multiplierMax, timeThreshold) = token.pools(poolId);
    }

    function _mint(address minter, address to, uint256 amount) internal {
        vm.prank(minter);
        token.mint(to, amount);
    }

    function _burn(address burner, uint256 amount) internal {
        vm.prank(burner);
        token.burn(amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        token.transfer(to, amount);
    }
}

contract WETH is ERC20("Wrapper Ethereum", "WETH", 18) {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockLPToken is ERC20("Mock LP", "MLP", 18) {
    uint112 public reserve0;
    uint112 public reserve1;
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function getReserves() external view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }
}