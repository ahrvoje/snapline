-- snapline - fast async git status prompt renderer for clink
--         by Hrvoje Abraham ahrvoje@gmail.com

-- Legend:  conflicted=' |N'      ahead=' ⇡N'   behind=' ⇣N'   diverged=' ⇕⇡A⇣B'   tracked=' ?'
--            modified=' !N'     staged=' +N'  deleted=' XN'  untracked=' ??'     stashed=' ≡N'  renamed=' »N'
--          '⇡?' upstream set but ahead/behind unknown (upstream gone or ahead_behind=false)
--          '…' first status for this repo is still collecting     '~Nd' time since last fetch
-- In-progress git state indicator (yellow unicode char): rebase/am/merge/cherry-pick/revert/bisect
-- Exit code marker: red '✗N >' when the last command failed (negative codes shown as hex NTSTATUS)
-- Type 'snapline-legend' at the prompt to print the glyph legend for the active config.
-- Type 'snapline-bench' at the prompt to benchmark Clink git API calls vs snapline alternatives.

local clock  = os.clock      -- Clink clock returning seconds with us precision
local concat = table.concat
local floor  = math.floor
local format = string.format
local getenv = os.getenv
local date   = os.date


-- cached values used for fast prompt render to keep CLI snappy
-- every use of cached value is refreshed upon async op finish
local function get_init_cache()
    return {
        cwd = '',
        venv = nil,
        git_dir = nil,
        git_branch = nil,
        git_upstream_key = nil,
        git_upstream_prompt = '',
        git_untracked_at = nil,
        git_untracked_count = 0,
        python_prompt = '',
        pyvenv_cfg_path = nil,
        pyvenv_version = nil,
        stash_path = nil,
        stash_size = nil,
        stash_mtime = nil,
        stash_count = 0,
        stash_prompt = '',
        fetch_age_prompt = '',
        git_render_text = nil,
        git_status_at = nil,
        git_status_failed = false,
        git_duration = '',
        dirty_branch = nil,
        dirty_dir = nil,
    }
end
local _cache = get_init_cache()

-- No-op outside Clink prompt runtime.
if not (clink and git and clink.promptfilter and clink.refilterprompt and clink.onbeginedit and clink.onendedit) then
    return
end

local config = {
    -- Nerd Fonts tables: https://www.nerdfonts.com/cheat-sheet
    --
    -- 30.08.2025. Clink uses Lua 5.2 which doesn't support Unicode literals
    -- It can use UTF-8, so conversion from UTF-16 to UTF-8 is presented
    --
    -- Python convert UTF-16 to UTF-8 and back for branch symbol \ue0a0
    --     list('\ue0a0'.encode('utf-8'))          >  [238, 130, 160]
    --     bytes([238, 130, 160]).decode('utf-8')  >  '\ue0a0'
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
    -- Seconds between full untracked-file scans.  Between full scans, Snapline
    -- uses "git status -uno" and reuses the last untracked count.  Set to 0 to
    -- scan untracked files every time, or false to disable untracked counts.
    untracked_refresh_interval = 2.0,
    status_include_submodules = false,
    -- Ahead/behind counts require walking commit history; on long-diverged
    -- branches in big repos this can dominate status time.  Set false to add
    -- --no-ahead-behind: status shows '⇡?' when the branch differs from its
    -- upstream instead of exact counts.
    ahead_behind = true,
    stash_git_fallback = false,
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
    -- change.  Clink throttles long-lived coroutines to one resume per 5s,
    -- so the effective cadence is watch_interval at first, later up to 5s.
    watch_repo = true,
    watch_interval = 2.0,
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
    -- Hide last-command durations below this many seconds.  Set 0 to show all.
    min_duration_display = 0.,
    -- Print a one-time hint when git status is repeatedly slow and
    -- core.fsmonitor is not enabled for the repo.
    fsmonitor_hint = true,
    fsmonitor_hint_threshold = 0.080,  -- seconds; status slower than this is 'slow'
    fsmonitor_hint_count = 5,          -- consecutive slow statuses before hinting
}

-- optional config overrides from a wrapper script (or test harness) that
-- defines the global 'snapline_config' table before this file loads
do
    local overrides = rawget(_G, 'snapline_config')
    if type(overrides) == 'table' then
        for k, v in pairs(overrides) do
            config[k] = v
        end
    end
end

-- one-time fsmonitor hint state
local slow_status_count = 0
local fsmonitor_hint_done = false
local pending_hint = nil

-- repo watcher is recreated for every input line session
local watcher_started = false
-- the prompt filter decides once per input line session whether to refresh;
-- refilters after an async apply must not start another round
local session_refresh_started = false

-- append value to table only if it is not nil/empty
local function append_non_empty(t, s)
    if s and s ~= '' then
        t[#t + 1] = s
    end
end

local function trim(s)
    if not s then
        return nil
    end
    s = s:match('^%s*(.-)%s*$')
    return s ~= '' and s or nil
end

local function to_int(v)
    return tonumber(v) or 0
end

-- yield to the coroutine scheduler, but only when actually inside a coroutine
-- (snapline-bench runs the same code paths on the main thread)
local function maybe_yield()
    local _, is_main = coroutine.running()
    if not is_main then
        coroutine.yield()
    end
end

local function set_pyvenv_cache(path, version)
    _cache.pyvenv_cfg_path = path
    _cache.pyvenv_version = version
end

local function clear_git_status_cache()
    _cache.git_upstream_key = nil
    _cache.git_upstream_prompt = ''
    _cache.git_untracked_at = nil
    _cache.git_untracked_count = 0
    _cache.git_render_text = nil
    _cache.git_status_at = nil
    _cache.git_status_failed = false
    _cache.git_duration = ''
    _cache.dirty_branch = nil
    _cache.dirty_dir = nil
end

local function clear_git_identity_cache()
    _cache.git_dir = nil
    _cache.git_branch = nil
    clear_git_status_cache()
end

local function set_git_upstream_cache(upstream, branch)
    upstream = trim(upstream)
    if not upstream then
        _cache.git_upstream_key = nil
        _cache.git_upstream_prompt = ''
        return
    end
    local key = upstream .. '\0' .. (branch or '')
    if key == _cache.git_upstream_key then
        return
    end
    local display = upstream
    if config.abbreviate_upstream and branch then
        -- 'origin/main' on branch 'main' is the common case: show just 'origin'
        local suffix = '/' .. branch
        if #upstream > #suffix and upstream:sub(-#suffix) == suffix then
            display = upstream:sub(1, #upstream - #suffix)
        end
    end
    _cache.git_upstream_key = key
    _cache.git_upstream_prompt = config.color.now .. display .. config.color.reset
end

local function set_stash_cache(path, size, mtime, count)
    _cache.stash_path = path
    _cache.stash_size = size
    _cache.stash_mtime = mtime
    _cache.stash_count = count or 0
end

local function basename_any_path(p)
    if not p or #p == 0 then
        return nil
    end
    local s = p:gsub('[\\/]+$', '')
    if #s == 0 then
        return nil
    end
    local b = s:match('([^\\/]+)$')
    if b and #b > 0 then
        return b
    end
    return nil
end

local function normalize_env_name(s)
    s = trim(s)
    if not s then return nil end

    local inner = s:match('^%((.+)%)$')
    return trim(inner or s)
end

local function get_cwd()
    return os.getcwd() or ''
end

local PATH_SEP = (package and package.config and package.config:sub(1, 1)) or '\\'
local function join_path(a, b)
    return a .. PATH_SEP .. b
end

local function extract_python_version(s)
    if not s or #s == 0 then
        return nil
    end
    local v = s:match('(%d+%.%d+%.%d+)') or s:match('(%d+%.%d+)')
    if not v then
        return nil
    end
    local major, minor = v:match('^(%d+)%.(%d+)')
    if major and minor then
        return major .. '.' .. minor
    end
    return v
end

local function get_cached_pyvenv_version(venv_root)
    if not venv_root or #venv_root == 0 then
        set_pyvenv_cache(nil, nil)
        return nil
    end

    -- read pyvenv.cfg only when VIRTUAL_ENV points somewhere new: activation
    -- always changes the path, and file probes on every prompt would block
    -- the prompt when the venv lives on a slow network share.  An in-place
    -- rebuild of the same venv is rare and self-heals on reactivation.
    local cfg_path = join_path(venv_root, 'pyvenv.cfg')
    if cfg_path == _cache.pyvenv_cfg_path then
        return _cache.pyvenv_version
    end

    local f = io.open(cfg_path, 'rb')
    if not f then
        set_pyvenv_cache(cfg_path, nil)
        return nil
    end
    local content = f:read('*a')
    f:close()

    local ver = nil
    if content then
        local raw = content:match('^%s*version%s*=%s*([^\r\n]+)') or
            content:match('[\r\n]%s*version%s*=%s*([^\r\n]+)') or
            content:match('^%s*version_info%s*=%s*([^\r\n]+)') or
            content:match('[\r\n]%s*version_info%s*=%s*([^\r\n]+)')
        ver = extract_python_version(raw)
    end

    set_pyvenv_cache(cfg_path, ver)
    return ver
end

-- venv name and python capsule from a single pass over the env vars
local function refresh_python_env()
    local virtual_env = getenv('VIRTUAL_ENV')
    local conda_env   = normalize_env_name(getenv('CONDA_DEFAULT_ENV'))
    local pyenv       = normalize_env_name(getenv('PYENV_VERSION'))
    local uv_active   = getenv('UV_ACTIVE')

    _cache.venv = normalize_env_name(getenv('VIRTUAL_ENV_PROMPT'))
        or basename_any_path(virtual_env)
        or normalize_env_name(getenv('CONDA_PROMPT_MODIFIER'))
        or conda_env
        or pyenv

    local source = nil
    local version = extract_python_version(getenv('PYTHON_VERSION')) or extract_python_version(getenv('UV_PYTHON'))
    if virtual_env and #virtual_env > 0 then
        source = uv_active and 'uv' or 'venv'
        version = get_cached_pyvenv_version(virtual_env) or version
    elseif conda_env then
        source = 'conda'
    elseif pyenv then
        source = 'pyenv'
        version = extract_python_version(pyenv) or version
    elseif uv_active then
        source = 'uv'
    end

    if not source then
        _cache.python_prompt = ''
        return
    end

    local capsule = 'py'
    if version then
        capsule = capsule .. version
    end
    capsule = capsule .. ':' .. source
    _cache.python_prompt = config.color.venv .. capsule .. config.color.reset
end

local function refresh_git_identity_cache()
    local gd = (git.getgitdir and git.getgitdir()) or nil
    if not gd then
        clear_git_identity_cache()
        return
    end

    if _cache.git_dir and _cache.git_dir ~= gd then
        clear_git_status_cache()
    end
    _cache.git_dir = gd
    if git.getbranch then
        local branch = git.getbranch()
        if branch and branch ~= '.invalid' then
            if _cache.git_branch and _cache.git_branch ~= branch then
                clear_git_status_cache()
            end
            _cache.git_branch = branch
        end
    end
end

local function get_file_info(p)
    if not (p and os.findfiles) then
        return nil
    end

    local ff = os.findfiles(p, 2, { files = true, dirs = true, hidden = true, system = true, dirsuffix = false })
    if not ff then
        return nil
    end

    local item = ff:next()
    ff:close()
    return item
end

local function get_file_mtime(p)
    local item = get_file_info(p)
    return item and item.mtime or nil
end

-- 'size:mtime' identity stamp used to detect file changes, nil when absent
local function get_file_stamp(p)
    local item = get_file_info(p)
    if not item then
        return nil
    end
    return (item.size or 0) .. ':' .. (item.mtime or 0)
end

local function openstashlog()
    local gd = (git.getcommondir and git.getcommondir()) or git.getgitdir()
    if not gd then return nil, nil, nil, nil end

    local stashpath = join_path(join_path(join_path(gd, 'logs'), 'refs'), 'stash')
    local f = io.open(stashpath, 'rb')
    if not f then return nil, nil, nil, nil end

    -- seek is fast and lets us skip reading when size is unchanged
    local sz = f:seek('end')
    if not sz then
        f:close()
        return nil, nil, nil, nil
    end

    return f, sz, stashpath, get_file_mtime(stashpath)
end

-- fast stash presence check: file exists with non-zero size
local function hasstash()
    local f, sz = openstashlog()
    if not f then return false end
    f:close()
    return sz ~= nil and sz > 0
end

-- fast stash count based on counting .git\logs\refs\stash lines
local function getstashcount()
    local f, sz, stashpath, stash_mtime = openstashlog()
    if not f or not sz or not stashpath then
        -- without a readable stash reflog the async git fallback owns the
        -- count; keep it instead of blinking it off on every prompt
        if config.stash_git_fallback and not _cache.stash_path then
            return _cache.stash_count
        end
        set_stash_cache(nil, nil, nil, 0)
        return 0
    end

    -- return cached stash count if cache is of the same path and file metadata
    if _cache.stash_size and stashpath == _cache.stash_path and
        sz == _cache.stash_size and stash_mtime == _cache.stash_mtime then
        f:close()
        return _cache.stash_count
    end

    if sz == 0 then
        set_stash_cache(stashpath, sz, stash_mtime, 0)
        f:close()
        return 0
    end

    f:seek('set', 0)
    local stash_content = f:read('*a')
    if not stash_content then
        set_stash_cache(stashpath, sz, stash_mtime, 0)
        f:close()
        return 0
    end
    local _, count = stash_content:gsub('[^\r\n]+', '')
    set_stash_cache(stashpath, sz, stash_mtime, count)
    f:close()

    return _cache.stash_count
end

local function set_stash_prompt(count)
    count = count or 0
    _cache.stash_prompt = count > 0
        and (config.color.clean .. (config.status_format.stashed):format(count) .. config.color.reset)
        or ''
end

local function refresh_stash_cache()
    local stash_count = getstashcount()
    set_stash_prompt(stash_count)
end

-- dim '~3d' reminder that ahead/behind may be outdated when the last fetch
-- (FETCH_HEAD mtime) is older than config.fetch_age_min
local function refresh_fetch_age()
    _cache.fetch_age_prompt = ''
    local min_age = config.fetch_age_min
    if not min_age or min_age <= 0 or not _cache.git_dir then
        return
    end
    local common = (git.getcommondir and git.getcommondir()) or _cache.git_dir
    local mtime = get_file_mtime(join_path(common, 'FETCH_HEAD'))
    if not mtime then
        return
    end
    local age = os.time() - mtime
    if age < min_age then
        return
    end
    local text = age >= 86400 and format('%dd', floor(age / 86400)) or format('%dh', floor(age / 3600))
    _cache.fetch_age_prompt = config.color.took ..
        (config.status_format.fetch_age):format(text) .. config.color.reset
end

-- refresh cache only on prompt boundaries, not every filter render
local function refresh_runtime_cache()
    if pending_hint then
        clink.print(config.color.took .. pending_hint .. config.color.reset)
        pending_hint = nil
    end
    watcher_started = false
    session_refresh_started = false
    local cwd = get_cwd()
    if cwd ~= _cache.cwd then
        local old = _cache
        _cache = get_init_cache()
        _cache.cwd = cwd
        slow_status_count = 0
        -- python env caches are keyed by path, not cwd: carry them over
        _cache.pyvenv_cfg_path = old.pyvenv_cfg_path
        _cache.pyvenv_version = old.pyvenv_version
        -- git status is repo-wide (repo-root relative), so it stays valid
        -- across cd within the same repo: carry it instead of blanking the
        -- glyphs until the async refresh lands
        local gd = (git.getgitdir and git.getgitdir()) or nil
        if gd and gd == old.git_dir then
            _cache.git_dir = gd
            _cache.git_branch = old.git_branch
            _cache.git_upstream_key = old.git_upstream_key
            _cache.git_upstream_prompt = old.git_upstream_prompt
            _cache.git_untracked_at = old.git_untracked_at
            _cache.git_untracked_count = old.git_untracked_count
            _cache.git_render_text = old.git_render_text
            _cache.git_status_at = old.git_status_at
            _cache.git_duration = old.git_duration
            _cache.dirty_branch = old.dirty_branch
            _cache.dirty_dir = old.dirty_dir
        end
    end
    refresh_python_env()
    refresh_git_identity_cache()
end

-- git status via a single porcelain=v2 run
-- potentialy slow subprocess in the focus of the entire story!
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
--
local function should_refresh_untracked()
    local interval = config.untracked_refresh_interval
    if interval == false then
        return false
    end
    if not interval or interval <= 0 then
        return true
    end
    return not _cache.git_untracked_at or (clock() - _cache.git_untracked_at) >= interval
end

local B_HASH  = 35
local B_SPACE = 32
local B_DOT   = 46
local B_1     = 49
local B_2     = 50
local B_QMARK = 63
local B_A     = 65
local B_C     = 67
local B_D     = 68
local B_M     = 77
local B_R     = 82
local B_T     = 84
local B_U     = 85
local B_u     = 117

local function has_status_change_byte(c)
    return c and c ~= B_DOT and c ~= B_SPACE
end

local function parse_branch_ab(info, line)
    local plus = line:find('+', 13, true)
    if not plus then return end

    local sep = line:find(' ', plus + 1, true)
    if not sep then return end

    local minus = line:find('-', sep + 1, true)
    if not minus then return end

    local ahead, behind = line:sub(plus + 1, sep - 1), line:sub(minus + 1)
    if ahead == '?' or behind == '?' then
        -- --no-ahead-behind prints '+? -?' when the branch differs from upstream
        return
    end
    info.has_ab = true
    info.ahead = to_int(ahead)
    info.behind = to_int(behind)
end

local function update_status_branch(info, oid)
    if info.branch == '(detached)' and oid and oid ~= '(initial)' then
        info.branch = oid:sub(1, 7)
    end
end

local status_command_cache = {}
local function get_status_command(scan_untracked)
    local key = (scan_untracked and '1' or '0') ..
        (config.status_include_submodules and '1' or '0') ..
        (config.ahead_behind and '1' or '0')
    local cached = status_command_cache[key]
    if cached then
        return cached
    end

    -- git.makecommand already runs git with --no-optional-locks, so the async
    -- status never takes index.lock and can't collide with typed git commands
    local cmd = 'status --porcelain=v2 --branch'
    cmd = cmd .. (scan_untracked and ' --untracked-files=normal' or ' --untracked-files=no')
    if not config.status_include_submodules then
        cmd = cmd .. ' --ignore-submodules=all'
    end
    if not config.ahead_behind then
        cmd = cmd .. ' --no-ahead-behind'
    end

    cached = git.makecommand(cmd)
    status_command_cache[key] = cached
    return cached
end

local function read_status_porcelain(info, scan_untracked)
    if not (git.makecommand and io.popenyield) then
        return false
    end

    local full_cmd = get_status_command(scan_untracked)
    if not full_cmd then
        return false
    end

    local file, pclose = io.popenyield(full_cmd, 'rt')
    if not file then
        return false
    end

    -- single bulk read keeps Lua<->C crossings low even for huge outputs
    local content = file:read('*a')
    local ok
    if pclose then
        ok = pclose()
    else
        ok = file:close()
    end
    if not ok or not content then
        return false
    end

    local oid = nil
    local lines = 0
    local conflicted, deleted, modified, renamed, staged, tracked, untracked = 0, 0, 0, 0, 0, 0, 0
    for line in content:gmatch('[^\r\n]+') do
        -- coroutines resume on the input thread: yield periodically so a huge
        -- status output can't stall keystrokes while it is parsed
        lines = lines + 1
        if lines % 5000 == 0 then
            maybe_yield()
        end
        local kind = line:byte(1)
        if kind == B_HASH then
            if line:sub(1, 14) == '# branch.head ' then
                info.branch = line:sub(15)
            elseif line:sub(1, 13) == '# branch.oid ' then
                oid = line:sub(14)
            elseif line:sub(1, 18) == '# branch.upstream ' then
                info.upstream = line:sub(19)
            elseif line:sub(1, 12) == '# branch.ab ' then
                parse_branch_ab(info, line)
            end
        elseif kind == B_QMARK then
            untracked = untracked + 1
        elseif kind == B_1 or kind == B_2 or kind == B_u then
            local x, y = line:byte(3), line:byte(4)
            if kind == B_u or x == B_U or y == B_U or
                (x == B_A and y == B_A) or (x == B_D and y == B_D) then
                conflicted = conflicted + 1
            elseif x == B_D or y == B_D then
                deleted = deleted + 1
            elseif y == B_M or y == B_T then
                modified = modified + 1
            elseif x == B_R or x == B_C then
                renamed = renamed + 1
            elseif has_status_change_byte(x) then
                staged = staged + 1
            elseif has_status_change_byte(y) then
                tracked = tracked + 1
            end
        end
    end

    update_status_branch(info, oid)
    info.conflicted = conflicted
    info.deleted = deleted
    info.modified = modified
    info.renamed = renamed
    info.staged = staged
    info.tracked = tracked
    info.untracked = untracked
    return true
end

local function collect_status()
    local gd = (git.getgitdir and git.getgitdir()) or nil
    if not gd then return nil end

    local info = {
        git_dir      = gd,
        branch       = nil,
        upstream     = nil,
        has_ab       = false,
        ahead        = 0,
        behind       = 0,
        tracked      = 0,
        untracked    = 0,
        untracked_refreshed = false,
        modified     = 0,
        staged       = 0,
        renamed      = 0,
        deleted      = 0,
        conflicted   = 0,
        dirty_branch = nil,
        dirty_dir    = nil,
    }

    local scan_untracked = should_refresh_untracked()
    if not read_status_porcelain(info, scan_untracked) then
        return nil
    end

    if not scan_untracked then
        info.untracked = _cache.git_untracked_count
    end
    info.untracked_refreshed = scan_untracked
    info.dirty_dir  = info.untracked > 0 or false
    info.dirty_branch = info.conflicted > 0 or info.modified > 0 or info.renamed > 0 or
        info.deleted > 0 or info.staged > 0 or info.tracked > 0 or info.dirty_dir

    return info
end

-- stringify git status info
local function git_render(info)
    local fmt = config.status_format

    local parts = {}
    if info.upstream and not info.has_ab then
        -- upstream configured but counts unknown: gone upstream or ahead_behind=false
        parts[#parts + 1] = fmt.ab_unknown
    elseif info.ahead > 0 or info.behind > 0 then
        parts[#parts + 1] = (info.ahead > 0 and info.behind > 0 and fmt.diverged or '') ..
            (info.ahead > 0 and (fmt.ahead):format(info.ahead) or '') ..
            (info.behind > 0 and (fmt.behind):format(info.behind) or '')
    end
    if info.conflicted > 0 then parts[#parts + 1] = (fmt.conflicted):format(info.conflicted) end
    if info.modified > 0 then parts[#parts + 1] = (fmt.modified):format(info.modified) end
    if info.renamed > 0 then parts[#parts + 1] = (fmt.renamed):format(info.renamed) end
    if info.deleted > 0 then parts[#parts + 1] = (fmt.deleted):format(info.deleted) end
    if info.staged > 0 then parts[#parts + 1] = (fmt.staged):format(info.staged) end
    if info.tracked > 0 then parts[#parts + 1] = (fmt.tracked):format(info.tracked) end
    if info.untracked > 0 then parts[#parts + 1] = (fmt.untracked):format(info.untracked) end

    -- color is applied at render time in rightfilter so pending status can be dimmed
    return concat(parts, ' ')
end

local function fmt_duration(s)
    -- clock precision 1e-6
    if not s or s < 1e-6 then return '' end

    -- round to the display unit first so rollover can't render '1000µs' or '1m60s'
    if s < 1e-3 then
        local us = floor(s*1000000 + 0.5)
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

-- measure the duration of last run command
-- blank input is measured too: it shows the real Enter-to-prompt roundtrip
-- (including cmd's hidden errorlevel capture), never a stale reading
local last_start, last_dur_s
local last_input_blank = false
-- true when the last input provably couldn't change git state
local last_input_neutral = false
-- bumped whenever an input line may have changed git state; an async status
-- collection is applied only when the count it started with is still current
local mutation_count = 0

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
    if os.getaliases then
        local aliases = os.getaliases()
        if aliases then
            for i = 1, #aliases do
                if aliases[i]:lower() == first then
                    return false
                end
            end
        end
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
        if not sub then
            return false
        end
        sub = sub:lower()
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

-- the cached status can be reused without spawning git when the last input
-- couldn't change git state and the cache is fresh enough
local function git_status_is_fresh()
    if not last_input_neutral then
        return false
    end
    local age = config.blank_input_reuse_age
    if not age or age <= 0 then
        return false
    end
    return _cache.git_status_at ~= nil and (clock() - _cache.git_status_at) < age
end

local function dir_name()
    local cwd = _cache.cwd
    local base = basename_any_path(cwd)
    if base and #base > 0 then return base end

    -- at drive root give readable name, e.g. for 'C:\' give 'C:'
    return cwd:match('^(%a:)') or cwd
end

-- read a git config value; runs inside the status coroutine, at most once per session
local function git_config_value(name)
    if not (git.makecommand and io.popenyield) then return nil end
    local cmd = git.makecommand('config --get ' .. name)
    if not cmd then return nil end
    local f, pclose = io.popenyield(cmd, 'rt')
    if not f then return nil end
    local out = f:read('*a')
    if pclose then pclose() else f:close() end
    return trim(out)
end

local function check_fsmonitor_hint(duration)
    if not config.fsmonitor_hint or fsmonitor_hint_done then return end
    if duration < config.fsmonitor_hint_threshold then
        slow_status_count = 0
        return
    end
    slow_status_count = slow_status_count + 1
    if slow_status_count < config.fsmonitor_hint_count then return end
    fsmonitor_hint_done = true
    if not git_config_value('core.fsmonitor') then
        pending_hint = format(
            'snapline: git status took >%.0fms %d times in a row - consider "git config core.fsmonitor true", "git config core.untrackedCache true" and "git maintenance start" for this repo',
            config.fsmonitor_hint_threshold * 1000, config.fsmonitor_hint_count)
    end
end

-- async status collection
--
-- Each refresh runs in its own coroutine marked runcoroutineuntilcomplete, so
-- unlike clink.promptcoroutine it survives Enter: on a slow repo the status
-- lands on a later prompt instead of being canceled and restarted (and
-- restarted...) by every command.  The result is applied to _cache only when
-- the repo is still the same and no git-mutating input ran meanwhile.
local status_inflight = nil    -- refresh currently collecting, nil when idle
local inflight_count = 0       -- includes abandoned refreshes still finishing

local function collect_profile()
    local response = {}
    -- duration is always measured since it drives the fsmonitor hint,
    -- config.profile only controls displaying it in the prompt
    response.duration = clock()
    response.info = collect_status()
    response.duration = clock() - response.duration
    response.finished_at = clock()
    if response.info then
        check_fsmonitor_hint(response.duration)
    end
    if config.stash_git_fallback and not _cache.stash_path and git.getstashcount then
        response.stash_count = to_int(git.getstashcount())
    end
    return response
end

local function apply_status_response(rec, response)
    -- discard when the repo changed or a git-mutating command ran since the
    -- collection started: the data describes a state that no longer exists
    if rec.mutation ~= mutation_count or rec.git_dir ~= _cache.git_dir then
        return
    end
    local info = response.info
    if not info then
        -- keep the old render but leave it marked stale: it was NOT refreshed
        _cache.git_status_failed = true
        return
    end
    _cache.git_status_failed = false
    _cache.git_branch    = info.branch or _cache.git_branch
    _cache.dirty_branch  = info.dirty_branch
    _cache.dirty_dir     = info.dirty_dir
    _cache.git_render_text = git_render(info)
    _cache.git_status_at = response.finished_at or clock()
    set_git_upstream_cache(info.upstream, info.branch)
    if info.untracked_refreshed then
        _cache.git_untracked_at = response.finished_at or clock()
        _cache.git_untracked_count = info.untracked
    end
    if config.profile and response.duration then
        _cache.git_duration = fmt_duration(response.duration)
    end
    if response.stash_count then
        set_stash_cache(nil, nil, nil, response.stash_count)
        set_stash_prompt(response.stash_count)
    end
end

local function start_status_refresh()
    if not _cache.git_dir then
        return
    end
    if status_inflight then
        if status_inflight.mutation == mutation_count and status_inflight.git_dir == _cache.git_dir then
            -- a refresh for exactly this state is already collecting
            return
        end
        status_inflight.abandoned = true
        status_inflight = nil
    end
    if inflight_count >= 4 then
        -- git is hanging (network repo?); don't pile up more processes
        return
    end

    local rec = { git_dir = _cache.git_dir, mutation = mutation_count }
    inflight_count = inflight_count + 1
    rec.co = coroutine.create(function ()
        local response = collect_profile()
        inflight_count = inflight_count - 1
        if status_inflight == rec then
            status_inflight = nil
        end
        if not rec.abandoned then
            apply_status_response(rec, response)
            clink.refilterprompt()
        end
    end)
    status_inflight = rec
    -- clink auto-resumes created coroutines while editing is idle
    if clink.setcoroutinename then clink.setcoroutinename(rec.co, 'snapline status') end
    if clink.runcoroutineuntilcomplete then clink.runcoroutineuntilcomplete(rec.co) end
end

-- repo watcher: while idle at the prompt, µs-scale file probes detect git
-- state changed by other terminals/editors and trigger an async refresh, so
-- the prompt corrects itself without Enter
local function repo_signature()
    local gd = _cache.git_dir
    if not gd then
        return nil
    end
    local common = (git.getcommondir and git.getcommondir()) or gd
    local sig = {}
    sig[#sig + 1] = get_file_stamp(join_path(gd, 'index')) or '-'
    sig[#sig + 1] = get_file_stamp(join_path(gd, 'HEAD')) or '-'
    sig[#sig + 1] = get_file_stamp(join_path(gd, 'MERGE_HEAD')) or '-'
    sig[#sig + 1] = get_file_stamp(join_path(gd, 'rebase-merge')) or '-'
    sig[#sig + 1] = get_file_stamp(join_path(gd, 'rebase-apply')) or '-'
    sig[#sig + 1] = get_file_stamp(join_path(common, 'packed-refs')) or '-'
    sig[#sig + 1] = get_file_stamp(join_path(common, 'FETCH_HEAD')) or '-'
    sig[#sig + 1] = get_file_stamp(join_path(join_path(join_path(common, 'logs'), 'refs'), 'stash')) or '-'
    local branch = _cache.git_branch
    if branch then
        -- git forbids space, :, ?, *, [, \ and .. in ref names, so the loose
        -- ref path is safe to probe directly ('/' works in Win32 file APIs)
        sig[#sig + 1] = get_file_stamp(common .. PATH_SEP .. 'refs' .. PATH_SEP .. 'heads' .. PATH_SEP .. branch) or '-'
    end
    return concat(sig, ';')
end

local function start_repo_watcher()
    if not config.watch_repo or watcher_started or not _cache.git_dir then
        return
    end
    watcher_started = true
    -- created without runcoroutineuntilcomplete: clink cancels it when the
    -- edit session ends, and the next session's filter starts a fresh one
    local co = coroutine.create(function ()
        local base = nil
        while true do
            coroutine.yield()
            local ok, sig = pcall(repo_signature)
            if not ok or not sig then
                break
            end
            if base == nil then
                base = sig
            elseif sig ~= base then
                base = sig
                pcall(refresh_stash_cache)
                pcall(refresh_fetch_age)
                start_status_refresh()
                clink.refilterprompt()
            end
        end
    end)
    if clink.setcoroutinename then clink.setcoroutinename(co, 'snapline watch') end
    if clink.setcoroutineinterval then clink.setcoroutineinterval(co, config.watch_interval) end
end

local function git_left_prompt()
    local prompt_parts = {}

    local branch = _cache.git_branch
    if branch then
        local branch_color = config.color.reset
        if _cache.dirty_branch ~= nil then
            branch_color = _cache.dirty_branch and config.color.dirty or config.color.clean
        end
        prompt_parts[#prompt_parts+1] = branch_color .. config.branch_symbol .. branch .. config.color.reset
    end

    -- https://github.com/chrisant996/clink/blob/master/clink/app/scripts/git.lua#L732
    -- rebase-i rebase-m rebase am am/rebase merging cherry-picking reverting bisecting
    local action = git.getaction and git.getaction() or nil
    if action then
        -- forbidden symbols [-/]
        local action_key = action:gsub('[-/]', '_')
        local symbol = config.action_symbol[action_key] or config.action_symbol.unknown
        prompt_parts[#prompt_parts+1] = config.color.state .. symbol .. config.color.reset
    end

    return concat(prompt_parts, ' ')
end

local function fmt_last_cmd_duration()
    if not last_dur_s or last_dur_s < config.min_duration_display then return '' end

    local d = fmt_duration(last_dur_s)
    if d == '' then return '' end

    -- limit command time duration width to 5 characters
    if #d < 5 then d = format('%5s', d) end

    return config.color.took .. d .. config.color.reset
end

-- '> ' marker carrying the last exit code when nonzero, e.g. '✗1 > '
-- requires Clink setting 'cmd.get_errorlevel' (on by default)
local function errorlevel_prompt_char()
    if config.errorlevel_indicator then
        local code = os.geterrorlevel and os.geterrorlevel() or to_int(getenv('ERRORLEVEL'))
        if code ~= 0 then
            -- negative codes are NTSTATUS values, e.g. 0xC0000005 access violation
            local shown = code < 0 and format('0x%08X', code + 4294967296) or code
            return config.color.dirty .. config.error_symbol .. shown .. config.color.reset .. ' > '
        end
    end
    return '> '
end

local FILTER_PRIORITY = 100  -- lower priority ids are called first
local pf = clink.promptfilter(FILTER_PRIORITY)
-- true while an async status refresh is still pending for the shown status
local git_status_stale = false
-- left prompt, first in execution line so it kicks off the async refresh
function pf:filter()
    -- decide once per input line session; a refilter after an async apply
    -- must not start another refresh or applies would loop forever
    if _cache.git_dir and not session_refresh_started then
        session_refresh_started = true
        -- spawn git only when the cached status isn't provably fresh
        if not git_status_is_fresh() then
            start_status_refresh()
        end
    end
    start_repo_watcher()
    git_status_stale = _cache.git_dir ~= nil and
        ((status_inflight ~= nil and status_inflight.git_dir == _cache.git_dir) or
         _cache.git_status_failed)

    local dir_color = config.color.reset
    if _cache.dirty_dir ~= nil then
        dir_color = _cache.dirty_dir and config.color.dirty or config.color.clean
    end

    local venv = _cache.venv
    local prompt_parts = {}
    append_non_empty(prompt_parts, (venv and #venv > 0) and (config.color.venv .. '{' .. venv .. '}' .. config.color.reset) or nil)
    append_non_empty(prompt_parts, git_left_prompt())
    append_non_empty(prompt_parts, dir_color..dir_name()..config.color.reset)
    append_non_empty(prompt_parts, errorlevel_prompt_char())
    return concat(prompt_parts, ' ')
end
-- right filter, second in execution line, renders only cached values
function pf:rightfilter()
    -- in a repo the status render must not be an empty string or the right
    -- prompt doesn't get redrawn after async! - with no glyphs still emit colors
    local git_status_prompt = nil
    if _cache.git_render_text then
        local color = config.color.clean
        if config.dim_stale_status and git_status_stale then
            color = config.color.took
        elseif _cache.dirty_branch then
            color = config.color.dirty
        end
        git_status_prompt = color .. _cache.git_render_text .. config.color.reset
    elseif _cache.git_dir and git_status_stale then
        -- first status for this repo is still collecting
        git_status_prompt = config.color.took .. config.status_format.pending .. config.color.reset
    end

    local stash_prompt = _cache.stash_prompt or ''
    local right_prompt_time = config.color.now .. date('%H:%M:%S') .. config.color.reset

    local prompt_parts = {}
    append_non_empty(prompt_parts, _cache.git_duration)
    append_non_empty(prompt_parts, git_status_prompt)
    append_non_empty(prompt_parts, _cache.git_upstream_prompt)
    append_non_empty(prompt_parts, _cache.fetch_age_prompt)
    append_non_empty(prompt_parts, stash_prompt)
    append_non_empty(prompt_parts, _cache.python_prompt)
    append_non_empty(prompt_parts, fmt_last_cmd_duration())
    append_non_empty(prompt_parts, right_prompt_time)
    return concat(prompt_parts, ' ')
end
function pf:surround()
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
    return errorlevel_prompt_char()
end
function pf:transientrightfilter()
    -- time when the command was submitted, replacing the live clock
    return config.color.took .. date('%H:%M:%S') .. config.color.reset
end

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
        {'snapline hasstash',       hasstash},
        {'snapline getstashcount',  getstashcount},
        {'snapline collect_status', collect_status},
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
    local fmt, act, col = config.status_format, config.action_symbol, config.color

    -- pad to visible width: nerd glyphs are 3-4 bytes but render as 1-2 cells
    local function pad(s, width)
        local cells = (console and console.cellcount) and console.cellcount(s) or #s
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
    })
    print_rows('action', col.state, {
        { 'int rebase',     act.rebase_i,       'rebase merge', act.rebase_m },
        { 'rebase',         act.rebase,         'mail split',   act.am },
        { 'mail s. rebase', act.am_rebase,      'merging',      act.merging },
        { 'cherry-picking', act.cherry_picking, 'reverting',    act.reverting },
        { 'bisecting',      act.bisecting,      'unknown',      act.unknown },
    })
    print_rows('marks', col.reset, {
        { 'branch',         config.branch_symbol, 'exit code',  config.error_symbol .. 'N' },
    })
end

local function command_input_filter(text)
    if text and text:match('^%s*snapline%-bench%s*$') then
        run_bench()
        return ''
    end
    if text and text:match('^%s*snapline%-legend%s*$') then
        run_legend()
        return ''
    end
end

-- event handlers; beginedit order matters: capture the command duration
-- before the cache refreshes below add their own microseconds to it
local function on_beginedit_timing()
    if last_start then
        last_dur_s = clock() - last_start
        last_start = nil
    end
end

local function on_endedit(line)
    last_input_blank = not (line and line:find('%S'))
    last_input_neutral = last_input_blank or is_status_neutral_input(line or '')
    if not last_input_neutral then
        mutation_count = mutation_count + 1
    end
    last_start = clock()
end

refresh_runtime_cache()
refresh_stash_cache()
refresh_fetch_age()

clink.onbeginedit(on_beginedit_timing)
clink.onbeginedit(refresh_runtime_cache)
clink.onbeginedit(refresh_stash_cache)
clink.onbeginedit(refresh_fetch_age)
clink.onendedit(on_endedit)
if clink.onfilterinput then
    clink.onfilterinput(command_input_filter)
end
