// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.6.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestStakingToken is ERC20 {
    constructor(uint amount) ERC20('Test Staking Token', 'TEST') public {
        _mint(msg.sender, amount);
    }
}
