-- snapline - fast async git status prompt renderer for clink
--         by Hrvoje Abraham ahrvoje@gmail.com

-- Legend:  conflicted=' |N'      ahead=' ⇡N'   behind=' ⇣N'   diverged=' ⇕⇡A⇣B'   tracked=' ?'
--            modified=' !N'     staged=' +N'  deleted=' XN'  untracked=' ??'     stashed=' ≡N'  renamed=' »N'
--          '⇡?' upstream set but ahead/behind unknown (upstream gone or ahead_behind=false)
--          '…' first status for this repo is still collecting     '~Nd' time since last fetch
--          '≥N' status entry limit reached (shown counts are lower bounds)
--          'async-off' Clink prompt.async is disabled, so blocking Git is suppressed
-- In-progress git state indicator (yellow unicode char): rebase/am/merge/cherry-pick/revert/bisect;
-- rebase/am operations include progress when Git exposes it, e.g. Ri3/12.
-- Repository markers: LOCK=index lock, sh=shallow, sp=sparse, wt=linked worktree, sub=submodule.
-- Exit code marker: red '✗N >' when the last command failed (negative codes shown as hex NTSTATUS)
-- Type 'snapline-legend' at the prompt to print the glyph legend for the active config.
-- Type 'snapline-bench' at the prompt to benchmark Clink git API calls vs snapline alternatives.

-- No-op outside the Clink prompt runtime (Clink 1.7.0 or newer).  Every API
-- used below is checked here once, so the rest of the file needs no guards.
if not (clink and git and settings and console and io.popenyield and os.findfiles
    and clink.promptfilter and clink.refilterprompt and clink.onbeginedit and clink.onendedit
    and clink.onfilterinput and clink.getclinkprompt and clink.runcoroutineuntilcomplete
    and clink.setcoroutineinterval and clink.setcoroutinename
    and git.getgitdir and git.getcommondir and git.getbranch and git.getaction and git.makecommand
    and os.getdrivetype and os.geterrorlevel and os.getalias and os.isfile
    and console.cellcount and console.getwidth) then
    return
end

local clock  = os.clock      -- Clink clock returning seconds with us precision
local concat = table.concat
local floor  = math.floor
local format = string.format
local getenv = os.getenv
local date   = os.date

local config = {
    -- Nerd Fonts tables: https://www.nerdfonts.com/cheat-sheet
    --
    -- 30.08.2025. Clink uses Lua 5.2 which doesn't support Unicode literals
    -- It can use UTF-8, so conversion from UTF-16 to UTF-8 is presented
    --
    -- Python convert UTF-16 to UTF-8 and back for branch symbol 
    --     list(''.encode('utf-8'))          >  [238, 130, 160]
    --     bytes([238, 130, 160]).decode('utf-8')  >  ''
    --
    -- For non-BMP glyphs contaning more than 4 unicode digits
    --     list('\U000f140b'.encode('utf-8'))           >  [243, 177, 144, 139]
    --     bytes([243, 177, 144, 139]).decode('utf-8')  >  '\U000f140b'

    branch_symbol = '\238\130\160',  -- UTF-8 code for branch glyph, UTF-16 is 'e0a0'
    error_symbol = '✗',              -- prefix of the nonzero exit code marker in left prompt
    color = {
        -- https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
        -- '\x1b' is hex ASCII 27 for Esc, '[' is Control Sequence Introducer (CSI)
        -- CSI Pm m, Ps = 3 3  =>  Set foreground color to Yellow.
        -- CSI Pm m, Ps = 3 2  =>  Set foreground color to Green.
        venv  = '\x1b[33m',             -- yellow
        state = '\x1b[33m',             -- yellow
        clean = '\x1b[32m',             -- green
        -- Ps = 3 8 : 2 : Pi : Pr : Pg : Pb  =>  Set foreground color
        -- using RGB values. If xterm is not compiled with direct-color
        -- support, it uses the closest match in its palette for the
        -- given RGB Pr/Pg/Pb. The color space identifier Pi is ignored.
        dirty = '\x1b[38;2;200;90;90m', -- red
        -- Ps = 3 8 : 5 : Ps  =>  Set foreground color to Ps, using indexed color.
        took  = '\x1b[38;5;242m',       -- gray (bright black)
        now   = '\x1b[38;5;109m',       -- dim cyan
        -- Ps = 0  =>  Normal (default), VT100.
        reset = '\x1b[0m',
    },
    -- https://chrisant996.github.io/clink/clink.html#git.getstatus
    status_format = {
        diverged   = '⇕',    -- if ahead and behind at the same time
        ahead      = '⇡%d',
        behind     = '⇣%d',
        ab_unknown = '⇡?',   -- upstream configured but counts unknown (gone or ahead_behind=false)
        pending    = '…',    -- shown while the first status for a repo is still collecting
        truncated  = '≥%d',  -- status entry limit reached; counts are lower bounds
        async_off  = 'async-off', -- prompt.async=false: never block by falling back to io.popen
        fetch_age  = '~%s',  -- time since last fetch, e.g. '~3d'
        conflicted = '\243\177\144\139%d',  -- UTF-8 code for thunder glyph, UTF-16 is 'f140b'
        staged     = '+%d',
        modified   = '!%d',
        renamed    = '»%d',
        deleted    = 'X%d',
        tracked    = '?%d',
        untracked  = '??%d',
        stashed    = '≡%d',
    },
    -- https://github.com/chrisant996/clink/blob/master/clink/app/scripts/git.lua#L732
    -- rebase-i rebase-m rebase am am/rebase merging cherry-picking reverting bisecting
    action_symbol = {
        rebase_i       = 'Ri',
        rebase_m       = 'Rm',
        rebase         = '\239\129\162',      -- UTF-16 is 'f062'
        am             = '\238\172\156',      -- UTF-16 is 'eb1c'
        am_rebase      = 'amR',
        merge          = '\243\176\189\156',  -- documented Clink action name
        merging        = '\243\176\189\156',  -- UTF-16 is 'f0f5c'
        cherry_pick    = '\238\138\155',
        cherry_picking = '\238\138\155',      -- UTF-16 is 'e29b'
        revert         = '\239\129\160',
        reverting      = '\239\129\160',      -- UTF-16 is 'f060'
        bisect         = '\243\176\135\148',
        bisecting      = '\243\176\135\148',  -- UTF-16 is 'f01d4'
        unknown        = '?',
    },
    -- Exceptional repository state.  Empty strings hide individual markers.
    repo_state_symbol = {
        index_lock = 'LOCK',
        shallow    = 'sh',
        sparse     = 'sp',
        worktree   = 'wt',
        submodule  = 'sub',
    },
    -- Seconds between full untracked-file scans.  Between full scans, Snapline
    -- uses "git status -uno" and reuses the last untracked count.  Set to 0 to
    -- scan untracked files every time, or false to disable untracked counts.
    untracked_refresh_interval = 2.0,
    -- Bound parsing work for pathological repositories.  Counts become lower
    -- bounds and the truncated marker is shown after this many changed paths.
    -- Set 0 or false to parse every entry (not recommended for interactive use).
    status_entry_limit = 100000,
    -- False ignores dirt inside submodule worktrees but still reports when a
    -- submodule HEAD differs from the commit recorded by the superproject.
    status_include_submodules = false,
    -- Ahead/behind counts require walking commit history; on long-diverged
    -- branches in big repos this can dominate status time.  Set false to add
    -- --no-ahead-behind: status shows '⇡?' when the branch differs from its
    -- upstream instead of exact counts.
    ahead_behind = true,
    profile = false,
    -- Enter on input that provably can't change git state reuses the last
    -- status without spawning git: a blank line always qualifies, and with
    -- reuse_neutral_commands also read-only commands (cls, dir, git log, ...)
    -- with no redirection.  The status is still refreshed when older than
    -- this many seconds to catch changes made from other terminals.
    -- Set 0 to always refresh.
    blank_input_reuse_age = 10.0,
    reuse_neutral_commands = true,
    -- While idle at the prompt, watch a handful of .git files (HEAD, index,
    -- packed-refs, stash log, FETCH_HEAD, ...) and refresh the status when
    -- they change, so commits made from other terminals or editors show up
    -- without pressing Enter.  A probe costs microseconds; git runs only on
    -- change.
    watch_repo = true,
    watch_interval = 2.0,
    -- Network filesystem metadata calls can block the input thread.  Git
    -- integration is therefore local-only by default; opt in explicitly when
    -- status fidelity on UNC/mapped network drives is worth the latency risk.
    enable_remote_repos = false,
    watch_remote_repo = false,
    -- Preserve high-value Git status on narrow terminals by progressively
    -- dropping ancillary right-prompt fields instead of losing everything.
    adaptive_right_prompt = true,
    right_prompt_min_gap = 4,
    -- Render status glyphs dimmed while an async refresh is pending, so
    -- stale info is visually distinct.  Color is restored when it lands.
    dim_stale_status = true,
    -- Show last exit code in the left prompt when nonzero, e.g. '✗1 >'.
    -- Negative codes are shown as hex NTSTATUS, e.g. '✗0xC0000005 >'.
    -- Requires Clink setting 'cmd.get_errorlevel' (on by default).
    errorlevel_indicator = true,
    -- When the upstream is '<remote>/<current branch>' show only '<remote>',
    -- the full upstream name is shown only when it actually differs.
    abbreviate_upstream = true,
    -- Show a dim '~<age>' after the upstream when FETCH_HEAD is older than
    -- this many seconds - a reminder that ahead/behind counts may be
    -- outdated.  Set false to disable.
    fetch_age_min = 259200,  -- 3 days
    -- Hide last-command durations below this many seconds.  Default 0 shows
    -- every submitted line, including an exact zero as '0ms'.
    min_duration_display = 0.0,
    -- Print a one-time hint when git status is repeatedly slow and
    -- core.fsmonitor is not enabled for the repo.
    fsmonitor_hint = true,
    fsmonitor_hint_threshold = 0.080,  -- seconds; status slower than this is 'slow'
    fsmonitor_hint_count = 5,          -- consecutive slow statuses before hinting
}

-- Messages printed once, at the next prompt boundary (never mid-edit, where
-- printing would corrupt the input line): config warnings, the fsmonitor
-- hint, and internal errors that would otherwise fail silently.
local notes = {}
local function note(message)
    notes[#notes + 1] = message
end

-- Optional config overrides from a wrapper script (or test harness) that
-- defines the global 'snapline_config' table before this file loads.  Nested
-- display tables are merged so changing one glyph/color cannot erase all of
-- the other required defaults.
do
    local function warn(message)
        note('snapline config: ' .. message)
    end
    local OPTIONAL_NUMBER = { untracked_refresh_interval = true, status_entry_limit = true, fetch_age_min = true }
    local NESTED = { color = true, status_format = true, action_symbol = true, repo_state_symbol = true }
    local FORMAT_SAMPLE = {
        ahead = 1, behind = 1, conflicted = 1, staged = 1, modified = 1, renamed = 1,
        deleted = 1, tracked = 1, untracked = 1, stashed = 1, fetch_age = '1d', truncated = 1,
    }
    local function expected(key, default)
        if key == 'watch_interval' then return 'a number of at least 0.05 seconds' end
        if OPTIONAL_NUMBER[key] then return 'a non-negative number or false' end
        return type(default) == 'number' and 'a non-negative number' or type(default)
    end
    local function accepts(key, value, default)
        if OPTIONAL_NUMBER[key] and value == false then return true end
        if type(value) ~= type(default) then return false end
        return type(default) ~= 'number' or value >= (key == 'watch_interval' and 0.05 or 0)
    end
    local function merge_nested(key, value)
        local defaults = config[key]
        for nested_key, nested_value in pairs(value) do
            local default = defaults[nested_key]
            if default == nil then
                warn(format('unknown option %s.%s ignored', key, tostring(nested_key)))
            elseif type(nested_value) ~= type(default) then
                warn(format('%s.%s must be %s; override ignored', key, nested_key, type(default)))
            elseif key == 'status_format' and FORMAT_SAMPLE[nested_key] and
                not pcall(format, nested_value, FORMAT_SAMPLE[nested_key]) then
                warn(format('%s.%s is not a valid format string; override ignored', key, nested_key))
            else
                defaults[nested_key] = nested_value
            end
        end
    end

    local overrides = rawget(_G, 'snapline_config')
    if overrides ~= nil and type(overrides) ~= 'table' then
        warn('snapline_config must be a table; overrides ignored')
    elseif overrides then
        for key, value in pairs(overrides) do
            local default = config[key]
            if default == nil then
                warn(format('unknown option %q ignored', tostring(key)))
            elseif NESTED[key] then
                if type(value) == 'table' then
                    merge_nested(key, value)
                else
                    warn(format('%s must be a table; override ignored', key))
                end
            elseif accepts(key, value, default) then
                config[key] = value
            else
                warn(format('%s must be %s; override ignored', key, expected(key, default)))
            end
        end
    end
end

-- ===== small helpers =====

local function trim(s)
    s = s and s:match('^%s*(.-)%s*$')
    return s ~= '' and s or nil
end

local function to_int(v)
    return tonumber(v) or 0
end

local function basename(p)
    return p and p:gsub('[\\/]+$', ''):match('([^\\/]+)$') or nil
end

local function join(...)
    return concat({ ... }, '\\')
end

local function paths_equal(a, b)
    return a == b or (type(a) == 'string' and type(b) == 'string' and a:lower() == b:lower())
end

local function path_key(p)
    return type(p) == 'string' and p:gsub('[/\\]+', '\\'):gsub('\\+$', ''):lower() or ''
end

local function repo_key(gd, common)
    return path_key(gd) .. '\0' .. path_key(common or gd)
end

-- true when any given path is on a network drive
local function any_remote(...)
    for i = 1, select('#', ...) do
        local p = select(i, ...)
        if p and os.getdrivetype(p) == 'remote' then return true end
    end
    return false
end

local function on_main_thread()
    local _, is_main = coroutine.running()
    return is_main
end

-- yield to the coroutine scheduler, but only when actually inside a coroutine
-- (snapline-bench runs the same code paths on the main thread)
local function maybe_yield()
    if not on_main_thread() then coroutine.yield() end
end

local FIND_FLAGS = { files = true, dirs = true, hidden = true, system = true, dirsuffix = false }
local function file_info(p)
    local ff = os.findfiles(p, 2, FIND_FLAGS)
    if not ff then return nil end
    local item = ff:next()
    ff:close()
    return item
end

local function file_mtime(p)
    local item = file_info(p)
    return item and item.mtime
end

-- 'size:mtime' identity stamp for files whose content never needs reading.
-- Clink mtimes have one-second precision, so refs and the index use content
-- fingerprints below instead.
local function file_stamp(p)
    local item = file_info(p)
    return item and ((item.size or 0) .. ':' .. (item.mtime or 0)) or '-'
end

-- Content identity for small Git state files, or nil when unreadable.  For
-- large files only the tail is needed: Git's index ends in an object
-- checksum, stash updates affect the last reflog entry, and reftable stack
-- updates affect tables.list's tail.
local function file_fingerprint(p, tail_bytes)
    local f = io.open(p, 'rb')
    if not f then return nil end
    local size = f:seek('end')
    local content = size and f:seek('set', size > tail_bytes and size - tail_bytes or 0) and f:read('*a')
    f:close()
    return content and (size .. ':' .. content) or nil
end

local function file_sample(p, tail_bytes)
    return file_fingerprint(p, tail_bytes) or '-'
end

local function fmt_duration(s)
    -- clock precision 1e-6
    if s == nil then return '' end
    if s <= 0 then return '0ms' end

    -- round to the display unit first so rollover can't render '1000µs' or '1m60s'
    if s < 1e-3 then
        local us = floor(s*1000000 + 0.5)
        if us == 0 then return '0ms' end
        if us < 1000 then return format('%dµs', us) end
        s = us * 1e-6
    end
    if s < 1 then
        local ms = floor(s*1000 + 0.5)
        if ms < 1000 then return format('%dms', ms) end
        s = ms * 1e-3
    end
    if s < 60 then
        local sec = format('%.2f', s)
        if sec ~= '60.00' then return sec .. 's' end
        s = 60
    end

    local total = floor(s + 0.5)
    local m, r = floor(total/60), total % 60
    if m < 60 then return format('%dm%ds', m, r) end

    local h = floor(m/60)
    return format('%dh%dm%ds', h, m % 60, r)
end

-- ===== cache =====
-- Everything the prompt renders comes from here, so a render never touches
-- git or the filesystem.  Lifetimes are nested tables rather than lists of
-- fields: cache (per cwd) > repo (per repository identity) > status (per
-- branch).  Replacing a table resets exactly its lifetime, nothing can be
-- forgotten.

local function new_status()
    return {
        text = nil,              -- rendered glyphs; '' when clean, nil before the first status
        dirty_branch = nil, dirty_dir = nil,
        at = nil,                -- clock() when the shown status was collected
        upstream = nil, upstream_prompt = '',
        untracked_at = nil, untracked_count = 0, untracked_truncated = false,
        duration = '',           -- collection time, shown with config.profile
        failed = false,          -- the last refresh did not land; status stays dimmed
        unavailable = nil,       -- marker text while prompt.async is off
        baseline = nil,          -- repo signature the shown status corresponds to
    }
end

-- Bumped by anything that may change what git status would report: a
-- mutating input line, a change seen by the watcher, a new repository
-- identity.  A collection result is applied only when the version it
-- started with is still current.
local state_version = 0

local function new_repo(gd, common, workspace_dir, root)
    state_version = state_version + 1
    local is_worktree = not paths_equal(common, gd)
    return {
        git_dir = gd, common_dir = common, workspace_dir = workspace_dir, root = root,
        key = repo_key(gd, common),
        is_worktree = is_worktree,
        is_submodule = not is_worktree and workspace_dir ~= nil and not paths_equal(workspace_dir, gd),
        remote = false,          -- cwd or git metadata on a network drive
        branch = nil,
        action = nil, action_step = nil, action_total = nil,
        state_prompt = '',       -- LOCK/sh/sp/wt/sub markers
        identity_stale = false,  -- rediscover git/common dir at the next prompt boundary
        stash_prompt = '',
        fetch_age_prompt = '', fetch_age_checked_at = nil,
        slow_count = 0,          -- consecutive slow statuses, for the fsmonitor hint
        status = new_status(),
    }
end

local function new_cache()
    return { cwd = '', venv = nil, python_prompt = '', repo = nil }
end
local cache = new_cache()
local pyvenv = {}                -- pyvenv.cfg probe cache; survives cache resets

local active = true              -- false while another .clinkprompt is selected
local session_refresh_started = false  -- one refresh decision per input line session
local last_input_neutral = false -- the last submitted line provably couldn't change git state
local last_start, last_dur_s     -- command duration measurement
local watcher = nil              -- this session's repo watcher coroutine

-- ===== python environment =====

local function extract_python_version(s)
    local major, minor = (s or ''):match('(%d+)%.(%d+)')
    return major and (major .. '.' .. minor) or nil
end

local function normalize_env_name(s)
    s = trim(s)
    return s and trim(s:match('^%((.+)%)$') or s)
end

local PYVENV_PROBE_INTERVAL = 5.0
local function pyvenv_version(venv_root)
    -- Recheck the same environment only on a short TTL; this catches in-place
    -- rebuilds without putting a file read on every prompt boundary.
    local cfg_path, now = join(venv_root, 'pyvenv.cfg'), clock()
    if cfg_path == pyvenv.path and pyvenv.checked_at and now - pyvenv.checked_at < PYVENV_PROBE_INTERVAL then
        return pyvenv.version
    end
    -- Never let a network-hosted environment stall prompt activation.  The
    -- version can still come from PYTHON_VERSION/UV_PYTHON.
    local content = nil
    local f = not any_remote(venv_root) and io.open(cfg_path, 'rb')
    if f then
        -- pyvenv.cfg is tiny by definition; cap a corrupt file so a prompt
        -- cannot allocate an unbounded Lua string.
        content = f:read(8192)
        f:close()
    end
    local version = pyvenv.version
    if cfg_path ~= pyvenv.path or content ~= pyvenv.stamp then
        local lines = content and ('\n' .. content)
        version = extract_python_version(lines and (
            lines:match('\n%s*version%s*=%s*([^\r\n]+)') or
            lines:match('\n%s*version_info%s*=%s*([^\r\n]+)')))
    end
    pyvenv.path, pyvenv.version, pyvenv.stamp, pyvenv.checked_at = cfg_path, version, content, now
    return version
end

-- venv name and python capsule from a single pass over the env vars
local function refresh_python_env()
    local virtual_env = getenv('VIRTUAL_ENV')
    local conda_env   = normalize_env_name(getenv('CONDA_DEFAULT_ENV'))
    local pyenv       = normalize_env_name(getenv('PYENV_VERSION'))
    local uv_active   = getenv('UV_ACTIVE')

    cache.venv = normalize_env_name(getenv('VIRTUAL_ENV_PROMPT'))
        or basename(virtual_env)
        or normalize_env_name(getenv('CONDA_PROMPT_MODIFIER'))
        or conda_env
        or pyenv

    local source = nil
    local version = extract_python_version(getenv('PYTHON_VERSION')) or extract_python_version(getenv('UV_PYTHON'))
    if virtual_env and #virtual_env > 0 then
        source = uv_active and 'uv' or 'venv'
        version = pyvenv_version(virtual_env) or version
    elseif conda_env then
        source = 'conda'
    elseif pyenv then
        source = 'pyenv'
        version = extract_python_version(pyenv) or version
    elseif uv_active then
        source = 'uv'
    end

    cache.python_prompt = source and
        (config.color.venv .. 'py' .. (version or '') .. ':' .. source .. config.color.reset) or ''
end

-- ===== repository identity, action and state (synchronous, prompt boundary) =====

local function refresh_identity(gd, workspace_dir, root)
    local repo = cache.repo
    local common = repo and not repo.identity_stale and paths_equal(repo.git_dir, gd) and repo.common_dir
        or git.getcommondir() or gd
    if repo and repo.key == repo_key(gd, common) then
        repo.git_dir, repo.common_dir, repo.workspace_dir, repo.root = gd, common, workspace_dir, root
        repo.identity_stale = false
    else
        repo = new_repo(gd, common, workspace_dir, root)
        cache.repo = repo
    end
    -- Passing git_dir avoids another upward directory scan.  The fast flag
    -- prevents Clink from spawning synchronous git in reftable repos;
    -- porcelain status supplies the real branch asynchronously.
    local branch = git.getbranch(gd, true)
    if branch and branch ~= '.invalid' then
        if repo.branch and repo.branch ~= branch then
            repo.status = new_status()
        end
        repo.branch = branch
    end
end

local function refresh_action(repo)
    local ok, action, step, total = pcall(git.getaction)
    repo.action = ok and action or nil
    repo.action_step = ok and tonumber(step) or nil
    repo.action_total = ok and tonumber(total) or nil
end

local function refresh_state(repo)
    local symbols, color = config.repo_state_symbol, config.color
    local parts = {}
    local function add(on, symbol, sgr)
        if on and symbol ~= '' then parts[#parts + 1] = sgr .. symbol .. color.reset end
    end
    add(os.isfile(join(repo.git_dir, 'index.lock')), symbols.index_lock, color.dirty)
    add(os.isfile(join(repo.common_dir, 'shallow')), symbols.shallow, color.state)
    add(os.isfile(join(repo.git_dir, 'info', 'sparse-checkout')), symbols.sparse, color.state)
    add(repo.is_worktree, symbols.worktree, color.state)
    add(repo.is_submodule, symbols.submodule, color.state)
    repo.state_prompt = concat(parts, ' ')
end

-- dim '~3d' reminder that ahead/behind may be outdated when the last fetch
-- (FETCH_HEAD mtime) is older than config.fetch_age_min
local FETCH_AGE_PROBE_INTERVAL = 60.0
local function refresh_fetch_age(repo, force)
    local now = clock()
    if not force and repo.fetch_age_checked_at and now - repo.fetch_age_checked_at < FETCH_AGE_PROBE_INTERVAL then
        return
    end
    repo.fetch_age_checked_at = now
    repo.fetch_age_prompt = ''
    local min_age = config.fetch_age_min
    if not min_age or min_age <= 0 then return end
    local mtime = file_mtime(join(repo.common_dir, 'FETCH_HEAD'))
    local age = mtime and os.time() - mtime
    if not age or age < min_age then return end
    local text = age >= 86400 and format('%dd', floor(age / 86400)) or format('%dh', floor(age / 3600))
    repo.fetch_age_prompt = config.color.took .. config.status_format.fetch_age:format(text) .. config.color.reset
end

-- Refresh everything synchronous once per prompt boundary, never per render.
local function refresh_runtime_cache()
    local cwd = os.getcwd() or ''
    local repo = cache.repo
    -- Blank/read-only commands in an unchanged repository reuse all identity,
    -- action and state data.  The idle watcher owns external metadata
    -- changes, so repeating synchronous filesystem probes here adds latency
    -- without improving the result.
    if cwd == cache.cwd and last_input_neutral and repo and not repo.identity_stale then
        refresh_python_env()
        return
    end
    -- A single metadata lookup on a disconnected UNC path can take far longer
    -- than the complete prompt budget.  Prefer a functional local prompt to a
    -- Git-enriched prompt that can freeze input; remote Git is explicit opt-in.
    local gd, workspace_dir, root
    if config.enable_remote_repos or not any_remote(cwd) then
        gd, workspace_dir, root = git.getgitdir()
        if gd and not config.enable_remote_repos and any_remote(gd) then gd = nil end
    end
    if cwd ~= cache.cwd then
        -- git status is repo-wide, so it stays valid across cd within the
        -- same repo: the repo object is kept and only the shown dir changes
        if not (gd and repo and paths_equal(gd, repo.git_dir)) then
            cache = new_cache()
        end
        cache.cwd = cwd
    end
    refresh_python_env()
    if not gd then
        cache.repo = nil
        return
    end
    refresh_identity(gd, workspace_dir, root)
    repo = cache.repo
    repo.remote = any_remote(cwd, gd, repo.common_dir)
    if repo.remote and not config.enable_remote_repos then
        cache.repo = nil
        return
    end
    refresh_action(repo)
    refresh_state(repo)
end

-- ===== git status via a single porcelain=v2 run =====
-- potentially slow subprocess in the focus of the entire story!
--
-- typical benchmark times for a single call ('snapline-bench' to re-measure)
--         no-repo dir                 repo dir
--
--         getaction   71µs            getaction   53µs
--         getgitdir   71µs            getgitdir   8µs
--          hasstash   74ms             hasstash   77ms   !!!
--    getaheadbehind   76ms       getaheadbehind   78ms   !!!
--         getremote   71µs            getremote   27µs
--          isgitdir   23µs             isgitdir   8µs
--         getbranch   70µs            getbranch   22µs
--     getstashcount   73ms        getstashcount   75ms   !!!
--      getcommondir   71µs         getcommondir   14µs
--         getstatus   69µs            getstatus   86ms   !!!
-- getconflictstatus   76ms    getconflictstatus   81ms   !!!
--     getsystemname   71µs        getsystemname   9µs

local function should_scan_untracked(status)
    local interval = config.untracked_refresh_interval
    if interval == false then return false end
    if interval <= 0 then return true end
    return not status.untracked_at or clock() - status.untracked_at >= interval
end

local status_commands = {}
local function status_command(scan_untracked)
    local cmd = status_commands[scan_untracked]
    if not cmd then
        -- git.makecommand runs git with --no-optional-locks, so the async
        -- status never takes index.lock and can't collide with typed git
        -- commands.  --show-stash folds stash counting into this already
        -- running process, supporting both files and reftable ref storage.
        -- "dirty" ignores expensive nested submodule worktree scans but still
        -- reports a changed submodule commit recorded by the parent.
        cmd = git.makecommand('status --porcelain=v2 --branch --show-stash' ..
            (scan_untracked and ' --untracked-files=normal' or ' --untracked-files=no') ..
            (config.status_include_submodules and '' or ' --ignore-submodules=dirty') ..
            (config.ahead_behind and '' or ' --no-ahead-behind'))
        status_commands[scan_untracked] = cmd
    end
    return cmd
end

local B_HASH, B_SPACE, B_DOT, B_QMARK = 35, 32, 46, 63
local B_1, B_2, B_u = 49, 50, 117
local B_A, B_C, B_D, B_M, B_R, B_T, B_U = 65, 67, 68, 77, 82, 84, 85

-- Coroutines execute on Clink's input thread.  Check both record and byte
-- budgets, then yield once a slice consumes about 1ms.  The byte budget also
-- protects responsiveness for unusually long Windows paths.
local STATUS_SLICE_SECONDS = 0.001
local STATUS_SLICE_LINES = 32
local STATUS_SLICE_BYTES = 16384

-- status byte other than '.' or ' '
local function changed(c)
    return c and c ~= B_DOT and c ~= B_SPACE
end

local function read_status_porcelain(info, scan_untracked)
    local file, pclose = io.popenyield(status_command(scan_untracked), 'rt')
    if not file then return false end

    local oid = nil
    local entries, slice_lines, slice_bytes, slice_started = 0, 0, 0, clock()
    local conflicted, deleted, modified, renamed, staged, tracked, untracked = 0, 0, 0, 0, 0, 0, 0
    local limit = config.status_entry_limit
    local parse_ok = pcall(function ()
        while true do
            local line = file:read('*l')
            if line == nil then break end

            slice_lines = slice_lines + 1
            slice_bytes = slice_bytes + #line
            if slice_lines >= STATUS_SLICE_LINES or slice_bytes >= STATUS_SLICE_BYTES then
                if clock() - slice_started >= STATUS_SLICE_SECONDS then
                    maybe_yield()
                    slice_started = clock()
                end
                slice_lines, slice_bytes = 0, 0
            end

            local kind = line:byte(1)
            if kind == B_HASH then
                local field, value = line:match('^# ([%w%.]+) (.*)$')
                if field == 'branch.head' then
                    info.branch = value
                elseif field == 'branch.oid' then
                    oid = value
                elseif field == 'branch.upstream' then
                    info.upstream = trim(value)
                elseif field == 'branch.ab' then
                    -- '+A -B'; --no-ahead-behind prints '+? -?' when the branch differs from upstream
                    local ahead, behind = value:match('^%+(%S+) %-(%S+)$')
                    if ahead and ahead ~= '?' and behind ~= '?' then
                        info.has_ab, info.ahead, info.behind = true, to_int(ahead), to_int(behind)
                    end
                elseif field == 'stash' then
                    info.stash_count = to_int(value)
                end
            elseif kind == B_QMARK then
                entries = entries + 1
                untracked = untracked + 1
            elseif kind == B_1 or kind == B_2 or kind == B_u then
                entries = entries + 1
                local x, y = line:byte(3), line:byte(4)
                if kind == B_u or x == B_U or y == B_U or
                    (x == B_A and y == B_A) or (x == B_D and y == B_D) then
                    conflicted = conflicted + 1
                else
                    -- X is the staged/index state and Y is the independent
                    -- worktree state.  A path such as MM, AM, or RM must
                    -- contribute to both relevant prompt categories.
                    if x == B_D or y == B_D then deleted = deleted + 1 end
                    if x == B_R or x == B_C then renamed = renamed + 1 end
                    if changed(x) and x ~= B_D and x ~= B_R and x ~= B_C then
                        staged = staged + 1
                    end
                    if y == B_M or y == B_T then
                        modified = modified + 1
                    elseif changed(y) and y ~= B_D then
                        tracked = tracked + 1
                    end
                end
            end

            if limit and limit > 0 and entries >= limit then
                info.truncated = true
                break
            end
        end
    end)

    -- pclose closes the handle and reports Git's exit status even if parsing
    -- stopped at the configured entry bound.  Always close after read errors.
    -- Outside a coroutine (snapline-bench) popenyield degrades to io.popen,
    -- which returns no pclose.
    local close_ok
    if pclose then close_ok = pclose() else close_ok = file:close() end
    if not parse_ok or not close_ok then return false end

    if info.branch == '(detached)' and oid and oid ~= '(initial)' then
        info.branch = oid:sub(1, 7)
    end
    info.conflicted, info.deleted, info.modified, info.renamed = conflicted, deleted, modified, renamed
    info.staged, info.tracked, info.untracked = staged, tracked, untracked
    return true
end

-- One status snapshot of the repository under the current cwd.  Returns the
-- info table, or nil plus the observed git dir (false when not in a repo).
-- 'status' supplies the throttled untracked count reused between full scans.
local function collect_status(status)
    local gd, workspace_dir, root = git.getgitdir()
    if not gd then return nil, false end
    local common = git.getcommondir() or gd
    local info = {
        git_dir = gd, common_dir = common, workspace_dir = workspace_dir, root = root,
        key = repo_key(gd, common),
        branch = nil, upstream = nil, has_ab = false, ahead = 0, behind = 0,
        stash_count = 0, truncated = false,
    }
    local scan_untracked = should_scan_untracked(status)
    if not read_status_porcelain(info, scan_untracked) then
        return nil, gd
    end
    if not scan_untracked then
        info.untracked = status.untracked_count
        info.truncated = info.truncated or status.untracked_truncated
    end
    info.untracked_refreshed = scan_untracked
    info.dirty_dir = info.untracked > 0
    info.dirty_branch = info.dirty_dir or info.conflicted > 0 or info.modified > 0 or
        info.renamed > 0 or info.deleted > 0 or info.staged > 0 or info.tracked > 0
    return info, gd
end

-- stringify git status info; color is applied at render time so a pending
-- status can be dimmed
local function render_status(info)
    local fmt = config.status_format
    local parts = {}
    if info.upstream and not info.has_ab then
        -- upstream configured but counts unknown: gone upstream or ahead_behind=false
        parts[#parts + 1] = fmt.ab_unknown
    elseif info.ahead > 0 or info.behind > 0 then
        parts[#parts + 1] = (info.ahead > 0 and info.behind > 0 and fmt.diverged or '') ..
            (info.ahead > 0 and fmt.ahead:format(info.ahead) or '') ..
            (info.behind > 0 and fmt.behind:format(info.behind) or '')
    end
    if info.conflicted > 0 then parts[#parts + 1] = fmt.conflicted:format(info.conflicted) end
    if info.modified > 0 then parts[#parts + 1] = fmt.modified:format(info.modified) end
    if info.renamed > 0 then parts[#parts + 1] = fmt.renamed:format(info.renamed) end
    if info.deleted > 0 then parts[#parts + 1] = fmt.deleted:format(info.deleted) end
    if info.staged > 0 then parts[#parts + 1] = fmt.staged:format(info.staged) end
    if info.tracked > 0 then parts[#parts + 1] = fmt.tracked:format(info.tracked) end
    if info.untracked > 0 then parts[#parts + 1] = fmt.untracked:format(info.untracked) end
    if info.truncated then parts[#parts + 1] = fmt.truncated:format(config.status_entry_limit or 0) end
    return concat(parts, ' ')
end

local function upstream_prompt(upstream, branch)
    if not upstream then return '' end
    local display = upstream
    if config.abbreviate_upstream and branch then
        -- 'origin/main' on branch 'main' is the common case: show just 'origin'
        local suffix = '/' .. branch
        if #upstream > #suffix and upstream:sub(-#suffix) == suffix then
            display = upstream:sub(1, #upstream - #suffix)
        end
    end
    return config.color.now .. display .. config.color.reset
end

-- ===== repository signature =====
-- A bounded set of .git file fingerprints describing what git status depends
-- on.  The watcher compares it to notice external changes while idle, and
-- the collector rejects a status whose inputs changed while git was running.
-- Ordinary prompt rendering never computes it.

-- length-prefix every part so concatenation is unambiguous
local function pack(parts)
    for i = 1, #parts do parts[i] = #parts[i] .. ':' .. parts[i] end
    return concat(parts)
end

local function signature(ctx)
    local gd, common = ctx.git_dir, ctx.common_dir
    if ctx.remote and not config.watch_remote_repo then
        local k = ctx.key
        return { identity = k, work = k, meta = k, fetch = k, refs = k }
    end
    local root_dotgit = ctx.root and join(ctx.root, '.git')
    local identity = pack({
        root_dotgit and not paths_equal(root_dotgit, gd) and file_sample(root_dotgit, 512) or path_key(gd),
        not paths_equal(common, gd) and file_sample(join(gd, 'commondir'), 256) or path_key(common),
    })
    -- a change here can alter the untracked set, so the throttled count is dropped
    local work = pack({
        file_sample(join(gd, 'index'), 64),
        file_sample(join(gd, 'info', 'sparse-checkout'), 512),
        file_sample(join(gd, 'info', 'exclude'), 512),
        file_sample(join(common, 'config'), 1024),
        file_sample(join(gd, 'config.worktree'), 512),
    })
    local meta = pack({
        os.isfile(join(gd, 'index.lock')) and '1' or '-',
        os.isfile(join(common, 'shallow')) and '1' or '-',
        file_sample(join(gd, 'HEAD'), 256),
        file_sample(join(gd, 'MERGE_HEAD'), 256),
        file_sample(join(gd, 'CHERRY_PICK_HEAD'), 256),
        file_sample(join(gd, 'REVERT_HEAD'), 256),
        file_sample(join(gd, 'BISECT_LOG'), 128),
        file_sample(join(gd, 'rebase-merge', 'msgnum'), 64),
        file_sample(join(gd, 'rebase-merge', 'end'), 64),
        file_stamp(join(gd, 'rebase-merge', 'interactive')),
        file_sample(join(gd, 'rebase-apply', 'next'), 64),
        file_sample(join(gd, 'rebase-apply', 'last'), 64),
        file_stamp(join(gd, 'rebase-apply', 'rebasing')),
        file_stamp(join(gd, 'rebase-apply', 'applying')),
        file_sample(join(common, 'packed-refs'), 512),
        file_sample(join(common, 'logs', 'refs', 'stash'), 256),
        file_sample(join(common, 'reftable', 'tables.list'), 512),
    })
    local refs = { ctx.branch or '-', ctx.upstream or '-' }
    if ctx.branch then
        refs[#refs + 1] = file_sample(join(common, 'refs', 'heads', ctx.branch), 256)
    end
    if ctx.upstream then
        refs[#refs + 1] = file_sample(join(common, 'refs', 'remotes', ctx.upstream), 256)
        refs[#refs + 1] = file_sample(join(common, 'refs', 'heads', ctx.upstream), 256)
    end
    return { identity = identity, work = work, meta = meta,
        fetch = file_sample(join(common, 'FETCH_HEAD'), 512), refs = pack(refs) }
end

local function same_signature(a, b, ignore_refs)
    return a.identity == b.identity and a.work == b.work and a.meta == b.meta and
        a.fetch == b.fetch and (ignore_refs or a.refs == b.refs)
end

-- what the signature depends on, from the cache or from a collected status
local function repo_context(repo)
    return { git_dir = repo.git_dir, common_dir = repo.common_dir, root = repo.root, key = repo.key,
        remote = repo.remote, branch = repo.branch, upstream = repo.status.upstream }
end

local function info_context(info)
    return { git_dir = info.git_dir, common_dir = info.common_dir, root = info.root, key = info.key,
        remote = any_remote(info.git_dir, info.common_dir), branch = info.branch, upstream = info.upstream }
end

-- ===== async status collection =====
--
-- Clink's scheduler resumes coroutines from a live pairs() traversal of its
-- private registry, and coroutine.create registers into that same table, so
-- creating a coroutine from inside a scheduled coroutine mutates the table
-- mid-traversal.  That is undefined behavior for next(): a rehash can make
-- Clink revisit an entry that already completed during the pass and resume
-- it dead ("coroutine failed: cannot resume dead coroutine").  Therefore
-- coroutines are only ever created on the main thread: the two creators
-- below no-op in coroutine context (prompt filters can run on a coroutine
-- stack via clink.refilterprompt), and code that runs inside a coroutine
-- communicates through flags instead of creating coroutines.
--
-- All status work runs in one perpetual worker coroutine marked
-- runcoroutineuntilcomplete, so unlike clink.promptcoroutine a slow
-- collection survives Enter: on a slow repo the status lands on a later
-- prompt instead of being canceled and restarted by every command.  Requests
-- from any context only set a flag and zero the worker's resume interval (a
-- plain field write inside Clink, safe even from coroutine context); the
-- worker collects sequentially, never more than one git process, coalescing
-- any number of mutations into one newest-state refresh.  The result is
-- applied only when the state version it started with is still current.
local worker = nil               -- perpetual collector coroutine, nil until needed
local worker_kept = false        -- registered untilcomplete, so it survives edit-session ends
local inflight = nil             -- { repo, version } while a collection runs
local refresh_pending = false    -- newest state still needs a collection
local WORKER_IDLE_INTERVAL = 3600   -- parked; requests wake the worker via interval 0

local function async_enabled()
    return settings.get('prompt.async') ~= false
end

-- internal errors are surfaced once per distinct message, never swallowed
local reported = {}
local function report_error(err)
    err = tostring(err)
    if not reported[err] then
        reported[err] = true
        note('snapline: ' .. err)
    end
end

-- refilterprompt runs the prompt filters, so it is protected like any other
-- callback invoked from a coroutine
local function refilter()
    local ok, err = pcall(clink.refilterprompt)
    if not ok then report_error(err) end
end

-- Ask for a status refresh of the current state.  Callable from any context:
-- it never creates a coroutine, it only marks work pending and wakes the
-- parked worker.
local function request_refresh()
    local repo = cache.repo
    if not repo then
        refresh_pending = false
        return
    end
    local status = repo.status
    if not async_enabled() then
        refresh_pending = false
        status.unavailable = config.status_format.async_off
        status.failed = false
        return
    end
    status.unavailable = nil
    if inflight and inflight.repo == repo and inflight.version == state_version then
        -- a collection for exactly this state is already running
        refresh_pending = false
        return
    end
    refresh_pending = true
    if worker then clink.setcoroutineinterval(worker, 0) end
end

-- read a git config value; runs inside the status coroutine
local function git_config_value(name)
    local f, pclose = io.popenyield(git.makecommand('config --get ' .. name), 'rt')
    if not f then return nil end
    local out = f:read('*a')
    if pclose then pclose() else f:close() end
    return trim(out)
end

local hinted = {}   -- git dirs already given the fsmonitor hint this session
local function check_fsmonitor_hint(repo, duration)
    if not config.fsmonitor_hint or hinted[repo.git_dir] then return end
    if duration < config.fsmonitor_hint_threshold then
        repo.slow_count = 0
        return
    end
    repo.slow_count = repo.slow_count + 1
    if repo.slow_count < config.fsmonitor_hint_count then return end
    local value = git_config_value('core.fsmonitor')
    if repo ~= cache.repo then return end
    hinted[repo.git_dir] = true
    value = value and value:lower()
    if not value or value == 'false' or value == 'no' or value == 'off' or value == '0' then
        note(format('snapline: git status took >%.0fms %d times in a row - consider ' ..
            '"git config core.fsmonitor true", "git config core.untrackedCache true" and ' ..
            '"git maintenance start" for this repo',
            config.fsmonitor_hint_threshold * 1000, config.fsmonitor_hint_count))
    end
end

-- Transactional snapshot: the signature is taken before and after git runs,
-- and the result is rejected when its inputs changed meanwhile.  An identity
-- change consumes one attempt, an unstable repository another; nothing is
-- committed unless a final signature still describes the collected status.
local function collect_stable(repo, version)
    local started = clock()
    local ctx = repo_context(repo)
    local response = { cwd = os.getcwd() }
    for _ = 1, 3 do
        local before = signature(ctx)
        local info, observed = collect_status(repo.status)
        response.info, response.observed = info, observed
        if not info then break end
        local next_ctx = info_context(info)
        local after = signature(next_ctx)
        -- a changed branch or upstream makes the ref fingerprints incomparable
        local same_keys = next_ctx.branch == ctx.branch and next_ctx.upstream == ctx.upstream
        if info.key == ctx.key and same_signature(before, after, not same_keys) then
            response.baseline = after
            break
        end
        response.info = nil
        ctx = next_ctx
        if version ~= state_version or repo ~= cache.repo then break end
    end
    -- duration is always measured since it drives the fsmonitor hint;
    -- config.profile only controls displaying it in the prompt
    response.duration = clock() - started
    response.finished_at = clock()
    return response
end

local function apply_status(repo, response)
    local info = response.info
    if not info then
        -- keep the old render but leave it marked stale: it was NOT refreshed
        repo.status.failed = true
        local observed = response.observed
        if observed == false or (observed and not paths_equal(observed, repo.git_dir)) then
            repo.identity_stale = true
            repo.status.baseline = nil
        end
        return false
    end
    if info.key ~= repo.key then
        -- the repository under this cwd was replaced, e.g. .git recreated
        if not paths_equal(os.getcwd(), response.cwd) or
            (not config.enable_remote_repos and any_remote(info.git_dir, info.common_dir)) then
            repo.identity_stale = true
            return false
        end
        repo = new_repo(info.git_dir, info.common_dir, info.workspace_dir, info.root)
        repo.remote = any_remote(response.cwd, info.git_dir, info.common_dir)
        cache.repo = repo
        refresh_action(repo)
        refresh_state(repo)
    end
    local status = repo.status
    status.failed, status.unavailable, repo.identity_stale = false, nil, false
    repo.branch = info.branch or repo.branch
    status.dirty_branch, status.dirty_dir = info.dirty_branch, info.dirty_dir
    status.text = render_status(info)
    status.at = response.finished_at
    status.upstream, status.upstream_prompt = info.upstream, upstream_prompt(info.upstream, info.branch)
    status.baseline = response.baseline
    repo.stash_prompt = info.stash_count > 0 and
        (config.color.clean .. config.status_format.stashed:format(info.stash_count) .. config.color.reset) or ''
    if info.untracked_refreshed then
        status.untracked_at = response.finished_at
        status.untracked_count, status.untracked_truncated = info.untracked, info.truncated
    end
    if config.profile then
        status.duration = fmt_duration(response.duration)
    end
    return true
end

local function run_collection()
    local repo, version = cache.repo, state_version
    inflight = { repo = repo, version = version }
    local ok, response = pcall(collect_stable, repo, version)
    inflight = nil
    if version ~= state_version or repo ~= cache.repo or repo.status.unavailable then
        -- Superseded mid-collection: the result describes a state that no
        -- longer exists, and the follow-up collection owns the next refilter.
        return
    end
    local applied = nil
    if ok then ok, applied = pcall(apply_status, repo, response) end
    if not ok then
        -- 'applied' holds the apply error, 'response' the collect error
        repo.status.failed = true
        report_error(applied or response)
    elseif applied then
        -- may yield for one async config read; the status is already committed
        local hint_ok, err = pcall(check_fsmonitor_hint, repo, response.duration)
        if not hint_ok then report_error(err) end
    end
    refilter()
end

local function worker_loop()
    local self = coroutine.running()
    while true do
        if refresh_pending then
            refresh_pending = false
            if cache.repo and async_enabled() then
                run_collection()
            end
        else
            -- Park until a request zeroes the interval again; without the
            -- large interval an idle worker would busy-wake every pass.  The
            -- interval also paces the yields inside a collection, so it goes
            -- back to 0 before any work.
            clink.setcoroutineinterval(self, WORKER_IDLE_INTERVAL)
            coroutine.yield()
            clink.setcoroutineinterval(self, 0)
        end
    end
end

local function ensure_worker()
    if not on_main_thread() then return end
    if worker and worker_kept and coroutine.status(worker) ~= 'dead' then return end
    -- A worker that could not be registered untilcomplete was canceled by
    -- clink at the last edit-session end; either way it is orphaned, so
    -- replace it.
    inflight = nil
    worker = coroutine.create(worker_loop)
    worker_kept = pcall(clink.runcoroutineuntilcomplete, worker)
    clink.setcoroutinename(worker, 'snapline status')
end

-- ===== repo watcher =====
-- While idle at the prompt, µs-scale file probes detect git state changed by
-- other terminals/editors and trigger an async refresh, so the prompt
-- corrects itself without Enter.  It reads the cache fresh on every probe,
-- so repository identity changes mid-session need no watcher restart.
local function watcher_probe()
    local repo = cache.repo
    if not repo then return end
    local status = repo.status
    local sig = signature(repo_context(repo))
    local base = status.baseline
    if not base then
        status.baseline = sig
        return
    end
    if same_signature(sig, base) then return end
    status.baseline = sig
    state_version = state_version + 1
    if sig.identity ~= base.identity then repo.identity_stale = true end
    if sig.work ~= base.work then status.untracked_at = nil end
    status.at = nil
    refresh_action(repo)
    refresh_state(repo)
    if sig.fetch ~= base.fetch then refresh_fetch_age(repo, true) end
    request_refresh()
    refilter()
end

-- One watcher coroutine per input line session, created on the main thread
-- only.  Without runcoroutineuntilcomplete clink cancels it when the edit
-- session ends; the next session's filter starts a fresh one.
-- lua.throttle_interval defaults to 0 since clink 1.7.17, so a sub-five-
-- second loop is not throttled.
local function start_watcher()
    local repo = cache.repo
    if watcher or not config.watch_repo or not repo or
        (repo.remote and not config.watch_remote_repo) or not on_main_thread() then
        return
    end
    local co
    co = coroutine.create(function ()
        while co == watcher do
            local ok, err = pcall(watcher_probe)
            if not ok then report_error(err) end
            coroutine.yield()
        end
    end)
    watcher = co
    clink.setcoroutinename(co, 'snapline watch')
    clink.setcoroutineinterval(co, config.watch_interval)
end

-- ===== input classification and command timing =====

-- commands that can't change git state as long as no redirection is involved
local NEUTRAL_CMDS = {
    cls = true, dir = true, type = true, echo = true, where = true,
    ver = true, vol = true, help = true, whoami = true, hostname = true,
    title = true, rem = true, cd = true, chdir = true, pushd = true,
    popd = true, more = true, tree = true, find = true, findstr = true,
    ['snapline-bench'] = true, ['snapline-legend'] = true,
}
-- read-only git subcommands; fetch/pull/push are excluded on purpose since
-- they move ahead/behind, and branch/tag/remote/config since they can mutate
local NEUTRAL_GIT_SUBS = {
    log = true, diff = true, show = true, blame = true, shortlog = true,
    describe = true, status = true, reflog = true, grep = true, help = true,
    version = true, ['ls-files'] = true, ['ls-tree'] = true,
    ['ls-remote'] = true, ['rev-parse'] = true, ['rev-list'] = true,
    ['cat-file'] = true, ['count-objects'] = true,
}

local function is_status_neutral_input(line)
    if not config.reuse_neutral_commands then
        return false
    end
    -- redirection creates files, & ^ | chain or escape into arbitrary
    -- commands, % expands env vars into anything, quotes and newlines make
    -- parsing ambiguous: bail out on all of them, a refresh is never wrong
    if line:find('[<>|&^%%"\r\n]') then
        return false
    end
    local first, rest = line:match('^%s*(%S+)%s*(.-)%s*$')
    if not first or not first:match('^[%w%.%-_]+$') then
        return false
    end
    first = first:lower()
    -- doskey aliases can remap any name to an arbitrary command line
    if os.getalias(first) then
        return false
    end
    if NEUTRAL_CMDS[first] then
        return true
    end
    if first == 'git' or first == 'git.exe' then
        -- --output-* diff/log flags write files without any shell redirection
        if rest:find('--output', 1, true) then
            return false
        end
        local sub, subrest = rest:match('^(%S+)%s*(.-)%s*$')
        sub = sub and sub:lower()
        if NEUTRAL_GIT_SUBS[sub] then
            return true
        end
        if sub == 'stash' then
            local op = subrest:match('^(%S+)')
            return op == 'list' or op == 'show'
        end
    end
    return false
end

-- Called for every submitted line.  A blank line or a neutral command lets
-- the next prompt reuse the cached status; anything else bumps the state
-- version so an in-flight collection is discarded and a fresh one runs.
local function record_input(line)
    last_input_neutral = not line:find('%S') or is_status_neutral_input(line)
    if last_input_neutral then return end
    state_version = state_version + 1
    local repo = cache.repo
    if repo then
        -- A mutating command can create or remove untracked files.  Never let
        -- the short untracked throttle make the immediately following prompt
        -- reuse a count known to predate that command.
        repo.status.at, repo.status.untracked_at, repo.fetch_age_checked_at = nil, nil, nil
    end
end

-- the cached status can be reused without spawning git when the last input
-- couldn't change git state and the cache is fresh enough
local function status_is_fresh(status)
    if not last_input_neutral or status.failed or status.unavailable then
        return false
    end
    local age = config.blank_input_reuse_age
    return age > 0 and status.at ~= nil and clock() - status.at < age
end

-- ===== prompt filters =====

local function dir_name()
    local cwd = cache.cwd
    -- at drive root give readable name, e.g. for 'C:\' give 'C:'
    return basename(cwd) or cwd:match('^(%a:)') or cwd
end

local function git_left_prompt(repo)
    local color, parts = config.color, {}
    if repo.branch then
        local branch_color = color.reset
        if repo.status.dirty_branch ~= nil then
            branch_color = repo.status.dirty_branch and color.dirty or color.clean
        end
        parts[#parts + 1] = branch_color .. config.branch_symbol .. repo.branch .. color.reset
    end
    if repo.action then
        -- clink action names contain [-/], e.g. 'rebase-i' and 'am/rebase'
        local symbol = config.action_symbol[(repo.action:gsub('[-/]', '_'))] or config.action_symbol.unknown
        local step, total = repo.action_step, repo.action_total
        if step and total and step > 0 and total > 0 then
            symbol = format('%s%d/%d', symbol, step, total)
        end
        parts[#parts + 1] = color.state .. symbol .. color.reset
    end
    if repo.state_prompt ~= '' then
        parts[#parts + 1] = repo.state_prompt
    end
    return concat(parts, ' ')
end

-- '> ' marker carrying the last exit code when nonzero, e.g. '✗1 > '
-- requires Clink setting 'cmd.get_errorlevel' (on by default)
local function errorlevel_prompt_char()
    local code = config.errorlevel_indicator and os.geterrorlevel() or 0
    if code == 0 then return '> ' end
    -- negative codes are NTSTATUS values, e.g. 0xC0000005 access violation
    local shown = code < 0 and format('0x%08X', code + 4294967296) or code
    return config.color.dirty .. config.error_symbol .. shown .. config.color.reset .. ' > '
end

local FILTER_PRIORITY = 100  -- lower priority ids are called first
local pf = clink.promptfilter(FILTER_PRIORITY)
local status_stale = false   -- an async refresh is still pending for the shown status
local left_prompt_cells = nil

-- left prompt, first in execution line so it kicks off the async refresh
function pf:filter()
    if not active then
        left_prompt_cells = nil
        return
    end
    local repo = cache.repo
    -- decide once per input line session; a refilter after an async apply
    -- must not start another refresh or applies would loop forever
    if repo and not session_refresh_started then
        session_refresh_started = true
        ensure_worker()
        -- spawn git only when the cached status isn't provably fresh
        if not async_enabled() or not status_is_fresh(repo.status) then
            request_refresh()
        end
    end
    start_watcher()
    status_stale = repo ~= nil and
        ((inflight ~= nil and inflight.repo == repo) or refresh_pending or repo.status.failed)

    local color = config.color
    local dir_color = color.reset
    local dirty_dir = repo and repo.status.dirty_dir
    if dirty_dir ~= nil then
        dir_color = dirty_dir and color.dirty or color.clean
    end

    local parts = {}
    if cache.venv then
        parts[#parts + 1] = color.venv .. '{' .. cache.venv .. '}' .. color.reset
    end
    local git_part = repo and git_left_prompt(repo) or ''
    if git_part ~= '' then
        parts[#parts + 1] = git_part
    end
    parts[#parts + 1] = dir_color .. dir_name() .. color.reset
    parts[#parts + 1] = errorlevel_prompt_char()
    local rendered = concat(parts, ' ')
    left_prompt_cells = console.cellcount(rendered)
    return rendered
end

-- Ancillary right-prompt fields are dropped in this order when the terminal
-- is too narrow.  Command duration is the one per-command historical
-- measurement and is never intentionally discarded: on very narrow terminals
-- it outranks cached Git fields, which reappear on the next wider render.
local RIGHT_DROP_ORDER = { 'fetch_age', 'python', 'upstream', 'profile_duration', 'clock', 'git_status', 'stash' }

local function render_segments(segments)
    local invisible, visible = {}, {}
    for i = 1, #segments do
        local seg = segments[i]
        if seg.on then
            -- A clean Git status deliberately emits only color controls so
            -- Clink redraws the async right prompt.  It needs no separator.
            if seg.zero_width then
                invisible[#invisible + 1] = seg.text
            else
                visible[#visible + 1] = seg.text
            end
        end
    end
    return concat(invisible) .. concat(visible, ' ')
end

local function fit_right_prompt(segments)
    local rendered = render_segments(segments)
    if not config.adaptive_right_prompt or not left_prompt_cells then return rendered end

    local width = console.getwidth()
    local function fits(text)
        return left_prompt_cells + config.right_prompt_min_gap + console.cellcount(text) <= width
    end
    if fits(rendered) then return rendered end

    for i = 1, #RIGHT_DROP_ORDER do
        for j = 1, #segments do
            if segments[j].key == RIGHT_DROP_ORDER[i] then segments[j].on = false end
        end
        rendered = render_segments(segments)
        if fits(rendered) then return rendered end
    end
    -- Even the command duration cannot physically coexist with the left
    -- prompt and safety gap.  Returning empty is the only non-clipping result.
    return ''
end

-- right filter, second in execution line, renders only cached values
function pf:rightfilter()
    if not active then return end
    local color, repo = config.color, cache.repo
    local status = repo and repo.status
    -- in a repo the status render must not be an empty string or the right
    -- prompt doesn't get redrawn after async! - with no glyphs still emit colors
    local git_text, git_zero_width = '', false
    if status and status.unavailable then
        git_text = color.took .. status.unavailable .. color.reset
    elseif status and status.text then
        local sgr = color.clean
        if config.dim_stale_status and status_stale then
            sgr = color.took
        elseif status.dirty_branch then
            sgr = color.dirty
        end
        git_text = sgr .. status.text .. color.reset
        git_zero_width = status.text == ''
    elseif repo and status_stale then
        -- first status for this repo is still collecting
        git_text = color.took .. config.status_format.pending .. color.reset
    end
    local duration = last_dur_s ~= nil and last_dur_s >= config.min_duration_display and
        (color.took .. fmt_duration(last_dur_s) .. color.reset) or ''

    local segments = {
        { key = 'profile_duration', text = status and status.duration or '' },
        { key = 'git_status',       text = git_text, zero_width = git_zero_width },
        { key = 'upstream',         text = status and status.upstream_prompt or '' },
        { key = 'fetch_age',        text = repo and repo.fetch_age_prompt or '' },
        { key = 'stash',            text = repo and repo.stash_prompt or '' },
        { key = 'python',           text = cache.python_prompt },
        { key = 'command_duration', text = duration },
        { key = 'clock',            text = color.now .. date('%H:%M:%S') .. color.reset },
    }
    for i = 1, #segments do
        segments[i].on = segments[i].text ~= ''
    end
    return fit_right_prompt(segments)
end

function pf:surround()
    if not active then return end
    -- clear line code before left prompt to clean entire line (left & right) before prompt render
    -- otherwise stray glyphs can persist if left prompt gets shorter after async call
    -- https://invisible-island.net/xterm/ctlseqs/ctlseqs.html

    -- '\x1b' is hex ASCII 27 for Esc, '[' is Control Sequence Introducer (CSI)
    -- 2K is the parameter + command: K = EL (Erase in Line), 2K = clear the entire line

    -- prefix, suffix, rprefix, rsuffix
    return '\x1b[2K', '', '', ''
end

-- transient prompt (opt-in via 'clink set prompt.transient always'): past
-- prompts collapse to just the exit marker, keeping scrollback compact
function pf:transientfilter()
    if not active then return end
    return errorlevel_prompt_char()
end

function pf:transientrightfilter()
    if not active then return end
    -- time when the command was submitted, replacing the live clock
    return config.color.took .. date('%H:%M:%S') .. config.color.reset
end

-- ===== snapline-bench and snapline-legend commands =====

-- benchmark Clink git API calls and snapline alternatives; typed as the
-- 'snapline-bench' command at the prompt (runs blocking, a few seconds)
local function time_loop(f, n)
    local t = clock()
    for _ = 1, n do
        f()
    end
    return (clock() - t) / n
end

local function run_bench()
    local n = 5
    clink.print(config.color.took .. format('snapline bench: %d iterations per call, slow calls red', n) .. config.color.reset)
    local rows = {
        {'git.getaction',           git.getaction},
        {'git.getgitdir',           git.getgitdir},
        {'git.getcommondir',        git.getcommondir},
        {'git.getbranch',           git.getbranch},
        {'git.getremote',           git.getremote},
        {'git.isgitdir',            git.isgitdir},
        {'git.getsystemname',       git.getsystemname},
        {'git.hasstash',            git.hasstash},
        {'git.getstashcount',       git.getstashcount},
        {'git.getaheadbehind',      git.getaheadbehind},
        {'git.getstatus',           git.getstatus},
        {'git.getconflictstatus',   git.getconflictstatus},
        {'snapline collect_status', function ()
            return collect_status(cache.repo and cache.repo.status or new_status())
        end},
    }
    for i = 1, #rows do
        local name, fn = rows[i][1], rows[i][2]
        if fn then
            local duration = time_loop(fn, n)
            local color = duration > 0.01 and config.color.dirty or config.color.clean
            clink.print(color .. format('%25s', name) .. '   ' .. fmt_duration(duration) .. config.color.reset)
        end
    end
end

-- print the action and status glyph legend built from the active config, so
-- it always shows the configured glyphs; typed as the 'snapline-legend' command
local function run_legend()
    local fmt, act, repo, col = config.status_format, config.action_symbol,
        config.repo_state_symbol, config.color

    -- pad to visible width: nerd glyphs are 3-4 bytes but render as 1-2 cells
    local function pad(s, width)
        local cells = console.cellcount(s)
        return s .. (' '):rep(width > cells and width - cells or 1)
    end
    -- replace the count placeholder in a status format, e.g. '⇡%d' > '⇡N'
    local function sample(f, n)
        return (f:gsub('%%[ds]', n or 'N'))
    end
    local function print_rows(title, color, rows)
        clink.print(col.took .. title .. col.reset)
        for i = 1, #rows do
            local r = rows[i]
            local line = '  ' .. pad(r[1], 16) .. color .. pad(r[2], 10) .. col.reset
            if r[3] then
                line = line .. pad(r[3], 16) .. color .. r[4] .. col.reset
            end
            clink.print(line)
        end
    end

    print_rows('status', col.clean, {
        { 'ahead',          sample(fmt.ahead),          'behind',     sample(fmt.behind) },
        { 'diverged',       fmt.diverged .. sample(fmt.ahead, 'A') .. sample(fmt.behind, 'B'),
                                                        'conflicted', sample(fmt.conflicted) },
        { 'staged',         sample(fmt.staged),         'modified',   sample(fmt.modified) },
        { 'renamed',        sample(fmt.renamed),        'deleted',    sample(fmt.deleted) },
        { 'tracked',        sample(fmt.tracked),        'untracked',  sample(fmt.untracked) },
        { 'stashed',        sample(fmt.stashed),        'ab unknown', fmt.ab_unknown },
        { 'fetch age',      sample(fmt.fetch_age, 'Nd'), 'collecting', fmt.pending },
        { 'entry limit',    sample(fmt.truncated),       'async off',  fmt.async_off },
    })
    print_rows('action', col.state, {
        { 'int rebase',     act.rebase_i,       'rebase merge', act.rebase_m },
        { 'rebase',         act.rebase,         'mail split',   act.am },
        { 'mail s. rebase', act.am_rebase,      'merging',      act.merging },
        { 'cherry-picking', act.cherry_picking, 'reverting',    act.reverting },
        { 'bisecting',      act.bisecting,      'unknown',      act.unknown },
        { 'progress',       act.rebase_i .. 'N/M' },
    })
    print_rows('repository', col.state, {
        { 'index lock',     repo.index_lock, 'shallow',     repo.shallow },
        { 'sparse checkout', repo.sparse,    'linked worktree', repo.worktree },
        { 'submodule',      repo.submodule },
    })
    print_rows('marks', col.reset, {
        { 'branch',         config.branch_symbol, 'exit code',  config.error_symbol .. 'N' },
    })
end

-- ===== events =====

-- onfilterinput sees the text after earlier input filters, which is what cmd
-- will actually run
clink.onfilterinput(function (text)
    record_input(text)
    if text:match('^%s*snapline%-bench%s*$') then
        run_bench()
        return '', false
    elseif text:match('^%s*snapline%-legend%s*$') then
        run_legend()
        return '', false
    end
end)

-- Blank input is measured too: it shows the real Enter-to-prompt roundtrip
-- (including cmd's hidden errorlevel capture), never a stale reading.
clink.onendedit(function ()
    last_start = clock()
end)

clink.onbeginedit(function ()
    -- capture the command duration first, before the cache refresh below
    -- adds its own microseconds to it
    if last_start then
        last_dur_s = clock() - last_start
        last_start = nil
    end
    -- Clink returns an empty string when no .clinkprompt is selected; when
    -- one is, snapline stands down instead of mixing two prompts.
    local selected = clink.getclinkprompt()
    active = not (type(selected) == 'string' and selected ~= '')
    watcher = nil   -- clink canceled the previous session's watcher at edit end
    session_refresh_started = not active
    if not active then return end
    if #notes > 0 then
        for i = 1, #notes do
            clink.print(config.color.took .. notes[i] .. config.color.reset)
        end
        notes = {}
    end
    refresh_runtime_cache()
    if cache.repo then
        refresh_fetch_age(cache.repo, false)
    end
end)
