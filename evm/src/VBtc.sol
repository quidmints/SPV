// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
contract VBtc {
    string public constant name     = "QuidMint vBTC";
    string public constant symbol   = "vBTC";
    uint8  public constant decimals = 8;
    uint public totalSupply;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;
    address public immutable VAULT;
    address public immutable WBTC;
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
    error NotVault();
    error InsufficientBalance();
    constructor(address vault, address wbtc) { VAULT = vault; WBTC = wbtc; }
    modifier onlyVault() { if (msg.sender != VAULT) revert NotVault(); _; }
    function asset() external view returns (address) { return WBTC; }
    function convertToAssets(uint shares) external pure returns (uint) { return shares; }
    function convertToShares(uint assets) external pure returns (uint) { return assets; }
    function transfer(address to, uint amt) external returns (bool) {
        uint bal = balanceOf[msg.sender];
        if (bal < amt) revert InsufficientBalance();
        unchecked { balanceOf[msg.sender] = bal - amt; }
        balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt);
        return true;
    }
    function transferFrom(address from, address to, uint amt) external returns (bool) {
        uint allowed = allowance[from][msg.sender];
        if (allowed != type(uint).max) {
            if (allowed < amt) revert InsufficientBalance();
            unchecked { allowance[from][msg.sender] = allowed - amt; }
        }
        uint bal = balanceOf[from];
        if (bal < amt) revert InsufficientBalance();
        unchecked { balanceOf[from] = bal - amt; }
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);
        return true;
    }
    function approve(address spender, uint amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }
    function mintTo(address to, uint sats) external onlyVault {
        balanceOf[to] += sats;
        totalSupply   += sats;
        emit Transfer(address(0), to, sats);
    }
    function burnFrom(address from, uint sats) external onlyVault {
        uint bal = balanceOf[from];
        if (bal < sats) revert InsufficientBalance();
        unchecked { balanceOf[from] = bal - sats; totalSupply -= sats; }
        emit Transfer(from, address(0), sats);
    }
}
