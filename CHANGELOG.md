# Changelog — agent-guard-core

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
