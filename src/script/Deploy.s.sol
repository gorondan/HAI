// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import 'forge-std/Script.sol';
import '@script/Contracts.s.sol';
import '@script/Params.s.sol';

contract Deploy is Script, Contracts {
  uint256 public chainId;
  address public deployer;
  uint256 internal _deployerPk = 69; // for tests

  function run() public {
    vm.startBroadcast(_deployerPk);
    deployer = vm.addr(_deployerPk);

    _deployAndSetup(
      GlobalParams({
        initialDebtAuctionMintedTokens: INITIAL_DEBT_AUCTION_MINTED_TOKENS,
        bidAuctionSize: BID_AUCTION_SIZE,
        surplusAuctionAmountToSell: SURPLUS_AUCTION_SIZE,
        globalDebtCeiling: GLOBAL_DEBT_CEILING,
        globalStabilityFee: GLOBAL_STABILITY_FEE,
        surplusAuctionBidReceiver: SURPLUS_AUCTION_BID_RECEIVER
      })
    );

    deployETHCollateral(
      CollateralParams({
        name: ETH_A,
        liquidationPenalty: ETH_A_LIQUIDATION_PENALTY,
        liquidationQuantity: ETH_A_LIQUIDATION_QUANTITY,
        debtCeiling: ETH_A_DEBT_CEILING,
        safetyCRatio: ETH_A_SAFETY_C_RATIO,
        liquidationRatio: ETH_A_LIQUIDATION_RATIO,
        stabilityFee: ETH_A_STABILITY_FEE
      }),
      TEST_ETH_PRICE
    );

    deployTokenCollateral(
      CollateralParams({
        name: TKN,
        liquidationPenalty: TKN_LIQUIDATION_PENALTY,
        liquidationQuantity: TKN_LIQUIDATION_QUANTITY,
        debtCeiling: TKN_DEBT_CEILING,
        safetyCRatio: TKN_SAFETY_C_RATIO,
        liquidationRatio: TKN_LIQUIDATION_RATIO,
        stabilityFee: TKN_STABILITY_FEE
      }),
      TEST_TKN_PRICE
    );

    vm.stopBroadcast();
  }

  function deployETHCollateral(CollateralParams memory _params, uint256 _initialPrice) public {
    // deploy oracle for test
    oracle[ETH_A] = new OracleForTest();
    oracle[ETH_A].setPriceAndValidity(_initialPrice, true);

    // deploy ETHJoin and CollateralAuctionHouse
    ethJoin = new ETHJoin(address(safeEngine), ETH_A);
    collateralAuctionHouse[ETH_A] = new CollateralAuctionHouse({
        _safeEngine: address(safeEngine), 
        _liquidationEngine: address(liquidationEngine), 
        _collateralType: ETH_A
        });

    // add ETHJoin to safeEngine
    safeEngine.addAuthorization(address(ethJoin));

    _setupCollateral(_params, address(oracle[ETH_A]));
  }

  function deployTokenCollateral(CollateralParams memory _params, uint256 _initialPrice) public {
    // deploy oracle for test
    oracle[_params.name] = new OracleForTest();
    oracle[_params.name].setPriceAndValidity(_initialPrice, true);

    // deploy Collateral, CollateralJoin and CollateralAuctionHouse
    collateral[_params.name] = new ERC20ForTest(); // TODO: replace for token
    collateralJoin[_params.name] = new CollateralJoin({
        _safeEngine: address(safeEngine), 
        _collateralType: _params.name, 
        _collateral: address(collateral[_params.name])
        });
    collateralAuctionHouse[_params.name] = new CollateralAuctionHouse({
        _safeEngine: address(safeEngine), 
        _liquidationEngine: address(liquidationEngine), 
        _collateralType: _params.name
        });

    // add CollateralJoin to safeEngine
    safeEngine.addAuthorization(address(collateralJoin[_params.name]));

    _setupCollateral(_params, address(oracle[_params.name]));
  }

  function revoke() public {
    vm.startBroadcast(deployer);

    // base contracts
    safeEngine.removeAuthorization(deployer);
    liquidationEngine.removeAuthorization(deployer);
    accountingEngine.removeAuthorization(deployer);
    oracleRelayer.removeAuthorization(deployer);

    // tax
    taxCollector.removeAuthorization(deployer);
    stabilityFeeTreasury.removeAuthorization(deployer);

    // tokens
    coin.removeAuthorization(deployer);
    protocolToken.removeAuthorization(deployer);

    // token adapters
    coinJoin.removeAuthorization(deployer);
    ethJoin.removeAuthorization(deployer);
    collateralJoin[TKN].removeAuthorization(deployer);

    // auction houses
    surplusAuctionHouse.removeAuthorization(deployer);
    debtAuctionHouse.removeAuthorization(deployer);

    // collateral auction houses
    collateralAuctionHouse[ETH_A].removeAuthorization(deployer);
    collateralAuctionHouse[TKN].removeAuthorization(deployer);

    vm.stopBroadcast();
  }

  function _deployAndSetup(GlobalParams memory _params) internal {
    // deploy Tokens
    coin = new Coin('HAI Index Token', 'HAI', chainId);
    protocolToken = new Coin('Protocol Token', 'GOV', chainId);

    // deploy Base contracts
    safeEngine = new SAFEEngine();
    oracleRelayer = new OracleRelayer(address(safeEngine));
    taxCollector = new TaxCollector(address(safeEngine));
    liquidationEngine = new LiquidationEngine(address(safeEngine));

    coinJoin = new CoinJoin(address(safeEngine), address(coin));
    surplusAuctionHouse = new MixedStratSurplusAuctionHouse(address(safeEngine), address(protocolToken));
    debtAuctionHouse = new DebtAuctionHouse(address(safeEngine), address(protocolToken));

    accountingEngine =
      new AccountingEngine(address(safeEngine), address(surplusAuctionHouse), address(debtAuctionHouse));

    stabilityFeeTreasury = new StabilityFeeTreasury(
          address(safeEngine),
          address(accountingEngine),
          address(coinJoin)
        );

    // TODO: deploy ESM, GlobalSettlement, SettlementSurplusAuctioneer

    globalSettlement = new GlobalSettlement();

    // setup registry
    debtAuctionHouse.modifyParameters('accountingEngine', address(accountingEngine));
    taxCollector.modifyParameters('primaryTaxReceiver', address(accountingEngine));
    liquidationEngine.modifyParameters('accountingEngine', address(accountingEngine));
    accountingEngine.modifyParameters('protocolTokenAuthority', address(protocolToken));

    // auth
    safeEngine.addAuthorization(address(oracleRelayer)); // modifyParameters
    safeEngine.addAuthorization(address(coinJoin)); // transferInternalCoins
    safeEngine.addAuthorization(address(taxCollector)); // updateAccumulatedRate
    safeEngine.addAuthorization(address(debtAuctionHouse)); // transferInternalCoins [createUnbackedDebt]
    safeEngine.addAuthorization(address(liquidationEngine)); // confiscateSAFECollateralAndDebt
    surplusAuctionHouse.addAuthorization(address(accountingEngine)); // startAuction
    debtAuctionHouse.addAuthorization(address(accountingEngine)); // startAuction
    accountingEngine.addAuthorization(address(liquidationEngine)); // pushDebtToQueue
    protocolToken.addAuthorization(address(debtAuctionHouse)); // mint
    coin.addAuthorization(address(coinJoin)); // mint

    // setup globalSettlement [auth: disableContract]
    // TODO: add key contracts to constructor
    globalSettlement.modifyParameters('safeEngine', address(safeEngine));
    safeEngine.addAuthorization(address(globalSettlement));
    globalSettlement.modifyParameters('liquidationEngine', address(liquidationEngine));
    liquidationEngine.addAuthorization(address(globalSettlement));
    globalSettlement.modifyParameters('stabilityFeeTreasury', address(stabilityFeeTreasury));
    stabilityFeeTreasury.addAuthorization(address(globalSettlement));
    globalSettlement.modifyParameters('accountingEngine', address(accountingEngine));
    accountingEngine.addAuthorization(address(globalSettlement));
    globalSettlement.modifyParameters('oracleRelayer', address(oracleRelayer));
    oracleRelayer.addAuthorization(address(globalSettlement));
    // globalSettlement.modifyParameters('coinSavingsAccount', address(oracleRelayer));
    // coinSavingsAccount.addAuthorization(address(globalSettlement));

    // setup params
    safeEngine.modifyParameters('globalDebtCeiling', _params.globalDebtCeiling);
    taxCollector.modifyParameters('globalStabilityFee', _params.globalStabilityFee);
    accountingEngine.modifyParameters('initialDebtAuctionMintedTokens', _params.initialDebtAuctionMintedTokens);
    accountingEngine.modifyParameters('debtAuctionBidSize', _params.bidAuctionSize);
    accountingEngine.modifyParameters('surplusAuctionAmountToSell', _params.surplusAuctionAmountToSell);
    surplusAuctionHouse.modifyParameters('protocolTokenBidReceiver', _params.surplusAuctionBidReceiver);
  }

  function _setupCollateral(CollateralParams memory _params, address _collateralOracle) internal {
    oracleRelayer.modifyParameters(_params.name, 'orcl', _collateralOracle);

    safeEngine.initializeCollateralType(_params.name);
    taxCollector.initializeCollateralType(_params.name);

    collateralAuctionHouse[_params.name].addAuthorization(address(liquidationEngine));
    liquidationEngine.addAuthorization(address(collateralAuctionHouse[_params.name]));
    // collateralAuctionHouse[_params.name].addAuthorization(address(globalSettlement));
    // TODO: change for a FSM oracle

    // setup registry
    collateralAuctionHouse[_params.name].modifyParameters('oracleRelayer', address(oracleRelayer));
    collateralAuctionHouse[_params.name].modifyParameters('collateralFSM', address(_collateralOracle));
    liquidationEngine.modifyParameters(
      _params.name, 'collateralAuctionHouse', address(collateralAuctionHouse[_params.name])
    );
    liquidationEngine.modifyParameters(_params.name, 'liquidationPenalty', _params.liquidationPenalty);
    liquidationEngine.modifyParameters(_params.name, 'liquidationQuantity', _params.liquidationQuantity);

    // setup params
    safeEngine.modifyParameters(_params.name, 'debtCeiling', _params.debtCeiling);
    taxCollector.modifyParameters(_params.name, 'stabilityFee', _params.stabilityFee);
    oracleRelayer.modifyParameters(_params.name, 'safetyCRatio', _params.safetyCRatio);
    oracleRelayer.modifyParameters(_params.name, 'liquidationCRatio', _params.liquidationRatio);

    // setup global settlement
    collateralAuctionHouse[_params.name].addAuthorization(address(globalSettlement)); // terminateAuctionPrematurely

    // setup initial price
    oracleRelayer.updateCollateralPrice(_params.name);
  }
}

contract DeployMainnet is Deploy {
  constructor() {
    _deployerPk = uint256(vm.envBytes32('OP_MAINNET_DEPLOYER_PK'));
    chainId = 10;
  }
}

contract DeployGoerli is Deploy {
  constructor() {
    _deployerPk = uint256(vm.envBytes32('OP_GOERLI_DEPLOYER_PK'));
    chainId = 420;
  }
}
