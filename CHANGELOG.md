# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — versionamento [Semantic Versioning](https://semver.org/).

## [0.5.1] — 2026-05-25

### Mudado

- **Rename `rad-pbx` → `rad_pbx`** em todos os caminhos do tema. Hífen no nome do tema pode ser interpretado como operador em alguns pontos do Issabel/Asterisk que tratam o identificador como expressão (themesetup, queries SQL sem aspas adequadas). Underscore é seguro em todos os contextos.
  - Constante `THEME_REPO_NAME`: `rad-pbx-theme` → `rad_pbx-theme`.
  - Constante `THEME_PATH_IN_REPO`: `www/html/themes/rad-pbx` → `www/html/themes/rad_pbx`.
  - Constante `THEME_INSTALL_DIR`: `/var/www/html/themes/rad-pbx` → `/var/www/html/themes/rad_pbx`.
  - Textos do menu, prompts e instruções de pós-instalação atualizados.
  - Pasta renomeada via `git mv` no repositório `rad_pbx-theme` (histórico preservado).
- `install.sh` v0.5.1 — patch (rename de path, sem mudança comportamental).

### Notas

- Quem já tinha instalado a v0.5.0 e instalar a v0.5.1 vai ficar com **dois diretórios** no servidor: o antigo `/var/www/html/themes/rad-pbx/` (não removido automaticamente) e o novo `/var/www/html/themes/rad_pbx/`. Remova o antigo manualmente se não precisar mais (`rm -rf /var/www/html/themes/rad-pbx/`).
- O repositório no GitHub precisa ser renomeado de `rad-pbx-theme` para `rad_pbx-theme` antes do instalador v0.5.1 funcionar.

## [0.5.0] — 2026-05-25

### Adicionado

- **Opção 3 no menu — Instalar Tema RAD-PBX**. Nova entrada que baixa o tema do repositório privado `rdebruem/rad-pbx-theme` (branch `main`) e instala dois artefatos no servidor Issabel:
  - Pasta `www/html/themes/rad-pbx/` do repo → `/var/www/html/themes/rad-pbx/` no destino (owner detectado do Apache, dirs `755` / arquivos `644` via `chmod u=rwX,go=rX`).
  - Arquivo `usr/local/sbin/motd.sh` do repo → `/usr/local/sbin/motd.sh` no destino, com permissão exata **`-rwxr-xr-x` (`755`) `root:root`** — banner executado pelo PAM em login SSH precisa ser executável por todos e imutável pelo usuário comum.
  - Função `install_rad_pbx_theme()` em `install.sh`.
- **Helper `github_download_tarball()`** — baixa o tarball completo de um repo privado via endpoint `GET /repos/{owner}/{repo}/tarball/{ref}` da GitHub API, com `curl -L` pra seguir o 302 → S3 e validação de magic bytes gzip (`1f 8b`) defensiva contra body JSON de erro. Necessário porque a pasta `rad-pbx/` do tema tem centenas de imagens — file-by-file via Contents API estouraria o rate limit do GitHub (5000 req/h) em uma única instalação.
- **Constantes do tema** no topo do `install.sh`: `THEME_REPO_OWNER`, `THEME_REPO_NAME`, `THEME_REPO_BRANCH`, `THEME_PATH_IN_REPO`, `MOTD_PATH_IN_REPO`, `THEME_INSTALL_DIR`, `MOTD_INSTALL_PATH`, `MOTD_INSTALL_MODE`, `MOTD_INSTALL_OWNER`.
- Backup automático antes de sobrescrever — tema existente vira `${THEME_INSTALL_DIR}.bak.<UTC-timestamp>` (via `mv`) e `motd.sh` existente vira `${MOTD_INSTALL_PATH}.bak.<UTC-timestamp>` (via `cp -p` pra preservar mtime/perms).
- Aplicação de contexto SELinux via `restorecon -Rv` no diretório do tema e `restorecon -v` no `motd.sh` (no-op se SELinux disabled).

### Mudado

- **Refatorado `get_github_token()`** pra aceitar `owner`, `repo` e descrição do artefato como argumentos (com defaults pro caminho legado). `GITHUB_TOKEN` env var continua sendo honrado — um único PAT com escopo amplo serve pra múltiplos repos.
- **Refatorado `github_download_file()`** pra aceitar `owner`, `repo`, `branch` como argumentos em vez de usar constantes globais. A opção 1 (rad-contacts.php) foi atualizada pra passar `SOURCE_REPO_OWNER_DEFAULT`/`NAME_DEFAULT`/`BRANCH` explicitamente — comportamento idêntico ao anterior.
- `install.sh` v0.5.0 — feature nova (terceira opção do menu), bump minor.

### Notas

- O tema é versionado por designer no repo `rad-pbx-theme`, separado do `rad-ecosystem` (que tem ciclo de release de engenharia). Mesma justificativa de [ADR-0210] aplicada ao tema.
- Pra criar o PAT do repositório do tema: `https://github.com/settings/personal-access-tokens/new` → escolher "Only select repositories" e marcar `rdebruem/rad-pbx-theme` → permissão `Contents: Read-only`. Token válido por até 1 ano; reusar entre opções 1 e 3 via `export GITHUB_TOKEN=...` antes de rodar o instalador.

## [0.4.0] — 2026-05-25

### Adicionado

- **Opção 2 no menu — Instalar áudios PT-BR (módulo Issabel PBX PT-BR)**. Nova entrada que executa o script `patch-issabelbr.sh` mantido pelo projeto `ibinetwork/IssabelBR` no GitHub, copiando áudios em português brasileiro pra central Issabel (URAs, prompts de voicemail, sons do sistema). Função `install_ptbr_audios()` em `install.sh`.
  - Aviso explícito de que o script é mantido por terceiros e roda como root, com `confirm()` obrigatório antes de baixar/executar.
  - Pre-flight `require_cmd wget` + `require_cmd bash`.
  - Executa exatamente o comando documentado pelo upstream: `wget -O - https://github.com/ibinetwork/IssabelBR/raw/master/patch-issabelbr.sh | bash`.
  - Captura exit code via `PIPESTATUS[1]` (sem deixar a falha do patch matar o instalador via `set -e`) e loga sucesso/falha no `LOG_FILE`.
  - Sugestão de pós-instalação (`asterisk -rx "core reload"` + teste de URA pra confirmar prompts em PT-BR).
- Constante `PTBR_PATCH_URL` no topo da seção pra facilitar troca da fonte se o upstream mover.

### Mudado

- `install.sh` v0.4.0 — feature nova (segunda opção do menu), bump minor.

### Notas

- O patch upstream toca em arquivos do Asterisk (`/var/lib/asterisk/sounds/`) — recomenda-se snapshot/backup do servidor antes de aplicar em produção. O instalador NÃO faz esse backup por padrão; isso fica a critério do operador.
- Como o script é externo ao repo `rad-pbx-api`, mudanças no upstream são herdadas automaticamente. Se desejar pin de versão, baixe o `.sh` pra um espelho próprio e ajuste `PTBR_PATCH_URL`.

## [0.3.2] — 2026-05-20

### Corrigido

- **`write = command,system,call`** na seção AMI do `manager.conf` — antes ficava vazio e bloqueava `Action: Command`, necessário pelo fallback `core show hints` em Asterisk < 13.7 (caso típico do Issabel). Sintoma sem o fix: AMI loga "Permission denied" no `ActionID: hints-*` e nenhum hint é coletado — endpoint retorna `presence` vazio mesmo com `amiOk: true`.
- O usuário AMI continua restrito a `127.0.0.1` via `permit`/`deny`, então a superfície de risco com o write expandido permanece **zero** em deployments típicos (AMI nunca exposto ao cliente).

Identificado no segundo deploy real em Asterisk 11.25.3 + Issabel — `Response: Error / Message: Permission denied` aparecia no dump bruto do socket AMI.

## [0.3.1] — 2026-05-20

### Corrigido

- **Regex case-sensitive em `manager show user`** dava falso warn "read perm não parece estar completo" mesmo quando o usuário AMI estava configurado certinho. Causa: o `asterisk -rx "manager show user X"` às vezes retorna `read perm:` (minúsculo) e o `grep -qE "Read perm:"` (maiúsculo) não batia. Fix: `grep -qiE` (case-insensitive).
- **Regex do JSON `format` falhava com pretty-print**: o PHP serializa com `JSON_PRETTY_PRINT` (espaço após `:`), o instalador procurava `"format":"rad-contacts-v1"` sem espaço. Resultado: endpoint HTTP 200 com body correto era reportado como warn "Endpoint respondeu HTTP 200. Inspecione...". Fix: regex `"format"[[:space:]]*:[[:space:]]*"rad-contacts-v1"` aceita pretty e compacto.

Ambos são bugs cosméticos no diagnóstico final do install.sh — não afetam funcionamento, mas davam impressão errada de "instalação com problemas" quando estava tudo OK.

## [0.3.0] — 2026-05-20

### Adicionado

- **BLF/presença via AMI server-side no `rad-contacts.php`** ([ADR-0215](https://github.com/rdebruem/rad-ecosystem) — repo privado). A cada hit do polling do cliente (a cada 15s), o PHP abre conexão AMI em `127.0.0.1:5038`, dispara `Action: ExtensionStateList`, mapeia o `Status` numérico do Asterisk pro enum `Presence` do RAD (`available`, `on_call`, `busy`, `offline`), popula `presence` + `statusText` em cada contato do response, fecha conexão. Cliente Electron já tem pipeline pronto (`useContactsStore` escuta `presence:update`, UI mostra bolinha colorida + rótulo "Livre / Em chamada / Ocupado / Ausente / Offline").
- **`install.sh` agora grava `AMI_USER` e `AMI_SECRET` no PHP automaticamente** (`php_set_ami_creds()`). As credenciais já eram perguntadas e gravadas no `manager.conf`; agora também vão pro PHP via `sed`. Usuário final não precisa de etapa manual extra.
- Response do endpoint ganhou campo `amiOk: bool` indicando se a coleta AMI deu certo nesta request (UI ignora silenciosamente quando false; lista de contatos segue funcional sem `presence`).

### Mudado

- `install.sh` v0.3.0 — feature nova (BLF), bump minor.

### Notas técnicas

- Falha graceful: se AMI cai ou login falha, o request HTTP continua respondendo a lista de ramais sem presence (vs falhar com 500). `amiOk: false` sinaliza ao cliente que aquela rodada veio sem BLF.
- Timeout AMI default: 3 segundos (constante `AMI_TIMEOUT_MS` no PHP). Suficiente pra AMI local em 127.0.0.1; ajustável se algum cliente tiver carga atípica.
- Mapeamento `ExtensionStatus` code → `Presence` mantém paridade com `electron/ami.ts:amiStatusToPresence()` (cliente AMI direto, alternativo).
- BLF só aparece pra ramais com `hint` definido no dialplan. FreePBX/Issabel padrão gera hints automaticamente pra cada ramal. Ramais sem hint vão pro estado "Desconhecido" (cinza) na UI.

## [0.2.0] — 2026-05-20

### Adicionado

- **Autenticação HTTP Basic com credenciais SIP** no `rad-contacts.php` (decisão canônica: [ADR-0214](https://github.com/rdebruem/rad-ecosystem) — repo privado). User final do RAD Softphone passa a NÃO PRECISAR de API key — basta marcar ☑ "Sincronizar contatos com a central" na seção da conta SIP do app. O cliente autentica usando `Authorization: Basic base64(ramal:senha)` e o servidor valida contra o `secret` que já está no `sip_additional.conf`.
- O endpoint agora distingue dois modos de auth:
  - **Modo basic** (default): exige HTTPS, autentica como o ramal SIP. Granular por usuário (cada operador autentica como ele mesmo, sem chave compartilhada).
  - **Modo apikey** (retrocompat): caminho original do ADR-0209. Útil pra scripts CI, integrações externas, ambientes onde Basic Auth não cabe.
- Mensagem final do instalador reformulada com 2 blocos distintos:
  - **"Para o usuário final"** — explica o fluxo simples (não precisa API key).
  - **"Para o admin / scripts CI"** — mostra a API key gerada (modo legacy/admin).

### Mudado

- Endpoint URL exibida no resumo final agora usa `https://` por default (era `http://`). Reflete a recomendação de HTTPS obrigatório quando em modo Basic.
- Log do servidor agora aparece com prefixo `[rad-contacts]` em casos de falha de auth Basic — facilita filtragem.

### Notas de segurança

- **Senha SIP em Basic Auth viaja em base64 sob TLS**: não é criptografia, mas é equivalente à proteção do canal SIP-over-UDP (modelo de ameaça já aceito). HTTPS obrigatório no modo Basic — cliente e servidor recusam em HTTP puro (servidor retorna `426 Upgrade Required`).
- **md5secret no Asterisk**: setups que armazenam senha como hash (raro em FreePBX/Issabel) não funcionam com modo Basic — o servidor responde 401 e o user precisa usar modo apikey via config avançada.
- **Brute force**: configure rate limit no Apache (fail2ban / mod_evasive). Documentar em runbook posterior.

## [0.1.3] — 2026-05-20

### Corrigido

- **Menu ainda saía em `curl|sudo bash` mesmo após o `exec </dev/tty` da v0.1.2.** Causa: em algumas configurações de `sudo`/SSH o `exec </dev/tty` aparenta funcionar (`/dev/tty` é legível) mas não torna stdin um tty efetivo pros `read`. Aplicada defesa em camadas:
  - Diagnóstico explícito no startup: imprime `[diagnóstico] stdin é tty? SIM/NÃO · /dev/tty acessível? SIM/NÃO` antes de qualquer interação.
  - Belt-and-suspenders: cada `read` interativo (`prompt`, `prompt_secret`, `confirm`, menu) passa `</dev/tty` explicitamente como redirect.
  - Caso `""` (input vazio) no menu agora aborta com mensagem clara apontando pra Opção 1 do README (`wget && sudo ./install.sh`), em vez de sair silenciosamente como se fosse `q`.
- **README**: promovida Opção 1 (`wget && sudo ./install.sh`) ao topo como recomendada; `curl|bash` virou Opção 3 com aviso explícito sobre o caveat de TTY.

## [0.1.2] — 2026-05-20

### Corrigido

- **Menu sai silenciosamente quando o script é executado via `curl ... | sudo bash`** (one-liner do README). Causa: o pipe do curl ocupa o stdin do bash, então o `read -r -p "Escolha uma opção:"` recebe EOF imediato e o `case` cai no padrão vazio (`""`), que faz `exit 0` por design. Fix: detecta `[[ ! -t 0 ]]` no início do `main()` e reanexa `/dev/tty` via `exec </dev/tty`. No-op quando o script roda como `./install.sh` (stdin já é tty). Mensagem de erro clara se `/dev/tty` for inacessível (ex.: containers sem TTY alocado).
- **Banner mostrava `versão 0.1.0`** mesmo no release v0.1.1 — `SCRIPT_VERSION` não havia sido bumpado junto com as outras mudanças. Agora reflete a versão corrente.

## [0.1.1] — 2026-05-20

### Corrigido

- **Detecção dinâmica do user efetivo do Apache** (`detect_apache_owner()`). Antes o script assumia `apache:apache` hardcoded — quebrava em Issabel, que sobrescreve o user padrão pra `asterisk` via `/etc/httpd/conf.d/issabel.conf`. Agora detecta via `ps -eo user,comm` (worker process, ignora master root) + fallback parse de `/etc/httpd/conf.d/*.conf` e `/etc/apache2/apache2.conf`.
- **`chown -R` no diretório E no arquivo** (antes só no arquivo). Importante porque `mkdir -p` cria o dir como `root:root`, e suEXEC checa o owner do dir além do arquivo.
- **Fallback automático `chmod 644`** quando HTTP 500 com body vazio (sinal típico de ionCube exigindo world-readable). Loga warning explicando o trade-off (API key fica world-readable na máquina). Não roda se a primeira tentativa com `640` já funcionar.
- **`restorecon -Rv` opcional** — defesa em profundidade pra SELinux enforcing. No-op em sistemas sem SELinux ou sem o comando.

### Notas técnicas

Sintoma diagnosticado durante o primeiro deploy em Issabel real (10.100.x.x):

```
[warn-ioncube] mmap cache can't open /var/www/html/rad-api/contacts.php - Permission denied
```

```
PHP Fatal error: Failed opening required '/var/www/html/rad-api/contacts.php' (...) in Unknown on line 0
```

Causa raiz: Apache no Issabel roda como `asterisk` (não `apache`), e o chown estava aplicando `apache:apache`. Fix manual com `chown asterisk:asterisk` + `chmod 640` resolveu sem precisar do fallback 644.

## [0.1.0] — 2026-05-20

### Adicionado

- Script `install.sh` interativo com menu.
- Opção 1: instalação do `rad-contacts.php` (endpoint HTTP de contatos pro RAD Softphone).
  - Download do repo privado `rdebruem/rad-ecosystem` via GitHub Contents API.
  - Autenticação por token (variável `GITHUB_TOKEN` ou prompt interativo).
  - Geração automática de API key (`openssl rand -hex 32`).
  - Substituição segura da constante `RAD_API_KEY` no PHP via `sed` com verificação pós-substituição.
  - Provisionamento de usuário AMI dedicado no `/etc/asterisk/manager.conf` com `permit = 127.0.0.1` e `read = system,call,user,reporting`.
  - Backup datado do `manager.conf` antes de qualquer alteração.
  - Reload do manager + `manager show user` pra validação.
  - Curl de teste no endpoint local.
- Pre-flight checks (root, comandos requeridos, Apache rodando, Asterisk respondendo).
- Logging centralizado em `/var/log/rad-pbx-api-installer.log` (sem segredos).
- Idempotência:
  - Detecção de instalação prévia do PHP (pergunta antes de sobrescrever).
  - Detecção de seção AMI duplicada (não recria).
- README com troubleshooting, fluxo esperado e exemplo de saída.
- LICENSE MIT.
