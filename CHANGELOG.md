# Changelog

## 1.0.0 - 2026-08-27

- Add live provider lookup via the NPPES NPI registry API.
- Search individuals by name or organizations by name, with an optional state
  filter and direct lookup of a ten-digit NPI.
- Read "Last, First" as well as "First Last", and prefix-match partial names.
- Copy an NPI to the clipboard with Enter, keeping the panel open for the next
  lookup.
- Show primary taxonomy, licence, practice location, phone, and a deactivated
  enumeration warning per result.
- Surface the former or other name that a search matched on.
- Add `lookup`, `lookupIn`, and `copy` IPC methods so a keybinding or script
  can drive the widget; `lookupIn` picks the record type up front.
- Add native Omarchy components and a theme-aware Nerd Font bar icon.
- Clear the search field along with the rest of the panel state, so repeating
  a query after closing the panel searches instead of silently doing nothing.
- Replay a lookup that arrives while a request is in flight rather than
  dropping it, so the newest query wins.
- Clear query and results on close and show public-registry guidance.
