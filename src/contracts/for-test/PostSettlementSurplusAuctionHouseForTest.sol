// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {
  PostSettlementSurplusAuctionHouse,
  IPostSettlementSurplusAuctionHouse
} from '@contracts/settlement/PostSettlementSurplusAuctionHouse.sol';

contract PostSettlementSurplusAuctionHouseForTest is PostSettlementSurplusAuctionHouse {
  constructor(
    address _safeEngine,
    address _protocolToken,
    PostSettlementSAHParams memory _pssahParams
  ) PostSettlementSurplusAuctionHouse(_safeEngine, _protocolToken, _pssahParams) {}

  function addBid(
    uint256 _id,
    uint256 _bidAmount,
    uint256 _amountToSell,
    address _highBidder,
    uint256 _bidExpiry,
    uint256 _auctionDeadline
  ) external {
    bids[_id].bidAmount = _bidAmount;
    bids[_id].amountToSell = _amountToSell;
    bids[_id].highBidder = _highBidder;
    bids[_id].bidExpiry = _bidExpiry;
    bids[_id].auctionDeadline = _auctionDeadline;
  }
}
