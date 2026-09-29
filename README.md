# ScratchPad

An always-there scratch pad in the Omarchy bar.

Click the notebook icon in the bar and a panel drops down with a notepad at the
top and your notes underneath. Type straight into it, or copy something
anywhere on the system and paste it in. Later, click any note to inject it into
whatever field you happen to be typing in.

Built on the same ideas as [SuperClip](https://github.com/RobbieUK1/omarchy-superclip):
the same panel shell, the same focus-aware paste, the same store and image
preview. ScratchPad adds the notepad that is always there, and a clipboard
*reader* (SuperClip only ever wrote to the clipboard).

## Install

```sh
omarchy plugin add https://github.com/RobbieUK1/omarchy-scratchpad.git --enable
omarchy restart shell
```

Right-click your bar -> **Configure bar** (or edit `~/.config/omarchy/shell.json`)
and add the widget to a section:

```json
"right": [
  { "id": "robbie.scratchpad" }
]
```

Requires `wl-paste` and `jq` (both ship with Omarchy) for pasting and for
terminal-aware injection.

## Using it

### The notepad

The box at the top of the panel has keyboard focus the moment the panel opens,
so you can start typing immediately.

| Key            | Does                                                      |
|----------------|-----------------------------------------------------------|
| `Ctrl+Enter`   | Save the draft as a note (or update, when editing)          |
| `Ctrl+V`       | Paste from the clipboard into the box                      |
| `Ctrl+Shift+V` | Paste, forcing the image path                               |
| `Ctrl+F`       | Jump to the search box                                      |
| `Esc`          | Clear the draft, then close the panel                       |

A note's title is taken from its first non-empty line, so notes stay scannable
in the list. Multi-line text (code, shell one-liners, a command with flags) is
kept verbatim and rendered with its own line breaks intact.

### The box grows as you type, then scrolls

The notepad starts small — a few lines — and expands to fit whatever you put in
it, easing open over about 120ms. Clear it and it shrinks back. What it takes
in height comes out of the list below, so the panel itself stays the same size
and doesn't jump around while you write.

Once the text passes roughly 13 lines the box stops growing and starts
scrolling instead, with a slim scrollbar down the right edge so there's no
mystery about how much is left. Scroll it with the wheel or by dragging the
bar. The three numbers behind this are `editorMinH`, `editorMaxH` and
`listCap` near the top of `ScratchPad.qml` if you want to tune them.

### Opening it from the keyboard

The panel registers the same IPC target every built-in Omarchy panel uses, so
it can be bound to a key or driven from a terminal:

```sh
qs --path /usr/share/omarchy/shell ipc call robbie.scratchpad compose  # open, ready to type
qs --path /usr/share/omarchy/shell ipc call robbie.scratchpad toggle   # open or close
```

To bind `compose` to a key, add it to your Hyprland config:

```ini
bind = $mainMod, N, exec, qs --path /usr/share/omarchy/shell ipc call robbie.scratchpad compose
```

### Pasting into the pad

`Ctrl+V` reads whatever is on the clipboard:

- **Text** goes into the box at the cursor, with newlines preserved.
- **An image** is written to `~/.local/state/omarchy/scratchpad/` and added to
  the list straight away. Qt's QML clipboard API cannot put an image into a
  `TextEdit`, so this path is done by hand with `wl-paste`.

When the clipboard offers both (browsers often attach an HTML fallback to
"Copy image"), text wins so a `Ctrl+V` pastes what you expect. Use the
**Paste image** button, or `Ctrl+Shift+V`, to force the image.

Supported image types, in preference order: `png`, `jpeg`, `webp`, `bmp`, `gif`,
`tiff`, `avif`, `x-icon`, then any other `image/*`.

### The list

| Action       | Does                                                       |
|--------------|------------------------------------------------------------|
| Click a row  | Inject it into the field you were last typing in            |
| Copy         | Copy to the clipboard only, without stealing focus          |
| Pencil       | Load the note back into the notepad to edit                 |
| Trash        | Delete the note (and its image file, if it has one)         |

Hover an image note for a large floating preview. The preview sits beside the
panel, and flips to the other side if the panel is pinned to the left edge.

New notes go to the top of the list. The list scrolls, and the panel is capped
at 560px so a long pad never runs off the bottom of the screen.

### How injection works

Clicking a row copies the note, hands focus back to the window you came from,
and sends that window's paste key. Terminals get `Shift+Insert`, everything
else gets `Ctrl+V` — detected by asking Hyprland whether the active window is
tagged `terminal`. This is the same mechanism SuperClip uses.

## Where your data lives

| What  | Where                                                    |
|-------|----------------------------------------------------------|
| Notes | `~/.config/omarchy/scratchpad.json`                      |
| Images| `~/.local/state/omarchy/scratchpad/`                     |

Notes are a plain JSON array, so you can read, edit, back up or version them
with any text editor. Deleting an image note only unlinks the file if it lives
under the scratchpad media directory, so a note pointing at an image elsewhere
on disk never deletes your file.

## Troubleshooting

**The panel won't open.** Check the shell log:

```sh
journalctl --user -f | grep -i scratchpad
```

**An injected snippet lands in the wrong place.** The paste goes to whatever
window was focused before the panel opened. If you opened the pad from a
notification or a menu, focus the target field first, then use the **Copy**
button and paste manually.

**Nothing appears when I paste an image.** Some applications put images on the
clipboard as a `file://` list rather than raw bytes, which `wl-paste` cannot
read as image data. Copy the image from a browser or an image viewer (Firefox's
"Copy Image" offers `image/png`) and try again.

## Credits

Panel, injection plumbing and store handling derived from
[omarchy-superclip](https://github.com/RobbieUK1/omarchy-superclip).

## License

MIT
