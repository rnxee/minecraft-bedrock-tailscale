# Safe First Publish

Run these commands from this repository checkout. The checkout should be separate from any live `~/minecraft-bedrock` server directory. Do not run `git init` or `git add` from the live server directory.

```bash
cd "/path/to/minecraft-bedrock-tailscale"

# Create the local repository only if this checkout is not already one.
if [ ! -d .git ]; then git init -b main; fi

# Confirm runtime state and the raw handoff export are ignored.
git check-ignore -v .env tailscale-state bvc-data data backups conversation-export.md

# Stage only public source and documentation. Do not use `git add .`.
git add .env.example .gitignore compose.yaml LICENSE README.md docs scripts

# Review exactly what will be published.
git diff --cached --check
git diff --cached --name-only
git grep -n -I -E 'renzpriela59|tail4c9810|100\.[0-9]|192\.168\.|tskey-' || true

# Commit locally before connecting a remote.
git branch -M main
git commit -m "Initial private Bedrock Tailscale server setup"

# Create an empty public GitHub repository, then replace the placeholder URL.
git remote add origin https://github.com/YOUR_GITHUB_USERNAME/minecraft-bedrock-tailscale.git
git push -u origin main
```

The explicit allowlist means the live `tailscale-state/`, `bvc-data/`, `data/`, and `backups/` directories cannot enter the first commit by accident. If Git reports that `origin` already exists, inspect it before changing anything:

```bash
git remote -v
```

Do not force-push for the first publication. If the staged-name review shows a runtime file, stop, remove it from the index with `git restore --staged -- path/to/file`, and investigate the ignore rule before committing.

