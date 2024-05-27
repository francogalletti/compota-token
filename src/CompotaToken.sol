// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { Owned } from "solmate/auth/Owned.sol";
import { ERC20Extended } from "@mzero-labs/ERC20Extended.sol";
import { IERC20 } from "@mzero-labs/interfaces/IERC20.sol";
import { ICompotaToken } from "./intefaces/ICompotaToken.sol";

/**
 * @title CompotaToken
 * @dev ERC20 token that accrues interest over time.
 */
contract CompotaToken is ICompotaToken, ERC20Extended, Owned {
    /* ============ Variables ============ */

    /// @notice Scale factor used to convert basis points (bps) into decimal fractions.
    uint16 internal constant SCALE_FACTOR = 10_000; // Ex, 100 bps (1%) is converted to 0.01 by dividing by 10,000

    /// @notice The number of seconds in a year.
    uint32 internal constant SECONDS_PER_YEAR = 31_536_000;

    /// @notice The minimum yearly rate of interest in basis points (bps).
    uint16 public constant MIN_YEARLY_RATE = 100; // This represents a 1% annual percentage yield (APY).

    /// @notice The maximum yearly rate of interest in basis points (bps).
    uint16 public constant MAX_YEARLY_RATE = 4_000; // This represents a 40% annual percentage yield (APY).

    uint16 public yearlyRate;

    uint256 internal _totalSupply;
    address[] internal _earners;

    mapping(address => uint256) internal _balances;
    mapping(address => uint256) internal _lastUpdateTimestamp;

    /* ============ Constructor ============ */

    constructor(uint16 yearlyRate_) ERC20Extended("Compota Token", "COMPOTA", 6) Owned(msg.sender) {
        setYearlyRate(yearlyRate_);
    }

    /* ============ Interactive Functions ============ */

    /**
     * @notice Sets the yearly rate of interest.
     * @dev Only the owner can call this function. The new rate must be between
     *      `MIN_YEARLY_RATE` (1% APY) and `MAX_YEARLY_RATE` (40% APY).
     * @param newRate_ The new interest rate in basis points (BPS).
     */
    function setYearlyRate(uint16 newRate_) public onlyOwner {
        if (newRate_ < MIN_YEARLY_RATE || newRate_ > MAX_YEARLY_RATE) {
            revert InvalidYearlyRate(newRate_);
        }
        uint16 oldYearlyRate = yearlyRate;
        yearlyRate = newRate_;
        emit YearlyRateUpdated(oldYearlyRate, newRate_);
    }

    /**
     * @notice Mints new tokens to a specified address.
     * @dev Only the owner can call this function.
     * @param to_ The address where the new tokens will be sent.
     * @param amount_ The number of tokens to mint.
     */
    function mint(address to_, uint256 amount_) external onlyOwner {
        _revertIfInvalidRecipient(to_);
        _revertIfInsufficientAmount(amount_);
        _updateRewards(to_);
        _mint(to_, amount_);
    }

    /**
     * @notice Burns tokens from the sender account.
     * @param amount_ The number of tokens to burn.
     */
    function burn(uint256 amount_) external {
        _revertIfInsufficientAmount(amount_);
        address caller = msg.sender;
        _updateRewards(caller);
        _revertIfInsufficientBalance(msg.sender, amount_);
        _burn(caller, amount_);
    }

    /**
     * @notice Gets the total balance of an account, including accrued rewards.
     * @param account_ The address of the account to query the balance of.
     * @return The total balance of the account.
     * @inheritdoc IERC20
     */
    function balanceOf(address account_) external view override returns (uint256) {
        return _balances[account_] + _calculateCurrentRewards(account_);
    }

    /**
     * @notice Retrieves the total supply of tokens, including unclaimed rewards.
     * @return totalSupply_ The total supply of tokens, including unclaimed rewards.
     * @inheritdoc IERC20
     */
    function totalSupply() external view returns (uint256 totalSupply_) {
        totalSupply_ = _totalSupply;
        uint256 length = _earners.length;
        for (uint256 i = 0; i < length; i++) {
            totalSupply_ += _calculateCurrentRewards(_earners[i]);
        }
        return totalSupply_;
    }

    /**
     * @notice Claims the accumulated rewards for the sender.
     * @dev It can only be called by the owner of the rewards.
     */
    function claimRewards() external {
        _updateRewards(msg.sender);
    }

    /* ============ Internal Interactive Functions ============ */

    /**
     * @notice Transfers tokens between accounts
     * @param sender_ The address of the account from which tokens will be transferred.
     * @param recipient_ The address of the account to which tokens will be transferred.
     * @param amount_ The amount of tokens to be transferred.
     */
    function _transfer(address sender_, address recipient_, uint256 amount_) internal override {
        _revertIfInvalidRecipient(recipient_);

        // Update rewards for both sender and recipient
        _updateRewards(sender_);
        _updateRewards(recipient_);

        _balances[sender_] -= amount_;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            _balances[recipient_] += amount_;
        }

        emit Transfer(sender_, recipient_, amount_);
    }

    /**
     * @notice Mints new tokens and assigns them to the specified account.
     * @param to_ The address of the account receiving the newly minted tokens.
     * @param amount_ The amount of tokens to mint.
     */
    function _mint(address to_, uint256 amount_) internal virtual {
        _totalSupply += amount_;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            _balances[to_] += amount_;
        }

        emit Transfer(address(0), to_, amount_);
    }

    /**
     * @notice Burns tokens from the specified account.
     * @param from_ The address of the account from which tokens will be burned.
     * @param amount_ The amount of tokens to burn.
     */
    function _burn(address from_, uint256 amount_) internal virtual {
        _balances[from_] -= amount_;

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            _totalSupply -= amount_;
        }

        emit Transfer(from_, address(0), amount_);
    }

    /**
     * @notice Updates the accrued rewards for the specified account.
     * @param account_ The address of the account for which rewards will be updated.
     */
    function _updateRewards(address account_) internal {
        uint256 timestamp = block.timestamp;
        if (_lastUpdateTimestamp[account_] == 0) {
            _lastUpdateTimestamp[account_] = timestamp;
            _earners.push(account_);
            emit StartedEarningRewards(account_);
            return;
        }

        uint256 rewards = _calculateCurrentRewards(account_);
        if (rewards > 0) {
            _mint(account_, rewards);
        }
        _lastUpdateTimestamp[account_] = timestamp;
    }

    /**
     * @notice Calculates the current accrued rewards for a specific account since the last update.
     * @param account_ The address of the account for which rewards will be calculated.
     * @return The amount of rewards accrued since the last update.
     */
    function _calculateCurrentRewards(address account_) internal view returns (uint256) {
        if (_lastUpdateTimestamp[account_] == 0) return 0;
        uint256 timeElapsed;
        // Safe to use unchecked here, since `block.timestamp` is always greater than `_lastUpdateTimestamp[account_]`.
        unchecked {
            timeElapsed = block.timestamp - _lastUpdateTimestamp[account_];
        }
        return (_balances[account_] * timeElapsed * yearlyRate) / (SCALE_FACTOR * uint256(SECONDS_PER_YEAR));
    }

    /**
     * @dev Reverts if the balance is insufficient.
     * @param caller_ Caller
     * @param amount_ Balance to check.
     */
    function _revertIfInsufficientBalance(address caller_, uint256 amount_) internal view {
        uint256 balance = _balances[caller_];
        if (balance < amount_) revert InsufficientBalance(amount_);
    }

    /**
     * @dev Reverts if the amount of a `mint` or `burn` is equal to 0.
     * @param amount_ Amount to check.
     */
    function _revertIfInsufficientAmount(uint256 amount_) internal pure {
        if (amount_ == 0) revert InsufficientAmount(amount_);
    }

    /**
     * @dev Reverts if the recipient of a `mint` or `transfer` is address(0).
     * @param recipient_ Address of the recipient to check.
     */
    function _revertIfInvalidRecipient(address recipient_) internal pure {
        if (recipient_ == address(0)) revert InvalidRecipient(recipient_);
    }
}