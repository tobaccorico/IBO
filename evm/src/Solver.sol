// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Types} from "./imports/Types.sol";

/// @notice Bebop JAM settlement — actual on-chain interface
interface IJamSettlement {
    function settle(
        Types.JamOrder calldata order,
        bytes calldata signature,                // raw EIP-712 sig bytes
        Types.Interaction[] calldata interactions,// solver's swap route
        bytes memory hooksData,                  // ABI-encoded hooks (or "")
        address balanceRecipient                 // where taker sell tokens go
    ) external payable;
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
/// @notice Flash-loan arbitrage solver for Bebop JAM settlements.
/// @dev Flow: borrow from Aux → receive taker's sell tokens as balanceRecipient
///      → interactions swap them into buy tokens → settlement sends buy tokens
///      to taker → we keep excess → repay Aux with principal + profit share.
contract JamSolver is Ownable {
    bytes32 constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public immutable aux;
    address public jamSettlement;

    error Unauthorized();
    error SettlementFailed();
    error InsufficientProfit();

    event Settled(
        address indexed token,
        uint256 borrowed,
        uint256 returned,
        uint256 profit
    );

    constructor(
        address _aux,
        address _jamSettlement
    ) Ownable(msg.sender) {
        aux = _aux;
        jamSettlement = _jamSettlement;
    }

    /// @notice Execute a JAM settlement using Aux flash loan
    /// @param token       Token to borrow from Aux
    /// @param amount      Amount to borrow
    /// @param shareBps    Profit share to Aux (5000 = 50%)
    /// @param order       Bebop JAM order
    /// @param signature   Raw EIP-712 taker signature
    /// @param interactions Swap route for settlement
    /// @param hooksData   ABI-encoded hooks (pass "" if none)
    function solve(
        address token,
        uint256 amount,
        uint16 shareBps,
        Types.JamOrder calldata order,
        bytes calldata signature,
        Types.Interaction[] calldata interactions,
        bytes calldata hooksData
    ) external onlyOwner {
        bytes memory data = abi.encode(
            order, signature, interactions, hooksData
        );
        IAux(aux).flashLoan(token, amount, shareBps, data);
    }

    /// @notice ERC-3156 callback — called by Aux during flashLoan
    /// @dev Decodes settlement params, approves tokens, calls settle,
    ///      verifies profit, returns everything to Aux.
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint16  /*shareBps*/,
        bytes calldata data
    ) external returns (bytes32) {
        if (msg.sender != aux) revert Unauthorized();
        if (initiator != address(this)) revert Unauthorized();

        (
            Types.JamOrder memory order,
            bytes memory signature,
            Types.Interaction[] memory interactions,
            bytes memory hooksData
        ) = abi.decode(
            data,
            (Types.JamOrder, bytes, Types.Interaction[], bytes)
        );

        // Approve settlement to pull the borrowed tokens
        IERC20(token).approve(jamSettlement, amount);

        // Settle: sell tokens flow solver→settlement, buy tokens→receiver.
        // We are the balanceRecipient, so taker's sell tokens come to us.
        // The interactions route them into buy tokens for the taker.
        // Any excess of the borrowed token remains in this contract.
        IJamSettlement(jamSettlement).settle(
            order,
            signature,
            interactions,
            hooksData,
            address(this)  // balanceRecipient = this solver
        );

        // Verify profit: we must have at least `amount` back
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientProfit();

        uint256 profit = balance - amount;

        // Return everything to Aux (principal + profit)
        IERC20(token).transfer(aux, balance);

        emit Settled(token, amount, balance, profit);
        return CALLBACK_SUCCESS;
    }

    /// @notice Update JAM settlement address
    function setJamSettlement(address _jamSettlement) external onlyOwner {
        jamSettlement = _jamSettlement;
    }

    /// @notice Rescue stuck ERC20 tokens
    function rescue(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /// @notice Rescue stuck ETH
    function rescueETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    receive() external payable {}
}
