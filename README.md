# custom-zsh

Personal Zsh utilities and interactive terminal helpers:

- `git-gusto.sh`: Git workflow manager, exposed as `gg`
- `ssh-connettersi.sh`: SSH manager, exposed as `ssi`

## Features

### Git Gusto

`git-gusto.sh` provides the `gg` command, an interactive Git workflow manager powered by [`gum`](https://github.com/charmbracelet/gum).

- initializes new repositories on `main`
- adds or updates `origin`
- stages, commits, and pushes with `gg ship`
- uses Conventional Commit prompts
- sets upstream with `git push -u origin <branch>` on first push
- asks to rename `master` to `main` before pushing
- manages branches, tags, worktrees, fetch, pull, push, merge, and search

Menu features:

- `Fetch`: fetch `origin` or all remotes with pruning
- `Ship`: stage all changes, create a commit, and push
- `Search`: search commits, branches, and tags
- `Branch`: list, switch, create, and delete branches
- `Tag`: list, add, and remove tags
- `Worktree`: add, remove, open, and list worktrees
- `Status`: view repository status
- `Remote`: add or update `origin`
- `Pull`: pull with rebase or merge
- `Merge`: merge from local, remote, or all branches with default, no-ff, or squash mode

### SSH Connettersi

`ssh-connettersi.sh` provides the `ssi` command, an interactive SSH manager powered by `gum`.

- connects to hosts from `~/.ssh/config`
- lists, searches, adds, removes, and tests hosts
- generates, lists, removes, and displays SSH public keys
- adds keys to `ssh-agent`, including macOS Keychain support
- shows agent status and clears loaded keys
- views resolved host config with `ssh -G`
- opens `~/.ssh/config` with Kiro or `$EDITOR`
- creates timestamped config backups before editing

Menu features:

- `Connect`: search configured hosts and connect
- `Hosts`: list, search, add, remove, and test SSH hosts
- `Keys`: list keys, show public keys, generate keys, remove keys, add keys to agent, and remove keys from agent
- `Agent`: show status, load keys, unload keys, and clear the agent
- `Config`: view resolved host config, open `~/.ssh/config`, and reload the host cache

## Usage

### `git-gusto.sh`

Common entrypoint:

```zsh
source /Users/chattonmai/.config/zsh/git-gusto.sh
gg
```

Useful commands:

```zsh
gg init      # Initialize a repository
gg remote    # Add or update origin
gg ship      # Stage, commit, and push
gg push      # Push current branch
gg status    # Show repository status
```

Expected first-time flow:

```zsh
git init -b main
git remote add origin https://github.com/chattonmai/custom-zsh.git
git push -u origin main
```

### `ssh-connettersi.sh`

Common entrypoint:

```zsh
source /Users/chattonmai/.config/zsh/ssh-connettersi.sh
ssi
```

Useful commands:

```zsh
ssi            # Open the full SSH menu
ssi connect    # Search hosts and connect
ssi <alias>    # Connect directly to a known SSH host
ssi help       # Show help
```

Notes:

- `~/.ssh/config` is the source of truth
- config backups are written as `~/.ssh/config.bak.<timestamp>`
- included SSH config files are not modified by the helper

## Requirements

- `zsh`
- `git`
- `gum`
- `ssh`
- `ssh-keygen`
- `ssh-add`

Install `gum` with Homebrew:

```zsh
brew install gum
```

## Reload

After changing these scripts, reload them in the current shell:

```zsh
source /Users/chattonmai/.config/zsh/git-gusto.sh
source /Users/chattonmai/.config/zsh/ssh-connettersi.sh
```
