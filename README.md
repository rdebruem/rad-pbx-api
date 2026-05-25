# RAD-PBX-API

Instalador interativo de componentes do ecossistema **RAD** no servidor **Issabel** — pensado pra rodar uma vez por servidor em ambiente B2B, onde cada cliente do Grupo RAD tem sua própria PBX.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## O que é

Um único script `install.sh` apresenta um menu com componentes que podem ser provisionados na Issabel:

1. **API de contatos** — endpoint HTTP que o RAD Softphone consome pra puxar a lista de ramais da central.
2. **Áudios PT-BR** — aplica o patch da comunidade [ibinetwork/IssabelBR](https://github.com/ibinetwork/IssabelBR) (prompts de URA, voicemail e sons do sistema em português brasileiro).

Mais opções entram conforme o ecossistema cresce.

## Pré-requisitos

- Servidor **Issabel** (ou Asterisk equivalente) com `bash 4+`, `curl`, `wget`, `openssl` e `asterisk` CLI.
- Acesso `root` (ou `sudo`).
- Para a opção 1 (API de contatos): **token de acesso** ao repositório privado do projeto. Solicite ao mantenedor.

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
