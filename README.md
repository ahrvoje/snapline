![](resources/snapline_v1.png)

Prompt theme for Windows+cmd+[Clink](https://github.com/chrisant996/clink) rendering Git status while focusing on speed and concise info using caching and async techniques to ensure snappiness at all times.

## Speed
  * Uses a cached sub-millisecond render path; Git runs only when Clink asynchronous prompts are enabled.
  * Streams and time-slices status parsing to a ~1ms budget so huge outputs cannot monopolize the input thread.
  * Bounds status parsing at 100,000 changed paths by default and coalesces obsolete refreshes to at most two status processes.
  * Applies status transactionally: repository generations and before/after metadata signatures prevent stale or cross-repository results from entering the cache.
  * Refuses to fall back to blocking Git when ```prompt.async=false``` (the prompt shows ```async-off```).
  * Skips Git integration when either the working directory or Git metadata is remote/UNC because filesystem calls can block unpredictably.
  * Cache last results so the content is always & instantly present.
  * Implement alternative methods proven to run much faster.
  * Blank Enter reuses the last git status - no git process is spawned at all.
  * Status-neutral commands (```cls```, ```dir```, ```type```, ```git log```, ```git diff```, ... with no redirection) also reuse the last status - most prompts spawn nothing.
  * ```cd``` within the same repo retains the repository cache object - no field copying, blank flash, or extra git run.
  * Async status survives Enter: on a slow repo the refresh lands on a later prompt instead of being canceled and restarted by every command.
  * A short-lived idle metadata watcher notices identity/config/action/ref updates (including reftable repositories) without Clink stretching its cadence. Ref-only changes reuse the throttled untracked count. It deliberately does not scan the working tree.
  * Async status runs with ```--no-optional-locks``` so it never takes ```index.lock``` and never collides with git commands typed at the prompt.
  * Stash count is collected by the existing async porcelain status process; no synchronous stash probe or extra process is needed.
  * One-time hint to enable ```core.fsmonitor``` when git status is repeatedly slow.
  * Benchmark of Clink methods, and alternative implementations; red are only called async.
    Type ```snapline-bench``` at the prompt to re-measure on your machine.
    <img src="resources/clink_benchmark.png" width="640" style="margin-left: 50px">
## Info
### Left prompt
  * virtual environment in yellow
  * git branch
  * git in-progress action; rebase and mail-apply actions include step/total progress when available, e.g. ```Ri3/12```
  * exceptional repository markers: ```LOCK``` for an index lock, ```sh``` for a shallow clone, ```sp``` for sparse checkout, ```wt``` for a linked worktree, and ```sub``` for a submodule
  * current working directory
    * no-repo in white
    * clean in green
    * dirty in red (untracked files found)
  * last exit code in red when nonzero, e.g. ```✗1 >``` (negative codes shown as hex NTSTATUS, e.g. ```✗0xC0000005 >```)
### Right prompt
  * git status glyphs (dimmed while an async refresh is still pending, dim ```…``` while the first status for a repo is collected)
  * ```⇡?``` when an upstream is configured but ahead/behind is unknown (upstream gone, or ```ahead_behind=false```)
  * git upstream, abbreviated to the remote name when it matches the current branch
  * dim ```~3d``` when the last fetch is older than 3 days (configurable) - ahead/behind may be outdated
  * duration of every submitted line, including an exact zero as ```0ms```
  * current time
  * width-aware layout: ancillary fields are removed progressively; command duration has highest retention priority, followed by Git/stash state when space permits
## git
  * branch
    * clean in green
    * dirty in red
    * no-repo in white
  * in-progress action legend
    <p align="center"><img src="resources/action_legend.png" width="720"></p>
  * status legend
    <p align="center"><img src="resources/status_legend.png" width="600"></p>
  * type ```snapline-legend``` at the prompt to print both legends with your configured glyphs

## Examples

* on dirty branch 'heureka', dir is clean, 1 file modified, 1 new file, 2 stash items
![](resources/ex-1.png)

* active virtual environment 'env1', branch and dir are clean, branch is 1 commit ahead and 2 behind the origin
![](resources/ex-2.png)

* virtual env 'env1', branch 'feat1' in dirty state, merge action in progress, dir is clean, 1 conflicted file, 1 new file
![](resources/ex-3.png)

## Transient prompt

Past prompts can collapse to just the exit marker (```> ``` or ```✗1 > ```) with the submit time on the right, keeping scrollback compact. Opt in with:

    clink set prompt.transient always


## Configuration

All knobs live in the ```config``` table at the top of ```snapline.lua``` (reuse window, untracked scan interval, status entry bound, local/remote repository policy, repo watcher, adaptive right-prompt layout, ahead/behind counts, fetch age, duration threshold, colors, glyphs, ...). A wrapper script loaded before snapline can also define a global ```snapline_config``` table to override entries without editing the file. Partial ```color```, ```status_format```, ```action_symbol```, and ```repo_state_symbol``` tables are merged with their defaults. Invalid or unknown options are ignored with a one-time message.

## Installation

Copy the ```.lua``` file into Clink configuration folder. Ensure terminal uses Nerd Fonts. Requires Clink 1.7.0 or newer (the script silently no-ops on older versions). When another ```.clinkprompt``` is selected, Snapline automatically stands down instead of mixing two prompts.

## Tests

Run the integration-style harness with Clink's Lua runtime:

    clink lua test\harness.lua
