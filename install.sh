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
readonly SCRIPT_VERSION="0.3.2"

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

# Asterisk Manager Interface.
readonly MANAGER_CONF="/etc/asterisk/manager.conf"
readonly AMI_USER_DEFAULT="rad-localhost"
readonly AMI_READ_PERMS="system,call,user,reporting"
# write=command é OBRIGATÓRIO pro Action:Command funcionar — o PHP usa
# Action:Command "core show hints" como fallback de BLF em Asterisk <13.7
# (Issabel típico). Sem isso, AMI responde "Permission denied" e nenhum
# hint é coletado. system,call adicionados pra preparação futura (Originate,
# Reload em pipelines admin). User fica restrito a 127.0.0.1 via permit/deny,
# então a superfície de risco continua nula em deployments típicos.
readonly AMI_WRITE_PERMS="command,system,call"

# Log centralizado — todo output do script é também tee'd pra cá.
readonly LOG_DIR="/var/log"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"

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
get_github_token() {
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
privado ${C_BOLD}${SOURCE_REPO_OWNER_DEFAULT}/${SOURCE_REPO_NAME_DEFAULT}${C_RESET} pra baixar o rad-contacts.php.

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
#   $2 = path no repo (ex: apps/rad-softphone/server/issabel/rad-contacts.php)
#   $3 = destino local
github_download_file() {
    local token="$1" repo_path="$2" dest="$3"
    local url="https://api.github.com/repos/${SOURCE_REPO_OWNER_DEFAULT}/${SOURCE_REPO_NAME_DEFAULT}/contents/${repo_path}?ref=${SOURCE_REPO_BRANCH}"

    info "Baixando ${repo_path} (branch ${SOURCE_REPO_BRANCH})…"
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

# Adiciona seção [user] no final do manager.conf, com backup datado.
# Não toca em seções existentes.
manager_add_user() {
    local user="$1" secret="$2" backup
    backup="${MANAGER_CONF}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "${MANAGER_CONF}" "${backup}" || die "Falha ao fazer backup de ${MANAGER_CONF}."
    ok "Backup salvo em ${backup}."

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

    ok "Seção [${user}] adicionada em ${MANAGER_CONF}."
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

  ${C_BOLD}q${C_RESET})  Sair

EOF
    local choice
    read -r -p "Escolha uma opção: " choice </dev/tty
    case "${choice}" in
        1)  install_contacts_api ;;
        2)  install_ptbr_audios ;;
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
        local existing_backup
        existing_backup="${INSTALL_PATH}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        cp -p "${INSTALL_PATH}" "${existing_backup}"
        ok "Backup do PHP existente: ${existing_backup}"
    fi

    # ─── 1.1  Token GitHub ───
    local token
    token=$(get_github_token)

    # ─── 1.2  Baixar PHP do repo privado pra /tmp ───
    local tmp_php="/tmp/rad-contacts.php.$$"
    trap 'rm -f "${tmp_php}"' EXIT

    github_download_file "${token}" "${PHP_PATH_IN_REPO}" "${tmp_php}"

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

    if manager_section_exists "${ami_user}"; then
        warn "Já existe seção [${ami_user}] em ${MANAGER_CONF}."
        if ! confirm "Pular criação (sim) ou abortar pra você revisar (não)?"; then
            die "Abortado a pedido do usuário."
        fi
        ami_secret=""  # sinal que pulamos
    else
        ami_secret=$(prompt_secret "Senha do AMI (input escondido — deixe vazio pra gerar automaticamente)")
        if [[ -z "${ami_secret}" ]]; then
            ami_secret=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)
            info "Senha AMI gerada automaticamente: ${C_BOLD}${ami_secret}${C_RESET}"
            warn "Guarde essa senha agora — ela não será exibida de novo."
        fi
        manager_add_user "${ami_user}" "${ami_secret}"

        # Grava as MESMAS credenciais no PHP (ADR-0215) pra que o
        # rad-contacts.php colete BLF/presença via AMI local. Sem isso,
        # listagem de contatos funciona mas sem campo `presence`.
        php_set_ami_creds "${INSTALL_PATH}" "${ami_user}" "${ami_secret}"

        # Reload do manager
        info "Recarregando manager do Asterisk…"
        if asterisk -rx "manager reload" >/dev/null 2>&1; then
            ok "Manager recarregado."
        else
            warn "Asterisk não respondeu ao reload — pode estar parado."
        fi

        # Show user pra confirmar
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
