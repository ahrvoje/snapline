-- snapline - fast async git status prompt renderer for clink
--     by Hrvoje Abraham ahrvoje@gmail.com

-- Legend: conflicted=' |N' ahead=' ⇡N' behind=' ⇣N' diverged=' ⇕⇡A⇣B' tracked=' ?'
--         stashed=' ≡N' modified=' !N' staged=' +N' renamed=' »N' deleted=' XN' untracked=' ??'
-- In-progress git state indicator (yellow unicode char): rebase/am/merge/cherry-pick/revert/bisect

-- cached values used for fast prompt render to keep CLI snappy
-- every use of cached value is refreshed upon async op finish
local _cache = { cwd = '', git_render = '', dirty_branch = nil, dirty_dir = nil, length = nil, offset = 0 }
-- Invalidate cache when directory changes
if clink and clink.onbeginedit then
    clink.onbeginedit(function ()
        local cwd = os.getenv('CD') or ''
        if cwd ~= _cache.cwd then
            _cache.cwd, _cache.git_render, _cache.dirty_branch, _cache.dirty_dir, _cache.length, offset = cwd, '', nil, nil, nil, 0
        end
    end)
end

local config = {
    branch_symbol = '\238\130\160',       -- UTF-8 code for branch glyph
    color_state = '\x1b[33m',             -- yellow
    color_clean = '\x1b[32m',             -- green
    color_dirty = '\x1b[38;2;200;90;90m', -- red
    color_took  = '\x1b[38;5;242m',       -- gray (bright black)
    color_time  = '\x1b[38;5;109m',       -- dim cyan
    color_reset = '\x1b[0m',
    -- https://chrisant996.github.io/clink/clink.html#git.getstatus
    status_format = {
        diverged   = '⇕',    -- if ahead and behind at the same time
        ahead      = '⇡%d',
        behind     = '⇣%d',
        conflicted = ' \243\177\144\139%d',  -- UTF-8 code for thunder glyph
        staged     = ' +%d',
        modified   = ' !%d',
        renamed    = ' »%d',
        deleted    = ' X%d',
        tracked    = ' ?%d',
        untracked  = ' ??%d',
        stashed    = ' ≡%d',
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
    },
    profile = false,
}

-- print("diverged  ⇕          ahead       ⇡")
-- print("behind    ⇣          conflicted  \243\177\144\139")
-- print("staged    +          modified    !")
-- print("renamed   »          deleted     X")
-- print("tracked   ?          untracked   ??")
-- print("stashed   ≡")
-- print()
-- 
-- print("int rebase      Ri        rebase merge  Rm")
-- print("rebase          \239\129\162         mail split    \238\172\156")
-- print("mail s. rebase  amR       merging       \243\176\189\156")
-- print("cherry-picking  \238\138\155         reverting     \239\129\160")
-- print("bisecting       \243\176\135\148")
-- print()
-- print()

-- recursive walk and format Lua table
local function pp(t,i,s)
    i=i or '' s=s or {}
    if s[t] then return '<cycle>' end s[t]=1
    local o={'{'}
    for k,v in pairs(t) do
        k=type(k)=='string' and string.format('%q',k) or tostring(k)
        v=type(v)=='table' and pp(v,i..'  ',s) or (type(v)=='string' and string.format('%q',v) or tostring(v))
        o[#o+1]=('\n%s  [%s]=%s,'):format(i,k,v)
    end
    s[t]=nil; o[#o+1]='\n'..i..'}'
    return table.concat(o)
end

-- prettyprint Lua table
function prettyprint(x, rl_buffer)
    if rl_buffer and rl_buffer.beginoutput then rl_buffer:beginoutput() end
    (clink and clink.print or print)(type(x)=='table' and pp(x) or tostring(x))
end

-- git status table using Clink's git API
local function collect_status()
    local info = {
        ahead        = 0,
        behind       = 0,
        stash        = 0,
        tracked      = 0,
        untracked    = 0,
        modified     = 0,
        staged       = 0,
        renamed      = 0,
        deleted      = 0,
        conflicted   = 0,
        dirty_branch = false,
        dirty_dir    = false,
        state        = nil,
        statech      = nil,
    }
    
    --    arg1 = no_untracked, arg2 = include_submodules
    local status = git.getstatus(false, false)
    
    if not status then
        info.dirty_branch  = nil
        info.dirty_dir = nil
    else
        -- prettyprint(status)
        
        -- overall dirty bit.
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
    end
    
    local sc = git.getstashcount()
    if sc then info.stash = sc end
    
    -- if ahead/behind missing from getstatus(), fallback to getaheadbehind()
    if (info.ahead == 0 and info.behind == 0) and status and (status.upstream ~= nil) then
        local ahead, behind = git.getaheadbehind()
        if ahead or behind then
            info.ahead  = tonumber(ahead)  or info.ahead
            info.behind = tonumber(behind) or info.behind
        end
    end
        
    return info
end

-- stringify git status info
local function git_render(info)
    local fmt = config.status_format
    
    local s = {}
    if info.ahead      > 0 or  info.behind > 0 then s[#s+1] = ' '                  end
    if info.ahead      > 0 and info.behind > 0 then s[#s+1] = fmt.diverged         end
    if info.ahead      > 0 then s[#s+1] = (fmt.ahead):format(info.ahead)           end
    if info.behind     > 0 then s[#s+1] = (fmt.behind):format(info.behind)         end
    if info.conflicted > 0 then s[#s+1] = (fmt.conflicted):format(info.conflicted) end
    if info.modified   > 0 then s[#s+1] = (fmt.modified):format(info.modified)     end
    if info.renamed    > 0 then s[#s+1] = (fmt.renamed):format(info.renamed)       end
    if info.deleted    > 0 then s[#s+1] = (fmt.deleted):format(info.deleted)       end
    if info.staged     > 0 then s[#s+1] = (fmt.staged):format(info.staged)         end
    if info.tracked    > 0 then s[#s+1] = (fmt.tracked):format(info.tracked)       end
    if info.untracked  > 0 then s[#s+1] = (fmt.untracked):format(info.untracked)   end
    if info.stash      > 0 then s[#s+1] = (fmt.stashed):format(info.stash)         end
    
    local color = info.dirty_branch and config.color_dirty or config.color_clean
    return color .. table.concat(s) .. config.color_reset .. ' '
end

local strfmt, floor = string.format, os.date, math.floor
local function _rp_fmt_duration(s)
    if not s or s < 1e-6 then return '' end
    
    if s < 1e-3 then return strfmt('%.0fµs', s*1000000) end
    if s < 1    then return strfmt('%.0fms', s*1000) end
    if s < 60   then return strfmt('%.2fs', s) end
    
    local m = floor(s/60)
    local r = floor(s - m*60 + 0.5)
    if m < 60 then return strfmt('%dm%ds', m, r) end
    
    local h = floor(m/60); m = m % 60
    return strfmt('%dh%dm%ds', h, m, r)
end

-- use clink gethrtime as faster than system os.clock
local _now_s = (clink and clink.gethrtime) and clink.gethrtime or os.clock

-- measure the duration of last run command
local _rp_last_start, _rp_last_dur_s, _rp_text
if clink and clink.onbeginedit then
    clink.onbeginedit(function ()
        if _rp_last_start then
            _rp_last_dur_s = _now_s() - _rp_last_start
            _rp_last_start = nil
        end
        
        local t = os.date('%H:%M:%S')
        local d = _rp_fmt_duration(_rp_last_dur_s)
        if d == '' then
            _rp_text = config.color_time .. t
        else
            if #d<5 then d = string.format('%5s', d) end
            _rp_text = config.color_took .. d .. ' ' .. config.color_time .. t
        end
    end)
end
if clink and clink.onendedit then
    clink.onendedit(function ()
        _rp_last_start = _now_s()
    end)
end

local function folder_name()
    local cwd = os.getcwd() or ''
    local base = path.getbasename(cwd)
    if base and #base > 0 then return base end
    -- at drive root give readable name, e.g. for 'C:\' give 'C:'
    local drive = cwd:match('^(%a:)')
    return drive or cwd
end

local function profile()
    local response = {}
    
    if config.profile then response.duration = _now_s() end
    response.info = collect_status()
    if config.profile then response.duration = _now_s() - response.duration end
    
    return response
end

local function format_git_prompt()
    local git_prompt = ''

    local branch = git.getbranch()
    if branch then
        local branch_color = config.color_reset
        if _cache.dirty_branch ~= nil then
            branch_color = _cache.dirty_branch and config.color_dirty or config.color_clean
        end
        git_prompt = branch_color .. config.branch_symbol .. branch .. ' ' .. config.color_reset
    end
    
    -- https://github.com/chrisant996/clink/blob/master/clink/app/scripts/git.lua#L732
    -- rebase-i rebase-m rebase am am/rebase merging cherry-picking reverting bisecting
    local action = git.getaction()
    if action then
        action_key = action:gsub('-', '_'):gsub('/', '_')
        git_prompt = git_prompt .. config.color_state .. config.action_symbol[action_key] .. ' ' .. config.color_reset
    end
    
    return git_prompt
end

local pf = clink.promptfilter(300)
-- left prompt, it is first in execution line so it contains the async part
function pf:filter(prompt)
    local response = clink.promptcoroutine(profile)
    if response then
        _cache.dirty_branch = response.info.dirty_branch
        _cache.dirty_dir = response.info.dirty_dir
        _cache.git_render = git_render(response.info)
        if config.profile then
            _cache.git_render = _rp_fmt_duration(response.duration) .. _cache.git_render
        end
    end
    
    local dir_color = config.color_reset
    if _cache.dirty_dir ~= nil then
        dir_color = _cache.dirty_dir and config.color_dirty or config.color_clean
    end

    prompt = format_git_prompt() .. dir_color .. folder_name() .. config.color_reset .. ' > '
    
    if not _cache.length then
        _cache.length = #prompt
    else        
        -- if left prompt shrinks after async get offset to keep right prompt informed
        _cache.offset =  (_cache.length > #prompt) and (_cache.length - #prompt) or 0
        _cache.length = #prompt
    end
    
    return prompt
end
-- right filter, second in execution line so it just uses cached value
-- provided by the left prompt async which is run before it
function pf:rightfilter()
    prompt = _rp_text
    if _cache.git_render then
        prompt = _cache.git_render .. prompt
    end

    -- if left prompt is async and shrinks after async op
    -- make sure right prompt it aligned by correct amount
    return (' '):rep(_cache.offset) .. prompt
end
