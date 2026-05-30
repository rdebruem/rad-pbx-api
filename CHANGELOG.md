# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — versionamento [Semantic Versioning](https://semver.org/).

## [0.13.0] — 2026-05-30

### Adicionado (nova opção 4 — RAD Connector via repo privado)

- **Nova opção 4 no menu: "Instalar RAD Connector (preparo da central pra Platform)"** (`install_rad_connector`). Provisiona os 4 usuários técnicos que o backend do RAD PBX Platform usa pra falar com a central (SSH, AMI, MariaDB, ECCP), aplicando o **template padrão do grupo RAD** — mesmo script que a Central de Ajuda do RAD PBX Platform gera dinamicamente quando o admin escolhe "usar valores padrão".
  - **O script de preparo vive no monorepo PRIVADO `rdebruem/rad-ecosystem`** em `apps/rad-pbx-platform/scripts/rad-connector/setup-default.sh`, porque contém credenciais técnicas compartilhadas (usuários e senha do grupo RAD). Este repo é público, então o template NÃO pode ser embutido inline. A opção 4 baixa via Contents API com GitHub PAT (mesma UX das opções 1 e 5).
  - **Pré-flight**: existência do usuário `asterisk`, `/etc/asterisk/manager.conf` presente, cliente `mysql` instalado. Aviso explícito antes de confirmar: o template default usa BACKEND_IP=0.0.0.0 (libera AMI 5038 e MariaDB 3306 pra qualquer origem) — pressupõe rede confiável + firewall externo. Pra restringir, regere o script pela UI da Platform.
  - **Sanity check** pós-download: rejeita arquivo sem shebang `#!.*bash` (defesa contra ler texto bruto da API REST quando o path está errado).
  - **Token zerado em memória** logo após o download.
  - **Cleanup garantido** do arquivo temp (`trap rm`), inclusive em falha.
  - O script em si é idempotente (chpasswd; bloco AMI removido+reescrito; `GRANT USAGE ... IDENTIFIED BY` + `SET PASSWORD` em MariaDB 5.5→MySQL 8; `ON DUPLICATE KEY UPDATE` no ECCP; detecção da coluna de hash entre `md5_password`/`password`/`secret`/`passwd`).
- **A antiga opção 4 (RAD-PROTOCOLO) virou opção 5.** Nenhuma mudança funcional — só o número e os comentários internos (`5.0`…`5.9`).
- **`SCRIPT_VERSION` 0.12.0 → 0.13.0.**

### Segurança

- **NADA de credenciais hardcoded neste repo público.** O instalador conhece apenas o **path** do template no monorepo privado (`CONNECTOR_REPO_PATH`); usuários, senha e BACKEND_IP ficam no template (privado). Quem clona este repo sem o PAT do `rad-ecosystem` consegue rodar as opções 2 (áudios PT-BR, fonte pública) mas não as 1/3/4/5.

> Migração: quem usava `4` no menu pra rodar o RAD-PROTOCOLO precisa digitar `5` na 0.13.0. Não há mudança em arquivos instalados. Pra rodar a opção 4 nova: PAT com `Contents: Read-only` em `rdebruem/rad-ecosystem`.

## [0.12.0] — 2026-05-30

### Adicionado (opção 4 — auto-instalação de dependências)

- **A opção 4 agora INSTALA as dependências que faltarem em vez de só abortar.** Antes, um servidor sem `python3` (caso comum no Issabel/CentOS 7 recém-provisionado) parava com `✗ Comando 'python3' não encontrado. Instale antes: yum install -y python3`. Agora o instalador detecta o gerenciador de pacotes e resolve sozinho.
  - Novos helpers `_pkg_mgr` (detecta `dnf`/`yum`/`apt-get`) e `_pkg_install` (instala um pacote pelo gerenciador detectado).
  - Nova função `_proto_ensure_deps` (passo 4.0): garante `coreutils` (`install`), `python3` e a stdlib essencial (`json`/`secrets` — o import valida 3.6+ de quebra), instalando `python3` e `python3-libs` quando ausentes. Idempotente; só age no que falta. Como o instalador roda via `sudo`, o `yum`/`dnf`/`apt` funciona.
  - O check de usuário `asterisk` **continua um erro fatal** (não dá pra "instalar" um servidor Asterisk — se o usuário não existe, não é uma central).
  - Mensagens claras de fallback: se não houver gerenciador de pacotes, ou se a instalação falhar, aborta com o comando manual exato.
- **`SCRIPT_VERSION` 0.11.0 → 0.12.0.**

## [0.11.0] — 2026-05-29

### Adicionado (opção 4 — setter do padrão + sudoers, ADR-0112 P-5)

- **A opção 4 agora instala o setter privilegiado `rad-pbx-set-pattern`** em `/usr/local/sbin/` (root:root 755) e configura o sudoers para a Platform gravar o padrão via SSH. É a contraparte do push implementado no backend (`SshService.execSetProtocolPattern`): a Platform faz `ssh <central> 'sudo -n /usr/local/sbin/rad-pbx-set-pattern' < pattern.json`.
  - O setter lê o JSON do stdin, valida (`template` obrigatório, `sequenceStrategy` ∈ ulid/uuid/sequence) e grava `/etc/rad-pbx/protocol-pattern.json` atomicamente como root:asterisk 640. **Destino fixo** (não aceita path por argumento) — fronteira de segurança.
  - Novo passo no instalador (`_proto_setup_sudoers`): pergunta o **usuário SSH** que a Platform usa nesta central e grava `/etc/sudoers.d/rad-pbx-protocol` com `<user> ALL=(root) NOPASSWD: /usr/local/sbin/rad-pbx-set-pattern`, **validado por `visudo -cf`** antes de instalar (440 root:root). Deixar o usuário vazio (conexão root) pula o sudoers. Mesmo modelo de privilégio do `fwconsole reload`.
  - Baixa 4 artefatos (antes 3): AGI + core + stub + setter.
- **`SCRIPT_VERSION` 0.10.0 → 0.11.0.**

## [0.10.0] — 2026-05-29

### Mudado (opção 4 — RAD-PROTOCOLO agora é central autônoma, ADR-0112)

- **A opção 4 foi reescrita para o modelo de central autônoma do [ADR-0112](https://github.com/rdebruem/rad-ecosystem)**, que supersede a camada de runtime do ADR-0110. A central deixa de depender da Platform em tempo de execução: o AGI lê o padrão de um arquivo **local** (`/etc/rad-pbx/protocol-pattern.json`) e grava o protocolo no `CDR(accountcode)`. A Platform passa a **empurrar** o padrão por SSH e a **ler** os registros do CDR (não há mais POST do AGI).
  - **Removido da instalação**: os prompts de `baseUrl`/token/timeouts/backlog; o serviço `rad-pbx-protocol-sync` (+ unit/timer systemd); os diretórios `/opt/rad-pbx/bin`, `/var/cache/rad-pbx` e `/var/spool/rad-pbx`; e o arquivo `protocol-agi.json`. A dependência de `systemd` também sai.
  - **Agora a opção 4 instala apenas**: `rad-protocolo.agi` + `rad_protocolo_core.py` em `/var/lib/asterisk/agi-bin/`, o stub `extensions_rad.conf`, o `#include` idempotente, e **semeia um padrão default** em `/etc/rad-pbx/protocol-pattern.json` (`PROT-{YYYY}-{ULID}`, 640 root:asterisk) — a Platform sobrescreve via SSH ao salvar um padrão na UI.
  - **Baixa só 3 artefatos** do `rad-ecosystem` (antes 7); os 4 do `protocol-sync` foram descontinuados.
  - Smoke test simplificado: `dialplan reload` + `dialplan show rad-protocolo` + dry-run do AGI lendo o padrão local (sem teste de conectividade à Platform, que não se aplica mais).
- **`SCRIPT_VERSION` 0.9.0 → 0.10.0.**

> Migração: quem instalou a 0.9.0 num servidor pode rodar a 0.10.0 por cima (idempotente). Para limpeza, remover manualmente o que a 0.9.0 deixou e não é mais usado: `systemctl disable --now rad-pbx-protocol-sync.timer 2>/dev/null; rm -f /etc/systemd/system/rad-pbx-protocol-sync.{service,timer}; rm -rf /opt/rad-pbx /var/cache/rad-pbx /var/spool/rad-pbx /etc/rad-pbx/protocol-agi.json; systemctl daemon-reload`.

## [0.9.0] — 2026-05-29

### Adicionado (opção 4 — RAD-PROTOCOLO, ADR-0110)

- **Nova opção 4 no menu: "Instalar RAD-PROTOCOLO (número de protocolo — ADR-0110)"** (`install_rad_protocolo`). Implementa o CP-8 do [ADR-0110](https://github.com/rdebruem/rad-ecosystem) — a camada de servidor da geração de número de protocolo de chamada (AGI Python + serviço systemd de reconciliação de spool + stub de dialplan).
  - **Mesma UX de download das opções 1 e 3**: pede um GitHub PAT (`get_github_token`) e baixa via Contents API (`github_download_file`) só os 7 artefatos necessários do monorepo privado `rdebruem/rad-ecosystem@main`, sob `apps/rad-pbx-platform/scripts/`. **Pré-requisito**: esses arquivos precisam estar na `main` do monorepo.
  - **Artefatos instalados** (com backup do anterior, owner/mode corretos): `rad-protocolo.agi` + `rad_protocolo_core.py` em `/var/lib/asterisk/agi-bin/` (asterisk:asterisk); `rad-pbx-protocol-sync` + `rad_protocolo_sync.py` em `/opt/rad-pbx/bin/` (root:root); `extensions_rad.conf` em `/etc/asterisk/`; unit+timer systemd em `/etc/systemd/system/`.
  - **Diretórios criados** (idempotente): `/etc/rad-pbx` (750 root:asterisk), `/var/cache/rad-pbx` e `/var/spool/rad-pbx/protocol-records` (750 asterisk:asterisk), `/opt/rad-pbx/bin` (755 root:root).
  - **Config `/etc/rad-pbx/protocol-agi.json`** (640 root:asterisk) gerada via prompts (baseUrl, token, TTL, timeouts, limites de backlog, verifyTls). Serializada por `python3` com `umask 077` — **o token nunca é logado nem passa por argv**.
  - **`#include extensions_rad.conf`** adicionado ao `extensions.conf` de forma idempotente (grep antes de append, com backup).
  - **Timer do sync** habilitado via `systemctl enable --now rad-pbx-protocol-sync.timer`.
  - **Smoke test**: `dialplan reload` + `dialplan show rad-protocolo`, dry-run isolado do AGI (base_url vazia + cache/spool em tmp — **não posta na Platform nem polui o spool real**), e teste de conectividade/TLS/auth no `/api/v1/protocols/patterns/active`.

### Decisões de design

- **O instalador NÃO altera roteamento do FreePBX/Issabel.** Instala o contexto `[rad-protocolo]` como subrotina inerte (termina em `Return()`, sem `Answer()`); enquanto nenhuma Inbound Route fizer `Gosub(rad-protocolo,s,1)`, o impacto é zero. O wiring por-rota é manual e validado (canary), conforme o runbook `protocol-cutover`. Motivo: editar contextos gerados pelo FreePBX (versão antiga no fork do Issabel) é o real risco de quebra; mantê-lo inerte é seguro e reversível.
- **`SCRIPT_VERSION` 0.8.0 → 0.9.0** (feature aditiva, sem breaking).

## [0.8.0] — 2026-05-26

### Mudado (breaking — destino do bloco AMI)

- **`MANAGER_CONF` agora aponta pra `/etc/asterisk/manager_custom.conf`** em vez do `manager.conf` principal. Descoberta empírica durante o incidente do servidor Issabel do Renato (mesmo dia da v0.7.0): editar o `manager.conf` principal — **mesmo só com append, sem rodar `asterisk -rx "manager reload"`** — dispara reload silencioso que derruba a sessão AMI estabelecida do `dialerd` (CallCenter), causando loop de `failed to authenticate as 'admin'` sem ninguém ter pedido reload. Provavelmente o `asterisk` tem `inotify` watch no arquivo principal (`/proc/<asterisk_pid>/fd/26 -> anon_inode:inotify` foi observado).
  - Validação empírica: testar `cat >> /etc/asterisk/manager_custom.conf` no estado de produção saudável (4 sessões admin ESTABLISHED) **não derrubou nenhuma sessão e não gerou nenhuma linha `failed to authenticate` no log**. Mesmo teste em `/etc/asterisk/manager.conf` derrubou uma sessão admin (FD 12) e iniciou o loop de fail.
  - O `manager_custom.conf` é incluído via `#include manager_custom.conf` do `manager.conf` principal (config padrão do Issabel/FreePBX) e é o local que o template do Issabel oficialmente designa pra customizações — já vem populado com `[phpconfig]`, `[phpagi]`, `[a2billinguser]`, `[AstTapi]`, `[remote_mgr]`. Não é vigiado pelo mesmo watcher inotify.
  - **Resultado prático:** a etapa "Configurar usuário AMI" do `install_contacts_api` (opção 1) agora **não derruba mais sessões AMI ativas no append**. A sessão de reload (`manager_safe_reload` da v0.7.0) continua sendo opt-in porque o reload em si ainda pode revelar divergência de senha entre `[admin]` e o que daemons têm cacheado — mas o problema de "dropar sessão sem reload" some.

### Notas

#### Contexto: como descobrimos

A v0.7.0 (poucos minutos antes) presumia que o gatilho era o `asterisk -rx "manager reload"` que o installer chamava. Após restaurar snapshot, o Renato fez **só o append no `manager.conf` principal** (sem nem chamar reload) e o CallCenter caiu mesmo assim — provando que a edição em si dispara o reload. Hipótese da vez: usar o include `manager_custom.conf`. Teste empírico no snapshot saudável confirmou: append no custom **não derruba nenhuma sessão**. Daí a v0.8.0.

A teoria de "reload do install.sh era o vilão" (v0.6.0 e v0.7.0) estava parcialmente certa — o reload tem o problema da divergência de senha — mas perdia o efeito do `inotify` que disparava reload **mesmo sem invocação explícita**. v0.8.0 ataca os dois: (1) edita no arquivo certo que não é vigiado, (2) mantém o reload opt-in da v0.7.0 + restart proativo de daemons pra cobrir o caso de divergência de senha quando o reload é manual.

#### Backwards compatibility

- **Quem rodou v0.7.0 ou anterior**: o bloco `[rad-localhost]` ficou no `manager.conf` principal. Na próxima rodada da v0.8.0, o `manager_section_exists` checa o `MANAGER_CONF` novo (custom), não acha lá → trata como instalação nova e adiciona no custom. O bloco antigo no `manager.conf` principal fica **órfão e ativo simultaneamente** (Asterisk aceita ambos — o último wins na ordem de leitura). Limpeza manual recomendada: `sed -i '/^\[rad-localhost\]/,/^\[/d' /etc/asterisk/manager.conf` ANTES de rodar a v0.8.0, ou ignorar (não causa problema funcional, só ocupa espaço).
- **Servidores que nunca rodaram o installer**: nenhuma migração necessária.

## [0.7.0] — 2026-05-26

### Mudado (breaking — UX do flow de reload AMI)

- **`asterisk -rx "manager reload"` agora é opt-in**, não mais automático. A v0.6.0 documentou no CHANGELOG (seção "Contexto: incidente failed to authenticate as 'admin'") que a causa raiz daquele incidente era cache stale de credenciais no `issabeldialer` — sintoma disparado *justamente pelo reload automático* que derruba sessões AMI ativas e força revalidação de senha em workers que tinham senha cacheada em memória. A v0.6.0 mitigou com aviso textual no resumo final; v0.7.0 promove a ação pra proativa antes do estrago acontecer.
  - Nova função `manager_safe_reload()` (seção "Reload seguro do manager + restart de consumidores AMI"). Antes do reload:
    1. Mostra snapshot de sessões AMI ativas via `asterisk -rx "manager show connected"` — operador vê EXATAMENTE quem vai ser derrubado.
    2. Exibe aviso explícito sobre impacto + sintoma típico (`failed to authenticate as 'admin' ~1×/s` no `/var/log/asterisk/full`).
    3. Pergunta `[s/N]` com default = N (mais seguro: preserva sessões ativas se operador não tiver certeza). Se recusar, devolve instruções pra rodar reload manualmente quando souber que pode derrubar conexões.
  - Retorno discriminado: `0`=reload OK, `1`=operador pulou, `2`=Asterisk não respondeu. Caller usa pra decidir se vale rodar o helper de restart na sequência.

### Adicionado (operacional — proativo)

- **Novo helper `restart_ami_consumers()`** roda automaticamente após reload bem-sucedido. Itera sobre `AMI_CONSUMERS_KNOWN=(issabeldialer fop2)` e pra cada daemon que está ativo no systemd:
  - Mostra `systemctl status -n 3` (últimas 3 linhas do journal) — operador vê na hora se está em loop de fail.
  - Pergunta `[s/N]` individualmente — cada equipe pode ter SLA distinto pra cada serviço (dialer derruba campanha em curso, fop2 zera live status do painel de operador).
  - Daemons inexistentes ou inativos são pulados silenciosamente — script funciona em Issabel mínimo (sem dialer/fop2) ou em Issabel completo.
- **`asterisk` NÃO está na lista `AMI_CONSUMERS_KNOWN` de propósito** — restart do asterisk derruba todas as chamadas E todos os registros SIP, é último recurso operacional que o admin faz manualmente, não algo que deve aparecer num fluxo guiado por sim/não.

### Notas

#### Contexto: por que separamos reload e restart de daemons em etapas independentes

O incidente da v0.6.0 mostrou três fases distintas: (1) instalador roda reload, (2) reload força revalidação de sessões AMI, (3) daemons com senha cacheada em memória começam loop de fail. O fix da v0.6.0 foi "avisar pro operador rodar `systemctl restart issabeldialer` depois". Mas o aviso aparecia DEPOIS do reload — quando o `/var/log/asterisk/full` já estava enchendo. O operador via o sintoma antes da solução.

A v0.7.0 inverte a ordem: o operador vê **quem está conectado** antes de decidir o reload, e o restart dos daemons é oferecido **automaticamente na sequência** se o reload foi efetivo. Mesmo escopo de mudança (manager.conf inalterado, perms inalteradas, AMI bloco inalterado) com fluxo operacional incrementalmente mais defensivo.

#### Backwards compatibility

- **Quem já rodou v0.6.0**: nada a migrar. `manager_safe_reload` substitui o trecho de `asterisk -rx "manager reload"` direto, e funciona em qualquer servidor Issabel sem dependência nova.
- **Quem roda v0.7.0 em ambiente onde `systemctl` não existe** (improvável em Issabel moderno, mas possível em servidores muito antigos): o loop de `restart_ami_consumers` falha silenciosamente (todos os `systemctl list-unit-files` retornam não-zero → daemons são pulados). Mensagem final "Nenhum consumidor AMI conhecido está ativo" aparece. Não bloqueia o resto da instalação.

## [0.6.0] — 2026-05-25

### Mudado (breaking — patch + UX)

- **`manager_add_user` agora é idempotente (add-or-replace)**. Rodadas repetidas do installer NÃO empilham mais blocos `[<user>]` nem comentários-marcador no `manager.conf`. Se o bloco já existe, é **substituído inteiro** (preservando todos os outros blocos como `[general]`, `[admin]` e blocos AMI de terceiros tipo `[fop2_user]`) e quaisquer marcadores órfãos de versões anteriores (`; ─── Adicionado pelo rad-pbx-api-installer v... ───` sem bloco correspondente) são removidos.
  - Nova função `manager_remove_block(user)` implementada via `awk` com 3 estados (in/out do bloco target + marker pendente). Algoritmo defensivo: usa regex ASCII puro pra não depender de UTF-8 no awk, e trata corretamente o caso onde múltiplos marcadores se acumularam de upgrades sucessivos.
  - **Contexto histórico:** observado num servidor real após múltiplas rodadas das versões 0.1.0 → 0.5.4 sem cleanup: 3 marcadores órfãos (`v0.1.0`, `v0.1.2`, `v0.3.0`) sobreviveram entre `[admin]` e `[rad-localhost]`. A v0.6.0 limpa esses resíduos na primeira rodada que rodar.
- **UX de "seção AMI já existe" mudou**. Antes: `Pular criação (sim) ou abortar pra você revisar (não)?` — escolher "sim" deixava o `manager.conf` com a senha antiga MAS o PHP com a senha nova (estado misto perigoso, causava failed-auth em loop até alguém reiniciar os serviços AMI). Agora: `Substituir bloco existente com NOVA senha (sim) ou cancelar setup AMI (não)?` — se cancela, **PHP também NÃO é tocado**, preservando o estado consistente atual.

### Adicionado (segurança)

- **Backups movidos pra fora do docroot do Apache**. Antes, todos os `.bak.<UTC-timestamp>` ficavam nos próprios diretórios dos artefatos — críticos como `/var/www/html/rad-api/contacts.php.bak.<UTC>` eram **servidos como texto pelo Apache** (extensão `.bak.<UTC>` não é interpretada como PHP) e expunham `RAD_API_KEY` e `AMI_SECRET` em claro pra quem adivinhasse o timestamp da URL. Agora **todos os 7 pontos de backup** centralizam em `/var/backups/rad-api/` com perms `0700 root:root`:
  - Nova constante `BACKUP_BASE_DIR=/var/backups/rad-api`.
  - Novos helpers `ensure_backup_dir` (cria com perms restritivas, idempotente) e `backup_path_for(tag)` (gera `${BACKUP_BASE_DIR}/<tag>.<UTC>`).
  - Migrados: `contacts.php`, `manager.conf`, `themes-rad_pbx`, `favicon.ico`, `lang-br.lang`, `motd.sh`, `modules-{agent_console,campaign_monitoring}`.
  - **Não migra backups antigos automaticamente.** Quem rodou v0.5.x ou anterior continua tendo `.bak.<UTC>` antigos em `/var/www/html/*` — remover manualmente é recomendado se a API key/AMI secret antigos forem sensíveis: `rm -rf /var/www/html/rad-api/*.bak.* /var/www/html/themes/*.bak.* /var/www/html/modules/*.bak.* /var/www/html/lang/*.bak.* /var/www/html/favicon.ico.bak.*`.

### Adicionado (operacional)

- **Aviso de restart de consumidores AMI no resumo final** da opção 1. Lista explicitamente `systemctl restart issabeldialer`, `systemctl restart fop2` e `systemctl restart asterisk` (opcional) — com explicação de por que (serviços AMI persistentes cachem a senha em memória no startup, então sem restart continuam mandando senha antiga em loop, sintoma típico `NOTICE manager.c ~1×/s` no `/var/log/asterisk/full`). Direcionamento direto fruto de incidente real diagnosticado durante o desenvolvimento desta versão — ver §Contexto abaixo.

### Auditado (sem mudança de código)

- **AMI perms (`AMI_READ_PERMS`, `AMI_WRITE_PERMS`) confirmadas cobrir todas as Actions emitidas hoje pelo `rad-contacts.php`**: `Login` (sem perm), `ExtensionStateList` (precisa `call` OU `reporting` — temos ambos), `Command "core show hints"` (precisa `write=command` — temos), `Logoff` (sem perm). Sobra `read=user` e `write=system,call` mantidos defensivamente pra futuras Actions admin (`Originate`, `Reload`) já documentadas no comentário existente do `install.sh`.

### Notas

#### Contexto: incidente "failed to authenticate as 'admin' ~1×/s"

O trabalho de v0.6.0 foi disparado por um sintoma observado em produção: tcpdump no `:5038` mostrava `Action: Login / Username: admin` em loop, e o `/var/log/asterisk/full` enchia de `NOTICE manager.c authenticate: 127.0.0.1 failed to authenticate as 'admin'` ~1×/s. Hipótese inicial: `rad-contacts.php` tinha `'admin'` hardcoded em vez de usar a constante `AMI_USER` patcheada pelo installer.

Investigação descartou todas as hipóteses do PHP/installer e fechou a causa raiz como **cache stale de credenciais nos workers persistentes do `dialerd`** (Issabel CallCenter). A senha em `call_center.valor_config` E em `manager.conf [admin]` estavam sincronizadas, mas os workers (PHP, processo master + forks) tinham carregado a senha antiga no startup e nunca recarregaram após alguém atualizar a senha do `[admin]`. **Fix:** `systemctl restart issabeldialer`. **Nenhum bug no `rad-pbx-api-installer` nem no `rad-contacts.php`.**

Mas a investigação validou empiricamente o sintoma de empilhamento (3 marcadores órfãos no `manager.conf` da produção) e gerou o aprendizado "alertar sobre restart de consumidores AMI" — daí o escopo desta release.

## [0.5.4] — 2026-05-25

### Adicionado

- **Módulos PHP `agent_console` e `campaign_monitoring` instalados pela opção 3**. A função `install_rad_pbx_theme()` agora também substitui as pastas completas dos dois módulos do Issabel:
  - `www/html/modules/agent_console/`        → `/var/www/html/modules/agent_console/`
  - `www/html/modules/campaign_monitoring/`  → `/var/www/html/modules/campaign_monitoring/`
  - **Substituição completa (NÃO merge)**: a pasta destino é movida pra `.bak.<UTC-timestamp>` via `mv` antes de copiar a nova via `cp -rp`. Merge causaria arquivos órfãos do módulo antigo coexistindo com o novo — e o autoloader do Issabel inclui tudo, então qualquer arquivo PHP órfão pode quebrar o módulo de forma sutil.
  - Owner = mesmo `apache_owner` detectado pra pasta do tema (em Issabel padrão = `asterisk:asterisk`).
  - Modo: dirs `755` / arquivos `644` via `chmod -R u=rwX,go=rX` (mesmo truque usado pro tema — `X` maiúsculo só dá exec em diretórios ou arquivos que já tinham, evita marcar PHP/HTML como executável).
  - `restorecon -Rv` em cada módulo (no-op se SELinux disabled).
- Constantes `MODULES_DIR_IN_REPO`, `MODULES_INSTALL_DIR` e o array `MODULES_TO_INSTALL=(agent_console campaign_monitoring)` no topo do `install.sh`. Adicionar/remover módulos no futuro é um one-liner — só alterar o array.
- Validação atômica estendida: o instalador checa que cada módulo do array existe no tarball ANTES de tocar em qualquer pasta do sistema. Se um dos módulos for removido do repo, o instalador aborta sem efeitos colaterais.
- `install.sh` v0.5.4 — patch (novos artefatos no pipeline, sem mudança de contrato).

### Notas

- Os módulos `agent_console` e `campaign_monitoring` substituem versões customizadas pelo RAD sobre a base Issabel. Backups datados ficam em `/var/www/html/modules/<nome>.bak.<UTC>` — útil pra comparar diffs depois (`diff -r <bak> <novo>`) ou rollback rápido (`mv` reverso).
- Se você adicionar mais módulos ao array no futuro, eles são processados na ordem listada — backups recebem timestamps separados, e qualquer falha em um módulo aborta antes dos próximos.

## [0.5.3] — 2026-05-25

### Adicionado

- **`br.lang` instalado pela opção 3**. A função `install_rad_pbx_theme()` agora copia também `www/html/lang/br.lang` do repo do tema para `/var/www/html/lang/br.lang` no servidor, sobrescrevendo o arquivo de idioma do Issabel. Aplica:
  - Owner = mesmo `apache_owner` detectado pra pasta do tema (em Issabel padrão = `asterisk:asterisk`).
  - Mode `644` — alinhado com os outros `.lang` de fábrica do Issabel (`en.lang`, `es.lang`, `pt-br.lang` etc.).
  - Backup `${BRLANG_INSTALL_PATH}.bak.<UTC-timestamp>` do arquivo existente antes de sobrescrever.
  - `mkdir -p` defensivo pro diretório `/var/www/html/lang/` caso ele não exista (Issabel modificado).
  - `restorecon -v` no arquivo (no-op se SELinux disabled).
- Constantes `BRLANG_PATH_IN_REPO`, `BRLANG_INSTALL_PATH` e `BRLANG_INSTALL_MODE` no topo do `install.sh`.
- Validação no extract: se `www/html/lang/br.lang` não existir no tarball baixado, o instalador aborta com mensagem clara antes de tocar em qualquer coisa do sistema (mesma estratégia atômica usada pro tema, favicon e motd).
- `install.sh` v0.5.3 — patch (artefato novo no pipeline de instalação do tema, sem mudança de contrato).

## [0.5.2] — 2026-05-25

### Adicionado

- **favicon.ico instalado pela opção 3**. A função `install_rad_pbx_theme()` agora copia também `www/html/favicon.ico` do repo do tema para `/var/www/html/favicon.ico` no servidor, substituindo o favicon original do Issabel. Aplica:
  - Owner = mesmo `apache_owner` detectado pra pasta do tema (em Issabel padrão = `asterisk:asterisk`).
  - Mode `644` — idêntico ao favicon de fábrica do Issabel (`-rw-r--r--`).
  - Backup `${FAVICON_INSTALL_PATH}.bak.<UTC-timestamp>` do favicon existente antes de sobrescrever.
  - `restorecon -v` no favicon (no-op se SELinux disabled).
- Constantes `FAVICON_PATH_IN_REPO`, `FAVICON_INSTALL_PATH` e `FAVICON_INSTALL_MODE` no topo do `install.sh`.
- Validação no extract: se `www/html/favicon.ico` não existir no tarball baixado, o instalador aborta com mensagem clara antes de tocar em qualquer coisa do sistema.
- `install.sh` v0.5.2 — patch (artefato novo no pipeline de instalação do tema, sem mudança de contrato).

## [0.5.1] — 2026-05-25

### Mudado

- **Rename da pasta do tema: `rad-pbx` → `rad_pbx`**. Hífen no nome do tema pode ser interpretado como operador em alguns pontos do Issabel/Asterisk que tratam o identificador como expressão (themesetup, queries SQL sem aspas adequadas). Underscore é seguro em todos os contextos. O **nome do repositório** no GitHub continua `rad-pbx-theme` — só a pasta interna foi renomeada.
  - Constante `THEME_PATH_IN_REPO`: `www/html/themes/rad-pbx` → `www/html/themes/rad_pbx`.
  - Constante `THEME_INSTALL_DIR`: `/var/www/html/themes/rad-pbx` → `/var/www/html/themes/rad_pbx`.
  - Textos do menu, prompts e instruções de pós-instalação atualizados.
  - Pasta renomeada via `git mv` no repositório `rad-pbx-theme` (histórico preservado).
- `install.sh` v0.5.1 — patch (rename de path, sem mudança comportamental).

### Notas

- Quem já tinha instalado a v0.5.0 e instalar a v0.5.1 vai ficar com **dois diretórios** no servidor: o antigo `/var/www/html/themes/rad-pbx/` (não removido automaticamente) e o novo `/var/www/html/themes/rad_pbx/`. Remova o antigo manualmente se não precisar mais (`rm -rf /var/www/html/themes/rad-pbx/`).

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
