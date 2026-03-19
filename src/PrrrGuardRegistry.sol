// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract PrrrGuardRegistry {
    uint256 public constant MIN_STAKE = 0.01 ether;

    struct Watcher {
        address addr;
        uint256 stake;
        uint256 reportsSubmitted;
        uint256 reportsWon;
        bool    active;
    }

    mapping(address => Watcher) public watchers;
    uint256 public watcherCount;

    event WatcherRegistered(address indexed watcher, uint256 stake);
    event WatcherDeregistered(address indexed watcher, uint256 stake);

    function register() external payable {
        require(msg.value >= MIN_STAKE, "Insufficient stake");
        require(!watchers[msg.sender].active, "Already registered");
        watchers[msg.sender] = Watcher(msg.sender, msg.value, 0, 0, true);
        watcherCount++;
        emit WatcherRegistered(msg.sender, msg.value);
    }

    function deregister() external {
        Watcher storage w = watchers[msg.sender];
        require(w.active, "Not registered");
        uint256 stake = w.stake;
        w.stake = 0;
        w.active = false;
        watcherCount--;
        (bool success,) = payable(msg.sender).call{value: stake}("");
        require(success, "Transfer failed");
        emit WatcherDeregistered(msg.sender, stake);
    }
}
