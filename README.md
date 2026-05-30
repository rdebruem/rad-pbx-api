# RAD-PBX-API

Instalador interativo de componentes do ecossistema **RAD** no servidor **Issabel** — pensado pra rodar uma vez por servidor em ambiente B2B, onde cada cliente do Grupo RAD tem sua própria PBX.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## O que é

Um único script `install.sh` apresenta um menu com componentes que podem ser provisionados na Issabel:

1. **API de contatos** — endpoint HTTP que o RAD Softphone consome pra puxar a lista de ramais da central.
2. **Áudios PT-BR** — aplica o patch da comunidade [ibinetwork/IssabelBR](https://github.com/ibinetwork/IssabelBR) (prompts de URA, voicemail e sons do sistema em português brasileiro).
3. **Tema RAD-PBX** — baixa o tema do repositório privado `rdebruem/rad-pbx-theme` e instala em `/var/www/html/themes/rad_pbx/`, substituindo também o `/var/www/html/favicon.ico`, o `/var/www/html/lang/br.lang` (ambos mode 644, owner apache), os módulos PHP `/var/www/html/modules/agent_console/` e `/var/www/html/modules/campaign_monitoring/` (dirs 755 / arquivos 644, owner apache — substituição completa, não merge), e o `/usr/local/sbin/motd.sh` (banner SSH) com permissões `-rwxr-xr-x root:root`.
4. **RAD Connector (preparo da central pra Platform)** — baixa do `rdebruem/rad-ecosystem` (privado, mesmo repo das opções 1 e 5) o template padrão do grupo RAD em `apps/rad-pbx-platform/scripts/rad-connector/setup-default.sh` e executa na central. O template provisiona os 4 usuários técnicos que o backend do RAD PBX Platform usa pra conectar (SSH com sudo NOPASSWD restrito a `fwconsole reload` / `amportal a r`, AMI em `manager.conf`, MariaDB com CRUD sem DDL em `asterisk`/`call_center` + SELECT em `asteriskcdrdb`, ECCP autorizado em `call_center.eccp_authorized_clients`), com **credenciais compartilhadas do grupo** (usuários e senha vivem no template privado — não neste repo público). **Aviso de segurança**: o template default usa `BACKEND_IP=0.0.0.0`, liberando AMI (5038) e MariaDB (3306) pra qualquer origem; usar apenas em redes confiáveis ou atrás de outro firewall. Pra restringir (ou trocar usuários/senha), regere o script pela UI da Platform (Central de Ajuda → RAD Connector) e rode o que sair de lá. Requer `mysql` client local.
5. **RAD-PROTOCOLO (ADR-0112 — central autônoma)** — número de protocolo de chamada. Baixa do `rdebruem/rad-ecosystem` o AGI Python (`/var/lib/asterisk/agi-bin/`), o stub de dialplan (`/etc/asterisk/extensions_rad.conf`) e o setter `rad-pbx-set-pattern` (`/usr/local/sbin/`), e semeia um padrão default em `/etc/rad-pbx/protocol-pattern.json`. A central é **independente da Platform**: o AGI lê o padrão do arquivo local a cada chamada e grava o protocolo no `CDR(accountcode)` — sem rede, sem sync. A Platform sobrescreve o arquivo de padrão **via SSH** (rodando o setter com `sudo`) ao salvar na UI, e lê os registros **do CDR**. Por isso a opção 5 pergunta o **usuário SSH** que a Platform usa e grava uma regra NOPASSWD em `/etc/sudoers.d/rad-pbx-protocol` (validada por `visudo`). **Não altera roteamento**: o contexto `[rad-protocolo]` fica inerte até a Inbound Route fazer `Gosub(rad-protocolo,s,1)` (wiring manual e validado — ver runbook `protocol-cutover` no vault). Requer `python3` (o de fábrica do CentOS 7, 3.6.8, basta).

Mais opções entram conforme o ecossistema cresce.

## Pré-requisitos

- Servidor **Issabel** (ou Asterisk equivalente) com `bash 4+`, `curl`, `wget`, `openssl`, `tar` e `asterisk` CLI.
- Acesso `root` (ou `sudo`).
- Para as opções 1 (API de contatos), 4 (RAD Connector) e 5 (RAD-PROTOCOLO): **token de acesso** ao repositório privado `rdebruem/rad-ecosystem`. Solicite ao mantenedor.
- Para a opção 3 (Tema RAD-PBX): **token de acesso** ao repositório privado `rdebruem/rad-pbx-theme`. O mesmo `GITHUB_TOKEN` pode ser reusado entre as opções se o PAT tiver escopo nos repos.
- Para a opção 4 (RAD Connector): além do token, cliente `mysql` local (já presente em qualquer Issabel) e acesso root ao MariaDB local (autodetectado via `/root/.my.cnf` ou `/etc/amportal.conf`).
- Para a opção 5 (RAD-PROTOCOLO): `python3` instalado (CentOS 7: `yum install -y python3`) e os scripts do RAD-PROTOCOLO presentes na `main` do `rad-ecosystem`. (Não requer mais `systemd` — o modelo autônomo do ADR-0112 não usa o serviço de sync.)

### Criando o GitHub PAT (fine-grained, recomendado)

1. Acesse https://github.com/settings/personal-access-tokens/new.
2. **Repository access**: marque "Only select repositories" e selecione o(s) repo(s) que você precisa (`rad-ecosystem` para opções 1, 4 e 5; `rad-pbx-theme` para opção 3).
3. **Repository permissions**: marque `Contents: Read-only`.
4. Gere e copie o token (`github_pat_...`) — o GitHub não mostra de novo.

## Como usar

**Opção A — baixa, inspeciona, executa (recomendado):**

```bash
wget https://raw.githubusercontent.com/rdebruem/rad-pbx-api/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

**Opção B — token via env var (pula o prompt de token):**

```bash
sudo GITHUB_TOKEN=ghp_xxxx ./install.sh
```

**Opção C — one-liner via curl (ver caveat abaixo):**

```bash
curl -fsSL https://raw.githubusercontent.com/rdebruem/rad-pbx-api/main/install.sh | sudo bash
```

> ⚠️ **Sobre `curl | sudo bash`**: em algumas configurações de `sudo`/SSH o stdin fica preso ao pipe do curl e os prompts interativos pegam EOF, fazendo o menu sair sem aviso. O script tenta reanexar `/dev/tty` automaticamente; se mesmo assim falhar, ele aborta com mensagem clara. **Prefira a Opção A**; reserve a C pra ambientes sem `wget`.

## Idempotência e segurança

- Backups automáticos datados de qualquer arquivo do sistema antes de alterações.
- Confirmação interativa antes de sobrescrever instalações anteriores.
- Detecção de configuração duplicada — não recria o que já existe.
- Segredos (token, chaves, senhas) ficam só em memória durante a execução; nunca são gravados em log.
- Log da sessão em `/var/log/rad-pbx-api-installer.log` (sem segredos).

## Desenvolvimento

```bash
shellcheck install.sh
```

## Versionamento

[Semantic Versioning](https://semver.org/). Ver [CHANGELOG.md](CHANGELOG.md).

## Licença

MIT — ver [LICENSE](LICENSE).
