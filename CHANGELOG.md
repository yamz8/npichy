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
- Add `lookup` and `copy` IPC methods so a keybinding or script can drive the
  widget; `lookup` takes an optional record type as its second argument.
- Add native Omarchy components and a theme-aware Nerd Font bar icon.
- Clear query and results on close and show public-registry guidance.
