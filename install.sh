#!/usr/bin/env bash
#
# RAD-PBX-API — instalador interativo de componentes do ecossistema RAD
#                no servidor Issabel.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/rdebruem/RAD-PBX-API/main/install.sh | sudo bash
#   # OU baixa primeiro e roda local:
#   wget https://raw.githubusercontent.com/rdebruem/RAD-PBX-API/main/install.sh
#   chmod +x install.sh
#   sudo ./install.sh
#
# Requer: bash 4+, curl, openssl, asterisk CLI, apache rodando.
#
# Licença: MIT — ver LICENSE no repo.

set -euo pipefail

# ════════════════════════════════════════════════════════════════════════
#  Constantes e defaults
# ════════════════════════════════════════════════════════════════════════

readonly SCRIPT_NAME="rad-pbx-api-installer"
readonly SCRIPT_VERSION="0.11.0"

# Repo PRIVADO de onde os artefatos vêm. Não precisa mudar a menos que
# você queira testar contra um fork seu.
readonly SOURCE_REPO_OWNER_DEFAULT="rdebruem"
readonly SOURCE_REPO_NAME_DEFAULT="rad-ecosystem"
readonly SOURCE_REPO_BRANCH="main"

# Caminho do arquivo no repo privado.
readonly PHP_PATH_IN_REPO="apps/rad-softphone/server/issabel/rad-contacts.php"

# Onde instalar no servidor Issabel.
readonly INSTALL_DIR="/var/www/html/rad-api"
readonly INSTALL_FILE_NAME="contacts.php"
readonly INSTALL_PATH="${INSTALL_DIR}/${INSTALL_FILE_NAME}"

# Owner é detectado em runtime via detect_apache_owner() — em CentOS padrão
# costuma ser apache:apache, mas Issabel sobrescreve pra asterisk:asterisk
# via /etc/httpd/conf.d/issabel.conf, e outras distros podem variar.
readonly INSTALL_MODE_RESTRICTIVE="640"   # apache só (mais seguro)
readonly INSTALL_MODE_PERMISSIVE="644"    # world-readable (fallback ionCube)

# Repo PRIVADO do tema RAD-PBX (opção 3 do menu).
# Mantido separado do rad-ecosystem porque o tema tem ciclo de release
# independente e é versionado por designer, não por engenharia.
readonly THEME_REPO_OWNER="rdebruem"
readonly THEME_REPO_NAME="rad-pbx-theme"
readonly THEME_REPO_BRANCH="main"

# Caminhos DENTRO do repo do tema (relativos à raiz).
# Nome rad_pbx (com underscore, sem hífen) porque alguns pontos do
# Issabel/Asterisk tratam o nome do tema como identificador onde hífen
# pode ser interpretado como operador.
readonly THEME_PATH_IN_REPO="www/html/themes/rad_pbx"
readonly MOTD_PATH_IN_REPO="usr/local/sbin/motd.sh"
readonly FAVICON_PATH_IN_REPO="www/html/favicon.ico"
readonly BRLANG_PATH_IN_REPO="www/html/lang/br.lang"
# Módulos PHP do Issabel — pasta inteira é substituída (NÃO merge — o
# Issabel não tem mecanismo de "patch parcial" pra módulos, e arquivos
# órfãos do módulo antigo causam bugs sutis de inclusão).
readonly MODULES_DIR_IN_REPO="www/html/modules"
# Array dos módulos que a opção 3 mantém. Ordem é a que aparece nos prompts
# e backups; idempotente: rodar de novo gera novos .bak.<UTC> sem perda.
readonly MODULES_TO_INSTALL=(agent_console campaign_monitoring)

# Caminhos de destino no servidor Issabel.
# /var/www/html/themes/... é o layout padrão do Issabel pra temas.
readonly THEME_INSTALL_DIR="/var/www/html/themes/rad_pbx"
readonly MOTD_INSTALL_PATH="/usr/local/sbin/motd.sh"
# favicon.ico fica direto em /var/www/html — Issabel serve em /favicon.ico
# como qualquer navegador espera. Owner = apache (asterisk:asterisk em
# Issabel — detectado em runtime), mode 644 (igual ao favicon que vem
# de fábrica no Issabel).
readonly FAVICON_INSTALL_PATH="/var/www/html/favicon.ico"
readonly FAVICON_INSTALL_MODE="644"
# br.lang fica em /var/www/html/lang/ junto com os outros .lang do Issabel
# (en.lang, es.lang, pt-br.lang etc.). Mesmas permissões: apache_owner +
# mode 644.
readonly BRLANG_INSTALL_PATH="/var/www/html/lang/br.lang"
readonly BRLANG_INSTALL_MODE="644"
# Diretório destino dos módulos PHP do Issabel.
readonly MODULES_INSTALL_DIR="/var/www/html/modules"
# motd.sh é executado pelo PAM em cada login SSH (via pam_exec) — precisa
# ser executável por todos (-rwxr-xr-x = 755) e owner root:root pra evitar
# que usuários menos privilegiados sobrescrevam o banner do sistema.
readonly MOTD_INSTALL_MODE="755"
readonly MOTD_INSTALL_OWNER="root:root"

# Asterisk Manager Interface.
#
# IMPORTANTE — destino do bloco AMI é `manager_custom.conf`, NÃO o
# `manager.conf` principal. Descoberta empírica em 2026-05-26 (servidor
# Issabel 4.0.0-9 do Renato): editar `/etc/asterisk/manager.conf` —
# mesmo só com append, SEM rodar `asterisk -rx "manager reload"` —
# dispara reload silencioso que derruba a sessão AMI do dialerd
# (CallCenter), causando loop de `failed to authenticate as 'admin'`.
# Provavelmente o asterisk tem `inotify` no arquivo principal.
#
# O `manager_custom.conf` é incluído via `#include manager_custom.conf`
# do arquivo principal, mas NÃO é vigiado pelo mesmo watcher. É o local
# que o Issabel/FreePBX oficialmente designa pra customizações (vem com
# `[phpconfig]`, `[phpagi]`, `[a2billinguser]` etc. pré-cadastrados).
# Editar esse arquivo é totalmente safe pra produção em curso.
readonly MANAGER_CONF="/etc/asterisk/manager_custom.conf"
readonly AMI_USER_DEFAULT="rad-localhost"
readonly AMI_READ_PERMS="system,call,user,reporting"
# write=command é OBRIGATÓRIO pro Action:Command funcionar — o PHP usa
# Action:Command "core show hints" como fallback de BLF em Asterisk <13.7
# (Issabel típico). Sem isso, AMI responde "Permission denied" e nenhum
# hint é coletado. system,call adicionados pra preparação futura (Originate,
# Reload em pipelines admin). User fica restrito a 127.0.0.1 via permit/deny,
# então a superfície de risco continua nula em deployments típicos.
readonly AMI_WRITE_PERMS="command,system,call"

# ── RAD-PROTOCOLO (opção 4) — ADR-0112 (central autônoma) ───────────────
# Número de protocolo de chamada. A central é INDEPENDENTE da Platform em
# runtime: o AGI lê o padrão de um arquivo LOCAL (/etc/rad-pbx/protocol-pattern
# .json, escrito pela Platform via SSH), materializa o valor e grava no
# CDR(accountcode). Sem HTTP, sem spool, sem serviço de sync. Os scripts vêm
# do monorepo rad-ecosystem (mesmo SOURCE_REPO da opção 1), pasta abaixo.
#
# IMPORTANTE: o instalador NÃO toca em roteamento do FreePBX/Issabel. Ele
# instala o contexto [rad-protocolo] (subrotina inerte que termina em
# Return()), o AGI e um padrão default local. Enquanto nenhuma Inbound Route
# fizer Gosub(rad-protocolo,s,1), NADA acontece — zero impacto. O wiring
# por-rota é passo manual validado (ver runbook protocol-cutover).
readonly PROTO_REPO_DIR="apps/rad-pbx-platform/scripts"
# Arquivos baixados: "path-no-repo|destino|owner|mode|tag-de-backup"
readonly PROTO_FILES=(
  "${PROTO_REPO_DIR}/asterisk-agi/rad-protocolo.agi|/var/lib/asterisk/agi-bin/rad-protocolo.agi|asterisk:asterisk|755|rad-protocolo.agi"
  "${PROTO_REPO_DIR}/asterisk-agi/rad_protocolo_core.py|/var/lib/asterisk/agi-bin/rad_protocolo_core.py|asterisk:asterisk|644|rad_protocolo_core.py"
  "${PROTO_REPO_DIR}/asterisk-agi/extensions_rad.conf|/etc/asterisk/extensions_rad.conf|asterisk:asterisk|644|extensions_rad.conf"
  "${PROTO_REPO_DIR}/asterisk-agi/rad-pbx-set-pattern|/usr/local/sbin/rad-pbx-set-pattern|root:root|755|rad-pbx-set-pattern"
)
readonly PROTO_CONFIG_DIR="/etc/rad-pbx"
readonly PROTO_PATTERN_PATH="${PROTO_CONFIG_DIR}/protocol-pattern.json"
readonly PROTO_DEFAULT_TEMPLATE="PROT-{YYYY}-{ULID}"
readonly PROTO_AGI_PATH="/var/lib/asterisk/agi-bin/rad-protocolo.agi"
readonly PROTO_SETTER_PATH="/usr/local/sbin/rad-pbx-set-pattern"
readonly PROTO_SUDOERS_FILE="/etc/sudoers.d/rad-pbx-protocol"
readonly PROTO_DIALPLAN_INCLUDE="extensions_rad.conf"
readonly PROTO_EXTENSIONS_CONF="/etc/asterisk/extensions.conf"

# Log centralizado — todo output do script é também tee'd pra cá.
readonly LOG_DIR="/var/log"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"

# Diretório central de backups — FORA do docroot do Apache.
# Backups dentro de /var/www/html ficam acessíveis via HTTP como texto plano
# (Apache não interpreta .bak.<UTC> como PHP), vazando RAD_API_KEY e AMI_SECRET
# se alguém adivinhar o timestamp. Perms 0700 root:root impedem leitura por
# outros users do servidor também. Veja helpers ensure_backup_dir/backup_path_for.
readonly BACKUP_BASE_DIR="/var/backups/rad-api"

# Cores ANSI — desligadas se stdout não é tty (ex.: redirect pra arquivo).
if [[ -t 1 ]]; then
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_RED=''
    readonly C_GREEN=''
    readonly C_YELLOW=''
    readonly C_BLUE=''
    readonly C_BOLD=''
    readonly C_DIM=''
    readonly C_RESET=''
fi

# ════════════════════════════════════════════════════════════════════════
#  Helpers de logging
# ════════════════════════════════════════════════════════════════════════

# tee'da via _tee_log se LOG_FILE é writable; senão só ecoa.
_log_init() {
    if ! touch "${LOG_FILE}" 2>/dev/null; then
        printf '%s\n' "${C_YELLOW}⚠${C_RESET} Sem permissão pra escrever em ${LOG_FILE}; logs só no stdout." >&2
        return
    fi
    chmod 600 "${LOG_FILE}" 2>/dev/null || true
    {
        printf '\n'
        printf -- '─── %s v%s — sessão iniciada em %s ───\n' \
            "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >> "${LOG_FILE}"
}

_log_to_file() {
    # NUNCA loga conteúdo sensível (tokens, senhas, api keys).
    if [[ -w "${LOG_FILE}" ]]; then
        printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "${LOG_FILE}"
    fi
}

# Garante que o diretório central de backups existe com perms restritivas.
# Idempotente: roda no início de cada operação que faz backup; se já existir,
# no-op. Perms 0700 root:root garantem que mesmo outros users locais do
# servidor não consigam ler os backups (que podem conter API keys, secrets,
# código-fonte de módulos).
ensure_backup_dir() {
    if [[ ! -d "${BACKUP_BASE_DIR}" ]]; then
        mkdir -p "${BACKUP_BASE_DIR}" \
            || die "Falha ao criar ${BACKUP_BASE_DIR}."
        chown root:root "${BACKUP_BASE_DIR}"
        chmod 700 "${BACKUP_BASE_DIR}"
        ok "Diretório de backups criado: ${BACKUP_BASE_DIR} (0700 root:root)"
    fi
}

# Gera um path de backup datado dentro de BACKUP_BASE_DIR.
# $1 = tag do artefato (ex: contacts.php, manager.conf, themes-rad_pbx).
# Echo do path completo, ex: /var/backups/rad-api/contacts.php.20260525T160000Z
backup_path_for() {
    local tag="$1"
    printf '%s/%s.%s' "${BACKUP_BASE_DIR}" "${tag}" "$(date -u +%Y%m%dT%H%M%SZ)"
}

info() {
    printf '%s\n' "${C_BLUE}ℹ${C_RESET} $*"
    _log_to_file "INFO: $*"
}

ok() {
    printf '%s\n' "${C_GREEN}✓${C_RESET} $*"
    _log_to_file "OK: $*"
}

warn() {
    printf '%s\n' "${C_YELLOW}⚠${C_RESET} $*" >&2
    _log_to_file "WARN: $*"
}

err() {
    printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2
    _log_to_file "ERROR: $*"
}

die() {
    err "$*"
    err "Abortando. Veja ${LOG_FILE} pra trace completa."
    exit 1
}

# ════════════════════════════════════════════════════════════════════════
#  Pre-flight checks
# ════════════════════════════════════════════════════════════════════════

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Este script precisa rodar como root. Use 'sudo ./install.sh' ou logue como root."
    fi
}

require_cmd() {
    local cmd="$1" hint="${2:-}"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        if [[ -n "${hint}" ]]; then
            die "Comando '${cmd}' não encontrado. Instale antes: ${hint}"
        else
            die "Comando '${cmd}' não encontrado. Instale antes de continuar."
        fi
    fi
}

preflight() {
    info "Pre-flight checks…"
    require_root
    require_cmd bash
    require_cmd curl       "yum install -y curl   (ou apt-get install -y curl)"
    require_cmd openssl    "yum install -y openssl"
    require_cmd asterisk   "Esse script só faz sentido em servidor Issabel/Asterisk."
    require_cmd sed
    require_cmd awk
    require_cmd grep

    if ! pgrep -x "httpd" >/dev/null 2>&1 && ! pgrep -x "apache2" >/dev/null 2>&1; then
        warn "Apache (httpd/apache2) não está rodando. O endpoint não vai responder até subir."
    fi

    if ! asterisk -rx "core show version" >/dev/null 2>&1; then
        warn "Asterisk CLI não respondeu — o serviço pode estar parado."
    fi

    ok "Pre-flight OK."
}

# ════════════════════════════════════════════════════════════════════════
#  Helpers de input do usuário
# ════════════════════════════════════════════════════════════════════════

# Todos os reads usam `</dev/tty` explicitamente — defesa em camadas pra o
# caso de `curl|sudo bash` onde stdin do shell é o pipe do curl. O `exec
# </dev/tty` no main() já deveria ter resolvido, mas em alguns sudos isso
# falha silenciosamente; o `</dev/tty` em cada read garante. Se /dev/tty
# não estiver acessível, o main() aborta antes desses reads serem chamados.

# Prompt simples com default.  Uso: var=$(prompt "Pergunta" "default")
prompt() {
    local question="$1" default="${2:-}" answer
    if [[ -n "${default}" ]]; then
        read -r -p "${question} [${C_DIM}${default}${C_RESET}]: " answer </dev/tty
        printf '%s' "${answer:-${default}}"
    else
        read -r -p "${question}: " answer </dev/tty
        printf '%s' "${answer}"
    fi
}

# Prompt com input escondido (senha, token).  Uso: var=$(prompt_secret "Token")
prompt_secret() {
    local question="$1" answer
    # -s esconde o input; printf newline manualmente
    read -r -s -p "${question}: " answer </dev/tty
    printf '\n' >&2
    printf '%s' "${answer}"
}

# Confirma sim/não. Default: N (seguro). Uso: confirm "Continuar?" && ...
confirm() {
    local question="$1" answer
    read -r -p "${question} [s/N]: " answer </dev/tty
    [[ "${answer,,}" =~ ^(s|sim|y|yes)$ ]]
}

# ════════════════════════════════════════════════════════════════════════
#  Helpers de GitHub
# ════════════════════════════════════════════════════════════════════════

# Lê o GitHub token: da env GITHUB_TOKEN (pref), ou pergunta interativamente.
#   $1 = owner do repo (ex: rdebruem)              [obrigatório no prompt interativo]
#   $2 = nome do repo (ex: rad-ecosystem)          [obrigatório no prompt interativo]
#   $3 = descrição curta do artefato a baixar      [opcional, default genérico]
# Mesmo token serve pra múltiplos repos se o PAT tiver escopo amplo o suficiente;
# por isso GITHUB_TOKEN é honrado independente do repo.
get_github_token() {
    local owner="${1:-${SOURCE_REPO_OWNER_DEFAULT}}"
    local repo="${2:-${SOURCE_REPO_NAME_DEFAULT}}"
    local artifact_desc="${3:-os artefatos}"
    local token="${GITHUB_TOKEN:-}"
    if [[ -n "${token}" ]]; then
        info "Usando GITHUB_TOKEN da variável de ambiente."
        printf '%s' "${token}"
        return
    fi

    cat >&2 <<EOF

${C_BOLD}Token do GitHub${C_RESET}
─────────────────────────
O instalador precisa de um token (PAT) com permissão de leitura no repo
privado ${C_BOLD}${owner}/${repo}${C_RESET} pra baixar ${artifact_desc}.

Crie um em:  https://github.com/settings/tokens
Escopo mínimo:
  - Fine-grained token: ${C_DIM}Contents: Read-only${C_RESET} no repo específico.
  - Classic token:      ${C_DIM}repo${C_RESET} (escopo completo necessário pra repo privado).

O token é usado apenas pra esta sessão e ${C_BOLD}NÃO${C_RESET} é gravado em disco.

EOF
    token=$(prompt_secret "GitHub token (input escondido)")
    if [[ -z "${token}" ]]; then
        die "Token vazio."
    fi
    printf '%s' "${token}"
}

# Baixa um arquivo do repo privado via GitHub Contents API com raw accept.
#   $1 = github token
#   $2 = owner do repo
#   $3 = nome do repo
#   $4 = branch
#   $5 = path no repo (ex: apps/rad-softphone/server/issabel/rad-contacts.php)
#   $6 = destino local
github_download_file() {
    local token="$1" owner="$2" repo="$3" branch="$4" repo_path="$5" dest="$6"
    local url="https://api.github.com/repos/${owner}/${repo}/contents/${repo_path}?ref=${branch}"

    info "Baixando ${repo_path} de ${owner}/${repo}@${branch}…"
    local http_code
    http_code=$(curl -sS \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github.raw" \
        -H "User-Agent: ${SCRIPT_NAME}/${SCRIPT_VERSION}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -o "${dest}" \
        -w "%{http_code}" \
        "${url}")

    case "${http_code}" in
        200) ok "Baixado com sucesso (HTTP 200, $(wc -c < "${dest}" | tr -d ' ') bytes)." ;;
        401) die "GitHub HTTP 401 — token inválido ou expirado." ;;
        403) die "GitHub HTTP 403 — token sem permissão pra esse repo, ou rate limit." ;;
        404) die "GitHub HTTP 404 — caminho '${repo_path}' não existe no repo (ou repo errado)." ;;
        *)   die "GitHub HTTP ${http_code} — erro inesperado. Veja ${dest} pra body bruto." ;;
    esac
}

# Baixa o tarball completo de um repo privado via GitHub API.
# Mais eficiente que Contents API quando precisamos de uma pasta inteira
# (ex.: tema rad_pbx tem centenas de imagens — file-by-file estouraria o
# rate limit e demoraria minutos).
#   $1 = github token
#   $2 = owner do repo
#   $3 = nome do repo
#   $4 = ref (branch ou tag — ex.: "main", "v1.2.0")
#   $5 = destino local (ex.: /tmp/foo.tar.gz)
#
# Observações importantes:
#   - Endpoint /tarball/{ref} retorna 302 → S3; -L é OBRIGATÓRIO.
#   - O tarball expande pra um diretório com nome tipo
#     ${owner}-${repo}-${commit_sha_curto}/ — o caller precisa
#     resolver isso (use `tar tzf` ou `find` no diretório de extração).
github_download_tarball() {
    local token="$1" owner="$2" repo="$3" ref="$4" dest="$5"
    local url="https://api.github.com/repos/${owner}/${repo}/tarball/${ref}"

    info "Baixando tarball de ${owner}/${repo}@${ref}…"
    local http_code
    http_code=$(curl -sSL \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ${SCRIPT_NAME}/${SCRIPT_VERSION}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -o "${dest}" \
        -w "%{http_code}" \
        "${url}")

    case "${http_code}" in
        200) ok "Tarball baixado (HTTP 200, $(wc -c < "${dest}" | tr -d ' ') bytes)." ;;
        401) die "GitHub HTTP 401 — token inválido ou expirado." ;;
        403) die "GitHub HTTP 403 — token sem permissão pra esse repo, ou rate limit." ;;
        404) die "GitHub HTTP 404 — repo '${owner}/${repo}' ou ref '${ref}' não existe." ;;
        *)   die "GitHub HTTP ${http_code} — erro inesperado ao baixar tarball." ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════
#  Detecção do user efetivo do Apache
# ════════════════════════════════════════════════════════════════════════

# Em CentOS padrão o Apache roda como `apache`, mas Issabel sobrescreve via
# /etc/httpd/conf.d/issabel.conf (User asterisk / Group asterisk). Em Debian/
# Ubuntu seria www-data. Esta função descobre o user real consultando os
# processos workers (não o master, que roda como root).
#
# Estratégia em camadas:
#   1. `ps -ef` — pega o user de um worker do httpd/apache2.
#   2. Parse de /etc/httpd/conf.d/*.conf e httpd.conf procurando `User ...`.
#   3. Fallback estático "apache" (default mais comum).
detect_apache_owner() {
    local user group

    # Camada 1: processo worker (mais confiável — reflete a config carregada).
    user=$(ps -eo user,comm 2>/dev/null \
        | awk '$2 ~ /^(httpd|apache2)$/ && $1 != "root" {print $1; exit}')

    # Camada 2: config files (caso o Apache não esteja rodando ainda).
    if [[ -z "${user}" ]]; then
        user=$(grep -hE '^[[:space:]]*User[[:space:]]+' \
            /etc/httpd/conf/httpd.conf \
            /etc/httpd/conf.d/*.conf \
            /etc/apache2/apache2.conf \
            2>/dev/null \
            | tail -1 \
            | awk '{print $2}')
    fi

    # Camada 3: fallback.
    if [[ -z "${user}" ]]; then
        user="apache"
    fi

    # Group: tenta paralelo. Se não achar, usa o mesmo do user.
    group=$(grep -hE '^[[:space:]]*Group[[:space:]]+' \
        /etc/httpd/conf/httpd.conf \
        /etc/httpd/conf.d/*.conf \
        /etc/apache2/apache2.conf \
        2>/dev/null \
        | tail -1 \
        | awk '{print $2}')
    if [[ -z "${group}" ]]; then
        group="${user}"
    fi

    printf '%s:%s' "${user}" "${group}"
}

# ════════════════════════════════════════════════════════════════════════
#  Manipulação segura do PHP
# ════════════════════════════════════════════════════════════════════════

# Substitui o valor da constante RAD_API_KEY no PHP, in-place, com backup.
# sed delim '|' evita conflito com '/' que pode aparecer em hex (raro mas
# defensivo). API key é hex puro [0-9a-f], então safe.
php_set_api_key() {
    local php_file="$1" api_key="$2"
    if ! grep -qE "^define\('RAD_API_KEY'," "${php_file}"; then
        die "PHP não tem 'define(RAD_API_KEY, …)'. Repo desatualizado?"
    fi
    sed -i.bak \
        "s|^define('RAD_API_KEY',.*|define('RAD_API_KEY', '${api_key}');|" \
        "${php_file}"
    rm -f "${php_file}.bak"
    # Verifica substituição
    if ! grep -qE "^define\('RAD_API_KEY', '${api_key}'\);" "${php_file}"; then
        die "Falha ao substituir RAD_API_KEY no PHP — verifique manualmente em ${php_file}."
    fi
    ok "RAD_API_KEY gravada no PHP."
}

# Grava credenciais AMI no PHP (ADR-0215) pra coleta de BLF/presença.
# Sem isso, AMI_USER fica '' e o PHP pula a coleta — lista de contatos
# funciona mas sem campo `presence`.
#
# A senha AMI é gravada como constante PHP (mode 640 protege; mesmo
# user/group do PHP). Não é ideal em termos de "secrets-management",
# mas Issabel não tem solução melhor sem dependência externa, e AMI
# fica restrito a 127.0.0.1 mesmo (config no manager.conf).
php_set_ami_creds() {
    local php_file="$1" ami_user="$2" ami_secret="$3"
    # Escape de chars que mexem com sed delim '|': nenhum em user/secret
    # gerado pelo nosso openssl rand. User é alfanumérico simples.
    # Defensivo: se usuário cole secret com '|', escapamos.
    local esc_secret="${ami_secret//|/\\|}"
    sed -i.bak \
        -e "s|^define('AMI_USER',.*|define('AMI_USER',       '${ami_user}');|" \
        -e "s|^define('AMI_SECRET',.*|define('AMI_SECRET',     '${esc_secret}');|" \
        "${php_file}"
    rm -f "${php_file}.bak"
    if ! grep -qE "^define\('AMI_USER', *'${ami_user}'\);" "${php_file}"; then
        warn "Falha ao gravar AMI_USER no PHP — BLF/presença não vai funcionar até corrigir manualmente."
        return
    fi
    ok "AMI_USER e AMI_SECRET gravados no PHP (BLF habilitado)."
}

# ════════════════════════════════════════════════════════════════════════
#  Manipulação segura do manager.conf
# ════════════════════════════════════════════════════════════════════════

# Verifica se a seção [user] já existe em manager.conf.
manager_section_exists() {
    local user="$1"
    grep -qE "^\[${user}\]" "${MANAGER_CONF}"
}

# Remove a seção [user] inteira do manager.conf (do header até a próxima
# [seção] ou EOF), e limpa comentários-marcador "Adicionado pelo SCRIPT_NAME v..."
# órfãos (sem [seção] correspondente logo depois). Não cria backup — o caller
# (manager_add_user) já criou um antes de chamar.
#
# Implementação via awk com 3 estados; trata defensivamente o caso de markers
# empilhados de upgrades anteriores (observado num servidor real: 3 markers
# v0.1.0/v0.1.2/v0.3.0 órfãos entre [admin] e [rad-localhost] após múltiplas
# rodadas de versões pré-idempotência).
#
# $1 = user (nome do bloco AMI a remover, ex: rad-localhost)
manager_remove_block() {
    local user="$1" tmp_out
    tmp_out=$(mktemp /tmp/manager.conf.XXXXXX) || die "Falha ao criar arquivo temporário."

    awk -v user="${user}" -v script_name="${SCRIPT_NAME}" '
        BEGIN {
            in_target_block = 0
            pending_marker = ""
            user_re = "^\\[" user "\\]"
            # Regex ASCII puro pra não depender de UTF-8 no awk
            marker_re = "Adicionado pelo " script_name " v"
        }
        # Marker do nosso installer — guarda como pendente (sobrescreve anterior)
        $0 ~ marker_re { pending_marker = $0; next }
        # Header do bloco target → inicia skip; descarta marker pendente (era do bloco velho)
        $0 ~ user_re { in_target_block = 1; pending_marker = ""; next }
        # Header de OUTRA seção → sai do skip; emite marker pendente antes dela
        /^\[[^]]+\]/ {
            in_target_block = 0
            if (pending_marker != "") { print pending_marker; pending_marker = "" }
            print; next
        }
        # Dentro do bloco target → pula tudo
        in_target_block == 1 { next }
        # Linha não-vazia não-seção com marker pendente → marker é órfão, descarta
        pending_marker != "" && NF > 0 { pending_marker = ""; print; next }
        # Default (linhas vazias, linhas normais sem marker pendente) → imprime
        { print }
        # END: marker pendente no final do arquivo é órfão, descarta silenciosamente
    ' "${MANAGER_CONF}" > "${tmp_out}" \
        || { rm -f "${tmp_out}"; die "awk falhou ao limpar bloco [${user}] em ${MANAGER_CONF}."; }

    # mv atomico no mesmo filesystem. Asterisk só relê manager.conf no 'manager reload',
    # então não há janela de race com leitor concorrente.
    mv "${tmp_out}" "${MANAGER_CONF}" \
        || { rm -f "${tmp_out}"; die "Falha ao substituir ${MANAGER_CONF}."; }
}

# Adiciona OU substitui seção [user] em manager.conf, com backup datado.
# Idempotente: se [user] já existe, substitui o bloco inteiro (preservando
# todos os outros blocos via manager_remove_block) e limpa comentários-marcador
# órfãos. Caso contrário, append simples no fim. Em ambos os casos, gera um
# marker novo com SCRIPT_VERSION e UTC timestamp.
manager_add_user() {
    local user="$1" secret="$2" backup existed=0
    ensure_backup_dir
    backup=$(backup_path_for "manager.conf")
    cp -p "${MANAGER_CONF}" "${backup}" || die "Falha ao fazer backup de ${MANAGER_CONF}."
    ok "Backup salvo em ${backup}."

    if manager_section_exists "${user}"; then
        existed=1
        info "Seção [${user}] já existe — substituindo bloco inteiro (idempotente)…"
        manager_remove_block "${user}"
    fi

    {
        printf '\n'
        printf '; ─── Adicionado pelo %s v%s em %s ───\n' \
            "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '[%s]\n' "${user}"
        printf 'secret = %s\n' "${secret}"
        printf 'deny = 0.0.0.0/0\n'
        printf 'permit = 127.0.0.1/255.255.255.255\n'
        printf 'read = %s\n' "${AMI_READ_PERMS}"
        printf 'write = %s\n' "${AMI_WRITE_PERMS}"
    } >> "${MANAGER_CONF}"

    if [[ ${existed} -eq 1 ]]; then
        ok "Seção [${user}] substituída em ${MANAGER_CONF}."
    else
        ok "Seção [${user}] adicionada em ${MANAGER_CONF}."
    fi
}

# ════════════════════════════════════════════════════════════════════════
#  Reload seguro do manager + restart de consumidores AMI
# ════════════════════════════════════════════════════════════════════════

# Daemons conhecidos que tipicamente mantêm conexão AMI persistente em
# servidores Issabel. Cada daemon é restartado independentemente — falha
# em um não afeta os outros. Adicionar novos? Mantenha ordem de prioridade:
# mais crítico primeiro. Asterisk de propósito NÃO está aqui — restartar
# asterisk derruba TODAS as chamadas/registros e é último recurso que o
# operador faz manualmente, não algo que o installer deve oferecer em
# fluxo guiado por sim/não.
#
# Histórico: dois incidentes em produção (servidor Issabel do Renato em
# 2026-05-26) revelaram causa raiz dupla:
#   1. Editar `manager.conf` principal dispara reload silencioso via inotify
#      do asterisk — sem ninguém rodar `asterisk -rx "manager reload"`. Fix
#      definitivo: v0.8.0 move append pra `manager_custom.conf` que não é
#      vigiado. Ver comentário em MANAGER_CONF acima.
#   2. Quando o reload ACONTECE (manual ou auto), sessões AMI ativas
#      revalidam. Se houver divergência entre `manager.conf [admin].secret`
#      e a senha que daemons (issabeldialer, fop2) têm em memória, eles
#      entram em loop de `failed to authenticate as 'admin' ~1×/s`. Fix:
#      `pkill -9 -f dialerd && /etc/rc.d/init.d/issabeldialer start` (SYSV
#      service em `active (exited)` não rastreia filhos — systemctl restart
#      sozinho não basta). Esta lista existe pra oferecer o restart
#      proativamente após reload, antes do operador ver o sintoma.
readonly AMI_CONSUMERS_KNOWN=(issabeldialer fop2)

# Faz `asterisk -rx "manager reload"` com proteção:
#   1. Snapshot de clientes AMI conectados ANTES — operador vê exatamente
#      quem vai ser derrubado pela revalidação forçada de sessão.
#   2. Aviso explícito sobre impacto operacional (daemons com senha
#      cacheada em memória vão começar a falhar autenticação).
#   3. Confirmação opt-in com default = N (mais seguro — preserva
#      sessões ativas se operador não tiver certeza).
#
# Retorna:
#   0 — reload feito com sucesso
#   1 — operador escolheu pular reload (instruções de manual já exibidas)
#   2 — reload tentado mas Asterisk não respondeu (asterisk parado?)
manager_safe_reload() {
    cat <<EOF

${C_BOLD}Reload do AMI${C_RESET}
─────────────────
O novo bloco AMI só fica ativo após ${C_DIM}asterisk -rx "manager reload"${C_RESET}.

${C_YELLOW}⚠${C_RESET}  Reload força revalidação de TODAS as sessões AMI ativas. Daemons
   que tiverem senha cacheada em memória (ex: ${C_BOLD}issabeldialer${C_RESET}, ${C_BOLD}fop2${C_RESET})
   podem começar a falhar autenticação em loop até serem reiniciados.

   Sintoma típico no /var/log/asterisk/full após reload:
     ${C_DIM}NOTICE manager.c authenticate: 127.0.0.1 failed to authenticate as 'admin'${C_RESET}

   Esta versão do installer oferece restartar esses daemons pra você
   logo após o reload, na próxima etapa.

EOF
    info "Sessões AMI ativas neste momento:"
    local connected
    if connected=$(asterisk -rx "manager show connected" 2>&1); then
        printf '%s\n' "${connected}" | sed 's/^/  /'
    else
        warn "Não consegui consultar 'manager show connected' — Asterisk pode estar parado."
    fi
    printf '\n'

    if ! confirm "Rodar 'manager reload' AGORA?"; then
        cat <<EOF

${C_DIM}Reload pulado. Quando quiser ativar o novo bloco AMI, rode manualmente:${C_RESET}
  ${C_BOLD}asterisk -rx "manager reload"${C_RESET}

${C_DIM}E se aparecer 'failed to authenticate as admin' em loop no /var/log/asterisk/full:${C_RESET}
  ${C_BOLD}systemctl restart issabeldialer fop2${C_RESET}

EOF
        return 1
    fi

    info "Recarregando manager do Asterisk…"
    if asterisk -rx "manager reload" >/dev/null 2>&1; then
        ok "Manager recarregado."
        return 0
    else
        warn "Asterisk não respondeu ao reload — pode estar parado."
        return 2
    fi
}

# Após reload, oferece restart dos consumidores AMI conhecidos que estão
# ativos no systemd. Pergunta individualmente — operador decide caso a
# caso. Daemons inativos/inexistentes são pulados silenciosamente. Falha
# de um restart NÃO interrompe o loop (próximo daemon segue).
#
# Por que individual e não "restart all"?
#   - issabeldialer: derruba campanha de discagem em curso (CallCenter)
#   - fop2: painel de operador perde live status por segundos
#   - cada equipe pode ter SLA distinto pra cada serviço
#
# Diagnóstico: mostra `systemctl status -n 3` (linhas recentes do journal)
# antes de perguntar — operador vê se daemon está em loop de fail.
restart_ami_consumers() {
    cat <<EOF

${C_BOLD}Restart dos consumidores AMI${C_RESET}
──────────────────────────────
Daemons com sessão AMI persistente podem estar mandando senha velha em
loop após o reload. Esta etapa oferece restartar cada um individualmente.
${C_DIM}Daemons inativos ou não-instalados são pulados.${C_RESET}

EOF
    local daemon any_active=0
    for daemon in "${AMI_CONSUMERS_KNOWN[@]}"; do
        # Pula daemons que nem existem como unit no systemd deste servidor
        if ! systemctl list-unit-files "${daemon}.service" >/dev/null 2>&1; then
            continue
        fi
        # Pula daemons que existem mas estão parados
        if ! systemctl is-active --quiet "${daemon}.service" 2>/dev/null; then
            info "${daemon}: inativo — pulando."
            continue
        fi
        any_active=1
        printf '\n%s%s%s status atual:\n' "${C_BOLD}" "${daemon}" "${C_RESET}"
        systemctl status --no-pager -n 3 "${daemon}.service" 2>/dev/null \
            | head -5 \
            | sed 's/^/  /'
        printf '\n'
        if confirm "Reiniciar ${daemon}?"; then
            if systemctl restart "${daemon}.service" 2>/dev/null; then
                ok "${daemon} reiniciado."
            else
                warn "Falha ao reiniciar ${daemon} — confira 'systemctl status ${daemon}'."
            fi
        else
            info "${daemon}: mantido como está."
        fi
    done

    if [[ ${any_active} -eq 0 ]]; then
        info "Nenhum consumidor AMI conhecido está ativo neste servidor."
        info "Se você tem daemons customizados que falam AMI, restarte-os manualmente."
    fi
}

# ════════════════════════════════════════════════════════════════════════
#  Banner e menu
# ════════════════════════════════════════════════════════════════════════

show_banner() {
    clear || true
    cat <<EOF
${C_BOLD}╔══════════════════════════════════════════════════════════╗
║           RAD-PBX-API — Instalador Issabel               ║
║                                                          ║
║                  versão ${SCRIPT_VERSION}                            ║
╚══════════════════════════════════════════════════════════╝${C_RESET}

  Componentes do ecossistema RAD pra rodar no servidor Issabel.

  Log da sessão: ${C_DIM}${LOG_FILE}${C_RESET}
  Repo fonte:    ${C_DIM}${SOURCE_REPO_OWNER_DEFAULT}/${SOURCE_REPO_NAME_DEFAULT}@${SOURCE_REPO_BRANCH}${C_RESET}

EOF
}

show_menu() {
    show_banner
    cat <<EOF
${C_BOLD}Menu principal${C_RESET}

  ${C_BOLD}1${C_RESET})  Instalar API de contatos (rad-contacts.php)
       └─ endpoint HTTP que o RAD Softphone usa pra puxar ramais.

  ${C_BOLD}2${C_RESET})  Instalar áudios PT-BR (módulo Issabel PBX PT-BR)
       └─ baixa e aplica o patch ibinetwork/IssabelBR (áudios em português).

  ${C_BOLD}3${C_RESET})  Instalar Tema RAD-PBX
       └─ baixa o tema do repo privado ${THEME_REPO_OWNER}/${THEME_REPO_NAME} e
          substitui ${THEME_INSTALL_DIR}/ + ${MOTD_INSTALL_PATH}.

  ${C_BOLD}4${C_RESET})  Instalar RAD-PROTOCOLO (número de protocolo — ADR-0112)
       └─ central autônoma: AGI + stub de dialplan + padrão local. Sem rede,
          sem sync. NÃO altera roteamento (inerte até a rota fazer Gosub).

  ${C_BOLD}q${C_RESET})  Sair

EOF
    local choice
    read -r -p "Escolha uma opção: " choice </dev/tty
    case "${choice}" in
        1)  install_contacts_api ;;
        2)  install_ptbr_audios ;;
        3)  install_rad_pbx_theme ;;
        4)  install_rad_protocolo ;;
        q|Q) info "Saindo."; exit 0 ;;
        "") warn "Input vazio (provavelmente stdin do bash não está atrelado ao terminal — curl|sudo bash em alguns sudos). Use: wget https://raw.githubusercontent.com/rdebruem/rad-pbx-api/main/install.sh && chmod +x install.sh && sudo ./install.sh"; exit 1 ;;
        *)  warn "Opção inválida: '${choice}'"; sleep 1; show_menu ;;
    esac
}

# ════════════════════════════════════════════════════════════════════════
#  Opção 1 — Instalar API de contatos
# ════════════════════════════════════════════════════════════════════════

install_contacts_api() {
    printf '\n%s═══ Instalação da API de contatos ═══%s\n\n' "${C_BOLD}" "${C_RESET}"

    # ─── 1.0  Idempotência: detecta instalação prévia ───
    if [[ -f "${INSTALL_PATH}" ]]; then
        warn "Já existe um ${INSTALL_PATH} no servidor."
        if ! confirm "Deseja sobrescrever (sim) ou cancelar (não)?"; then
            info "Cancelado pelo usuário. Nada foi alterado."
            return
        fi
        ensure_backup_dir
        local existing_backup
        existing_backup=$(backup_path_for "contacts.php")
        cp -p "${INSTALL_PATH}" "${existing_backup}"
        ok "Backup do PHP existente: ${existing_backup}"
    fi

    # ─── 1.1  Token GitHub ───
    local token
    token=$(get_github_token \
        "${SOURCE_REPO_OWNER_DEFAULT}" \
        "${SOURCE_REPO_NAME_DEFAULT}" \
        "o rad-contacts.php")

    # ─── 1.2  Baixar PHP do repo privado pra /tmp ───
    local tmp_php="/tmp/rad-contacts.php.$$"
    trap 'rm -f "${tmp_php}"' EXIT

    github_download_file "${token}" \
        "${SOURCE_REPO_OWNER_DEFAULT}" \
        "${SOURCE_REPO_NAME_DEFAULT}" \
        "${SOURCE_REPO_BRANCH}" \
        "${PHP_PATH_IN_REPO}" \
        "${tmp_php}"

    # Sanity check: arquivo começa com <?php
    if ! head -c 5 "${tmp_php}" | grep -q '<?php'; then
        die "Arquivo baixado não parece PHP válido. Token sem permissão? Conteúdo em ${tmp_php}."
    fi

    # ─── 1.3  Gerar API key forte ───
    info "Gerando API key (32 bytes hex = 256 bits)…"
    local api_key
    api_key=$(openssl rand -hex 32)
    ok "API key gerada (${#api_key} caracteres hex)."

    # ─── 1.4  Substituir constante no PHP ANTES de mover ───
    php_set_api_key "${tmp_php}" "${api_key}"

    # ─── 1.5  Instalar no caminho final com permissões certas ───
    info "Detectando user/group efetivo do Apache…"
    local apache_owner
    apache_owner=$(detect_apache_owner)
    ok "Apache roda como: ${apache_owner}  ${C_DIM}(detectado de ps + conf)${C_RESET}"

    info "Instalando em ${INSTALL_PATH}…"
    mkdir -p "${INSTALL_DIR}"
    mv "${tmp_php}" "${INSTALL_PATH}"

    # chown -R: dir + arquivo. Importante porque suEXEC e outros mecanismos
    # podem checar o owner do dir, não só do arquivo.
    chown -R "${apache_owner}" "${INSTALL_DIR}"
    chmod 755 "${INSTALL_DIR}"
    chmod "${INSTALL_MODE_RESTRICTIVE}" "${INSTALL_PATH}"
    ok "Instalado: ${INSTALL_PATH} (owner ${apache_owner}, mode ${INSTALL_MODE_RESTRICTIVE})."

    # Defesa em profundidade: SELinux. No-op se SELinux disabled ou cmd ausente.
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -Rv "${INSTALL_DIR}" >/dev/null 2>&1 || true
    fi

    trap - EXIT  # já moveu, não precisa do trap

    # ─── 1.6  Configurar usuário AMI (pro cliente Electron, NÃO pro PHP) ───
    cat <<EOF

${C_BOLD}Configuração do usuário AMI${C_RESET}
──────────────────────────────
O ${C_BOLD}rad-contacts.php NÃO usa AMI${C_RESET} — ele lê direto de sip_additional.conf.
Quem precisa do AMI é o ${C_BOLD}cliente Electron${C_RESET} do RAD Softphone (eventos
de presença em tempo real — BLF).

Esta etapa adiciona um usuário AMI em ${MANAGER_CONF}, restrito a
127.0.0.1, com permissões de leitura ${C_DIM}${AMI_READ_PERMS}${C_RESET}.

EOF
    local ami_user ami_secret
    ami_user=$(prompt "Nome do usuário AMI" "${AMI_USER_DEFAULT}")
    if [[ -z "${ami_user}" ]]; then
        die "Nome do usuário AMI não pode ser vazio."
    fi

    local skip_ami_setup=0
    if manager_section_exists "${ami_user}"; then
        warn "Já existe seção [${ami_user}] em ${MANAGER_CONF}."
        info "O instalador agora é idempotente: pode substituir o bloco inteiro com uma NOVA senha."
        warn "ATENÇÃO: serviços que já estão usando essa senha (ex: dialerd da Issabel,"
        warn "FOP2) vão precisar ser reiniciados depois pra pegar a senha nova."
        if ! confirm "Substituir bloco existente com NOVA senha (sim) ou cancelar setup AMI (não)?"; then
            info "Cancelado: bloco [${ami_user}] preservado, PHP não terá BLF habilitado."
            skip_ami_setup=1
            ami_secret=""
        fi
    fi

    if [[ ${skip_ami_setup} -eq 0 ]]; then
        ami_secret=$(prompt_secret "Senha do AMI (input escondido — deixe vazio pra gerar automaticamente)")
        if [[ -z "${ami_secret}" ]]; then
            ami_secret=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)
            info "Senha AMI gerada automaticamente: ${C_BOLD}${ami_secret}${C_RESET}"
            warn "Guarde essa senha agora — ela não será exibida de novo."
        fi
        manager_add_user "${ami_user}" "${ami_secret}"

        # Grava as MESMAS credenciais no PHP (ADR-0215) pra que o rad-contacts.php
        # colete BLF/presença via AMI local. Sem isso, listagem de contatos funciona
        # mas sem campo `presence`.
        php_set_ami_creds "${INSTALL_PATH}" "${ami_user}" "${ami_secret}"

        # Reload seguro do manager — opt-in com snapshot de sessões ativas +
        # aviso de impacto. Se operador pular, instruções pra rodar depois
        # já são exibidas dentro de manager_safe_reload.
        local reload_status=0
        manager_safe_reload || reload_status=$?

        # Pós-reload: oferece restart dos daemons conhecidos (issabeldialer,
        # fop2) que podem ter senha cacheada em memória. Só faz sentido se o
        # reload foi efetivo (status 0); se foi pulado, sessões AMI ainda
        # não foram derrubadas → daemons continuam funcionando com a config
        # em memória antiga, sem motivo pra restart proativo.
        if [[ ${reload_status} -eq 0 ]]; then
            restart_ami_consumers
        fi

        # Show user pra confirmar (sempre roda — mostra config carregada no
        # Asterisk; se reload foi pulado, mostra estado anterior, que é
        # informativo pro operador comparar com o que ele acabou de adicionar).
        info "Verificando usuário com 'manager show user ${ami_user}'…"
        local show_output
        if show_output=$(asterisk -rx "manager show user ${ami_user}" 2>&1); then
            printf '%s\n' "${show_output}"
            # case-insensitive: Asterisk às vezes retorna 'read perm' (minúsculo)
            # — o regex case-sensitive antigo dava falso warn mesmo com perms OK.
            if printf '%s' "${show_output}" | grep -qiE "read perm:.*${AMI_READ_PERMS//,/.*}"; then
                ok "Usuário AMI provisionado corretamente."
            else
                warn "Usuário criado mas read perm não parece estar completo. Confira a saída acima."
            fi
        else
            warn "Não consegui rodar 'asterisk -rx'. Confira manualmente."
        fi
    fi

    # ─── 1.7  Teste com curl (HTTP, com fallback ionCube em mode 644) ───
    info "Testando endpoint local com curl…"
    local curl_output curl_status http_status
    local php_mode_final="${INSTALL_MODE_RESTRICTIVE}"

    _test_endpoint() {
        # Devolve HTTP code via -w; body em stdout via -o
        set +e
        http_status=$(curl -sS -k -o /tmp/rad-curl-body.$$ -w "%{http_code}" \
            -H "X-API-Key: ${api_key}" \
            "https://localhost/rad-api/contacts.php" 2>/dev/null)
        curl_status=$?
        set -e
        curl_output=$(cat /tmp/rad-curl-body.$$ 2>/dev/null || printf '')
        rm -f /tmp/rad-curl-body.$$
    }

    _test_endpoint

    # Casos de falha onde valha tentar fallback 644 (típico ionCube em Issabel).
    if [[ ${curl_status} -ne 0 ]] || [[ "${http_status}" == "500" && -z "${curl_output}" ]]; then
        warn "Resposta HTTP ${http_status:-erro}. Tentando fallback ${INSTALL_MODE_PERMISSIVE} (ionCube em algumas configs exige world-readable)…"
        chmod "${INSTALL_MODE_PERMISSIVE}" "${INSTALL_PATH}"
        php_mode_final="${INSTALL_MODE_PERMISSIVE}"
        _test_endpoint
    fi

    if [[ ${curl_status} -ne 0 ]]; then
        warn "curl falhou completamente (status=${curl_status})."
    elif [[ "${http_status}" == "200" ]] && printf '%s' "${curl_output}" | grep -qE '"format"[[:space:]]*:[[:space:]]*"rad-contacts-v1"'; then
        ok "Endpoint respondeu HTTP 200 no formato esperado (mode final ${php_mode_final})."
        if command -v python3 >/dev/null 2>&1; then
            printf '%s' "${curl_output}" | python3 -m json.tool | head -20 || true
        elif command -v python >/dev/null 2>&1; then
            printf '%s' "${curl_output}" | python -m json.tool | head -20 || true
        else
            printf '%s\n' "${curl_output}" | head -c 500
            printf '\n'
        fi
        if [[ "${php_mode_final}" == "${INSTALL_MODE_PERMISSIVE}" ]]; then
            warn "PHP ficou em mode 644 (world-readable). API key fica legível por qualquer user do servidor."
            warn "Aceitável em servidor B2B sem outros users humanos; revise se aplicar."
        fi
    else
        warn "Endpoint respondeu HTTP ${http_status}. Body:"
        printf '%s\n' "${curl_output}" | head -c 800
        printf '\n'
        warn "Inspecione /var/log/httpd/error_log e ssl_error_log pra mais detalhes."
    fi

    # ─── 1.8  Resumo final ───
    cat <<EOF

${C_BOLD}${C_GREEN}═══ Instalação concluída ═══${C_RESET}

  ${C_BOLD}Endpoint URL${C_RESET}:    https://$(hostname -I | awk '{print $1}')/rad-api/contacts.php
  ${C_BOLD}Arquivo PHP${C_RESET}:     ${INSTALL_PATH}
  ${C_BOLD}Manager.conf${C_RESET}:    ${MANAGER_CONF}
EOF
    if [[ -n "${ami_secret}" ]]; then
        cat <<EOF
  ${C_BOLD}AMI user${C_RESET}:        ${ami_user}
  ${C_BOLD}AMI secret${C_RESET}:      ${ami_secret}${C_DIM}  (também guarde, não será mostrado de novo)${C_RESET}
EOF
    fi
    cat <<EOF

${C_BOLD}${C_GREEN}═══ Para o usuário final do RAD Softphone ═══${C_RESET}

  ${C_BOLD}Não é mais preciso compartilhar API key!${C_RESET} A partir do v0.2.0 do
  endpoint (ADR-0214), a autenticação usa as credenciais SIP que o operador
  já tem. Basta no app:

    ${C_BOLD}1.${C_RESET} Configurações → Conta SIP
    ${C_BOLD}2.${C_RESET} Preencher ramal + senha + domínio (esta máquina, ${C_DIM}$(hostname -I | awk '{print $1}')${C_DIM})${C_RESET}
    ${C_BOLD}3.${C_RESET} Marcar ☑ "Sincronizar contatos com a central"
    ${C_BOLD}4.${C_RESET} Salvar e registrar.

  Não precisa colar API key, não precisa colar URL.

${C_BOLD}═══ Para o admin / scripts CI ═══${C_RESET}

  Se você precisa de auth via API key (legacy, scripts curl, integrações
  externas), pode usar a chave gerada agora:

  ${C_BOLD}API key (admin)${C_RESET}: ${api_key}
  ${C_DIM}Guarde — não será mostrada de novo. No app, abra "Configuração
  avançada de fonte de contatos" e preencha URL + API key.${C_RESET}

${C_BOLD}Próximos passos operacionais:${C_RESET}

  1. Configure cert TLS válido no Apache (Let's Encrypt) sempre que possível.
     Sem cert válido, o app exige opt-in explícito no checkbox
     "Aceitar certificado TLS auto-assinado".

  2. Logs do endpoint:
     • ${C_DIM}/var/log/httpd/access_log${C_RESET} — requests bem-sucedidas
     • ${C_DIM}/var/log/httpd/error_log${C_RESET} + ${C_DIM}ssl_error_log${C_RESET} — falhas
     • Auth Basic falha aparece como ${C_DIM}error_log:[rad-contacts] auth basic falhou: ramal=NNN${C_RESET}

  3. ${C_BOLD}Reinicie consumidores AMI${C_RESET} pra eles pegarem a senha nova:
     ${C_DIM}(Pular se o setup AMI foi cancelado acima.)${C_RESET}
     • ${C_BOLD}systemctl restart issabeldialer${C_RESET}     ${C_DIM}— Issabel CallCenter (dialerd)${C_RESET}
     • ${C_BOLD}systemctl restart fop2${C_RESET}              ${C_DIM}— FOP2 Operator Panel (se instalado)${C_RESET}
     • ${C_BOLD}systemctl restart asterisk${C_RESET}          ${C_DIM}— opcional, força reload completo do manager.conf${C_RESET}

     ${C_DIM}Por que: serviços AMI persistentes carregam a senha em memória no startup.
     Se você alterou o bloco AMI sem reiniciá-los, eles continuam mandando a senha
     antiga em loop (sintoma típico: NOTICE manager.c ~1×/s em /var/log/asterisk/full).${C_RESET}

EOF
    _log_to_file "INSTALL OK: api_key=<redacted> ami_user=${ami_user}"
    ok "Pronto! Volte ao menu (Enter) ou Ctrl+C pra sair."
    read -r
    show_menu
}

# ════════════════════════════════════════════════════════════════════════
#  Opção 2 — Instalar áudios PT-BR (módulo Issabel PBX PT-BR)
# ════════════════════════════════════════════════════════════════════════

# Roda o patch-issabelbr.sh do projeto ibinetwork/IssabelBR, que copia
# áudios em PT-BR pra central Issabel. O script remoto é mantido por
# terceiros — exibimos aviso claro e pedimos confirmação antes de rodar
# qualquer coisa baixada de fora do nosso repo.
readonly PTBR_PATCH_URL="https://github.com/ibinetwork/IssabelBR/raw/master/patch-issabelbr.sh"

install_ptbr_audios() {
    printf '\n%s═══ Instalação de áudios PT-BR (Issabel PBX PT-BR) ═══%s\n\n' "${C_BOLD}" "${C_RESET}"

    cat <<EOF
${C_BOLD}Sobre este patch${C_RESET}
──────────────────
Este passo executa o script ${C_BOLD}patch-issabelbr.sh${C_RESET} mantido pelo projeto
${C_BOLD}ibinetwork/IssabelBR${C_RESET} no GitHub. Ele baixa e instala áudios em
português brasileiro na sua central Issabel.

  URL: ${C_DIM}${PTBR_PATCH_URL}${C_RESET}

${C_YELLOW}⚠${C_RESET}  ${C_BOLD}Aviso:${C_RESET} o script é mantido por terceiros e roda como root.
   Recomenda-se revisar o conteúdo antes de aplicar em produção.

EOF

    if ! confirm "Continuar e executar o patch agora?"; then
        info "Cancelado pelo usuário. Nada foi alterado."
        read -r -p "Pressione Enter pra voltar ao menu…" _ </dev/tty
        show_menu
        return
    fi

    require_cmd wget "yum install -y wget   (ou apt-get install -y wget)"
    require_cmd bash

    info "Baixando e executando ${PTBR_PATCH_URL}…"
    _log_to_file "PTBR_PATCH: invocando ${PTBR_PATCH_URL}"

    # Pipe wget → bash, idêntico ao comando documentado pelo upstream.
    # set +e local pra capturar exit code sem matar o instalador.
    local patch_status
    set +e
    wget -O - "${PTBR_PATCH_URL}" | bash
    patch_status=${PIPESTATUS[1]:-$?}
    set -e

    if [[ ${patch_status} -eq 0 ]]; then
        ok "Patch PT-BR executado com sucesso (exit 0)."
        _log_to_file "PTBR_PATCH OK"
    else
        warn "Patch PT-BR terminou com exit ${patch_status}. Revise a saída acima."
        _log_to_file "PTBR_PATCH FAIL exit=${patch_status}"
    fi

    cat <<EOF

${C_BOLD}Próximos passos sugeridos:${C_RESET}

  1. Reiniciar/recarregar o Asterisk pra garantir que os novos áudios sejam
     servidos: ${C_DIM}asterisk -rx "core reload"${C_RESET}
  2. Testar uma chamada que dispare URA/IVR pra confirmar prompts em PT-BR.

EOF

    read -r -p "Pressione Enter pra voltar ao menu…" _ </dev/tty
    show_menu
}

# ════════════════════════════════════════════════════════════════════════
#  Opção 3 — Instalar Tema RAD-PBX
# ════════════════════════════════════════════════════════════════════════

install_rad_pbx_theme() {
    printf '\n%s═══ Instalação do Tema RAD-PBX ═══%s\n\n' "${C_BOLD}" "${C_RESET}"

    cat <<EOF
${C_BOLD}Sobre esta instalação${C_RESET}
──────────────────────
Este passo baixa o tema ${C_BOLD}rad_pbx${C_RESET} do repositório privado
${C_BOLD}${THEME_REPO_OWNER}/${THEME_REPO_NAME}${C_RESET} (branch ${THEME_REPO_BRANCH}) e instala:

  ${C_DIM}• ${THEME_PATH_IN_REPO}/  →  ${THEME_INSTALL_DIR}/${C_RESET}
  ${C_DIM}• ${FAVICON_PATH_IN_REPO}        →  ${FAVICON_INSTALL_PATH}${C_RESET}
  ${C_DIM}• ${BRLANG_PATH_IN_REPO}       →  ${BRLANG_INSTALL_PATH}${C_RESET}
  ${C_DIM}• ${MOTD_PATH_IN_REPO}        →  ${MOTD_INSTALL_PATH}${C_RESET}
  ${C_DIM}• ${MODULES_DIR_IN_REPO}/agent_console/        →  ${MODULES_INSTALL_DIR}/agent_console/${C_RESET}
  ${C_DIM}• ${MODULES_DIR_IN_REPO}/campaign_monitoring/  →  ${MODULES_INSTALL_DIR}/campaign_monitoring/${C_RESET}

Diretórios/arquivos existentes serão renomeados pra .bak.<timestamp> antes da cópia.

EOF

    # ─── 3.0  Pré-requisitos específicos da opção ───
    require_cmd tar  "yum install -y tar"

    if ! confirm "Continuar com a instalação do tema?"; then
        info "Cancelado pelo usuário. Nada foi alterado."
        read -r -p "Pressione Enter pra voltar ao menu…" _ </dev/tty
        show_menu
        return
    fi

    # ─── 3.1  Token GitHub (mesma UX da opção 1) ───
    local token
    token=$(get_github_token \
        "${THEME_REPO_OWNER}" \
        "${THEME_REPO_NAME}" \
        "o tema rad_pbx")

    # ─── 3.2  Baixar tarball do repo privado ───
    local tmp_tar="/tmp/rad-pbx-theme.$$.tar.gz"
    local tmp_extract="/tmp/rad-pbx-theme-extract.$$"
    # Cleanup automático em qualquer saída — falha de rede, Ctrl+C, etc.
    # Mantemos pasta de extração só até o final do install; cleanup remove tudo.
    trap 'rm -rf "${tmp_tar}" "${tmp_extract}"' EXIT

    github_download_tarball "${token}" \
        "${THEME_REPO_OWNER}" \
        "${THEME_REPO_NAME}" \
        "${THEME_REPO_BRANCH}" \
        "${tmp_tar}"

    # Sanity: arquivo é gzip de verdade? (token errado às vezes retorna 200
    # com body JSON de erro — defensivo.)
    if ! file "${tmp_tar}" 2>/dev/null | grep -qi "gzip"; then
        # Fallback: tenta inspecionar magic bytes diretamente (file pode estar ausente)
        if ! head -c 2 "${tmp_tar}" | od -An -tx1 | grep -q "1f 8b"; then
            die "Arquivo baixado não é um tarball gzip válido (token sem permissão?). Conteúdo em ${tmp_tar}."
        fi
    fi

    # ─── 3.3  Extrair tarball ───
    info "Extraindo tarball…"
    mkdir -p "${tmp_extract}"
    tar -xzf "${tmp_tar}" -C "${tmp_extract}" \
        || die "Falha ao extrair ${tmp_tar} em ${tmp_extract}."

    # GitHub empacota tudo dentro de uma pasta tipo
    # ${owner}-${repo}-${commit_sha_curto}/ — resolvemos via find.
    local extracted_root
    extracted_root=$(find "${tmp_extract}" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [[ -z "${extracted_root}" || ! -d "${extracted_root}" ]]; then
        die "Não consegui localizar a pasta raiz extraída em ${tmp_extract}."
    fi
    ok "Tarball extraído em ${extracted_root}"

    local src_theme_dir="${extracted_root}/${THEME_PATH_IN_REPO}"
    local src_motd_file="${extracted_root}/${MOTD_PATH_IN_REPO}"
    local src_favicon_file="${extracted_root}/${FAVICON_PATH_IN_REPO}"
    local src_brlang_file="${extracted_root}/${BRLANG_PATH_IN_REPO}"

    # ─── 3.4  Validar que os paths esperados existem no tarball ───
    if [[ ! -d "${src_theme_dir}" ]]; then
        die "Pasta '${THEME_PATH_IN_REPO}' não encontrada no repo. Estrutura do repo mudou?"
    fi
    if [[ ! -f "${src_motd_file}" ]]; then
        die "Arquivo '${MOTD_PATH_IN_REPO}' não encontrado no repo. Estrutura do repo mudou?"
    fi
    if [[ ! -f "${src_favicon_file}" ]]; then
        die "Arquivo '${FAVICON_PATH_IN_REPO}' não encontrado no repo. Estrutura do repo mudou?"
    fi
    if [[ ! -f "${src_brlang_file}" ]]; then
        die "Arquivo '${BRLANG_PATH_IN_REPO}' não encontrado no repo. Estrutura do repo mudou?"
    fi
    # Valida TODOS os módulos antes de qualquer cópia — falha rápido se algum
    # tiver sido removido do repo, pra não deixar o sistema em estado misto.
    local module_name
    for module_name in "${MODULES_TO_INSTALL[@]}"; do
        if [[ ! -d "${extracted_root}/${MODULES_DIR_IN_REPO}/${module_name}" ]]; then
            die "Módulo '${MODULES_DIR_IN_REPO}/${module_name}' não encontrado no repo. Estrutura do repo mudou?"
        fi
    done
    ok "Estrutura do repo validada — encontrados theme/, favicon.ico, br.lang, motd.sh e módulos: ${MODULES_TO_INSTALL[*]}."

    # ─── 3.5  Backup + instalação do tema ───
    if [[ -d "${THEME_INSTALL_DIR}" ]]; then
        ensure_backup_dir
        local theme_backup
        theme_backup=$(backup_path_for "themes-rad_pbx")
        info "Tema existente detectado em ${THEME_INSTALL_DIR} — movendo pra ${theme_backup}…"
        mv "${THEME_INSTALL_DIR}" "${theme_backup}" \
            || die "Falha ao mover tema existente pra backup."
        ok "Backup do tema antigo: ${theme_backup}"
    fi

    info "Detectando user/group efetivo do Apache…"
    local apache_owner
    apache_owner=$(detect_apache_owner)
    ok "Apache roda como: ${apache_owner}  ${C_DIM}(detectado de ps + conf)${C_RESET}"

    info "Instalando tema em ${THEME_INSTALL_DIR}…"
    mkdir -p "$(dirname "${THEME_INSTALL_DIR}")"
    # cp -rp preserva mtimes (importante pra cache do navegador via If-Modified-Since)
    cp -rp "${src_theme_dir}" "${THEME_INSTALL_DIR}" \
        || die "Falha ao copiar tema pra ${THEME_INSTALL_DIR}."

    # Ownership pra Apache servir os assets sem 403.
    chown -R "${apache_owner}" "${THEME_INSTALL_DIR}"
    # Modo seguro: dirs 755, arquivos 644.
    # 'X' (X maiúsculo) é o truque clássico — só adiciona x em diretórios
    # ou arquivos que já têm x. Evita dar exec em PNG/CSS/JS.
    chmod -R u=rwX,go=rX "${THEME_INSTALL_DIR}"
    ok "Tema instalado em ${THEME_INSTALL_DIR} (owner ${apache_owner}, dirs 755 / arquivos 644)."

    # SELinux: aplica contexto httpd_sys_content_t se SELinux ativo.
    if command -v restorecon >/dev/null 2>&1; then
        info "Aplicando contexto SELinux nos arquivos do tema…"
        restorecon -Rv "${THEME_INSTALL_DIR}" >/dev/null 2>&1 || true
    fi

    # ─── 3.6  Backup + instalação do favicon.ico ───
    # Reusa apache_owner já detectado no passo do tema (asterisk:asterisk
    # em Issabel padrão). O favicon do Issabel de fábrica fica em
    # /var/www/html/favicon.ico com mode 644 e apache_owner — replicamos.
    if [[ -f "${FAVICON_INSTALL_PATH}" ]]; then
        ensure_backup_dir
        local favicon_backup
        favicon_backup=$(backup_path_for "favicon.ico")
        info "favicon.ico existente detectado — backup em ${favicon_backup}…"
        cp -p "${FAVICON_INSTALL_PATH}" "${favicon_backup}" \
            || die "Falha ao fazer backup de ${FAVICON_INSTALL_PATH}."
        ok "Backup do favicon antigo: ${favicon_backup}"
    fi

    info "Instalando ${FAVICON_INSTALL_PATH}…"
    cp -p "${src_favicon_file}" "${FAVICON_INSTALL_PATH}" \
        || die "Falha ao copiar favicon.ico pra ${FAVICON_INSTALL_PATH}."
    chown "${apache_owner}" "${FAVICON_INSTALL_PATH}" \
        || warn "Falha ao definir owner ${apache_owner} em ${FAVICON_INSTALL_PATH}."
    chmod "${FAVICON_INSTALL_MODE}" "${FAVICON_INSTALL_PATH}" \
        || die "Falha ao definir modo ${FAVICON_INSTALL_MODE} em ${FAVICON_INSTALL_PATH}."
    ok "favicon.ico instalado (owner ${apache_owner}, modo ${FAVICON_INSTALL_MODE})."

    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v "${FAVICON_INSTALL_PATH}" >/dev/null 2>&1 || true
    fi

    # ─── 3.7  Backup + instalação do br.lang ───
    # Vai junto com os outros .lang de fábrica do Issabel em /var/www/html/lang/.
    # Mesma fórmula do favicon: backup datado, apache_owner, mode 644, SELinux.
    # Defensivo: se /var/www/html/lang/ não existir (Issabel modificado), cria.
    if [[ -f "${BRLANG_INSTALL_PATH}" ]]; then
        ensure_backup_dir
        local brlang_backup
        brlang_backup=$(backup_path_for "lang-br.lang")
        info "br.lang existente detectado — backup em ${brlang_backup}…"
        cp -p "${BRLANG_INSTALL_PATH}" "${brlang_backup}" \
            || die "Falha ao fazer backup de ${BRLANG_INSTALL_PATH}."
        ok "Backup do br.lang antigo: ${brlang_backup}"
    fi

    info "Instalando ${BRLANG_INSTALL_PATH}…"
    mkdir -p "$(dirname "${BRLANG_INSTALL_PATH}")"
    cp -p "${src_brlang_file}" "${BRLANG_INSTALL_PATH}" \
        || die "Falha ao copiar br.lang pra ${BRLANG_INSTALL_PATH}."
    chown "${apache_owner}" "${BRLANG_INSTALL_PATH}" \
        || warn "Falha ao definir owner ${apache_owner} em ${BRLANG_INSTALL_PATH}."
    chmod "${BRLANG_INSTALL_MODE}" "${BRLANG_INSTALL_PATH}" \
        || die "Falha ao definir modo ${BRLANG_INSTALL_MODE} em ${BRLANG_INSTALL_PATH}."
    ok "br.lang instalado (owner ${apache_owner}, modo ${BRLANG_INSTALL_MODE})."

    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v "${BRLANG_INSTALL_PATH}" >/dev/null 2>&1 || true
    fi

    # ─── 3.8  Backup + instalação do motd.sh ───
    if [[ -f "${MOTD_INSTALL_PATH}" ]]; then
        ensure_backup_dir
        local motd_backup
        motd_backup=$(backup_path_for "motd.sh")
        info "motd.sh existente detectado — backup em ${motd_backup}…"
        cp -p "${MOTD_INSTALL_PATH}" "${motd_backup}" \
            || die "Falha ao fazer backup de ${MOTD_INSTALL_PATH}."
        ok "Backup do motd.sh antigo: ${motd_backup}"
    fi

    info "Instalando ${MOTD_INSTALL_PATH}…"
    mkdir -p "$(dirname "${MOTD_INSTALL_PATH}")"
    cp -p "${src_motd_file}" "${MOTD_INSTALL_PATH}" \
        || die "Falha ao copiar motd.sh pra ${MOTD_INSTALL_PATH}."

    # Permissões EXATAS solicitadas: -rwxr-xr-x root:root (modo 755).
    # cp -p preserva o owner do tarball (extraído como root da sessão sudo);
    # explicitamos chown defensivamente caso o tar tenha sido extraído por
    # user diferente (raro em rodar sob sudo, mas barato).
    chown "${MOTD_INSTALL_OWNER}" "${MOTD_INSTALL_PATH}" \
        || warn "Falha ao definir owner ${MOTD_INSTALL_OWNER} em ${MOTD_INSTALL_PATH}."
    chmod "${MOTD_INSTALL_MODE}" "${MOTD_INSTALL_PATH}" \
        || die "Falha ao definir modo ${MOTD_INSTALL_MODE} em ${MOTD_INSTALL_PATH}."
    ok "motd.sh instalado (owner ${MOTD_INSTALL_OWNER}, modo ${MOTD_INSTALL_MODE})."

    # SELinux pro motd.sh — bin_t é o contexto correto pra binários em /usr/local/sbin.
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v "${MOTD_INSTALL_PATH}" >/dev/null 2>&1 || true
    fi

    # Confirma permissão final (visual pro usuário comparar com -rwxr-xr-x)
    info "Permissão final do motd.sh:"
    ls -l "${MOTD_INSTALL_PATH}" 2>/dev/null || true

    # ─── 3.9  Backup + instalação dos módulos PHP ───
    # Substituição COMPLETA da pasta — mesmo padrão do tema (mv → backup
    # antes de cp -rp do novo). NÃO é merge: arquivos órfãos do módulo
    # antigo causam bugs sutis no autoloader do Issabel.
    #
    # Owner = apache_owner detectado lá em cima pra dar consistência com
    # o resto dos artefatos servidos pelo Apache. dirs 755 / arquivos 644
    # via chmod u=rwX,go=rX (mesmo truque usado no tema).
    info "Detectando estado dos módulos PHP em ${MODULES_INSTALL_DIR}/…"
    mkdir -p "${MODULES_INSTALL_DIR}"

    local module_name src_module_dir dest_module_dir module_backup
    for module_name in "${MODULES_TO_INSTALL[@]}"; do
        src_module_dir="${extracted_root}/${MODULES_DIR_IN_REPO}/${module_name}"
        dest_module_dir="${MODULES_INSTALL_DIR}/${module_name}"

        if [[ -d "${dest_module_dir}" ]]; then
            ensure_backup_dir
            module_backup=$(backup_path_for "modules-${module_name}")
            info "Módulo '${module_name}' existente — movendo pra ${module_backup}…"
            mv "${dest_module_dir}" "${module_backup}" \
                || die "Falha ao mover ${dest_module_dir} pra backup."
            ok "Backup do módulo antigo: ${module_backup}"
        fi

        info "Instalando módulo '${module_name}' em ${dest_module_dir}…"
        cp -rp "${src_module_dir}" "${dest_module_dir}" \
            || die "Falha ao copiar módulo '${module_name}' pra ${dest_module_dir}."

        chown -R "${apache_owner}" "${dest_module_dir}"
        chmod -R u=rwX,go=rX "${dest_module_dir}"
        ok "Módulo '${module_name}' instalado (owner ${apache_owner}, dirs 755 / arquivos 644)."

        if command -v restorecon >/dev/null 2>&1; then
            restorecon -Rv "${dest_module_dir}" >/dev/null 2>&1 || true
        fi
    done

    # Cleanup imediato (trap também faz, mas explicit é mais higiênico)
    rm -rf "${tmp_tar}" "${tmp_extract}"
    trap - EXIT

    # ─── 3.10 Resumo final ───
    cat <<EOF

${C_BOLD}${C_GREEN}═══ Tema RAD-PBX instalado ═══${C_RESET}

  ${C_BOLD}Tema${C_RESET}:        ${THEME_INSTALL_DIR}
  ${C_BOLD}favicon.ico${C_RESET}: ${FAVICON_INSTALL_PATH}  ${C_DIM}(${FAVICON_INSTALL_MODE} ${apache_owner})${C_RESET}
  ${C_BOLD}br.lang${C_RESET}:     ${BRLANG_INSTALL_PATH}  ${C_DIM}(${BRLANG_INSTALL_MODE} ${apache_owner})${C_RESET}
  ${C_BOLD}motd.sh${C_RESET}:     ${MOTD_INSTALL_PATH}  ${C_DIM}(${MOTD_INSTALL_MODE} ${MOTD_INSTALL_OWNER})${C_RESET}
  ${C_BOLD}Módulos${C_RESET}:     ${MODULES_INSTALL_DIR}/{${MODULES_TO_INSTALL[0]},${MODULES_TO_INSTALL[1]}}/  ${C_DIM}(755/644 ${apache_owner})${C_RESET}

${C_BOLD}Próximos passos sugeridos:${C_RESET}

  1. No Issabel: ${C_DIM}System → Preferences → Theme${C_RESET} — selecione
     ${C_BOLD}rad_pbx${C_RESET} na lista e salve.
  2. Force refresh do navegador (Ctrl+Shift+R) pra invalidar cache de CSS/JS.
  3. Faça login SSH novo pra testar o banner do motd.sh.

EOF
    _log_to_file "INSTALL THEME OK: ${THEME_INSTALL_DIR}, ${MOTD_INSTALL_PATH}"
    ok "Pronto! Volte ao menu (Enter) ou Ctrl+C pra sair."
    read -r
    show_menu
}

# ════════════════════════════════════════════════════════════════════════
#  Opção 4 — Instalar RAD-PROTOCOLO (ADR-0110)
# ════════════════════════════════════════════════════════════════════════

# Instala um arquivo baixado: backup do destino se já existir, depois copia
# com owner/mode atômico via `install`.
#   $1=src  $2=dest  $3=owner(user:group)  $4=mode  $5=tag-de-backup
_proto_install_file() {
    local src="$1" dest="$2" owner="$3" mode="$4" tag="$5"
    if [[ -f "${dest}" ]]; then
        ensure_backup_dir
        local b; b=$(backup_path_for "${tag}")
        cp -p "${dest}" "${b}" || die "Falha ao backupear ${dest}."
        ok "Backup: ${b}"
    fi
    install -o "${owner%%:*}" -g "${owner##*:}" -m "${mode}" "${src}" "${dest}" \
        || die "Falha ao instalar ${dest}."
    ok "Instalado: ${dest}  (${owner}, ${mode})"
}

# Grava o padrão default local (/etc/rad-pbx/protocol-pattern.json). A Platform
# sobrescreve esse arquivo via SSH ao salvar um padrão na UI (ADR-0112).
# Idempotente: se já existir, pergunta antes de sobrescrever — não pisa num
# padrão que a Platform já tenha enviado.
_proto_seed_pattern() {
    if [[ -f "${PROTO_PATTERN_PATH}" ]]; then
        warn "Padrão local já existe: ${PROTO_PATTERN_PATH}"
        if ! confirm "Sobrescrever pelo default (sim) ou manter o atual (não)?"; then
            info "Mantendo o padrão existente."
            return
        fi
        ensure_backup_dir
        local pb; pb=$(backup_path_for "protocol-pattern.json")
        cp -p "${PROTO_PATTERN_PATH}" "${pb}" && ok "Backup: ${pb}"
    fi

    local _um; _um=$(umask); umask 027
    RAD_TEMPLATE="${PROTO_DEFAULT_TEMPLATE}" \
    python3 - "${PROTO_PATTERN_PATH}" <<'PY' || die "Falha ao gravar o padrão default."
import json, os, sys
# version 0 = padrão default do instalador (ainda não veio da Platform).
cfg = {"template": os.environ["RAD_TEMPLATE"], "sequenceStrategy": "ulid", "version": 0}
with open(sys.argv[1], "w") as fh:
    fh.write(json.dumps(cfg, indent=2) + "\n")
PY
    umask "${_um}"
    chown root:asterisk "${PROTO_PATTERN_PATH}"
    chmod 640 "${PROTO_PATTERN_PATH}"
    ok "Padrão default: ${PROTO_PATTERN_PATH}  (${PROTO_DEFAULT_TEMPLATE}, 640 root:asterisk)"
}

# Configura o sudoers para o usuário SSH da Platform rodar o setter sem senha
# (ADR-0112). Sem isso, o push do padrão pela Platform falha com "a password
# is required". Idempotente: reescreve o arquivo. Pula se o usuário for vazio
# (ex.: a Platform conecta como root, que não precisa de sudo).
_proto_setup_sudoers() {
    cat >&2 <<EOF

${C_BOLD}Acesso do setter via sudo (ADR-0112)${C_RESET}
─────────────────────────────────────
A Platform grava o padrão na central rodando ${C_DIM}${PROTO_SETTER_PATH}${C_RESET}
via SSH. Informe o usuário SSH que a Platform usa nesta central (o mesmo da
Connection / do reload do dialplan) para liberar sudo NOPASSWD só desse setter.
Deixe vazio se a Platform conecta como ${C_BOLD}root${C_RESET} (não precisa de sudo).

EOF
    local ssh_user
    ssh_user=$(prompt "Usuário SSH da Platform (vazio = root, pula sudoers)" "")
    if [[ -z "${ssh_user}" ]]; then
        info "Sem usuário SSH informado — sudoers não configurado (assumindo conexão root)."
        return
    fi
    if ! id "${ssh_user}" >/dev/null 2>&1; then
        warn "Usuário '${ssh_user}' não existe no host. Pulei o sudoers — crie o usuário e rode a opção 4 de novo, ou ajuste ${PROTO_SUDOERS_FILE} manualmente."
        return
    fi

    local tmp; tmp=$(mktemp)
    {
        printf '# RAD-PROTOCOLO (ADR-0112) — gerado por %s v%s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
        printf '# Libera a Platform a gravar o padrão via setter, sem senha.\n'
        printf '%s ALL=(root) NOPASSWD: %s\n' "${ssh_user}" "${PROTO_SETTER_PATH}"
    } > "${tmp}"

    # Valida ANTES de instalar — um sudoers quebrado trava o sudo do host todo.
    if command -v visudo >/dev/null 2>&1; then
        if ! visudo -cf "${tmp}" >/dev/null 2>&1; then
            rm -f "${tmp}"
            die "Regra sudoers inválida (visudo -c falhou). Nada foi alterado."
        fi
    else
        warn "visudo não encontrado — gravando sem validação prévia (revise ${PROTO_SUDOERS_FILE})."
    fi

    install -o root -g root -m 440 "${tmp}" "${PROTO_SUDOERS_FILE}" \
        || { rm -f "${tmp}"; die "Falha ao instalar ${PROTO_SUDOERS_FILE}."; }
    rm -f "${tmp}"
    ok "sudoers: ${ssh_user} roda ${PROTO_SETTER_PATH} via sudo NOPASSWD (${PROTO_SUDOERS_FILE}, 440)."
}

# Smoke test pós-instalação. Não aborta a instalação se algo falhar (já está
# instalado) — só avisa.
_proto_smoke_test() {
    printf '\n%s── Smoke test ──%s\n' "${C_BOLD}" "${C_RESET}"

    # 1. Dialplan: reload + contexto presente.
    if asterisk -rx "dialplan reload" >/dev/null 2>&1; then
        if asterisk -rx "dialplan show rad-protocolo" 2>/dev/null | grep -q "rad-protocolo"; then
            ok "Contexto [rad-protocolo] carregado no Asterisk."
        else
            warn "Contexto [rad-protocolo] não apareceu após reload — confira o #include."
        fi
    else
        warn "dialplan reload falhou — recarregue manualmente: asterisk -rx 'dialplan reload'."
    fi

    # 2. AGI lê o padrão local instalado e emite PROTOCOL (sem rede).
    local out val
    out=$(printf 'agi_uniqueid: install.smoke.1\nagi_channel: PJSIP/install-smoke\n\n' \
        | sudo -u asterisk python3 "${PROTO_AGI_PATH}" 2>/dev/null || true)
    if printf '%s' "${out}" | grep -q 'SET VARIABLE PROTOCOL'; then
        val=$(printf '%s' "${out}" | sed -n 's/.*SET VARIABLE PROTOCOL "\([^"]*\)".*/\1/p' | head -1)
        ok "AGI gerou PROTOCOL=${val:-?} a partir do padrão local."
    else
        warn "AGI não emitiu PROTOCOL — depure: sudo -u asterisk python3 ${PROTO_AGI_PATH}"
    fi
}

# Imprime instruções de wiring (NÃO automatizado — o instalador não toca em
# roteamento do FreePBX/Issabel).
_proto_print_wiring() {
    cat <<EOF

${C_BOLD}${C_GREEN}═══ RAD-PROTOCOLO instalado (central autônoma — ADR-0112) ═══${C_RESET}

  ${C_BOLD}AGI${C_RESET}:        ${PROTO_AGI_PATH}
  ${C_BOLD}Dialplan${C_RESET}:   /etc/asterisk/extensions_rad.conf  ${C_DIM}(contexto [rad-protocolo])${C_RESET}
  ${C_BOLD}Padrão${C_RESET}:     ${PROTO_PATTERN_PATH}  ${C_DIM}(default: ${PROTO_DEFAULT_TEMPLATE})${C_RESET}
  ${C_BOLD}Setter${C_RESET}:     ${PROTO_SETTER_PATH}  ${C_DIM}(escrita do padrão pela Platform via sudo)${C_RESET}

${C_BOLD}A central é independente da Platform.${C_RESET} O AGI lê o padrão do arquivo
local a cada chamada — sem rede, sem spool. A Platform sobrescreve esse arquivo
via SSH (sudo no setter ${PROTO_SETTER_PATH}) quando você salva um padrão na UI,
e lê os registros do CDR (não há mais POST do AGI).

${C_BOLD}${C_YELLOW}IMPORTANTE — o roteamento NÃO foi alterado.${C_RESET}
O contexto [rad-protocolo] está instalado mas INERTE. Pra ativar numa rota,
faça a Inbound Route chamar a subrotina (seta o protocolo e RETORNA, sem
Answer e sem mudar o fluxo):

  ${C_DIM}same => n,Gosub(rad-protocolo,s,1)${C_RESET}

${C_BOLD}Cutover recomendado (canary):${C_RESET}
  1. Ative o Gosub em UMA Inbound Route de teste.
  2. Ligue pra ela; confirme o protocolo no CDR (accountcode) e no Dashboard.
  3. Só então propague pras demais rotas.
  Passo a passo completo: runbook ${C_BOLD}protocol-cutover${C_RESET} no vault.

${C_BOLD}Trocar o formato:${C_RESET} na UI (Padrões de Protocolo) — a Platform reescreve
${PROTO_PATTERN_PATH} via SSH. Pra testar local, edite o arquivo: a próxima
chamada já usa o novo template.

EOF
}

install_rad_protocolo() {
    printf '\n%s═══ Instalação do RAD-PROTOCOLO (ADR-0112 — central autônoma) ═══%s\n\n' "${C_BOLD}" "${C_RESET}"

    # ─── 4.0  Pré-requisitos específicos ───
    require_cmd python3 "yum install -y python3   (CentOS 7 traz 3.6.8, suficiente)"
    require_cmd install
    if ! id asterisk >/dev/null 2>&1; then
        die "Usuário 'asterisk' não existe — esperado em servidor Issabel/Asterisk."
    fi
    if ! python3 -c 'import json, secrets' >/dev/null 2>&1; then
        die "python3 sem stdlib essencial (json/secrets) — instale python3-libs."
    fi

    # ─── 4.1  Token GitHub (mesma UX das opções 1 e 3) ───
    local token
    token=$(get_github_token "${SOURCE_REPO_OWNER_DEFAULT}" "${SOURCE_REPO_NAME_DEFAULT}" \
        "os scripts do RAD-PROTOCOLO (ADR-0112)")

    # ─── 4.2  Download dos artefatos pra um tmp ───
    local tmp; tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' EXIT
    local entry repo_path dest owner mode tag
    for entry in "${PROTO_FILES[@]}"; do
        IFS='|' read -r repo_path dest owner mode tag <<< "${entry}"
        github_download_file "${token}" "${SOURCE_REPO_OWNER_DEFAULT}" \
            "${SOURCE_REPO_NAME_DEFAULT}" "${SOURCE_REPO_BRANCH}" \
            "${repo_path}" "${tmp}/$(basename "${dest}")"
    done
    token=""  # não é mais necessário

    # ─── 4.3  Diretório de config/padrão (idempotente) ───
    mkdir -p "${PROTO_CONFIG_DIR}" && chown root:asterisk "${PROTO_CONFIG_DIR}" && chmod 750 "${PROTO_CONFIG_DIR}"
    ok "Diretório pronto: ${PROTO_CONFIG_DIR}  (750 root:asterisk)"

    # ─── 4.4  Instala os arquivos (backup do anterior se houver) ───
    for entry in "${PROTO_FILES[@]}"; do
        IFS='|' read -r repo_path dest owner mode tag <<< "${entry}"
        _proto_install_file "${tmp}/$(basename "${dest}")" "${dest}" "${owner}" "${mode}" "${tag}"
    done

    # ─── 4.5  Padrão default local (Platform sobrescreve por SSH depois) ───
    _proto_seed_pattern

    # ─── 4.6  sudoers do setter (push do padrão pela Platform) ───
    _proto_setup_sudoers

    # ─── 4.7  #include extensions_rad.conf (idempotente, com backup) ───
    if grep -qxF "#include ${PROTO_DIALPLAN_INCLUDE}" "${PROTO_EXTENSIONS_CONF}" 2>/dev/null; then
        ok "#include ${PROTO_DIALPLAN_INCLUDE} já presente em ${PROTO_EXTENSIONS_CONF}."
    else
        ensure_backup_dir
        local ext_bak; ext_bak=$(backup_path_for "extensions.conf")
        if cp -p "${PROTO_EXTENSIONS_CONF}" "${ext_bak}" 2>/dev/null; then
            ok "Backup: ${ext_bak}"
        else
            warn "Não consegui backupear ${PROTO_EXTENSIONS_CONF} (segue mesmo assim)."
        fi
        printf '\n#include %s\n' "${PROTO_DIALPLAN_INCLUDE}" >> "${PROTO_EXTENSIONS_CONF}" \
            || die "Falha ao adicionar #include em ${PROTO_EXTENSIONS_CONF}."
        ok "#include ${PROTO_DIALPLAN_INCLUDE} adicionado a ${PROTO_EXTENSIONS_CONF}."
    fi

    # ─── 4.8  Smoke test ───
    _proto_smoke_test

    # ─── 4.9  Instruções de wiring (manual — não tocamos em roteamento) ───
    _proto_print_wiring

    rm -rf "${tmp}"; trap - EXIT
    _log_to_file "INSTALL RAD-PROTOCOLO (autonomo) OK"
    ok "Pronto! Volte ao menu (Enter) ou Ctrl+C pra sair."
    read -r </dev/tty || true
    show_menu
}

# ════════════════════════════════════════════════════════════════════════
#  Main
# ════════════════════════════════════════════════════════════════════════

main() {
    # ─── Diagnóstico de TTY (visível pro usuário) ───
    # Quando rodado via `curl ... | sudo bash`, o stdin do bash É o pipe do
    # curl — todos os `read` recebem EOF imediato. Tentamos:
    #   1. Detectar via [[ -t 0 ]] se stdin é tty
    #   2. Se não, e /dev/tty está acessível, reanexar via exec </dev/tty
    #   3. Belt-and-suspenders: cada read individual também faz </dev/tty
    #   4. Se nenhum dos dois funcionar, mensagem clara apontando wget
    local stdin_is_tty="NAO" tty_dev_readable="NAO"
    [[ -t 0 ]] && stdin_is_tty="SIM"
    [[ -r /dev/tty ]] && tty_dev_readable="SIM"

    printf '%s\n' "${C_DIM}[diagnóstico] stdin é tty? ${stdin_is_tty} · /dev/tty acessível? ${tty_dev_readable}${C_RESET}"

    if [[ "${stdin_is_tty}" == "NAO" ]]; then
        if [[ "${tty_dev_readable}" == "SIM" ]]; then
            printf '%s\n' "${C_DIM}[diagnóstico] reanexando /dev/tty via exec…${C_RESET}"
            exec </dev/tty
            if [[ -t 0 ]]; then
                printf '%s\n' "${C_DIM}[diagnóstico] reanexar OK — stdin agora é tty.${C_RESET}"
            else
                printf '%s\n' "${C_DIM}[diagnóstico] exec não tornou stdin tty — usando </dev/tty em cada read individualmente.${C_RESET}"
            fi
        else
            printf '%s\n' "${C_RED}✗${C_RESET} Sem terminal interativo (stdin não é tty e /dev/tty inacessível)." >&2
            printf '%s\n' "" >&2
            printf '%s\n' "Baixe e rode com:" >&2
            printf '%s\n' "  wget https://raw.githubusercontent.com/rdebruem/rad-pbx-api/main/install.sh" >&2
            printf '%s\n' "  chmod +x install.sh" >&2
            printf '%s\n' "  sudo ./install.sh" >&2
            exit 1
        fi
    fi

    _log_init
    preflight
    show_menu
}

main "$@"
