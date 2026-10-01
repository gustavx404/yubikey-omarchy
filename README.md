# YubiKey OATH for Omarchy

A compact Omarchy bar widget for copying existing OATH TOTP and HOTP codes from USB-connected YubiKeys.

The YubiKey keeps OATH credentials on the device. This plugin asks YubiKey Manager to list and calculate codes; it does not save OATH passwords or credential secrets. Passwords are sent to a short-lived local helper over stdin and remain in the shell process memory only until the key inventory changes.

## Features

- Show the bar icon only when a USB-connected YubiKey exposes the CCID interface used for OATH.
- Group accounts by key and copy the selected code with one click.
- Support TOTP, HOTP, and accounts that require a physical touch.
- Prompt for a protected OATH application password after opening the panel.
- Keep passwords in memory only; forget them and clear a copied code when the connected-key inventory changes.
- Mark copied codes as sensitive so Omarchy's clipboard history skips them.
- Clear a copied code after 30 seconds by default. Choose 30, 60, 120, or 300 seconds. TOTP codes are cleared at their validity deadline if it comes first.
- Store only the timeout and optional key aliases in the widget's local Omarchy settings.

HOTP generation advances the YubiKey's counter. The panel labels HOTP accounts and warns that copying one generates the next code. A TOTP is valid for its configured period, commonly 30 seconds. See [Yubico's OATH guide](https://docs.yubico.com/software/yubikey/tools/authenticator/auth-guide/oath.html).

## Requirements

- Omarchy 4.0 or later (the manifest schema was validated with Omarchy 4.0.4).
- A USB YubiKey with OATH available over CCID.
- The Arch package `yubikey-manager`, which provides Yubico's Python API used by the helper.
- A working PC/SC service for CCID communication.
- `wl-copy` and `wl-paste` from `wl-clipboard`.

Install the dependencies yourself; the plugin never runs an installer or requests elevated permissions:

```sh
omarchy pkg add yubikey-manager wl-clipboard
```

If CCID access is unavailable, check that the system PC/SC service from the `ccid` dependency is running. No account secrets or passwords are written to disk. The helper receives a password through stdin instead of process arguments.

## Install

```sh
omarchy plugin add https://github.com/gustavx404/yubikey-omarchy.git
```

Review the source before enabling it. The Omarchy plugin loader runs third-party plugins as code inside the long-lived `omarchy-shell` process.

## Use

Plug in a supported YubiKey and click the YubiKey icon in the bar. If OATH is password-protected, enter its password in the matching key group. Click an account to copy its code, then paste it into the sign-in form.

To change the clipboard timeout, use the selector in the panel. Optional key aliases are kept in the local `shell.json` widget settings. Passwords and OTP values are never included in those settings.

## Limitations

- USB only; NFC support is not included in this version.
- Accounts must already be stored on the YubiKey. QR enrollment and account management are future work.
- A clipboard manager outside Omarchy may ignore the sensitive-data hint. Clipboard cleanup only clears the current selection if it still contains the code copied by this plugin.
- The code has not been tested with physical YubiKey hardware in this development environment.

## Development

Validate the manifest with:

```sh
omarchy plugin validate .
```

For plugin details, see [Omarchy's shell plugin manual](https://omarchy.org/manual/shell-plugins/).

---

# YubiKey OATH para Omarchy

Um widget compacto para a barra do Omarchy que copia códigos OATH TOTP e HOTP existentes em YubiKeys conectadas por USB.

As credenciais OATH permanecem na YubiKey. O plugin usa o YubiKey Manager para listar contas e gerar códigos; não salva senhas OATH nem segredos das contas. As senhas são enviadas a um helper local de curta duração por stdin e ficam somente na memória do shell até mudar o conjunto de chaves conectadas.

## Recursos

- Mostrar o ícone da barra apenas quando uma YubiKey USB disponibiliza a interface CCID usada pelo OATH.
- Agrupar contas por chave e copiar um código com um clique.
- Suportar TOTP, HOTP e contas que exigem toque físico.
- Pedir a senha OATH protegida depois que o painel for aberto.
- Manter senhas apenas em memória; esquecê-las e limpar um código copiado quando o conjunto de chaves mudar.
- Marcar códigos copiados como sensíveis para que o histórico de clipboard do Omarchy os ignore.
- Limpar o código copiado após 30 segundos por padrão. Escolha 30, 60, 120 ou 300 segundos. Códigos TOTP são apagados quando expiram, se isso ocorrer antes.
- Salvar apenas o intervalo e apelidos opcionais para as chaves nas configurações locais do Omarchy.

A geração de HOTP avança o contador da YubiKey. O painel identifica contas HOTP e avisa que copiar gera o próximo código. Um TOTP é válido pelo período configurado, normalmente 30 segundos. Consulte o [guia OATH da Yubico](https://docs.yubico.com/software/yubikey/tools/authenticator/auth-guide/oath.html).

## Requisitos

- Omarchy 4.0 ou posterior (o esquema do manifesto foi validado no Omarchy 4.0.4).
- YubiKey USB com OATH disponível por CCID.
- Pacote Arch `yubikey-manager`, que fornece a API Python da Yubico usada pelo helper.
- Serviço PC/SC funcional para comunicação CCID.
- `wl-copy` e `wl-paste`, fornecidos pelo pacote `wl-clipboard`.

Instale as dependências manualmente; o plugin não executa instaladores nem solicita permissões elevadas:

```sh
omarchy pkg add yubikey-manager wl-clipboard
```

Se o acesso CCID não funcionar, confira se o serviço PC/SC do pacote `ccid` está ativo. Nenhuma senha ou segredo de conta é gravado em disco. O helper recebe a senha por stdin, não por argumentos de processo.

## Instalação

```sh
omarchy plugin add https://github.com/gustavx404/yubikey-omarchy.git
```

Revise o código antes de ativar. O carregador do Omarchy executa plugins de terceiros como código dentro do processo persistente `omarchy-shell`.

## Uso

Conecte uma YubiKey compatível e clique no ícone YubiKey na barra. Se OATH estiver protegido por senha, digite-a no grupo da chave correspondente. Clique numa conta para copiar o código e cole-o no formulário de autenticação.

Altere o prazo de limpeza no seletor do painel. Apelidos opcionais ficam nas configurações locais do widget em `shell.json`. Senhas e códigos OTP nunca são incluídos nessas configurações.

## Limitações

- Apenas USB; NFC não está incluído nesta versão.
- As contas devem já estar armazenadas na YubiKey. Cadastro por QR e gerenciamento de contas ficam para o futuro.
- Um gerenciador de clipboard externo ao Omarchy pode ignorar a indicação de dado sensível. A limpeza apaga a seleção atual apenas se ela ainda contiver o código copiado pelo plugin.
- Este ambiente de desenvolvimento não possui uma YubiKey física para validar a comunicação com o hardware.

## Desenvolvimento

Valide o manifesto com:

```sh
omarchy plugin validate .
```

Consulte também o [manual de plugins do Omarchy](https://omarchy.org/manual/shell-plugins/).
