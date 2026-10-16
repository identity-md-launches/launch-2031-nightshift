// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Nightshift} from "../src/Nightshift.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Only the Foundry cheatcodes used here; no external test dependency.
interface Vm {
    function prank(address sender) external;
    function deal(address account, uint256 newBalance) external;
    function expectRevert(bytes calldata data) external;
    function expectRevert() external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);

    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
}

/// @dev A recipient that reverts when it is paid in ether, and otherwise does nothing: tokens
/// must still reach it, because an ERC-20 transfer never calls the receiver.
contract RefusingReceiver {
    receive() external payable {
        revert("no ether");
    }
}

/// @notice Edge cases and failure paths beyond the main suite: the exact external surface, the
/// finite/unlimited allowance boundary, pair isolation of allowances, callers the code did not
/// expect, and calls that carry ether. Where a fuzzed amount matters, the known edges (zero, one
/// unit, the full supply, the maximum) are pinned as plain tests beside it.
/// forge-config: default.fuzz.runs = 1000
contract NightshiftEdgeTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    uint256 private constant MAX = type(uint256).max;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");
    Nightshift private token;

    function setUp() public {
        token = new Nightshift();
    }

    // ------------------------------------------------------------ external surface

    /// @dev The complete ABI: nine ERC-20 functions and the supply constant. Anything else reverts.
    function _isErc20Surface(bytes4 selector) private pure returns (bool) {
        string[10] memory surface = [
            "name()",
            "symbol()",
            "decimals()",
            "totalSupply()",
            "balanceOf(address)",
            "transfer(address,uint256)",
            "allowance(address,address)",
            "approve(address,uint256)",
            "transferFrom(address,address,uint256)",
            "INITIAL_SUPPLY()"
        ];
        for (uint256 i; i < surface.length; ++i) {
            if (selector == bytes4(keccak256(bytes(surface[i])))) return true;
        }
        return false;
    }

    function testFuzzUnknownSelectorRevertsWithoutEffect(bytes4 selector, bytes calldata payload, uint256 callerSeed)
        public
    {
        while (_isErc20Surface(selector)) {
            selector = bytes4(keccak256(abi.encodePacked(selector)));
        }
        address caller = callerSeed % 2 == 0 ? address(this) : ALICE;
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(abi.encodePacked(selector, payload));
        require(!ok, "unknown selector accepted");
        require(ret.length == 0, "unknown selector returned data");
        require(token.totalSupply() == SUPPLY && token.balanceOf(address(this)) == SUPPLY, "state changed");
    }

    function testEmptyCalldataReverts() public {
        (bool ok,) = address(token).call("");
        require(!ok, "empty call accepted");
        vm.prank(ALICE);
        (ok,) = address(token).call("");
        require(!ok, "empty call from stranger accepted");
    }

    function testEtherIsRefused() public {
        vm.deal(address(this), 3 ether);
        (bool ok,) = address(token).call{value: 1 ether}("");
        require(!ok, "plain ether accepted");
        (ok,) = address(token).call{value: 1 ether}(abi.encodeCall(token.transfer, (ALICE, 1)));
        require(!ok, "ether accepted alongside transfer");
        (ok,) = address(token).call{value: 1 ether}(abi.encodeCall(token.approve, (ALICE, 1)));
        require(!ok, "ether accepted alongside approve");
        require(address(token).balance == 0, "token kept ether");
        require(token.balanceOf(ALICE) == 0 && token.allowance(address(this), ALICE) == 0, "state changed");
    }

    function testCodeIsWithinTheRuntimeLimit() public view {
        require(address(token).code.length > 0 && address(token).code.length <= 24_576, "runtime size");
    }

    // ------------------------------------------------------------ deployment

    function testEveryDeploymentHasItsOwnIndependentSupply() public {
        Nightshift second = new Nightshift();
        require(second.totalSupply() == SUPPLY && second.balanceOf(address(this)) == SUPPLY, "second supply");
        require(token.totalSupply() == SUPPLY, "first supply changed");
        token.transfer(ALICE, 5);
        require(second.balanceOf(ALICE) == 0 && second.balanceOf(address(this)) == SUPPLY, "crossed over");
        require(token.balanceOf(ALICE) == 5, "first transfer");
    }

    function testConstructorEmitsExactlyOneEvent() public {
        vm.recordLogs();
        Nightshift fresh = new Nightshift();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "event count");
        require(logs[0].emitter == address(fresh), "emitter");
        require(logs[0].topics[0] == TRANSFER_TOPIC, "topic");
        require(logs[0].topics[1] == bytes32(0), "from is not zero");
        require(logs[0].topics[2] == bytes32(uint256(uint160(address(this)))), "to is not deployer");
        require(abi.decode(logs[0].data, (uint256)) == SUPPLY, "minted amount");
    }

    // ------------------------------------------------------------ transfer edges

    function testTransferOfOneUnitAndOfTheMaximum() public {
        require(token.transfer(ALICE, 1), "one unit");
        require(token.balanceOf(ALICE) == 1 && token.balanceOf(address(this)) == SUPPLY - 1, "one unit balances");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY - 1, MAX)
        );
        token.transfer(ALICE, MAX);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1, 2));
        token.transfer(BOB, 2);
    }

    function testEmptyAccountCannotSendOneUnit() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function testZeroAddressCannotSendEvenZero() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(ALICE, 0);
    }

    function testSelfTransferAboveBalanceStillReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(address(this), SUPPLY + 1);
    }

    function testTransferReachesAContractThatRefusesEther() public {
        RefusingReceiver receiver = new RefusingReceiver();
        require(token.transfer(address(receiver), 7), "transfer to refusing receiver");
        require(token.balanceOf(address(receiver)) == 7, "receiver balance");
    }

    function testTransferToTokenContractStrandsButConservesSupply() public {
        require(token.transfer(address(token), 9), "transfer to token");
        require(token.balanceOf(address(token)) == 9, "token balance");
        require(token.balanceOf(address(this)) + 9 == SUPPLY && token.totalSupply() == SUPPLY, "conservation");
    }

    /// @dev Exactly the balance succeeds; one unit more reverts with that balance in the error.
    function testFuzzTransferBoundaryAtExactBalance(uint256 rawBalance, uint256 rawExcess) public {
        uint256 balance = rawBalance % (SUPPLY + 1);
        uint256 excess = 1 + (rawExcess % (SUPPLY - balance + 1));
        token.transfer(ALICE, balance);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, balance, balance + excess)
        );
        token.transfer(BOB, balance + excess);
        require(token.balanceOf(ALICE) == balance && token.balanceOf(BOB) == 0, "failed transfer moved tokens");
        vm.prank(ALICE);
        require(token.transfer(BOB, balance), "exact balance");
        require(token.balanceOf(ALICE) == 0 && token.balanceOf(BOB) == balance, "exact balance moved");
    }

    /// @dev A stranger with nothing cannot send any positive amount to anyone. The zero address is
    /// refused as a sender outright, before its (empty) balance is even consulted.
    function testFuzzStrangerCannotSpendWhatItDoesNotHold(address stranger, address to, uint256 rawAmount) public {
        if (stranger == address(this)) stranger = ALICE;
        if (to == address(0)) to = BOB;
        uint256 amount = 1 + (rawAmount % MAX);
        if (stranger == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        } else {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, amount));
        }
        vm.prank(stranger);
        token.transfer(to, amount);
        require(token.balanceOf(to) == 0 || to == address(this), "recipient credited");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    /// @dev Splitting the supply across a random partition and sending it on leaves the sum intact.
    function testFuzzPartitionConservesSupply(uint256 a, uint256 b, uint256 c) public {
        a = a % (SUPPLY + 1);
        b = b % (SUPPLY - a + 1);
        c = c % (SUPPLY - a - b + 1);
        token.transfer(ALICE, a);
        token.transfer(BOB, b);
        token.transfer(SPENDER, c);
        require(token.balanceOf(address(this)) == SUPPLY - a - b - c, "remainder");
        vm.prank(ALICE);
        token.transfer(BOB, a);
        vm.prank(BOB);
        token.transfer(SPENDER, a + b);
        require(token.balanceOf(SPENDER) == a + b + c, "chain delivered short");
        require(token.balanceOf(ALICE) == 0 && token.balanceOf(BOB) == 0, "senders kept something");
        require(
            token.balanceOf(address(this)) + token.balanceOf(SPENDER) == SUPPLY && token.totalSupply() == SUPPLY,
            "conservation"
        );
    }

    // ------------------------------------------------------------ allowance edges

    function testOwnerNeedsAnAllowanceToSpendItsOwnBalanceThroughTransferFrom() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), ALICE, 1);
        token.approve(address(this), 1);
        require(token.transferFrom(address(this), ALICE, 1), "self-approved transferFrom");
        require(token.allowance(address(this), address(this)) == 0 && token.balanceOf(ALICE) == 1, "self spend");
    }

    function testAllowanceIsBoundToThePair() public {
        token.approve(SPENDER, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        require(token.allowance(address(this), SPENDER) == 100, "pair allowance changed");
        require(token.allowance(SPENDER, address(this)) == 0, "allowance is not directional");
    }

    function testApprovalMovesNothing() public {
        token.approve(SPENDER, SUPPLY);
        require(token.balanceOf(SPENDER) == 0 && token.balanceOf(address(this)) == SUPPLY, "approve moved tokens");
        require(token.totalSupply() == SUPPLY, "approve changed supply");
    }

    function testApprovalAboveBalanceIsAllowedButCannotBeSpent() public {
        token.approve(SPENDER, MAX - 1);
        require(token.allowance(address(this), SPENDER) == MAX - 1, "allowance above balance");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, SUPPLY + 1);
        require(token.allowance(address(this), SPENDER) == MAX - 1, "failed spend touched allowance");
    }

    function testMaxMinusOneAllowanceIsFiniteAndDecrements() public {
        token.approve(SPENDER, MAX - 1);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        require(token.allowance(address(this), SPENDER) == MAX - 2, "max-1 treated as unlimited");
    }

    function testUnlimitedAllowanceSpendsTheWholeBalanceAndNoMore() public {
        token.approve(SPENDER, MAX);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, SUPPLY), "spend whole balance");
        require(token.allowance(address(this), SPENDER) == MAX, "unlimited decremented");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
    }

    function testExactAllowanceSpendsToZeroThenOneMoreReverts() public {
        token.approve(SPENDER, 10);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 10);
        require(token.allowance(address(this), SPENDER) == 0, "exact spend remainder");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
    }

    function testZeroTransferFromWithoutAllowanceSucceeds() public {
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 0), "zero delegated transfer");
        require(token.allowance(address(this), SPENDER) == 0 && token.balanceOf(ALICE) == 0, "zero spend");
    }

    function testAllowanceOrderIsCheckedBeforeBalance() public {
        // Alice holds nothing and allows 5: asking 6 fails on the allowance, not the balance.
        vm.prank(ALICE);
        token.approve(SPENDER, 5);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 5, 6));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 6);
    }

    function testTransferFromToZeroWithZeroAllowanceFailsOnAllowanceFirst() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 1);
    }

    function testTransferFromDoesNotEmitApproval() public {
        token.approve(SPENDER, 10);
        vm.recordLogs();
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "event count");
        require(logs[0].topics[0] == TRANSFER_TOPIC, "not a Transfer");
        require(logs[0].topics[1] == bytes32(uint256(uint160(address(this)))), "from");
        require(logs[0].topics[2] == bytes32(uint256(uint160(ALICE))), "to");
        require(abi.decode(logs[0].data, (uint256)) == 4, "amount");
        require(token.allowance(address(this), SPENDER) == 6, "remaining allowance");
    }

    function testApproveEmitsApprovalOnlyWithTheNewValue() public {
        token.approve(SPENDER, 10);
        vm.recordLogs();
        token.approve(SPENDER, 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1 && logs[0].topics[0] == APPROVAL_TOPIC, "one Approval");
        require(abi.decode(logs[0].data, (uint256)) == 3, "approval value is not the replacement");
    }

    /// @dev The last approval always wins, whatever came before, including the unlimited sentinel.
    function testFuzzLastApprovalWins(uint256 first, uint256 second) public {
        token.approve(SPENDER, first);
        require(token.allowance(address(this), SPENDER) == first, "first approval");
        token.approve(SPENDER, second);
        require(token.allowance(address(this), SPENDER) == second, "second approval");
        require(token.allowance(SPENDER, address(this)) == 0 && token.allowance(address(this), BOB) == 0, "leak");
    }

    /// @dev Above a finite allowance, by any excess, the spend reverts naming the allowance and
    /// leaves allowance and balances untouched.
    function testFuzzSpendAboveFiniteAllowanceReverts(uint256 rawAllowance, uint256 rawExcess) public {
        uint256 allowed = rawAllowance % MAX; // finite: never the unlimited sentinel
        uint256 amount = allowed + 1 + (rawExcess % (MAX - allowed));
        token.approve(SPENDER, allowed);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, allowed, amount)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, amount);
        require(token.allowance(address(this), SPENDER) == allowed, "allowance changed");
        require(token.balanceOf(ALICE) == 0 && token.balanceOf(address(this)) == SUPPLY, "balances changed");
    }

    /// @dev Spending in several steps consumes a finite allowance exactly, and never a unit more.
    function testFuzzAllowanceIsConsumedExactlyAcrossSteps(uint256 rawAllowance, uint256 rawSteps) public {
        uint256 allowed = rawAllowance % (SUPPLY + 1);
        uint256 steps = 1 + (rawSteps % 8);
        token.approve(SPENDER, allowed);
        uint256 spent;
        for (uint256 i; i < steps; ++i) {
            uint256 part = (allowed - spent) / (steps - i);
            vm.prank(SPENDER);
            require(token.transferFrom(address(this), ALICE, part), "step");
            spent += part;
            require(token.allowance(address(this), SPENDER) == allowed - spent, "allowance after step");
        }
        require(spent == allowed && token.balanceOf(ALICE) == allowed, "allowance not fully consumed");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
    }

    /// @dev Spenders are isolated: spending through one leaves every other allowance as set.
    function testFuzzSpendersAreIsolated(uint256 rawA, uint256 rawB, uint256 rawAmount) public {
        uint256 allowedA = rawA % (SUPPLY + 1);
        uint256 allowedB = rawB % MAX;
        uint256 amount = rawAmount % (allowedA + 1);
        token.approve(SPENDER, allowedA);
        token.approve(BOB, allowedB);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, amount);
        require(token.allowance(address(this), SPENDER) == allowedA - amount, "spender A");
        require(token.allowance(address(this), BOB) == allowedB, "spender B touched");
        require(token.allowance(ALICE, SPENDER) == 0 && token.allowance(ALICE, BOB) == 0, "recipient gained");
    }
}
