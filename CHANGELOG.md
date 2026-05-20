# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — versionamento [Semantic Versioning](https://semver.org/).

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
