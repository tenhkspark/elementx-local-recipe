# Publishing checklist (for the maintainer)

This repo is kept push-ready. Do NOT run `gh repo create` as part of routine work —
creating the remote IS publishing. Follow this list when the go signal comes.

## 1. Final content scan (full worktree, including untracked files)

- [ ] No RFC1918 addresses (`192.168.*`, `10.0.*`, `172.16-31.*`)
- [ ] No real `*.ts.net` hostnames or tailnet names (grep for `ts.net`)
- [ ] No `/Users/<name>/` or `/home/<name>/` paths (grep `/Users/`, `/home/`)
- [ ] No tokens: `gho_`, `github_pat_`, `sk-`, `AKIA`, `xox*`, `Bearer `, key blocks
- [ ] No room IDs (`!`), user IDs (`@...:`), device IDs, or real usernames
- [ ] Example fixtures use RFC 5737 TEST-NET (`192.0.2.0/24`) and placeholder names
- [ ] No priority claims ("first public", "初公開")

Commands:

```
grep -rInE '([0-9]{1,3}\.){3}[0-9]{1,3}|ts\.net|/Users/|/home/|gho_|sk-|AKIA|Bearer ' . --exclude-dir=.git
grep -rInE '@[a-z0-9_.=-]+:[a-z]' .
```

## 2. Repo mechanics

- [ ] `git remote -v` empty (remote creation is part of publishing)
- [ ] author = noreply, no Co-Authored-By, no session URLs in commits
- [ ] LICENSE present (MIT)

## 3. Publish (only on explicit go)

```
gh repo create <name> --public --source=. --push --description "..."
```

- Verify the push landed by reading a file back over raw.githubusercontent.com.
- Record the publish (or any retraction) in the decisions ledger.

## 4. Unpublish path

`gh repo delete <owner>/<repo> --yes` needs the `delete_repo` scope
(`gh auth refresh -h github.com -s delete_repo`) or the web UI
(Settings → Danger Zone). Keep the local clone as the record; remove the
git remote only after deletion succeeds (confirm with a 404 from
`gh repo view`).
