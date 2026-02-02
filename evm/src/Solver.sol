
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// JamOrder, Signature, JamIntent, JamHooks
import {Types} from "./imports/Types.sol";
/// @notice Bebop JAM settlement interface
interface IJamSettlement {
    function settle(
        Types.JamOrder calldata order,
        Types.Signature calldata signature,
        Types.JamIntent[] calldata interactions,
        Types.JamHooks calldata hooks,
        bytes calldata solverData
    ) external;
}
interface IAux {
    function flashLoan(
        address token,
        uint256 amount,
        uint16 shareBps,
        bytes calldata data
    ) external returns (bool);
}

/// @title JamSolver
/// @notice Flash loan consumer that executes Bebop JAM settlements
/// @dev Borrows from Aux, settles via Bebop, returns principal + profit
contract JamSolver is Ownable {
    bytes32 constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public immutable aux;
    address public jamSettlement;

    error Unauthorized();
    error SettlementFailed();
    error InsufficientProfit();
    event Settled(address indexed token,
        uint256 borrowed, uint256 returned, uint256 profit);
    constructor(address _aux, address _jamSettlement) Ownable(msg.sender) {
        aux = _aux; jamSettlement = _jamSettlement;
    }

    /// @notice Execute a JAM settlement using Aux flash loan
    /// @param token Token to borrow from Aux
    /// @param amount Amount to borrow
    /// @param shareBps Profit share commitment to Aux (5000 = 50% min)
    /// @param order Bebop JAM order
    /// @param signature Order signature
    /// @param interactions Swap interactions
    /// @param hooks Pre/post hooks
    /// @param solverData Solver-specific data
    function solve(address token,
        uint256 amount, uint16 shareBps,
        Types.JamOrder calldata order,
        Types.Signature calldata signature,
        Types.JamIntent[] calldata interactions,
        Types.JamHooks calldata hooks,
        bytes calldata solverData) external onlyOwner {
        // Encode settlement params for callback
        bytes memory data = abi.encode(jamSettlement,
            order, signature, interactions, hooks,
            solverData); IAux(aux).flashLoan(token,
                            amount, shareBps, data);
    } /// @notice callback - executes settlement
    /// @dev Called by Aux during flashLoan...
    function onFlashLoan(address initiator, // solver
        address token, uint256 amount, uint16 shareBps,
        bytes calldata data) external returns (bytes32) {
        if (msg.sender != aux) revert Unauthorized();
        if (initiator != address(this)) revert Unauthorized();
        (address settlement, Types.JamOrder memory order,
            Types.Signature memory signature,
            Types.JamIntent[] memory interactions,
            Types.JamHooks memory hooks,
            bytes memory solverData) = abi.decode(data, (address,
            Types.JamOrder, Types.Signature, Types.JamIntent[],
            Types.JamHooks, bytes )); IERC20(token).approve(
                                         settlement, amount);
        // This should result in us receiving buyTokens
        IJamSettlement(settlement).settle(order,
            signature, interactions, hooks,
            solverData); // what we owe back
        // For simplicity, assume buyToken == sellToken
        // (arb within same token) or the settlement
        // swaps back to the borrowed token
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientProfit();
        uint256 profit = balance - amount;
        IERC20(token).transfer(aux, balance);
        emit Settled(token, amount, balance,
            profit); return CALLBACK_SUCCESS;
    }
    /// @notice Update default JAM settlement address
    function setJamSettlement(address _jamSettlement) external onlyOwner {
        jamSettlement = _jamSettlement;
    }
    /// @notice Rescue stuck tokens
    function rescue(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }
    /// @notice Rescue ETH
    function rescueETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    receive() external payable {}
}
