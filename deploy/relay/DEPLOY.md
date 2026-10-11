# Деплой KeelRelay

KeelRelay — контракт, который станет верификатором KeelVault. Сервер подписывает ваучеры сборок, создатели отправляют их в KeelRelay и сами платят газ. Деплой делается один раз с кошелька владельца.

Файлы в этой папке собраны из `src/KeelRelay.sol` этого репозитория: `KeelRelay.flat.sol` компилируется в тот же байткод, что и `forge build` (проверено побайтно). Ваучер «записать без выплаты» (amount = 0) может отправить только создатель токена или владелец релея; ваучер на выплату — кто угодно, деньги всё равно уходят только создателю.

## Когда

После установки сервера, когда `scripts/new-keys.js` на сервере покажет адрес **VERIFIER**: он нужен как аргумент `signer_`. До шага 4 (`setVerifier`) из OWNER-SETUP.md.

## Что нужно

- Кошелёк владельца `0x51a9ca901c0cb5c222d244b2ccb0ebfc5c9aba99` (MetaMask или Rabby) в сети Ethereum.
- ETH на газ: деплой ~995 000 газа (замер на локальной ноде), это ~0,001 ETH при 1 gwei и ~0,005 ETH при 5 gwei.
- Файлы из этой папки: `KeelRelay.flat.sol`, `compiler_config.json`, `KeelRelay.standard-input.json`.

## Шаги в Remix

1. Откройте https://remix.ethereum.org, создайте файл `KeelRelay.flat.sol` и вставьте в него содержимое `KeelRelay.flat.sol` целиком.
2. Вкладка **Solidity compiler**:
   - Compiler: `0.8.26`.
   - Раскройте **Advanced configurations**, выберите **Use configuration file**, откройте созданный там `compiler_config.json` и замените его содержимое на наш `compiler_config.json`.
   - Нажмите **Compile KeelRelay.flat.sol**. Ошибок быть не должно.
3. Вкладка **Deploy & run transactions**:
   - Environment: **Injected Provider** (ваш кошелёк). Проверьте, что выбран аккаунт `0x51a9…ba99` и сеть Ethereum mainnet (chain id 1).
   - Contract: **KeelRelay**.
   - Раскройте поля у кнопки **Deploy** и заполните:

     | Поле | Значение |
     |---|---|
     | `owner_` | `0x51a9ca901c0cb5c222d244b2ccb0ebfc5c9aba99` |
     | `vault_` | `0xe2fb1c0e5ea5342cd8607efa8e7c44f06b47013c` |
     | `hook_` | `0x77ad6136c102384d0f1a213bcb241b7d090528cc` |
     | `signer_` | адрес VERIFIER с сервера |

   - **Transact**, подтвердите в кошельке. В кошельке «To» должно быть пусто (создание контракта), «Value» = 0.
4. Проверка: в Remix под развёрнутым контрактом нажмите `owner`, `vault`, `hook`, `signer`. Все четыре должны совпасть с таблицей. Во вкладке компилятора у `KeelRelay` в ABI должна быть ошибка `RecordNotAllowed` — так видно, что это исправленная версия.
5. Пришлите в тред адрес KeelRelay. Я пропишу его в `RELAY_ADDRESS` на сервере и дам calldata для шага 4: `KeelVault.setVerifier(адрес KeelRelay)`.

ETH на сам KeelRelay не отправляйте: он ему не нужен.

## Верификация на Etherscan (по желанию, но лучше сделать)

1. На странице адреса контракта: **Contract → Verify and Publish**.
2. Compiler type: **Solidity (Standard-Json-Input)**, version `v0.8.26`, license **MIT**.
3. Загрузите `KeelRelay.standard-input.json`.
4. Constructor arguments Etherscan обычно находит сам. Если попросит, я посчитаю строку аргументов по вашим адресам.

## Если что-то пошло не так

- Не тот `signer_`: владелец вызывает `setSigner(новый адрес)` на KeelRelay, передеплой не нужен.
- Ключ VERIFIER утёк: `revokeSigner()` на KeelRelay сразу останавливает все ваучеры (или `revokeVerifier()` на KeelVault).
- Ошибка в `owner_`, `vault_` или `hook_`: эти поля не меняются, просто задеплойте заново и не используйте первый адрес.

Для тех, у кого есть Foundry, то же одной командой из клона keel-contracts:
`forge create src/KeelRelay.sol:KeelRelay --broadcast --rpc-url <RPC> --interactive --constructor-args <owner> <vault> <hook> <VERIFIER>`
