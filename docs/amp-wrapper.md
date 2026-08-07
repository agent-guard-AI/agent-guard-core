# Wrapper do Agent Guard para o Amp CLI

## Visão geral

O wrapper do Amp é a porta de entrada protegida para executar `amp` em um
repositório gerenciado pelo Agent Guard. Antes de iniciar a CLI real, ele:

1. identifica o repositório e lê `agent-guard.yaml`;
2. seleciona, aluga ou adota um slot da família `ampN`;
3. direciona a sessão ao worktree isolado correspondente;
4. rejeita worktrees ocupados, estrangeiros ou sujos sem autorização de
   recuperação;
5. exporta identidade, branch e worktree para a sessão; e
6. substitui o próprio processo pela CLI real com `exec`.

Isso é necessário porque várias abas do Amp abertas no mesmo clone partiriam
do mesmo diretório, compartilhariam branch e arquivos e poderiam sobrescrever
o trabalho umas das outras. O wrapper transforma cada aba em uma sessão com
lease e worktree próprios (`amp1`, `amp2`, etc.). Fora de um ecossistema
gerenciado, a chamada é repassada sem alteração para o Amp real.

### Diferença em relação ao wrapper do Kimi

O Kimi instala e atualiza seu executável no mesmo caminho em que o wrapper
precisa ficar. Por isso, uma atualização pode substituir o wrapper, exigindo
restauração. O Amp usa caminhos separados:

- o wrapper fica em um diretório estável controlado pelo HMVIP;
- o binário real continua no diretório controlado pelo instalador do Amp.

Assim, uma atualização troca o binário real **sem substituir o wrapper**. A
seleção entre ambos é feita pela ordem do `PATH`, não por renomeação ou
substituição in-place do executável do Amp.

## Arquitetura

### Layout de diretórios

| Caminho | Papel |
|---|---|
| `~/.local/hmvip/bin/amp` | Wrapper do Agent Guard; deve ser o primeiro `amp` encontrado no `PATH`. |
| `~/.amp/bin/amp` | Binário real, mantido e atualizado pelo Amp. |
| `~/.local/bin/amp` | Symlink original que o instalador do Amp pode criar ou recriar. Não deve ter precedência sobre o wrapper. |

O arquivo versionado que origina o wrapper é
`packages/agent-guard-core/wrappers/amp/wrapper.sh`. O script de recuperação é
`packages/agent-guard-core/wrappers/amp/recovery.sh`.

### Ordem obrigatória do `PATH`

`~/.local/hmvip/bin` deve aparecer antes de `~/.local/bin` e de qualquer outro
diretório que exponha o Amp real:

```bash
export PATH="$HOME/.local/hmvip/bin:$HOME/.local/bin:$PATH"
```

Adicionar o diretório ao fim do `PATH` não é suficiente. Um symlink anterior
continuaria contornando o wrapper.

### Configuração

O wrapper usa `agent-guard.yaml` como SSOT. `wrappers.amp.*` descreve o ponto de
entrada e a CLI real; `identities.amp.*` define a capacidade, os nomes dos
worktrees e a identidade Git dos slots Amp. Caminhos gerais, como
`paths.main_repo`, `paths.base_dir`, `paths.init_script` e
`paths.session_storage`, também são consumidos pelo fluxo de lease.

### Ordem de resolução do binário real

Dentro de um repositório com configuração carregada, a resolução ocorre nesta
ordem:

1. `AG_AMP_REAL`, se definido;
2. `wrappers.amp.real_bin_path` em `agent-guard.yaml`;
3. caminho canônico `~/.amp/bin/amp`;
4. `command -v amp`.

Cada candidato precisa existir, ser executável e não resolver para o próprio
wrapper, inclusive por symlink. Isso evita recursão. No bypass de emergência,
o caminho é deliberadamente mais restrito: `AG_AMP_REAL` ou
`~/.amp/bin/amp`.

## Instalação

### Instalação manual

Execute a partir da raiz do repositório:

```bash
mkdir -p "$HOME/.local/hmvip/bin"
cp packages/agent-guard-core/wrappers/amp/wrapper.sh \
  "$HOME/.local/hmvip/bin/amp"
chmod +x "$HOME/.local/hmvip/bin/amp"
```

Confirme antes que o Amp real esteja instalado em `~/.amp/bin/amp` ou ajuste
`wrappers.amp.real_bin_path`.

### Instalação ou recuperação pelo script

O método recomendado é idempotente e respeita a configuração do projeto:

```bash
bash packages/agent-guard-core/wrappers/amp/recovery.sh \
  --repo-root /home/hmvip-dev/hmvip
```

Sem `--repo-root`, o script tenta usar a raiz Git atual e, depois,
`AG_REPO_ROOT`. Ele cria o diretório, copia o wrapper quando necessário,
garante permissão de execução e avisa sobre binário real ou `PATH` incorretos.

### Configuração persistente do `PATH`

Adicione à configuração do shell, por exemplo em `~/.bashrc`:

```bash
export PATH="$HOME/.local/hmvip/bin:$HOME/.local/bin:$PATH"
```

Depois recarregue o shell e limpe o cache de comandos:

```bash
source ~/.bashrc
hash -r
```

Para shells não interativos, configure o `PATH` também no ambiente que os
inicia; `.bashrc` pode não ser lido nesses casos.

### Verificação

```bash
which amp
readlink -f "$(which amp)"
agent-guard doctor
```

Os dois primeiros comandos devem apontar para
`$HOME/.local/hmvip/bin/amp`. O `doctor` deve confirmar a configuração geral
do Agent Guard. Uma inspeção adicional é útil:

```bash
head -n 5 "$(which amp)"
test -x "$HOME/.amp/bin/amp"
```

O cabeçalho deve conter `Agent Guard — Amp CLI Wrapper`.

## Mitigação contra atualizações do Amp

`amp update` (ou `amp upgrade`) é classificado como comando de gerenciamento:
o wrapper o repassa diretamente ao binário real, sem adquirir lease. A
atualização altera os arquivos gerenciados pelo Amp, normalmente
`~/.amp/bin/amp` e possivelmente o symlink `~/.local/bin/amp`; ela não escreve
em `~/.local/hmvip/bin/amp`.

O wrapper, por outro lado, permanece estável e, na próxima execução normal,
descobre e executa a nova versão do binário real. Isso elimina o problema de
substituição in-place existente no Kimi.

Como defesa adicional, `_ensure_amp_wrapper()` em `src/init.sh` é executada ao
inicializar o Agent Guard. Se o arquivo estável estiver ausente ou não tiver o
cabeçalho esperado, ela chama `wrappers/amp/recovery.sh` e registra o resultado
em `/tmp/ag-amp-wrapper-recovery.log`.

Se uma atualização recriar `~/.local/bin/amp`, não é necessário apagar o
symlink. Garanta que `~/.local/hmvip/bin` venha antes no `PATH`, rode `hash -r`
e repita os comandos de verificação. Se preferir remover ambiguidade, remova o
symlink somente depois de confirmar que `~/.amp/bin/amp` continua presente.

## Uso

### Nova sessão com alocação automática

Na raiz principal gerenciada, execute:

```bash
cd /home/hmvip-dev/hmvip
amp
```

O wrapper tenta, nesta ordem, retomar a sessão Amp mais recente que seja segura,
usar um worktree Amp existente e livre ou pedir ao `init` que aloque/expanda um
slot. Sessões concorrentes recebem slots distintos. Argumentos não consumidos
pelo wrapper são encaminhados à CLI real.

### Seleção explícita de slot

```bash
amp --slot amp3
amp --slot=amp3
AGENT_GUARD_SLOT=amp3 amp
```

`--slot` é consumido pelo wrapper. Se uma versão futura do Amp adotar a mesma
flag, prefira a variável de ambiente. O slot deve pertencer à família definida
em `wrappers.amp.identity_prefix`; um slot vivo nunca é tomado à força.

### Comandos de gerenciamento sem lease

Chamadas que contenham qualquer um destes argumentos passam diretamente ao Amp
real: `--version`, `-V`, `--help`, `-h`, `update`, `upgrade` e `login`.

Exemplos:

```bash
amp --version
amp update
amp login
```

### Bypass de emergência

```bash
AG_WRAPPER_BYPASS=1 amp ...
```

Use apenas para diagnóstico ou recuperação humana: esse modo não aluga slot,
não redireciona ao worktree e não aplica as proteções do wrapper. Para um
binário real em caminho não padrão:

```bash
AG_WRAPPER_BYPASS=1 AG_AMP_REAL=/caminho/para/amp amp ...
```

### Adoção de slot com trabalho não commitado

Ao solicitar explicitamente um slot cujo lease aponta para PID morto, o
wrapper diferencia dois casos:

- worktree limpo: limpa o lease obsoleto pelo fluxo normal e adquire o slot;
- worktree sujo: executa `--adopt`, preserva e mostra mudanças e stashes e só
  então inicia o Amp nesse mesmo worktree.

Exemplo:

```bash
amp --slot amp3
```

Revise imediatamente `git status`, `git diff`, `git stash list` e a nota da
tarefa. A adoção nunca deve ser usada para tomar um PID vivo.

## Referência de configuração

### `wrappers.amp.*`

| Chave | Default | Descrição |
|---|---|---|
| `bin_dir` | `~/.local/hmvip/bin` | Diretório estável no qual o wrapper é instalado. Deve preceder o Amp original no `PATH`. |
| `real_bin_path` | `~/.amp/bin/amp` | Caminho do executável real mantido pelo Amp. |
| `default_role` | `ia-a` | Papel passado ao `init` quando o wrapper cria ou adquire uma sessão. |
| `identity_prefix` | `amp` | Família de slots aceita por `--slot`; impede que o wrapper Amp tome slots de outra CLI. |

### `identities.amp.*`

| Chave | Descrição |
|---|---|
| `slots` | Quantidade inicial de slots Amp. |
| `max_slots` | Limite superior para expansão dinâmica. Nunca deve ser menor que `slots`. |
| `auto_expand` | Permite ao `init` criar slots adicionais até `max_slots` quando todos os iniciais estão ocupados. |
| `worktree_prefix` | Prefixo dos diretórios de worktree; `{prefixo}1`, `{prefixo}2`, etc. |
| `author_email` | Template do e-mail Git; `{n}` é substituído pelo número do slot. |
| `author_name` | Template do nome do autor Git; `{n}` é substituído pelo número do slot. |

### Exemplo completo

```yaml
identities:
  amp:
    slots: 3
    max_slots: 10
    auto_expand: true
    worktree_prefix: hmvip-ia-amp
    author_email: agent-amp{n}@hmvip.dev
    author_name: HMVIP Amp{n} Agent

wrappers:
  amp:
    bin_dir: /home/hmvip-dev/.local/hmvip/bin
    real_bin_path: /home/hmvip-dev/.amp/bin/amp
    default_role: ia-a
    identity_prefix: amp
```

Evite `~` em valores YAML quando quiser eliminar diferenças de expansão entre
ferramentas; caminhos absolutos são os mais previsíveis.

## Troubleshooting

### Wrapper não encontrado

Sintoma: `which amp` não aponta para `~/.local/hmvip/bin/amp` ou o arquivo não
existe.

```bash
bash packages/agent-guard-core/wrappers/amp/recovery.sh \
  --repo-root /home/hmvip-dev/hmvip
hash -r
```

### `PATH` não configurado

Verifique a declaração e a ordem efetiva:

```bash
grep -n 'local/hmvip/bin' ~/.bashrc
printf '%s\n' "$PATH" | tr ':' '\n' | nl -ba
type -a amp
```

Corrija `~/.bashrc`, recarregue-a e execute `hash -r`. Em VS Code, tmux ou
outro processo antigo, abra um terminal novo ou reinicie o processo pai para
que ele herde o ambiente atualizado.

### Binário real não encontrado

```bash
test -x "$HOME/.amp/bin/amp" && "$HOME/.amp/bin/amp" --version
readlink -f "$HOME/.local/bin/amp"
```

Reinstale o Amp se o binário real não existir, ou ajuste
`wrappers.amp.real_bin_path`. Não aponte essa chave para o wrapper.

### Nenhum slot livre

Consulte as sessões e confirme `identities.amp.slots`, `max_slots` e
`auto_expand`. Feche/libere sessões concluídas de forma segura ou aumente
`max_slots`; não mate nem reutilize uma sessão viva. A expansão e a criação do
worktree são responsabilidade do `init`, não do wrapper.

### Worktree estrangeiro (`foreign worktree`)

O diretório atual pertence a identidade diferente da identidade alugada.
Saia desse worktree e inicie pela raiz principal para obter um slot livre:

```bash
cd /home/hmvip-dev/hmvip
amp
```

Para retomar uma branch própria, use o fluxo oficial de `attach`. Não faça
checkout no worktree de outra identidade.

### Worktree sujo (`dirty worktree`)

Inspecione antes de agir:

```bash
git status --short
git diff
git stash list
```

Commit o trabalho na branch correta ou crie um stash identificado. Não apague
mudanças desconhecidas. Para recuperação deliberada existe
`AG_ALLOW_DIRTY_WORKTREE=1`, mas ele não deve ser usado para uma sessão nova;
prefira `amp --slot ampN`, que adota com segurança um lease morto e sujo.

## Cenários cobertos e garantias

### Múltiplas abas concorrentes

Cada aba que parte da raiz passa pelo aluguel e recebe um slot `ampN` livre.
Worktrees com lease vivo, processo de agente vivo, mudanças pendentes ou estado
de pós-release não são oferecidos como livres.

### Corrida na aquisição do lease

A escolha inicial do wrapper é confirmada pelo `init`, que serializa a operação
com lock exclusivo atômico (`flock`). Duas abas que observem o mesmo candidato
não conseguem confirmar simultaneamente o mesmo lease: uma vence; a outra
reavalia/falha sem compartilhar o slot.

### Amp iniciado dentro de um worktree existente

O wrapper detecta o worktree atual. Se estiver livre e compatível, inicializa o
lease nele; se houver outro agente vivo, bloqueia e orienta iniciar pela raiz.
Depois do lease, o guard de worktree estrangeiro compara o diretório atual com
o worktree atribuído.

### PID obsoleto e adoção

PIDs mortos, zombies, parados ou rastreados não são tratados como sessões
saudáveis. Um slot explícito limpo pode ser readquirido; se estiver sujo, passa
pelo fluxo de adoção preservando o trabalho. PIDs vivos e outros agentes com
`cwd` no worktree provocam recusa fail-closed.

### Atualizações do Amp

`amp update` atualiza o binário real e pode recriar o symlink original, mas não
altera o diretório estável do wrapper. A ordem do `PATH` mantém a proteção e
`_ensure_amp_wrapper()` recupera um wrapper ausente no próximo init.

### Shells não interativos, `sudo`, subshells, VS Code e tmux

- Shell não interativo pode não ler `~/.bashrc`: forneça o `PATH` no ambiente
  do processo ou use o caminho completo do wrapper.
- `sudo` costuma aplicar `secure_path` e trocar `HOME`; não use `sudo amp` para
  trabalho normal. Se recuperação privilegiada for inevitável, preserve e
  audite explicitamente `HOME`/`PATH`.
- Subshells herdam o `PATH`, mas o wrapper remove variáveis de lease herdadas
  antes de adquirir uma nova sessão, evitando reutilizar a identidade do pai.
- Terminais do VS Code e servidores tmux antigos podem conservar um `PATH`
  anterior; reinicie o terminal ou servidor tmux após mudar a configuração.
- Para automação, prefira
  `PATH="$HOME/.local/hmvip/bin:$PATH" amp ...`.

### Sinais (`SIGINT` e `SIGTERM`)

Após as validações, o wrapper usa `exec` para substituir seu processo pelo Amp
real. Portanto, `Ctrl+C` (`SIGINT`) e `SIGTERM` chegam diretamente ao Amp, sem
um processo intermediário que retenha ou perca o sinal. O lock de aquisição é
liberado por trap no `init`; o watcher de trace é best-effort, desacoplado e
para quando o PID do Amp deixa de existir ou é reutilizado por outro comando.

### Prevenção de recursão

Todo candidato ao binário real é normalizado com `readlink -f` e comparado ao
wrapper. Um symlink que volta ao wrapper é rejeitado. No bypass, a busca evita
deliberadamente `command -v amp`, reduzindo ainda mais o risco de loop.

### Comportamento fail-closed

Dentro de um repositório que aparenta ser gerenciado, ausência de
`agent-guard.yaml`, script de init, binário real, lease completo ou identidade
coerente encerra a execução. Ocupação incerta, worktree estrangeiro e sujeira
não autorizada também bloqueiam. O repasse sem lease só ocorre fora do
ecossistema ou para a lista explícita de comandos de gerenciamento. O bypass é
uma exceção manual, visível e destinada exclusivamente à recuperação.
