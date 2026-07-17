# agent-guard-core

Protocolo open source de governança multi-IA para repositórios Git.

Permite que múltiplos agentes de IA CLI colaborem no mesmo repositório sem colidir em branches, worktrees ou commits.

> ⚠️ **Compatibilidade de wrappers:** o protocolo e os hooks são genéricos e podem ser estendidos para várias identidades, mas o **wrapper CLI oficial e testado é o do Kimi (Moonshot AI)**. Hoje, apenas `wrappers/kimi/` está implementado. Outros agentes (Claude, Gemini, Grok etc.) podem usar o protocolo via init stub manual, mas não há wrapper automático para eles.

## Por que usar

Quando vários agentes de IA trabalham no mesmo repo, problemas comuns aparecem:

- Dois agentes no mesmo worktree sobrescrevendo o trabalho um do outro.
- Commits feitos no repo principal em vez de worktree isolado.
- Commits em branch de outra identidade.
- Pushes acidentais para `main`/`develop`.
- Impossibilidade de auditar de qual máquina/worktree um commit de IA veio.

`agent-guard-core` resolve isso com:

1. **Identidade e lease atômico**: cada sessão de IA aluga um slot/worktree exclusivo.
2. **Worktree isolation**: cada identidade trabalha em seu próprio worktree Git.
3. **Git hooks de identidade**: validam autor, branch, mensagem e worktree origin.
4. **CI audit via git notes**: todo commit de IA carrega metadados de origem auditáveis.
5. **Anti-regressão e triage**: protege contra reversões acidentais e acumulo de branches mortas.

## Componentes

```
agent-guard-core/
├── bin/
│   ├── agent-guard              # CLI principal
│   ├── agent-guard-config       # Leitor de agent-guard.yaml (SSOT)
│   └── agent-guard-status       # Atalho para status
├── src/
│   ├── init.sh                  # Aluguel de identidade e worktree
│   ├── journal.sh               # Session journal para recuperação de contexto
│   └── Config.php               # Loader PHP para agent-guard.yaml
├── hooks/
│   ├── install.sh               # Instala hooks no repo consumidor
│   ├── post-commit              # Adiciona git note de origem
│   ├── pre-push                 # Valida push e envia notes
│   ├── pre-commit               # Valida autor e branch
│   ├── pre-checkout             # Bloqueia checkout com working tree dirty
│   └── commit-msg               # Valida mensagem de commit
├── ci/
│   ├── worktree-origin-audit.php # Audita origem dos commits no CI
│   ├── add-worktree-note.sh     # Cria git note de origem
│   └── branch-triage.sh         # Limpeza de branches por identidade
├── wrappers/
│   └── kimi/
│       ├── wrapper.sh           # Wrapper do Kimi CLI
│       └── recovery.sh          # Restaura wrapper após updates
├── tests/
│   └── run-all.sh               # Testes funcionais básicos
└── examples/
    └── agent-guard.json         # Configuração de exemplo
```

> **Estado atual:** Fase 3 — pacote independente e instalável em qualquer repositório Git. Todos os componentes leem a configuração de `agent-guard.yaml` (SSOT) via `agent-guard-config`. Não há hardcodes de projeto no núcleo.

## Instalação rápida

1. Copie este diretório para o seu repositório (ex: `packages/agent-guard-core/`) ou execute:
   ```bash
   bash /path/to/agent-guard-core/install.sh --target /path/to/your/repo
   ```
2. Edite `agent-guard.yaml` na raiz do seu repo (criado a partir do exemplo).
3. Commit o pacote e a configuração.
4. Configure o wrapper da ferramenta de IA que você usa (ver `wrappers/kimi/`).
5. Para instalar apenas os hooks: `./packages/agent-guard-core/hooks/install.sh`.

## Configuração

Crie `agent-guard.yaml` na raiz do repositório:

```yaml
project:
  name: meu-projeto
  main_repo: /caminho/absoluto/do/repo
  domain: exemplo.dev

identities:
  - name: kimi
    slots: 4
    worktree_prefix: "myproject-ia-kimi"
    author_email: "agent-kimi{n}@example.dev"
    author_name: "Kimi{n} Agent"
  # Outras identidades podem ser declaradas para uso manual via init stub,
  # mas nenhum wrapper CLI está implementado para elas.
  - name: claude
    slots: 2
    worktree_prefix: "myproject-ia-claude"
    author_email: "agent-claude{n}@example.dev"
    author_name: "Claude{n} Agent"

git:
  protected_branches: [main, master, develop, staging]
  notes_ref: refs/notes/agent-guard-worktree
  hooks_path: .githooks
  base_branch: develop

commit:
  author_template: "agent-{identity}@{domain}"
  message_pattern: '^(feat|fix|docs|refactor|chore|test|ci|hotfix)(\(.+\))?: .+'
  require_conventional: true
  identity_env_var: AGENT_GUARD_IDENTITY
  generic_agent_email_template: agent@{domain}

wrappers:
  # Apenas o wrapper Kimi (Moonshot AI) está implementado.
  kimi:
    bin_dir: /home/user/.kimi-code/bin
    real_bin: kimi.real
```

## Uso

### Iniciar uma sessão

```bash
source agent-guard init <identidade> <papel>
# exemplo:
source agent-guard init kimi feature-x
```

O comando:
- Encontra um slot livre.
- Cria ou reusa o worktree correspondente.
- Cria ou reusa a branch `ia-kimi/<papel>/task-YYYYMMDD-HHMM`.
- Configura o autor Git.
- Instala os hooks no worktree.
- Escreve o lease atômico.

### Verificar status

```bash
source agent-guard status
```

### Liberar sessão

```bash
source agent-guard release
```

> **Nota de implementação:** o release deve validar que a worktree está em uma branch base neutra (ex: `develop` ou `main`), que não há arquivos pendentes e que não há stashes antes de liberar o lease. Isso evita que outro agente reutilize o mesmo slot herdando estado deixado pelo anterior.

> **Guarda de trabalho pendente (0.9.3):** finalizar uma tarefa **não** libera o slot automaticamente. Antes de liberar, o release consulta PRs abertos da identidade (`ia-<identidade>/*`) via `gh`:
>
> - **Sem PRs abertos:** o release segue normalmente.
> - **Com PRs abertos:** em terminal interativo (TTY), o release pergunta `[y/N]` antes de liberar; fora de TTY (agentes de IA), o release é **bloqueado** com a lista dos PRs. Para prosseguir é preciso `--force`, que só deve ser usado após autorização explícita do usuário:
>
>   ```bash
>   source agent-guard release --force   # só com autorização do usuário
>   ```
>
> - **Sem `gh` ou falha de rede:** a verificação é pulada com aviso (fail-open).

### Reentrar em sessão existente

```bash
source agent-guard attach <identidade>/<papel>/<branch>
```

### Assumir slot sujo/ocioso de sessão morta (novo dia)

```bash
source agent-guard adopt <identidade>
# Exemplo: source agent-guard adopt kimi3
```

Quando um novo dia começa e os slots ainda estão sujos com o trabalho de ontem, o fluxo normal de aquisição pula worktrees sujas (por segurança). O `adopt` é a escotilha explícita: assume o slot de uma sessão cujo processo já morreu, **sem apagar, commitar ou stashar nada** — o agente inspeciona o estado (`git status`, stashes) e decide como continuar.

Trilhos de segurança:

- Recusa slots presos por PID vivo.
- Recusa worktrees em branch de outra identidade ou branch protegida — só permite `ia-<identidade>/...` ou `_released/<identidade>`.
- Registra evento `adopt` no session journal.

### Trocar de sessão

```bash
source agent-guard switch <identidade>
# Exemplo: source agent-guard switch kimi4
```

Libera a sessão atual e aluga a identidade especificada em um único comando atômico. A identidade de destino deve estar livre; sessões ativas com PID vivo são recusadas. A worktree atual deve estar liberável (sem alterações pendentes e sem stashes).

## Session Journal — recuperação após crash

O `agent-guard-core` mantém um journal append-only em `.agent-guard/journal/agent-guard.jsonl` (caminho configurável) com eventos de sessão (`init`, `attach`, `release`, `commit`, `checkpoint`). Isso permite que uma nova sessão de IA descubra o que estava sendo feito antes, mesmo após crash da IDE ou troca de slot.

### Listar trabalhos recentes

```bash
source agent-guard journal --limit 10
source agent-guard journal --identity kimi1 --since 2026-07-01T00:00:00Z
```

### Retomar o último trabalho

```bash
source agent-guard resume --last
```

Saída típica:

```text
# Resume context
timestamp: 2026-07-02T16:24:00.123Z
identity:  kimi3
role:      ia-c
branch:    ia-kimi3/ia-c/agent-guard-session-journal
worktree:  /home/user/projects/my-project-ia-kimi3
message:   checkpoint: ADR-0014 escrito

To resume:
  cd /home/user/projects/my-project-ia-kimi3
  source .agent-guard-init --attach ia-kimi3/ia-c/agent-guard-session-journal
```

### Gravar checkpoint manual

```bash
source agent-guard checkpoint "Refatoração do tier selector em 80%"
```

### Configuração

No `agent-guard.yaml`:

```yaml
journal:
  path: .agent-guard/journal/agent-guard.jsonl
  retention_days: 90
```

## Git hooks

Os hooks garantem:

- `pre-commit`: autor da sessão compatível com identidade; branch sob prefixo correto.
- `commit-msg`: mensagem em conventional commits (se habilitado).
- `post-commit`: adiciona `git note` com `worktree`, `identity` e `branch`.
- `pre-push`: bloqueia push em branch protegida ou de outra identidade; envia notes.

## CI audit

No GitHub Actions (ou similar), execute o script de audit:

```bash
php packages/agent-guard-core/ci/worktree-origin-audit.php origin/main HEAD
```

O script rejeita commits de IA que não carreguem metadados de worktree ou cujo worktree não corresponda à identidade declarada.

## Adapters e wrappers

Adapters são thin wrappers que interceptam a chamada da ferramenta de IA e redirecionam para um worktree livre antes de delegar ao binário real.

> **Atenção:** nesta versão, o único adapter implementado e testado é o **wrapper do Kimi (Moonshot AI)** em `wrappers/kimi/`. Outras ferramentas de IA CLI não possuem wrapper automático e devem usar o init stub manualmente.

### Wrapper Kimi (`wrappers/kimi/`)

O wrapper `wrappers/kimi/wrapper.sh` substitui o binário `kimi` do Kimi Code CLI (Moonshot AI) para impor isolamento automaticamente. Ele:

- Detecta automaticamente o repositório via `git rev-parse --show-toplevel`.
- Lê `agent-guard.yaml` para descobrir caminhos, identidades e o binário real do Kimi.
- Impede execução no repo principal e redireciona para um worktree livre.
- Bloqueia worktrees sujos ou já em uso por outro processo.

#### Seleção explícita de slot (`--slot` / `AGENT_GUARD_SLOT`)

Por padrão o wrapper escolhe o slot automaticamente (retoma a última sessão ativa ou aloca o primeiro livre). Para ir direto a um slot específico em um único comando — sem rodar `adopt`/`init` manualmente antes:

```bash
kimi --slot kimi3            # de qualquer diretório do ecossistema
AGENT_GUARD_SLOT=kimi3 kimi  # equivalente via variável de ambiente
```

O wrapper decide automaticamente entre três fluxos:

1. **Recusa** — o slot tem um processo de agente vivo (ou um PID de lease vivo). Nunca há takeover de sessão ativa.
2. **Adopt** — a sessão anterior morreu (PID stale) e a worktree tem trabalho não commitado. O wrapper delega ao fluxo `--adopt` do init, que **preserva e exibe** o trabalho da sessão morta antes de lançar o agente.
3. **Acquire** — slot livre (ou stale com worktree limpa). Delega ao fluxo `--slot` do init.

Notas de implementação:

- O flag é consumido pelo wrapper e **nunca** é repassado ao binário real. Se o CLI um dia introduzir seu próprio `--slot`, use `AGENT_GUARD_SLOT`.
- Cada wrapper só aceita slots da própria família de identidade (o wrapper Kimi aceita `kimiN`, nunca `claudeN`). Configurável via `wrappers.kimi.identity_prefix` no `agent-guard.yaml`.
- No fluxo *adopt*, o wrapper exporta `AG_ALLOW_DIRTY_WORKTREE=1` com escopo local: o cleanliness guard não pode bloquear o lançamento de uma worktree cujo trabalho sujo acabou de ser explicitamente assumido e exibido ao usuário.

**Modo padrão (não-invasivo):** o instalador não substitui mais o binário global `kimi`. O isolamento pode ser ativado manualmente via init stub ou, para automação total, via wrapper invasivo.

- Instalação do wrapper invasivo (opcional, requer `--install-wrapper`):
  ```bash
  bash /path/to/agent-guard-core/install.sh --target /path/to/your/repo --install-wrapper
  ```
- Instalação manual do wrapper:
  ```bash
  mv <bin_dir>/kimi <bin_dir>/kimi.real
  cp packages/agent-guard-core/wrappers/kimi/wrapper.sh <bin_dir>/kimi
  chmod +x <bin_dir>/kimi
  ```
- Recuperação automática após updates do Kimi CLI:
  ```bash
  bash packages/agent-guard-core/wrappers/kimi/recovery.sh
  ```
  O recovery faz backup do binário real em `kimi.real.<timestamp>` antes de
  restaurar o wrapper e mantém apenas os 3 backups mais novos
  (`AG_KIMI_BACKUP_KEEP` para customizar), evitando acúmulo em disco.
- Remoção do wrapper invasivo e restauração do binário real:
  ```bash
  bash packages/agent-guard-core/wrappers/kimi/recovery.sh --remove-wrapper
  ```

## Testes

```bash
cd packages/agent-guard-core
bash tests/run-all.sh
```

## Origem

O `agent-guard-core` nasceu como protocolo interno de governança multi-IA em um projeto privado, depois foi refatorado para ser genérico e reutilizável em qualquer repositório Git. Mantenha o núcleo livre de regras de domínio específicas — adapters e hooks extras devem viver no projeto consumidor.

## Licença

MIT

## Contribuição

Contribuições são bem-vindas. Abra uma issue ou PR descrevendo o problema ou melhoria. Mantenha o escopo do núcleo: regras universais multi-IA, não regras de domínio de projeto específico.
