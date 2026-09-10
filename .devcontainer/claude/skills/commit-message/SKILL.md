---
name: commit-message
description: Formatting rules for git commit messages. Use whenever creating a git commit (git commit), in any repository, so the message format doesn't need to be specified each time.
model: sonnet
---

# Commit message format

When running `git commit`:

- Write a single concise line (no body, no bullet points) unless the user explicitly asks for more detail.
- Use imperative mood (e.g. "Fix", "Add", "Remove"), matching the repository's existing commit log (`git log --oneline`).
- Do NOT add a `Co-Authored-By` trailer.
- Do NOT add an AI-generated-content notice or similar footer.

If the repository has its own commit conventions (a `CLAUDE.md`, a `CONTRIBUTING.md`, a commitlint config, a consistent style in `git log`), those take precedence over the defaults above.
