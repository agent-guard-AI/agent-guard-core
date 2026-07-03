<?php
declare(strict_types=1);

/**
 * Worktree Origin Audit
 *
 * Validates that AI agent commits carry worktree origin metadata via git notes.
 * Rejects commits created in the main repository or without metadata.
 *
 * Configuration is read from agent-guard.yaml (SSOT).
 *
 * Usage:
 *   php packages/agent-guard-core/ci/worktree-origin-audit.php <base-ref> <head-ref>
 *
 * Example:
 *   php packages/agent-guard-core/ci/worktree-origin-audit.php origin/develop HEAD
 */

namespace AgentGuard\CI;

require_once __DIR__ . '/../src/Config.php';

use AgentGuard\Core\Config;

$baseRef = $argv[1] ?? 'origin/develop';
$headRef = $argv[2] ?? 'HEAD';

$exitCode = (new WorktreeOriginAudit(new Config()))->run($baseRef, $headRef);
exit($exitCode);

final class WorktreeOriginAudit
{
    private Config $config;

    /** @var array<int, array{regex: string, name: string}> */
    private array $identityPatterns = array();

    public function __construct(Config $config)
    {
        $this->config = $config;
        $this->buildIdentityPatterns();
    }

    public function run(string $baseRef, string $headRef): int
    {
        echo "🔍 Worktree Origin Audit\n";
        echo "   Base: {$baseRef}\n";
        echo "   Head: {$headRef}\n\n";

        $notesRef = escapeshellarg($this->config->getGitNotesRef());
        shell_exec("git fetch origin {$notesRef}:{$notesRef} >/dev/null 2>&1");

        $commits = $this->getCommits($baseRef, $headRef);
        if (empty($commits)) {
            echo "⚠️  No commits found between base and head.\n";
            return 0;
        }

        $violations = 0;
        foreach ($commits as $commit) {
            $email = $commit['email'];
            $hash  = $commit['hash'];
            $subject = $commit['subject'];

            $identityMatch = $this->matchIdentity($email);
            if ($identityMatch === null) {
                // Human commits are not audited by worktree.
                continue;
            }

            $identity = $identityMatch['identity'];
            $identityName = $identityMatch['name'];
            echo "🤖 AI commit detected: {$identityName} ({$hash}) {$subject}\n";

            $note = $this->getWorktreeNote($hash);
            if ($note === null) {
                echo "   ❌ Missing worktree metadata (git note {$this->config->getGitNotesRef()}).\n";
                echo "      The commit must be created inside the AI worktree.\n";
                $violations++;
                continue;
            }

            $worktree = $this->parseWorktreeFromNote($note);
            if ($worktree === null) {
                echo "   ❌ Malformed worktree metadata.\n";
                echo "      Note content:\n{$note}\n";
                $violations++;
                continue;
            }

            echo "   📌 Origin worktree: {$worktree}\n";

            $mainRepo = $this->config->getMainRepo();
            if ($worktree === $mainRepo) {
                echo "   ❌ Commit created in the main repository ({$worktree}).\n";
                echo "      AI agents must use their isolated worktree.\n";
                $violations++;
                continue;
            }

            $wtMatch = $this->matchWorktreeIdentity($worktree);
            if ($wtMatch === null) {
                echo "   ❌ Worktree '{$worktree}' does not match any configured identity pattern.\n";
                $violations++;
                continue;
            }

            if ($wtMatch['identity'] !== $identity) {
                echo "   ❌ Worktree identity ({$wtMatch['identity']}) does not match author identity ({$identity}).\n";
                $violations++;
                continue;
            }

            echo "   ✅ Origin validated.\n";
        }

        echo "\n";
        if ($violations > 0) {
            echo "❌ Worktree Origin Audit FAILED: {$violations} violation(s).\n";
            return 1;
        }

        echo "✅ Worktree Origin Audit PASSED.\n";
        return 0;
    }

    private function buildIdentityPatterns(): void
    {
        foreach ($this->config->getIdentities() as $name => $identity) {
            if (!is_array($identity)) {
                continue;
            }
            $template = $identity['author_email'] ?? '';
            if ($template === '') {
                continue;
            }
            $regex = $this->templateToRegex((string) $template);
            if ($regex !== '') {
                $this->identityPatterns[] = array(
                    'regex' => $regex,
                    'name'  => $name,
                );
            }
        }
    }

    private function templateToRegex(string $template): string
    {
        // Replace {n} with a numeric capture group.
        $regex = preg_replace('/\{n\}/', '([0-9]+)', $template);
        if ($regex === null) {
            return '';
        }
        // Escape regex metacharacters except the capture group we just inserted.
        $regex = preg_replace_callback(
            '/\(\[0\-9\]\+\)/',
            static function () {
                return '__AGENT_GUARD_SLOT_CAPTURE__';
            },
            $regex
        );
        if ($regex === null) {
            return '';
        }
        $regex = preg_quote($regex, '/');
        $regex = str_replace('__AGENT_GUARD_SLOT_CAPTURE__', '([0-9]+)', $regex);
        return '/^' . $regex . '$/';
    }

    /**
     * @return array{identity: string, name: string, slot: string}|null
     */
    private function matchIdentity(string $email): ?array
    {
        foreach ($this->identityPatterns as $pattern) {
            if (preg_match($pattern['regex'], $email, $matches)) {
                $slot = $matches[1] ?? '';
                return array(
                    'identity' => $pattern['name'] . $slot,
                    'name'     => $pattern['name'],
                    'slot'     => $slot,
                );
            }
        }
        return null;
    }

    /**
     * @return array{identity: string, name: string, slot: string}|null
     */
    private function matchWorktreeIdentity(string $worktree): ?array
    {
        foreach ($this->config->getIdentities() as $name => $identity) {
            if (!is_array($identity)) {
                continue;
            }
            $prefix = $identity['worktree_prefix'] ?? '';
            if ($prefix === '') {
                continue;
            }
            $pattern = '#/' . preg_quote($prefix, '#') . '([0-9]+)$#';
            if (preg_match($pattern, $worktree, $matches)) {
                return array(
                    'identity' => $name . $matches[1],
                    'name'     => $name,
                    'slot'     => $matches[1],
                );
            }
        }
        return null;
    }

    /**
     * @return array<int, array{hash: string, subject: string, email: string, timestamp: int}>
     */
    private function getCommits(string $baseRef, string $headRef): array
    {
        $range = escapeshellarg("{$baseRef}..{$headRef}");
        $format = '%H%x1f%s%x1f%ae%x1f%ct%x1e';
        $output = shell_exec("git log {$range} --no-merges --pretty=format:{$format} 2>/dev/null") ?: '';

        $commits = array();
        foreach (explode("\x1e", $output) as $raw) {
            $raw = trim($raw);
            if ($raw === '') {
                continue;
            }
            $parts = explode("\x1f", $raw, 4);
            if (count($parts) < 4) {
                continue;
            }
            $commits[] = array(
                'hash'      => substr($parts[0], 0, 8),
                'subject'   => $parts[1],
                'email'     => $parts[2],
                'timestamp' => (int) $parts[3],
            );
        }

        return $commits;
    }

    private function getWorktreeNote(string $hash): ?string
    {
        $hash = escapeshellarg($hash);
        $notesRef = escapeshellarg($this->config->getGitNotesRef());
        $note = shell_exec("git notes --ref={$notesRef} show {$hash} 2>/dev/null") ?: '';
        $note = trim($note);
        return $note === '' ? null : $note;
    }

    private function parseWorktreeFromNote(string $note): ?string
    {
        foreach (explode("\n", $note) as $line) {
            if (strpos($line, 'worktree:') === 0) {
                return trim(substr($line, strlen('worktree:')));
            }
        }
        return null;
    }
}
