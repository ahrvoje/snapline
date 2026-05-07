-- snapline - fast async git status prompt renderer for clink
--         by Hrvoje Abraham ahrvoje@gmail.com

-- Legend:  conflicted=' |N'      ahead=' ⇡N'   behind=' ⇣N'   diverged=' ⇕⇡A⇣B'   tracked=' ?'
--            modified=' !N'     staged=' +N'  deleted=' XN'  untracked=' ??'     stashed=' ≡N'  renamed=' »N'
-- In-progress git state indicator (yellow unicode char): rebase/am/merge/cherry-pick/revert/bisect

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
        pyvenv_cfg_size = nil,
        pyvenv_version = nil,
        stash_path = nil,
        stash_size = nil,
        stash_mtime = nil,
        stash_count = 0,
        stash_prompt = '',
        git_render = '',
        git_duration = '',
        dirty_branch = nil,
        dirty_dir = nil,
    }
end
local _cache = get_init_cache()

-- No-op outside Clink prompt runtime.
if not (clink and git and clink.promptfilter and clink.promptcoroutine and clink.onbeginedit and clink.onendedit) then
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
    stash_git_fallback = false,
    profile = false,
}

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

local function set_pyvenv_cache(path, size, version)
    _cache.pyvenv_cfg_path = path
    _cache.pyvenv_cfg_size = size
    _cache.pyvenv_version = version
end

local function clear_git_status_cache()
    _cache.git_upstream_key = nil
    _cache.git_upstream_prompt = ''
    _cache.git_untracked_at = nil
    _cache.git_untracked_count = 0
    _cache.git_render = ''
    _cache.git_duration = ''
    _cache.dirty_branch = nil
    _cache.dirty_dir = nil
end

local function clear_git_identity_cache()
    _cache.git_dir = nil
    _cache.git_branch = nil
    clear_git_status_cache()
end

local function set_git_upstream_cache(upstream)
    upstream = trim(upstream)
    if not upstream then
        _cache.git_upstream_key = nil
        _cache.git_upstream_prompt = ''
        return
    end
    if upstream == _cache.git_upstream_key then
        return
    end
    _cache.git_upstream_key = upstream
    _cache.git_upstream_prompt = config.color.now .. upstream .. config.color.reset
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

-- extract venv name from env vars
local function venv_name()
    return normalize_env_name(getenv('VIRTUAL_ENV_PROMPT'))
        or basename_any_path(getenv('VIRTUAL_ENV'))
        or normalize_env_name(getenv('CONDA_PROMPT_MODIFIER'))
        or normalize_env_name(getenv('CONDA_DEFAULT_ENV'))
        or normalize_env_name(getenv('PYENV_VERSION'))
end

local function get_cwd()
    return getenv('CD') or getenv('PWD') or ''
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
        set_pyvenv_cache(nil, nil, nil)
        return nil
    end
    
    local cfg_path = join_path(venv_root, 'pyvenv.cfg')
    local f = io.open(cfg_path, 'rb')
    if not f then
        set_pyvenv_cache(cfg_path, nil, nil)
        return nil
    end
    
    local sz = f:seek('end')
    if sz and cfg_path == _cache.pyvenv_cfg_path and sz == _cache.pyvenv_cfg_size then
        f:close()
        return _cache.pyvenv_version
    end
    if not sz then
        f:close()
        set_pyvenv_cache(cfg_path, nil, nil)
        return nil
    end
    
    f:seek('set', 0)
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
    
    set_pyvenv_cache(cfg_path, sz, ver)
    return ver
end

local function refresh_python_capsule()
    local source = nil
    local version = extract_python_version(getenv('PYTHON_VERSION')) or extract_python_version(getenv('UV_PYTHON'))
    
    local venv_root = getenv('VIRTUAL_ENV')
    if venv_root and #venv_root > 0 then
        source = getenv('UV_ACTIVE') and 'uv' or 'venv'
        version = get_cached_pyvenv_version(venv_root) or version
    else
        local conda_env = normalize_env_name(getenv('CONDA_DEFAULT_ENV'))
        if conda_env then
            source = 'conda'
        else
            local pyenv = normalize_env_name(getenv('PYENV_VERSION'))
            if pyenv then
                source = 'pyenv'
                version = extract_python_version(pyenv) or version
            elseif getenv('UV_ACTIVE') then
                source = 'uv'
            end
        end
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
        local branch = git.getbranch(gd, true)
        if branch and branch ~= '.invalid' then
            if _cache.git_branch and _cache.git_branch ~= branch then
                clear_git_status_cache()
            end
            _cache.git_branch = branch
        end
    end
end

-- refresh cache only on prompt boundaries, not every filter render
local function refresh_runtime_cache()
    local cwd = get_cwd()
    if cwd ~= _cache.cwd then
        _cache = get_init_cache()
        _cache.cwd = cwd
    end
    _cache.venv = venv_name()
    refresh_python_capsule()
    refresh_git_identity_cache()
end
refresh_runtime_cache()
clink.onbeginedit(refresh_runtime_cache)

local function get_file_mtime(p)
    if not (p and os.findfiles) then
        return nil
    end

    local ff = os.findfiles(p, 2, { files = true, dirs = false, hidden = true, system = true, dirsuffix = false })
    if not ff then
        return nil
    end

    local item = ff:next()
    ff:close()
    return item and item.mtime or nil
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
refresh_stash_cache()
clink.onbeginedit(refresh_stash_cache)

-- git status table using Clink's git API
-- potentialy slow function in the focus of the entire story!
--
-- typical benchmark times for a single call
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
    if minus then
        info.ahead = to_int(line:sub(plus + 1, sep - 1))
        info.behind = to_int(line:sub(minus + 1))
    end
end

local function update_status_branch(info, oid)
    if info.branch == '(detached)' and oid and oid ~= '(initial)' then
        info.branch = oid:sub(1, 7)
    end
end

local status_command_cache = {}
local function get_status_command(scan_untracked)
    local key = (scan_untracked and '1' or '0') .. (config.status_include_submodules and '1' or '0')
    local cached = status_command_cache[key]
    if cached then
        return cached
    end

    local cmd = 'status --porcelain=v2 --branch'
    cmd = cmd .. (scan_untracked and ' --untracked-files=normal' or ' --untracked-files=no')
    if not config.status_include_submodules then
        cmd = cmd .. ' --ignore-submodules=all'
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

    local oid = nil
    local conflicted, deleted, modified, renamed, staged, tracked, untracked = 0, 0, 0, 0, 0, 0, 0
    while true do
        local line = file:read('*line')
        if not line then break end

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

    local ok = true
    if pclose then
        ok = pclose()
    else
        ok = file:close()
    end
    update_status_branch(info, oid)
    info.conflicted = conflicted
    info.deleted = deleted
    info.modified = modified
    info.renamed = renamed
    info.staged = staged
    info.tracked = tracked
    info.untracked = untracked
    return ok and true or false
end

local function collect_status()
    local gd = (git.getgitdir and git.getgitdir()) or nil
    if not gd then return nil end

    local info = {
        git_dir      = gd,
        branch       = nil,
        upstream     = nil,
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
    if info.ahead > 0 or info.behind > 0 then
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
    
    -- render must not be empty string or right prompt doesn't get redrawn after async!
    -- so if git info is empty still return it wrapped in colors - don't simplify to ''
    local color = info.dirty_branch and config.color.dirty or config.color.clean
    return color .. concat(parts, ' ') .. config.color.reset
end

local function fmt_duration(s)
    -- clock precision 1e-6
    if not s or s < 1e-6 then return '' end
    
    if s < 1e-3 then return format('%.0fµs', s*1000000) end
    if s < 1    then return format('%.0fms', s*1000) end
    if s < 60   then return format('%.2fs', s) end
    
    local m = floor(s/60)
    local r = floor(s - m*60 + 0.5)
    if m < 60 then return format('%dm%ds', m, r) end
    
    local h, m = floor(m/60), m % 60
    return format('%dh%dm%ds', h, m, r)
end

-- measure the duration of last run command
local last_start, last_dur_s
clink.onbeginedit(function ()
    if last_start then
        last_dur_s = clock() - last_start
        last_start = nil
    end
end)
clink.onendedit(function ()
    last_start = clock()
end)

local function dir_name()
    local cwd = _cache.cwd
    local base = basename_any_path(cwd)
    if base and #base > 0 then return base end
    
    -- at drive root give readable name, e.g. for 'C:\' give 'C:'
    return cwd:match('^(%a:)') or cwd
end

local function profile()
    local response = {}
    response.cwd = _cache.cwd
    
    if config.profile then response.duration = clock() end
    response.info = collect_status()
    if config.profile then response.duration = clock() - response.duration end
    response.finished_at = clock()
    if config.stash_git_fallback and not _cache.stash_path and git.getstashcount then
        response.stash_count = to_int(git.getstashcount())
    end
    
    return response
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
    local action = git.getaction()
    if action then
        -- forbidden symbols [-/]
        local action_key = action:gsub('[-/]', '_')
        local symbol = config.action_symbol[action_key] or config.action_symbol.unknown
        prompt_parts[#prompt_parts+1] = config.color.state .. symbol .. config.color.reset
    end
    
    return concat(prompt_parts, ' ')
end

local function fmt_last_cmd_duration()
    local d = fmt_duration(last_dur_s)
    if d == '' then return '' end
    
    -- limit command time duration width to 5 characters
    if #d < 5 then d = format('%5s', d) end
    
    return config.color.took .. d .. config.color.clean
end

local FILTER_PRIORITY = 100  -- lower priority ids are called first
local pf = clink.promptfilter(FILTER_PRIORITY)
-- left prompt, first in execution line so it contains async promptcoroutine
function pf:filter()
    local response = clink.promptcoroutine(profile)
    if response and response.info and response.cwd == _cache.cwd then
        _cache.git_dir       = response.info.git_dir
        _cache.git_branch    = response.info.branch
        _cache.dirty_branch = response.info.dirty_branch
        _cache.dirty_dir    = response.info.dirty_dir
        _cache.git_render   = git_render(response.info)
        set_git_upstream_cache(response.info.upstream)
        if response.info.untracked_refreshed then
            _cache.git_untracked_at = response.finished_at or clock()
            _cache.git_untracked_count = response.info.untracked
        end
    end
    if config.profile and response and response.duration and response.cwd == _cache.cwd then
        _cache.git_duration = fmt_duration(response.duration)
    end
    if response and response.stash_count and response.cwd == _cache.cwd then
        set_stash_cache(nil, nil, nil, response.stash_count)
        set_stash_prompt(response.stash_count)
    end
    
    local dir_color = config.color.reset
    if _cache.dirty_dir ~= nil then
        dir_color = _cache.dirty_dir and config.color.dirty or config.color.clean
    end
    
    local venv = _cache.venv
    local prompt_parts = {}
    append_non_empty(prompt_parts, (venv and #venv > 0) and (config.color.venv .. '{' .. venv .. '}') or nil)
    append_non_empty(prompt_parts, git_left_prompt())
    append_non_empty(prompt_parts, dir_color..dir_name()..config.color.reset)
    append_non_empty(prompt_parts, '> ')
    return concat(prompt_parts, ' ')
end
-- right filter, second in execution line so it doesn't contain async calls
-- it uses cached values provided by the left prompt after its async call
function pf:rightfilter()
    local stash_prompt = _cache.stash_prompt or ''
    local right_prompt_time = config.color.now .. date('%H:%M:%S') .. config.color.reset

    local prompt_parts = {}
    append_non_empty(prompt_parts, _cache.git_duration)
    append_non_empty(prompt_parts, _cache.git_render)
    append_non_empty(prompt_parts, _cache.git_upstream_prompt)
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



------------------------------- MISC -------------------------------
-- action and status legend
-- print('diverged  ⇕          ahead       ⇡')
-- print('behind    ⇣          conflicted  \243\177\144\139')
-- print('staged    +          modified    !')
-- print('renamed   »          deleted     X')
-- print('tracked   ?          untracked   ??')
-- print('stashed   ≡')
-- print()
-- 
-- print('int rebase      Ri        rebase merge  Rm')
-- print('rebase          \239\129\162         mail split    \238\172\156')
-- print('mail s. rebase  amR       merging       \243\176\189\156')
-- print('cherry-picking  \238\138\155         reverting     \239\129\160')
-- print('bisecting       \243\176\135\148')
-- print()
-- print()

-- benchmark clink git API calls
-- local function time_loop(f)
--     local duration, n = clock(), 10
--     for i = 1, n do
--         _ = f()
--     end
--     return (clock() - duration) / n
-- end

-- local function bench()
--     local funs = {
--         {'getaction',         git.getaction},
--         {'getgitdir',         git.getgitdir},
--         {'hasstash',          git.hasstash},
--         {'getaheadbehind',    git.getaheadbehind},
--         {'getremote',         git.getremote},
--         {'isgitdir',          git.isgitdir},
--         {'getbranch',         git.getbranch},
--         {'getstashcount',     git.getstashcount},
--         {'getcommondir',      git.getcommondir},
--         {'getstatus',         git.getstatus},
--         {'getconflictstatus', git.getconflictstatus},
--         {'getsystemname',     git.getsystemname},
--     }
--     for i = 1, #funs do
--         duration = time_loop(funs[i][2])
--         duration_color = duration>0.01 and config.color.dirty or config.color.clean
--         print(duration_color .. format('%18s', funs[i][1]) .. '   ' .. fmt_duration(duration))
--     end
--     print()
-- end
-- clink.onbeginedit(function ()
--     bench()
-- end)

-- benchmark alternative fast functions
-- local function bench_alt()
--     local funs = {
--         {'',              nil},
--         {'',              nil},
--         {'hasstash',      hasstash},
--         {'',              nil},
--         {'',              nil},
--         {'',              nil},
--         {'',              nil},
--         {'getstashcount', getstashcount},
--         {'',              nil},
--         {'',              nil},
--         {'',              nil},
--         {'',              nil},
--     }
--     for i = 1, #funs do
--         if not funs[i][2] then
--             print()
--         else
--             duration = time_loop(funs[i][2])
--             duration_color = duration>0.01 and config.color.dirty or config.color.clean
--             print(duration_color .. format('%18s', funs[i][1]) .. '   ' .. fmt_duration(duration))
--         end
--     end
--     print()
-- end
-- clink.onbeginedit(function ()
--     bench_alt()
-- end)
