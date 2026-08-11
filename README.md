# migrate-exe-vm 🚀

> One command to spin up a fresh [exe.dev](https://exe.dev) VM **and** carry your whole shell brain over to it — dotfiles, credentials, `ble.sh`, tmux, and a couple of quality-of-life tricks that make the terminal feel like home.

```bash
create_vm kms-proxy-explainer
```

That single line provisions a brand-new cloud VM, waits for it to boot, and rsyncs a curated slice of your environment onto it — with backups, dependency installs, and validation. No more "fresh machine, blank prompt, where are all my aliases" energy.

---

## Why this exists

Every time I asked exe.dev for a new VM, I got a beautiful, *pristine*, and completely **amnesiac** machine. Fresh Ubuntu, default bash, a 2000-line tmux scrollback, and — most annoyingly — **none of my credentials**. My Composio API key, my `~/.netrc`, my SSH identity: all gone. I'd spend the first ten minutes of every new box re-teaching it who I was.

So I wrote `migrate-exe-vm.sh` (aliased to `create_vm`) to do it once, correctly, every time.

### The exe.dev design decision that started all this

Here's the thing worth appreciating: **exe.dev almost certainly refuses to carry your secrets to the next VM on purpose.**

When you run `ssh exe.dev new`, you get a genuinely clean machine. Your Composio API key from the last box does **not** ride along. At first this feels like a missing feature — "why won't it just remember my stuff?" — but it's actually a *good* security posture:

- **Blast radius containment.** If one VM is compromised, the secret material doesn't automatically propagate to every future VM you spin up. Each machine starts from zero trust.
- **No implicit secret sprawl.** A platform that silently copied your `COMPOSIO_API_KEY`, cloud tokens, and SSH keys into every new VM would be quietly duplicating your most sensitive material across ephemeral infrastructure you may forget to tear down. That's how keys leak.
- **Ephemerality by default.** exe.dev VMs are meant to be disposable. Disposable machines shouldn't be trusted vaults. Making secret-transfer an *explicit, opt-in action* keeps the default safe.

In other words, exe.dev made secrets **your** decision to move, not theirs to assume. This tool is that explicit, consenting action — it copies credentials **only because I told it to**, with a loud confirmation prompt, and it *never* copies `authorized_keys` or `known_hosts` so it can't accidentally hijack the new machine's login trust.

> **The philosophy this repo adopts:** the platform should be secure-by-default and amnesiac; the *human* should be the one who deliberately says "yes, carry my keys forward." The friction is the feature. This script just makes that deliberate act ergonomic.

And of course — the script itself is careful with secrets too. The Composio env, SSH private keys, tokens, and `.netrc` are all `.gitignore`d, so **none of my credentials ever land in this repository.**

---

## What gets carried over

| Item | What it is | Why it matters |
|------|-----------|----------------|
| `.bashrc` / `.bash_aliases` / `.blerc` / `.inputrc` | Shell config + `ble.sh` tuning | The muscle memory: aliases, prompt, completion |
| `.local/bin/` | Personal scripts | The little tools you forgot you rely on |
| `ble.sh` | Rich bash line editor | Inline autosuggestions, syntax highlighting |
| Credentials *(opt-in)* | `~/.config/composio/env`, SSH keys, `~/.netrc` | So the new box can actually *do* things |
| tmux config | Scrollback + mouse | Covered in detail below 👇 |

Everything is **backed up with a timestamp** on the destination before anything is overwritten, and shell files are `bash -n` syntax-checked after landing.

---

## The three quality-of-life tricks

These are the small things that, once you have them, you never want a terminal without. The script makes sure every new VM is born with them.

### 1. 🌀 The Fibonacci-accelerating backspace

Holding backspace to delete a long path or a mistyped command, one character at a time, is death by a thousand cuts. So `.bashrc` rebinds Backspace (`\C-?` and `\C-h`) to a function that **accelerates the deletion the longer you hold it** — following the Fibonacci sequence.

```
Deletion speed:  1 → 2 → 3 → 5 → 8 → 13 → 21 → 34   characters per keypress
```

The clever bits:

- **It detects a *held* key by timing.** If two backspace events land less than one second apart (measured via `EPOCHREALTIME`), they count as part of the same "streak." Let go, and the streak resets.
- **It ramps up *gradually*, not instantly.** Each Fibonacci speed is held for **seven repeats** (`stage = streak / 7`) before advancing. So a quick tap deletes exactly one character like normal — the acceleration only kicks in when you're clearly holding it down to nuke a big chunk of text.
- **It's capped** at stage 7 (34 chars/press) so it never runs away from you, and it never deletes past the start of the line.

The result: single taps stay precise, but *holding* backspace feels like the cursor gains momentum — gentle at first, then fast. It's the difference between chipping at a wall and knocking it down.

### 2. 🖥️ `new` and `attach` — tmux without the flag-memorization tax

Nobody should have to remember `tmux new-session -s pi` and `tmux attach-session -t pi` by heart. So `.bash_aliases` gives them human names:

```bash
alias new='tmux new-session -s pi'      # start the "pi" session
alias attach='tmux attach-session -t pi' # rejoin it later
```

Now the entire tmux workflow on a fresh box is just:

```bash
new       # first time — creates a persistent session named "pi"
# ... do work, disconnect, close your laptop, whatever ...
attach    # you're right back where you left off
```

One consistent session name (`pi`), two verbs you'll never forget. The flags live in the alias so your brain doesn't have to.

### 3. ♾️ Infinite scrollback + mouse scrolling in tmux

Fresh tmux caps scrollback at **2000 lines** and ignores your mouse. Both are fixed automatically on every new VM. The script writes (and de-duplicates) these into the destination `~/.tmux.conf`:

```tmux
set -g history-limit 1000000000   # effectively-unlimited scrollback
set -g mouse on                    # wheel/trackpad scrolls the buffer
```

Why it's needed: tango-mountain (my source VM) has **no** `.tmux.conf`, so new boxes would silently inherit tmux's 2000-line default and swallow the top of any long build log. Now the buffer is effectively bottomless and you can just *scroll* into it with the trackpad.

> **Two honest caveats:**
> - tmux has no *true* "infinite" — `history-limit` is an integer, so we use a very large one. A huge value means a pane *could* consume a lot of RAM if it actually accumulates that many lines.
> - With `mouse on`, selecting text to copy changes: scroll normally with the wheel, but hold **Option (⌥)** while dragging to select/copy (that bypasses tmux's mouse handling).

---

## Usage

```bash
# Create a new VM and migrate everything into it
create_vm my-new-box

# Reuse an existing VM instead of creating one
create_vm --no-create existing-box.exe.xyz

# Pass options through to 'ssh exe.dev new'
create_vm --exe-new-arg --cpu=4 --exe-new-arg --memory=16GB big-box

# Preview without creating or changing anything
create_vm --dry-run my-new-box

# Skip copying credentials entirely
create_vm --exclude-secrets my-new-box
```

The `create_vm` alias lives in `~/.zshrc`:

```zsh
create_vm() {
    "$HOME/Downloads/migrate-exe-vm.sh" "$@"
}
```

### How the creation step works

1. **Normalizes the name** — exe.dev requires 5–52 chars, lowercase, digits, single hyphens. So `kms_proxy_vm` → `kms-proxy-vm`, and a trailing `.exe.xyz` is stripped rather than mangled into `-exe-xyz`.
2. **Provisions** via `ssh exe.dev new --name=<name> --json` and parses the real hostname out of `.ssh_host` with `jq`.
3. **Waits** — polls SSH until the new machine actually answers (up to ~2.5 min).
4. **Migrates** — fetch → backup → push → install deps → install `ble.sh` → configure tmux → validate.

---

## Safety notes

- 🔒 **Secrets are never committed.** `.gitignore` blocks the Composio env, SSH keys, tokens, `.netrc`, and anything matching `*secret*`/`*token*`.
- 🔑 **Login trust is protected.** `authorized_keys` and `known_hosts` are always excluded, even in `--include-secrets` mode, so the tool can never clobber the destination's own login access.
- 📦 **Backups first.** Every destination file that would be overwritten is copied to `<file>.backup-<timestamp>` before the push.
- 🧪 **Validated.** Copied shell files are checked with `bash -n` on the destination.
- 👀 **Dry-run everything.** `--dry-run` shows the full plan and touches nothing.

---

## Requirements

- Local: `ssh`, `rsync`, `mktemp`, and `jq` (for parsing the VM-creation JSON)
- An [exe.dev](https://exe.dev) account reachable via `ssh exe.dev`

---

*Built because a new machine should feel like coming home, not starting over.*
