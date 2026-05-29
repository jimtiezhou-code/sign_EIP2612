// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

interface ITokenReceiver {
    function tokensReceived(address from, uint256 amount) external returns (bool);
}

contract BaseERC20 is ERC20Permit {
    constructor() ERC20("BaseERC20", "BERC20") ERC20Permit("BaseERC20") {
        _mint(msg.sender, 100_000_000 * 10 ** decimals());
    }

    function transferWithCallback(address _to, uint256 _value) public returns (bool success) {
        _transfer(msg.sender, _to, _value);

        if (_to.code.length > 0) {
            require(ITokenReceiver(_to).tokensReceived(msg.sender, _value), "ERC20: callback failed");
        }

        return true;
    }
}
