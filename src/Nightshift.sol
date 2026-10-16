// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title NIGHTSHIFT (SHIFT)
/// @notice Fixed supply ERC-20. The creating account receives the entire supply.
/// @dev No owner, post-deployment minting, burning, fees, or transfer restrictions.
contract Nightshift is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("NIGHTSHIFT", "SHIFT") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
