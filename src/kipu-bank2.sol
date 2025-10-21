// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
KipuBankV2
- Bóveda multi-token (ETH + ERC20)
- Control de acceso basado en roles (OpenZeppelin AccessControl)
- Oraculo Chainlink para conversion a USD
- Contabilidad interna multi-token 
- SafeERC20 para transferencias seguras, ReentrancyGuard para retiros
- address(0) representa ETH nativo
*/

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


contract KipuBankV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ROL_ADMIN = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ROL_PAUSADOR = keccak256("ROL_PAUSADOR");

    error DepositoCero();
    error TopeBancoUSDExcedido(uint256 intentoUSD, uint256 topeUSD);
    error TopePorTransaccionExcedido(uint256 intento, uint256 limite);
    error SaldoInsuficiente(uint256 saldo, uint256 solicitado);
    error TransferenciaFallida();
    error TokenSinOraculo(address token);
    error NoEsAdmin();

    event DepositoRealizado(address indexed usuario, address indexed token, uint256 monto);
    event RetiroRealizado(address indexed usuario, address indexed token, uint256 monto);
    event OraculoAsignado(address indexed token, address indexed oraculo);
    event TopeBancoActualizado(uint256 nuevoTopeUSD);
    event LimitePorTransaccionActualizado(uint256 nuevoLimiteWei);

    address public immutable creador;
    AggregatorV3Interface public immutable oraculoEthUsd; // Oraculo Chainlink ETH/USD
    uint8 public constant DECIMALES_USD = 6; // Conversion a formato USDC (6 decimales)

    // saldos[token][usuario] => cantidad (para ETH token==address(0), en wei)
    mapping(address => mapping(address => uint256)) private saldos;
    mapping(address => AggregatorV3Interface) public oraculosDeToken;
    mapping(address => uint8) private cacheDecimalesToken;

    uint256 public topeBancoUSD; // limite global en USD (6 decimales)
    uint256 public limitePorTransaccionWei; // limite por retiro de ETH (en wei)

    uint256 public totalDepositos;
    uint256 public totalRetiros;

    modifier soloAdmin() {
        if (!hasRole(ROL_ADMIN, msg.sender)) revert NoEsAdmin();
        _;
    }

    constructor(address _oraculoEthUsd, uint256 _topeBancoUSD6) {
        require(_oraculoEthUsd != address(0), "Oraculo ETH invalido");
        creador = msg.sender;
        oraculoEthUsd = AggregatorV3Interface(_oraculoEthUsd);
        topeBancoUSD = _topeBancoUSD6;

        _grantRole(ROL_ADMIN, msg.sender);     
        _grantRole(ROL_PAUSADOR, msg.sender);  
    }

    /// @notice Depositar ETH nativo en la boveda
    function depositarETH() external payable {
        if (msg.value == 0) revert DepositoCero();

        uint256 depositoUSD = _convertirETHaUSD(msg.value);
        uint256 totalUSD = _valorTotalUSD() + depositoUSD;

        if (topeBancoUSD > 0 && totalUSD > topeBancoUSD) {
            revert TopeBancoUSDExcedido(totalUSD, topeBancoUSD);
        }

        saldos[address(0)][msg.sender] += msg.value;
        totalDepositos++;

        emit DepositoRealizado(msg.sender, address(0), msg.value);
    }

    /// @notice Depositar un token ERC20 en la boveda (requiere aprobacion previa)
    function depositarERC20(address token, uint256 monto) external {
        if (monto == 0) revert DepositoCero();
        require(token != address(0), "usar depositarETH() para ETH");

        if (address(oraculosDeToken[token]) != address(0)) {
            uint256 valorUSD = _convertirTokenAUSD(token, monto);
            uint256 totalUSD = _valorTotalUSD() + valorUSD;
            if (topeBancoUSD > 0 && totalUSD > topeBancoUSD) {
                revert TopeBancoUSDExcedido(totalUSD, topeBancoUSD);
            }
        }

        saldos[token][msg.sender] += monto;
        totalDepositos++;

        IERC20(token).safeTransferFrom(msg.sender, address(this), monto);
        emit DepositoRealizado(msg.sender, token, monto);
    }

    /// @notice Retirar ETH o tokens ERC20
    /// @param token address(0) para ETH, o direccion del token ERC20
    function retirar(address token, uint256 monto) external nonReentrant {
        uint256 saldoUsuario = saldos[token][msg.sender];
        if (monto > saldoUsuario) revert SaldoInsuficiente(saldoUsuario, monto);

        if (token == address(0) && limitePorTransaccionWei > 0 && monto > limitePorTransaccionWei) {
            revert TopePorTransaccionExcedido(monto, limitePorTransaccionWei);
        }

        saldos[token][msg.sender] = saldoUsuario - monto;
        totalRetiros++;

        if (token == address(0)) {
            (bool exito, ) = msg.sender.call{value: monto}("");
            if (!exito) revert TransferenciaFallida();
        } else {
            IERC20(token).safeTransfer(msg.sender, monto);
        }

        emit RetiroRealizado(msg.sender, token, monto);
    }

    /// @notice Ver saldo de un usuario para un token dado
    function verSaldo(address token, address usuario) external view returns (uint256) {
        return saldos[token][usuario];
    }

    /// @notice Ultimo precio ETH/USD del oraculo (con sus decimales)
    function ultimoPrecioETH() public view returns (int256 precio, uint8 decimales) {
        (, int256 p, , , ) = oraculoEthUsd.latestRoundData();
        decimales = oraculoEthUsd.decimals();
        return (p, decimales);
    }

    /// @notice Convierte una cantidad en wei a USD (6 decimales)
    function _convertirETHaUSD(uint256 cantidadWei) internal view returns (uint256) {
        (int256 precio, uint8 decimalesPrecio) = ultimoPrecioETH();
        uint256 numerador = cantidadWei * uint256(precio);
        uint256 denominador = 1e18 * (10 ** uint256(decimalesPrecio));
        return (numerador * (10 ** uint256(DECIMALES_USD))) / denominador;
    }

    /// @notice Convierte una cantidad de token ERC20 a USD (6 decimales)
    function _convertirTokenAUSD(address token, uint256 monto) internal view returns (uint256) {
        AggregatorV3Interface oraculo = oraculosDeToken[token];
        if (address(oraculo) == address(0)) revert TokenSinOraculo(token);
        (, int256 precio, , , ) = oraculo.latestRoundData();
        uint8 decimalesPrecio = oraculo.decimals();

        uint8 decimalesToken = _obtenerDecimalesToken(token);

        uint256 numerador = monto * uint256(precio) * (10 ** uint256(DECIMALES_USD));
        uint256 denominador = (10 ** uint256(decimalesToken)) * (10 ** uint256(decimalesPrecio));
        return numerador / denominador;
    }

    /// @notice Valor total de la boveda en USD (solo ETH y tokens con oraculo registrado)
    function _valorTotalUSD() internal view returns (uint256) {
        uint256 totalUSD = 0;

        uint256 saldoETH = address(this).balance;
        if (saldoETH > 0) {
            totalUSD += _convertirETHaUSD(saldoETH);
        }
        return totalUSD;
    }

    /// @notice Valor en USD (6 decimales) de un token especifico en la boveda
    function valorTokenUSD(address token) external view returns (uint256) {
        if (token == address(0)) {
            return _convertirETHaUSD(address(this).balance);
        } else {
            AggregatorV3Interface oraculo = oraculosDeToken[token];
            if (address(oraculo) == address(0)) revert TokenSinOraculo(token);
            uint256 saldoToken = IERC20(token).balanceOf(address(this));
            return _convertirTokenAUSD(token, saldoToken);
        }
    }

    /// @notice Obtiene los decimales del token (con cache)
    function _obtenerDecimalesToken(address token) internal view returns (uint8) {
        uint8 d = cacheDecimalesToken[token];
        if (d != 0) return d;
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return 18;
        }
    }

    /// @notice Asignar o actualizar el oraculo (price feed) para un token ERC20
    function asignarOraculoToken(address token, address oraculo) external soloAdmin {
        require(token != address(0), "ETH no permitido");
        oraculosDeToken[token] = AggregatorV3Interface(oraculo);
        emit OraculoAsignado(token, oraculo);
    }

    /// @notice Actualizar el tope global del banco en USD
    function actualizarTopeBancoUSD(uint256 nuevoTopeUSD6) external soloAdmin {
        topeBancoUSD = nuevoTopeUSD6;
        emit TopeBancoActualizado(nuevoTopeUSD6);
    }

    /// @notice Actualizar el limite por transaccion en ETH (wei)
    function actualizarLimitePorTransaccion(uint256 nuevoLimite) external soloAdmin {
        limitePorTransaccionWei = nuevoLimite;
        emit LimitePorTransaccionActualizado(nuevoLimite);
    }

    /// @notice Rescate de tokens enviados por error (solo admin)
    function rescatarERC20(address token, address destinatario, uint256 monto) external soloAdmin {
        IERC20(token).safeTransfer(destinatario, monto);
    }

    /// @notice Rescate de ETH (solo admin)
    function rescatarETH(address payable destinatario, uint256 monto) external soloAdmin {
        (bool ok, ) = destinatario.call{value: monto}("");
        require(ok, "Fallo al rescatar ETH");
    }

    receive() external payable {
        this.depositarETH();
    }

    fallback() external payable {
        this.depositarETH();
    }
}
