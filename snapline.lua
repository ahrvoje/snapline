-- snapline - fast async git status prompt renderer for clink
--     by Hrvoje Abraham ahrvoje@gmail.com

-- Legend: conflicted=' |N' ahead=' ⇡N' behind=' ⇣N' diverged=' ⇕⇡A⇣B' tracked=' ?'
--         stashed=' ≡N' modified=' !N' staged=' +N' renamed=' »N' deleted=' XN' untracked=' ??'
-- In-progress git state indicator (yellow unicode char): rebase/am/merge/cherry-pick/revert/bisect

local clock  = os.clock      -- Clink clock returning seconds with us precision
local concat = table.concat
local floor  = math.floor
local format = string.format
local getenv = os.getenv

-- cached values used for fast prompt render to keep CLI snappy
-- every use of cached value is refreshed upon async op finish
local function get_init_cache()
    return {
        cwd = '',
        stash_path = nil,
        stash_size = nil,
        stash_count = 0,
        git_render = '',
        git_duration = '',
        dirty_branch = nil,
        dirty_dir = nil,
    }
end
local _cache = get_init_cache()
-- invalidate cache on dir change
clink.onbeginedit(function ()
    local cwd = getenv('CD') or ''
    if cwd ~= _cache.cwd then
        _cache = get_init_cache()
        _cache.cwd = cwd
    end
end)

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
    
    branch_symbol = '\238\130\160',     -- UTF-8 code for branch glyph
    color = {
        venv = '\x1b[33m',              -- yellow
        state = '\x1b[33m',             -- yellow
        clean = '\x1b[32m',             -- green
        dirty = '\x1b[38;2;200;90;90m', -- red
        took  = '\x1b[38;5;242m',       -- gray (bright black)
        now   = '\x1b[38;5;109m',       -- dim cyan
        reset = '\x1b[0m',
    },
    -- https://chrisant996.github.io/clink/clink.html#git.getstatus
    status_format = {
        diverged   = '⇕',    -- if ahead and behind at the same time
        ahead      = '⇡%d',
        behind     = '⇣%d',
        conflicted = '\243\177\144\139%d',  -- UTF-8 code for thunder glyph
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
        rebase         = '\239\129\162',
        am             = '\238\172\156',
        am_rebase      = 'amR',
        merging        = '\243\176\189\156',
        cherry_picking = '\238\138\155',
        reverting      = '\239\129\160',
        bisecting      = '\243\176\135\148',
        unknown        = '?',
    },
    profile = false,
}

-- remove nil and '' elements from a table
local function clean(t)
    local out = {}
    
    for _, s in ipairs(t) do
        if s and s ~= '' then out[#out+1] = s end
    end
    
    return out
end

-- recursive walk and format Lua table
-- local function prettyformat(t,i,s)
--     if not t then return '' end
--     
--     i = i or ''
--     s = s or {}
--     if s[t] then return '<cycle>' end s[t]=1
--     
--     local o = {'{'}
--     for k, v in pairs(t) do
--         k = type(k)=='string' and format('%q', k) or tostring(k)
--         v = type(v)=='table' and prettyformat(v, i..'  ', s) or (type(v)=='string' and format('%q', v) or tostring(v))
--         o[#o+1] = ('\n%s  [%s]=%s,'):format(i, k, v)
--     end
--     
--     s[t] = nil
--     o[#o+1] = '\n'..i..'}'
--     
--     return concat(o)
-- end

-- extract venv name from env vars
local function venv_name()
    local v = getenv('VIRTUAL_ENV')
    if v and #v > 0 then return path.getbasename(v) end
    
    -- conda
    local cpm = getenv('CONDA_PROMPT_MODIFIER')
    if cpm and #cpm > 0 then
        local s = cpm:gsub('^%s*%(', ''):gsub('%)%s*$', '')
        if #s > 0 then return s end
    end
    local c = getenv('CONDA_DEFAULT_ENV')
    if c and #c > 0 then return c end
    
    -- python
    local pv = getenv('PYENV_VERSION')
    if pv and #pv > 0 then return pv end
    
    return nil
end

local function getstashsizepath()
    local gd = git.getgitdir()
    if not gd then return nil, nil end
    
    local stashpath = gd .. '\\logs\\refs\\stash'
    local f = io.open(stashpath, 'rb')
    if not f then return nil, nil end
    
    -- getting file size is super quick, use opportunity to get it here
    local sz = f:seek('end')
    f:close()
    
    return sz, stashpath
end

-- fast stash check based on checking if .git\logs\refs\stash is empty
local function hasstash()
    return (getstashsizepath() or 0) > 0
end

-- fast stash count based on counting .git\logs\refs\stash lines
local function getstashcount()
    local sz, stashpath = getstashsizepath()
    if not sz or not stashpath then return 0 end
    
    -- return cached stash count if cache is of the same path and stash file size
    if _cache.stash_size and stashpath == _cache.stash_path and sz == _cache.stash_size then
        return _cache.stash_count
    end
    _cache.stash_size = sz
    _cache.stash_path = stashpath
    
    local f = io.open(stashpath, 'rb')
    if not f then
        _cache.stash_count = 0
    else    
        _, _cache.stash_count = f:read('*a'):gsub('\n', '\n')
        f:close()
    end
    
    return _cache.stash_count
end

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
local function collect_status()
    if not git.isgitdir() then return nil end

    local info = {
        ahead        = 0,
        behind       = 0,
        tracked      = 0,
        untracked    = 0,
        modified     = 0,
        staged       = 0,
        renamed      = 0,
        deleted      = 0,
        conflicted   = 0,
        dirty_branch = nil,
        dirty_dir    = nil,
    }
    
    -- arg1: ignore untracked, arg2: include submodules
    local status = git.getstatus(false, false)
    if not status then return nil end
    -- print(prettyformat(status))  -- for debugging
    
    info.dirty_branch = status.dirty and true or false
    
    -- ahead/behind (numbers or nil)
    info.ahead  = tonumber(status.ahead)  or 0
    info.behind = tonumber(status.behind) or 0
    
    -- file counts
    info.conflicted = status.conflict or 0
    info.tracked    = status.tracked or 0
    info.untracked  = status.untracked or 0
    info.dirty_dir  = info.untracked > 0 or false
    
    -- working tree modifications
    if status.working then
        info.modified = status.working.modify or 0
        -- also exists status.working.untracked
    end
    
    -- staged changes; sum add/modify/delete/rename (copy is folded into rename)
    if status.staged then
        local s = 0
        if status.staged.add    then s = s + status.staged.add    end
        if status.staged.modify then s = s + status.staged.modify end
        if status.staged.delete then s = s + status.staged.delete end
        if status.staged.rename then s = s + status.staged.rename end
        info.staged  = s
        info.renamed = status.staged.rename or 0
    end
    
    -- unique deletes across working+index
    if status.total and status.total.delete then
        info.deleted = status.total.delete
    end
    
    return info
end

-- stringify git status info
local function git_render(info)
    local fmt = config.status_format
    
    local s = {}
    if info.ahead > 0 or info.behind > 0 then
        s[#s+1] = (info.ahead>0  and info.behind>0 and fmt.diverged   or '') ..
                  (info.ahead>0  and (fmt.ahead):format(info.ahead)   or '') ..
                  (info.behind>0 and (fmt.behind):format(info.behind) or '')
    end
    if info.conflicted > 0 then s[#s+1] = (fmt.conflicted):format(info.conflicted) end
    if info.modified   > 0 then s[#s+1] = (fmt.modified):format(info.modified)     end
    if info.renamed    > 0 then s[#s+1] = (fmt.renamed):format(info.renamed)       end
    if info.deleted    > 0 then s[#s+1] = (fmt.deleted):format(info.deleted)       end
    if info.staged     > 0 then s[#s+1] = (fmt.staged):format(info.staged)         end
    if info.tracked    > 0 then s[#s+1] = (fmt.tracked):format(info.tracked)       end
    if info.untracked  > 0 then s[#s+1] = (fmt.untracked):format(info.untracked)   end
    
    -- render must not be empty string or right prompt doesn't get redrawn after async!
    -- so if git info is empty still return it wrapped in colors - don't simplify to ''
    local color = info.dirty_branch and config.color.dirty or config.color.clean
    return color .. concat(s, ' ') .. config.color.reset
end

local function fmt_duration(s)
    local CLOCK_PRECISION = 1e-6  -- Clink clock returning seconds with us precision
    if not s or s < CLOCK_PRECISION then return '' end
    
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
local last_start, last_dur_s, right_prompt_time
if clink and clink.onbeginedit then
    clink.onbeginedit(function ()
        if last_start then
            last_dur_s = clock() - last_start
            last_start = nil
        end
        
        right_prompt_time = config.color.now .. os.date('%H:%M:%S') .. config.color.reset
        
        local d = fmt_duration(last_dur_s)
        if d ~= '' then
            local MINIMAL_WIDTH = 5
            if #d < MINIMAL_WIDTH then d = format('%5s', d) end
            right_prompt_time = config.color.took .. d .. ' ' .. right_prompt_time
        end
    end)
end
if clink and clink.onendedit then
    clink.onendedit(function ()
        last_start = clock()
    end)
end

local function dir_name()
    local cwd = _cache.cwd
    local base = path.getbasename(cwd)
    if base and #base > 0 then return base end
    
    -- at drive root give readable name, e.g. for 'C:\' give 'C:'
    return cwd:match('^(%a:)') or cwd
end

local function profile()
    local response = {}
    
    if config.profile then response.duration = clock() end
    response.info = collect_status()
    if config.profile then response.duration = clock() - response.duration end
    
    return response
end

local function git_left_prompt()
    local prompt_parts = {}
    
    local branch = git.getbranch()
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
        local FORBIDDEN_SYMBOLS = '[-/]'  -- replace with '_'
        local action_key = action:gsub(FORBIDDEN_SYMBOLS, '_')
        local symbol = config.action_symbol[action_key] or config.action_symbol.unknown
        prompt_parts[#prompt_parts+1] = config.color.state .. symbol .. config.color.reset
    end
    
    return concat(prompt_parts, ' ')
end

local FILTER_PRIORITY = 100  -- lower priority ids are called first
local pf = clink.promptfilter(FILTER_PRIORITY)
-- left prompt, first in execution line so it contains async promptcoroutine
function pf:filter()
    local response = clink.promptcoroutine(profile)
    if response and response.info then
        _cache.dirty_branch = response.info.dirty_branch
        _cache.dirty_dir    = response.info.dirty_dir
        _cache.git_render   = git_render(response.info)
    end
    if config.profile and response and response.duration then
        _cache.git_duration = fmt_duration(response.duration)
    end
    
    local dir_color = config.color.reset
    if _cache.dirty_dir ~= nil then
        dir_color = _cache.dirty_dir and config.color.dirty or config.color.clean
    end
    
    local venv = venv_name()
    local prompt_parts = {
        venv and (config.color.venv .. '{' .. venv .. '}') or '',
        git_left_prompt(),
        dir_color..dir_name()..config.color.reset,
        '> ',
    }
    
    return concat(clean(prompt_parts), ' ')
end
-- right filter, second in execution line so it doesn't contain async calls
-- it uses cached values provided by the left prompt after its async call
function pf:rightfilter()
    local stash_count = getstashcount()
    local stash_prompt = (stash_count>0) and config.color.clean..(config.status_format.stashed):format(stash_count)..config.color.reset or ''
    
    local prompt_parts = {
        _cache.git_duration,
        _cache.git_render,
        stash_prompt,
        right_prompt_time,
    }
    
    return concat(clean(prompt_parts), ' ')
end
function pf:surround()
    -- clear line code before left prompt to clean entire line (left & right) before prompt render
    -- otherwise stray glyphs can persist if left prompt gets shorter after async call
    local CLEAR_LINE = '\x1b[2K'
    -- prefix, suffix, rprefix, rsuffix
    return CLEAR_LINE, '', '', ''
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
