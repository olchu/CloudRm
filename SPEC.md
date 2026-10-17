# CloudeRm: Specification and Development Plan

## Idea

CloudeRm is a macOS app for manually freeing up space taken by local copies of iCloud Drive files.

The user picks a folder inside iCloud Drive. The app finds files that are already downloaded to this Mac, lists them, and lets the user pick individual files for the "Remove from this Mac" action. The files must stay in iCloud and remain available for download later.

## Main User Flow

1. The user opens the app.
2. Clicks "Choose Folder".
3. Picks a folder inside iCloud Drive.
4. The app scans the files in the selected folder.
5. The table shows only files whose local copy can be safely removed.
6. The user selects the files they want.
7. Clicks "Free Up Space".
8. The app asks the system to evict the local iCloud copy.
9. The user sees the result for each file: success, error, or skipped.

## MVP Non-Goals

- Do not delete files from iCloud.
- Do not try to manage every cloud provider: Google Drive, Dropbox, OneDrive.
- No automatic background cleanup.
- No daemon or menu bar helper.
- No complex disk analytics.
- Do not change the system "Optimize Mac Storage" setting.

## Key API

To remove a local copy, use:

```swift
try FileManager.default.evictUbiquitousItem(at: fileURL)
```

This action is meant for iCloud (ubiquitous) items: the local copy is removed from the device and the file stays in iCloud.

To determine a file's status, use resource values:

```swift
let values = try url.resourceValues(forKeys: [
    .isUbiquitousItemKey,
    .ubiquitousItemDownloadingStatusKey,
    .ubiquitousItemIsDownloadedKey,
    .ubiquitousItemIsDownloadingKey,
    .ubiquitousItemIsUploadedKey,
    .fileSizeKey,
    .contentModificationDateKey,
    .isDirectoryKey
])
```

Important: the available keys and their behavior can differ between macOS versions. The code must tolerate `nil` values and metadata read errors.

## MVP Architecture

Suggested modules:

- `ContentView`
  Main screen: folder picker, action bar, file table, scan status.

- `CloudFile`
  Model of one found file: id, url, displayName, relativePath, size, modificationDate, downloadStatus, selection/result state.

- `CloudFileScanner`
  Walks the selected folder recursively and returns the list of candidates.

- `CloudFileEvictor`
  Runs `evictUbiquitousItem(at:)` for the selected files and returns a result for each.

- `AppState` or `CloudFilesViewModel`
  Holds the selected folder, the file list, the selected ids, and loading/error state.

- `FileAccess`
  Handles `NSOpenPanel`, security-scoped bookmarks, and restoring access after a relaunch.

## Data Model

Minimal model:

```swift
struct CloudFile: Identifiable, Hashable {
    let id: URL
    let url: URL
    let displayName: String
    let relativePath: String
    let byteSize: Int64?
    let modificationDate: Date?
    let downloadStatus: CloudDownloadStatus
    var evictionResult: EvictionResult?
}
```

Statuses:

```swift
enum CloudDownloadStatus: Hashable {
    case downloaded
    case notDownloaded
    case current
    case downloading
    case unknown
}

enum EvictionResult: Hashable {
    case pending
    case success
    case skipped(String)
    case failure(String)
}
```

## Safety Rules

- Never use `removeItem(at:)` for the main eviction operation.
- Before evicting, check that the file is an iCloud item.
- Do not evict directories in the MVP, only files.
- Do not evict files that are actively downloading or syncing, if the status shows it.
- Show every error to the user; never hide one silently.
- Before a bulk action, show the number of files and their approximate total size.

## MVP UX

App window:

- Top bar:
  - folder picker button;
  - selected folder path;
  - rescan button.

- Summary:
  - number of downloaded files found;
  - number selected;
  - total selected size.

- Table:
  - checkbox;
  - name;
  - relative path;
  - size;
  - modification date;
  - status;
  - eviction result.

- Bottom bar:
  - "Select All";
  - "Deselect All";
  - "Free Up Space";
  - progress/status text.

Interface tone: utilitarian, calm, no marketing screen.

## Plan of Small Independent Tasks

Each task can be started in a new session. At the start of a new session it is enough to say: "Open `SPEC.md` and do task N".

### 1. Create the basic app state skeleton - done

Goal: move from `Hello, world!` to a minimal app structure.

Status: done.

Done:

- added `CloudFile.swift` and `CloudFilesViewModel.swift`;
- `ContentView` is connected to the view model;
- the start screen replaced the template `Hello, world!`;
- the project built after the change.

To do:

- create `CloudFile.swift` with the `CloudFile`, `CloudDownloadStatus`, and `EvictionResult` models;
- create `CloudFilesViewModel.swift`;
- connect the view model to `ContentView`;
- show the empty state "Choose an iCloud Drive folder".

Done when:

- the project builds;
- the window shows the initial state;
- the models compile and do not depend on the iCloud API yet.

### 2. Add folder selection with NSOpenPanel - done

Goal: the user can pick a folder to scan.

Status: done.

Done:

- added `FileAccess.swift`;
- the "Choose Folder" button opens `NSOpenPanel`;
- only folders can be selected;
- the selected `URL` is stored in the view model;
- the selected folder path is shown in the UI.

To do:

- add `FileAccess.swift`;
- implement opening `NSOpenPanel`;
- allow selecting folders only;
- store the selected `URL` in the view model;
- show the path in the UI.

Done when:

- the folder picker button works;
- the selected folder path is displayed;
- cancelling the picker does not break the state.

### 3. Add security-scoped access for the session - done

Goal: correctly read the user-selected folder in a sandboxed setup.

Status: done.

Done:

- added `FileAccess.withSecurityScopedAccess(to:perform:)`;
- the selected folder is validated through security-scoped access;
- selection and access errors are shown in the UI;
- the bookmark is not persisted between launches yet, as planned.

To do:

- wrap read operations in `startAccessingSecurityScopedResource()`;
- guarantee `stopAccessingSecurityScopedResource()`;
- handle access errors carefully;
- do not persist the bookmark between launches yet.

Done when:

- scanning can read the selected folder;
- an access error is visible in the UI;
- access is released after the operation.

### 4. Implement recursive file traversal - done

Goal: get the list of regular files inside the selected folder.

Status: done.

Done:

- added `CloudFileScanner.swift`;
- uses `FileManager.enumerator(at:includingPropertiesForKeys:options:)`;
- directories, hidden files, and package contents are skipped;
- scanning starts after a folder is selected;
- errors on individual files are counted as skipped;
- the UI shows progress while scanning.

To do:

- create `CloudFileScanner.swift`;
- use `FileManager.enumerator(at:includingPropertiesForKeys:options:)`;
- skip directories;
- skip hidden files and package contents in the first iteration;
- return an intermediate model or `CloudFile`.

Done when:

- after selecting a folder, a list of files can be obtained;
- large folders do not block the UI forever;
- errors on individual files do not crash the whole scan.

### 5. Detect a file's iCloud/ubiquitous status - done

Goal: tell iCloud files apart from regular local files.

Status: done.

Done:

- the scanner reads `.isUbiquitousItemKey`;
- regular local files do not appear in the list;
- the iCloud download status is displayed;
- metadata errors do not crash the whole scan.

To do:

- read `.isUbiquitousItemKey`;
- add a helper for reading resource values;
- skip files where `isUbiquitousItem != true`;
- add an `unknown` status when metadata is incomplete.

Done when:

- regular local files do not appear in the candidate list;
- iCloud files are recognized;
- metadata errors are shown or logged as skipped.

### 6. Keep only locally downloaded files - done

Goal: show only files that actually take up space on the Mac.

Status: done.

Done:

- the scanner reads `.ubiquitousItemDownloadingStatusKey` and `.ubiquitousItemIsDownloadingKey`;
- only the `current` and `downloaded` statuses make it into the list;
- cloud-only, downloading, and unknown files are not shown as candidates;
- UI copy now talks about local iCloud files;
- the summary shows the number of local iCloud files and their total size;
- the list is sorted by size, largest first.

To do:

- use `.ubiquitousItemDownloadingStatusKey` and/or `.ubiquitousItemIsDownloadedKey`;
- define the `isEvictableCandidate` rule;
- show only eviction candidates in the table;
- add a "found" counter.

Done when:

- already evicted cloud-only files do not appear in the main list;
- locally downloaded iCloud files do appear;
- ambiguous/unknown files are never evicted automatically.

### 7. Add the file table - done

Goal: the user sees the found files in a convenient table.

Status: done.

Done:

- found local iCloud files are shown in a `Table`;
- name, relative path, size, and status are shown;
- added a modification date column;
- added file size formatting;
- added an empty state;
- long names and paths are truncated in the middle; the full path is available as help text.

To do:

- replace the empty screen with a `Table` or `List`;
- show name, relative path, size, modification date, and status;
- add file size formatting;
- add an empty state for "nothing found".

Done when:

- found files are displayed;
- long paths do not break the layout;
- the app looks like a working macOS utility.

### 8. Add file selection - done

Goal: the user can pick specific files to evict.

Status: done.

Done:

- the `Table` is bound to `selectedFileIDs`, so rows can be selected with standard macOS selection;
- added "Select All" and "Deselect All" buttons;
- the selected count and total size are shown;
- selection is cleared after picking a new folder or rescanning.

To do:

- store a `Set<CloudFile.ID>` of selected files;
- add checkboxes or table selection;
- add "Select All" and "Deselect All";
- show the selected count and total size.

Done when:

- one, several, or all files can be selected;
- the counters update;
- after a rescan, the selection contains no ids that no longer exist.

### 9. Implement evicting a single file - done

Goal: prove the core operation on one selected file.

Status: done.

Done:

- added `CloudFileEvictor.swift`;
- before eviction, the file is re-checked as an iCloud item;
- directories, cloud-only files, and files being downloaded are not evicted;
- uses `FileManager.default.evictUbiquitousItem(at:)`;
- the UI shows the "Evict Selected" button only when exactly one file is selected;
- the table shows the eviction result per file.

To do:

- create `CloudFileEvictor.swift`;
- call `FileManager.default.evictUbiquitousItem(at:)`;
- re-check that the file is an iCloud item before the call;
- return an `EvictionResult`.

Done when:

- one selected file can be evicted;
- success/error is shown in the UI;
- the file is not deleted from iCloud.

### 10. Implement bulk eviction

Goal: apply eviction to all selected files.

To do:

- process selected files sequentially or with limited concurrency;
- show progress;
- do not stop the whole operation because one file failed;
- update each file's result.

Done when:

- several files can be evicted in one run;
- the UI stays responsive;
- the user sees the outcome: how many succeeded and how many failed.

### 11. Add confirmation before a bulk action

Goal: reduce the risk of an accidental operation.

To do:

- show an `Alert` before evicting;
- state the number of files and the total size;
- name the action explicitly: "local copies will be removed from this Mac, the files stay in iCloud";
- buttons: "Cancel" and "Free Up Space".

Done when:

- the action cannot be triggered by a single accidental click;
- the copy does not confuse eviction with deleting the file.

### 12. Rescan after eviction

Goal: the list reflects the current state.

To do:

- after a successful bulk eviction, offer to rescan or do it automatically;
- remove successfully evicted files from the candidate list;
- keep errors visible.

Done when:

- successfully evicted files disappear from the list after a refresh;
- errors stay understandable;
- the counters are correct.

### 13. Remember the selected folder between launches

Goal: the app remembers the last folder.

Status: partially done.

Already done:

- the last selected folder is saved as a security-scoped bookmark;
- on launch the app tries to restore the last folder;
- the last found file list is cached and shown right after launch;
- no automatic full scan runs on launch: the user can press "Refresh".

Remaining:

- handle a stale bookmark better and explicitly ask the user to pick the folder again;
- add a separate cache reset if needed.

To do:

- create a security-scoped bookmark;
- store the bookmark in `UserDefaults` or a small settings store;
- restore access on launch;
- handle a stale bookmark.

Done when:

- after a relaunch the app shows the last folder;
- scanning works without picking the folder again if access is still valid;
- with a stale/invalid bookmark the user is asked to pick the folder again.

### 14. Add scan cancellation - done

Goal: do not make the user wait on large folders.

Status: done.

Done:

- the view model keeps the current `scanTask`;
- the scan worker task is cancelled directly, without a nested unstructured `Task.detached`;
- starting a new scan cancels the previous task;
- stale results after cancellation are ignored through a generation guard;
- added a "Stop" button;
- the scanner calls `Task.checkCancellation()` during traversal.

To do:

- move scanning to a `Task`;
- keep the current scan task;
- add a "Stop" button;
- check `Task.isCancelled` during traversal.

Done when:

- the scan can be stopped;
- after cancelling, the app stays in a normal state;
- a scan can be started again.

### 15. Improve handling of large folders - partially done

Goal: the app does not look frozen on thousands of files.

Status: partially done.

Already done:

- the UI receives progress during the scan;
- the number of checked files is shown;
- the status shows the candidates found during traversal;
- found candidates are added to the table in batches during the scan, not only at the end;
- if candidates have already been found, the table stays visible while the scan continues;
- the main fast scan moved to `NSMetadataQuery` to use the Spotlight metadata index instead of reading every file by hand;
- added a manual "Full Scan" fallback using `FileManager.enumerator`;
- the last result is cached and shown instantly on the next launch.

Remaining:

- if needed, update found files in batches before the scan finishes;
- measure the behavior on a real large iCloud folder;
- consider depth limits or exclusions for very large trees.

To do:

- update the UI in batches;
- show the current progress at least as text: "Scanned N files";
- do not keep unnecessary heavy metadata;
- measure the behavior on a large folder.

Done when:

- the UI does not noticeably freeze;
- the user understands that the scan is running;
- memory does not grow without bound.

### 16. Add sorting and filters - partially done

Goal: the user finds large and old files faster.

Status: partially done.

Already done:

- the list is sorted by size, largest files first.

Remaining:

- add user-selectable sorting by size, date, name, and path;
- add search by name/path;
- keep the file selection while filtering (after task 8).

To do:

- sorting by size, date, name, and path;
- filter by extension or search string;
- a quick "larger than N MB" filter can wait.

Done when:

- the table can be sorted by size;
- search by name/path works;
- the file selection is kept while filtering.

### 17. Add tests for pure logic

Goal: lock in the candidate selection rules.

To do:

- extract `isEvictableCandidate` into a testable helper;
- add unit tests for the statuses;
- add tests for size formatting;
- add tests for updating the selection after a refresh.

Done when:

- tests run through Xcode/xcodebuild;
- the core filtering logic is covered;
- the UI and the real iCloud API do not need deep mocking yet.

### 18. Check sandbox/capabilities

Goal: make sure the app settings match its file access.

To do:

- check the App Sandbox entitlement;
- check the User Selected File read/write entitlement;
- decide whether the iCloud Documents entitlement is needed for this approach;
- record the outcome in `SPEC.md` or a separate `NOTES.md`.

Done when:

- the app works with the selected folder in the sandbox;
- the entitlements are understood and minimal;
- there are no unnecessary broad permissions.

### 19. Polish the first release

Goal: make the MVP pleasant for real use.

To do:

- proper button titles;
- tidy empty/error/loading states;
- disabled states for impossible actions;
- the app icon can be a separate task;
- check dark and light appearance.

Done when:

- the app can be handed to another person without a verbal explanation;
- the destructive action is worded clearly;
- the main flow works from picking a folder to seeing the result.

### 20. Prepare a manual test plan

Goal: have a checklist to run before every major change.

To do:

- create `TEST_PLAN.md`;
- describe a test with a small iCloud folder;
- describe a test with a regular local folder;
- describe a test for cancelling the picker and the scan;
- describe a test for access errors.

Done when:

- the test plan can be run by hand in 5-10 minutes;
- it checks that files are not deleted from iCloud.

## Current Status

Done:

- task 1: models and view model;
- task 2: folder selection;
- task 3: security-scoped access for the session;
- task 4: recursive traversal;
- task 5: recognizing iCloud/ubiquitous files;
- task 6: filtering locally downloaded iCloud files;
- task 7: file table, size, modification date, status, empty state;
- task 8: table row selection, "Select All", "Deselect All", selected size summary;
- task 9: evicting one selected file;
- part of task 13: remembering the last folder and caching the file list;
- task 14: scan cancellation;
- part of task 15: fast `NSMetadataQuery` scan, cache-first UI, progress while scanning large folders;
- part of task 16: sorting by size, largest first.

Current build check:

```sh
xcodebuild -project CloudeRm.xcodeproj -scheme CloudeRm -configuration Debug -derivedDataPath /private/tmp/CloudeRm-DerivedData CODE_SIGNING_ALLOWED=NO build
```

Last result: `BUILD SUCCEEDED`.

A regular signed build may depend on a local `Mac Development` certificate.

## Recommended Order for the Next Sessions

1. Task 10: bulk eviction.
2. Task 11: confirmation before a bulk action.
3. Task 12: rescan after eviction.
4. Task 13: remember the selected folder between launches.

## Risks and Open Questions

- Some iCloud metadata values may return `nil` or a stale state.
- Finder and the system may download a file again automatically if it is needed.
- The behavior of `ubiquitousItemDownloadingStatus` may differ between macOS versions.
- The App Store may require separate checks of entitlements and sandbox behavior.
- Testing must happen only on a real iCloud Drive folder, not on a synthetic local folder.

## Prompt for a New Session

Example request:

```text
Open SPEC.md and do task 1. Don't do anything extra yet.
```

Or:

```text
Open SPEC.md, look at the current code, and continue with the next unfinished task.
```
