# RAD-PBX-API

Instalador interativo de componentes do ecossistema **RAD** no servidor **Issabel** — pensado pra ser executado uma única vez por servidor, em ambiente B2B onde cada cliente do Grupo RAD tem sua própria PBX.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## O que é

Um único script `install.sh` apresenta um menu com componentes que podem ser provisionados na Issabel:

1. **API de contatos** (`rad-contacts.php`) — endpoint HTTP que o RAD Softphone consome pra puxar a lista de ramais. Decidido em [ADR-0209](https://github.com/rdebruem/rad-ecosystem/blob/main/vault/04-ARCHITECTURE/adrs/ADR-0209-softphone-contacts-http-vs-ami.md) (repo privado).

Mais componentes entram conforme o ecossistema cresce.

## Como usar

### Pré-requisitos

- Servidor **Issabel** (ou Asterisk equivalente) com `bash 4+`, `curl`, `openssl`, `asterisk` CLI e Apache rodando.
- Acesso `root` (ou `sudo`).
- **Token de acesso** ao repo privado `rdebruem/rad-ecosystem`.
  - Crie em https://github.com/settings/tokens
  - Fine-grained: escopo `Contents: Read-only` no repo `rad-ecosystem`.
  - Classic: escopo `repo` (necessário pra acesso a repo privado).

### Execução

**Opção 1 — direto via curl (one-liner):**

```bash
curl -fsSL https://raw.githubusercontent.com/rdebruem/RAD-PBX-API/main/install.sh | sudo bash
```

**Opção 2 — baixa, inspeciona, executa (recomendado):**

```bash
wget https://raw.githubusercontent.com/rdebruem/RAD-PBX-API/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

**Opção 3 — token via env var (não interativo no prompt do token):**

```bash
sudo GITHUB_TOKEN=ghp_xxxx ./install.sh
```

### O que o instalador faz (opção 1 — API de contatos)

1. Pre-flight checks (root, comandos, Apache rodando, Asterisk respondendo).
2. Pede token GitHub (escondido) — ou usa `$GITHUB_TOKEN` se definido.
3. Baixa `rad-contacts.php` do repo privado via GitHub Contents API.
4. Gera API key forte automaticamente (`openssl rand -hex 32` — 256 bits).
5. Substitui a constante `RAD_API_KEY` no PHP.
6. Instala em `/var/www/html/rad-api/contacts.php` (`apache:apache`, mode `640`).
7. Pergunta nome do usuário AMI (default: `rad-localhost`) e senha (gera se vazia).
8. Adiciona seção `[user]` no `/etc/asterisk/manager.conf` com `permit = 127.0.0.1` e `read = system,call,user,reporting`.
9. Faz `asterisk -rx "manager reload"` + `manager show user <user>`.
10. Roda `curl` de teste no endpoint local com a API key.
11. Mostra resumo (URL, key, user/secret AMI) — guarde, não será mostrado de novo.

> O `rad-contacts.php` lê direto de `/etc/asterisk/sip_additional.conf` (texto plano, mode 644) — **não usa AMI**. O usuário AMI configurado é pro **cliente Electron** do RAD Softphone, que conecta direto no AMI:5038 pra obter eventos de presença em tempo real (BLF).

## Idempotência e segurança

- **Backup automático** do `manager.conf` antes de qualquer alteração (`*.bak.YYYYMMDDTHHMMSSZ`).
- **Backup automático** do `contacts.php` se já existir (sobrescrita requer confirmação).
- **Detecção de seção AMI duplicada** — não duplica `[rad-localhost]` se já existir.
- API key e AMI secret **NUNCA** são logados em disco (`/var/log/rad-pbx-api-installer.log` registra eventos sem segredos).
- Token GitHub fica só em memória durante a execução.
- PHP fica com permissão `640 apache:apache` (só o Apache lê).
- Usuário AMI fica restrito a `127.0.0.1` no `manager.conf`.

## Saída esperada

```
ℹ Pre-flight checks…
✓ Pre-flight OK.

╔══════════════════════════════════════════════════════════╗
║           RAD-PBX-API — Instalador Issabel               ║
║                                                          ║
║                  versão 0.1.0                            ║
╚══════════════════════════════════════════════════════════╝

Menu principal

  1)  Instalar API de contatos (rad-contacts.php)
       └─ endpoint HTTP que o RAD Softphone usa pra puxar ramais.

  q)  Sair

Escolha uma opção: 1

═══ Instalação da API de contatos ═══

GitHub token (input escondido): ********
ℹ Baixando apps/rad-softphone/server/issabel/rad-contacts.php (branch main)…
✓ Baixado com sucesso (HTTP 200, 11142 bytes).
ℹ Gerando API key (32 bytes hex = 256 bits)…
✓ API key gerada (64 caracteres hex).
✓ RAD_API_KEY gravada no PHP.
ℹ Instalando em /var/www/html/rad-api/contacts.php…
✓ Instalado: /var/www/html/rad-api/contacts.php (owner apache:apache, mode 640).

Configuração do usuário AMI
──────────────────────────────
Nome do usuário AMI [rad-localhost]: <enter>
Senha do AMI (input escondido — deixe vazio pra gerar automaticamente): <enter>
ℹ Senha AMI gerada automaticamente: AbCdEf123…
✓ Backup salvo em /etc/asterisk/manager.conf.bak.20260520T180000Z.
✓ Seção [rad-localhost] adicionada em /etc/asterisk/manager.conf.
ℹ Recarregando manager do Asterisk…
✓ Manager recarregado.
ℹ Verificando usuário com 'manager show user rad-localhost'…
       username: rad-localhost
        ...
       Read perm: system,call,user,reporting
✓ Usuário AMI provisionado corretamente.

ℹ Testando endpoint local com curl…
✓ Endpoint respondeu no formato esperado (rad-contacts-v1).
{
    "format": "rad-contacts-v1",
    "exportedAt": 1747459200,
    "count": 42,
    ...
}

═══ Instalação concluída ═══
  Endpoint URL:    http://10.100.0.204/rad-api/contacts.php
  API key:         <64 hex chars>
  Arquivo PHP:     /var/www/html/rad-api/contacts.php
  ...
```

## Troubleshooting

| Sintoma | Causa provável | Como resolver |
| --- | --- | --- |
| `GitHub HTTP 401` | Token inválido ou expirado | Gerar token novo |
| `GitHub HTTP 403` | Token sem permissão de leitura no repo privado | Adicionar scope `Contents: Read` (fine-grained) ou `repo` (classic) |
| `GitHub HTTP 404` | Caminho do PHP mudou no monorepo | Atualizar `PHP_PATH_IN_REPO` no `install.sh` |
| `Apache não está rodando` | Serviço parado | `systemctl start httpd` |
| `Asterisk CLI não respondeu` | Asterisk parado | `systemctl start asterisk` |
| `Já existe seção [rad-localhost]` | Reinstalação | Confirmar pular criação (a anterior continua válida) |
| `count: 0` no curl mas sem erro | Schema FreePBX diferente | Ver `mysql -u asteriskuser -p asterisk -e "SHOW TABLES;"` |

## Desenvolvimento

```bash
# Lint
shellcheck install.sh

# Teste local (sem tocar em sistema real — abort no preflight)
./install.sh   # vai falhar em "precisa rodar como root" — esperado
```

## Versionamento

[Semantic Versioning](https://semver.org/). Ver [CHANGELOG.md](CHANGELOG.md).

## Licença

MIT — ver [LICENSE](LICENSE).
