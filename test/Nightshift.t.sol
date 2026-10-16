// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Nightshift} from "../src/Nightshift.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Only the Foundry cheatcodes used here; no external test dependency.
interface Vm {
    function prank(address sender) external;
    function expectRevert(bytes calldata data) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
}

/// @dev Models contract deployment by a factory without assuming tx.origin.
contract TokenFactory {
    function deploy() external returns (Nightshift) {
        return new Nightshift();
    }
}

contract NightshiftTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    Nightshift private token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new Nightshift();
    }

    function testMetadataAndInitialAllocation() public view {
        require(keccak256(bytes(token.name())) == keccak256("NIGHTSHIFT"), "name");
        require(keccak256(bytes(token.symbol())) == keccak256("SHIFT"), "symbol");
        require(token.decimals() == 18, "decimals");
        require(token.INITIAL_SUPPLY() == SUPPLY, "supply constant");
        require(token.totalSupply() == SUPPLY, "total supply");
        require(token.balanceOf(address(this)) == SUPPLY, "deployer allocation");
        require(token.balanceOf(ALICE) == 0 && token.balanceOf(address(0)) == 0, "other allocation");
    }

    function testConstructorEmitsMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new Nightshift();
    }

    function testFactoryReceivesEntireSupply() public {
        TokenFactory factory = new TokenFactory();
        Nightshift deployed = factory.deploy();
        require(deployed.balanceOf(address(factory)) == SUPPLY, "factory allocation");
        require(deployed.balanceOf(address(this)) == 0, "factory caller allocation");
        require(deployed.totalSupply() == SUPPLY, "factory supply");
    }

    function testTransferEmitsEventAndDeliversExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 42 ether);
        require(token.transfer(ALICE, 42 ether), "transfer result");
        require(token.balanceOf(ALICE) == 42 ether, "received");
        require(token.balanceOf(address(this)) == SUPPLY - 42 ether, "debited");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    function testFullBalanceTransfer() public {
        require(token.transfer(ALICE, SUPPLY), "transfer result");
        require(token.balanceOf(address(this)) == 0 && token.balanceOf(ALICE) == SUPPLY, "full balance");
    }

    function testZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        require(token.transfer(BOB, 0), "zero transfer");
        require(token.balanceOf(ALICE) == 0 && token.balanceOf(BOB) == 0, "balances changed");
    }

    function testSelfTransferPreservesBalance() public {
        require(token.transfer(address(this), SUPPLY), "self transfer");
        require(token.balanceOf(address(this)) == SUPPLY, "self balance");
    }

    function testTransferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        require(token.balanceOf(address(this)) == SUPPLY, "balance changed");
    }

    function testZeroTransferToZeroAlsoReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function testTransferAboveBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(ALICE, SUPPLY + 1);
        require(token.balanceOf(address(this)) == SUPPLY && token.balanceOf(ALICE) == 0, "balances changed");
    }

    function testApproveOverwriteAndRevoke() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, 50);
        require(token.approve(SPENDER, 50), "approve result");
        require(token.allowance(address(this), SPENDER) == 50, "approval");
        token.approve(SPENDER, 20);
        require(token.allowance(address(this), SPENDER) == 20, "replacement");
        token.approve(SPENDER, 0);
        require(token.allowance(address(this), SPENDER) == 0, "revocation");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
    }

    function testApproveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function testTransferFromSpendsAllowanceAndEmitsTransfer() public {
        token.approve(SPENDER, 100);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 40);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 40), "transferFrom result");
        require(token.allowance(address(this), SPENDER) == 60, "remaining allowance");
        require(token.balanceOf(ALICE) == 40 && token.balanceOf(address(this)) == SUPPLY - 40, "balances");
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, 60);
        require(token.allowance(address(this), SPENDER) == 0, "exhausted allowance");
    }

    function testInfiniteAllowanceIsNotDecremented() public {
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 100);
        require(token.allowance(address(this), SPENDER) == type(uint256).max, "infinite allowance");
    }

    function testTransferFromWithoutApprovalReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        require(token.balanceOf(address(this)) == SUPPLY && token.balanceOf(ALICE) == 0, "balances changed");
    }

    function testTransferFromAboveAllowanceReverts() public {
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 10, 11));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 11);
        require(token.allowance(address(this), SPENDER) == 10, "allowance changed");
        require(token.balanceOf(address(this)) == SUPPLY && token.balanceOf(ALICE) == 0, "balances changed");
    }

    function testTransferFromInsufficientBalanceRollsBackAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 100));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        require(token.allowance(ALICE, SPENDER) == 100, "allowance not rolled back");
        require(token.balanceOf(BOB) == 0, "recipient balance changed");
    }

    function testTransferFromToZeroRollsBackAllowance() public {
        token.approve(SPENDER, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 100);
        require(token.allowance(address(this), SPENDER) == 100, "allowance not rolled back");
        require(token.balanceOf(address(this)) == SUPPLY, "balance changed");
    }

    function testTransferFromZeroSenderReverts() public {
        // Spending even a zero allowance validates its owner before the transfer runs.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
    }

    function testLaunchDistributionAndClaimHaveNoFees() public {
        uint256 swarm = SUPPLY / 10;
        uint256 pool = SUPPLY * 8 / 10;
        token.transfer(ALICE, swarm);
        token.transfer(BOB, pool);
        token.transfer(SPENDER, SUPPLY - swarm - pool);
        vm.prank(ALICE);
        token.transfer(address(this), swarm);
        require(token.balanceOf(ALICE) == 0, "claim balance");
        require(token.balanceOf(address(this)) == swarm, "claim shortfall");
        require(token.balanceOf(BOB) == pool && token.balanceOf(SPENDER) == SUPPLY / 10, "allocation shortfall");
        require(token.totalSupply() == SUPPLY, "supply changed");
    }

    function testNoMintBurnOrAdministrativeEntryPoints() public {
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", ALICE, 100);
        calls[1] = abi.encodeWithSignature("burn(uint256)", 100);
        calls[2] = abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, 100);
        calls[3] = abi.encodeWithSignature("pause()");
        calls[4] = abi.encodeWithSignature("blacklist(address)", ALICE);
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", ALICE);
        calls[6] = abi.encodeWithSignature("upgradeTo(address)", ALICE);
        calls[7] = abi.encodeWithSignature("initialize(address)", ALICE);
        calls[8] = abi.encodeWithSignature("seize(address)", ALICE);
        calls[9] = abi.encodeWithSignature("setMinter(address)", ALICE);
        token.transfer(ALICE, 100);
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerOk,) = address(token).call(calls[i]);
            require(!deployerOk, "deployer admin call succeeded");
            vm.prank(BOB);
            (bool strangerOk,) = address(token).call(calls[i]);
            require(!strangerOk, "stranger admin call succeeded");
        }
        require(token.balanceOf(ALICE) == 100 && token.totalSupply() == SUPPLY, "admin changed balances");
        vm.prank(ALICE);
        token.transfer(BOB, 100);
        require(token.balanceOf(BOB) == 100, "holder frozen");
    }

    function testFuzzTransferConservesSupply(uint256 rawAmount) public {
        uint256 amount = rawAmount % (SUPPLY + 1);
        token.transfer(ALICE, amount);
        require(token.balanceOf(ALICE) == amount, "fuzz received");
        require(token.balanceOf(address(this)) == SUPPLY - amount, "fuzz debited");
        vm.prank(ALICE);
        token.transfer(address(this), amount);
        require(token.balanceOf(address(this)) == SUPPLY && token.balanceOf(ALICE) == 0, "fuzz roundtrip");
        require(token.totalSupply() == SUPPLY, "fuzz supply");
    }

    function testFuzzDelegatedTransfer(uint256 rawAllowance, uint256 rawAmount) public {
        uint256 approved = rawAllowance % (SUPPLY + 1);
        uint256 amount = rawAmount % (approved + 1);
        token.approve(SPENDER, approved);
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, amount), "fuzz delegated result");
        require(token.allowance(address(this), SPENDER) == approved - amount, "fuzz allowance");
        require(token.balanceOf(ALICE) == amount && token.balanceOf(address(this)) == SUPPLY - amount, "fuzz balances");
        require(token.totalSupply() == SUPPLY, "fuzz supply");
    }

    function testFuzzOverdrawAlwaysReverts(uint256 rawExcess) public {
        uint256 amount = SUPPLY + 1 + (rawExcess % (type(uint256).max - SUPPLY));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        token.transfer(ALICE, amount);
        require(token.balanceOf(address(this)) == SUPPLY && token.totalSupply() == SUPPLY, "fuzz overdraw state");
    }

    /// @dev Arbitrary sequences include self transfers, zero amounts, and repeated actors.
    function testFuzzTransferSequenceConservesAllBalances(uint256 seed) public {
        address[4] memory actors = [address(this), ALICE, BOB, SPENDER];
        for (uint256 i; i < 32; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address from = actors[seed % actors.length];
            address to = actors[(seed >> 8) % actors.length];
            uint256 amount = (seed >> 16) % (token.balanceOf(from) + 1);
            vm.prank(from);
            require(token.transfer(to, amount), "sequence transfer");
            uint256 sum;
            for (uint256 j; j < actors.length; ++j) {
                sum += token.balanceOf(actors[j]);
            }
            require(sum == SUPPLY && token.totalSupply() == SUPPLY, "sequence conservation");
        }
    }
}
