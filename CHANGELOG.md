# Changelog — agent-guard-core

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
