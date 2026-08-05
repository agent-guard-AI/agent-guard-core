#!/usr/bin/env bash
#
# grid.sh — abre janelas kitty em grade 2x2 nos monitores extras.
# Modulo do agent-guard-core (migrado de .kiro/shell/hmvip-tab/ na F1 da spec
# agent-guard-tab-unification-20260805). Nomes de funcoes _hmvip_grid_*
# preservados para compatibilidade.
#
# Sourceado pelo ~/.bashrc (instalado por `agent-guard tab install`) ou pelo
# subcomando `agent-guard grid`. Segue as regras de shell-safety do HMVIP:
# NAO altera flags do shell, NAO faz cd, NAO usa exit — apenas define funcoes.
#
# Uso:
#   hmvip grid                      # 4 kitty (2x2) em cada monitor EXTRA (principal livre)
#   hmvip grid --primary            # inclui o monitor principal na grade
#   hmvip grid --only DP-1,HDMI-0   # so nos monitores listados
#   hmvip grid --cmd "kimi"         # abre cada janela ja rodando o comando
#   hmvip grid --replace            # fecha a grade atual antes de abrir outra
#   hmvip grid close                # fecha todas as janelas da grade
#   hmvip grid layout               # mostra o plano (dry-run), sem abrir nada
#
# Como funciona (GNOME/Ubuntu, X11):
#   1. Abre 1 janela kitty por quadrante (WM_CLASS=hmvip-grid).
#   2. Move grosseiramente para o centro do quadrante-alvo (so para a janela
#      estar no monitor certo).
#   3. Dispara o quarter-tiling NATIVO via atalho do Ubuntu Tiling Assistant
#      (tile-topleft-quarter etc., padrao Super+KP_7/9/1/3): a janela encaixa
#      pixel-perfeito no quadrante, respeitando paineis, dock e gaps.
#   Fallback: se a extensao nao reagir, aplica posicionamento manual (xdotool).
#
# Requer: X11, xrandr, xdotool, kitty. Wayland nao suportado.
#

HMVIP_GRID_CLASS="${HMVIP_GRID_CLASS:-hmvip-grid}"

# Lista monitores conectados via `xrandr --listmonitors`.
# Saida (uma linha por monitor): "<nome> <primario:0|1> <x> <y> <w> <h>"
function _hmvip_grid_monitors() {
    xrandr --listmonitors 2>/dev/null | awk '
        /^ *[0-9]+:/ {
            flags = $2; sub(/^\+/, "", flags)
            primary = (index(flags, "*") > 0) ? 1 : 0
            # geometria: W/mm x H/mm + X + Y  (ex: 1920/344x1080/194+812+768)
            geo = $3
            split(geo, a, /[x+]/)
            split(a[1], w, "/")
            split(a[2], h, "/")
            name = $4
            printf "%s %d %d %d %d %d\n", name, primary, a[3], a[4], w[1], h[1]
        }'
}

# Imprime o plano da grade: "<monitor> <q> <cx> <cy> <w> <h>" por linha, onde
# cx,cy e o CENTRO do quadrante (alvo do move grosseiro) e w,h o quadrante.
# Args: <include_primary:0|1> <only_csv>
function _hmvip_grid_plan() {
    local include_primary="$1" only_csv="$2"
    local name primary x y w h
    local mons
    mons="$(_hmvip_grid_monitors)" || return 1
    [ -n "${mons}" ] || { echo "Nenhum monitor detectado via xrandr." >&2; return 1; }

    # Ordena da esquerda para a direita (por X) para nomeacao estavel M1..Mn.
    local line idx=0
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        read -r name primary x y w h <<<"${line}"
        if [ "${primary}" = "1" ] && [ "${include_primary}" != "1" ]; then
            continue
        fi
        if [ -n "${only_csv}" ]; then
            case ",${only_csv}," in
                *",${name},"*) : ;;
                *) continue ;;
            esac
        fi
        idx=$((idx + 1))
        local hw hh q cx cy
        hw=$((w / 2))
        hh=$((h / 2))
        for q in 1 2 3 4; do
            case "${q}" in
                1) cx=$((x + hw / 2));      cy=$((y + hh / 2)) ;;
                2) cx=$((x + hw + hw / 2)); cy=$((y + hh / 2)) ;;
                3) cx=$((x + hw / 2));      cy=$((y + hh + hh / 2)) ;;
                4) cx=$((x + hw + hw / 2)); cy=$((y + hh + hh / 2)) ;;
            esac
            printf '%s %d %d %d %d %d\n' "M${idx}(${name})" "${q}" "${cx}" "${cy}" "${hw}" "${hh}"
        done
    done <<<"$(printf '%s\n' "${mons}" | sort -k3,3n)"
    return 0
}

# WIDs (X window ids) das janelas da grade abertas. --onlyvisible filtra so
# janelas top-level mapeadas (o kitty cria janelas transitorias durante o
# startup, que quebravam o pareamento wid->quadrante).
function _hmvip_grid_wids() {
    xdotool search --onlyvisible --class "${HMVIP_GRID_CLASS}" 2>/dev/null | sort -n
}

# Fecha todas as janelas da grade (graceful; fallback para kill).
function _hmvip_grid_close() {
    local wids wid count=0
    wids="$(_hmvip_grid_wids)"
    if [ -z "${wids}" ]; then
        echo "Nenhuma janela da grade (${HMVIP_GRID_CLASS}) aberta."
        return 0
    fi
    while IFS= read -r wid; do
        [ -n "${wid}" ] || continue
        xdotool windowclose "${wid}" 2>/dev/null \
            || xdotool windowkill "${wid}" 2>/dev/null \
            || true
        count=$((count + 1))
    done <<<"${wids}"
    echo "Fechadas ${count} janela(s) da grade."
    return 0
}

# Abre uma janela kitty e espera mapear. Define _HMVIP_GRID_LAST_WID.
# Args: <title> <cmd...>
function _hmvip_grid_open_one() {
    local title="$1"
    shift
    local before after wid tries
    # before/after em UMA linha separada por espacos: o teste de pertencimento
    # via case " $before " exige wid cercado de espacos (newlines quebrariam
    # a comparacao e o diff pegaria sempre a primeira janela da grade).
    before=" $(_hmvip_grid_wids | tr '\n' ' ') "
    # resize_in_steps=no: o kitty arredonda tamanhos para celulas de caracteres
    # por padrao, o que quebraria o encaixe pixel-exato do quadrante.
    # remember_window_size=no: nao restaurar tamanho de sessoes anteriores.
    if [ "$#" -gt 0 ]; then
        setsid kitty --class "${HMVIP_GRID_CLASS}" --title "${title}" \
            -o resize_in_steps=no -o remember_window_size=no \
            --directory "${HOME}" "$@" >/dev/null 2>&1 </dev/null &
    else
        setsid kitty --class "${HMVIP_GRID_CLASS}" --title "${title}" \
            -o resize_in_steps=no -o remember_window_size=no \
            --directory "${HOME}" >/dev/null 2>&1 </dev/null &
    fi
    # Espera a janela nova aparecer (diff do conjunto de WIDs da grade),
    # com checagem de estabilidade: o wid precisa continuar existindo e
    # sendo visivel apos 0.3s (descarta janelas transitorias do startup).
    wid=""
    tries=0
    while [ "${tries}" -lt 100 ]; do
        after=" $(_hmvip_grid_wids | tr '\n' ' ') "
        local candidate
        for candidate in ${after}; do
            case " ${before} " in
                *" ${candidate} "*) : ;;
                *)
                    sleep 0.3
                    if xdotool getwindowname "${candidate}" >/dev/null 2>&1 \
                        && xdotool search --onlyvisible --class "${HMVIP_GRID_CLASS}" 2>/dev/null \
                            | grep -qx "${candidate}"; then
                        wid="${candidate}"
                    fi
                    ;;
            esac
            [ -n "${wid}" ] && break
        done
        [ -n "${wid}" ] && break
        tries=$((tries + 1))
        sleep 0.1
    done
    if [ -z "${wid}" ]; then
        echo "  ⚠ ${title}: janela nao apareceu (timeout)" >&2
        return 1
    fi
    _HMVIP_GRID_LAST_WID="${wid}"
    echo "  ✔ ${title} aberta"
    return 0
}

# Keysym do atalho de quarter-tiling do Tiling Assistant para o quadrante,
# conforme o estado do NumLock (padrao: Super+KP_7/9/1/3; com NumLock off o
# keypad emite KP_Home/Prior/End/Next — o binding so casa com a variante certa).
function _hmvip_grid_tile_keysym() {
    local q="$1" numlock
    numlock="$(xset q 2>/dev/null | sed -n 's/.*Num Lock: *\([a-z]*\).*/\1/p')"
    if [ "${numlock}" = "on" ]; then
        case "${q}" in
            1) printf 'KP_7' ;;
            2) printf 'KP_9' ;;
            3) printf 'KP_1' ;;
            4) printf 'KP_3' ;;
        esac
    else
        case "${q}" in
            1) printf 'KP_Home' ;;
            2) printf 'KP_Prior' ;;
            3) printf 'KP_End' ;;
            4) printf 'KP_Next' ;;
        esac
    fi
}

# Foca a janela com um clique real (XTEST) no centro dela. windowactivate e
# negado intermitentemente pelo focus-stealing-prevention do GNOME; o clique
# XTEST conta como interacao do usuario e sempre foca.
function _hmvip_grid_focus_click() {
    local wid="$1" cx="$2" cy="$3"
    xdotool mousemove "${cx}" "${cy}" click 1 2>/dev/null || true
    sleep 0.25
}

# Dispara o quarter-tiling nativo na janela. Retorna 0 se a janela ficou
# encaixada no quadrante (centro dentro do quadrante + tamanho compativel,
# tolerando gaps da extensao e o clamp do workarea nos paineis).
# Args: <wid> <q> <cx> <cy> <qw> <qh>
function _hmvip_grid_tile_quarter() {
    local wid="$1" q="$2" cx="$3" cy="$4" qw="$5" qh="$6"
    local keysym
    keysym="$(_hmvip_grid_tile_keysym "${q}")"
    [ -n "${keysym}" ] || return 1
    _hmvip_grid_focus_click "${wid}" "${cx}" "${cy}"
    xdotool key --clearmodifiers "super+${keysym}" 2>/dev/null || true
    sleep 0.7
    # Encaixe: centro da janela dentro do quadrante-alvo e tamanho >=
    # quadrante - 150px (gaps + paineis reduzem um pouco as dimensoes).
    local ax ay aw ah acx acy ex ey
    read -r ax ay aw ah <<<"$(_hmvip_grid_geom "${wid}")"
    ex=$((cx - qw / 2))
    ey=$((cy - qh / 2))
    acx=$((ax + aw / 2))
    acy=$((ay + ah / 2))
    [ "${acx}" -ge "${ex}" ] && [ "${acx}" -le $((ex + qw)) ] \
        && [ "${acy}" -ge "${ey}" ] && [ "${acy}" -le $((ey + qh)) ] \
        && [ "${aw}" -ge $((qw - 150)) ] && [ "${ah}" -ge $((qh - 150)) ]
}

# Geometria atual "<x> <y> <w> <h>" de uma janela.
function _hmvip_grid_geom() {
    local g
    g="$(xdotool getwindowgeometry --shell "$1" 2>/dev/null)"
    local x y w h
    x="$(printf '%s\n' "${g}" | sed -n 's/^X=//p')"
    y="$(printf '%s\n' "${g}" | sed -n 's/^Y=//p')"
    w="$(printf '%s\n' "${g}" | sed -n 's/^WIDTH=//p')"
    h="$(printf '%s\n' "${g}" | sed -n 's/^HEIGHT=//p')"
    printf '%s %s %s %s' "${x:-0}" "${y:-0}" "${w:-0}" "${h:-0}"
}

function _hmvip_grid_usage() {
    cat <<'EOF'
hmvip grid — grade 2x2 de janelas kitty nos monitores extras

  hmvip grid                      4 kitty em cada monitor EXTRA (principal livre)
  hmvip grid --primary            inclui o monitor principal na grade
  hmvip grid --only DP-1,HDMI-0   restringe aos monitores listados
  hmvip grid --cmd "kimi"         cada janela ja abre rodando o comando
  hmvip grid --replace            fecha a grade atual antes de abrir outra
  hmvip grid close                fecha todas as janelas da grade
  hmvip grid layout               dry-run: mostra o plano sem abrir nada

Usa o quarter-tiling NATIVO do Ubuntu Tiling Assistant (Super+KP_7/9/1/3) —
as janelas encaixam pixel-perfeito, respeitando paineis/dock/gaps.
Requer X11 + xrandr + xdotool + kitty. Wayland nao suportado.
As janelas usam WM_CLASS=hmvip-grid (e assim que `close` as encontra).
EOF
}

function _hmvip_grid_cmd() {
    # Wayland: xdotool/xrandr nao funcionam para posicionamento.
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        echo "hmvip grid requer X11 (sessao atual: wayland)." >&2
        return 1
    fi
    local dep
    for dep in xrandr xdotool kitty xset; do
        if ! command -v "${dep}" >/dev/null 2>&1; then
            echo "Dependencia ausente: ${dep}" >&2
            return 1
        fi
    done

    local sub="${1:-}"
    case "${sub}" in
        -h|--help|ajuda)
            _hmvip_grid_usage
            return 0
            ;;
        close|fechar)
            _hmvip_grid_close
            return $?
            ;;
    esac

    local include_primary=0 only_csv="" replace=0 dry_run=0
    local cmd_args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --primary|--all|--include-primary) include_primary=1 ;;
            --only)        only_csv="${2:-}"; shift ;;
            --only=*)      only_csv="${1#*=}" ;;
            --cmd)         cmd_args=(sh -c "${2:-}"); shift ;;
            --cmd=*)       cmd_args=(sh -c "${1#*=}") ;;
            --replace)     replace=1 ;;
            layout|plan|dry-run|--dry-run) dry_run=1 ;;
            *) echo "Opcao desconhecida: $1" >&2; _hmvip_grid_usage; return 1 ;;
        esac
        shift
    done

    local plan
    plan="$(_hmvip_grid_plan "${include_primary}" "${only_csv}")" || return 1
    if [ -z "${plan}" ]; then
        echo "Nenhum monitor selecionado (o principal fica livre por padrao; use --primary para inclui-lo)." >&2
        return 1
    fi

    if [ "${dry_run}" = "1" ]; then
        printf '%-16s %-2s %-8s %-8s %-6s %-6s\n' "MONITOR" "Q" "CX" "CY" "W" "H"
        printf '%s\n' "${plan}" | while IFS= read -r l; do
            local m q cx cy w h
            read -r m q cx cy w h <<<"${l}"
            printf '%-16s %-2s %-8s %-8s %-6s %-6s\n' "${m}" "${q}" "${cx}" "${cy}" "${w}" "${h}"
        done
        return 0
    fi

    if [ "${replace}" = "1" ]; then
        _hmvip_grid_close
    elif [ -n "$(_hmvip_grid_wids)" ]; then
        echo "Ja existe uma grade aberta. Use 'hmvip grid close' ou 'hmvip grid --replace'." >&2
        return 1
    fi

    local total=0 ok=0 line mon q cx cy w h
    local entries=()
    total="$(printf '%s\n' "${plan}" | grep -c . || true)"
    echo "Abrindo ${total} janela(s) kitty em grade 2x2..."
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        read -r mon q cx cy w h <<<"${line}"
        _HMVIP_GRID_LAST_WID=""
        if _hmvip_grid_open_one "hmvip ${mon} q${q}" "${cmd_args[@]}"; then
            ok=$((ok + 1))
            entries+=("${_HMVIP_GRID_LAST_WID}|${mon}|${q}|${cx}|${cy}|${w}|${h}")
        fi
    done <<<"${plan}"
    if [ "${ok}" -eq 0 ]; then
        echo "Nenhuma janela abriu." >&2
        return 1
    fi

    # Posicionamento: move grosseiro para o centro do quadrante (garante o
    # monitor certo) + quarter-tiling nativo do Tiling Assistant.
    sleep 1
    local entry wid
    local ex ey
    for entry in "${entries[@]}"; do
        IFS='|' read -r wid mon q cx cy w h <<<"${entry}"
        # Move grosseiro: canto superior-esquerdo = centro - metade do quadrante.
        ex=$((cx - w / 2))
        ey=$((cy - h / 2))
        xdotool windowmove "${wid}" "${ex}" "${ey}" 2>/dev/null || true
        xdotool windowsize "${wid}" "${w}" "${h}" 2>/dev/null || true
        sleep 0.3
        _hmvip_grid_focus_click "${wid}" "${cx}" "${cy}"
        xdotool key --clearmodifiers "super+$(_hmvip_grid_tile_keysym "${q}")" 2>/dev/null || true
        sleep 0.5
    done
    # Varredura de consistencia: janela com altura == quadrante cru nao foi
    # tileada (o tile nativo aplica gaps e encolhe um pouco) — re-dispara.
    local pass tiled ax ay aw ah
    for pass in 1 2 3; do
        local pending=0
        for entry in "${entries[@]}"; do
            IFS='|' read -r wid mon q cx cy w h <<<"${entry}"
            read -r ax ay aw ah <<<"$(_hmvip_grid_geom "${wid}")"
            if [ "${ah}" -ge "${h}" ]; then
                pending=$((pending + 1))
                _hmvip_grid_focus_click "${wid}" "${cx}" "${cy}"
                xdotool key --clearmodifiers "super+$(_hmvip_grid_tile_keysym "${q}")" 2>/dev/null || true
                sleep 0.5
            fi
        done
        [ "${pending}" -eq 0 ] && break
    done
    # Relatorio final.
    local placed=0 tiled=0
    for entry in "${entries[@]}"; do
        IFS='|' read -r wid mon q cx cy w h <<<"${entry}"
        read -r ax ay aw ah <<<"$(_hmvip_grid_geom "${wid}")"
        placed=$((placed + 1))
        if [ "${ah}" -lt "${h}" ]; then
            tiled=$((tiled + 1))
            echo "  ✔ ${mon} q${q} @ ${ax},${ay} ${aw}x${ah} (tile nativo)"
        else
            echo "  ⚠ ${mon} q${q} @ ${ax},${ay} ${aw}x${ah} (manual — tile nao pegou)"
        fi
    done
    echo "Pronto: ${placed}/${total} janela(s) posicionadas (${tiled} via tile nativo). Feche com: hmvip grid close"
    [ "${placed}" = "${total}" ] && return 0 || return 1
}

