// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Nightshift} from "../src/Nightshift.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Only the Foundry cheatcodes used here; no external test dependency.
interface Vm {
    function prank(address sender) external;
    function deal(address account, uint256 newBalance) external;
}

/// @notice Drives the token with random, bounded call sequences from several actors and keeps a
/// deliberately simple model of what the token should now hold and allow. The handler never
/// reverts itself: every outcome, expected or not, is recorded in a counter the invariants read.
/// @dev Expected reverts are caught and their revert data compared with the ERC-6093 error the
/// token must raise, so a failure path that silently succeeds, or fails for the wrong reason, is a
/// counted violation rather than an ignored revert.
contract NightshiftHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    Nightshift public immutable token;
    address[] private actors;

    /// @dev Model: what each account should hold and what each owner should allow each spender.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    /// @dev Tokens sent to the token contract itself: stranded, but still part of the supply.
    uint256 public ghostStranded;

    /// @dev A call the model says must succeed reverted.
    uint256 public unexpectedReverts;
    /// @dev A call the model says must revert succeeded.
    uint256 public unexpectedSuccesses;
    /// @dev A call reverted as expected but with the wrong error or arguments.
    uint256 public wrongRevertReasons;
    /// @dev A successful call returned false or left a balance the model did not predict.
    uint256 public postconditionViolations;

    /// @dev Per-function call counters, so a vacuous run can be told from a real one.
    mapping(string => uint256) public calls;

    string[6] private adminSignatures = [
        "mint(address,uint256)",
        "burn(uint256)",
        "burnFrom(address,uint256)",
        "pause()",
        "blacklist(address)",
        "transferOwnership(address)"
    ];

    constructor() {
        token = new Nightshift();
        actors.push(address(this));
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        actors.push(address(0xDA4E));
        ghostBalance[address(this)] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _revertedWith(bytes memory reason, bytes memory expected) private returns (bool) {
        if (keccak256(reason) == keccak256(expected)) return true;
        wrongRevertReasons++;
        return false;
    }

    // ---------------------------------------------------------------- happy paths

    /// @dev Any actor sends any amount up to its balance to any actor, itself included.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls["transfer"]++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = amount % (token.balanceOf(from) + 1);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok) postconditionViolations++;
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            if (from == to) {
                if (token.balanceOf(from) != fromBefore) postconditionViolations++;
            } else if (token.balanceOf(from) != fromBefore - amount || token.balanceOf(to) != toBefore + amount) {
                postconditionViolations++;
            }
        } catch {
            unexpectedReverts++;
        }
    }

    /// @dev A zero-amount transfer is legal from anyone, even an account that holds nothing.
    function transferZero(uint256 fromSeed, uint256 toSeed) external {
        calls["transferZero"]++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, 0) returns (bool ok) {
            if (!ok || token.balanceOf(from) != fromBefore || token.balanceOf(to) != toBefore) {
                postconditionViolations++;
            }
        } catch {
            unexpectedReverts++;
        }
    }

    /// @dev Tokens sent to the token contract are stranded but must still be counted.
    function transferToTokenContract(uint256 fromSeed, uint256 amount) external {
        calls["transferToTokenContract"]++;
        address from = _actor(fromSeed);
        amount = amount % (token.balanceOf(from) + 1);
        vm.prank(from);
        try token.transfer(address(token), amount) returns (bool ok) {
            if (!ok) postconditionViolations++;
            ghostBalance[from] -= amount;
            ghostStranded += amount;
        } catch {
            unexpectedReverts++;
        }
    }

    /// @dev Approvals take the whole uint256 range, so the unlimited sentinel is reached often.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        calls["approve"]++;
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            if (!ok) postconditionViolations++;
            ghostAllowance[owner][spender] = amount;
        } catch {
            unexpectedReverts++;
        }
    }

    /// @dev A spender moves up to min(allowance, balance) on an owner's behalf.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        calls["transferFrom"]++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        uint256 cap = allowed < balance ? allowed : balance;
        amount = amount % (cap + 1);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            if (!ok) postconditionViolations++;
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
            if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        } catch {
            unexpectedReverts++;
        }
    }

    // ---------------------------------------------------------------- failure paths

    /// @dev Any amount above the balance, up to the maximum, must revert with the exact error.
    function transferOverdraw(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        calls["transferOverdraw"]++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = balance + 1 + (excess % (type(uint256).max - balance));
        vm.prank(from);
        try token.transfer(to, amount) {
            unexpectedSuccesses++;
        } catch (bytes memory reason) {
            _revertedWith(
                reason, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
            );
        }
    }

    /// @dev Sending to the zero address must revert, for any amount including zero.
    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        calls["transferToZeroAddress"]++;
        address from = _actor(fromSeed);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            unexpectedSuccesses++;
        } catch (bytes memory reason) {
            _revertedWith(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        }
    }

    /// @dev Approving the zero address must revert and leave no allowance behind.
    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        calls["approveZeroSpender"]++;
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            unexpectedSuccesses++;
        } catch (bytes memory reason) {
            _revertedWith(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        }
        if (token.allowance(owner, address(0)) != 0) postconditionViolations++;
    }

    /// @dev One unit above the allowance must revert on the allowance before the balance is read.
    /// An unlimited allowance is first replaced by a finite one so the bound exists.
    function transferFromOverAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        calls["transferFromOverAllowance"]++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            allowed = excess % SUPPLY;
            vm.prank(owner);
            token.approve(spender, allowed);
            ghostAllowance[owner][spender] = allowed;
        }
        uint256 amount = allowed + 1 + (excess % (type(uint256).max - allowed));
        uint256 ownerBefore = token.balanceOf(owner);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            unexpectedSuccesses++;
        } catch (bytes memory reason) {
            _revertedWith(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        }
        if (token.allowance(owner, spender) != allowed || token.balanceOf(owner) != ownerBefore) {
            postconditionViolations++;
        }
    }

    /// @dev With an unlimited allowance, one unit above the owner's balance must revert on the
    /// balance, and the allowance must stay unlimited.
    function transferFromOverBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) external {
        calls["transferFromOverBalance"]++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghostAllowance[owner][spender] = type(uint256).max;
        uint256 balance = token.balanceOf(owner);
        uint256 amount = balance + 1 + (excess % (type(uint256).max - balance));
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            unexpectedSuccesses++;
        } catch (bytes memory reason) {
            _revertedWith(
                reason, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
        }
        if (token.allowance(owner, spender) != type(uint256).max) postconditionViolations++;
    }

    /// @dev No actor, the deployer included, reaches a mint, burn, pause, blacklist or ownership
    /// entry point: every such call must fail and move nothing.
    function adminCall(uint256 callerSeed, uint256 signatureSeed, uint256 argument) external {
        calls["adminCall"]++;
        address caller = _actor(callerSeed);
        address target = _actor(argument);
        string memory signature = adminSignatures[signatureSeed % adminSignatures.length];
        bytes memory data = abi.encodeWithSignature(signature, target, argument);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        if (ok) unexpectedSuccesses++;
    }

    /// @dev The token has no receive or fallback: ether sent to it must bounce.
    function sendEther(uint256 amount) external {
        calls["sendEther"]++;
        amount = 1 + (amount % 10 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(token).call{value: amount}("");
        if (ok) unexpectedSuccesses++;
    }
}

/// @notice Properties that must hold after every random call sequence the handler produces.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract NightshiftInvariantTest {
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    NightshiftHandler private handler;
    Nightshift private token;

    function setUp() public {
        handler = new NightshiftHandler();
        token = handler.token();
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory targets) {
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = NightshiftHandler.transfer.selector;
        selectors[1] = NightshiftHandler.transferZero.selector;
        selectors[2] = NightshiftHandler.transferToTokenContract.selector;
        selectors[3] = NightshiftHandler.approve.selector;
        selectors[4] = NightshiftHandler.transferFrom.selector;
        selectors[5] = NightshiftHandler.transferOverdraw.selector;
        selectors[6] = NightshiftHandler.transferToZeroAddress.selector;
        selectors[7] = NightshiftHandler.approveZeroSpender.selector;
        selectors[8] = NightshiftHandler.transferFromOverAllowance.selector;
        selectors[9] = NightshiftHandler.transferFromOverBalance.selector;
        selectors[10] = NightshiftHandler.adminCall.selector;
        selectors[11] = NightshiftHandler.sendEther.selector;
        targets = new FuzzSelector[](1);
        targets[0] = FuzzSelector(address(handler), selectors);
    }

    /// @dev Fixed supply: no sequence mints or burns.
    function invariant_totalSupplyNeverChanges() public view {
        require(token.totalSupply() == SUPPLY, "total supply changed");
        require(token.INITIAL_SUPPLY() == SUPPLY, "supply constant changed");
    }

    /// @dev Conservation: what every actor holds, plus what was stranded in the token contract,
    /// is exactly the supply. Nothing leaks to the zero address.
    function invariant_supplyIsFullyAccountedFor() public view {
        uint256 sum;
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            sum += token.balanceOf(handler.actorAt(i));
        }
        sum += token.balanceOf(address(token));
        require(sum == token.totalSupply(), "balances do not sum to the supply");
        require(token.balanceOf(address(0)) == 0, "zero address holds tokens");
    }

    /// @dev Every balance equals what the model predicts from the transfers that succeeded.
    function invariant_balancesMatchModel() public view {
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            address actor = handler.actorAt(i);
            require(token.balanceOf(actor) == handler.ghostBalance(actor), "balance drifted from model");
        }
        require(token.balanceOf(address(token)) == handler.ghostStranded(), "stranded balance drifted");
    }

    /// @dev Every allowance equals what the model predicts: set by approve, decremented by finite
    /// spending, untouched when unlimited, never touched by a failed call.
    function invariant_allowancesMatchModel() public view {
        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            address owner = handler.actorAt(i);
            for (uint256 j; j < count; ++j) {
                address spender = handler.actorAt(j);
                require(
                    token.allowance(owner, spender) == handler.ghostAllowance(owner, spender),
                    "allowance drifted from model"
                );
            }
            require(token.allowance(owner, address(0)) == 0, "zero spender has an allowance");
        }
    }

    /// @dev No happy-path call reverted, no failure-path call succeeded, every revert carried the
    /// exact ERC-6093 error, and every successful call returned true with the predicted effect.
    function invariant_everyCallHadItsExpectedOutcome() public view {
        require(handler.unexpectedReverts() == 0, "a valid call reverted");
        require(handler.unexpectedSuccesses() == 0, "an invalid call succeeded");
        require(handler.wrongRevertReasons() == 0, "a call reverted with the wrong error");
        require(handler.postconditionViolations() == 0, "a call had an unexpected effect");
    }

    function invariant_metadataIsImmutable() public view {
        require(keccak256(bytes(token.name())) == keccak256("NIGHTSHIFT"), "name changed");
        require(keccak256(bytes(token.symbol())) == keccak256("SHIFT"), "symbol changed");
        require(token.decimals() == 18, "decimals changed");
    }

    function invariant_tokenHoldsNoEther() public view {
        require(address(token).balance == 0, "token accepted ether");
    }

    /// @dev Every handler entry point runs once, from a fixed state, without an unexpected outcome:
    /// the invariant run above cannot be vacuous because of a handler that silently misfires.
    function testHandlerEntryPointsAreExercisable() public {
        handler.transfer(0, 1, 123 ether);
        handler.transferZero(3, 4);
        handler.transferToTokenContract(0, 1 ether);
        handler.approve(1, 2, 50 ether);
        handler.transferFrom(2, 1, 3, 20 ether);
        handler.transferOverdraw(1, 2, 7);
        handler.transferToZeroAddress(0, 1);
        handler.approveZeroSpender(0, 5);
        handler.transferFromOverAllowance(2, 1, 3, 9);
        handler.transferFromOverBalance(4, 3, 0, 11);
        handler.adminCall(0, 0, 100);
        handler.adminCall(2, 3, 1);
        handler.sendEther(1 ether);
        string[12] memory names = [
            "transfer",
            "transferZero",
            "transferToTokenContract",
            "approve",
            "transferFrom",
            "transferOverdraw",
            "transferToZeroAddress",
            "approveZeroSpender",
            "transferFromOverAllowance",
            "transferFromOverBalance",
            "adminCall",
            "sendEther"
        ];
        for (uint256 i; i < names.length; ++i) {
            require(handler.calls(names[i]) > 0, names[i]);
        }
        invariant_totalSupplyNeverChanges();
        invariant_supplyIsFullyAccountedFor();
        invariant_balancesMatchModel();
        invariant_allowancesMatchModel();
        invariant_everyCallHadItsExpectedOutcome();
        invariant_tokenHoldsNoEther();
        require(token.balanceOf(address(0xA11CE)) == 123 ether - 20 ether, "scripted balances");
        require(token.balanceOf(address(0xCA201)) == 20 ether, "scripted delegated transfer");
        require(token.balanceOf(address(token)) == 1 ether, "scripted stranded amount");
    }
}
