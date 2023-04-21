// SPDX-License-Identifier: GPL-3.0
/// StabilityFeeTreasury.sol

// Copyright (C) 2018 Rain <rainbreak@riseup.net>, 2020 Reflexer Labs, INC

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity 0.8.19;

import {ISAFEEngine as SAFEEngineLike} from '@interfaces/ISAFEEngine.sol';
import {ISystemCoin as SystemCoinLike} from '@interfaces/external/ISystemCoin.sol';
import {ICoinJoin as CoinJoinLike} from '@interfaces/ICoinJoin.sol';

import {Authorizable} from '@contracts/utils/Authorizable.sol';

import {Math, RAY, HUNDRED} from '@libraries/Math.sol';

contract StabilityFeeTreasury is Authorizable {
  // --- Events ---
  event ModifyParameters(bytes32 parameter, address addr);
  event ModifyParameters(bytes32 parameter, uint256 val);
  event DisableContract();
  event SetTotalAllowance(address indexed account, uint256 rad);
  event SetPerBlockAllowance(address indexed account, uint256 rad);
  event GiveFunds(address indexed account, uint256 rad, uint256 expensesAccumulator);
  event TakeFunds(address indexed account, uint256 rad);
  event PullFunds(
    address indexed sender, address indexed dstAccount, address token, uint256 rad, uint256 expensesAccumulator
  );
  event TransferSurplusFunds(address extraSurplusReceiver, uint256 fundsToTransfer);

  // --- Structs ---
  struct Allowance {
    uint256 total;
    uint256 perBlock;
  }

  // Mapping of total and per block allowances
  mapping(address => Allowance) private allowance;
  // Mapping that keeps track of how much surplus an authorized address has pulled each block
  mapping(address => mapping(uint256 => uint256)) public pulledPerBlock;

  SAFEEngineLike public safeEngine;
  SystemCoinLike public systemCoin;
  CoinJoinLike public coinJoin;

  // The address that receives any extra surplus which is not used by the treasury
  address public extraSurplusReceiver;

  uint256 public treasuryCapacity; // max amount of SF that can be kept in the treasury                        [rad]
  uint256 public minimumFundsRequired; // minimum amount of SF that must be kept in the treasury at all times      [rad]
  uint256 public expensesMultiplier; // multiplier for expenses                                                  [hundred]
  uint256 public surplusTransferDelay; // minimum time between transferSurplusFunds calls                          [seconds]
  uint256 public expensesAccumulator; // expenses accumulator                                                     [rad]
  uint256 public accumulatorTag; // latest tagged accumulator price                                          [rad]
  uint256 public pullFundsMinThreshold; // minimum funds that must be in the treasury so that someone can pullFunds [rad]
  uint256 public latestSurplusTransferTime; // latest timestamp when transferSurplusFunds was called                    [seconds]
  uint256 public contractEnabled;

  modifier accountNotTreasury(address account) {
    require(account != address(this), 'StabilityFeeTreasury/account-cannot-be-treasury');
    _;
  }

  constructor(address _safeEngine, address _extraSurplusReceiver, address _coinJoin) {
    require(address(CoinJoinLike(_coinJoin).systemCoin()) != address(0), 'StabilityFeeTreasury/null-system-coin');
    require(_extraSurplusReceiver != address(0), 'StabilityFeeTreasury/null-surplus-receiver');

    _addAuthorization(msg.sender);

    safeEngine = SAFEEngineLike(_safeEngine);
    extraSurplusReceiver = _extraSurplusReceiver;
    coinJoin = CoinJoinLike(_coinJoin);
    systemCoin = SystemCoinLike(coinJoin.systemCoin());
    latestSurplusTransferTime = block.timestamp;
    expensesMultiplier = HUNDRED;
    contractEnabled = 1;

    systemCoin.approve(address(coinJoin), type(uint256).max);

    emit AddAuthorization(msg.sender);
  }

  // --- Administration ---
  /**
   * @notice Modify address parameters
   * @param parameter The name of the contract whose address will be changed
   * @param addr New address for the contract
   */
  function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
    require(contractEnabled == 1, 'StabilityFeeTreasury/contract-not-enabled');
    require(addr != address(0), 'StabilityFeeTreasury/null-addr');
    if (parameter == 'extraSurplusReceiver') {
      require(addr != address(this), 'StabilityFeeTreasury/accounting-engine-cannot-be-treasury');
      extraSurplusReceiver = addr;
    } else {
      revert('StabilityFeeTreasury/modify-unrecognized-param');
    }
    emit ModifyParameters(parameter, addr);
  }

  /**
   * @notice Modify uint256 parameters
   * @param parameter The name of the parameter to modify
   * @param val New parameter value
   */
  function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
    require(contractEnabled == 1, 'StabilityFeeTreasury/not-live');
    if (parameter == 'expensesMultiplier') {
      expensesMultiplier = val;
    } else if (parameter == 'treasuryCapacity') {
      require(val >= minimumFundsRequired, 'StabilityFeeTreasury/capacity-lower-than-min-funds');
      treasuryCapacity = val;
    } else if (parameter == 'minimumFundsRequired') {
      require(val <= treasuryCapacity, 'StabilityFeeTreasury/min-funds-higher-than-capacity');
      minimumFundsRequired = val;
    } else if (parameter == 'pullFundsMinThreshold') {
      pullFundsMinThreshold = val;
    } else if (parameter == 'surplusTransferDelay') {
      surplusTransferDelay = val;
    } else {
      revert('StabilityFeeTreasury/modify-unrecognized-param');
    }
    emit ModifyParameters(parameter, val);
  }

  /**
   * @notice Disable this contract (normally called by GlobalSettlement)
   */
  function disableContract() external isAuthorized {
    require(contractEnabled == 1, 'StabilityFeeTreasury/already-disabled');
    contractEnabled = 0;
    joinAllCoins();
    safeEngine.transferInternalCoins(address(this), extraSurplusReceiver, safeEngine.coinBalance(address(this)));
    emit DisableContract();
  }

  /**
   * @notice Join all ERC20 system coins that the treasury has inside the SAFEEngine
   */
  function joinAllCoins() internal {
    if (systemCoin.balanceOf(address(this)) > 0) {
      coinJoin.join(address(this), systemCoin.balanceOf(address(this)));
    }
  }

  /**
   * @notice Settle as much bad debt as possible (if this contract has any)
   */
  function settleDebt() public {
    uint256 coinBalanceSelf = safeEngine.coinBalance(address(this));
    uint256 debtBalanceSelf = safeEngine.debtBalance(address(this));

    if (debtBalanceSelf > 0) {
      safeEngine.settleDebt(Math.min(coinBalanceSelf, debtBalanceSelf));
    }
  }

  // --- Getters ---
  /**
   * @notice Returns the total and per block allowances for a specific address
   * @param account The address to return the allowances for
   */
  function getAllowance(address account) public view returns (uint256, uint256) {
    return (allowance[account].total, allowance[account].perBlock);
  }

  // --- SF Transfer Allowance ---
  /**
   * @notice Modify an address' total allowance in order to withdraw SF from the treasury
   * @param account The approved address
   * @param rad The total approved amount of SF to withdraw (number with 45 decimals)
   */
  function setTotalAllowance(address account, uint256 rad) external isAuthorized accountNotTreasury(account) {
    require(account != address(0), 'StabilityFeeTreasury/null-account');
    allowance[account].total = rad;
    emit SetTotalAllowance(account, rad);
  }

  /**
   * @notice Modify an address' per block allowance in order to withdraw SF from the treasury
   * @param account The approved address
   * @param rad The per block approved amount of SF to withdraw (number with 45 decimals)
   */
  function setPerBlockAllowance(address account, uint256 rad) external isAuthorized accountNotTreasury(account) {
    require(account != address(0), 'StabilityFeeTreasury/null-account');
    allowance[account].perBlock = rad;
    emit SetPerBlockAllowance(account, rad);
  }

  // --- Stability Fee Transfer (Governance) ---
  /**
   * @notice Governance transfers SF to an address
   * @param account Address to transfer SF to
   * @param rad Amount of internal system coins to transfer (a number with 45 decimals)
   */
  function giveFunds(address account, uint256 rad) external isAuthorized accountNotTreasury(account) {
    require(account != address(0), 'StabilityFeeTreasury/null-account');

    joinAllCoins();
    settleDebt();

    require(safeEngine.debtBalance(address(this)) == 0, 'StabilityFeeTreasury/outstanding-bad-debt');
    require(safeEngine.coinBalance(address(this)) >= rad, 'StabilityFeeTreasury/not-enough-funds');

    if (account != extraSurplusReceiver) {
      expensesAccumulator = expensesAccumulator + rad;
    }

    safeEngine.transferInternalCoins(address(this), account, rad);
    emit GiveFunds(account, rad, expensesAccumulator);
  }

  /**
   * @notice Governance takes funds from an address
   * @param account Address to take system coins from
   * @param rad Amount of internal system coins to take from the account (a number with 45 decimals)
   */
  function takeFunds(address account, uint256 rad) external isAuthorized accountNotTreasury(account) {
    safeEngine.transferInternalCoins(account, address(this), rad);
    emit TakeFunds(account, rad);
  }

  // --- Stability Fee Transfer (Approved Accounts) ---
  /**
   * @notice Pull stability fees from the treasury (if your allowance permits)
   * @param dstAccount Address to transfer funds to
   * @param token Address of the token to transfer (in this case it must be the address of the ERC20 system coin).
   *              Used only to adhere to a standard for automated, on-chain treasuries
   * @param wad Amount of system coins (SF) to transfer (expressed as an 18 decimal number but the contract will transfer
   *             internal system coins that have 45 decimals)
   */
  function pullFunds(address dstAccount, address token, uint256 wad) external {
    if (dstAccount == address(this)) return;
    require(allowance[msg.sender].total >= wad * RAY, 'StabilityFeeTreasury/not-allowed');
    require(dstAccount != address(0), 'StabilityFeeTreasury/null-dst');
    require(dstAccount != extraSurplusReceiver, 'StabilityFeeTreasury/dst-cannot-be-accounting');
    require(wad > 0, 'StabilityFeeTreasury/null-transfer-amount');
    require(token == address(systemCoin), 'StabilityFeeTreasury/token-unavailable');
    if (allowance[msg.sender].perBlock > 0) {
      require(
        pulledPerBlock[msg.sender][block.number] + (wad * RAY) <= allowance[msg.sender].perBlock,
        'StabilityFeeTreasury/per-block-limit-exceeded'
      );
    }

    pulledPerBlock[msg.sender][block.number] = pulledPerBlock[msg.sender][block.number] + (wad * RAY);

    joinAllCoins();
    settleDebt();

    require(safeEngine.debtBalance(address(this)) == 0, 'StabilityFeeTreasury/outstanding-bad-debt');
    require(safeEngine.coinBalance(address(this)) >= wad * RAY, 'StabilityFeeTreasury/not-enough-funds');
    require(
      safeEngine.coinBalance(address(this)) >= pullFundsMinThreshold,
      'StabilityFeeTreasury/below-pullFunds-min-threshold'
    );

    // Update allowance and accumulator
    allowance[msg.sender].total = allowance[msg.sender].total - (wad * RAY);
    expensesAccumulator = expensesAccumulator + (wad * RAY);

    // Transfer money
    safeEngine.transferInternalCoins(address(this), dstAccount, wad * RAY);

    emit PullFunds(msg.sender, dstAccount, token, wad * RAY, expensesAccumulator);
  }

  // --- Treasury Maintenance ---
  /**
   * @notice Transfer surplus stability fees to the extraSurplusReceiver. This is here to make sure that the treasury
   *              doesn't accumulate fees that it doesn't even need in order to pay for allowances. It ensures
   *              that there are enough funds left in the treasury to account for projected expenses (latest expenses multiplied
   *              by an expense multiplier)
   */
  function transferSurplusFunds() external {
    require(
      block.timestamp >= latestSurplusTransferTime + surplusTransferDelay,
      'StabilityFeeTreasury/transfer-cooldown-not-passed'
    );
    // Compute latest expenses
    uint256 latestExpenses = expensesAccumulator - accumulatorTag;
    // Check if we need to keep more funds than the total capacity
    uint256 remainingFunds = (treasuryCapacity <= expensesMultiplier * latestExpenses / HUNDRED)
      ? expensesMultiplier * latestExpenses / HUNDRED
      : treasuryCapacity;
    // Make sure to keep at least minimum funds
    remainingFunds =
      (expensesMultiplier * latestExpenses / HUNDRED <= minimumFundsRequired) ? minimumFundsRequired : remainingFunds;
    // Set internal vars
    accumulatorTag = expensesAccumulator;
    latestSurplusTransferTime = block.timestamp;
    // Join all coins in system
    joinAllCoins();
    // Settle outstanding bad debt
    settleDebt();
    // Check that there's no bad debt left
    require(safeEngine.debtBalance(address(this)) == 0, 'StabilityFeeTreasury/outstanding-bad-debt');
    // Check if we have too much money
    if (safeEngine.coinBalance(address(this)) > remainingFunds) {
      // Make sure that we still keep min SF in treasury
      uint256 fundsToTransfer = safeEngine.coinBalance(address(this)) - remainingFunds;
      // Transfer surplus to accounting engine
      safeEngine.transferInternalCoins(address(this), extraSurplusReceiver, fundsToTransfer);
      // Emit event
      emit TransferSurplusFunds(extraSurplusReceiver, fundsToTransfer);
    }
  }
}