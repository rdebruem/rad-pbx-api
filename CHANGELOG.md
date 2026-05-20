# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — versionamento [Semantic Versioning](https://semver.org/).

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
