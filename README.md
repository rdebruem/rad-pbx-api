# RAD-PBX-API

Instalador interativo de componentes do ecossistema **RAD** no servidor **Issabel** — pensado pra rodar uma vez por servidor em ambiente B2B, onde cada cliente do Grupo RAD tem sua própria PBX.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## O que é

Um único script `install.sh` apresenta um menu com componentes que podem ser provisionados na Issabel:

1. **API de contatos** — endpoint HTTP que o RAD Softphone consome pra puxar a lista de ramais da central.
2. **Áudios PT-BR** — aplica o patch da comunidade [ibinetwork/IssabelBR](https://github.com/ibinetwork/IssabelBR) (prompts de URA, voicemail e sons do sistema em português brasileiro).
3. **Tema RAD-PBX** — baixa o tema do repositório privado `rdebruem/rad-pbx-theme` e instala em `/var/www/html/themes/rad_pbx/`, substituindo também o `/var/www/html/favicon.ico` (mode 644, owner apache) e o `/usr/local/sbin/motd.sh` (banner SSH) com permissões `-rwxr-xr-x root:root`.

Mais opções entram conforme o ecossistema cresce.

## Pré-requisitos

- Servidor **Issabel** (ou Asterisk equivalente) com `bash 4+`, `curl`, `wget`, `openssl`, `tar` e `asterisk` CLI.
- Acesso `root` (ou `sudo`).
- Para a opção 1 (API de contatos): **token de acesso** ao repositório privado `rdebruem/rad-ecosystem`. Solicite ao mantenedor.
- Para a opção 3 (Tema RAD-PBX): **token de acesso** ao repositório privado `rdebruem/rad-pbx-theme`. O mesmo `GITHUB_TOKEN` pode ser reusado entre opções 1 e 3 se o PAT tiver escopo nos dois repos.

### Criando o GitHub PAT (fine-grained, recomendado)

1. Acesse https://github.com/settings/personal-access-tokens/new.
2. **Repository access**: marque "Only select repositories" e selecione o(s) repo(s) que você precisa (`rad-ecosystem` para opção 1, `rad-pbx-theme` para opção 3).
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
