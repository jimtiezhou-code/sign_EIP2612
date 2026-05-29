// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITokenReceiver {
    function tokensReceived(address from, uint256 amount) external returns (bool);
}

contract BaseERC20 {
    string public name; 
    string public symbol; 
    uint8 public decimals; 

    uint256 public totalSupply; 

    mapping (address => uint256) balances; 

    mapping (address => mapping (address => uint256)) allowances; 

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        // set name,symbol,decimals,totalSupply
        name = "BaseERC20";
        symbol = "BERC20";
        decimals= 18;
        totalSupply = 100000000 * 10**uint(decimals);
        balances[msg.sender] = totalSupply;
    }


    function balanceOf(address _owner) public view returns (uint256 balance) {
        // write your code here
        return balances[_owner];

    }

    function transfer(address _to, uint256 _value) public returns (bool success) {
        // write your code here
        require(balances[msg.sender] >= _value,"ERC20: transfer amount exceeds balance");
        require(_to != address(0),"_to is invalid");
        balances[msg.sender] -= _value;
        balances[_to] += _value;
        emit Transfer(msg.sender, _to, _value);  
        return true;   
    }

    function transferWithCallback(address _to, uint256 _value) public returns (bool success) {
        require(balances[msg.sender] >= _value, "ERC20: transfer amount exceeds balance");
        require(_to != address(0), "ERC20: transfer to the zero address");

        balances[msg.sender] -= _value;
        balances[_to] += _value;
        emit Transfer(msg.sender, _to, _value);

        if (_to.code.length > 0) {
            require(ITokenReceiver(_to).tokensReceived(msg.sender, _value), "ERC20: callback failed");
        }

        return true;
    }

    function transferFrom(address _from, address _to, uint256 _value) public returns (bool success) {
        // write your code here
        // 校验1：转账金额不能超过发起者的余额
        require(balances[_from] >= _value,"ERC20: transfer amount exceeds balance");
         // 校验2：转账金额不能超过发起者对当前调用者的授权额度
        require(allowances[_from][msg.sender] >= _value,"ERC20: transfer amount exceeds allowance");
        require(_to != address(0),"ERC20: transfer to the zero address");
        allowances[_from][msg.sender] -= _value;
        balances[_from] -= _value;
        balances[_to] += _value;
        
        emit Transfer(_from, _to, _value); 
        return true; 
    }

    function approve(address _spender, uint256 _value) public returns (bool success) {
        // write your code here
        // 为避免旧授权覆盖新授权导致的安全风险，需先将授权额清零再设置
        allowances[msg.sender][_spender] = 0;
        allowances[msg.sender][_spender] = _value;


        emit Approval(msg.sender, _spender, _value); 
        return true; 
    }

    function allowance(address _owner, address _spender) public view returns (uint256 remaining) {   
        // write your code here   
        return allowances[_owner][_spender]; 

    }
}