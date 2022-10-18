pragma solidity ^0.8.4;

interface IFluxPriceFeed {
    event AnswerUpdated(
        int256 indexed current,
        uint256 indexed roundId,
        uint256 updatedAt
    );
    event NewRound(
        uint256 indexed roundId,
        address indexed startedBy,
        uint256 startedAt
    );
    event NewTransmission(
        uint32 indexed aggregatorRoundId,
        int192 answer,
        address transmitter
    );
    event RoleAdminChanged(
        bytes32 indexed role,
        bytes32 indexed previousAdminRole,
        bytes32 indexed newAdminRole
    );
    event RoleGranted(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );
    event RoleRevoked(
        bytes32 indexed role,
        address indexed account,
        address indexed sender
    );

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

    function VALIDATOR_ROLE() external view returns (bytes32);

    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function getAnswer(uint256 _roundId) external view returns (int256);

    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function getTimestamp(uint256 _roundId) external view returns (uint256);

    function grantRole(bytes32 role, address account) external;

    function hasRole(bytes32 role, address account)
        external
        view
        returns (bool);

    function latestAggregatorRoundId() external view returns (uint32);

    function latestAnswer() external view returns (int256);

    function latestRound() external view returns (uint256);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function latestTimestamp() external view returns (uint256);

    function latestTransmissionDetails()
        external
        view
        returns (int192 _latestAnswer, uint64 _latestTimestamp);

    function renounceRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    function transmit(int192 _answer) external;

    function typeAndVersion() external pure returns (string memory);

    function version() external view returns (uint256);
}