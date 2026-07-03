<?php
declare(strict_types=1);

/**
 * Agent Guard configuration loader.
 *
 * Reads agent-guard.yaml as the SSOT, falling back to .hmvip-agent-guard.json
 * when the YAML file is missing or cannot be parsed.
 */

namespace AgentGuard\Core;

final class Config
{
    /** @var array<string, mixed>|null */
    private ?array $data = null;

    private string $repoRoot;

    public function __construct(?string $repoRoot = null)
    {
        $this->repoRoot = $repoRoot ?: $this->detectRepoRoot();
    }

    /**
     * @return array<string, mixed>
     */
    public function all(): array
    {
        if ($this->data === null) {
            $this->data = $this->load();
        }
        return $this->data;
    }

    public function get(string $key, mixed $default = null): mixed
    {
        $data = $this->all();
        $parts = explode('.', $key);
        foreach ($parts as $part) {
            if (!is_array($data) || !array_key_exists($part, $data)) {
                return $default;
            }
            $data = $data[$part];
        }
        return $data;
    }

    public function getGitNotesRef(): string
    {
        return (string) $this->get('git.notes_ref', 'refs/notes/agent-guard-worktree');
    }

    public function getProtectedBranches(): array
    {
        return (array) $this->get('git.protected_branches', array('main', 'master', 'develop'));
    }

    public function getMainRepo(): string
    {
        $legacy = $this->get('paths.main_repo');
        if ($legacy !== null) {
            return (string) $legacy;
        }
        return (string) $this->get('worktrees.main_repo', getcwd() ?: '.');
    }

    public function getWorktreeBaseDir(): string
    {
        $legacy = $this->get('paths.base_dir');
        if ($legacy !== null) {
            return (string) $legacy;
        }
        return (string) $this->get('worktrees.base_dir', dirname($this->getMainRepo()));
    }

    public function getSessionStorage(): string
    {
        $legacy = $this->get('paths.session_storage');
        if ($legacy !== null) {
            return (string) $legacy;
        }
        return (string) $this->get('session.session_storage', '.agent-guard/sessions');
    }

    public function getHooksPath(): string
    {
        $legacy = $this->get('paths.hooks_path');
        if ($legacy !== null) {
            return (string) $legacy;
        }
        return (string) $this->get('git.hooks_path', '.githooks');
    }

    /**
     * @return array<string, array<string, mixed>>
     */
    public function getIdentities(): array
    {
        $identities = $this->get('identities', array());
        return is_array($identities) ? $identities : array();
    }

    public function getIdentityNames(): array
    {
        return array_keys($this->getIdentities());
    }

    public function getAuthorEmailTemplate(string $identityName): string
    {
        $identity = $this->getIdentities()[$identityName] ?? array();
        return (string) ($identity['author_email'] ?? 'agent-{n}@example.dev');
    }

    public function getAuthorNameTemplate(string $identityName): string
    {
        $identity = $this->getIdentities()[$identityName] ?? array();
        return (string) ($identity['author_name'] ?? 'Agent {n}');
    }

    public function getSlots(string $identityName): int
    {
        $identity = $this->getIdentities()[$identityName] ?? array();
        return (int) ($identity['slots'] ?? 0);
    }

    public function getWorktreePrefix(string $identityName): string
    {
        $identity = $this->getIdentities()[$identityName] ?? array();
        return (string) ($identity['worktree_prefix'] ?? 'agent-{name}');
    }

    public function getCommitMessagePattern(): string
    {
        return (string) $this->get(
            'commit.message_pattern',
            '^(feat|fix|docs|refactor|chore|test|ci|hotfix)(\(.+\))?: .+'
        );
    }

    /**
     * @return array<string, mixed>
     */
    private function load(): array
    {
        $yamlPath = $this->repoRoot . '/agent-guard.yaml';
        if (is_file($yamlPath)) {
            $parsed = $this->parseYaml($yamlPath);
            if ($parsed !== null) {
                return $parsed;
            }
        }

        $jsonPath = $this->repoRoot . '/.hmvip-agent-guard.json';
        if (is_file($jsonPath)) {
            $content = file_get_contents($jsonPath);
            if ($content !== false) {
                $parsed = json_decode($content, true);
                if (is_array($parsed)) {
                    return $parsed;
                }
            }
        }

        return array();
    }

    /**
     * @return array<string, mixed>|null
     */
    private function parseYaml(string $path): ?array
    {
        $command = sprintf(
            'python3 -c %s %s 2>/dev/null',
            escapeshellarg('import json, sys, yaml; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)'),
            escapeshellarg($path)
        );
        $output = shell_exec($command);
        if ($output === null || $output === '') {
            return null;
        }
        $decoded = json_decode($output, true);
        return is_array($decoded) ? $decoded : null;
    }

    private function detectRepoRoot(): string
    {
        $output = shell_exec('git rev-parse --show-toplevel 2>/dev/null');
        if ($output !== null) {
            $root = trim($output);
            if ($root !== '') {
                return $root;
            }
        }
        return getcwd() ?: '.';
    }
}
