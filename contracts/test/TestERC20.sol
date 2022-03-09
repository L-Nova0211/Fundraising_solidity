// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.6.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestERC20 is ERC20 {
    constructor(uint amount) ERC20('Test ERC20', 'TEST') public {
        _mint(msg.sender, amount);
    }
}
