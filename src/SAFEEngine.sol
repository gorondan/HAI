/// SAFEEngine.sol -- SAFE database

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.6.7;

contract SAFEEngine {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        require(contractEnabled == 1, "SAFEEngine/contract-not-enabled");
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        require(contractEnabled == 1, "SAFEEngine/contract-not-enabled");
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "SAFEEngine/account-not-authorized");
        _;
    }

    // Who can transfer collateral & debt in/out of a SAFE
    mapping(address => mapping (address => uint)) public safeRights;
    /**
     * @notice Allow an address to modify your SAFE
     * @param account Account to give SAFE permissions to
     */
    function approveSAFEModification(address account) external {
        safeRights[msg.sender][account] = 1;
        emit ApproveSAFEModification(msg.sender, account);
    }
    /**
     * @notice Deny an address the rights to modify your SAFE
     * @param account Account to give SAFE permissions to
     */
    function denySAFEModification(address account) external {
        safeRights[msg.sender][account] = 0;
        emit DenySAFEModification(msg.sender, account);
    }
    /**
    * @notice Checks whether msg.sender has the right to modify a SAFE
    **/
    function canModifySAFE(address safe, address account) public view returns (bool) {
        return either(safe == account, safeRights[safe][account] == 1);
    }

    // --- Data ---
    struct CollateralType {
        // Total debt issued for this specific collateral type
        uint256 debtAmount;        // [wad]
        // Accumulator for interest accrued on this collateral type
        uint256 accumulatedRate;   // [ray]
        // Floor price at which a SAFE is allowed to generate debt
        uint256 safetyPrice;       // [ray]
        // Maximum amount of debt that can be generated with this collateral type
        uint256 debtCeiling;       // [rad]
        // Minimum amount of debt that must be generated by a SAFE using this collateral
        uint256 debtFloor;         // [rad]
        // Price at which a SAFE gets liquidated
        uint256 liquidationPrice;  // [ray]
    }
    struct SAFE {
        // Total amount of collateral locked in a SAFE
        uint256 lockedCollateral;  // [wad]
        // Total amount of debt generated by a SAFE
        uint256 generatedDebt;     // [wad]
    }

    // Data about each collateral type
    mapping (bytes32 => CollateralType)             public collateralTypes;
    // Data about each SAFE
    mapping (bytes32 => mapping (address => SAFE )) public safes;
    // Balance of each collateral type
    mapping (bytes32 => mapping (address => uint))  public tokenCollateral;  // [wad]
    // Internal balance of system coins
    mapping (address => uint)                       public coinBalance;      // [rad]
    // Amount of debt held by an account. Coins & debt are like matter and antimatter. They nullify each other
    mapping (address => uint)                       public debtBalance;      // [rad]

    // Total amount of debt that a single safe can generate
    uint256 public safeDebtCeiling;      // [wad]
    // Total amount of debt (coins) currently issued
    uint256  public globalDebt;          // [rad]
    // 'Bad' debt that's not covered by collateral
    uint256  public globalUnbackedDebt;  // [rad]
    // Maximum amount of debt that can be issued
    uint256  public globalDebtCeiling;   // [rad]
    // Access flag, indicates whether this contract is still active
    uint256  public contractEnabled;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ApproveSAFEModification(address sender, address account);
    event DenySAFEModification(address sender, address account);
    event InitializeCollateralType(bytes32 collateralType);
    event ModifyParameters(bytes32 parameter, uint data);
    event ModifyParameters(bytes32 collateralType, bytes32 parameter, uint data);
    event DisableContract();
    event ModifyCollateralBalance(bytes32 collateralType, address account, int256 wad);
    event TransferCollateral(bytes32 collateralType, address src, address dst, uint256 wad);
    event TransferInternalCoins(address src, address dst, uint256 rad);
    event ModifySAFECollateralization(
        bytes32 collateralType,
        address safe,
        address collateralSource,
        address debtDestination,
        int deltaCollateral,
        int deltaDebt,
        uint lockedCollateral,
        uint generatedDebt,
        uint globalDebt
    );
    event TransferSAFECollateralAndDebt(
        bytes32 collateralType,
        address src,
        address dst,
        int deltaCollateral,
        int deltaDebt,
        uint srcLockedCollateral,
        uint srcGeneratedDebt,
        uint dstLockedCollateral,
        uint dstGeneratedDebt
    );
    event ConfiscateSAFECollateralAndDebt(
        bytes32 collateralType,
        address safe,
        address collateralCounterparty,
        address debtCounterparty,
        int deltaCollateral,
        int deltaDebt,
        uint globalUnbackedDebt
    );
    event SettleDebt(address account, uint rad, uint debtBalance, uint coinBalance, uint globalUnbackedDebt, uint globalDebt);
    event CreateUnbackedDebt(
        address debtDestination,
        address coinDestination,
        uint rad,
        uint debtDstBalance,
        uint coinDstBalance,
        uint globalUnbackedDebt,
        uint globalDebt
    );
    event UpdateAccumulatedRate(
        bytes32 collateralType,
        address surplusDst,
        int rateMultiplier,
        uint dstCoinBalance,
        uint globalDebt
    );

    // --- Init ---
    constructor() public {
        authorizedAccounts[msg.sender] = 1;
        safeDebtCeiling = uint(-1);
        contractEnabled = 1;
        emit AddAuthorization(msg.sender);
        emit ModifyParameters("safeDebtCeiling", uint(-1));
    }

    // --- Math ---
    function addition(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function addition(int x, int y) internal pure returns (int z) {
        z = x + y;
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function subtract(uint x, int y) internal pure returns (uint z) {
        z = x - uint(y);
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function subtract(int x, int y) internal pure returns (int z) {
        z = x - y;
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function multiply(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }
    function addition(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function subtract(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---

    /**
     * @notice Creates a brand new collateral type
     * @param collateralType Collateral type name (e.g ETH-A, TBTC-B)
     */
    function initializeCollateralType(bytes32 collateralType) external isAuthorized {
        require(collateralTypes[collateralType].accumulatedRate == 0, "SAFEEngine/collateral-type-already-exists");
        collateralTypes[collateralType].accumulatedRate = 10 ** 27;
        emit InitializeCollateralType(collateralType);
    }
    /**
     * @notice Modify general uint params
     * @param parameter The name of the parameter modified
     * @param data New value for the parameter
     */
    function modifyParameters(bytes32 parameter, uint data) external isAuthorized {
        require(contractEnabled == 1, "SAFEEngine/contract-not-enabled");
        if (parameter == "globalDebtCeiling") globalDebtCeiling = data;
        else if (parameter == "safeDebtCeiling") safeDebtCeiling = data;
        else revert("SAFEEngine/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /**
     * @notice Modify collateral specific params
     * @param collateralType Collateral type we modify params for
     * @param parameter The name of the parameter modified
     * @param data New value for the parameter
     */
    function modifyParameters(
        bytes32 collateralType,
        bytes32 parameter,
        uint data
    ) external isAuthorized {
        require(contractEnabled == 1, "SAFEEngine/contract-not-enabled");
        if (parameter == "safetyPrice") collateralTypes[collateralType].safetyPrice = data;
        else if (parameter == "liquidationPrice") collateralTypes[collateralType].liquidationPrice = data;
        else if (parameter == "debtCeiling") collateralTypes[collateralType].debtCeiling = data;
        else if (parameter == "debtFloor") collateralTypes[collateralType].debtFloor = data;
        else revert("SAFEEngine/modify-unrecognized-param");
        emit ModifyParameters(collateralType, parameter, data);
    }
    /**
     * @notice Disable this contract (normally called by GlobalSettlement)
     */
    function disableContract() external isAuthorized {
        contractEnabled = 0;
        emit DisableContract();
    }

    // --- Fungibility ---
    /**
     * @notice Join/exit collateral into and and out of the system
     * @param collateralType Collateral type we join/exit
     * @param account Account that gets credited/debited
     * @param wad Amount of collateral
     */
    function modifyCollateralBalance(
        bytes32 collateralType,
        address account,
        int256 wad
    ) external isAuthorized {
        tokenCollateral[collateralType][account] = addition(tokenCollateral[collateralType][account], wad);
        emit ModifyCollateralBalance(collateralType, account, wad);
    }
    /**
     * @notice Transfer collateral between accounts
     * @param collateralType Collateral type transferred
     * @param src Collateral source
     * @param dst Collateral destination
     * @param wad Amount of collateral transferred
     */
    function transferCollateral(
        bytes32 collateralType,
        address src,
        address dst,
        uint256 wad
    ) external {
        require(canModifySAFE(src, msg.sender), "SAFEEngine/not-allowed");
        tokenCollateral[collateralType][src] = subtract(tokenCollateral[collateralType][src], wad);
        tokenCollateral[collateralType][dst] = addition(tokenCollateral[collateralType][dst], wad);
        emit TransferCollateral(collateralType, src, dst, wad);
    }
    /**
     * @notice Transfer internal coins (does not affect external balances from Coin.sol)
     * @param src Coins source
     * @param dst Coins destination
     * @param rad Amount of coins transferred
     */
    function transferInternalCoins(address src, address dst, uint256 rad) external {
        require(canModifySAFE(src, msg.sender), "SAFEEngine/not-allowed");
        coinBalance[src] = subtract(coinBalance[src], rad);
        coinBalance[dst] = addition(coinBalance[dst], rad);
        emit TransferInternalCoins(src, dst, rad);
    }

    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- SAFE Manipulation ---
    /**
     * @notice Add/remove collateral or put back/generate more debt in a SAFE
     * @param collateralType Type of collateral to withdraw/deposit in and from the SAFE
     * @param safe Target SAFE
     * @param collateralSource Account we take collateral from/put collateral into
     * @param debtDestination Account from which we credit/debit coins and debt
     * @param deltaCollateral Amount of collateral added/extract from the SAFE (wad)
     * @param deltaDebt Amount of debt to generate/repay (wad)
     */
    function modifySAFECollateralization(
        bytes32 collateralType,
        address safe,
        address collateralSource,
        address debtDestination,
        int deltaCollateral,
        int deltaDebt
    ) external {
        // system is live
        require(contractEnabled == 1, "SAFEEngine/contract-not-enabled");

        SAFE memory safeData = safes[collateralType][safe];
        CollateralType memory collateralTypeData = collateralTypes[collateralType];
        // collateral type has been initialised
        require(collateralTypeData.accumulatedRate != 0, "SAFEEngine/collateral-type-not-initialized");

        safeData.lockedCollateral      = addition(safeData.lockedCollateral, deltaCollateral);
        safeData.generatedDebt         = addition(safeData.generatedDebt, deltaDebt);
        collateralTypeData.debtAmount  = addition(collateralTypeData.debtAmount, deltaDebt);

        int deltaAdjustedDebt = multiply(collateralTypeData.accumulatedRate, deltaDebt);
        uint totalDebtIssued  = multiply(collateralTypeData.accumulatedRate, safeData.generatedDebt);
        globalDebt            = addition(globalDebt, deltaAdjustedDebt);

        // either debt has decreased, or debt ceilings are not exceeded
        require(
          either(
            deltaDebt <= 0,
            both(multiply(collateralTypeData.debtAmount, collateralTypeData.accumulatedRate) <= collateralTypeData.debtCeiling,
              globalDebt <= globalDebtCeiling)
            ),
          "SAFEEngine/ceiling-exceeded"
        );
        // safe is either less risky than before, or it is safe
        require(
          either(
            both(deltaDebt <= 0, deltaCollateral >= 0),
            totalDebtIssued <= multiply(safeData.lockedCollateral, collateralTypeData.safetyPrice)
          ),
          "SAFEEngine/not-safe"
        );

        // safe is either more safe, or the owner consents
        require(either(both(deltaDebt <= 0, deltaCollateral >= 0), canModifySAFE(safe, msg.sender)), "SAFEEngine/not-allowed-to-modify-safe");
        // collateral src consents
        require(either(deltaCollateral <= 0, canModifySAFE(collateralSource, msg.sender)), "SAFEEngine/not-allowed-collateral-src");
        // debt dst consents
        require(either(deltaDebt >= 0, canModifySAFE(debtDestination, msg.sender)), "SAFEEngine/not-allowed-debt-dst");

        // safe has no debt, or a non-dusty amount
        require(either(safeData.generatedDebt == 0, totalDebtIssued >= collateralTypeData.debtFloor), "SAFEEngine/dust");

        // safe didn't go above the safe debt limit
        if (deltaDebt > 0) {
          require(safeData.generatedDebt <= safeDebtCeiling, "SAFEEngine/above-debt-limit");
        }

        tokenCollateral[collateralType][collateralSource] =
          subtract(tokenCollateral[collateralType][collateralSource], deltaCollateral);

        coinBalance[debtDestination] = addition(coinBalance[debtDestination], deltaAdjustedDebt);

        safes[collateralType][safe] = safeData;
        collateralTypes[collateralType] = collateralTypeData;

        emit ModifySAFECollateralization(
            collateralType,
            safe,
            collateralSource,
            debtDestination,
            deltaCollateral,
            deltaDebt,
            safeData.lockedCollateral,
            safeData.generatedDebt,
            globalDebt
        );
    }

    // --- SAFE Fungibility ---
    /**
     * @notice Transfer collateral and/or debt between SAFEs
     * @param collateralType Collateral type transferred between SAFEs
     * @param src Source SAFE
     * @param dst Destination SAFE
     * @param deltaCollateral Amount of collateral to take/add into src and give/take from dst (wad)
     * @param deltaDebt Amount of debt to take/add into src and give/take from dst (wad)
     */
    function transferSAFECollateralAndDebt(
        bytes32 collateralType,
        address src,
        address dst,
        int deltaCollateral,
        int deltaDebt
    ) external {
        SAFE storage srcSAFE = safes[collateralType][src];
        SAFE storage dstSAFE = safes[collateralType][dst];
        CollateralType storage collateralType_ = collateralTypes[collateralType];

        srcSAFE.lockedCollateral = subtract(srcSAFE.lockedCollateral, deltaCollateral);
        srcSAFE.generatedDebt    = subtract(srcSAFE.generatedDebt, deltaDebt);
        dstSAFE.lockedCollateral = addition(dstSAFE.lockedCollateral, deltaCollateral);
        dstSAFE.generatedDebt    = addition(dstSAFE.generatedDebt, deltaDebt);

        uint srcTotalDebtIssued = multiply(srcSAFE.generatedDebt, collateralType_.accumulatedRate);
        uint dstTotalDebtIssued = multiply(dstSAFE.generatedDebt, collateralType_.accumulatedRate);

        // both sides consent
        require(both(canModifySAFE(src, msg.sender), canModifySAFE(dst, msg.sender)), "SAFEEngine/not-allowed");

        // both sides safe
        require(srcTotalDebtIssued <= multiply(srcSAFE.lockedCollateral, collateralType_.safetyPrice), "SAFEEngine/not-safe-src");
        require(dstTotalDebtIssued <= multiply(dstSAFE.lockedCollateral, collateralType_.safetyPrice), "SAFEEngine/not-safe-dst");

        // both sides non-dusty
        require(either(srcTotalDebtIssued >= collateralType_.debtFloor, srcSAFE.generatedDebt == 0), "SAFEEngine/dust-src");
        require(either(dstTotalDebtIssued >= collateralType_.debtFloor, dstSAFE.generatedDebt == 0), "SAFEEngine/dust-dst");

        emit TransferSAFECollateralAndDebt(
            collateralType,
            src,
            dst,
            deltaCollateral,
            deltaDebt,
            srcSAFE.lockedCollateral,
            srcSAFE.generatedDebt,
            dstSAFE.lockedCollateral,
            dstSAFE.generatedDebt
        );
    }

    // --- SAFE Confiscation ---
    /**
     * @notice Normally used by the LiquidationEngine in order to confiscate collateral and
       debt from a SAFE and give them to someone else
     * @param collateralType Collateral type the SAFE has locked inside
     * @param safe Target SAFE
     * @param collateralCounterparty Who we take/give collateral to
     * @param debtCounterparty Who we take/give debt to
     * @param deltaCollateral Amount of collateral taken/added into the SAFE (wad)
     * @param deltaDebt Amount of collateral taken/added into the SAFE (wad)
     */
    function confiscateSAFECollateralAndDebt(
        bytes32 collateralType,
        address safe,
        address collateralCounterparty,
        address debtCounterparty,
        int deltaCollateral,
        int deltaDebt
    ) external isAuthorized {
        SAFE storage safe_ = safes[collateralType][safe];
        CollateralType storage collateralType_ = collateralTypes[collateralType];

        safe_.lockedCollateral = addition(safe_.lockedCollateral, deltaCollateral);
        safe_.generatedDebt = addition(safe_.generatedDebt, deltaDebt);
        collateralType_.debtAmount = addition(collateralType_.debtAmount, deltaDebt);

        int deltaTotalIssuedDebt = multiply(collateralType_.accumulatedRate, deltaDebt);

        tokenCollateral[collateralType][collateralCounterparty] = subtract(
          tokenCollateral[collateralType][collateralCounterparty],
          deltaCollateral
        );
        debtBalance[debtCounterparty] = subtract(
          debtBalance[debtCounterparty],
          deltaTotalIssuedDebt
        );
        globalUnbackedDebt = subtract(
          globalUnbackedDebt,
          deltaTotalIssuedDebt
        );

        emit ConfiscateSAFECollateralAndDebt(
            collateralType,
            safe,
            collateralCounterparty,
            debtCounterparty,
            deltaCollateral,
            deltaDebt,
            globalUnbackedDebt
        );
    }

    // --- Settlement ---
    /**
     * @notice Nullify an amount of coins with an equal amount of debt
     * @param rad Amount of debt & coins to destroy
     */
    function settleDebt(uint rad) external {
        address account       = msg.sender;
        debtBalance[account]  = subtract(debtBalance[account], rad);
        coinBalance[account]  = subtract(coinBalance[account], rad);
        globalUnbackedDebt    = subtract(globalUnbackedDebt, rad);
        globalDebt            = subtract(globalDebt, rad);
        emit SettleDebt(account, rad, debtBalance[account], coinBalance[account], globalUnbackedDebt, globalDebt);
    }
    /**
     * @notice Usually called by CoinSavingsAccount in order to create unbacked debt
     * @param debtDestination Usually AccountingEngine that can settle debt with surplus
     * @param coinDestination Usually CoinSavingsAccount that passes the new coins to depositors
     * @param rad Amount of debt to create
     */
    function createUnbackedDebt(
        address debtDestination,
        address coinDestination,
        uint rad
    ) external isAuthorized {
        debtBalance[debtDestination]  = addition(debtBalance[debtDestination], rad);
        coinBalance[coinDestination]  = addition(coinBalance[coinDestination], rad);
        globalUnbackedDebt            = addition(globalUnbackedDebt, rad);
        globalDebt                    = addition(globalDebt, rad);
        emit CreateUnbackedDebt(
            debtDestination,
            coinDestination,
            rad,
            debtBalance[debtDestination],
            coinBalance[coinDestination],
            globalUnbackedDebt,
            globalDebt
        );
    }

    // --- Rates ---
    /**
     * @notice Usually called by TaxCollector in order to accrue interest on a specific collateral type
     * @param collateralType Collateral type we accrue interest for
     * @param surplusDst Destination for amount of surplus created by applying the interest rate
       to debt created by SAFEs with 'collateralType'
     * @param rateMultiplier Multiplier applied to the debtAmount in order to calculate the surplus [ray]
     */
    function updateAccumulatedRate(
        bytes32 collateralType,
        address surplusDst,
        int rateMultiplier
    ) external isAuthorized {
        require(contractEnabled == 1, "SAFEEngine/contract-not-enabled");
        CollateralType storage collateralType_ = collateralTypes[collateralType];
        collateralType_.accumulatedRate        = addition(collateralType_.accumulatedRate, rateMultiplier);
        int deltaSurplus                       = multiply(collateralType_.debtAmount, rateMultiplier);
        coinBalance[surplusDst]                = addition(coinBalance[surplusDst], deltaSurplus);
        globalDebt                             = addition(globalDebt, deltaSurplus);
        emit UpdateAccumulatedRate(
            collateralType,
            surplusDst,
            rateMultiplier,
            coinBalance[surplusDst],
            globalDebt
        );
    }
}
