// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WeirTownies} from "../src/WeirTownies.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// Four-leaf Merkle trees built in the test with the contract's leaf encoding (double-hashed address), sorted pairs
/// as OpenZeppelin's MerkleProof expects.
contract WeirTowniesTest is Test {
    WeirTownies t;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address updater = makeAddr("updater");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address eve = makeAddr("eve"); // never on any list

    uint256 constant MAX = 100;
    bytes32 constant PROV = keccak256("provenance");
    uint256 constant AL_PRICE = 0;
    uint256 constant PUB_PRICE = 0.001 ether;

    bytes32 generalRoot;
    bytes32 mayorRoot;
    bytes32 auditorRoot;
    mapping(address => bytes32[]) generalProof;
    mapping(address => bytes32[]) mayorProof;
    mapping(address => bytes32[]) auditorProof;

    function leaf(address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a))));
    }

    function pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// Builds a 4-leaf tree and records each member's proof.
    function build(address[4] memory m, mapping(address => bytes32[]) storage proofs) internal returns (bytes32 root) {
        bytes32[4] memory l = [leaf(m[0]), leaf(m[1]), leaf(m[2]), leaf(m[3])];
        bytes32 n01 = pair(l[0], l[1]);
        bytes32 n23 = pair(l[2], l[3]);
        root = pair(n01, n23);
        proofs[m[0]] = new bytes32[](2); proofs[m[0]][0] = l[1]; proofs[m[0]][1] = n23;
        proofs[m[1]] = new bytes32[](2); proofs[m[1]][0] = l[0]; proofs[m[1]][1] = n23;
        proofs[m[2]] = new bytes32[](2); proofs[m[2]][0] = l[3]; proofs[m[2]][1] = n01;
        proofs[m[3]] = new bytes32[](2); proofs[m[3]][0] = l[2]; proofs[m[3]][1] = n01;
    }

    function setUp() public {
        t = new WeirTownies(owner, treasury, MAX, PROV, AL_PRICE, PUB_PRICE);
        generalRoot = build([alice, bob, carol, dave], generalProof);
        mayorRoot = build([alice, bob, carol, dave], mayorProof);
        auditorRoot = build([bob, carol, dave, alice], auditorProof);
        // layout: reserve 5, mayor pool 1, auditor pool 2, general 92 (ids 9..100)
        uint32[] memory sizes = new uint32[](2);
        sizes[0] = 1;
        sizes[1] = 2;
        bytes32[] memory roots = new bytes32[](2);
        roots[0] = mayorRoot;
        roots[1] = auditorRoot;
        vm.startPrank(owner);
        t.setLayout(5, sizes, roots);
        t.sealPools();
        t.setAllowlistRoot(generalRoot);
        t.setBaseURI("https://town.weir.cool/api/meta/");
        t.setUpdater(updater);
        vm.stopPrank();
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(eve, 1 ether);
    }

    // ---------- layout ----------

    function test_layout() public view {
        assertEq(t.reserveSize(), 5);
        assertEq(t.generalStart(), 9);
        assertEq(t.generalSize(), 92);
        assertEq(t.poolCount(), 2);
        WeirTownies.Pool memory p = t.pool(1);
        assertEq(p.start, 7);
        assertEq(p.size, 2);
        assertTrue(t.poolsSealed());
    }

    function test_layout_rejectsOverflowAndChangesAfterSeal() public {
        WeirTownies u = new WeirTownies(owner, treasury, MAX, PROV, 0, 0);
        uint32[] memory sizes = new uint32[](1);
        sizes[0] = 200;
        bytes32[] memory roots = new bytes32[](1);
        vm.startPrank(owner);
        vm.expectRevert(WeirTownies.BadLayout.selector);
        u.setLayout(5, sizes, roots);
        vm.expectRevert(WeirTownies.BadLayout.selector);
        u.sealPools(); // nothing laid out
        sizes[0] = 10;
        u.setLayout(0, sizes, roots);
        u.sealPools();
        vm.expectRevert(WeirTownies.PoolsAlreadySealed.selector);
        u.setLayout(0, sizes, roots);
        vm.stopPrank();
    }

    function test_mintNeedsSeal() public {
        WeirTownies u = new WeirTownies(owner, treasury, MAX, PROV, 0, 0);
        vm.prank(owner);
        u.setPhase(WeirTownies.Phase.Public);
        vm.prank(alice);
        vm.expectRevert(WeirTownies.PoolsNotSealed.selector);
        u.mintPublic{value: 0}(1);
    }

    // ---------- reserve ----------

    function test_ownerMintReserve() public {
        vm.prank(owner);
        t.ownerMint(owner, 5);
        assertEq(t.ownerOf(1), owner);
        assertEq(t.ownerOf(5), owner);
        vm.prank(owner);
        vm.expectRevert(WeirTownies.SoldOut.selector);
        t.ownerMint(owner, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        t.ownerMint(alice, 1);
    }

    // ---------- role pools ----------

    function test_mintRole_oncePerWallet_firstCome() public {
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Allowlist);
        vm.prank(bob);
        t.mintRole(1, auditorProof[bob]);
        assertEq(t.ownerOf(7), bob);
        vm.prank(bob);
        vm.expectRevert(WeirTownies.AlreadyClaimed.selector);
        t.mintRole(1, auditorProof[bob]);
        vm.prank(carol);
        t.mintRole(1, auditorProof[carol]);
        assertEq(t.ownerOf(8), carol);
        vm.prank(dave);
        vm.expectRevert(WeirTownies.PoolExhausted.selector);
        t.mintRole(1, auditorProof[dave]);
        // the mayor pool is a different list: alice's auditor proof does not work there, her mayor proof does
        vm.prank(alice);
        vm.expectRevert(WeirTownies.NotOnList.selector);
        t.mintRole(0, auditorProof[alice]);
        vm.prank(alice);
        t.mintRole(0, mayorProof[alice]);
        assertEq(t.ownerOf(6), alice);
    }

    function test_mintRole_closedPhaseAndStrangers() public {
        vm.prank(bob);
        vm.expectRevert(WeirTownies.WrongPhase.selector);
        t.mintRole(1, auditorProof[bob]);
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Public);
        vm.prank(eve);
        vm.expectRevert(WeirTownies.NotOnList.selector);
        t.mintRole(1, auditorProof[bob]);
    }

    function test_setPoolRootAfterSeal() public {
        vm.prank(owner);
        t.setPoolRoot(1, bytes32(0));
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Allowlist);
        vm.prank(bob);
        vm.expectRevert(WeirTownies.NotOnList.selector);
        t.mintRole(1, auditorProof[bob]);
    }

    // ---------- general: allowlist ----------

    function test_allowlist_freeMintAndCap() public {
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Allowlist);
        vm.prank(alice);
        t.mintAllowlist(2, generalProof[alice]);
        assertEq(t.ownerOf(9), alice);
        assertEq(t.ownerOf(10), alice);
        assertEq(t.generalMintedBy(alice), 2);
        vm.prank(alice);
        vm.expectRevert(WeirTownies.WalletCapReached.selector);
        t.mintAllowlist(2, generalProof[alice]);
        vm.prank(alice);
        t.mintAllowlist(1, generalProof[alice]);
        assertEq(t.balanceOf(alice), 3);
    }

    function test_allowlist_rejectsStrangerWrongPhaseWrongPayment() public {
        vm.prank(eve);
        vm.expectRevert(WeirTownies.WrongPhase.selector);
        t.mintAllowlist(1, generalProof[alice]);
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Allowlist);
        vm.prank(eve);
        vm.expectRevert(WeirTownies.NotOnList.selector);
        t.mintAllowlist(1, generalProof[alice]);
        vm.prank(alice);
        vm.expectRevert(WeirTownies.WrongPayment.selector);
        t.mintAllowlist{value: 1 wei}(1, generalProof[alice]);
        vm.prank(alice);
        vm.expectRevert(WeirTownies.ZeroQuantity.selector);
        t.mintAllowlist(0, generalProof[alice]);
    }

    // ---------- general: public ----------

    function test_public_priceAndSharedCap() public {
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Allowlist);
        vm.prank(alice);
        t.mintAllowlist(2, generalProof[alice]);
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Public);
        vm.prank(alice);
        vm.expectRevert(WeirTownies.WalletCapReached.selector);
        t.mintPublic{value: PUB_PRICE * 2}(2);
        vm.prank(alice);
        t.mintPublic{value: PUB_PRICE}(1);
        vm.prank(eve);
        vm.expectRevert(WeirTownies.WrongPayment.selector);
        t.mintPublic{value: PUB_PRICE - 1}(1);
        vm.prank(eve);
        t.mintPublic{value: PUB_PRICE * 3}(3);
        assertEq(address(t).balance, PUB_PRICE * 4);
    }

    function test_public_soldOutExactly() public {
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Public);
        // 92 general ids; 31 wallets x 3 = 93 > 92
        for (uint256 i = 0; i < 30; i++) {
            address w = address(uint160(0x1000 + i));
            vm.deal(w, 1 ether);
            vm.prank(w);
            t.mintPublic{value: PUB_PRICE * 3}(3);
        }
        assertEq(t.generalMinted(), 90);
        address last = address(0x9999);
        vm.deal(last, 1 ether);
        vm.prank(last);
        vm.expectRevert(WeirTownies.SoldOut.selector);
        t.mintPublic{value: PUB_PRICE * 3}(3);
        vm.prank(last);
        t.mintPublic{value: PUB_PRICE * 2}(2);
        assertEq(t.generalRemaining(), 0);
        assertEq(t.ownerOf(100), last);
        assertEq(t.totalSupply(), 92);
    }

    function testFuzz_generalNeverExceedsRange(uint8 a, uint8 b, uint8 c) public {
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Public);
        uint8[3] memory q = [a % 4, b % 4, c % 4];
        address[3] memory w = [alice, bob, eve];
        for (uint256 i = 0; i < 3; i++) {
            if (q[i] == 0) continue;
            vm.prank(w[i]);
            t.mintPublic{value: PUB_PRICE * q[i]}(q[i]);
        }
        assertLe(t.generalMinted(), t.generalSize());
        assertLe(t.totalSupply(), MAX);
    }

    // ---------- metadata ----------

    function test_tokenURIAndInterfaces() public {
        vm.prank(owner);
        t.ownerMint(owner, 1);
        assertEq(t.tokenURI(1), "https://town.weir.cool/api/meta/1");
        vm.expectRevert();
        t.tokenURI(2);
        assertTrue(t.supportsInterface(0x49064906)); // ERC-4906
        assertTrue(t.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(t.supportsInterface(0x780e9d63)); // ERC-721 Enumerable
        assertTrue(t.supportsInterface(0x2a55205a)); // ERC-2981
    }

    function test_rendererHook() public {
        vm.prank(owner);
        t.ownerMint(owner, 1);
        FakeRenderer r = new FakeRenderer();
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        t.setRenderer(address(r));
        vm.prank(owner);
        t.setRenderer(address(r));
        assertEq(t.tokenURI(1), "data:application/json;base64,eyJpZCI6MX0=");
        vm.expectRevert(); // unminted ids still revert through the renderer path
        t.tokenURI(2);
        vm.prank(owner);
        t.setRenderer(address(0));
        assertEq(t.tokenURI(1), "https://town.weir.cool/api/meta/1");
    }

    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function test_refreshAuth() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 3;
        ids[1] = 7;
        vm.prank(updater);
        vm.expectEmit(true, true, true, true);
        emit MetadataUpdate(3);
        vm.expectEmit(true, true, true, true);
        emit MetadataUpdate(7);
        t.refreshMetadata(ids);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit BatchMetadataUpdate(1, MAX);
        t.refreshAll();
        vm.prank(eve);
        vm.expectRevert(WeirTownies.NotUpdater.selector);
        t.refreshAll();
    }

    // ---------- money and ownership ----------

    function test_withdrawToTreasuryOnly() public {
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Public);
        vm.prank(eve);
        t.mintPublic{value: PUB_PRICE * 2}(2);
        uint256 before = treasury.balance;
        vm.prank(eve); // anyone may trigger it
        t.withdraw();
        assertEq(treasury.balance - before, PUB_PRICE * 2);
        assertEq(address(t).balance, 0);
    }

    function test_royalty() public view {
        (address to, uint256 amount) = t.royaltyInfo(1, 1 ether);
        assertEq(to, treasury);
        assertEq(amount, 0.05 ether);
    }

    function test_ownable2Step() public {
        vm.prank(owner);
        t.transferOwnership(alice);
        assertEq(t.owner(), owner);
        vm.prank(alice);
        t.acceptOwnership();
        assertEq(t.owner(), alice);
    }

    function test_settersOnlyOwner() public {
        vm.startPrank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        t.setPhase(WeirTownies.Phase.Public);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        t.setPrices(1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        t.setTreasury(eve);
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(WeirTownies.ZeroAddress.selector);
        t.setTreasury(address(0));
    }

    function test_constructorGuards() public {
        vm.expectRevert(WeirTownies.ZeroAddress.selector);
        new WeirTownies(owner, address(0), MAX, PROV, 0, 0);
        vm.expectRevert(WeirTownies.BadLayout.selector);
        new WeirTownies(owner, treasury, 0, PROV, 0, 0);
        assertEq(t.PROVENANCE_HASH(), PROV);
        assertEq(t.MAX_SUPPLY(), MAX);
    }

    // ---------- reentrancy: a receiver that re-enters mintPublic ----------

    function test_reentrantReceiverCannotDoubleMint() public {
        vm.prank(owner);
        t.setPhase(WeirTownies.Phase.Public);
        Reenterer r = new Reenterer(t);
        vm.deal(address(r), 1 ether);
        r.go{value: PUB_PRICE}();
        // the nested call reverted inside onERC721Received; _safeMint bubbles that up, so nothing was minted at all
        assertEq(t.balanceOf(address(r)), 0);
        assertTrue(r.sawRevert());
    }
}

contract FakeRenderer {
    function tokenURI(uint256 id) external pure returns (string memory) {
        return id == 1 ? "data:application/json;base64,eyJpZCI6MX0=" : "";
    }
}

contract Reenterer is IERC721Receiver {
    WeirTownies t;
    bool public sawRevert;
    bool entered;

    constructor(WeirTownies t_) {
        t = t_;
    }

    function go() external payable {
        try t.mintPublic{value: msg.value}(1) {} catch { sawRevert = true; }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external override returns (bytes4) {
        if (!entered) {
            entered = true;
            t.mintPublic{value: 0}(1); // reverts: ReentrancyGuard
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}
