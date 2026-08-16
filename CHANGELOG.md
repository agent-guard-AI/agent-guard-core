# Changelog — agent-guard-core

## 0.10.6 — Auto-Rescue Protocol

Resolve o bloqueio de slots cuja sessão anterior morreu sem commitar o
worktree. Quando um agente trava, o terminal é fechado ou o processo morre, o
worktree fica "sujo" e o próximo `go`/`adopt`/`attach` era barrado pelas
camadas de proteção do agent-guard. Agora o agent-guard detecta sessões
mortas com worktree sujo e cria automaticamente um commit de resgate, uma tag
e um registro na nota do slot para revisão posterior.

- `src/init.sh`:
  - Novo Auto-Rescue Protocol (`_ag_auto_rescue_dirty_worktree` e
    `_ag_update_task_note_rescue`):
    - Cria commit `rescue(<id>): [IA-<id>] F? auto-rescue from ...` com
      corpo `REVIEW REQUIRED`, listando todos os arquivos resgatados.
    - Cria tag leve `rescue-<id>-<timestamp>` apontando para o rescue commit.
    - Atualiza a nota do slot com seção "Resgate automático pendente de
      revisão", hash, tag, motivo e arquivos resgatados.
    - Commits de follow-up `rescue-note(<id>)` registram a nota com o hash
      final, garantindo worktree limpo ao final.
  - Ativação:
    - `--adopt`: sempre resgata worktrees sujos de sessões confirmadas mortas.
    - Aquisição de slot (`go`): slots mortos com worktree sujo são
      considerados livres e resgatados após alocação.
    - `--attach` via wrapper: resgata se a sessão anterior estiver morta.
  - Segurança:
    - Só resgata na branch própria do slot (`ia-<id>/*`, `_released/<id>`) ou
      branch base segura (`develop`, `main`, `master`).
    - Só resgata quando a sessão anterior está confirmada como morta.
    - Respeita `AG_NO_AUTO_RESCUE=1` para desabilitar o comportamento.
  - `_branch_belongs_to_identity_or_base` movida para escopo global para
    ficar disponível com `AGENT_GUARD_FUNCTIONS_ONLY=1` e para o rescue.
- `tests/auto-rescue-test.sh`:
  - Teste funcional que simula sessão morta com worktree sujo, chama o
    auto-rescue e verifica: worktree limpo, commit com `REVIEW REQUIRED`,
    tag `rescue-*` e nota do slot atualizada.
- `tests/run-all.sh`:
  - Inclui `auto-rescue-test.sh` na suite do agent-guard-core.

## 0.10.5 — CodeWhale Support

Adiciona suporte oficial ao CodeWhale CLI, permitindo que sessões do CodeWhale
nascam isoladas em worktrees próprios assim como Kimi, Amp e Kilo.

- `wrappers/codewhale/wrapper.sh`:
  - Wrapper do CodeWhale CLI que intercepta o launcher npm, adquire um slot
    `codewhale<n>` via `init` e redireciona a sessão para o worktree alugado.
  - Suporte a `--slot <identidade>` e `AGENT_GUARD_SLOT` para seleção explícita
    de slot.
  - Guarda contra execução no repo principal, worktrees estrangeiras e worktrees
    sujas com trabalho de outro agente.
  - Exporta `AGENT_GUARD_REPO_ROOT` para garantir que o `agent-guard-config`
    leia o `agent-guard.yaml` correto independentemente do cwd.
- `wrappers/codewhale/recovery.sh`:
  - Recupera o wrapper automaticamente após `npm install -g codewhale` ou
    self-updates que recriem o launcher original.
  - Preserva o launcher real como `codewhale.real` e mantém backups rotativos
    (`AG_CODEWHALE_BACKUP_KEEP`, padrão 3).
- `packages/agent-guard-core/bin/agent-guard`:
  - Adiciona `codewhale` em `KNOWN_IDENTITIES` para que o CLI reconheça a nova
    identidade.
- `agent-guard.yaml.example`:
  - Adiciona identidade `codewhale` e configuração de wrapper de exemplo.
- `README.md`:
  - Documenta o wrapper CodeWhale na lista de adapters oficiais, na árvore de
    componentes, na configuração de exemplo e na seção de adapters.
- `tests/agent-guard/codewhale-wrapper-test.sh`:
  - Testes comportamentais cobrindo: pass-through de management commands,
    instalação do wrapper, restauração após npm update e respeito ao
    `AGENT_GUARD_REPO_ROOT`.

## 0.10.4 — Shared-PID Cleanup

Adiciona limpeza automática de slots que compartilham o mesmo PID vivo. Esse
 cenário ocorre quando um único processo IDE (ex.: `kimi-code`) adquire leases
 de múltiplos slots e libera apenas o primário, deixando os secundários
 fantasmas no `--status`. A melhoria mantém o slot com atividade mais recente
 e libera os demais de forma segura (worktree limpo + sem PRs abertos).

- `src/release-helpers.sh`:
  - Nova função `_cleanup_shared_pid_sessions()` que detecta grupos de slots
    ativos apontando para o mesmo PID vivo, ordena por `last_activity`
    descendente e tenta auto-release dos secundários via
    `_auto_release_if_safe()`.
  - `_cleanup_stale_sessions()` agora invoca `_cleanup_shared_pid_sessions()`
    antes da limpeza por stale time/PID morto, garantindo que leases órfãos
    sejam tratados em primeiro lugar.
  - Liberação de shared-PID é auditada no journal com ação
    `shared_pid_cleanup_blocked` quando bloqueada por worktree sujo ou PRs
    abertos.
- `tests/agent-guard/agent-guard-shared-pid-cleanup-test.sh`:
  - Testes comportamentais cobrindo: liberação do slot menos recente,
    preservação do mais recente, proteção de worktree sujo e dispatch via
    CLI `cleanup-stale`.

### Correções na 0.10.4

- `src/release-helpers.sh`:
  - `_cleanup_shared_pid_sessions()` agora usa `LC_ALL=C` na ordenação por
    `last_activity`. Sem isso, locales onde a vírgula é separador decimal
    (ex.: `pt_BR`) faziam `sort -n` tratar `1786543661.967517` como menor que
    `1786540475.0792904`, mantendo o slot *mais antigo* e tentando liberar o
    mais recente.
- `tests/agent-guard/agent-guard-shared-pid-cleanup-test.sh`:
  - Novo caso de teste com timestamps fracionados para garantir que a
    ordenação seja estável independentemente do locale do runner.
- `.kiro/scripts/agent-guard-cleanup.sh`:
  - Agora resolve o init stub mais atualizado disponível (repo principal em
    `develop`/`main`, worktree em trunk, ou worktree com
    `packages/agent-guard-core` modificado mais recentemente). Antes, o script
    usava sempre o stub do repo principal, que frequentemente fica em branch
    antiga neste setup multi-IA e não continha o shared-PID cleanup.

## 0.10.3 — Dead-PID Stale Cleanup + Descriptive Branch Names

Corrige a falha de engenharia onde sessões cujo PID havia morrido permaneciam
marcadas como `active` indefinidamente, bloqueando adoção automática via
`hmvip go`/`hmvip ad` e acumulando slots fantasmas no `--status`. Adiciona
suporte a nomes descritivos de branch para que seja possível identificar o
conteúdo de cada slot sem abrir o worktree.

- `src/release-helpers.sh`:
  - `_cleanup_stale_sessions()` agora trata PID morto como sessão stale por
    definição. Antes, a condição `_is_pid_alive || continue` fazia o cleanup
    ignorar deliberadamente sessões com PID morto, deixando o lease file
    preso para sempre.
  - Sessões active com PID inexistente/zombie são candidatas a auto-release
    seguro (worktree limpo + sem PRs abertos), exatamente como sessões stale
    por tempo ou shell-pinned.
- `src/init.sh`:
  - Novo parâmetro `--topic "<descrição>"` para `init`, `--slot`, `--attach` e
    `--adopt`. A descrição é convertida em slug e incorporada ao nome da
    branch: `ia-<id>/<role>/<slug>-YYYYMMDD-HHMM`.
  - Mantido o formato legado `ia-<id>/<role>/task-YYYYMMDD-HHMM` quando
    `--topic` não é fornecido.
  - Novo modo `--rename-topic "<descrição>"` para renomear a branch de
    trabalho atual quando o escopo muda de fase/tópico.
  - A nota do slot (`.agent-guard/tasks/<slot>.md`) é criada/atualizada
    automaticamente com as linhas **Branch:** e **Tópico:** apontando para
    o trabalho corrente.
  - Reuse mode agora permite retomar um worktree quando o lease está no PID
    pai/ancestral do processo atual. Corrige o cenário em que o usuário faz
    `source .hmvip-agent-init --adopt` no shell e depois executa `kimi` no
    mesmo shell — antes o wrapper recusava com "WORKTREE ALREADY IN USE".
- `.kiro/shell/hmvip.sh`:
  - `_hmvip_resolve_init_script()` escolhe o stub `.hmvip-agent-init` mais
    atualizado disponível. Prioridade: repo principal quando está em
    `develop`/`main`; depois um worktree em `develop`/`main`; depois o worktree
    cujo `packages/agent-guard-core` tenha o commit mais recente. Isso evita que
    `hmvip go/ad` use um init desatualizado quando o repo principal está
    estacionado em uma task branch antiga (cenário comum no setup multi-IA).
- `src/init.sh`:
  - Nova função `_show_open_prs_for_identity()` que consulta PRs abertos do slot
    e exibe resumo (número, título, estado dos checks, merge state, URL) ao
    final de `init`, `--adopt` e reuse mode. A IA passa a ver imediatamente, ao
    retomar um slot, quais PRs precisam de atenção — checks falhos, conflito,
    bloqueado ou pronto para merge. A consulta é fail-open: se `gh` falhar ou
    não houver PRs, a inicialização continua normalmente.
- Wrappers Kimi/Amp (`wrappers/kimi/wrapper.sh`, `wrappers/amp/wrapper.sh`):
  - Requisição explícita de slot (`hmvip go <slot>` / `amp go <slot>`) em um
    worktree sujo agora entra no modo **adopt** automaticamente, em vez de
    recusar. Isso permite retomar slots que foram liberados com trabalho ativo
    (drift reportado por `--status`) sem precisar decorar
    `AG_ALLOW_DIRTY_WORKTREE=1`. A guarda de agente/lease vivo continua
    bloqueando takeovers indevidos.
- Testes:
  - `tests/agent-guard/agent-guard-stale-cleanup-test.sh`: adicionado Test 6
    que valida liberação automática de slot com PID morto e heartbeat recente.
  - `tests/agent-guard/agent-guard-topic-branch-test.sh` (novo): valida
    `--topic`, `--rename-topic` e atualização da nota do slot.

## 0.10.2 — Release Atomicity & Structural Drift Reporting

Fecha o gap onde slots podiam ser marcados como `free` enquanto o worktree
permanecia em uma task branch (liberação não-atômica), e adiciona visibilidade
externa para drifts estruturais detectados pelo `--status`.

- `src/release-helpers.sh`:
  - `_move_worktree_to_neutral_branch()` — novo helper que move o worktree para
    `_released/<identity>` e retorna sucesso/falha, sem limpar a sessão.
  - `_auto_release_if_safe()` agora move o worktree ANTES de `_clear_session()`;
    se o checkout falhar, a sessão permanece ativa e um evento
    `auto_release_blocked` com blocker `neutral_branch_failed` é registrado.
- `src/init.sh`:
  - `--release` move o worktree para `_released/<identity>` ANTES de limpar a
    sessão. Se o checkout falhar, o release aborta, a sessão continua ativa e um
    evento `release_failed` é gravado no journal.
  - `--status` registra eventos `slot_drift_detected` no journal quando encontra
    slots liberados com trabalho ativo, branch mismatch ou outro health não-live.
- `.github/workflows/agent-guard-drift-reporter.yml` (novo):
  - Reporter 2×/dia que varre o journal por `slot_drift_detected` e
    `release_failed`, abrindo/comentando issue `guardian` com os slots em drift.
- `.github/workflows/agent-guard-stale-blocked-reporter.yml`:
  - Agora também reage a eventos `release_failed`.
- `wrappers/amp/wrapper.sh`:
  - Watcher em background agora tenta auto-release seguro ao final da sessão Amp,
    registrando `session_end_blocked` quando o worktree está sujo ou há PRs abertos.
    Fecha o gap de `/exit`/`/quit` no Amp Code CLI.
- Testes:
  - `tests/agent-guard/agent-guard-release-atomicity-test.sh` (novo): valida
    que o worktree é movido antes da limpeza da sessão e que uma falha de
    checkout preserva a sessão.

## 0.10.1 — Blocked Release Visibility (auditoria de slots que não liberam)

Fecha gaps onde `/exit`/`/quit`, `--cleanup-stale` ou falta do `gh` deixavam
slots presos sem notificar o admin.

- `src/release-helpers.sh` (novo):
  - Helpers globais usados por release, stale cleanup, orphan rescue e pelo hook
    `SessionEnd` do Kimi, disponíveis mesmo com `AGENT_GUARD_FUNCTIONS_ONLY=1`.
  - `_note_slot_event()` — append estruturado em `.agent-guard/tasks/<slot>.md`.
  - `_blocked_event_notifications_enabled()` — lê a config
    `session.blocked_event_notifications`.
  - `_worktree_release_blockers()` — retorna a lista de bloqueios de liberação
    de forma silenciosa (reusa a lógica das guards existentes).
  - `_branch_is_current_agent_task()` e `_branch_is_neutral_released()` migrados
    para cá para ficarem acessíveis no `SessionEnd` hook.
  - `_auto_release_if_safe()` registra eventos `session_end_blocked` /
    `stale_cleanup_blocked` no journal e na nota do slot quando não consegue
    liberar, mantendo o comportamento silencioso no terminal para não bloquear
    o shutdown do Kimi.
  - `_release_pending_work_guard()` registra `pr_guard_skipped` no journal
    quando `gh` está indisponível ou a consulta falha, preservando o
    fail-open por disponibilidade.
- `src/init.sh`:
  - Sourcia `src/release-helpers.sh` no escopo global.
  - `--status` registra `shared_pid_detected` no journal quando um mesmo PID
    de IDE detém múltiplos slots.
- `agent-guard.yaml` + `agent-guard.yaml.example`:
  - Nova seção `session.blocked_event_notifications` com `enabled`, `journal`
    e `slot_note` (todos default `true`).
- `wrappers/kimi/hooks/agent-guard-session-end.sh`:
  - Passa evento `session_end_blocked` para `_auto_release_if_safe`.
- `.github/workflows/agent-guard-stale-blocked-reporter.yml` (novo):
  - Reporter diário que varre o journal e abre/comenta issue `guardian` com
    slots bloqueados nas últimas 24h.
- `.github/workflows/agent-guard-orphan-sweep.yml`:
  - Adicionado job manual `rescue` que executa `orphan-sweep --auto` via
    `workflow_dispatch` input `run_rescue`.
- Testes:
  - `tests/agent-guard/agent-guard-stale-cleanup-test.sh`: valida journal e
    nota do slot para `stale_cleanup_blocked`.
  - `tests/agent-guard/agent-guard-session-end-blocked-test.sh` (novo):
    valida `session_end_blocked` ao sair com worktree suja.
  - `tests/agent-guard/agent-guard-pr-guard-failopen-test.sh` (novo):
    valida `pr_guard_skipped` quando `gh` está ausente.

## 0.10.0 — Amp CLI Wrapper (Sourcegraph)

- **Novo wrapper**: `wrappers/amp/wrapper.sh` — isolamento automático para o
  Amp CLI (Sourcegraph). Diferente do wrapper Kimi, usa um diretório estável
  (`~/.local/hmvip/bin/amp`) que o auto-updater do Amp não sobrescreve.
- **Novo recovery**: `wrappers/amp/recovery.sh` — instala/restaura o wrapper
  idempotentemente, verifica PATH e existência do binário real.
- **Nova identidade**: `amp` em `agent-guard.yaml` com `worktree_prefix:
  hmvip-ia-amp`, slots iniciais 3, max 10, auto-expand.
- **Nova config**: `wrappers.amp.*` com `bin_dir`, `real_bin_path`,
  `default_role`, `identity_prefix`.
- `bin/agent-guard`: `amp` adicionado a `KNOWN_IDENTITIES`.
- `src/init.sh`: `_ensure_amp_wrapper()` executa recovery automático em toda
  inicialização, igual ao `_ensure_kimi_wrapper`.
- `install.sh`: `--install-amp-wrapper` instala o wrapper no diretório estável.
- `README.md`: seção completa do wrapper Amp com arquitetura, instalação,
  mitigação de updates, comparação com wrapper Kimi.
- `docs/amp-wrapper.md`: documentação detalhada (432 linhas) cobrindo
  arquitetura, instalação, uso, troubleshooting e cenários proativos.
- `agent-guard.yaml.example`: exemplo de configuração Amp incluído.

### Mitigação contra updates do Amp

O Amp CLI atualiza `~/.amp/bin/amp` (binário real) durante `amp update`.
O wrapper em `~/.local/hmvip/bin/amp` não é tocado, desde que
`~/.local/hmvip/bin` esteja antes no PATH. O `init.sh` detecta e restaura
o wrapper automaticamente se ele for removido.

## 0.9.12 — `hmvip continuar-tudo` (ranking A+B + grade kitty)

- `src/continue-all.sh`:
  - Ranking dupla camada de slots com trabalho em andamento.
  - Camada A: lease active + PID morto, PRs abertos de `ia-<slot>/*`, ou branch
    `ia-<slot>/*` não released.
  - Camada B: título da aba vem de `Próximo passo:` em
    `.agent-guard/tasks/<slot>.md`; fallback para `tab_title`; último fallback
    "trabalho pendente".
  - Ordenação: notas primeiro, depois PRs abertos, depois atividade recente.
  - Modo `--dry-run` imprime a fila sem abrir janelas.
  - Slots com sessão viva são pulados (nunca adopt forçado).
- `src/grid.sh`:
  - Novo modo `--slots <json>`: abre uma janela kitty por slot, mapeando cada
    um para um quadrante sequencial nos monitores extras.
  - Título inicial: `⚪ <slot> | <título>`; comando: `kimi --slot <slot>`.
- `bin/agent-guard`: subcomandos `continuar-tudo` e alias `ct`.
- `.kiro/shell/hmvip.sh`: atalhos `hmvip continuar-tudo` / `hmvip ct`.
- `tests/agent-guard/continue-all-test.sh`: fixture com 4 slots + notas,
  valida inclusão/exclusão, títulos da nota, ordenação, dry-run e skip de slot
  vivo.
- `tests/agent-guard/shell-isolation-test.sh`: caso para `continuar-tudo --dry-run`.

## 0.9.10 — SessionEnd hook restaura o wrapper Kimi (janela do cron zerada)

- `wrappers/kimi/hooks/agent-guard-session-end.sh`:
  - Ao encerrar a sessão num repo gerenciado, executa
    `wrappers/kimi/recovery.sh --repo-root <repo>` de forma best-effort
    (silenciosa, `|| true`), antes de qualquer lógica de lease/auto-release.
  - Motivo: o self-update do Kimi CLI sobrescreve `<bin_dir>/kimi` tipicamente
    ao sair da sessão, e o cron de recovery (`*/5`) deixava uma janela de até
    5 minutos em que um relançamento rodava o binário cru — sem slot, no repo
    principal (incidente 2026-08-05, update 0.33.0: sessão lançada ~47s após
    a sobrescrita rodou sem lease). Com o recovery no SessionEnd, a janela vai
    a zero para o próximo lançamento; o cron vira apenas backstop.
- `tests/agent-guard/kimi-session-end-recovery-test.sh`:
  - 4 casos: recovery invocado mesmo sem lease, skipped fora de repo
    gerenciado, hook sai 0 com recovery.sh ausente e com recovery.sh falhando.

## 0.9.11 — Shell-Pinned Lease Recovery

Caso real (2026-08-05): agente morre, mas a aba de terminal que fez `source`
do init sobrevive parada no worktree. O lease fica preso a um PID vivo que não
é processo de agente e o `adopt` recusava com "SLOT STILL IN USE" para sempre.

- `src/init.sh`:
  - Novo helper `_pid_tree_has_agent_process()` — detecta processo de agente
    (mesmo predicado comm/args de `_worktree_has_other_live_agent`) no PID e em
    todos os descendentes transitivos. O próprio `$$` do caller falha fechado
    por design (o pipeline de scan carrega os nomes de agente no argv).
  - Novo helper `_shell_pin_grace_seconds()` — config
    `session.shell_pin_grace_minutes` (padrão 15, mínimo 1).
  - Novo helper `_lease_is_shell_pinned()` — lease ativo cujo PID vivo não é
    árvore de agente + nenhum agente vivo no worktree + heartbeat mais velho
    que a grace period. Falha fechado em qualquer dúvida (heartbeat ausente,
    agente na árvore, agente no worktree).
  - `adopt`: lease shell-pinned é limpo automaticamente em vez de recusar com
    "SLOT STILL IN USE".
  - `_slot_is_free()` (init normal): slot shell-pinned é tratado como livre.
  - `_cleanup_stale_sessions()`: slots shell-pinned entram na varredura de
    auto-release seguro (worktree limpo + sem PRs abertos).
  - `--status`: novo health `pinned` com drift "lease held by stray non-agent
    PID" (antes aparecia como `live`, enganoso).
- `tests/agent-guard/agent-guard-shell-pinned-lease-test.sh`:
  - 9 cenários: detecção por args, descendente de agente, heartbeat fresco
    (fail closed), agente na árvore (fail closed), shared-PID (fail closed) e
    auto-release via cleanup-stale.


## 0.9.9 — Orphan Rescue Protocol (ADR-0037)

- `src/init.sh`:
  - Novo modo `--orphan-sweep` com subcomandos `--dry-run` (padrão) e `--auto`.
  - Helpers `_orphan_sweep()`, `_orphan_sweep_identity()`, `_rescue_orphan_slot()`,
    `_cleanup_rescued_slot()`, `_is_orphan_sweep_candidate()`, `_has_open_prs_for_identity()`.
  - Ao detectar um slot morto com worktree sujo, cria branch
    `ia-<identidade>/orphan-rescue/YYYYMMDD-HHMMSS`, committa o estado atual,
    faz push para `origin`, reseta o worktree para `_released/<identidade>` no
    `origin/develop` e libera a sessão.
  - Preserva trabalho não commitado sem poluir a branch neutra; adiciona entrada
    na nota do slot (`.agent-guard/tasks/<slot>.md`) e evento `orphan_rescued`
    no journal.
  - Só resgata slots em branches próprias (`ia-<id>/*` ou `_released/<id>`),
    com sessão morta, sem agente vivo no worktree e sem PRs abertos.
- `bin/agent-guard`:
  - Novo subcomando `orphan-sweep` (atalho `os`) mapeado para `--orphan-sweep`.
- `agent-guard.yaml`:
  - Nova seção `session.orphan_rescue` com `enabled: true`, `ttl_days: 7` e
    `workflow_auto: false`.
- `.kiro/scripts/agent-guard-cleanup.sh`:
  - Após `--cleanup-stale`, executa `--orphan-sweep --auto` como rede de segurança.
- `.github/workflows/agent-guard-orphan-sweep.yml`:
  - Workflow diário que lista branches `ia-*/orphan-rescue/*` no origin e abre/
    atualiza issue `guardian` quando encontram branches mais velhas que o TTL.
- `.github/scripts/agent-guard-orphan-check.sh` (gate `G-AGENT-GUARD-ORPHAN`):
  - Falha se houver branches de resgate no origin com mais de 48h.
- `tests/agent-guard/agent-init-test.sh`:
  - Novos cenários de smoke test para `--orphan-sweep`.

## 0.9.8 — Performance: abertura de slots abaixo de 5s, scan /proc único e rotação de journal

- `wrappers/kimi/wrapper.sh`:
  - `_ag_scan_proc_once()` faz uma única passagem por `/proc` e cacheia PIDs de
    agentes e PIDs cujo `cwd` está dentro de worktrees conhecidos.
  - `_ag_worktree_has_live_agent()` e `_ag_find_resumable_worktree()` reutilizam
    esse cache, eliminando múltiplos scans de `/proc` por invocação.
  - `_ag_find_resumable_worktree()` lê apenas as últimas 2000 linhas do journal
    via `tail`, em vez de carregar o arquivo JSONL inteiro (que já passava de 9 MB).
  - Log de lease agora usa caminho por slot (`/tmp/ag-wrapper-lease-<slot>.log`),
    evitando que abas paralelas sobrescrevam o mesmo arquivo.
  - Novo helper `_ag_find_agent_ancestor()` identifica a sessão IDE/agente raiz
    (topo da cadeia de processos) em vez de comparar com `$$`. Isso evita que o
    próprio wrapper/teste seja confundido com ocupante e impede que sessões
    distintas do mesmo IDE compartilhem um slot.
  - Watcher de session trace inicia com `cd /` para que um processo de fundo
    sobrevivente não segure o `cwd` do worktree e bloqueie reabertura do slot.
- `src/init.sh`:
  - Novo helper `_ag_build_proc_cache()` com a mesma lógica single-pass do wrapper,
    usado por `_worktree_has_other_live_agent()`.
  - `_worktree_has_other_live_agent()` usa `_ag_find_agent_ancestor()` para
    distinguir a própria sessão IDE de outras sessões no mesmo worktree,
    alinhando-se com a lógica do wrapper.
  - `git fetch origin` em todos os caminhos de inicialização agora usa `timeout 15s`,
    impedindo que uma rede lenta congele a abertura do slot.
  - Verificação de stale global lock via `lslocks` passa de a cada 5s para a cada
    10s, reduzindo overhead sem comprometer a recuperação.
- `src/journal.sh`:
  - Rotação automática no momento da escrita quando o journal ultrapassa 50 MiB;
    preserva os 10 MiB mais recentes e arquiva o restante compactado com `gzip`.
- `tests/agent-guard/*`:
  - Testes existentes de shell isolation, init, lease-owner, wrapper, proteção do
    repo principal, diff regression e PID collision continuam passando.
  - `agent-init-test.sh` e `kimi-wrapper-test.sh`: fake agents usam `setsid` em
    subshell transitória para serem re-parentizados ao init, simulando agentes de
    sessões IDE separadas no teste de bloqueio de worktree ocupado.

## 0.9.7 — Fix: --adopt recusa PID vivo sem exceção de "mesmo processo"

- `src/init.sh`:
  - A verificação de `--adopt` que recusa sessões vivas não compara mais o PID
    armazenado contra o PID da sessão atual (`_ag_session_pid`). A comparação
    anterior permitia que um único processo (mesmo shell/IDE) adotasse vários
    slots sucessivamente, violando o invariante de 1 slot por sessão e
    prendendo múltiplas identidades ao mesmo PID compartilhado.
  - Agora `--adopt` recusa **sempre** que o PID registrado estiver vivo;
    adotar é estritamente para sessões mortas. Reattach do próprio slot vivo
    deve usar init normal, reuse ou `--attach`.
- `tests/agent-guard/agent-init-test.sh`:
  - Novo teste de regressão: `--adopt` recusa slot cujo PID registrado está
    vivo, mesmo quando o processo de teste compartilharia o mesmo PID.

## 0.9.6 — Heartbeat, stale detection e auto-release seguro (ADR-0033)

- `agent-guard.yaml`:
  - Nova seção `session` com `stale_threshold_hours: 24` e `auto_release_stale: true`.
- `src/init.sh`:
  - `_save_session()` grava `last_activity` no lease JSON.
  - Novos helpers `_update_last_activity()`, `_load_last_activity()`,
    `_stale_threshold_seconds()`, `_is_session_stale()`.
  - `_status_reconcile_session()` reporta health `stale` quando o PID está vivo
    mas `last_activity` ultrapassou o threshold configurado.
  - `_detect_shared_pids()` e alerta no `--status` quando um mesmo PID de IDE
    detém múltiplos leases ativos.
  - `_slot_is_free()` trata sessões `stale` com worktree limpo como livres,
    permitindo reutilização de slots abandonados por abas ociosas do Kimi Code.
  - `_auto_release_if_safe()` e `_cleanup_stale_sessions()` implementam liberação
    condicional: só liberam se worktree estiver limpo, sem stashes e sem PRs
    abertos da identidade.
  - Novo modo `--cleanup-stale` (também via `source agent-guard cleanup-stale`).
- Hooks do Kimi Code:
  - `~/.kimi-code/hooks/agent-guard-heartbeat.sh` atualiza `last_activity` a cada
    `UserPromptSubmit`.
  - `~/.kimi-code/hooks/agent-guard-session-end.sh` tenta liberar o slot no
    `SessionEnd` quando seguro.
  - `~/.kimi-code/config.toml` ganha entradas `[[hooks]]` para os dois eventos.
- Watcher local:
  - `.kiro/scripts/agent-guard-cleanup.sh` para execução periódica via cron.
- `tests/agent-guard/agent-guard-stale-cleanup-test.sh` (novo):
  - Valida stale detection, heartbeat, auto-release de slot limpo, recusa de
    release de slot sujo e dispatch do comando `cleanup-stale`.
- `wrappers/kimi/wrapper.sh`:
  - Watcher de sessão Kimi em background agora desacopla stdin/stdout/stderr
    (`</dev/null >/dev/null 2>&1`) antes do `disown`, evitando que o watcher
    segure pipes do processo pai em command substitution (`$(...)`). Corrige
    travamento do `kimi-wrapper-test.sh` e de scripts que invocam `kimi` via
    subshell.

## 0.9.5 — Adoção segura de slots órfãos, shell isolation e guarda de PRs preservada (ADR-0023)

> Sync upstream: enviado para `agent-guard-AI/agent-guard-core@main` em 2026-07-25 (commit `106e748443`).

- `src/init.sh`:
  - Novo helper `_branch_belongs_to_identity_or_base()` que identifica se a branch
    atual do worktree pertence ao dono do slot ou é uma branch base segura.
  - `_slot_is_free()` agora recusa worktrees em branch estrangeira, impedindo que
    o fluxo normal de aquisição orfane branches de outras IAs.
  - `_create_or_reuse_worktree()` ganha segunda trava: se a branch atual for
    estrangeira, falha com instrução para usar `--adopt`.
  - `--adopt` permite assumir slots órfãos com branch estrangeira quando a sessão
    dona está confirmada morta e não há outro processo de agente vivo no worktree.
  - Adoção de órfão estrangeiro exibe aviso explícito, preserva arquivos/stashes e
    grava checkpoint no journal identificando a branch estrangeira.
  - `_status_reconcile_session()` reporta estado `orphan`/`foreign branch` quando o
    worktree está em branch de outra identidade.
  - Shell isolation: strict mode (`set -euo pipefail`) não vaza mais para o shell
    chamador; flags originais são salvas antes de ativar o strict mode e
    restauradas antes do `return`.
  - Guarda de PRs pendentes preservada no redesign: `--release` continua
    bloqueando quando há PRs abertos de `ia-<identidade>/*`, listando-os e
    instruindo `--release --force` em não-TTY; `--release --force` libera com
    aviso de autorização explícita.
- `.hmvip-agent-init` e `bin/agent-guard`:
  - Aplicado o mesmo padrão de shell isolation, com nomes de variáveis distintos
    para evitar colisão entre os três níveis de source.
  - `bin/agent-guard`: subcomando `release|r)` repassa `"$@"` para que `--force`
    chegue até `src/init.sh`.
- `tests/agent-guard/agent-init-test.sh`:
  - Testes de branch estrangeira recusada na aquisição normal, adoção de órfão
    estrangeiro, recusa com processo agente vivo e detecção no `--status`.
- `tests/agent-guard/shell-isolation-test.sh` (novo):
  - Valida que falhas no `.hmvip-agent-init`, no `agent-guard` e fontes bem-sucedidas
    não ativam `set -e` no shell do usuário.

## 0.9.4 — Fix: dispatcher do `bin/agent-guard` encaminha `"$@"` no subcomando `release`

- **Bug (introduzido em 0.9.3):** o caso `release|r)` do dispatcher chamava
  `_ag_source_init --release` **sem repassar `"$@"`**, descartando o
  `--force`. O caminho documentado `source .hmvip-agent-init --release --force`
  (impresso pela própria guarda de PRs abertos em `src/init.sh`) nunca levava
  o flag ao `init.sh`: em não-TTY (IA) a guarda bloqueava, instruía
  `--release --force` e bloqueava de novo — loop sem saída. Em TTY o bug era
  invisível, pois a guarda pergunta `[y/N]` interativamente e não precisa do
  flag. Todos os outros subcomandos com argumentos (`switch`, `attach`,
  `adopt`, `triage`) já repassavam `"$@"`; só `release` (e `status`, que não
  tem argumentos) não. Workaround vigente: sourcar
  `packages/agent-guard-core/src/init.sh --release --force` direto.
- `bin/agent-guard`: `release|r)` agora chama `_ag_source_init --release "$@"`
  (1 linha). Sem mudança de comportamento para `release` sem argumentos.
- Testes (monorepo HMVIP, `tests/agent-guard/agent-guard-release-pending-prs-test.sh`):
  novo **cenário D** — cadeia real stub → `bin/agent-guard` → `init.sh`. O
  stub fake do teste original sourceava o `init.sh` DIRETO, mascarando bugs
  de dispatcher; o cenário D copia o stub raiz real e o bin real para o
  sandbox e roda `--release --force` ponta a ponta. Controle negativo
  verificado: sem o fix, exatamente as 2 asserções do cenário D falham
  (guarda bloqueia apesar do `--force`).

## 0.9.3 — Release nunca é automático: guarda de PRs abertos + `--force`

- **Mudança de protocolo (pedido do dono, 2026-07-17):** finalizar uma
  tarefa/spec/lição/alteração/refatoração/correção/implementação **não libera
  o slot**. A IA deve encerrar o trabalho com segurança, informar o estado
  (PRs, fila, CI) e **perguntar ao usuário** se ele deseja liberar — 99% das
  sessões ainda têm PRs em andamento e o slot estava sendo liberado
  antecipadamente.
- `src/init.sh`:
  - Nova guarda `_release_pending_work_guard` no fluxo `--release`: consulta
    PRs abertos da identidade (`gh pr list` filtrando `ia-<identidade>/*` por
    prefixo via `startswith`) e:
    - **sem PRs abertos:** release segue normalmente;
    - **com PRs abertos + TTY (humano):** pergunta explícita `[y/N]` antes de
      liberar;
    - **com PRs abertos + não-TTY (IA):** release **bloqueado**, com a lista
      dos PRs e a instrução de apresentá-los ao usuário — só prossegue com
      `--release --force`, que exige autorização prévia do usuário;
    - **gh ausente ou erro de rede:** fail-open com aviso (a guarda é contra
      esquecimento, não trava de disponibilidade).
  - Novo flag global `--force` (parser de argumentos + variável
    `FORCE_RELEASE`).
- Testes (monorepo HMVIP, `tests/agent-guard/agent-guard-release-pending-prs-test.sh`):
  8 casos — bloqueio com PRs abertos, listagem dos PRs, instrução de
  `--force`, sessão e branch preservadas no bloqueio, release com `--force`,
  e release sem PRs sem `--force` (gh fakeado via PATH).
- Documentação: ritual de encerramento do `AGENTS.md` e skills
  `hmvip-multi-agent` / `hmvip-agent-guard` atualizados para o fluxo
  "perguntar antes de liberar".

## 0.9.2 — Retenção de backups `kimi.real.*` no recovery do wrapper Kimi

- `wrappers/kimi/recovery.sh`:
  - Nova função `_ag_prune_real_backups`: mantém apenas os N backups
    timestamped mais novos (`kimi.real.*`), descartando os demais por mtime.
    N configurável via `AG_KIMI_BACKUP_KEEP` (padrão 3; valor inválido cai
    para 3 sem quebrar o script). O `kimi.real` canônico (sem sufixo) nunca
    é tocado.
  - A poda roda em **toda** invocação — inclusive nas execuções no-op
    ("já é o wrapper") — e novamente logo após a criação de um novo backup,
    garantindo o invariante "no máximo N backups ao fim de qualquer run".
  - Incidente que motivou: em 20 dias, 595 backups `kimi.real.<timestamp>`
    (~150 MB cada, ~88 GB no total) se acumularam em `~/.kimi-code/bin/`
    porque o recovery fazia backup a cada restauração e nunca apagava —
    em um único dia de briga entre o auto-updater do Kimi CLI e o guard,
    280 backups (~40 GB) foram criados.
- Testes (monorepo HMVIP, `tests/agent-guard/kimi-recovery-retention-test.sh`):
  9 casos cobrindo poda em run de recovery, poda em run no-op, preservação
  do `kimi.real`, ordem por mtime, `AG_KIMI_BACKUP_KEEP` customizado e
  inválido.

## 0.9.1 — Wrapper nunca herda lease de sessão pai

- `wrappers/kimi/wrapper.sh`:
  - **Correção de isolamento:** o wrapper agora faz `unset` de
    `_AG_WORKTREE/_AG_IDENTITY/_AG_BRANCH`, `_HMVIP_*`, `AG_WORKTREE_PATH`,
    `AG_BRANCH` e `AGENT_GUARD_WORKTREE_PATH/IDENTITY/BRANCH` logo no início.
    Antes, uma invocação aninhada de `kimi` de dentro de uma sessão de agente
    existente herdava essas variáveis e o `_ag_have_lease` fazia
    short-circuit da aquisição de lease com a identidade/worktree/branch da
    sessão pai — o agente filho rodava preso ao lease errado (ou morria no
    cleanliness/foreign guard com dados do pai). Mesma classe de problema do
    `unset AGENT_GUARD_SESSION_PID` já existente.
- Testes (monorepo HMVIP, `tests/agent-guard/kimi-wrapper-test.sh`):
  novo caso cobre a invocação aninhada com lease herdado da sessão pai
  (16 casos no total).
- Upstream `agent-guard-AI/agent-guard-core`:
  - `tests/agent-guard/kimi-wrapper-fallback-test.sh` corrigido: layout
    canônico `packages/agent-guard-core`, stub de init cria worktree com
    branch própria (`develop` já estava checked out por outro worktree e o
    `git worktree add` falhava em silêncio), arg não-management (`chat`)
    para exercitar o fallback de verdade — management short-circuita antes
    do fluxo de lease.
  - `tests/agent-guard/agent-guard-release-reuse-test.sh` atualizado para a
    versão do monorepo (atomic-lock refactor) com paths adaptados ao layout
    do upstream.

## 0.9.0 — Lançamento direto em slot específico (`kimi --slot`)

- `wrappers/kimi/wrapper.sh`:
  - Novo flag `--slot <identidade>` e variável de ambiente `AGENT_GUARD_SLOT`:
    inicia o agente diretamente no slot pedido, em um único comando e de
    qualquer diretório do ecossistema — sem rodar `adopt`/`init` manualmente
    antes (gap relatado em recuperação pós-crash: o `adopt` preparava o slot,
    mas o usuário ainda precisava lançar o agente em um segundo comando).
  - O wrapper decide automaticamente entre três fluxos:
    1. **Recusa** slots com processo de agente vivo ou PID de lease vivo —
       nunca faz takeover de sessão ativa.
    2. **Adopt** quando a sessão está morta (PID stale) e a worktree tem
       trabalho não commitado: delega ao fluxo `--adopt` do init, que preserva
       e exibe o trabalho da sessão morta, e exporta
       `AG_ALLOW_DIRTY_WORKTREE=1` com escopo local para que o cleanliness
       guard não bloqueie o lançamento recém-adotado.
    3. **Acquire** para slots livres (ou stale com worktree limpa, que o
       próprio init limpa): delega ao fluxo `--slot` do init.
  - O flag é consumido pelo wrapper e nunca repassado ao binário real. Se o
    CLI um dia introduzir seu próprio `--slot`, use `AGENT_GUARD_SLOT`.
  - Cada wrapper só aceita slots da própria família de identidade (o wrapper
    Kimi aceita `kimiN`, nunca `claudeN`); configurável via
    `wrappers.kimi.identity_prefix` no `agent-guard.yaml`.
- `README.md`: nova subseção "Seleção explícita de slot (`--slot` /
  `AGENT_GUARD_SLOT`)" na documentação do wrapper Kimi.
- Testes (monorepo HMVIP, `tests/agent-guard/kimi-wrapper-test.sh`):
  cobertura dos fluxos acquire/adopt/refuse, formato inválido, família de
  identidade estrangeira e a variável `AGENT_GUARD_SLOT` (15 casos no total).

## 0.8.8 — Isolamento de shell e correção do crash em `hmvip adopt`

- `.hmvip-agent-init`, `bin/agent-guard`, `src/init.sh`:
  - Corrigido o vazamento de `set -euo pipefail` para o shell interativo do
    usuário quando comandos como `hmvip adopt` falhavam, o que terminava o
    terminal com código 1.
  - Scripts `source`ados agora salvam as flags do shell chamador, envolvem a
    lógica em funções internas e restauram as flags originais **antes** de
    retornar um código de erro, evitando que `errexit` dispare no shell do
    usuário.
  - `src/init.sh`: corpo principal movido para `_agent_guard_init_body()`;
    falhas são capturadas com `|| _rc=$?` e o retorno é feito com as flags
    restauradas.
- `src/init.sh`:
  - `--adopt` agora aceita worktrees em *detached HEAD* desde que o commit
    atual pertença à branch própria do slot (`ia-<identidade>/...`).
- `.kiro/shell/hmvip.sh`:
  - Helper `hmvip()` protege o diretório de trabalho com `_hmvip_old_pwd` e
    restaura-o em caso de falha do `source`, evitando que o usuário fique
    preso em um diretório inesperado após um adopt malsucedido.
  - Novo helper `_hmvip_safe_source()` centraliza todo `source` do stub do
    agent-guard: salva e restaura o diretório de trabalho, garantindo que
    nenhum comando (`status`, `triage`, `menu`, etc.) deixe o terminal em um
    diretório errado.
  - Validação inicial de `python3` e existência do stub impede mensagens
    confusas em ambientes quebrados.
- `.kiro/scripts/diff-regression-guard.sh`:
  - Corrigido o `Broken pipe` causado por `echo "$VAR" | grep -q` sob
    `set -euo pipefail`. As buscas foram reescritas com here-strings
    (`grep -q ... <<< "$VAR"`), eliminando SIGPIPE quando a correspondência
    é encontrada.
- `.kiro/locks/regression-guard-allowlist.json`:
  - Adicionada entrada para `packages/agent-guard-core/bin/agent-guard` (type
    `large-content-removed-from-recent-file`), documentando que as ~178 linhas
    removidas são a mesma lógica funcional reestruturada, não uma reversão.
- `tests/agent-guard/`:
  - Novo `shell-isolation-test.sh` valida que `source .hmvip-agent-init` não
    deixa `set -e` ativo no shell chamador.
  - Novo `diff-regression-guard-test.sh` valida que o guard detecta
    regressões, respeita a allowlist e não emite `Broken pipe`.
  - `agent-init-test.sh` ganhou casos de regressão para `--adopt` (PID morto,
    PID vivo, branch estrangeira e detached HEAD).

## 0.8.7 — Fix do wrapper Kimi: `local` em subshells

- `wrappers/kimi/wrapper.sh`:
  - Remove `local` de variáveis declaradas em subshells de nível superior
    (`heartbeat_interval`, `last_heartbeat`, `now`, `watch_interval`).
  - `local` fora de funções causava `local: can only be used in a function`
    e abortava o wrapper ao disparar heartbeat/watcher.
- **Sync upstream:** correção incluída no PR upstream #10
  (`agent-guard-AI/agent-guard-core`).

## 0.8.6 — Rastros contínuos de sessão para Kimi (ADR-0022)

- `src/session_trace.sh`:
  - Novas funções `_trace_find_kimi_session_dir`, `_trace_snapshot_kimi_state`, `_trace_watch_kimi_session`, `_trace_grep_sessions` e `_trace_search_kimi_sessions`.
  - Captura best-effort do `state.json` do Kimi Code (título, último prompt, workDir, sessionId) a cada batimento, com redação de secrets.
  - Busca unificada por termo tanto nos checkpoints da ref `refs/agent-guard/sessions/v1` quanto no estado Kimi local.
- `wrappers/kimi/wrapper.sh`:
  - Inicia um watcher em background após a aquisição do lease; ele tira snapshots do estado da sessão Kimi e grava checkpoints automáticos enquanto o processo da IA estiver vivo.
  - Configurável via `AGENT_GUARD_KIMI_WATCH_INTERVAL_SECONDS` (padrão 60) e `AGENT_GUARD_KIMI_WATCH_CHECKPOINT_INTERVAL_SECONDS` (padrão 300).
- `bin/agent-guard`:
  - Novo subcomando `session grep <termo>` para descobrir em qual slot/branch um termo (ex: `mobilerun`) apareceu nos rastros de sessão ou no estado Kimi.
- `packages/agent-guard-core/hooks/post-commit`:
  - Grava um checkpoint de session-trace a cada commit, ligando o estado da conversa ao código commitado.
- `tests/agent-guard/session_trace-test.sh`:
  - Testes de descoberta de sessão Kimi, snapshot redacted, `grep_sessions` e `search_kimi_sessions`.
- **Sync upstream:** melhorias sincronizadas com `agent-guard-AI/agent-guard-core` via PR #10.

## 0.8.5 — Correção do dispatch do subcomando `prune`

- `bin/agent-guard`:
  - O caso `prune` agora carrega `src/init.sh` no modo
    `AGENT_GUARD_FUNCTIONS_ONLY` antes de invocar `_prune_identity`.
  - Args do prune não são mais repassados para o parser do `init.sh`,
    evitando erros como `Unknown option: --dry-run`.
- `src/init.sh`:
  - Guarda `AGENT_GUARD_FUNCTIONS_ONLY` para skippar o fluxo de aquisição/reuso
    quando o script for carregado apenas pelos helpers.
- `tests/agent-guard/prune-test.sh`:
  - Adicionado teste de regressão para o dispatch CLI de `prune`.

## 0.8.4 — Menu interativo de seleção de slots (`hmvip slots` / `hmvip selecionar`)

- `.kiro/shell/hmvip.sh`:
  - Nova função `_hmvip_menu_slots()` lista todos os slots configurados em
    `agent-guard.yaml` com status (`free`/`active`), saúde do PID (`live`/`dead`),
    existência do worktree e branch atual.
  - Novos comandos `hmvip slots` e `hmvip selecionar` abrem o menu de slots.
  - O menu principal (`hmvip m`) ganha a opção `2. selecionar` para abrir o
    menu de slots.
  - Ações disponíveis por slot:
    - **Livre:** usar, adotar ou retomar (mostrar nota de tarefa).
    - **Ativo:** retomar (nota) ou liberar.
- `AGENTS.md`: documenta `hmvip slots` / `hmvip selecionar` na tabela de atalhos.

## 0.8.3 — Alocação explícita de slot (`--slot` / `hmvip use`)

- `src/init.sh`:
  - `_acquire_slot()` ganha quarto parâmetro `forced_identity`. Quando
    informado, só o slot solicitado é considerado (com e sem cooldown).
    Validação rejeita identidades fora do prefixo ou fora de `max_slots`.
  - Parse de argumentos aceita `--slot <identidade>`, permitindo
    `source .hmvip-agent-init kimi ia-a --slot kimi3`.
- `.kiro/shell/hmvip.sh`:
  - Novo comando `hmvip use <identidade>` (e sinônimo `hmvip usar`).
  - `HMVIP_AGENT_INIT` agora é resolvido dinamicamente: se o shell estiver
    dentro de um worktree `hmvip-ia-*`, usa o stub daquele worktree;
    caso contrário, usa o stub do repo principal.
- `AGENTS.md` e `.agents/skills/hmvip-multi-agent/SKILL.md` atualizados com
  o novo comando e gatilhos de linguagem natural.
- Sync upstream: melhorias enviadas para `agent-guard-AI/agent-guard-core`
  via PR #9 (`sync-main-for-upstream-20260715`).

## 0.8.2 — Resiliência a crashes e reinicializações (L207)

- `src/init.sh`:
  - `_is_pid_alive()` agora rejeita processos em estados `T` (traced/stopped),
    `Z` (zombie) e `X/x` (dead). Sessões cujo PID existe mas não está saudável
    são reportadas como `dead` no status, não `live`.
  - Nova função `_status_reconcile_session()` reconcilia session file com o
    estado real do worktree: verifica `worktree_path`, `branch` e dirty state.
    Divergências são reportadas como `drift` no `--status`.
  - `--status` agora lista todos os slots até `max_slots` (incluindo slots
    expandidos como `kimi8+`), mostra uma coluna `Health` e imprime um bloco de
    aviso com ações sugeridas (`--adopt`).
  - Nova função `_ensure_task_note()` cria `.agent-guard/tasks/<slot>.md`
    automaticamente ao alocar um slot expandido, garantindo governança de
    retomada igual à dos slots base.
  - Chamadas automáticas de `_journal_checkpoint()` em `init` e `adopt`,
    gravando HEAD, arquivos modificados e stashes no journal para recuperação
    pós-crash.
- `src/journal.sh`:
  - `_journal_checkpoint()` expandido para capturar `branch`, `head`, lista de
    arquivos dirty e lista de stashes.
- `tests/agent-guard/agent-init-test.sh`:
  - Teste 18: processo parado (`SIGSTOP`) é detectado como `dead`.
  - Teste 19: slots expandidos aparecem no status e drift é detectado quando o
    session file diz `_released` mas o worktree está em task branch suja.
  - Teste 20: checkpoint no journal captura arquivos modificados.

## 0.8.1 — Impede reassumir slot imediatamente após release

- `src/init.sh`:
  - `_clear_session()` agora grava `released_at` (timestamp) no session file.
  - `_slot_is_free()` ganha verificação de cooldown: slots liberados nos
    últimos 60s são tratados como ocupados na primeira passagem do acquire;
    uma segunda passagem os reconsidera caso sejam a única opção.
  - `_acquire_slot()` executa dupla passagem: primeiro sem cooldown, depois
    com cooldown ignorado.
  - Reuse mode (seção 12) não mais reativa automaticamente um worktree que
    está na branch neutra `_released/<identidade>`. Ao invés disso, o fluxo
    cai para `_acquire_slot()`, que respeita o cooldown e aloca o próximo
    slot livre. Isso evita que a IA "volte a assumir a mesma identidade"
    quando o usuário pede para continuar logo após liberar.
- `tests/agent-guard/agent-guard-release-reuse-test.sh` (novo, no repo
  hospedeiro): 4 casos — `released_at` gravado, cooldown pula slot recente,
  fallback seleciona slot recente quando é o único livre, e worktree
  `_released/<identidade>` não é reusado.

## 0.8.0 — Posse de worktree por lease: hooks bloqueiam processos fora da sessão dona (L186)

- `hooks/lease-owner-check.sh` (novo): validação de posse ancorada no session
  file (`<repo-principal>/.kiro/locks/agent-sessions/<identidade>.json`). Se
  existe lease `active` com PID vivo cujo `worktree_path` é o worktree atual,
  somente processos descendentes desse PID podem escrever (caminhada de
  PPID). Lease morto, ausente ou de outro worktree → permitido (recovery/adopt).
  Bypass manual documentado: `HMVIP_AGENT_GUARD_BYPASS=1`. Override de teste:
  `AGENT_GUARD_SESSION_DIR`.
- `hooks/pre-commit` e `hooks/pre-push`: chamam `lease_owner_check <identidade>`
  após a validação de identidade/prefixo — o gap era que qualquer processo
  dentro de um worktree configurado (user.email repo-wide) podia criar branch
  `ia-*` e commitar/pushar sem lease, mesmo com a sessão dona viva (L186:
  ator sem init criou branch, commitou e mergeou PR no worktree do kimi1).
- `hooks/pre-checkout`: chama `lease_owner_check ""` (modo qualquer-identidade)
  antes de trocar/criar branch — o `checkout -b` com working tree limpa era o
  ponto de entrada do invasor.
- `tests/agent-guard/lease-owner-check-test.sh` (novo, no repo hospedeiro):
  10 casos — ausente/ancestral/não-ancestral/morto/outro-worktree/inativo/
  sem-file/modo-checkout/bypass. Roda no job `agent-guard-validation` do CI.

## 0.7.2 — Lease ancorado no processo da sessão (fim da corrida de slots via CLI)

- `src/init.sh`:
  - Novo helper `_ag_session_pid()` que resolve o PID gravado no lease:
    1. `AGENT_GUARD_SESSION_PID` (pin explícito de wrappers), se vivo;
    2. `$$` quando o shell é interativo (terminal humano);
    3. `$PPID` quando não-interativo (subshell `bash -c` de CLIs de agente,
       ex.: ferramenta Bash do Kimi Code) — o `$$` efêmero morria ao fim do
       comando e o slot alugado parecia livre/stale, permitindo que outra
       sessão roubasse o slot (corrida de slots);
    4. fallback `$$`.
  - PID 1 nunca é aceito como âncora (processo reparented não representa a
    sessão).
  - `_save_session` e as comparações de "lease já pertence a mim" nos fluxos
    de acquire/attach/adopt passam a usar `_ag_session_pid`.
- `wrappers/kimi/wrapper.sh`:
  - Exporta `AGENT_GUARD_SESSION_PID=$$` antes de sourcar o init: o wrapper é
    não-interativo, mas seu PID sobrevive ao `exec` final para `kimi.real`,
    preservando o comportamento canônico (lease preso ao processo do agente).

## 0.7.1 — Release idempotente em branch neutra `_released/<identidade>`

- `src/init.sh`:
  - Novo helper `_branch_is_neutral_released()` e extensão de
    `_validate_worktree_release_ready()` para aceitar a branch neutra
    `_released/<identidade>` além de `develop` e `ia-<identidade>/...`.
  - Corrige falso erro "WORKTREE NOT RELEASABLE" ao rodar `--release` num
    worktree já liberado: o próprio release estaciona o worktree em
    `_released/<identidade>` (não pode usar `develop`, que fica presa ao repo
    principal), e um segundo release — ou um release após crash no meio do
    fluxo — reprovava na validação de branch. Release agora é idempotente.
  - Mensagem de erro atualizada para listar `_released/<identidade>` como
    estado aceito.

## 0.7.0 — Modo adopt: assumir slots sujos de sessões mortas

- `src/init.sh`:
  - Novo modo `--adopt <identidade>` (ex: `--adopt kimi3`) para assumir
    explicitamente um slot deixado sujo/ocioso por uma sessão anterior cujo
    processo já morreu — o caso típico de "novo dia, continuar o trabalho de
    ontem". O fluxo normal de aquisição (`_slot_is_free`) continua pulando
    worktrees sujas por segurança; o adopt é a escotilha explícita.
  - Trilhos de segurança do adopt:
    - Recusa quando o slot está preso por um PID vivo.
    - Recusa quando o worktree está em branch de outra identidade ou em
      branch protegida — só permite `ia-<identidade>/...` ou
      `_released/<identidade>`.
    - Nunca limpa a worktree: arquivos sujos e stashes são apenas reportados
      para inspeção do agente.
  - Sessões stale (PID morto) são limpas automaticamente antes da adoção.
- `bin/agent-guard`: novo subcomando `adopt` (atalho `ad`).
- `src/journal.sh`: novo evento `adopt` (`_journal_adopt`) no journal de sessão.
- `.kiro/shell/hmvip.sh` (repo HMVIP): novo atalho `hmvip ad <identidade>`.

## 0.6.0 — Expansão dinâmica de slots

- `agent-guard.yaml`:
  - Adicionadas chaves `identities.<name>.max_slots` e `identities.<name>.auto_expand`.
  - Quando `auto_expand: true`, novos slots/worktrees são criados automaticamente
    até `max_slots` quando todos os slots iniciais (`slots`) estão ocupados.
  - Nova chave `wrappers.kimi.default_role` (padrão `ia-a`) usada pelo wrapper
    ao alocar um novo slot dinamicamente.
- `src/init.sh`:
  - `_acquire_slot` respeita `max_slots` e `auto_expand`.
  - Slots expandidos são reutilizados se já existirem e estiverem limpos;
    caso contrário, novos worktrees são criados automaticamente.
  - Sessões stale (PID morto) continuam sendo limpas antes da alocação.
- `wrappers/kimi/wrapper.sh`:
  - `_ag_find_free_kimi_worktree` busca worktrees livres até `max_slots`.
  - Quando nenhum worktree existente está livre, o wrapper delega ao init script
    com papel padrão, permitindo que o agent-guard expanda slots em vez de falhar
    com "no free kimi worktree available".
- `agent-guard.yaml.example` atualizado com as novas chaves.

## 0.5.3 — Compatibilidade Windows/Git Bash e instalação robusta

- `install.sh`:
  - Remove referência ao diretório `shell` inexistente.
  - Detecta Python válido cross-platform via `bin/agent-guard-python` (ignora placeholder `WindowsApps`).
  - Detecta quando o binário Kimi está em uso e instrui a rodar `recovery.sh` após reiniciar, em vez de falhar.
  - Adiciona `.agent-guard/` e `.githooks/` ao `.gitignore` do repo consumidor.
  - Cria `.gitattributes` com regras LF para scripts, PHP, YAML/JSON.
- Novo `bin/agent-guard-python`:
  - Resolve interpretador Python válido considerando `${HOME}/.kimi/python*/python`, `python`, `py` e `python3`.
  - Respeita override `AGENT_GUARD_PYTHON`.
- `src/init.sh`, `src/journal.sh`, `wrappers/kimi/wrapper.sh`, `bin/agent-guard-config`, `templates/init_stub.sh`, `src/Config.php`:
  - Substitui hardcodes de `python3` por resolução via `bin/agent-guard-python` (shell) ou `resolvePython()` (PHP).
- `src/init.sh` e `src/journal.sh`:
  - Implementam fallback de lock atômico via `mkdir` quando `flock(1)` não está disponível (Git Bash/Windows).
- `templates/init_stub.sh`:
  - Suporta `{{PACKAGE_ROOT}}` substituído pelo `install.sh`.
- Novos testes funcionais:
  - `tests/agent-guard/agent-guard-python-test.sh`
  - `tests/agent-guard/install-test.sh`

## 0.5.2 — Release a partir de task branch sem forçar develop

- `src/init.sh`:
  - `_validate_worktree_release_ready` agora aceita release do worktree quando ele está na própria branch de tarefa do agente (`ia-<identity>/...`), além de `develop`.
  - Remove a heurística `merge-base --is-ancestor HEAD develop`, que falhava após squash merges e impedia liberação do slot.
  - Após release, o worktree continua sendo movido para `_released/<identity>`, liberando `develop` para outros worktrees.
  - Mensagem de erro atualizada para refletir as novas regras.
- `tests/agent-guard/agent-init-test.sh`:
  - Adiciona cenário de release bloqueado em branch não-agente (`feature/other-task`).
  - Adiciona cenário de release permitido diretamente da task branch `ia-kimi1/...`.
  - Mantém validações de dirty/stash e release a partir de `develop`.

## 0.5.1 — Proteção contra operação no repositório principal

- `wrappers/kimi/wrapper.sh`:
  - Exige `agent-guard.yaml` para carregar configuração; sem ele, o wrapper não faz pass-through.
  - Detecta repositórios que parecem ser o main repo (presença de `packages/agent-guard-core` ou stubs de init) e falha com mensagem de recuperação em vez de executar no repo principal.
- `src/init.sh`:
  - Bloqueia `--release` quando executado a partir do repositório principal (`paths.main_repo`).
  - Mensagem de erro orienta o usuário a voltar para `develop` e atualizar o repo principal.
- Novo teste funcional: `tests/agent-guard/main-repo-protection-test.sh`.

## 0.5.0 — Fase 3: Pacote independente e instalável em qualquer repo Git

- Criação de `agent-guard.yaml` como SSOT moderno.
- `agent-guard.yaml.example` atualizado para o schema real usado por `Config.php` e `src/init.sh` (`paths.*`, `git.*`, `commit.*`, `wrappers.*`).
- `src/init.sh`:
  - Removeu regex hardcoded de prefixo de worktree; detecção de identidade a partir do nome do worktree agora usa `identities.*.worktree_prefix` da config.
  - Removeu hardcodes de caminhos absolutos de projeto.
  - Resolve base branch configurado (`git.base_branch`) com fallback para branch local quando `origin/<base>` não existe (suporta repos sem remote).
  - Renomeou variáveis/funções internas legadas para `_AG_S_*`.
  - Exporta variáveis canônicas `AGENT_GUARD_*`.
  - Mensagens de uso respeitam `AGENT_GUARD_INIT_NAME` (setado pelo stub).
- Stub de init exporta `AGENT_GUARD_INIT_NAME` para mensagens consistentes.
- `wrappers/kimi/wrapper.sh` e `wrappers/kimi/recovery.sh`:
  - Usam `paths.init_script` da config em vez de nome hardcoded.
  - `recovery.sh` removeu fallback de caminho absoluto; exige `--repo-root`, git repo ou `AG_REPO_ROOT`.
- `bin/agent-guard-status` reescrito para detectar repo root e ler config; funciona em qualquer projeto.
- `hooks/install.sh` suporta `--target <repo-root>` para instalação não-interativa.
- Novo `install.sh` genérico: instala o pacote, cria `agent-guard.yaml`, gera stub de init e instala hooks em qualquer repo Git.
- Novo `templates/init-stub.sh`: stub de init gerado pelo instalador para projetos open source.
- CI audit atualizado para validar `agent-guard.yaml` e usar `packages/agent-guard-core/ci/worktree-origin-audit.php`.
- Testado instalação limpa em repo novo com worktree, hooks e autor configurados corretamente.

## 0.4.0 — Session Journal

- Adiciona `src/journal.sh`: serviço de journal append-only em JSONL.
- Journal central configurável (compartilhado entre worktrees).
- CLI `bin/agent-guard` ganha comandos:
  - `journal` (`j`): lista trabalhos recentes por data/hora/segundo.
  - `resume` (`res`): retorna contexto do último ou n-ésimo trabalho.
  - `checkpoint` (`cp`): grava checkpoint manual com mensagem.
- Integração automática de eventos em `init`, `attach`, `release` e `post-commit`.
- Rotação por retenção configurável (padrão 90 dias).
- ADR-0014 documenta a decisão arquitetural.

## 0.3.2 — Microfase: Limpeza de duplicação e instalador de hooks

- Remove duplicação do wrapper Kimi na raiz do projeto consumidor.
- `src/init.sh`: remove fallback legado para recovery script fora do pacote.
- Cria `hooks/install.sh` para instalar hooks no repositório consumidor.
- Atualiza `README.md` para refletir componentes existentes e futuros.

## 0.3.1 — Microfase: Wrapper Kimi genérico

- `agent-guard.yaml`: adicionada seção `wrappers.kimi` com `bin_dir` e `real_bin` configuráveis.
- `wrappers/kimi/wrapper.sh`:
  - Totalmente genérico: lê `agent-guard.yaml` para resolver repo, base_dir, package_root, identidades e caminhos do binário Kimi.
  - Removeu hardcodes de caminhos absolutos e padrões de worktree.
  - Renomeou variáveis/funções internas de nomes legados para `_AG_*`.
- `wrappers/kimi/recovery.sh`:
  - Usa `paths.package_root` do YAML para localizar o wrapper do pacote.
  - Usa `wrappers.kimi.bin_dir` para instalar/restaurar o wrapper.
  - Removeu referências hardcoded a caminhos de projeto.
- `src/init.sh`: recovery agora usa `packages/agent-guard-core/wrappers/kimi/recovery.sh` (canônico).
- Novo teste funcional: `tests/agent-guard/kimi-wrapper-test.sh`.

## 0.3.0 — Fase 3a: Hooks genéricos sem hardcodes de projeto

- `agent-guard.yaml`:
  - Adicionadas chaves `git.base_branch`, `commit.identity_env_var` e `commit.generic_agent_email_template`.
  - Padronizado o uso de `worktree_prefix` (em vez de `worktree_pattern`) para manter consistência com os hooks e `src/init.sh`.
- `hooks/pre-commit`:
  - Totalmente parametrizado via `agent-guard.yaml`.
  - Removeu quality checks específicos de linguagem do projeto de origem (deverão viver em gates/hooks do projeto consumidor).
- `hooks/pre-push`:
  - Refatorado para usar `agent-guard-config` na identificação de identidades e na leitura de `git.base_branch`.
  - Removeu parser Python embarcado; agora usa shell puro com base nas configurações declarativas.
- `src/init.sh`:
  - Exporta a variável de ambiente configurada em `commit.identity_env_var` (fallback `AGENT_GUARD_IDENTITY`).
- `agent-guard.yaml.example` e `README.md` atualizados para refletir as novas chaves e o formato `worktree_prefix`.

## 0.2.0 — Fase 2: Configuração parametrizável via `agent-guard.yaml`

- Criação de `src/Config.php`: loader PHP para `agent-guard.yaml`.
- Criação de `bin/agent-guard-config`: helper shell para hooks e scripts lerem valores do YAML.
- Parametrização dos hooks:
  - `pre-commit`: valida domínio, identidades e branches a partir de `agent-guard.yaml`.
  - `pre-push`: valida push e identidade usando configurações do YAML.
  - `post-commit`: adiciona git notes parametrizado por `git.notes_ref`.
- Parametrização de `ci/worktree-origin-audit.php`: usa `Config.php` para ler identidades e regras.
- Parametrização de `src/init.sh`: lê `agent-guard.yaml` via `agent-guard-config`.
- Atualização do `README.md` com o novo estado e componentes.

## 0.1.0 — Fase 0: Mirror funcional

- Criação da estrutura de diretórios do pacote.
- Extração dos componentes principais do sistema de governança multi-IA original:
  - `src/init.sh`
  - `wrappers/kimi/wrapper.sh` e `recovery.sh`
  - `hooks/post-commit`, `pre-push`, `pre-commit`, `pre-checkout`, `commit-msg`
  - `ci/worktree-origin-audit.php`, `add-worktree-note.sh`, `branch-triage.sh`
  - `examples/agent-guard.json`
- CLI unificado `bin/agent-guard` com comandos: `init`, `status`, `release`, `attach`, `triage`.
- Testes funcionais básicos em `tests/run-all.sh`.
- Wrapper Kimi CLI corrigido e recovery funcionando.
