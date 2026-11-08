# AI review guidelines — automation-pipelines

Review Jenkinsfiles and CI workflow definitions as production automation code.

- Flag pipeline syntax or control-flow defects that can prevent a job from loading or running.
- Check that shell scripts fail safely (`set -eu` or equivalent), quote variables, and do not expose credentials in logs or command output.
- Verify Jenkins credentials are loaded through `withCredentials`; never hardcode tokens, passwords, or API keys.
- Check workspace paths, repository URLs, branch/ref handling, agent assumptions, timeouts, retries, concurrency, artifact paths, and cleanup.
- Check that notification failures do not hide the original build/test failure.
- Treat PR source as untrusted. Do not recommend executing untrusted PR scripts in privileged `pull_request_target` workflows.
- Prefer actionable defects tied to changed lines. Do not report style preferences or speculative problems as bugs.
