# DevOps Board

An Omarchy shell plugin that shows your Azure DevOps team's sprint in a
keyboard-driven window: every work item the iteration touches, from the
Epic or Feature above it down to the Tasks beneath it, how far through the
sprint you are, and an editor for any of them.

- **Board**: the full backlog hierarchy nested under each other — Epic >
  Feature > Story/Bug > Task — in backlog order, with state glyphs (○ to
  do, ◐ in progress, ● done), roll-up progress bars and counts, points on
  stories, remaining hours on tasks, and assignee initials, with your own
  items highlighted. A bar across the top shows tasks done or in progress,
  plus a marker for today's position in the sprint. Toggle **Backlog**
  (Ctrl+B) to show every active item in the project instead of just the
  current sprint — handy when nothing's been planned yet.
- **Editor**: title, state, assignee, story points / effort or remaining
  hours, priority, tags, description (or repro steps) and acceptance
  criteria. It also shows the parent and child items and the discussion, and
  you can add comments. Only the fields you change are sent. The save checks
  the item's revision so it can't overwrite someone else's edit.
- Works with the Agile, Scrum and CMMI processes and their custom
  inheritances. States and fields are read from the process.

![The board with demo data: a sprint of user stories and a bug, tasks nested underneath, sprint progress and assignee initials](preview.png)

## Keys

| Where | Keys |
|---|---|
| Board | type to filter · ↑↓ move · → ← expand / collapse · Enter open · Tab all / mine · Ctrl+← → sprint · Ctrl+B backlog · Ctrl+T team · Ctrl+R refresh · Ctrl+H hide closed · Ctrl+O open in browser · Ctrl+, connection · Esc clear filter |
| Editor | Tab next field · Ctrl+S save · Ctrl+Enter post comment · Ctrl+R reload · Ctrl+O browser · Esc leave field, then back |

Rich text is edited as light markdown: paragraphs, `- ` and `1. ` lists,
`#` headings, `**bold**`, `*italic*` and `[links](https://…)`. A description
containing images or tables is read-only here (Ctrl+O edits it in the
browser), so nothing is lost in the round trip.

## Requirements

- [Omarchy](https://omarchy.org) 4 (the Quickshell-based shell with plugins).
  Python 3 is included with Omarchy.
- `secret-tool` (libsecret) and a running keyring such as GNOME Keyring, to
  store the access token. Without it, set `AZURE_DEVOPS_EXT_PAT` instead.
- An Azure DevOps organization and a personal access token (see below).

## Install

```sh
omarchy plugin add https://github.com/abdullahazmy/omarchy-devops-board.git --enable
```

The **DevOps Board** bar widget can be added from Omarchy's bar settings. Update
with `omarchy plugin update funcoder.devops-board`.

Once enabled, the board also appears under **Apps** in the Omarchy menu and in
the app launcher: at startup the plugin writes
`~/.local/share/applications/funcoder-devops-board.desktop`. Delete that file
if you remove the plugin.

The board is a normal Hyprland window (title `DevOps Board`): it tiles, moves
between workspaces and closes with Super+W. Its layout adapts to narrow tiles.
`summon` opens it, or focuses it if it's already open. Bind a key in
`~/.config/hypr/bindings.lua` and run `hyprctl reload`:

```lua
o.bind("SUPER + SHIFT + PERIOD", "DevOps board", "omarchy-shell shell summon funcoder.devops-board '{}'")
```

## Setup

On first open, step 1 asks for access: your organization (a URL like
`https://dev.azure.com/contoso`, or paste any Azure DevOps URL) and a personal
access token with **Work Items (Read & write)** and **Project and Team
(Read)**. The token is kept in the desktop keyring (`secret-tool`);
`AZURE_DEVOPS_EXT_PAT` is used when the keyring has none. Step 2 lists every
team the token can see, with its project; pick yours (Ctrl+T switches later).
"Try with demo data" shows a sample sprint without connecting.

## Remove

Disconnect from the connection screen (Ctrl+,) first to delete the token from
the keyring, then:

```sh
omarchy plugin remove funcoder.devops-board
rm -rf ~/.config/funcoder-devops-board ~/.cache/funcoder-devops-board   # optional: settings and cache
```

Also delete the key binding from `~/.config/hypr/bindings.lua`.

## Files

| Path | Contents |
|---|---|
| `~/.config/funcoder-devops-board/config.json` | organization, chosen team and its project, you |
| `~/.cache/funcoder-devops-board/` | last board per sprint (opens instantly), states, fields, team members |

## Command line

Everything goes through `devops.py`, which prints JSON:

```bash
H=~/.config/omarchy/plugins/funcoder.devops-board/devops.py
$H status
$H teams
$H board                       # current sprint; --iteration <id> for another
                                  # walks parents, so Epics and Features above
                                  # the iteration's items show too
$H board --backlog              # every active item in the project (not just
                                  # what's in the current sprint)
$H item 4812
echo '{"changes":{"state":"Active"}}' | $H update 4812
omarchy-shell funcoder.devops-board item 4812   # open the card on an item
```

## Development

`./deploy-local.sh` copies a checkout into `~/.config/omarchy/plugins` and
validates it. Re-run it after editing. If QML changes don't show up, run
`omarchy restart shell`.
