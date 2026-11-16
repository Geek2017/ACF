# Agentic CLI Fleet (ACF)

One terminal window that runs many coding agents at once, each in its own tab or split, on one Linux machine. Claude Code, Codex, Gemini CLI and Antigravity sit side by side; the fleet keeps them inside a memory and CPU budget, shows what each one is doing, and keeps a log of every conversation.

This folder is **where the fleet lives**. Its programs and its tmux config run from here: the usual home-folder paths (`~/.local/bin/agents`, `~/.local/bin/afc-*`, `~/.tmux.conf`, …) are links to the files in this folder, so an edit here is live at once (programs on their next call, the tmux config after Ctrl+B then R).

Three things stay as real files in the home folder, with a copy kept here: the resource guard (`autonice`, `jobq`, `keepawake-agents`), the systemd units, and the machine's own lists (accounts, projects, prices). They must keep working when this drive is not mounted, and the lists hold real account names. `bash _tools/collect.sh` refreshes those copies.

Moved here: 2026-11-16, on the Kubuntu 24.04 workstation.

**If this drive is not mounted or this folder is moved**, the links break and the fleet will not start. The last home-folder copies are in `~/.local/share/acf-home-backup-20261116/` with restore steps in its `README.txt`; after a move, `bash _tools/install.sh --apply` from the new place re-points the links.

## What you see

```
── [C / acct] [C5.5-Opu X] [T:265k 26% $22.24] [S0% W4%] ───────────── [↔ – □ ✕]     pane header
   ... the agent ...                                                          ▎          scrollbar
 ACF | 1 ProjectA | 2 ProjectB            [C:27%|R:47%|F:5 1.5G/12G]  ▣ 1  ◀  ▶        bottom bar
```

**Pane header**, one per split:

| Field | Meaning |
|---|---|
| `[C / acct]` | which tool (C Claude, X Codex, G Gemini, A Antigravity) and which account |
| `[C5.5-Opu X]` | model and effort: maker letter, version, 3 letters of the name, effort (L M H X) |
| `[T:265k 26% $22.24]` | tokens the chat holds, share of the model's window, cost (`~$` = estimated from list prices) |
| `[S0% W4%]` | plan limits used: 5-hour session, week (plus a per-model cap when that model is in use) |
| `[↔ – □ ✕]` | move, minimise, maximise, close: for that split |

**Bottom bar**: tabs, then machine CPU and RAM and the fleet's agent count and memory against its cap, `▣ N` when N splits are minimised, and previous / next tab.

## Keys

| Key | Does |
|---|---|
| Alt+1 … Alt+0 | jump to tab 1 … 10 |
| Alt+\ / Alt+- | split right / below, with a menu of what to start there |
| Alt+G | change the agent or account in this pane |
| Alt+M | pick the model or effort (Claude, Gemini) without the agent's own tall picker |
| Alt+J | move this split: left, right, up, down, merge under a neighbour, own column |
| Alt+H / Alt+U | minimise this split / bring a minimised one back |
| Alt+Z | maximise this split to the whole tab, and back |
| Alt+Q | close this split (asks first) |
| Alt+S / Alt+X | show another tab beside this one / send this pane to its own tab |
| Alt+N / Alt+C | add a project folder as a new tab / plain terminal tab |
| Ctrl+V | paste text or an image |
| Ctrl+click, scroll, Ctrl+click | copy a stretch longer than one screen |
| Ctrl+B then R | reload the config |

Everything with a button also lights up under the pointer and can be clicked, menus included.

## What is in this folder

"Home path" is where the machine looks for it. **link** = the home path points at this folder's file (this is the live one); **copy** = the live one is a real file at home and this is its copy.

| Path | Home path | What it is |
|---|---|---|
| `bin/agents` | link: `~/.local/bin/agents` (also as `afc`) | the launcher: opens the fleet, tabs, splits, account and split menus |
| `bin/afc-bar` | link: `~/.local/bin/` (so are all `bin/afc-*` and the two usage tools) | draws the pane header and the bottom bar's figures |
| `bin/afc-statusline` | | Claude's status-line hook: records model, effort, limits, tokens, cost per pane |
| `bin/afc-agent-info` | | the same facts for Codex, Gemini and Antigravity, read from their own chat records |
| `bin/claude-usage`, `bin/llm-usage` | | plan limits per account |
| `bin/afc-logs` | | the chat log: every thread copied into `<project>/logs/acf/`, searchable, no tokens |
| `bin/afc-min`, `bin/afc-move` | | minimise / restore, and move / merge splits |
| `bin/afc-reflow`, `bin/afc-gap` | | make Claude redraw after a resize, and close the gap its pop-ups leave |
| `bin/afc-longcopy`, `bin/afc-model-menu` | | long copy, and the Alt+M menu |
| `bin/autonice`, `bin/jobq`, `bin/keepawake-agents` | copy: `~/.local/bin/` | the resource guard: renices, caps and queues heavy jobs; keeps the machine awake while agents work |
| `lib/afc/pb.py` | link: `~/.local/lib/afc/` | reads Antigravity's binary records |
| `tmux/tmux.conf` | link: `~/.tmux.conf` | all keys, bars, hooks and the scrollbar |
| `tmux/afc-tmux-3.8.patch` | copy: `~/.local/opt/tmux-3.8/` | the changes to tmux 3.8 the fleet needs (below) |
| `tmux/src/`, `tmux/deps/`, `tmux/SHA256SUMS` | | the tmux 3.8 source, the build packages, and their checksums: what `build-tmux.sh` builds from |
| `config/agents/` | copy: `~/.config/agents/` | account lists per tool, project list, price table, labels |
| `config/systemd/user/` | copy: `~/.config/systemd/user/` | `agents.slice` (the budget), `autonice`, the chat-log timer |
| `config/autonice/rules` | copy: `~/.config/autonice/` | which programs get throttled or queued |
| `config/alacritty/` | copy: `~/.config/alacritty/` | the terminal the fleet window runs in |
| `config/claude/`, `config/gemini/` | | only the fleet's keys from those tools' settings, to merge by hand |
| `share/` | link: `~/.local/share/` | the desktop launcher, the window-raise script, the no-browser stand-ins |
| `_tools/` | | `collect.sh`, `install.sh`, `build-tmux.sh` |
| `logs/acf/` | | this folder's own chat log, written by `afc-logs` when an agent works here (raw transcripts: they name the real account) |

Not here, on purpose: sign-ins, other projects' chats and logs, and the built tmux program (it is rebuilt from `tmux/` and stays on the home disk, so tmux itself starts even without this drive).

## The tmux build

The fleet runs tmux 3.8 with five small patches (`tmux/afc-tmux-3.8.patch`), installed in `~/.local/opt/tmux-3.8` with `~/.local/bin/tmux` pointing at it. Stock tmux will run the config but loses these:

| Patch | Gives |
|---|---|
| `screen-redraw.c`, `window-copy.c` | a thin scrollbar slider (`@scrollbar-slider`) that stops short of the pane's bottom (`@scrollbar-bottom-margin`) |
| `format.c` | the column and row of a click on a pane border, so the header buttons can be told apart |
| `key-string.c`, `server-client.c` | mouse hover: `@mouse-hover on`, and bindable `MouseMoveStatus` / `MouseMoveBorder` / `MouseMovePane` |

To build it, everything needed is in this folder: the official source (`tmux/src/tmux-3.8.tar.gz`), the patch, and the four build packages (`tmux/deps/`, Ubuntu 24.04 amd64; unpacked to a temporary folder, never installed). No download and no sudo:

```bash
bash _tools/build-tmux.sh --dry-run
```

```bash
bash _tools/build-tmux.sh
```

It takes about a minute, installs into `~/.local/opt/tmux-3.8`, and keeps the previous program beside the new one. Add `--prefix <folder>` to try a build without touching the installed one. A running fleet only picks up a new build after a restart.

To change tmux itself: unpack the source, apply the patch, edit, then write the new differences back to `tmux/afc-tmux-3.8.patch` (same `orig/tmux-3.8/…` and `src/tmux-3.8/…` path style, applied with `patch -p2`) and run the build script.

## Things that will bite

- **Claude runs in classic mode** (`"tui": "default"`): that is what lets tmux keep the chat history for the scrollbar. The price is that Claude does not re-wrap on its own; `afc-reflow` and `afc-gap` press Ctrl+L for it.
- **A chat belongs to an account.** A restart reopens each chat on the account that owns it, and a new split takes the account of the pane it came from. Resuming a chat on another organisation's account makes Claude drop its earlier thinking.
- **A fleet restart stops every agent.** Chats resume; the step in progress, extra splits, minimised splits and jobs in terminal splits do not.
- **Start the fleet from the desktop**, not from inside an agent's shell: that shell's environment would leak into every agent.
- **Claude deletes its own chat files after 30 days.** `afc-logs` is the permanent copy.

## Stand-in names

One account name on the machine is not allowed in this workspace's documents. In the copied lists under `config/` it reads `acct1` (account lists, folder paths, a commented line); a few comments in `bin/` say `acct1` too, which changes nothing in how they run. The real name and the pairing live only on the machine, in `~/.config/agents/copy-names`. `collect.sh` swaps the name out of `config/` on the way in and `install.sh` swaps it back on the way out, so the live fleet is never renamed. On a machine without that map, `install.sh` installs the stand-in as the account's name. The chat log in `logs/acf/` is a raw record and is not swapped.

## Changing the fleet

- A program in `bin/`, `lib/` or `share/`, or `tmux/tmux.conf`: edit it here. It is the live file.
- A machine list, a systemd unit or the resource guard: edit the real file in the home folder, then bring the copy here up to date:

```bash
bash _tools/collect.sh --dry-run
```

```bash
bash _tools/collect.sh
```

To set a machine up to run the fleet from this folder (dry run unless `--apply` is given; links by default, `--apply --copy` for real copies):

```bash
bash _tools/install.sh
```
