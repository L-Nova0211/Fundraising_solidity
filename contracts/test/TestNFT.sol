// We will be using Solidity version 0.5.3
pragma solidity =0.6.6;
pragma experimental ABIEncoderV2;

// Import the IERC20 interface and and SafeMath library
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC721/ERC721.sol';

contract TestNFT is ERC721 {
    constructor() ERC721('TestERC721', 'TEST') public {
    }

    uint256[] public allocations;
    mapping(address => uint256) public userToAllocation;

    event AllocationSpent(uint256 id, uint256 amount);

    function mint(address to, uint256 value) public {
        allocations.push(value);
        _mint(to, allocations.length - 1);
    }

    function getAvailableAllocation(uint256 id) public view returns (uint256) {
        return allocations[id];
    }

    function spendAllocation(uint256 id, uint256 amount) public {
        uint256 allocation = allocations[id];
        allocations[id] = allocation.sub(amount);
        emit AllocationSpent(id, amount);
    }
}