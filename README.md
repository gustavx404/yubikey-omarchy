# YubiKey OATH for Omarchy

A compact Omarchy bar widget for copying existing OATH TOTP and HOTP codes from USB-connected YubiKeys.

The YubiKey keeps OATH credentials on the device. This plugin asks YubiKey Manager to list and calculate codes; it does not save OATH passwords or credential secrets. Passwords are sent to a short-lived local helper over stdin and remain in the shell process memory only until the key inventory changes.

## Features

- Show the bar icon only when a USB-connected YubiKey exposes the CCID interface used for OATH.
- Use compact account cards with bundled YubiKey, TOTP, HOTP, settings, and back icons.
- Show a stable colored initial for every issuer and optionally load local Aegis-compatible icon packs for service logos.
- Group accounts by key and copy the selected code with one click.
- Support TOTP, HOTP, and accounts that require a physical touch.
- Prompt for a protected OATH application password after opening the panel.
- Keep passwords in memory only; forget them and clear a copied code when the connected-key inventory changes.
- Mark copied codes as sensitive so Omarchy's clipboard history skips them.
- Clear a copied code after 30 seconds by default (recommended). Choose 30 seconds, 1 minute, or 2 minutes. TOTP codes are cleared at their validity deadline if it comes first.
- Generate and copy codes in a transient, network-restricted helper. The OTP is not returned to QML; the helper clears it only if the clipboard still contains that code.
- Open a dedicated settings page for clipboard timeout, key aliases, and security behavior; return to accounts with the back button.
- Store only the timeout and optional key aliases in the widget's local Omarchy settings.

HOTP generation advances the YubiKey's counter. The panel labels HOTP accounts and warns that copying one generates the next code. A TOTP is valid for its configured period, commonly 30 seconds. See [Yubico's OATH guide](https://docs.yubico.com/software/yubikey/tools/authenticator/auth-guide/oath.html).

## Requirements

- Omarchy 4.0 or later (the manifest schema was validated with Omarchy 4.0.4).
- A USB YubiKey with OATH available over CCID.
- The Arch package `yubikey-manager`, which provides Yubico's Python API used by the helper.
- `bubblewrap`, a working systemd user manager, and unprivileged user namespaces for helper isolation.
- A working PC/SC service for CCID communication.
- `wl-copy` and `wl-paste` from `wl-clipboard`.

The helper was checked with `yubikey-manager` 5.9.1. Compatibility with older versions has not been verified.

Install the dependencies yourself; the plugin never runs an installer or requests elevated permissions:

```sh
omarchy pkg add yubikey-manager bubblewrap wl-clipboard
```

If CCID access is unavailable, check that the system PC/SC service from the `ccid` dependency is running. No account secrets or passwords are written to disk. The helper receives a password through stdin instead of process arguments. Account and code operations run with network socket families disabled, a read-only filesystem view, and explicit PC/SC and Wayland socket access. The helper environment is rebuilt from a small allowlist and uses absolute executable paths.

## Install

```sh
omarchy plugin add https://github.com/gustavx404/yubikey-omarchy.git
```

Review the source before enabling it. The Omarchy plugin loader runs third-party plugins as code inside the long-lived `omarchy-shell` process.

## Use

Plug in a supported YubiKey and click the YubiKey icon in the bar. If OATH is password-protected, enter its password in the matching key group. Click an account to copy its code, then paste it into the sign-in form.

Open **Settings** with the gear button to change the clipboard timeout, key aliases, or account icon pack; use the back button to return to accounts. Load an Aegis-compatible ZIP from disk to display service logos. The helper validates the archive and imports only referenced PNG, JPEG, or sanitized SVG files. Community packs are available from [aegis-icons](https://aegis-icons.github.io/). Unknown issuers still get a colored initial. Passwords and OTP values are never included in the local `shell.json` widget settings.

## Limitations

- USB only; NFC support is not included in this version.
- Accounts must already be stored on the YubiKey. QR enrollment and account management are future work.
- A clipboard manager outside Omarchy may ignore the sensitive-data hint. Clipboard cleanup only clears the current selection if it still contains the code copied by this plugin.
- The QML panel remains loaded by `omarchy-shell`; the OTP calculation and timed clipboard ownership run in an isolated transient helper. OATH passwords are cached in shell memory until the connected-key inventory changes.
- Hardware discovery and protected OATH account listing have been checked with a physical key; end-to-end TOTP, HOTP, and touch-code generation still need hardware validation.

## Development

Validate the manifest with:

```sh
omarchy plugin validate .
```

Run the dependency-free protocol and label fuzz checks with:

```sh
python -m unittest discover -s tests
```

See [SECURITY.md](SECURITY.md) for the threat model and vulnerability reporting.

For plugin details, see [Omarchy's shell plugin manual](https://omarchy.org/manual/shell-plugins/).

---

# YubiKey OATH para Omarchy

Um widget compacto para a barra do Omarchy que copia códigos OATH TOTP e HOTP existentes em YubiKeys conectadas por USB.

As credenciais OATH permanecem na YubiKey. O plugin usa o YubiKey Manager para listar contas e gerar códigos; não salva senhas OATH nem segredos das contas. As senhas são enviadas a um helper local de curta duração por stdin e ficam somente na memória do shell até mudar o conjunto de chaves conectadas.

## Recursos

- Mostrar o ícone da barra apenas quando uma YubiKey USB disponibiliza a interface CCID usada pelo OATH.
- Agrupar contas por chave e copiar um código com um clique.
- Usar cartões compactos com ícones locais da YubiKey, TOTP, HOTP, configurações e retorno.
- Mostrar uma inicial colorida para cada emissor e permitir carregar pacotes de ícones Aegis compatíveis para exibir logotipos.
- Suportar TOTP, HOTP e contas que exigem toque físico.
- Pedir a senha OATH protegida depois que o painel for aberto.
- Manter senhas apenas em memória; esquecê-las e limpar um código copiado quando o conjunto de chaves mudar.
- Marcar códigos copiados como sensíveis para que o histórico de clipboard do Omarchy os ignore.
- Limpar o código copiado após 30 segundos por padrão (recomendado). Escolha 30 segundos, 1 minuto ou 2 minutos. Códigos TOTP são apagados quando expiram, se isso ocorrer antes.
- Gerar e copiar códigos em um helper transitório com rede bloqueada. O OTP não volta ao QML; o helper só apaga o valor se o clipboard ainda contiver aquele código.
- Abrir uma tela de configurações para prazo de limpeza, apelidos das chaves e informações de segurança; voltar à lista de contas pelo botão de retorno.
- Salvar apenas o intervalo e apelidos opcionais para as chaves nas configurações locais do Omarchy.

A geração de HOTP avança o contador da YubiKey. O painel identifica contas HOTP e avisa que copiar gera o próximo código. Um TOTP é válido pelo período configurado, normalmente 30 segundos. Consulte o [guia OATH da Yubico](https://docs.yubico.com/software/yubikey/tools/authenticator/auth-guide/oath.html).

## Requisitos

- Omarchy 4.0 ou posterior (o esquema do manifesto foi validado no Omarchy 4.0.4).
- YubiKey USB com OATH disponível por CCID.
- Pacote Arch `yubikey-manager`, que fornece a API Python da Yubico usada pelo helper.
- `bubblewrap`, um gerenciador systemd do usuário ativo e user namespaces sem privilégio para isolar o helper.
- Serviço PC/SC funcional para comunicação CCID.
- `wl-copy` e `wl-paste`, fornecidos pelo pacote `wl-clipboard`.

O helper foi verificado com `yubikey-manager` 5.9.1. A compatibilidade com versões anteriores não foi verificada.

Instale as dependências manualmente; o plugin não executa instaladores nem solicita permissões elevadas:

```sh
omarchy pkg add yubikey-manager bubblewrap wl-clipboard
```

Se o acesso CCID não funcionar, confira se o serviço PC/SC do pacote `ccid` está ativo. Nenhuma senha ou segredo de conta é gravado em disco. O helper recebe a senha por stdin, não por argumentos de processo. Listagem e geração de códigos usam uma visão somente leitura do sistema, famílias de sockets de rede desativadas e acesso explícito aos sockets PC/SC e Wayland. O ambiente do helper usa uma allowlist pequena e caminhos absolutos para executáveis.

## Instalação

```sh
omarchy plugin add https://github.com/gustavx404/yubikey-omarchy.git
```

Revise o código antes de ativar. O carregador do Omarchy executa plugins de terceiros como código dentro do processo persistente `omarchy-shell`.

## Uso

Conecte uma YubiKey compatível e clique no ícone YubiKey na barra. Se OATH estiver protegido por senha, digite-a no grupo da chave correspondente. Clique numa conta para copiar o código e cole-o no formulário de autenticação.

Abra **Configurações** pela engrenagem para alterar o prazo do clipboard ou apelidos das chaves; use o botão de retorno para voltar às contas. Senhas e códigos OTP nunca são incluídos nas configurações locais do widget em `shell.json`.

Em **Configurações → Account icons**, carregue um pacote Aegis `.zip` local. O [Yubico Authenticator também aceita esse formato](https://docs.yubico.com/software/yubikey/tools/authenticator/auth-guide/settings.html); a especificação do [pacote Aegis](https://github.com/beemdevelopment/Aegis/blob/master/docs/iconpacks.md) associa emissores a imagens PNG, JPEG ou SVG. Pacotes comunitários estão disponíveis em [aegis-icons](https://aegis-icons.github.io/). O helper valida o arquivo e importa somente imagens referenciadas e SVGs sanitizados. Emissores sem logotipo continuam identificáveis por uma inicial colorida.

## Limitações

- Apenas USB; NFC não está incluído nesta versão.
- As contas devem já estar armazenadas na YubiKey. Cadastro por QR e gerenciamento de contas ficam para o futuro.
- Um gerenciador de clipboard externo ao Omarchy pode ignorar a indicação de dado sensível. A limpeza apaga a seleção atual apenas se ela ainda contiver o código copiado pelo plugin.
- O painel QML continua carregado pelo `omarchy-shell`; cálculo de OTP e controle temporário do clipboard rodam num helper isolado. Senhas OATH ficam em cache na memória do shell até mudar o conjunto de chaves conectadas.
- A detecção de hardware e a leitura de contas OATH protegidas foram verificadas com uma chave física; geração TOTP, HOTP e toque ainda precisam de validação ponta a ponta.

## Desenvolvimento

Valide o manifesto com:

```sh
omarchy plugin validate .
```

Execute os testes sem dependências externas de protocolo e fuzz de rótulos com:

```sh
python -m unittest discover -s tests
```

Consulte [SECURITY.md](SECURITY.md) para o modelo de ameaças e o canal de reporte.

Consulte também o [manual de plugins do Omarchy](https://omarchy.org/manual/shell-plugins/).
