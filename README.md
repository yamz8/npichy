# npichy

`npichy` is a native Omarchy bar plugin for looking up healthcare providers in
**NPPES**, the U.S. registry behind every National Provider Identifier. Type a
name, an organization, or a ten-digit NPI, and the matching records come back
live.

Each result shows the NPI, the provider's primary taxonomy and licence number,
the practice location and phone, and whether the enumeration is still active.
Pressing Enter copies the NPI to the clipboard and leaves the panel open.

## Individuals and organizations are separate searches

NPPES splits its registry in two: **NPI-1** is an individual clinician, matched
through `first_name` / `last_name`, and **NPI-2** is a practice or facility,
matched through `organization_name`. The API ANDs whatever criteria it is
given, so a request carrying both a surname and an organization name matches
nothing. The widget therefore searches one or the other, switched by the
**Record type** control, rather than pretending a single query covers both.

A ten-digit NPI bypasses this entirely — a number identifies exactly one
record, so the type and state filters are dropped from that request.

## Names

| You type | Searched as |
|---|---|
| `aalbers` | surname `aalbers*` |
| `john aalbers` | first `john*`, surname `aalbers*` |
| `Aalbers, John` | surname `Aalbers*`, first `John*` — the form directories print |
| `1942262431` | NPI number, filters ignored |

Terms of two characters or more get a trailing wildcard, so a partial name
still finds the provider. NPPES rejects a wildcard with fewer than two leading
characters, so a single letter is sent unstarred.

### Former names

NPPES matches former and other names as well as current ones. Searching
`smith` in VT returns a record named **Audette** — because Smith is her former
name. That is the registry working correctly, so rather than looking like a
mismatch, the matched name is shown on the result as `Former Name: Judy Ann
Smith`.

## Keys

| Key | Action |
|---|---|
| `Enter` | Copy the selected NPI to the clipboard (runs the search first if the query changed) |
| `Ctrl+Enter` | Open the selected record in the configured browser |
| `↑` `↓` | Move the selection |
| `Esc` | Close the panel |

Left-clicking a result copies it; right-clicking opens it. Right-clicking the
bar icon opens the NPI registry search page.

## Scripting

The widget answers on its own IPC target, so a lookup can come from a
keybinding or a script:

```bash
omarchy-shell yamz8.npichy lookup "aalbers"                    # opens the panel and searches
omarchy-shell yamz8.npichy lookup "mayo clinic" organization   # ... as an organization
omarchy-shell yamz8.npichy copy                   # copies the selected NPI, echoes it
omarchy-shell yamz8.npichy toggle                 # open / close
```

`lookup` takes an optional record type (`individual` or `organization`) as its
second argument. It returns `ok`, or `empty query` when handed nothing. `copy` returns the
NPI it put on the clipboard, or `no selection`.

## Omarchy integration

The widget uses Omarchy's native `Panel`, `BarIconButton`, `KeyboardPanel`,
`PanelHero`, `ButtonGroup`, and theme tokens. Its account-search mark is a
monochrome Nerd Font glyph, so it follows the active bar foreground color and
font instead of falling back to a colored emoji.

Runtime dependencies are `curl`, `wl-copy`, and network access to
`npiregistry.cms.hhs.gov`. No API key is needed.

## Privacy

NPPES is a public registry of *providers*, not patients. The plugin writes no
cache, history, or analytics, and clears the query and results whenever the
panel closes. Queries are still sent to CMS, so do not enter patient names,
record numbers, or other personal identifiers.

## Settings

| Setting | Values | Default |
|---|---|---|
| Record type searched first | `individual`, `organization` | `individual` |
| Default state filter | two letters, or blank | blank |
| Results shown | 5–12 | 8 |

## Install

```bash
omarchy plugin add https://github.com/yamz8/npichy
```

## Development

```bash
node --test tests/npi.test.mjs
omarchy plugin validate .
```

All URL building and response parsing lives in `NPI.js` so it can be tested
outside QML.

## License

MIT
