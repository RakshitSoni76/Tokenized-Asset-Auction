// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Basic Tokenized Asset (ERC721) + AuctionHouse implementation
// - AssetToken: simple ERC721 that allows the owner to mint tokens representing real-world assets.
// - AuctionHouse: English auction for ERC721 tokens. Sellers create auctions for tokenIds they own
//   (or have approved the AuctionHouse). Bidders place ETH bids. Auction can be settled after end.

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract AssetToken is ERC721, Ownable {
    uint256 private _nextTokenId = 1;

    // simple metadata storage (tokenURI library could be used instead)
    mapping(uint256 => string) private _tokenURIs;

    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    /// @notice Mint a new asset token to `to` with optional tokenURI
    function mint(address to, string memory tokenURI_) external onlyOwner returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        if (bytes(tokenURI_).length > 0) {
            _tokenURIs[tokenId] = tokenURI_;
        }
        return tokenId;
    }

    function tokenURI(uint256 tokenId) public view virtual returns (string memory) {
        require(_exists(tokenId), "ERC721: URI query for nonexistent token");
        return _tokenURIs[tokenId];
    }

    /// @notice Allow owner to set tokenURI for an existing token
    function setTokenURI(uint256 tokenId, string memory uri_) external onlyOwner {
        require(_exists(tokenId), "ERC721: set URI for nonexistent token");
        _tokenURIs[tokenId] = uri_;
    }
}

contract AuctionHouse is ReentrancyGuard {
    struct Auction {
        address seller;         // token owner who created auction
        address tokenAddress;   // ERC721 contract
        uint256 tokenId;        // token being auctioned
        uint256 minBid;         // minimum starting bid
        uint256 highestBid;     // current highest bid
        address highestBidder;  // current highest bidder
        uint256 startTime;      // auction start timestamp
        uint256 endTime;        // auction end timestamp
        bool settled;           // whether auction settled
    }

    // auctionId => Auction
    mapping(uint256 => Auction) public auctions;
    uint256 public nextAuctionId = 1;

    // bidder => amount pending withdrawal (used to refund outbid bidders)
    mapping(address => uint256) public pendingReturns;

    // events
    event AuctionCreated(uint256 indexed auctionId, address indexed seller, address tokenAddress, uint256 tokenId, uint256 minBid, uint256 endTime);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionSettled(uint256 indexed auctionId, address indexed winner, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Create an auction for an ERC721 token. The caller must be token owner and approve this contract.
    /// @param tokenAddress address of the ERC721 contract
    /// @param tokenId token id to auction
    /// @param minBid minimum starting bid in wei
    /// @param duration auction duration in seconds (from now)
    function createAuction(address tokenAddress, uint256 tokenId, uint256 minBid, uint256 duration) external returns (uint256) {
        require(duration >= 60, "Auction: duration too short");
        // verify msg.sender owns token
        ERC721 token = ERC721(tokenAddress);
        require(token.ownerOf(tokenId) == msg.sender, "Auction: not token owner");
        // contract must be approved to transfer the token
        require(token.getApproved(tokenId) == address(this) || token.isApprovedForAll(msg.sender, address(this)), "Auction: not approved");

        uint256 auctionId = nextAuctionId++;
        auctions[auctionId] = Auction({
            seller: msg.sender,
            tokenAddress: tokenAddress,
            tokenId: tokenId,
            minBid: minBid,
            highestBid: 0,
            highestBidder: address(0),
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            settled: false
        });

        emit AuctionCreated(auctionId, msg.sender, tokenAddress, tokenId, minBid, block.timestamp + duration);
        return auctionId;
    }

    /// @notice Place a bid on an active auction. Bid amount is msg.value (in wei).
    /// If outbidding a previous bidder, previous bid is credited to pendingReturns for withdrawal.
    function bid(uint256 auctionId) external payable nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller != address(0), "Auction: not found");
        require(block.timestamp >= a.startTime && block.timestamp < a.endTime, "Auction: not active");
        uint256 incoming = msg.value;
        uint256 requiredMin = a.highestBid == 0 ? a.minBid : a.highestBid + ((a.highestBid * 5) / 100); // optionally 5% min increment
        require(incoming >= requiredMin, "Auction: bid too low");

        if (a.highestBidder != address(0)) {
            // refund previous highest by crediting
            pendingReturns[a.highestBidder] += a.highestBid;
        }

        a.highestBid = incoming;
        a.highestBidder = msg.sender;

        emit BidPlaced(auctionId, msg.sender, incoming);
    }

    /// @notice Withdraw pending refunds from being outbid.
    function withdraw() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        require(amount > 0, "Auction: no funds to withdraw");
        pendingReturns[msg.sender] = 0;
        (bool sent, ) = payable(msg.sender).call{value: amount}('');
        require(sent, "Auction: withdraw failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Settle an auction after it ends. Transfers token to winner and sends funds to seller.
    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        require(a.seller != address(0), "Auction: not found");
        require(block.timestamp >= a.endTime, "Auction: not ended");
        require(!a.settled, "Auction: already settled");

        a.settled = true;

        ERC721 token = ERC721(a.tokenAddress);

        if (a.highestBidder == address(0)) {
            // no bids; auction canceled/un-sold. Nothing to transfer. Seller keeps token.
            emit AuctionSettled(auctionId, address(0), 0);
            return;
        }

        // transfer token from seller to winner
        token.safeTransferFrom(a.seller, a.highestBidder, a.tokenId);

        // transfer funds to seller
        (bool sent, ) = payable(a.seller).call{value: a.highestBid}('');
        require(sent, "Auction: transfer to seller failed");

        emit AuctionSettled(auctionId, a.highestBidder, a.highestBid);
    }

    // helper: get auction details
    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return auctions[auctionId];
    }
}
