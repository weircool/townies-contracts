// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice An optional on-chain metadata source. When the owner sets one, tokenURI asks it instead of the base URI,
///         so the art can move on chain (a layer renderer) after mint without a new collection.
interface ITownieRenderer {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

/// @title Weir Townies
/// @notice 3,333 pixel frogs who live and work in Weir town (town.weir.cool). Token ids are laid out in fixed ranges
///         by the generator before deploy and sealed by the provenance hash:
///           [1 .. reserve]   the 1/1s and the team reserve, minted by the owner
///           [role pools]     earned occupations (Mayor, Judge, Auditor, Spaces Host), one id range each, claimable
///                            once per wallet against that pool's Merkle root, first come until the pool is gone
///           [general]        everyone else: the allowlist (Merkle root, free) and then the public sale
///         Metadata lives at baseURI + id and may change (live traits); the contract emits ERC-4906 events when the
///         updater says so. Nothing is upgradeable. The owner can close the phase, change prices, roots, the base URI,
///         the updater and the treasury, and nothing else; sold tokens are never touched.
contract WeirTownies is ERC721, ERC721Enumerable, ERC2981, Ownable2Step, ReentrancyGuard {
    using Strings for uint256;

    enum Phase { Closed, Allowlist, Public }

    struct Pool {
        uint32 start;   // first token id of the pool (inclusive)
        uint32 size;    // number of ids in the pool
        uint32 minted;  // ids handed out so far
        bytes32 root;   // Merkle root of the wallets that may claim one
    }

    uint256 public immutable MAX_SUPPLY;
    bytes32 public immutable PROVENANCE_HASH;
    uint8 public constant WALLET_CAP = 3; // general mints per wallet across the allowlist and public phases
    uint96 public constant MAX_ROYALTY_BPS = 1000; // 10%
    bytes4 private constant ERC4906_INTERFACE = 0x49064906;

    Phase public phase;
    uint256 public allowlistPrice; // wei per token in the allowlist phase (0 = free)
    uint256 public publicPrice; // wei per token in the public phase
    bytes32 public allowlistRoot; // the general allowlist
    string private _baseTokenURI;
    ITownieRenderer public renderer; // optional on-chain metadata source; zero = use the base URI
    address public updater; // may emit metadata refresh events
    address public treasury; // receives withdrawals and royalties
    uint96 public royaltyBps; // follows the treasury on every rotation
    bool public metadataFrozen; // one way: no more base URI or renderer changes
    bool public saleEnded; // one way: closes minting for good; unsold ids may then be swept by the owner

    uint32 public reserveSize; // ids 1..reserveSize belong to the owner (1/1s, team)
    uint32 public reserveMinted;
    Pool[] private _pools; // role pools in id order after the reserve
    uint32 public generalStart; // first general id; set by the layout
    uint32 public generalMinted;
    bool public poolsSealed;

    mapping(address => uint8) public generalMintedBy; // per-wallet general mints
    mapping(uint256 => mapping(address => bool)) public roleClaimed; // pool index => wallet => claimed

    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event PhaseSet(Phase phase);
    event PricesSet(uint256 allowlistPrice, uint256 publicPrice);
    event AllowlistRootSet(bytes32 root);
    event PoolSet(uint256 indexed pool, uint32 start, uint32 size, bytes32 root);
    event PoolsSealed(uint32 reserveSize, uint32 generalStart);
    event BaseURISet(string uri);
    event RendererSet(address renderer);
    event UpdaterSet(address updater);
    event TreasurySet(address treasury);
    event Withdrawn(address to, uint256 amount);
    event RoyaltySet(uint96 bps);
    event MetadataFrozen();
    event SaleEnded();

    error WrongPhase();
    error SoldOut();
    error WalletCapReached();
    error WrongPayment();
    error NotOnList();
    error AlreadyClaimed();
    error PoolExhausted();
    error PoolsNotSealed();
    error PoolsAlreadySealed();
    error BadLayout();
    error NotUpdater();
    error ZeroAddress();
    error ZeroQuantity();
    error TransferFailed();
    error NothingToWithdraw();
    error RoyaltyTooHigh();
    error MetadataIsFrozen();
    error SaleIsOver();
    error SaleNotOver();
    error Renounced();

    constructor(
        address owner_,
        address treasury_,
        uint256 maxSupply_,
        bytes32 provenanceHash_,
        uint256 allowlistPrice_,
        uint256 publicPrice_
    ) ERC721("Weir Townies", "TOWNIE") Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (maxSupply_ == 0 || maxSupply_ > type(uint32).max) revert BadLayout();
        MAX_SUPPLY = maxSupply_;
        PROVENANCE_HASH = provenanceHash_;
        allowlistPrice = allowlistPrice_;
        publicPrice = publicPrice_;
        treasury = treasury_;
        royaltyBps = 500; // 5%
        _setDefaultRoyalty(treasury_, 500);
    }

    // ---------- layout (owner, before the sale) ----------

    /// @notice Sets the reserve and the role pools in one go, in id order. Pools tile the ids after the reserve with
    ///         no gaps; everything after the last pool is the general range. Callable until sealed.
    function setLayout(uint32 reserveSize_, uint32[] calldata sizes, bytes32[] calldata roots) external onlyOwner {
        if (poolsSealed) revert PoolsAlreadySealed();
        if (sizes.length != roots.length) revert BadLayout();
        delete _pools;
        uint32 next = reserveSize_ + 1;
        for (uint256 i = 0; i < sizes.length; i++) {
            if (sizes[i] == 0) revert BadLayout();
            _pools.push(Pool({start: next, size: sizes[i], minted: 0, root: roots[i]}));
            emit PoolSet(i, next, sizes[i], roots[i]);
            next += sizes[i];
        }
        if (uint256(next) - 1 > MAX_SUPPLY) revert BadLayout();
        reserveSize = reserveSize_;
        generalStart = next;
    }

    /// @notice Freezes the ranges. Minting of any kind needs this.
    function sealPools() external onlyOwner {
        if (poolsSealed) revert PoolsAlreadySealed();
        if (generalStart == 0) revert BadLayout();
        poolsSealed = true;
        emit PoolsSealed(reserveSize, generalStart);
    }

    /// @notice A pool's root may change after sealing (a corrected snapshot), never its range.
    function setPoolRoot(uint256 poolIndex, bytes32 root) external onlyOwner {
        Pool storage p = _pools[poolIndex];
        p.root = root;
        emit PoolSet(poolIndex, p.start, p.size, root);
    }

    function pools() external view returns (Pool[] memory) {
        return _pools;
    }

    function poolCount() external view returns (uint256) {
        return _pools.length;
    }

    function pool(uint256 i) external view returns (Pool memory) {
        return _pools[i];
    }

    /// @notice Ids in the general range (0 until the layout is set).
    function generalSize() public view returns (uint256) {
        return generalStart == 0 ? 0 : MAX_SUPPLY + 1 - generalStart;
    }

    function generalRemaining() external view returns (uint256) {
        return generalSize() - generalMinted;
    }

    // ---------- minting ----------

    /// @notice The owner mints from the reserve (the 1/1s and the team's share) to any address, in any phase.
    function ownerMint(address to, uint32 qty) external onlyOwner nonReentrant {
        if (!poolsSealed) revert PoolsNotSealed();
        if (qty == 0) revert ZeroQuantity();
        if (saleEnded) revert SaleIsOver();
        if (uint256(reserveMinted) + qty > reserveSize) revert SoldOut();
        uint32 first = reserveMinted + 1;
        reserveMinted += qty;
        for (uint32 i = 0; i < qty; i++) _safeMint(to, first + i);
    }

    /// @notice One Townie of an earned occupation for a wallet on that pool's list, first come until the pool is gone.
    ///         Free; open in both sale phases.
    function mintRole(uint256 poolIndex, bytes32[] calldata proof) external nonReentrant {
        if (!poolsSealed) revert PoolsNotSealed();
        if (saleEnded) revert SaleIsOver();
        if (phase == Phase.Closed) revert WrongPhase();
        Pool storage p = _pools[poolIndex];
        if (roleClaimed[poolIndex][msg.sender]) revert AlreadyClaimed();
        if (!_onList(p.root, proof, msg.sender)) revert NotOnList();
        if (p.minted >= p.size) revert PoolExhausted();
        roleClaimed[poolIndex][msg.sender] = true;
        uint256 id = uint256(p.start) + p.minted;
        p.minted += 1;
        _safeMint(msg.sender, id);
    }

    /// @notice General allowlist mint (free when allowlistPrice is 0), up to WALLET_CAP per wallet.
    function mintAllowlist(uint8 qty, bytes32[] calldata proof) external payable nonReentrant {
        if (phase != Phase.Allowlist) revert WrongPhase();
        if (!_onList(allowlistRoot, proof, msg.sender)) revert NotOnList();
        _mintGeneral(qty, allowlistPrice);
    }

    /// @notice Public mint at publicPrice, up to WALLET_CAP per wallet (the cap is shared with the allowlist phase).
    function mintPublic(uint8 qty) external payable nonReentrant {
        if (phase != Phase.Public) revert WrongPhase();
        _mintGeneral(qty, publicPrice);
    }

    function _mintGeneral(uint8 qty, uint256 price) private {
        if (!poolsSealed) revert PoolsNotSealed();
        if (saleEnded) revert SaleIsOver();
        if (qty == 0) revert ZeroQuantity();
        if (uint256(generalMintedBy[msg.sender]) + qty > WALLET_CAP) revert WalletCapReached();
        if (uint256(generalMinted) + qty > generalSize()) revert SoldOut();
        if (msg.value != price * qty) revert WrongPayment();
        generalMintedBy[msg.sender] += qty;
        uint256 first = uint256(generalStart) + generalMinted;
        generalMinted += qty;
        for (uint256 i = 0; i < qty; i++) _safeMint(msg.sender, first + i);
    }

    /// @notice Closes minting for good. After this the owner may sweep what nobody claimed, so the collection can
    ///         still reach its full size; nothing minted is touched.
    function endSale() external onlyOwner {
        if (saleEnded) revert SaleIsOver();
        saleEnded = true;
        phase = Phase.Closed;
        emit SaleEnded();
        emit PhaseSet(Phase.Closed);
    }

    /// @notice After endSale: mints unsold general ids to `to`, oldest id first, up to `qty`.
    function sweepGeneral(address to, uint32 qty) external onlyOwner nonReentrant {
        if (!saleEnded) revert SaleNotOver();
        if (qty == 0) revert ZeroQuantity();
        if (uint256(generalMinted) + qty > generalSize()) revert SoldOut();
        uint256 first = uint256(generalStart) + generalMinted;
        generalMinted += qty;
        for (uint256 i = 0; i < qty; i++) _safeMint(to, first + i);
    }

    /// @notice After endSale: mints the unclaimed ids of one role pool to `to`, up to `qty`.
    function sweepPool(uint256 poolIndex, address to, uint32 qty) external onlyOwner nonReentrant {
        if (!saleEnded) revert SaleNotOver();
        if (qty == 0) revert ZeroQuantity();
        Pool storage p = _pools[poolIndex];
        if (uint256(p.minted) + qty > p.size) revert PoolExhausted();
        uint256 first = uint256(p.start) + p.minted;
        p.minted += qty;
        for (uint256 i = 0; i < qty; i++) _safeMint(to, first + i);
    }

    function _onList(bytes32 root, bytes32[] calldata proof, address account) private pure returns (bool) {
        if (root == bytes32(0)) return false;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account))));
        return MerkleProof.verify(proof, root, leaf);
    }

    // ---------- metadata ----------

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (address(renderer) != address(0)) return renderer.tokenURI(tokenId);
        return string.concat(_baseTokenURI, tokenId.toString());
    }

    /// @notice Tells marketplaces these tokens' metadata changed (ERC-4906). Owner or the updater.
    function refreshMetadata(uint256[] calldata ids) external {
        if (msg.sender != updater && msg.sender != owner()) revert NotUpdater();
        for (uint256 i = 0; i < ids.length; i++) emit MetadataUpdate(ids[i]);
    }

    function refreshAll() external {
        if (msg.sender != updater && msg.sender != owner()) revert NotUpdater();
        emit BatchMetadataUpdate(1, MAX_SUPPLY);
    }

    // ---------- owner settings ----------

    function setPhase(Phase p) external onlyOwner {
        if (saleEnded) revert SaleIsOver();
        phase = p;
        emit PhaseSet(p);
    }

    function setPrices(uint256 allowlist_, uint256 public_) external onlyOwner {
        allowlistPrice = allowlist_;
        publicPrice = public_;
        emit PricesSet(allowlist_, public_);
    }

    function setAllowlistRoot(bytes32 root) external onlyOwner {
        allowlistRoot = root;
        emit AllowlistRootSet(root);
    }

    function setBaseURI(string calldata uri) external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        _baseTokenURI = uri;
        emit BaseURISet(uri);
    }

    /// @notice One way: the base URI and the renderer can never change again.
    function freezeMetadata() external onlyOwner {
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    /// @notice Points tokenURI at an on-chain renderer (or back to the base URI with address(0)). Tell marketplaces
    ///         with refreshAll() afterwards.
    function setRenderer(address r) external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        renderer = ITownieRenderer(r);
        emit RendererSet(r);
    }

    function setUpdater(address u) external onlyOwner {
        updater = u;
        emit UpdaterSet(u);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        _setDefaultRoyalty(t, royaltyBps);
        emit TreasurySet(t);
    }

    function setRoyalty(uint96 bps) external onlyOwner {
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        royaltyBps = bps;
        _setDefaultRoyalty(treasury, bps);
        emit RoyaltySet(bps);
    }

    /// @notice Ownership is handed over in two steps only; it is never given up.
    function renounceOwnership() public view override onlyOwner {
        revert Renounced();
    }

    /// @notice Sends the whole ETH balance to the treasury. Anyone may call; only the treasury ever receives.
    function withdraw() external nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(treasury, amount);
    }

    // ---------- plumbing ----------

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC2981)
        returns (bool)
    {
        return interfaceId == ERC4906_INTERFACE || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }
}
