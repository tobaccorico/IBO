// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Mock Rover for testing
contract MockRover {
    mapping(address => uint) public deposits;
    
    function deposit(uint) external payable {
        deposits[msg.sender] += msg.value;
    }
    
    function withdraw(uint amount) external {
        require(deposits[msg.sender] >= amount, "Insufficient");
        deposits[msg.sender] -= amount;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success);
    }
    
    receive() external payable {}
}