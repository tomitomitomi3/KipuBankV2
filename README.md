# KipuBankV2

## 1. Caracteristicas principales

- **Control de acceso:** OpenZeppelin AccessControl con roles `ROL_ADMIN` y `ROL_PAUSADOR`.  
- **Multi-token:** depositos y retiros de ETH (`address(0)`) y tokens ERC20.  
- **Contabilidad interna:** balances por token y usuario (`verSaldo(token, user)`).  
- **Oraculos Chainlink:** `oraculoEthUsd` obligatorio; soporte para oraculos ERC20 con `asignarOraculoToken`.  
- **Bank cap en USD:** limite global en USD (6 decimales) para ETH y tokens con oraculo.  
- **Seguridad:** ReentrancyGuard para `retirar`, SafeERC20 para transferencias, Checks-Effects-Interactions.  
- **Optimizacion:** `immutable` y `constant` donde aplica, errores personalizados para ahorro de gas.  
- **Eventos:** `DepositoRealizado`, `RetiroRealizado`, `OraculoAsignado`, `TopeBancoActualizado`, `LimitePorTransaccionActualizado`.

## 2. Decisiones de diseño / trade-offs

- `address(0)` representa ETH nativo.  
- Bank cap se calcula con ETH siempre y tokens solo si tienen oraculo.  
- No hay enumeracion automatica de tokens; para auditoria off-chain se requiere registro externo o añadir array `supportedTokens`.  
- Los precios se normalizan segun decimales del oraculo.  
- Funciones de rescate `rescatarERC20` y `rescatarETH` solo para admin; deben usarse con criterio.  
- Limite por transaccion aplica solo para ETH (`actualizarLimitePorTransaccion`); se puede extender a ERC20.

## 3. Despliegue (Testnet)

1. Compilar con `solc ^0.8.20`.  
2. Constructor:
   - `_oraculoEthUsd`: direccion del agregador ETH/USD en la testnet.  
   - `_topeBancoUSD6`: limite global en USD (6 decimales).  
3. Tras deploy:
   - Owner recibe `ROL_ADMIN`.  
   - Registrar oraculos ERC20 con `asignarOraculoToken(token, feed)`.  
   - Limitar retiros ETH por transaccion con `actualizarLimitePorTransaccion(nuevoLimite)`.

## 4. Funciones principales

- `depositarETH()` — depositar ETH (tambien via `receive()` o `fallback()`).  
- `depositarERC20(token, monto)` — depositar tokens ERC20 (requiere `approve` previo).  
- `retirar(token, monto)` — retirar ETH o ERC20 (`token == address(0)` para ETH).  
- `verSaldo(token, usuario)` — consultar balance interno de usuario por token.  
- `valorTokenUSD(token)` — valor en USD del token en la boveda.  
- `ultimoPrecioETH()` — obtener precio ETH/USD del oraculo.  
- `asignarOraculoToken(token, oraculo)` — registrar o actualizar oraculo ERC20/USD (solo admin).  
- `actualizarTopeBancoUSD(nuevoTopeUSD6)` — cambiar limite global USD (solo admin).  
- `actualizarLimitePorTransaccion(nuevoLimite)` — cambiar limite por transaccion ETH (solo admin).  
- `rescatarERC20(token, destinatario, monto)` — enviar tokens erroneamente enviados (solo admin).  
- `rescatarETH(destinatario, monto)` — enviar ETH erroneamente enviado (solo admin).

