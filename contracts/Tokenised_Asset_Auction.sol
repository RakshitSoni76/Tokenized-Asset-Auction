// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Tokenized Asset Auction
 * @dev A simple auction contract where the owner lists a tokenized asset for sale
 * and bidders compete with increasing bids. The highest bidder wins after auction ends.
 */
contract TokenizedAuction {
    address public owner;
    string public assetName;
    uint256 public startPrice;
    uint256 public highestBid;
    address public highestBidder;
    uint256 public endTime;
    bool public ended;

    mapping(address => uint256) public bids;

    event AuctionStarted(string assetName, uint256 startPrice, uint256 endTime);
    event NewBid(address indexed bidder, uint256 amount);
    event AuctionEnded(address indexed winner, uint256 amount);
    event Withdraw(address indexed bidder, uint256 amount);

    constructor(
        string memory _assetName,
        uint256 _startPrice,
        uint256 _durationSeconds
    ) {
        owner = msg.sender;
        assetName = _assetName;
        startPrice = _startPrice;
        endTime = block.timestamp + _durationSeconds;
        highestBid = _startPrice;
        emit AuctionStarted(_assetName, _startPrice, endTime);
    }

    /**
     * @dev Place a bid higher than the current highest bid.
     */
    function placeBid() external payable {
        require(block.timestamp < endTime, "Auction ended");
        require(msg.value > highestBid, "Bid too low");

        // Refund previous highest bidder
        if (highestBidder != address(0)) {
            bids[highestBidder] += highestBid;
        }

        highestBid = msg.value;
        highestBidder = msg.sender;
        emit NewBid(msg.sender, msg.value);
    }

    /**
     * @dev Withdraw funds for bidders who didn’t win.
     */
    function withdraw() external {
        uint256 amount = bids[msg.sender];
        require(amount > 0, "No funds to withdraw");
        bids[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdraw failed");
        emit Withdraw(msg.sender, amount);
    }

    /**
     * @dev End the auction and send funds to the owner.
     */
    function endAuction() external {
        require(msg.sender == owner, "Only owner");
        require(block.timestamp >= endTime, "Auction still running");
        require(!ended, "Auction already ended");

        ended = true;

        if (highestBidder != address(0)) {
            (bool success, ) = payable(owner).call{value: highestBid}("");
            require(success, "Transfer to owner failed");
        }

        emit AuctionEnded(highestBidder, highestBid);
    }

    /**
     * @dev Returns remaining time (seconds).
     */
    function getRemainingTime() external view returns (uint256) {
        if (block.timestamp >= endTime) return 0;
        return endTime - block.timestamp;
    }
}
