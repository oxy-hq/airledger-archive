/// GitHub repo configuration — sourced from the schemas repo's
/// `config.yml` and resolved at build time by brand.dart. Two roles:
///
///   1. **Hot-reload** — SchemaSync fetches view/template files from
///      `<owner>/<repo>` at `default_branch` and caches them locally, so
///      a merged PR shows up in the running app without a rebuild.
///   2. **AI assistant** — the chat's tool-using LLM uses the same token
///      to read files and open PRs against the same repo.
///
/// Optional. When absent, hot-reload is disabled and the chat's GitHub
/// tools no-op (the chat itself still works, it just can't touch the
/// repo).
class GithubConfig {
  /// PAT with `contents:rw` + `pull_requests:rw` scoped to {owner}/{repo}.
  final String token;
  final String owner;
  final String repo;

  /// Branch the app pulls schemas FROM. Usually `main`. The chat opens PRs
  /// AGAINST this branch when proposing changes.
  final String defaultBranch;

  /// Subdirectory in the repo where view/template/app YAML lives.
  /// Defaults to `views` since that's how airledger-fitness is laid out.
  final String viewsPath;

  GithubConfig({
    required this.token,
    required this.owner,
    required this.repo,
    this.defaultBranch = 'main',
    this.viewsPath = 'views',
  });

  String get repoFullName => '$owner/$repo';

  static GithubConfig fromYaml(Map<String, dynamic> m) {
    final token = m['token'] as String?;
    final owner = m['owner'] as String?;
    final repo = m['repo'] as String?;
    if (token == null || token.isEmpty) {
      throw const FormatException(
        'github.token missing (set token_var: GITHUB_TOKEN in config.yml + '
        'the env var in .env)',
      );
    }
    if (owner == null || repo == null) {
      throw const FormatException(
        'github.owner and github.repo are required',
      );
    }
    return GithubConfig(
      token: token,
      owner: owner,
      repo: repo,
      defaultBranch: (m['default_branch'] as String?) ?? 'main',
      viewsPath: (m['views_path'] as String?) ?? 'views',
    );
  }
}
