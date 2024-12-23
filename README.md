>>==========================================================<<
||  ____    ___    __  __   ____     ___    _____      _    ||
|| / ___|  / _ \  |  \/  | |  _ \   / _ \  |_   _|    / \   ||
||| |     | | | | | |\/| | | |_) | | | | |   | |     / _ \  ||
||| |___  | |_| | | |  | | |  __/  | |_| |   | |    / ___ \ ||
|| \____|  \___/  |_|  |_| |_|      \___/    |_|   /_/   \_\||
>>==========================================================<<

**Compota** is an ERC20 token designed to **continuously** accrue rewards for its holders. These rewards come in two main forms:
1. **Base Rewards**: Simply holding the token yields automatically accruing interest over time.  
2. **Staking Rewards**: Staking **Uniswap V2-compatible** liquidity pool (LP) tokens for additional yield, boosted by a **time-based cubic multiplier** applied to the staking rewards formula.

The system also introduces key features such as **configurable interest rate bounds**, a **reward cooldown** to prevent **excessive compounding**, a **maximum total supply cap**, **multi-pool** staking, and thorough **ownership** controls. This README explains every novel element, mathematical underpinning, usage flow, and test coverage in great detail.

---

## Table of Contents

1. [Conceptual Overview](#conceptual-overview)  
2. [Feature Highlights](#feature-highlights)  
3. [Contract Architecture](#contract-architecture)  
4. [Mathematical Foundations of Rewards](#mathematical-foundations-of-rewards)  
   - [Base Rewards](#base-rewards)  
   - [Staking Rewards](#staking-rewards)  
   - [Cubic Multiplier](#cubic-multiplier)  
   - [Average Balance & Accumulated Balance Per Time](#average-balance--accumulated-balance-per-time)  
5. [Implementation Details](#implementation-details)  
   - [Multi-Pool Support](#multi-pool-support)  
   - [Min/Max Yearly Rate](#minmax-yearly-rate)  
   - [Reward Cooldown](#reward-cooldown)  
   - [Max Total Supply Constraint](#max-total-supply-constraint)  
   - [Global vs. User-Specific Reward Updates](#global-vs-user-specific-reward-updates)  
   - [Active Stakers Management](#active-stakers-management)  
   - [Precision & Overflow Protection](#precision--overflow-protection)  
   - [Custom Errors & Event Emissions](#custom-errors--event-emissions)  
6. [Integration with External Interfaces](#integration-with-external-interfaces)  
7. [Ownership & Access Control](#ownership--access-control)  
8. [ERC20 Standard + Extended](#erc20-standard--extended)  
9. [API Reference & Methods](#api-reference--methods)  
   - [ICompota Interface](#icompota-interface)  
   - [Additional Public/External Functions](#additional-publicexternal-functions)  
10. [Step-by-Step Usage](#step-by-step-usage)  
    - [Deployment](#deployment)  
    - [Staking & Unstaking Flow](#staking--unstaking-flow)  
    - [Claiming Rewards](#claiming-rewards)  
    - [Minting & Burning](#minting--burning)  
    - [Transferring Tokens](#transferring-tokens)  
11. [Test Coverage & Notable Scenarios](#test-coverage--notable-scenarios)  
    - [Ownership & Access Tests](#ownership--access-tests)  
    - [Minting, Burning, and Supply Tests](#minting-burning-and-supply-tests)  
    - [Interest Accrual & Rate Change Tests](#interest-accrual--rate-change-tests)  
    - [Cooldown Logic Tests](#cooldown-logic-tests)  
    - [Staking & Unstaking Tests](#staking--unstaking-tests)  
    - [Fuzz Testing](#fuzz-testing)  
12. [Security & Audit Considerations](#security--audit-considerations)  
13. [License](#license)

---

## Conceptual Overview

`Compota` is a system that **auto-accrues** yield for holders while also allowing **stakers** to earn boosted returns. The **boost** is governed by a **cubic multiplier** that scales rewards significantly the longer the staker remains in the pool. Additionally, the system is designed with **predictable** rate changes (bounded by min/max BPS), a **reward cooldown** to prevent abuse via rapid re-claims, and a **maximum total supply** that caps inflation.

---

## Feature Highlights

1. **Continuous Accrual**: Rewards accumulate over time, without constant user claims.  
2. **Cubic Multiplier**: Novel time-based booster for stakers, culminating in higher returns for longer durations.  
3. **Multi-Pool Staking**: Supports multiple LP tokens, each with distinct parameters.  
4. **Configurable Rate Bounds**: An **owner** can adjust the yearlyRate (APR in BPS) within `[MIN_YEARLY_RATE, MAX_YEARLY_RATE]`.  
5. **Reward Cooldown**: Users must wait a specified period to claim new rewards, preventing **over-compounding**.  
6. **Max Total Supply**: Prevents unbounded inflation.  
7. **Precision & Overflow Handling**: Uses `uint224` and carefully scaled integer math.

---

## Contract Architecture

`Compota` inherits from:
- **ERC20Extended**: A standard token interface (with 6 decimals) plus minor utility methods.  
- **Owned**: An ownership module from **Solmate** controlling certain admin functions.

It interfaces with:
- **ICompota**: The main external interface.  
- **IERC20**: For interacting with ERC20-based LP tokens.  
- **IUniswapV2Pair**: For reading pool reserves (`getReserves()`) and identifying token addresses, ensuring **Uniswap v2** compatibility.

**Data structures** central to the system:

- **`AccountBalance`**: Tracks base holdings for each user.  
- **`UserStake`**: Tracks staked LP and relevant timestamps.  
- **`StakingPool`**: Parameters for each pool, including `lpToken`, `multiplierMax`, `timeThreshold`.

---

## Mathematical Foundations of Rewards

### Base Rewards

For **base rewards**, each address’s holding grows according to:

**Δ_base = (avgBalance * elapsedTime * yearlyRate) / (SCALE_FACTOR * SECONDS_PER_YEAR)**

where:  
- **avgBalance** is the user’s time-weighted average holdings,  
- **elapsedTime** is the number of seconds since last update,  
- **yearlyRate** is in BPS,  
- **SCALE_FACTOR** = 10,000,  
- **SECONDS_PER_YEAR** = 31,536,000.

---

### Staking Rewards

When **staking** an LP token, the user’s effective portion of `Compota` in the pool is determined by:

**compotaPortion = (avgLpStaked * compotaReserve) / lpTotalSupply**

The staking reward itself (Δ_staking) applies the **cubic multiplier** in the final step:

**Δ_staking = (compotaPortion * elapsedTime * yearlyRate) / (SCALE_FACTOR * SECONDS_PER_YEAR) * cubicMultiplier(t)**

---

### Cubic Multiplier

A core innovation is the **cubic multiplier** for staking. Let:
- t = timeStaked  
- timeThreshold  
- multiplierMax (scaled by 1e6)

Then:

**cubicMultiplier(t) = multiplierMax      if t >= timeThreshold**

**cubicMultiplier(t) = 1*10^6 + (multiplierMax - 10^6) * (t / timeThreshold)^3      if t < timeThreshold**

---

### Average Balance & Accumulated Balance Per Time

To compute **average balance**, the contract uses **discrete integration** at every balance-changing event (transfer, stake, unstake, claim).

1. Accumulate:

**accumulatedBalancePerTime += (balance * (T_now - lastUpdateTimestamp))**

**lastUpdateTimestamp = T_now**

2. Average Balance:

**avgBalance = accumulatedBalancePerTime / (T_final - periodStartTimestamp)**

This yields a **time-weighted average** of how much the user held or staked.

---

## Implementation Details

### Multi-Pool Support
- The contract holds an array of `StakingPool`.
- Each pool has its own LP token, `multiplierMax`, and `timeThreshold`.
- Users can stake/unstake by specifying `poolId`.

### Min/Max Yearly Rate
- `MIN_YEARLY_RATE` and `MAX_YEARLY_RATE` define the allowable range.
- Attempts to set `yearlyRate` outside this range revert.

### Reward Cooldown
- A global `rewardCooldownPeriod` ensures a user cannot claim rewards too often, preventing **over-compounding**.
- If a user attempts to claim before cooldown finishes, only their internal accounting is updated.

### Max Total Supply Constraint
- Any token mint or reward mint cannot exceed `maxTotalSupply`.
- If a reward calculation attempts to exceed the supply cap, it is truncated.

### Global vs. User-Specific Reward Updates
- Maintains global timestamps plus user-specific data (`AccountBalance`, `UserStake`).
- Ensures each user’s pending rewards are accurately tracked and minted only if cooldown passes.

### Active Stakers Management
- Tracks stakers in an `activeStakers` array + `_activeStakerIndices` mapping.
- Users are removed from the list when they fully unstake from all pools.

### Precision & Overflow Protection
- Uses `uint224` to avoid overflow.
- BPS calculations are scaled by `10,000`, multipliers by `1e6`.
- Casting is checked with `toSafeUint224`.

### Custom Errors & Event Emissions
- Custom errors like `InvalidYearlyRate`, `NotEnoughStaked`, `InsufficientAmount` give precise revert reasons.
- Events like `YearlyRateUpdated`, `RewardCooldownPeriodUpdated` ensure transparency.

---

## Integration with External Interfaces

- **IUniswapV2Pair**: Queries `getReserves()` to identify how many `Compota` tokens are in the LP.
- **IERC20**: Standard for staking/unstaking LP tokens.
- **Uniswap v2** chosen for straightforward reserve calculations. Future v4 pools may be wrapped to mimic v2 (see [this approach](https://github.com/hensha256/v2-on-v4/blob/main/src/V2PairHook.sol)).

---

## Ownership & Access Control

- Inherits `Owned` from **Solmate**.
- Only `owner` can:
- Set `yearlyRate`, within min/max range
- Set `rewardCooldownPeriod`
- Add staking pools
- Mint new tokens
- Non-owners cannot perform these privileged actions.

---

## ERC20 Standard + Extended

- Implements standard ERC20 methods: `transfer`, `approve`, `balanceOf`, `totalSupply`, etc.
- `balanceOf(account)` includes unclaimed rewards.
- `transfer` updates both sender’s and recipient’s reward states.

---

## API Reference & Methods

### ICompota Interface

1. **`setYearlyRate(uint16 newRate_)`**  
Adjusts APY (BPS) within `[MIN_YEARLY_RATE, MAX_YEARLY_RATE]`.

2. **`setRewardCooldownPeriod(uint32 newRewardCooldownPeriod_)`**  
Changes the cooldown for claiming.

3. **`addStakingPool(address lpToken_, uint32 multiplierMax_, uint32 timeThreshold_)`**  
Introduces a new pool.

4. **`stakeLiquidity(uint256 poolId_, uint256 amount_)`**  
Stakes LP tokens in `poolId_`.

5. **`unstakeLiquidity(uint256 poolId_, uint256 amount_)`**  
Unstakes LP tokens from `poolId_`.

6. **`mint(address to_, uint256 amount_)`**  
Owner-only. Respects `maxTotalSupply`.

7. **`burn(uint256 amount_)`**  
Burns user’s tokens.

8. **`balanceOf(address account_) returns (uint256)`**  
Current user balance + unclaimed rewards.

9. **`calculateBaseRewards(address account_, uint32 currentTimestamp_) returns (uint256)`**  
Helper function for base reward math.

10. **`calculateStakingRewards(address account_, uint32 currentTimestamp_) returns (uint256)`**  
 Helper function for staking reward math.

11. **`totalSupply() returns (uint256)`**  
 Global supply including pending rewards.

12. **`claimRewards()`**  
 Mints pending rewards if cooldown is met; otherwise updates state.

### Additional Public/External Functions
- **`calculateCubicMultiplier(uint256 multiplierMax_, uint256 timeThreshold_, uint256 timeStaked_) returns (uint256)`**  
Public helper to view the multiplier growth.

---

## Step-by-Step Usage

### Deployment

1. Deploy `Compota` with constructor parameters:
- `name_`, `symbol_`, `yearlyRate_`, `rewardCooldownPeriod_`, `maxTotalSupply_`.
2. Optionally add or configure pools and adjust rates (owner only).

---

### Staking & Unstaking Flow

1. **Add a Pool**:  
```solidity
addStakingPool(lpToken, multiplierMax, timeThreshold);
```

2.	**Stake**:
```solidity
stakeLiquidity(poolId, amount);
```

3.	**Unstake**:
```solidity
unstakeLiquidity(poolId, amount);
```

### Claiming Rewards

- `claimRewards()` checks if enough time has passed since the user’s last claim:
  - If the **cooldown** is satisfied, it **mints** pending base + staking rewards to the caller.
  - If the **cooldown** is not met, it only updates the user’s reward accounting internally (no new tokens minted).

---

### Minting & Burning

- **Mint** (owner only):
  ```solidity
  mint(to, amount);
  ```

- **Burn** (owner only):
  ```solidity
  burn(amount);
  ```
### Transferring Tokens

- Uses **standard ERC20** methods (`transfer`, `transferFrom`).
- Each transfer triggers reward updates for **both** the sender and the recipient, ensuring accurate reward calculations for all parties.

---

## Test Coverage & Notable Scenarios

### Ownership & Access Tests
- Confirms only the owner can set rates, add pools, and mint tokens.

### Minting, Burning, and Supply Tests
- Validates partial minting near `maxTotalSupply`.
- Ensures burning cannot exceed a holder’s balance.

### Interest Accrual & Rate Change Tests
- Covers incremental interest accrual (partial-year intervals) and updates following a rate change.

### Cooldown Logic Tests
- Ensures rewards are withheld if claimed prematurely (preventing over-compounding).
- Verifies normal mint/burn/transfer functionality remains unaffected by the cooldown.

### Staking & Unstaking Tests
- Checks multiple staking pools, partial or full unstaking, and invalid pool ID handling.

### Fuzz Testing
- Subjects the contract to large and random input values for minting, burning, base rewards, and staking rewards—ensuring robust edge-case coverage.

---

## Security & Audit Considerations

- **Ownership**: The `owner` can change rates, add pools, and mint tokens—adopt secure governance (e.g., multisig).
- **Time Manipulation**: Miners can nudge block timestamps slightly, but the contract’s design minimizes material impact over long durations.
- **Rate Boundaries**: Constraining the APY within `[MIN_YEARLY_RATE, MAX_YEARLY_RATE]` prevents extreme or sudden changes.
- **Cooldown Enforcement**: Thwarts repeated reward claims, limiting excessive compounding exploitation.
- **Max Supply**: Caps total token issuance to prevent runaway inflation.
- **Uniswap v2**: Straightforward reserve interface. For v4, consider [this wrapper approach](https://github.com/hensha256/v2-on-v4/blob/main/src/V2PairHook.sol).

---

## License

All code in `Compota.sol` and associated files is published under the **GPL-3.0** license.  
For full details, see the [LICENSE](./LICENSE) file.

(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧  Enjoy continuous compounding with Compota!  ✧ﾟ･: *ヽ(◕ヮ◕ヽ)





## Getting started

The easiest way to get started is by clicking the [Use this template](https://github.com/MZero-Labs/foundry-template/generate) button at the top right of this page.

If you prefer to go the CLI way:

```bash
forge init my-project --template https://github.com/MZero-Labs/foundry-template
```

## Development

### Installation

You may have to install the following tools to use this repository:

- [Foundry](https://github.com/foundry-rs/foundry) to compile and test contracts
- [lcov](https://github.com/linux-test-project/lcov) to generate the code coverage report
- [slither](https://github.com/crytic/slither) to static analyze contracts

Install dependencies:

```bash
npm i
```

### Env

Copy `.env` and write down the env variables needed to run this project.

```bash
cp .env.example .env
```

### Compile

Run the following command to compile the contracts:

```bash
npm run compile
```

### Coverage

Forge is used for coverage, run it with:

```bash
npm run coverage
```

You can then consult the report by opening `coverage/index.html`:

```bash
open coverage/index.html
```

### Test

To run all tests:

```bash
npm test
```

Run test that matches a test contract:

```bash
forge test --mc <test-contract-name>
```

Test a specific test case:

```bash
forge test --mt <test-case-name>
```

To run slither:

```bash
npm run slither
```

### Code quality

[Husky](https://typicode.github.io/husky/#/) is used to run [lint-staged](https://github.com/okonet/lint-staged) and tests when committing.

[Prettier](https://prettier.io) is used to format code. Use it by running:

```bash
npm run prettier
```

[Solhint](https://protofire.github.io/solhint/) is used to lint Solidity files. Run it with:

```bash
npm run solhint
```

To fix solhint errors, run:

```bash
npm run solhint-fix
```

### CI

The following Github Actions workflow are setup to run on push and pull requests:

- [.github/workflows/coverage.yml](.github/workflows/coverage.yml)
- [.github/workflows/test-gas.yml](.github/workflows/test-gas.yml)

It will build the contracts and run the test coverage, as well as a gas report.

The coverage report will be displayed in the PR by [github-actions-report-lcov](https://github.com/zgosalvez/github-actions-report-lcov) and the gas report by [foundry-gas-diff](https://github.com/Rubilmax/foundry-gas-diff).

For the workflows to work, you will need to setup the `MNEMONIC_FOR_TESTS` and `MAINNET_RPC_URL` repository secrets in the settings of your Github repository.

Some additional workflows are available if you wish to add fuzz, integration and invariant tests:

- [.github/workflows/test-fuzz.yml](.github/workflows/test-fuzz.yml)
- [.github/workflows/test-integration.yml](.github/workflows/test-integration.yml)
- [.github/workflows/test-invariant.yml](.github/workflows/test-invariant.yml)

You will need to uncomment them to activate them.

### Documentation

The documentation can be generated by running:

```bash
npm run doc
```

It will run a server on port 4000, you can then access the documentation by opening [http://localhost:4000](http://localhost:4000).

## Deployment

### Build

To compile the contracts for production, run:

```bash
npm run build
```

### Deploy

#### Local

Open a new terminal window and run [anvil](https://book.getfoundry.sh/reference/anvil/) to start a local chain:

```bash
anvil
```

Deploy the contracts by running:

```bash
npm run deploy-local
```

#### Sepolia

To deploy to the Sepolia testnet, run:

```bash
npm run deploy-sepolia
```
