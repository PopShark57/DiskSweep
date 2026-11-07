# Design: cleaning Duplicates and Large Files (F1, F2)

**Status:** proposal for review. Nothing here is implemented. Decision Q7 says not to widen the cleanup allowlist without a reviewed design; this is that design.

## Problem

Duplicates and Large Files can find gigabytes of reclaimable space, but neither screen can clean anything today:

- Duplicates says "Use Finder", and `selectedDuplicateFileIDs` never reaches cleanup.
- Large Files uses a single-selection `Table` with Quick Look and Reveal only.

Every cleanup goes through `CleanupEngine` with a provider authorization: a fixed, allowlisted root (validated by `SafetyValidator.isExpectedRoot`) plus a scan-time identity snapshot. There is no root that covers arbitrary files in the home folder, and the validator refuses Desktop, Documents, Pictures, Music, Movies, iCloud Drive (`Library/CloudStorage`), and more. So these files can't be cleaned without a new kind of authorization.

## Goals

1. Let a person move selected duplicate copies and selected large files to the Trash.
2. Keep every guarantee the engine gives today: no symlinks, no volume crossing, no protected locations, exact identity match with the scan, revalidation right before the move.
3. Make the result reversible: Trash only, recorded for Undo and Put Back (F3).
4. Never let the authorization widen beyond the exact files the person selected.

## Non-goals

- Permanent deletion of user files from these screens.
- Folders. Only regular files (and, later, maybe bundles; see Open questions).
- Changing the protected-location list as part of this work.

## Proposal: `UserFileSelectionAuthorization`

A new authorization kind, separate from provider authorizations:

| Property | Rule |
| --- | --- |
| Granularity | One authorization per selected file. Its "root" is the file's parent folder, and the only item it allows is that file. |
| Disposition | Always `.trash`. The engine refuses `.permanent` for this kind, regardless of what the caller passes. |
| Item kind | Regular files only (`FileIdentity.kind == .file`). Directories, packages, and symlinks are refused. |
| Identity | Required. The analyzer records a snapshot for every result it returns (Downloads already does this through `analysisSnapshotProviderID`), and cleanup needs an exact (`.strict`) match. |
| Protected locations | Unchanged: the parent folder goes through `canonicalApprovedRoot`, so Desktop, Documents, Pictures, iCloud Drive, Library data, and the rest stay refused. |
| Scope | The parent must be inside the home folder (not the home folder itself) or the per-user temporary folder, as for any approved root. |
| Content walk | Not needed for single files, but the exclusion check still runs (custom exclusions, `.git`, photo libraries via path components). |
| Allowlist size | At most the number of selected files; built at cleanup time from the selection, never persisted. |

`SafetyValidator.isExpectedRoot` gets no new location case. Instead, the engine handles the new authorization kind with its own check: "the target's parent equals the authorization's single root, and the target equals the authorized file". That keeps the existing location shapes untouched and makes the new path narrow enough to test exhaustively.

### Duplicates (F1)

- Add a `.duplicateCopies` analysis snapshot provider ID, recorded by `DuplicateAnalyzer` for files in confirmed groups.
- Enforce `DuplicateSelection.preservingOneCopy` in `AppViewModel`, not only in the view: when building cleanup items, each group must keep at least one unselected copy, or the whole group is dropped from the request.
- Recheck right before the move that the kept copy still exists and still matches its own snapshot. If it doesn't, refuse the group, because removing the others could lose the only remaining copy.
- Use `uniqueSize` (F4) to tell the person how much each removal frees; clones free almost nothing.

### Large Files (F2)

- Switch the `Table` selection to `Set<UUID>` and add checkboxes like the other lists.
- Record snapshots for result files under a `.largeFiles` analysis provider ID.
- Bundles stay "Reveal only" (Q5) until a separate decision.

### Review and scope

- New `CleanupScope` cases, `.duplicates` and `.largeFiles`, so each screen reviews and cleans exactly what its footer counts (as in 4.1).
- The review sheet lists every file (4.3) with the badge "Moved to Trash" and no disposition picker.

## What this does and doesn't widen

- **Widens:** files anywhere in the home folder outside protected locations become movable to the Trash, one selected file at a time, with an exact identity match.
- **Doesn't widen:** nothing can be deleted permanently through this path; protected locations stay protected; folders can't be targeted; no file that wasn't in the analysis result can be named.

Because the allowlist currently refuses Documents and Desktop, duplicates there would still be refused. If cleaning those is wanted, that's a separate policy decision (see Open questions).

## Testing plan

Negative tests first, all in temporary folders:

1. A selected file in a protected location (Documents, Desktop, iCloud Drive) is refused.
2. A file not in the analysis result (no snapshot) is refused.
3. A file replaced after analysis (new inode, same mtime) is refused.
4. A symlink, a folder, and a package are refused.
5. `.permanent` is refused for this authorization kind.
6. A request that selects every copy of a duplicate group is reduced to keep one, or dropped.
7. If the kept copy disappears between analysis and cleanup, the group is refused.
8. An authorization for file A can't be used for file B in the same folder.

Then positive tests: one selected duplicate and one selected large file move to a stand-in Trash (the injectable `TrashMover` from F3), and Undo restores them.

## Open questions for you

1. **Protected folders.** Should Duplicates be allowed to trash copies inside Documents or Desktop? Today's policy says no, which leaves most real duplicates (photos, PDFs) out of reach. A narrower option is allowing Trash-only moves there when another copy remains elsewhere.
2. **Bundles.** Should `.app` and `.sparsebundle` items from Downloads and Large Files become movable to the Trash under the same rules (Q5 deferred this)?
3. **External volumes.** Large Files only scans the home folder today. Should this design consider other volumes, where the Trash is per-volume?
4. **Batch limits.** Should one cleanup be capped (for example 1,000 files) to keep the review sheet reviewable?
