// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIntake} from "../../src/BurnTracker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public transfers;
    uint256 public lastApproval;
    bool public failTransfers;
    bool public feeOnTransfer;
    address public hook;
    bytes public hookData;
    bool public hookSucceeded;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFailure(bool value) external {
        failTransfers = value;
    }

    function setFee(bool value) external {
        feeOnTransfer = value;
    }

    function setHook(address target, bytes calldata data) external {
        hook = target;
        hookData = data;
    }

    function approve(address to, uint256 amount) external returns (bool) {
        allowance[msg.sender][to] = amount;
        lastApproval = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (failTransfers) return false;
        allowance[from][msg.sender] -= amount;
        if (hook != address(0)) (hookSucceeded,) = hook.call(hookData);
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private returns (bool) {
        if (failTransfers) return false;
        ++transfers;
        balanceOf[from] -= amount;
        balanceOf[to] += feeOnTransfer ? amount - 1 : amount;
        return true;
    }
}

/// @dev Mimics payment, payer recording, selectors and the writer's one 200k-gas callback attempt.
contract MockIntake is IIntake {
    struct Request {
        address payer;
        address target;
        bytes4 selector;
        bytes4 failure;
        bool settled;
    }
    mapping(bytes32 => Request) public requests;
    mapping(bytes32 => uint256) public prices;
    uint256 public nonce;
    address public immutable treasury;
    address public immutable writer;
    uint256 public allowanceAtRequest;
    uint256 public amountAtRequest;
    bytes32 public actionAtRequest;
    bytes32 public bodyHash;
    uint256 public callbackGas;
    bool public revertOrder;
    address public hook;
    bytes public hookData;
    bool public hookSucceeded;
    event Requested(
        bytes32 indexed requestId,
        address indexed payer,
        bytes32 indexed action,
        bytes body,
        address callbackTarget,
        bytes4 callbackSelector,
        address asset,
        uint256 amount
    );

    constructor(address treasury_, address writer_) {
        treasury = treasury_;
        writer = writer_;
    }

    function setPrice(bytes32 action, uint256 amount) external {
        prices[action] = amount;
    }

    function setRevert(bool value) external {
        revertOrder = value;
    }

    function setHook(address target, bytes calldata data) external {
        hook = target;
        hookData = data;
    }

    function priceOf(bytes32 action, address) external view returns (uint256) {
        return prices[action];
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata cb,
        bytes4 failure,
        address token,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(!revertOrder, "order failed");
        require(prices[action] != 0 && amount == prices[action], "price");
        require(body.length != 0 && body.length <= 16_384, "body");
        allowanceAtRequest = IERC20(token).allowance(msg.sender, address(this));
        amountAtRequest = amount;
        actionAtRequest = action;
        bodyHash = keccak256(body);
        require(IERC20(token).transferFrom(msg.sender, treasury, amount), "transfer");
        if (hook != address(0)) (hookSucceeded,) = hook.call(hookData);
        id = keccak256(abi.encode(address(this), ++nonce));
        requests[id] = Request(msg.sender, cb.target, cb.selector, failure, false);
        emit Requested(id, msg.sender, action, body, cb.target, cb.selector, token, amount);
    }

    function complete(bytes32 id, bytes32 hash, string calldata uri) external returns (bool ok) {
        require(msg.sender == writer, "writer");
        Request storage r = requests[id];
        require(!r.settled && r.target != address(0), "request");
        r.settled = true;
        bytes memory data = abi.encodeWithSelector(r.selector, id, hash, uri);
        uint256 beforeGas = gasleft();
        (ok,) = r.target.call{gas: 200_000}(data);
        callbackGas = beforeGas - gasleft();
    }

    function fail(bytes32 id, uint8 status, bytes32 reason) external returns (bool ok) {
        require(msg.sender == writer, "writer");
        Request storage r = requests[id];
        require(!r.settled && r.target != address(0), "request");
        r.settled = true;
        bytes memory data = abi.encodeWithSelector(r.failure, id, status, reason, uint16(0), uint16(0), bytes(""));
        uint256 beforeGas = gasleft();
        (ok,) = r.target.call{gas: 200_000}(data);
        callbackGas = beforeGas - gasleft();
    }
}
