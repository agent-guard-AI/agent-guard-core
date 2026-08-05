#!/usr/bin/env python3
"""
summarize-prompt.py — resume o prompt do usuario em um titulo curto para a aba.

Integrado ao hmvip-tab: e chamado por kimi-tab-hook.sh a cada UserPromptSubmit.
Retorna JSON com:
  title      : titulo resumido (max ~32 chars)
  command    : comando slash detectado ou null
  reset      : True se deve descartar o titulo anterior
  compact    : True se deve compactar/resumir o titulo existente
  manual     : True se o usuario quer fixar o titulo manualmente

Uso:
  python3 summarize-prompt.py "prompt aqui" [titulo_atual]
  echo "prompt" | python3 summarize-prompt.py - [titulo_atual]
"""

from __future__ import annotations

import json
import re
import sys
from typing import Optional

import os

MAX_TITLE_CHARS = int(os.environ.get("HMVIP_TAB_TITLE_CHARS", "32"))
COMPACT_SUFFIX = "/compact"
NEW_SUFFIX = "/new"

# Quanto deixar reservado para suffixos como /compact, /new, /skill: etc.
SUFFIX_RESERVE = 10


# ---------------------------------------------------------------------------
# Comandos slash reconhecidos
# ---------------------------------------------------------------------------
SLASH_COMMANDS = {
    # comando : (reset, compact, manual, prefixo_sugerido)
    "/new": (True, False, False, ""),
    "/nova": (True, False, False, ""),
    "/novo": (True, False, False, ""),
    "/compact": (False, True, False, ""),
    "/compactar": (False, True, False, ""),
    "/resumir": (False, True, False, ""),
    "/resume": (False, True, False, ""),
    "/clear": (True, False, False, "livre"),
    "/limpar": (True, False, False, "livre"),
    "/reset": (True, False, False, ""),
    "/continue": (False, False, False, ""),
    "/continuar": (False, False, False, ""),
    "/tab": (True, False, True, ""),
    "/aba": (True, False, True, ""),
    "/pin": (True, False, True, ""),
    "/fixar": (True, False, True, ""),
    "/multi": (True, False, False, ""),
    "/tasks": (True, False, False, ""),
    "/context": (True, False, False, ""),
    "/ctx": (True, False, False, ""),
    "/skill": (True, False, False, "skill:"),
    "/goal": (True, False, False, "goal:"),
    "/meta": (True, False, False, "goal:"),
    "/deploy": (True, False, False, "deploy"),
    "/release": (True, False, False, "release"),
    "/pr": (True, False, False, "PR"),
    "/merge": (True, False, False, "merge"),
    "/sync": (True, False, False, "sync"),
    "/review": (True, False, False, "review"),
    "/revisar": (True, False, False, "review"),
    "/test": (True, False, False, "test"),
    "/testes": (True, False, False, "test"),
    "/tests": (True, False, False, "test"),
    # Prefixos de commit conventional
    "/fix": (True, False, False, "fix"),
    "/feat": (True, False, False, "feat"),
    "/chore": (True, False, False, "chore"),
    "/docs": (True, False, False, "docs"),
    "/hotfix": (True, False, False, "hotfix"),
    "/bug": (True, False, False, "fix"),
    "/issue": (True, False, False, "issue"),
    "/ask": (True, False, False, "ask"),
    "/explain": (True, False, False, "explain"),
    "/ajuda": (True, False, False, "ask"),
}


# ---------------------------------------------------------------------------
# Dicionario de entidades HMVIP e acoes
# ---------------------------------------------------------------------------
VERB_ACTIONS = {
    # pt-BR (infinitivo + formas flexionadas comuns no imperativo/presente)
    "corrigir": "fix",
    "corrige": "fix",
    "corrija": "fix",
    "corrigiu": "fix",
    "consertar": "fix",
    "conserta": "fix",
    "conserte": "fix",
    "arrumar": "fix",
    "arruma": "fix",
    "arrume": "fix",
    "resolver": "fix",
    "resolve": "fix",
    "resolva": "fix",
    "debugar": "debug",
    "debuga": "debug",
    "debugue": "debug",
    "investigar": "debug",
    "investiga": "debug",
    "investigue": "debug",
    "ver porque": "debug",
    "ver por que": "debug",
    "veja porque": "debug",
    "veja por que": "debug",
    "descobrir": "debug",
    "descobre": "debug",
    "descubra": "debug",
    "achar": "find",
    "acha": "find",
    "ache": "find",
    "encontrar": "find",
    "encontra": "find",
    "encontre": "find",
    "implementar": "add",
    "implementa": "add",
    "implemente": "add",
    "criar": "add",
    "cria": "add",
    "crie": "add",
    "adicionar": "add",
    "adiciona": "add",
    "adicione": "add",
    "fazer": "add",
    "faz": "add",
    "faça": "add",
    "montar": "add",
    "monta": "add",
    "monte": "add",
    "construir": "add",
    "constrói": "add",
    "construa": "add",
    "refatorar": "refactor",
    "refatora": "refactor",
    "refatore": "refactor",
    "melhorar": "refactor",
    "melhora": "refactor",
    "melhore": "refactor",
    "otimizar": "refactor",
    "otimiza": "refactor",
    "otimize": "refactor",
    "simplificar": "refactor",
    "simplifica": "refactor",
    "simplifique": "refactor",
    "atualizar": "update",
    "atualiza": "update",
    "atualize": "update",
    "mudar": "update",
    "muda": "update",
    "mude": "update",
    "alterar": "update",
    "altera": "update",
    "altere": "update",
    "modificar": "update",
    "modifica": "update",
    "modifique": "update",
    "trocar": "update",
    "troca": "update",
    "troque": "update",
    "renomear": "rename",
    "renomeia": "rename",
    "renomeie": "rename",
    "remover": "remove",
    "remove": "remove",
    "remova": "remove",
    "deletar": "remove",
    "deleta": "remove",
    "delete": "remove",
    "excluir": "remove",
    "exclui": "remove",
    "exclua": "remove",
    "apagar": "remove",
    "apaga": "remove",
    "apague": "remove",
    "testar": "test",
    "testa": "test",
    "teste": "test",
    "validar": "test",
    "valida": "test",
    "valide": "test",
    "revisar": "review",
    "revisa": "review",
    "revise": "review",
    "analisar": "analyze",
    "analisa": "analyze",
    "analise": "analyze",
    "verificar": "check",
    "verifica": "check",
    "verifique": "check",
    "checar": "check",
    "checa": "check",
    "cheque": "check",
    "configurar": "config",
    "configura": "config",
    "configure": "config",
    "instalar": "install",
    "instala": "install",
    "instale": "install",
    "mergear": "merge",
    "merge": "merge",
    "fazer merge": "merge",
    "sincronizar": "sync",
    "sincroniza": "sync",
    "sincronize": "sync",
    "syncar": "sync",
    "liberar": "release",
    "libera": "release",
    "libere": "release",
    "perguntar": "ask",
    "pergunta": "ask",
    "pergunte": "ask",
    "explicar": "explain",
    "explica": "explain",
    "explique": "explain",
    "entender": "understand",
    "entende": "understand",
    "entenda": "understand",
    "compreender": "understand",
    "compreende": "understand",
    "compreenda": "understand",
    # EN
    "fix": "fix",
    "debug": "debug",
    "investigate": "debug",
    "create": "add",
    "add": "add",
    "make": "add",
    "build": "add",
    "implement": "add",
    "refactor": "refactor",
    "improve": "refactor",
    "optimize": "refactor",
    "update": "update",
    "change": "update",
    "modify": "update",
    "rename": "rename",
    "remove": "remove",
    "delete": "remove",
    "test": "test",
    "validate": "test",
    "review": "review",
    "analyze": "analyze",
    "check": "check",
    "configure": "config",
    "install": "install",
    "merge": "merge",
    "sync": "sync",
    "release": "release",
    "ask": "ask",
    "explain": "explain",
    "understand": "understand",
}

ENTITY_ALIASES = {
    # mantem chaves minusculas
    "hmvip-core": "core",
    "hmvip-pay": "pay",
    "hmvip-subscriptions": "subs",
    "hmvip-store-manager": "store",
    "hmvip-media-manager": "media",
    "hmvip-content-shield": "shield",
    "hmvip-identity": "identity",
    "hmvip-messenger": "messenger",
    "hmvip-ai-assistant": "ai",
    "hmvip-analytics": "analytics",
    "hmvip-engage": "engage",
    "hmvip-social-publisher": "social",
    "hmvip-comment-auction": "auction",
    "hmvip-creator-finder": "creators",
    "hmvip-spotlight": "spotlight",
    "hmvip-security": "security",
    "hmvip-auth": "auth",
    "hmvip-legal-guardian": "legal",
    "hmvip-support": "support",
    "hmvip-help": "help",
    "hmvip-ads": "ads",
    "hmvip-player": "player",
    "hmvip-thinking-logger": "logger",
    "hmvip-test": "test",
    "hmvip-tab": "tab",
    "hmvip-tabs": "tab",
    "kimi tab": "tab",
    "kimi tabs": "tab",
    "titulo da aba": "tab",
    "titulo da abas": "tab",
    "título da aba": "tab",
    "título da abas": "tab",
    "nome da aba": "tab",
    "nome da abas": "tab",
    "renomear aba": "tab",
    "renomear abas": "tab",
    "agent-guard": "agent-guard",
    "agent-guard-core": "agent-guard",
    "hmvip-agent-init": "agent-guard",
    "kimi-code": "kimi",
    "mcp serena": "serena",
    "serena mcp": "serena",
    "serena": "serena",
    "agent guard sync": "agent-guard",
    "sync upstream": "upstream",
    "action scheduler": "AS",
    "merge queue": "MQ",
    "ci/cd": "CI",
    "github actions": "CI",
    "github": "github",
    "phpstan": "stan",
    "phpcs": "cs",
    "wordpress": "WP",
    "woocommerce": "WC",
    "buddyboss": "BB",
    "staging": "staging",
    "producao": "prod",
    "produção": "prod",
    "deploy": "deploy",
    "upstream": "upstream",
}

STOPWORDS = {
    "o", "a", "os", "as", "um", "uma", "uns", "umas", "de", "do", "da", "dos", "das",
    "no", "na", "nos", "nas", "em", "para", "pra", "por", "pelo", "pela", "pelos", "pelas",
    "com", "sem", "sobre", "sob", "ante", "apos", "ate", "desde", "entre", "contra", "perante",
    "que", "qual", "quais", "quem", "cujo", "cuja", "onde", "como", "quando", "porque", "porquê",
    "por que", "por quê", "se", "mesmo", "proprio", "tal", "tais", "este", "esta", "estes", "estas",
    "esse", "essa", "esses", "essas", "aquele", "aquela", "aqueles", "aquelas", "isto", "isso", "aquilo",
    "eu", "voce", "vc", "ele", "ela", "eles", "elas", "nós", "nos", "vos", "meu", "minha", "meus", "minhas",
    "teu", "tua", "teus", "tuas", "seu", "sua", "seus", "suas", "nosso", "nossa", "nossos", "nossas",
    "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "from",
    "by", "about", "as", "into", "through", "during", "before", "after", "above", "below", "between",
    "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did",
    "will", "would", "could", "should", "may", "might", "must", "shall", "can", "need", "dare",
    "this", "that", "these", "those", "i", "you", "he", "she", "it", "we", "they", "my", "your",
    "his", "her", "its", "our", "their", "what", "which", "who", "whom", "whose", "where", "when",
    "why", "how", "all", "each", "every", "both", "few", "more", "most", "other", "some", "such",
    "no", "not", "only", "own", "same", "so", "than", "too", "very", "just", "now", "then",
}

GREETINGS = re.compile(
    r"^(?:\s*(?:oi|olá|ola|opa|ei|hey|hi|hello|bom dia|boa tarde|boa noite|tudo bem|td bem|blz|beleza|ok|okay)[\s,!?.-]*)+",
    re.IGNORECASE,
)


# ---------------------------------------------------------------------------
# Utilitarios
# ---------------------------------------------------------------------------
def _normalize(text: str) -> str:
    text = text.replace("\r", " ").replace("\n", " ").replace("\t", " ")
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _truncate(text: str, max_len: int = MAX_TITLE_CHARS) -> str:
    if len(text) <= max_len:
        return text
    cut = text[:max_len]
    # tenta cortar na ultima palavra completa
    cut2 = re.sub(r" [^ ]*$", "", cut)
    if len(cut2) < max_len // 4:
        cut2 = cut
    return cut2.rstrip() + "…"


def _extract_slash_command(text: str) -> tuple[Optional[str], str]:
    """Retorna (comando, resto_do_texto)."""
    match = re.match(r"^(/[a-zA-Z0-9_\-áéíóúãõç]+)(?:\s+(.+))?$", text, re.DOTALL)
    if not match:
        return None, text
    return match.group(1).lower(), (match.group(2) or "").strip()


def _detect_hmvip_entity(text: str) -> Optional[str]:
    text_lower = text.lower()
    # procura plugins hmvip-*
    for m in re.finditer(r"\bhmvip-[a-zA-Z0-9_\-]+\b", text_lower):
        entity = m.group(0)
        return ENTITY_ALIASES.get(entity, entity.replace("hmvip-", ""))
    # procura aliases soltos
    for phrase, alias in ENTITY_ALIASES.items():
        if phrase in text_lower:
            return alias
    return None


def _detect_action(text: str) -> tuple[Optional[str], Optional[str]]:
    """Retorna (acao_mapeada, verbo_original_detectado)."""
    text_lower = text.lower()
    # prioriza verbos compostos
    for phrase, action in sorted(VERB_ACTIONS.items(), key=lambda kv: -len(kv[0])):
        if re.search(r"\b" + re.escape(phrase) + r"\b", text_lower):
            return action, phrase
    return None, None


def _extract_keyword_phrase(text: str, verbs_to_drop: set[str] | None = None, entity: str = "") -> str:
    """Tenta extrair uma frase curta significativa sem stopwords."""
    verbs_to_drop = verbs_to_drop or set()
    # remove URLs, paths, codigo inline e marcacao
    text = re.sub(r"`[^`]*`", " ", text)
    text = re.sub(r"\bhttps?://\S+", " ", text)
    text = re.sub(r"\b/[a-zA-Z0-9_\-/]+\b", " ", text)
    text = _normalize(text)

    # Preserva expressoes multi-palavras conhecidas (ex: mcp serena, agent guard)
    text = re.sub(r"\bmcp serena\b", "mcp_serena", text, flags=re.IGNORECASE)
    text = re.sub(r"\bagent guard\b", "agent_guard", text, flags=re.IGNORECASE)
    text = re.sub(r"\bagent guard core\b", "agent_guard_core", text, flags=re.IGNORECASE)

    words = [w for w in re.findall(r"[a-zA-Z0-9_\-/áéíóúãõç]+", text.lower()) if w not in STOPWORDS]
    if not words:
        return ""

    # Restaura tokens compostos
    restored = []
    for w in words:
        if w == "mcp_serena":
            restored.append("serena")
        elif w == "agent_guard":
            restored.append("agent-guard")
        elif w == "agent_guard_core":
            restored.append("agent-guard")
        else:
            restored.append(w)
    words = restored

    # remove verbos detectados e suas variacoes
    filtered = []
    for w in words:
        drop = False
        for v in verbs_to_drop:
            if v in w or w in v:
                drop = True
                break
        # tambem dropa a propria entidade para nao repetir
        if entity and w in entity.replace("-", " "):
            drop = True
        if not drop:
            filtered.append(w)

    # junta as primeiras 4-5 palavras significativas
    seen = []
    for w in filtered:
        if w not in seen:
            seen.append(w)
        if len(seen) >= 5:
            break
    return " ".join(seen)


def _extract_pr_issue_number(text: str) -> str:
    """Extrai numero de PR ou issue (#123) se presente."""
    m = re.search(r"\b#(\d{2,})\b", text)
    if m:
        return f"#{m.group(1)}"
    # PR 123, issue 123, pull request 123
    m = re.search(r"\b(?:pr|pull request|issue)\s+#?(\d{2,})\b", text, re.IGNORECASE)
    if m:
        return f"#{m.group(1)}"
    return ""


def _split_multi_task(text: str) -> list[str]:
    """Divide prompt com varias tarefas em partes independentes (recursivo)."""
    text = text.strip(" ,;.")
    if len(text) < 8:
        return [text]

    # Separadores fortes: quebram mesmo que os lados sejam curtos.
    strong_separators = ["\n---\n", "\n\n", "; ", " depois ", " em seguida ", " depois disso ", " alem disso ", " também ", " tambem "]
    for sep in strong_separators:
        if sep in text:
            parts = [p.strip(" ,;.") for p in text.split(sep)]
            parts = [p for p in parts if len(p) >= 6]
            if len(parts) > 1:
                result = []
                for p in parts:
                    result.extend(_split_multi_task(p))
                return result

    # Separador fraco " e ": so quebra quando ha clara enumeracao de acoes.
    if " e " in text:
        parts = [p.strip(" ,;.") for p in text.split(" e ")]
        if len(parts) == 2:
            left, right = parts
            left_action = _detect_action(left)[0]
            right_action = _detect_action(right)[0]
            if left_action and right_action and len(left) >= 8 and len(right) >= 8:
                return [_split_multi_task(left)[0], _split_multi_task(right)[0]]

    return [text]


def _summarize_single_task(text: str, allow_entity: bool = True) -> str:
    """Gera um titulo curto para uma unica tarefa."""
    action, original_verb = _detect_action(text)
    entity = _detect_hmvip_entity(text) if allow_entity else None
    verbs_to_drop = {original_verb} if original_verb else set()
    failure_ctx = _detect_failure_context(text)
    pr_issue = _extract_pr_issue_number(text)

    title = ""
    if action and entity:
        kw = _extract_keyword_phrase(text, verbs_to_drop, entity)
        if failure_ctx:
            title = f"{action} {entity} {failure_ctx}"
        elif pr_issue:
            title = f"{action} {entity} {pr_issue}"
        elif kw and len(f"{action} {entity} {kw.split()[0]}") <= MAX_TITLE_CHARS - 4:
            title = f"{action} {entity} {kw.split()[0]}"
        else:
            title = f"{action} {entity}"
    elif action:
        kw = _extract_keyword_phrase(text, verbs_to_drop)
        if pr_issue:
            title = f"{action} {pr_issue}"
        elif kw:
            title = f"{action} {kw}"
        else:
            title = action
    elif entity:
        kw = _extract_keyword_phrase(text, {entity}, entity)
        if failure_ctx:
            title = f"{entity} {failure_ctx}"
        elif pr_issue:
            title = f"{entity} {pr_issue}"
        elif kw:
            title = f"{entity}: {kw}"
        else:
            title = entity
    else:
        title = _extract_keyword_phrase(text) or text

    return _normalize(title) or "livre"


def _summarize_multi_task(text: str) -> str:
    """Gera titulo concatenando as principais tarefas detectadas."""
    tasks = _split_multi_task(text)
    if len(tasks) == 1:
        return _summarize_single_task(tasks[0])

    summaries = []
    for task in tasks[:3]:  # max 3 tarefas para nao estourar o titulo
        s = _summarize_single_task(task)
        if s and s != "livre" and s not in summaries:
            summaries.append(s)
        if len(summaries) >= 2:
            break

    if not summaries:
        return _summarize_single_task(tasks[0])

    combined = " + ".join(summaries)
    if len(combined) <= MAX_TITLE_CHARS:
        return combined

    # se nao couber, resume cada parte
    short = []
    for s in summaries:
        parts = s.split()
        if len(parts) > 2:
            short.append(" ".join(parts[:2]))
        else:
            short.append(s)
    combined = " + ".join(short)
    return _truncate(combined)


def _detect_failure_context(text: str) -> str:
    """Se o prompt menciona parada/falha/erro, retorna um qualificador curto."""
    text_lower = text.lower()
    if re.search(r"\bparou\b|\bparar\b|\bstopped\b|\.\.\. parou", text_lower):
        return "stopped"
    if re.search(r"\bfalhou\b|\.\.\. falhou|failed", text_lower):
        return "failed"
    if re.search(r"\berro\b|error", text_lower):
        return "error"
    return ""


def _compact_existing(current: str) -> str:
    """Resume ainda mais um titulo existente e marca como compactado."""
    if not current or current in ("livre", "free"):
        return "compact"
    # remove suffixos anteriores para nao acumular
    current = re.sub(r"\s*/(compact|new|resumo)$", "", current, flags=re.IGNORECASE).strip()
    # Tenta preservar o verbo/action (primeira palavra) e resumir o objeto
    parts = current.split()
    if len(parts) > 3:
        current = " ".join(parts[:3])
    elif len(parts) > 2:
        current = " ".join(parts[:2])
    compacted = _truncate(current, max_len=max(16, MAX_TITLE_CHARS - len(COMPACT_SUFFIX) - 2))
    return f"{compacted} {COMPACT_SUFFIX}"


def _summarize_text(text: str, current_title: str = "", force_multi: bool = False) -> str:
    """Gera titulo a partir do texto livre do prompt."""
    text = _normalize(text)
    if not text:
        return "livre"

    # remove saudacao
    text = GREETINGS.sub("", text)
    text = _normalize(text)
    if not text:
        return "livre"

    # Detecta multi-tarefa automaticamente ou por comando explicito
    tasks = _split_multi_task(text)
    if force_multi or len(tasks) > 1:
        return _summarize_multi_task(text)

    return _summarize_single_task(text)


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] != "-":
        prompt = sys.argv[1]
    else:
        prompt = sys.stdin.read()

    current_title = sys.argv[2] if len(sys.argv) > 2 else ""

    prompt = _normalize(prompt)
    command, rest = _extract_slash_command(prompt)

    result = {
        "command": command,
        "reset": False,
        "compact": False,
        "manual": False,
        "title": "",
    }

    if command:
        cfg = SLASH_COMMANDS.get(command, (True, False, False, ""))
        reset, compact, manual, prefix = cfg
        result["reset"] = reset
        result["compact"] = compact
        result["manual"] = manual

        if command in ("/clear", "/limpar", "/reset"):
            result["title"] = "livre"
        elif command in ("/continue", "/continuar"):
            result["title"] = current_title or "livre"
        elif command in ("/compact", "/compactar", "/resumir", "/resume"):
            result["title"] = _compact_existing(current_title)
            # se vier texto extra, tenta resumir a partir dele em vez do atual
            if rest:
                candidate = _summarize_text(rest)
                if candidate != "livre":
                    result["title"] = _compact_existing(candidate)
        elif command in ("/tab", "/aba", "/pin", "/fixar"):
            result["title"] = _truncate(_normalize(rest)) if rest else current_title or "livre"
        elif command in ("/multi", "/tasks"):
            if rest:
                result["title"] = _summarize_text(rest, force_multi=True)
            else:
                result["title"] = _summarize_text(current_title or "multi-task", force_multi=True)
        elif command in ("/context", "/ctx"):
            if rest:
                result["title"] = _summarize_text(rest)
            elif current_title:
                result["title"] = current_title
            else:
                result["title"] = "context"
        elif command in ("/skill", "/goal", "/meta", "/deploy", "/pr", "/review", "/revisar"):
            if rest:
                suffix = _summarize_text(rest)
                result["title"] = f"{prefix} {suffix}".strip()
            else:
                result["title"] = prefix or command.lstrip("/")
        else:
            # /new, /nova, /test, etc.: novo titulo a partir do restante
            if rest:
                result["title"] = _summarize_text(rest)
            else:
                result["title"] = prefix or command.lstrip("/")
    else:
        result["title"] = _summarize_text(prompt)

    # sanitizacao final contra escape sequences (defesa em profundidade)
    result["title"] = re.sub(r"[\x00-\x1f\x7f]", "", result["title"])

    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
