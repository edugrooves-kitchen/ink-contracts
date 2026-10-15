// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IInkRenderer {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

/// @title Ink & Inference portraits
/// @notice A static, one-time drop of at most 2,000 portraits. Only the vault mints.
/// - Agent portraits: token id = seat number (0–1999), painted from that agent's work record.
/// - Swarm portraits: token ids from 10,000, painted from a random seed.
/// - 0% trading fee: ERC-2981 reports a zero royalty, so marketplaces show no creator fee on resales.
contract InkPortraits is ERC721, ERC2981, Ownable {
    uint256 public constant MAX_SUPPLY = 2000;
    uint256 public constant SEAT_COUNT = 2000;
    uint256 public constant SWARM_ID_OFFSET = 10_000;
    uint96 public constant ROYALTY_BPS = 0;

    struct AgentStats {
        uint32 accepted;
        uint16 rateBps;
        uint32 turns;
        uint32 hoursTenths;
        bool outdated;
    }

    address public vault;
    address public renderer;
    bool public rendererLocked;

    uint256 public agentMinted;
    uint256 public swarmMinted;

    mapping(uint256 seat => AgentStats) internal _stats;
    mapping(uint256 tokenId => bytes32) public swarmSeed;
    /// @notice How many agent portraits an address holds.
    mapping(address => uint256) public agentBalanceOf;
    /// @notice The block an address last went from holding no agent portrait to holding one.
    mapping(address => uint256) public agentHolderSince;

    event VaultSet(address vault);
    event RendererSet(address renderer);
    event RendererLocked();
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event MetadataUpdate(uint256 _tokenId);

    error NotASwarmPortrait();
    error OnlyVault();
    error VaultAlreadySet();
    error SoldOut();
    error NotASeat();
    error Locked();
    error NoRenderer();

    constructor(address owner_) ERC721("Ink & Inference", "INKINF") Ownable(owner_) {
        _setDefaultRoyalty(owner_, ROYALTY_BPS);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    // ---------------------------------------------------------------- owner

    function setVault(address vault_) external onlyOwner {
        if (vault != address(0)) revert VaultAlreadySet();
        vault = vault_;
        emit VaultSet(vault_);
    }

    function setRenderer(address renderer_) external onlyOwner {
        if (rendererLocked) revert Locked();
        renderer = renderer_;
        emit RendererSet(renderer_);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Freezes the renderer forever.
    function lockRenderer() external onlyOwner {
        if (renderer == address(0)) revert NoRenderer(); // locking with no renderer would break tokenURI for good
        rendererLocked = true;
        emit RendererLocked();
    }

    // ---------------------------------------------------------------- minting (vault only)

    function mintAgent(uint256 seat, address to, AgentStats calldata stats) external onlyVault {
        if (seat >= SEAT_COUNT) revert NotASeat();
        if (agentMinted + swarmMinted >= MAX_SUPPLY) revert SoldOut();
        _stats[seat] = stats;
        agentMinted++;
        // No receiver check, so a seat held by a contract wallet can still claim. Reverts if this seat's
        // portrait already exists.
        _mint(to, seat);
    }

    function mintSwarm(address to, bytes32 seed) external onlyVault returns (uint256 tokenId) {
        if (agentMinted + swarmMinted >= MAX_SUPPLY) revert SoldOut();
        tokenId = SWARM_ID_OFFSET + swarmMinted;
        swarmMinted++;
        swarmSeed[tokenId] = seed;
        _mint(to, tokenId); // no receiver check: reveals are run by anyone and must not be blockable
    }

    /// @notice A trait reroll: the vault gives an existing swarm portrait a new seed, which repaints it.
    function setSwarmSeed(uint256 tokenId, bytes32 seed) external onlyVault {
        if (isAgentPortrait(tokenId)) revert NotASwarmPortrait();
        _requireOwned(tokenId);
        swarmSeed[tokenId] = seed;
        emit MetadataUpdate(tokenId);
    }

    // ---------------------------------------------------------------- views

    function isAgentPortrait(uint256 tokenId) public pure returns (bool) {
        return tokenId < SWARM_ID_OFFSET;
    }

    /// @notice Whether `holder` gets agent-holder perks (no hook fee, half-price rerolls): it holds an agent
    /// portrait and has since an earlier block, so a portrait lent for one transaction doesn't count.
    function isAgentHolder(address holder) external view returns (bool) {
        return agentBalanceOf[holder] > 0 && agentHolderSince[holder] < block.number;
    }

    function agentStats(uint256 seat) external view returns (AgentStats memory) {
        return _stats[seat];
    }

    function totalSupply() external view returns (uint256) {
        return agentMinted + swarmMinted;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return IInkRenderer(renderer).tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (isAgentPortrait(tokenId)) {
            if (from != address(0)) agentBalanceOf[from]--;
            if (to != address(0) && agentBalanceOf[to]++ == 0) agentHolderSince[to] = block.number;
        }
    }
}
