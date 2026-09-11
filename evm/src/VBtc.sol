// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {InsufficientAllowance} from "./imports/Types.sol";
import {IVBtcRange} from "./imports/Interfaces.sol";
import {BitcoinTx} from "./imports/BitcoinTx.sol";

contract VBtc {
    string public constant name     = "QuidMint vBTC";
    string public constant symbol   = "vBTC";

    uint8  public constant decimals = 8;

    address public immutable VAULT;

    address public immutable WBTC;

    mapping(address => mapping(address => uint)) public allowance;

    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    event Redeemed(address indexed holder, uint sats, bytes p2trScript);

    error BadPayoutKey();

    constructor(address vault, address wbtc) { VAULT = vault; WBTC = wbtc; }

    function totalSupply() public view returns (uint) { return IVBtcRange(VAULT).totalShares(); }

    function balanceOf(address user) public view returns (uint) {
        return IVBtcRange(VAULT).sharesOf(user);
    }

    function asset() external view returns (address) { return WBTC; }
    function convertToAssets(uint shares) external pure returns (uint) { return shares; }
    function convertToShares(uint assets) external pure returns (uint) { return assets; }

    function transfer(address to, uint amt) external returns (bool) {
        IVBtcRange(VAULT).transferShares(msg.sender, to, amt);
        emit Transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint amt) external returns (bool) {
        uint allowed = allowance[from][msg.sender];
        if (allowed != type(uint).max) {
            if (allowed < amt) revert InsufficientAllowance();
            unchecked { allowance[from][msg.sender] = allowed - amt; }
        }
        IVBtcRange(VAULT).transferShares(from, to, amt);
        emit Transfer(from, to, amt);
        return true;
    }

    function approve(address spender, uint amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }

    function redeemVBtc(uint sats, bytes32 p2trKey) external returns (bool) {
        if (!BitcoinTx.isValidXOnlyKey(p2trKey)) revert BadPayoutKey();
        IVBtcRange(VAULT).redeemVBtc(msg.sender, sats);
        emit Transfer(msg.sender, address(0), sats);
        emit Redeemed(msg.sender, sats, BitcoinTx.buildTaprootScriptPubKey(p2trKey));
        return true;
    }
}
