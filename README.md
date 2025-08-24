![](resources/snapline_v1.png)

Prompt theme for Windows+cmd+Clink focusing on speed and concise info using caching and async techniques to ensure snappiness at all times.

## Speed
  * Use only sub-millisecond calls to render the prompt.
  * Async all delays so editing is never blocked.
  * Cache last results so info is always present.
## Info
### Left prompt
  * virtual environment in yellow
  * git branch
  * git in-progress action
  * current working directory
    * no-repo in white
    * clean in green
    * dirty in red (untracked files found)
### Right prompt
  * git status glyphs
  * duration of the last executed command
  * current time
## git
  * branch
    * clean in green
    * dirty in red
    * no-repo in white
  * in-progress action glyph in yellow for

![](resources/action_legend.png)

  * status

![](resources/status_legend.png)

## Examples

* on dirty branch 'heureka', dir is clean, 1 file modified, 1 new file, 2 stash items
![](resources/ex-1.png)

* active virtual environment 'env1', branch and dir are clean, branch is 1 commit ahead and 2 behind the origin
![](resources/ex-2.png)

* virtual env 'env1', branch 'feat1' in dirty state, merge action in progress, dir is clean, 1 conflicted file, 1 new file
![](resources/ex-3.png)

## Installation

Copy the ```.lua``` file into Clink configuration folder. Ensure terminal uses Nerd Fonts.
