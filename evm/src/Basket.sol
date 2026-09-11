// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Aux} from "./Aux.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {SortedSetLib} from "./imports/Types.sol";

import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {ICollection} from "./imports/Interfaces.sol";
import {Types, BtcVaultPinned, Unauthorized} from "./imports/Types.sol";
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

contract Basket is ERC20, ERC6909,
    ReentrancyGuard, OApp {

    uint32 public constant SOLANA_EID = 30168;

    uint constant SD_RATE = 1e12;

    uint constant OFT_MSG_LEN = 40;

    error BadBridgeMessage();
    event BridgeReceived(bytes32 indexed guid, address indexed to, uint amount, uint month);
    event BridgeSent(bytes32 indexed guid, address indexed from, bytes32 to, uint amount);
    using SortedSetLib for SortedSetLib.Set;
    error InsufficientUnlocked();

    uint internal _deployed;
    uint constant CAP = 600_000 * 1e18;
    uint internal seeded;

    function target() external view returns (uint) { return seeded; }
    Aux public AUX;
    address payable public RANGE;

    address constant F8N = 0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405;
    uint public constant ANGEL = 16508;

    modifier onlyUs() {
        if (!auth(msg.sender)) revert Unauthorized(); _;
    }
    function auth(address who) public view returns (bool) {

        return (who == address(AUX) || who == RANGE || who == BTC_VAULT);
    }

    address public BTC_VAULT;
    function setBtcVault(address b) external {
        if (msg.sender != owner()) revert Unauthorized();
        if (BTC_VAULT != address(0)) revert BtcVaultPinned();
        BTC_VAULT = b;
    }

    mapping(uint => uint) public totalSupplies;
    mapping(address => uint) internal tranche;

    function trancheTotal() external view returns (uint) {
        return seeded;
    }

    constructor(address _range, address _aux, address _lzEndpoint)
        ERC20("QU!D", "QUI")
        OApp(_lzEndpoint, msg.sender)
        Ownable(msg.sender) {
        RANGE = payable(_range);
        AUX = Aux(payable(_aux));
        _deployed = block.timestamp;

        require(ICollection(F8N).getApproved(ANGEL) == address(AUX), "angel");
    }

    function bridgeToSolana(bytes32 to, uint amount)
        external payable nonReentrant returns (bytes32) {
        if (to == bytes32(0)) revert BadBridgeMessage();
        uint amountSD = amount / SD_RATE;
        if (amountSD == 0) revert BadBridgeMessage();

        uint burned = _transferHelper(msg.sender, address(0), amountSD * SD_RATE);
        if (burned == 0) revert InsufficientUnlocked();

        uint sentSD = burned / SD_RATE;
        if (sentSD == 0) revert InsufficientUnlocked();

        bytes memory message = abi.encodePacked(to, uint64(sentSD));
        bytes memory options = "";
        MessagingFee memory fee = _quote(SOLANA_EID, message, options, false);
        require(msg.value >= fee.nativeFee, "fee");

        bytes32 guid = _lzSend(SOLANA_EID, message, options, fee, msg.sender).guid;
        if (msg.value > fee.nativeFee) {
            (bool ok,) = payable(msg.sender).call{value: msg.value - fee.nativeFee}("");
            require(ok);
        }
        emit BridgeSent(guid, msg.sender, to, sentSD * SD_RATE);
        return guid;
    }

    function _lzReceive(Origin calldata _origin, bytes32 _guid,
        bytes calldata _message, address, bytes calldata) internal override {
        if (_origin.srcEid != SOLANA_EID) revert Unauthorized();
        if (_message.length != OFT_MSG_LEN) revert BadBridgeMessage();

        address to = address(uint160(uint(bytes32(_message[0:32]))));
        uint amount = uint(uint64(bytes8(_message[32:40]))) * SD_RATE;
        if (to == address(0) || amount == 0) revert BadBridgeMessage();

        uint month = currentMonth() + 1;
        _mint(to, month, amount);
        emit BridgeReceived(_guid, to, amount, month);
    }

    function immatureBalanceOf(address who) public view returns (uint bal) {
        uint cm = currentMonth();
        for (uint m = cm + 1; m <= cm + 13; ++m) bal += balanceOf[who][m];
    }

    function immatureSupply() public view returns (uint s) {
        uint cm = currentMonth();
        for (uint m = cm + 1; m <= cm + 13; ++m) s += totalSupplies[m];
    }

    function matureSupply() public view returns (uint) {
        uint imm = immatureSupply();
        uint ts = totalSupply();
        return ts > imm ? ts - imm : 0;
    }

    mapping(address => SortedSetLib.Set) private perMonth;
    function currentMonth() public view returns (uint month) {
        month = (block.timestamp - _deployed) / BasketLib.MONTH;
    }

    function turn(address from, uint value) external
        onlyUs returns (uint sent, uint seedBurned) {
        uint seedBefore = tranche[from];
        sent = _transferHelper(from, address(0), value);
        seedBurned = seedBefore - tranche[from];
    }

    function _mint(address receiver,
        uint when, uint amount)
        internal override {
        totalSupplies[when] += amount;
        perMonth[receiver].insert(when);
        super._update(address(0), receiver, amount);
        balanceOf[receiver][when] += amount;
        emit Transfer(msg.sender, address(0),
                    receiver, when, amount);
    }

    function mint(address pledge, uint amount,
        address token, uint when) external
        nonReentrant returns (uint normalized) {
        uint nextMonth = currentMonth() + 1;
        if (auth(msg.sender)) {

            if (currentMonth() >= 12) {
                (uint total,) = AUX.get_metrics(true);
                total -= Math.min(total, AUX.depegLoss());

                total -= Math.min(total, AUX.illiquidLossFlagging());

                uint headroom = total > totalSupply()
                              ? total - totalSupply() : 0;
                if (amount > headroom) {

                    if (headroom > 0) _mint(pledge,
                        nextMonth, headroom);

                    _mint(pledge, nextMonth + 1,
                           amount - headroom);
                    return amount;
                }
            }
            if (amount > 0) _mint(pledge,
                nextMonth, amount);
                    return amount;
        }
        uint deposited = AUX.deposit(
               pledge, token, amount);

        normalized = _finishMint(pledge, deposited,
                          IERC20(token).decimals(),
                                  when, nextMonth);
    }

    function _finishMint(address pledge, uint deposited,
        uint decimals, uint when, uint nextMonth)
        internal returns (uint normalized) {

        (uint total, uint avgYield) = AUX.get_metrics(true);

        total -= Math.min(total, AUX.depegLoss());

        uint maxFwd;
        if (currentMonth() < 12) {
            maxFwd = 12;
        } else {
            uint bufBps = total > totalSupply()
                ? (total - totalSupply()) * 10_000 / total : 0;
            maxFwd = bufBps >= 500 ? 12
                   : bufBps >= 300 ? 6
                   : bufBps >= 150 ? 3
                   : 1;
        }
        uint month = Math.max(Math.min(when,
                nextMonth + maxFwd), nextMonth);
        bool isSeed = month == 13 && seeded < CAP;
        uint tgtMonth = month;
        (normalized, month) = BasketLib.calcMintYield(deposited,
            decimals, tgtMonth, nextMonth, avgYield, isSeed);

        uint mature = matureSupply();

        total -= Math.min(total, decimals < 18 ? deposited * (10 ** (18 - decimals)) : deposited);
        if (mature > 0 && total > 0 && total < mature)
            normalized = Math.mulDiv(normalized, mature, total);

        if (isSeed && seeded + normalized > CAP) {
            isSeed = false;
            (normalized, month) = BasketLib.calcMintYield(deposited,
                decimals, tgtMonth, nextMonth, avgYield, false);

            if (mature > 0 && total > 0 && total < mature)
                normalized = Math.mulDiv(normalized, mature, total);
        }

        if (isSeed) { seeded += normalized;
            tranche[pledge] += normalized;
        }
        _mint(pledge, month, normalized);
    }

    function transfer(address to,
        uint value) public override returns (bool) {
        require(value == _transferHelper(msg.sender,
                          to, value)); return true;
    }

    function transfer(address to, uint256, uint256 amount)
        public override returns (bool) {
        require(amount == _transferHelper(msg.sender, to, amount));
        return true;
    }

    function transferFrom(address from, address to, uint256, uint256 amount)
        public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _transferHelper(from, to, amount); return true;
    }

    function transferFrom(address from,
        address to, uint value) public
        override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transferHelper(from, to, value); return true;
    }

    function _transferHelper(address from, address to,
        uint amount) internal returns (uint sent) {
        if (super.balanceOf(from) < amount)
            revert InsufficientUnlocked();

        uint[] memory batches = perMonth[from].getSortedSet();
        bool turning = to == address(0); int i = turning
            ? BasketLib.matureBatches(
                        batches, block.timestamp, _deployed):
                                     int(batches.length - 1);
        sent = _moveBatches(from, to, amount, turning, batches, i);
        if (sent > 0) { super._update(from, to, sent);
            if (tranche[from] > 0) {
                uint seed = Math.min(sent,
                  tranche[from]);
                tranche[from] -= seed;
                if (to == address(0)) {

                    seeded -= Math.min(seeded, seed);
                } else tranche[to] += seed;
            }
        }
    }

    function _moveBatches(address from, address to, uint amount, bool turning,
        uint[] memory batches, int i) private returns (uint sent) {
        while (amount > 0 && i >= 0) {
            uint k = batches[uint(i)];
            uint amt = balanceOf[from][k];
            if (amt > 0) {
                amt = Math.min(amount, amt);
                balanceOf[from][k] -= amt;
                if (!turning) {
                    perMonth[to].insert(k);
                    balanceOf[to][k] += amt;
                } else
                    totalSupplies[k] -= amt;
                if (balanceOf[from][k] == 0)
                    perMonth[from].remove(k);
                amount -= amt; sent += amt;
            } i -= 1;
        }
    }
}
