-- snapline test harness: stubs clink/git/popenyield and drives full edit
-- sessions against the shipped snapline.lua using clink's own Lua runtime
--
--     clink lua test\harness.lua        (from the repo root)
--
-- It builds a fake .git tree next to this script and needs no real repo.
local HERE = debug.getinfo(1, 'S').source:match('^@(.*[\\/])') or '.\\'
local REPO_GD  = HERE .. 'fakerepo\\.git'
local SNAPLINE = HERE .. '..\\snapline.lua'

-- fixture tree with real files: stash reflog with 2 entries, FETCH_HEAD
-- 5 days old (mtime set via powershell), index/HEAD/refs for the watcher
do
    local function write(path, content)
        local f = assert(io.open(path, 'wb'))
        f:write(content)
        f:close()
    end
    os.execute('cmd /c rmdir /s /q "' .. HERE .. 'fakerepo" 2>nul')
    os.execute('cmd /c mkdir "' .. REPO_GD .. '\\logs\\refs" "' .. REPO_GD .. '\\refs\\heads" 2>nul')
    write(REPO_GD .. '\\index', 'DIRC fake index content')
    write(REPO_GD .. '\\HEAD', 'ref: refs/heads/main\n')
    write(REPO_GD .. '\\FETCH_HEAD', 'abc123 def456 fetched\n')
    write(REPO_GD .. '\\logs\\refs\\stash', 'l1 stash@{0}\nl2 stash@{1}\n')
    write(REPO_GD .. '\\refs\\heads\\main', 'abc123\n')
    os.execute('powershell -NoProfile -Command "(Get-Item \'' .. REPO_GD ..
        '\\FETCH_HEAD\').LastWriteTime = (Get-Date).AddDays(-5)" >nul')
end

local DIRTY_SGR = '\27[38;2;200;90;90m'
local CLEAN_SGR = '\27[32m'
local DIM_SGR   = '\27[38;5;242m'

local tests, fails = 0, 0
local function check(cond, name)
    tests = tests + 1
    if cond then
        print('ok   ' .. name)
    else
        fails = fails + 1
        print('FAIL ' .. name)
    end
end

-- strip OSC/SGR/EL escapes for content matching
local function plain(s)
    s = s or ''
    s = s:gsub('\27%][^\27]*\27\\', '')
    s = s:gsub('\27%[[%d;:]*m', '')
    s = s:gsub('\27%[2K', '')
    return s
end

-- the SGR code in effect where glyph starts (color correctness checks)
local function color_at(s, glyph)
    local i = s:find(glyph, 1, true)
    if not i then return nil end
    local seg, last = s:sub(1, i - 1), nil
    for code in seg:gmatch('(\27%[[%d;:]*m)') do last = code end
    return last
end

if rawget(_G, 'NONL') == nil then
    rawset(_G, 'NONL', '\1NONL\1')
end

-- ===== stubs =====
local H  -- per-suite harness state
local G = {}  -- git repo state
local P = { calls = 0, lastcmd = '', porcelain = '', fail = false, slow = false,
            raise = false, stash_count = 2, config_value = '',
            errorlevel = 0, aliases = {} }
local CWD = { path = 'C:\\work\\proj' }
local NOW = 1000

local real_create = coroutine.create
coroutine.create = function (f)
    local co = real_create(f)
    if H then H.cos[#H.cos + 1] = co end
    return co
end

local function make_clink_stub()
    return {
        promptfilter = function () H.pf = {}; return H.pf end,
        onbeginedit = function (f) H.beginedit[#H.beginedit + 1] = f end,
        onendedit = function (f) H.endedit[#H.endedit + 1] = f end,
        onfilterinput = function (f) H.filterinput[#H.filterinput + 1] = f end,
        refilterprompt = function () H.refilters = H.refilters + 1 end,
        runcoroutineuntilcomplete = function (co) H.keep[co] = true end,
        setcoroutineinterval = function () end,
        setcoroutinename = function () end,
        getclinkprompt = function () return H.active_prompt end,
        print = function (...)
            local parts = {}
            local args = {...}
            for i = 1, #args do
                if args[i] ~= NONL then parts[#parts + 1] = tostring(args[i]) end
            end
            H.printed[#H.printed + 1] = table.concat(parts, ' ')
        end,
    }
end

local function make_git_stub()
    return {
        getgitdir = function () return G.gitdir end,
        getcommondir = function () return G.commondir or G.gitdir end,
        getbranch = function (git_dir, fast)
            G.branch_git_dir, G.branch_fast = git_dir, fast
            return G.branch
        end,
        getaction = function () return G.action, G.action_step, G.action_total end,
        makecommand = function (cmd) return 'git --no-optional-locks ' .. cmd .. ' 2>nul' end,
        getremote = function () return 'origin' end,
        isgitdir = function () return G.gitdir ~= nil end,
        getsystemname = function () return 'git' end,
        hasstash = function () return false end,
        getstashcount = function () return 0 end,
        getaheadbehind = function () return '0', '0' end,
        getstatus = function () return {} end,
        getconflictstatus = function () return false end,
    }
end

io.popenyield = function (cmd)
    P.calls = P.calls + 1
    P.lastcmd = cmd
    local out = ''
    if cmd:find('status --porcelain', 1, true) then
        local lines = {}
        for line in P.porcelain:gmatch('[^\r\n]+') do
            if not (cmd:find('--untracked-files=no ', 1, true) and line:sub(1, 1) == '?') then
                lines[#lines + 1] = line
            end
        end
        if P.stash_count and P.stash_count > 0 then
            lines[#lines + 1] = '# stash ' .. P.stash_count
        end
        out = table.concat(lines, '\n')
    elseif cmd:find('config --get', 1, true) then
        out = P.config_value or ''
    end
    local yielded = false
    local file = {
        read = function ()
            if P.raise then error('simulated popen read failure') end
            if P.slow and not yielded then
                yielded = true
                coroutine.yield()
            end
            return out
        end,
        close = function () return not P.fail end,
        seek = function () return 0 end,
    }
    return file, function () return not P.fail end
end

os.getcwd = function () return CWD.path end
os.getenv = function () return nil end
os.geterrorlevel = function () return P.errorlevel end
os.getaliases = function () return P.aliases end
os.clock = function () return NOW end

-- ===== session simulation =====
local function beginedit()
    for i = 1, #H.beginedit do H.beginedit[i]() end
end

local function endedit(line)
    for i = 1, #H.endedit do H.endedit[i](line) end
    local replaced
    for i = 1, #H.filterinput do
        local r = H.filterinput[i](line)
        if r ~= nil then replaced = r end
    end
    -- clink cancels coroutines at session end unless runcoroutineuntilcomplete
    local alive = {}
    for i = 1, #H.cos do
        local co = H.cos[i]
        if H.keep[co] and coroutine.status(co) ~= 'dead' then
            alive[#alive + 1] = co
        end
    end
    H.cos = alive
    return replaced
end

-- one scheduler pass: resume every alive coroutine once
local function tick()
    local snapshot = {}
    for i = 1, #H.cos do snapshot[i] = H.cos[i] end
    for i = 1, #snapshot do
        if coroutine.status(snapshot[i]) == 'suspended' then
            local ok, err = coroutine.resume(snapshot[i])
            if not ok then
                fails = fails + 1
                print('COROUTINE ERROR: ' .. tostring(err))
            end
        end
    end
end

local function load_snapline(overrides)
    H = { cos = {}, keep = {}, beginedit = {}, endedit = {}, filterinput = {},
          refilters = 0, printed = {}, pf = nil, active_prompt = '' }
    rawset(_G, 'snapline_config', overrides)
    rawset(_G, 'clink', make_clink_stub())
    rawset(_G, 'git', make_git_stub())
    G.gitdir, G.branch, G.action, G.commondir = nil, nil, nil, nil
    G.action_step, G.action_total = nil, nil
    G.branch_git_dir, G.branch_fast = nil, nil
    P.calls, P.lastcmd, P.porcelain = 0, '', ''
    P.fail, P.slow, P.raise, P.stash_count = false, false, false, 2
    P.config_value, P.errorlevel, P.aliases = '', 0, {}
    CWD.path = 'C:\\work\\proj'
    NOW = 1000
    dofile(SNAPLINE)
end

-- ===== porcelain fixtures =====
local PORC_DIRTY = table.concat({
    '# branch.oid 1234567890abcdef',
    '# branch.head main',
    '# branch.upstream origin/main',
    '# branch.ab +1 -2',
    '1 .M N... 100644 100644 100644 aaa bbb file1.txt',
    '1 M. N... 100644 100644 100644 aaa bbb file0.txt',
    '? newfile.txt',
}, '\n')
local PORC_STAGED = table.concat({
    '# branch.oid 1234567890abcdef',
    '# branch.head main',
    '# branch.upstream origin/main',
    '# branch.ab +0 -0',
    '1 M. N... 100644 100644 100644 aaa bbb file0.txt',
}, '\n')
local PORC_AHEAD = table.concat({
    '# branch.oid 1234567890abcdef',
    '# branch.head main',
    '# branch.upstream origin/main',
    '# branch.ab +1 -0',
}, '\n')
local PORC_AB_UNKNOWN = table.concat({
    '# branch.oid 1234567890abcdef',
    '# branch.head main',
    '# branch.upstream origin/main',
    '# branch.ab +? -?',
}, '\n')

-- =====================================================================
print('===== suite 1: default config =====')
load_snapline(nil)
check(H.pf ~= nil and H.pf.filter ~= nil, 'snapline loaded and registered a prompt filter')

-- T1 outside a repo
beginedit()
local left  = H.pf:filter()
local right = H.pf:rightfilter()
check(left ~= nil, 'empty getclinkprompt value keeps snapline active')
check(plain(left):find('proj > ', 1, true) ~= nil, 'non-repo left prompt shows dir and marker')
check(plain(right):match('%d%d:%d%d:%d%d') ~= nil, 'right prompt shows clock')
check(P.calls == 0, 'no git spawned outside a repo')

-- Last-command duration is content-width, not padded to a fixed field.
endedit('echo duration')
NOW = NOW + 0.007
beginedit()
right = plain(H.pf:rightfilter())
check(right:match('^7ms %d%d:%d%d:%d%d$') ~= nil,
    'single-digit duration has no leading empty space')

-- T2 first status in a repo
G.gitdir, G.branch = REPO_GD, 'main'
G.action, G.action_step, G.action_total = 'rebase-i', 3, 12
P.porcelain = PORC_DIRTY
endedit('git checkout main')
beginedit()
left  = H.pf:filter()
right = H.pf:rightfilter()
check(plain(left):find('main', 1, true) ~= nil, 'left prompt shows branch')
check(plain(left):find('Ri3/12', 1, true) ~= nil, 'left prompt shows action step/total progress')
check(G.branch_git_dir == REPO_GD and G.branch_fast == true,
    'branch lookup reuses git dir and requests nonblocking fast mode')
check(plain(right):find('…', 1, true) ~= nil, 'placeholder … while first status collects')
check(color_at(right, '…') == DIM_SGR, 'placeholder is dimmed')
check(P.calls == 0, 'prompt render spawned nothing synchronously')
tick()
check(P.calls == 1, 'exactly one git status ran')
check(P.lastcmd:find('--show-stash', 1, true) ~= nil, 'status command collects stash count')
check(P.lastcmd:find('--ignore-submodules=dirty', 1, true) ~= nil and
      P.lastcmd:find('--ignore-submodules=all', 1, true) == nil,
    'status preserves changed submodule commits without scanning nested dirt')
check(H.refilters == 1, 'async apply refiltered the prompt')
left  = H.pf:filter()
right = H.pf:rightfilter()
check(P.calls == 1, 'refilter did not spawn another git (session gate)')
local pright = plain(right)
check(pright:find('⇕⇡1⇣2', 1, true) ~= nil, 'diverged ahead/behind rendered')
check(pright:find('!1', 1, true) and pright:find('+1', 1, true) and pright:find('??1', 1, true),
    'modified/staged/untracked counts rendered')
check(color_at(right, '⇕⇡1⇣2') == DIRTY_SGR, 'dirty status rendered red')
check(color_at(left, 'main') == DIRTY_SGR, 'dirty branch rendered red')
check(pright:find('≡2', 1, true) ~= nil, 'stash count parsed from porcelain status')
check(pright:find('~5d', 1, true) ~= nil, 'fetch age shown for old FETCH_HEAD')
check(pright:find('origin', 1, true) ~= nil and pright:find('origin/main', 1, true) == nil,
    'upstream abbreviated to remote name')

-- T3 blank Enter reuse
G.action, G.action_step, G.action_total = nil, nil, nil
endedit('')
beginedit()
H.pf:filter()
right = H.pf:rightfilter()
tick()
check(P.calls == 1, 'blank Enter reused status without spawning git')
check(color_at(right, '⇕⇡1⇣2') == DIRTY_SGR, 'reused status rendered undimmed')

-- T4 neutral command reuse
endedit('git log -3')
beginedit(); H.pf:filter(); tick()
check(P.calls == 1, 'git log reused status without spawning git')
endedit('dir *.lua')
beginedit(); H.pf:filter(); tick()
check(P.calls == 1, 'dir reused status without spawning git')

-- T5 non-neutral input refreshes, dims while pending
P.porcelain = PORC_STAGED
local c5 = P.calls
endedit('git add .')
beginedit(); H.pf:filter()
right = H.pf:rightfilter()
check(color_at(right, '⇕⇡1⇣2') == DIM_SGR, 'stale glyphs dimmed while refresh pending')
tick()
check(P.calls == c5 + 1, 'git add triggered a refresh')
H.pf:filter()
right = H.pf:rightfilter()
pright = plain(right)
check(pright:find('+1', 1, true) ~= nil and pright:find('!1', 1, true) == nil, 'new status applied')
check(color_at(right, '+1') == DIRTY_SGR, 'applied status recolored')
endedit('git log > out.txt')
beginedit(); H.pf:filter(); tick()
check(P.calls == c5 + 2, 'redirection forces a refresh')
H.pf:filter()
P.aliases = { 'dir' }
endedit('dir')
beginedit(); H.pf:filter(); tick()
check(P.calls == c5 + 3, 'doskey-shadowed neutral command forces a refresh')
H.pf:filter()
P.aliases = {}

-- A potentially mutating command must force a full untracked scan even when
-- the previous full scan was less than two seconds ago.
local cu = P.calls
P.porcelain = PORC_DIRTY
P.stash_count = 0
endedit('echo x > newfile.txt')
beginedit(); H.pf:filter(); tick(); H.pf:filter()
check(P.calls == cu + 1, 'mutating command triggered status immediately')
check(P.lastcmd:find('--untracked-files=normal', 1, true) ~= nil,
    'mutating command invalidated throttled untracked count')
right = H.pf:rightfilter()
check(plain(right):find('??1', 1, true) ~= nil, 'new untracked entry shown immediately')
check(plain(right):find('≡', 1, true) == nil, 'zero porcelain stash count clears cached stash')
P.porcelain = PORC_STAGED

-- T6 in-flight refresh crossing sessions: abandoned on mutation
P.slow = true
local c6 = P.calls
endedit('git add a')
beginedit(); H.pf:filter()
tick()  -- co1 starts its popen and yields mid-read
check(P.calls == c6 + 1, 'slow refresh started')
local r0 = H.refilters
endedit('git add b')
beginedit(); H.pf:filter()
tick()  -- co1 completes abandoned; co2 starts and yields
check(P.calls == c6 + 2, 'in-flight refresh abandoned after mutating input, new one started')
tick()  -- co2 completes and applies
check(H.refilters == r0 + 1, 'abandoned refresh did not apply or refilter')
P.slow = false
H.pf:filter()

-- T7 failed refresh keeps status visibly stale
P.fail = true
endedit('git add c')
beginedit(); H.pf:filter(); tick()
H.pf:filter()
right = H.pf:rightfilter()
check(color_at(right, '+1') == DIM_SGR, 'failed refresh leaves status dimmed')
P.fail = false
local failed_calls = P.calls
endedit('')
beginedit(); H.pf:filter(); tick()
check(P.calls == failed_calls + 1, 'blank Enter retries a failed refresh despite fresh old cache')
H.pf:filter()
right = H.pf:rightfilter()
check(color_at(right, '+1') == DIRTY_SGR, 'status recovers after blank-Enter retry')

-- Exceptions inside collection must clean up inflight bookkeeping and permit
-- the following session to retry normally.
P.raise = true
endedit('git add throws')
beginedit(); H.pf:filter(); tick(); H.pf:filter()
right = H.pf:rightfilter()
check(color_at(right, '+1') == DIM_SGR, 'collection exception leaves cached status visibly stale')
P.raise = false
local raised_calls = P.calls
endedit('')
beginedit(); H.pf:filter(); tick(); H.pf:filter()
check(P.calls == raised_calls + 1, 'collection exception cleaned up and retried next session')
check(color_at(H.pf:rightfilter(), '+1') == DIRTY_SGR, 'status recovers after collection exception')

-- T8 upstream with unknown ahead/behind
P.porcelain = PORC_AB_UNKNOWN
endedit('git add e')
beginedit(); H.pf:filter(); tick(); H.pf:filter()
right = H.pf:rightfilter()
check(plain(right):find('⇡?', 1, true) ~= nil, 'ab_unknown glyph rendered for +? -?')

-- T9 cd within the same repo carries the status
CWD.path = 'C:\\work\\proj\\sub'
local c9 = P.calls
endedit('cd sub')
beginedit(); H.pf:filter(); tick()
check(P.calls == c9, 'cd within repo reused status without spawning git')
right = H.pf:rightfilter()
check(plain(right):find('⇡?', 1, true) ~= nil, 'status carried across cd within repo')
check(plain(H.pf:filter()):find('sub > ', 1, true) ~= nil, 'left prompt shows new dir')

-- T10 leaving the repo clears the status
CWD.path = 'C:\\elsewhere'
G.gitdir, G.branch = nil, nil
local c10 = P.calls
endedit('cd C:\\elsewhere')
beginedit(); H.pf:filter(); tick()
right = H.pf:rightfilter()
check(plain(right):find('⇡?', 1, true) == nil and plain(right):find('≡', 1, true) == nil,
    'status cleared outside repo')
check(P.calls == c10, 'no spawn outside repo')

-- T11 repo watcher: external change refreshes without Enter
CWD.path = 'C:\\work\\proj'
G.gitdir, G.branch = REPO_GD, 'main'
P.porcelain = PORC_DIRTY
endedit('cd C:\\work\\proj')
beginedit(); H.pf:filter(); tick(); H.pf:filter()
local calls0, ref1 = P.calls, H.refilters
local fh = io.open(REPO_GD .. '\\index', 'ab')
fh:write('x'); fh:close()
tick()
check(H.refilters == ref1 + 1, 'watcher detects change before its first probe')
tick()
check(P.calls == calls0 + 1, 'watcher-triggered status ran')
check(H.refilters == ref1 + 2, 'watcher-triggered status applied and refiltered')
tick()
check(P.calls == calls0 + 1, 'watcher stable after refresh (no spawn loop)')

-- T11b push from another terminal: only the remote-tracking ref moves,
-- ahead count must clear without Enter
os.execute('cmd /c mkdir "' .. REPO_GD .. '\\refs\\remotes\\origin" 2>nul')
fh = io.open(REPO_GD .. '\\refs\\remotes\\origin\\main', 'wb')
fh:write('abc123\n'); fh:close()
P.porcelain = PORC_STAGED
tick()
check(H.refilters == ref1 + 3, 'watcher detected remote-tracking ref update (push)')
tick()
check(P.calls == calls0 + 2, 'push-triggered status ran')
right = H.pf:rightfilter()
pright = plain(right)
check(pright:find('⇡', 1, true) == nil and pright:find('+1', 1, true) ~= nil,
    'ahead count cleared after push, status neutral')
tick()
check(P.calls == calls0 + 2, 'watcher stable after push refresh (no spawn loop)')

-- A ref rewrite normally keeps the same size and can share the same whole-
-- second mtime.  Content fingerprints must still notice it.
local same_size_calls, same_size_refilters = P.calls, H.refilters
fh = io.open(REPO_GD .. '\\refs\\remotes\\origin\\main', 'wb')
fh:write('def456\n'); fh:close()
P.porcelain = PORC_AHEAD
tick()
check(H.refilters == same_size_refilters + 1, 'watcher detects same-size ref rewrite')
tick()
check(P.calls == same_size_calls + 1, 'same-size ref rewrite triggered status')
check(plain(H.pf:rightfilter()):find('⇡1', 1, true) ~= nil,
    'same-size ref rewrite applied updated ahead state')
tick()

-- Reftable stacks change through tables.list rather than loose refs.
os.execute('cmd /c mkdir "' .. REPO_GD .. '\\reftable" 2>nul')
fh = io.open(REPO_GD .. '\\reftable\\tables.list', 'wb')
fh:write('one.ref\n'); fh:close()
local reftable_calls = P.calls
tick(); tick()
check(P.calls == reftable_calls + 1, 'watcher detects reftable stack creation')
fh = io.open(REPO_GD .. '\\reftable\\tables.list', 'wb')
fh:write('two.ref\n'); fh:close()
reftable_calls = P.calls
tick(); tick()
check(P.calls == reftable_calls + 1, 'watcher detects same-size reftable stack rewrite')
tick()

-- Rebase progress files are watched by content so progress updates while idle.
os.execute('cmd /c mkdir "' .. REPO_GD .. '\\rebase-merge" 2>nul')
fh = io.open(REPO_GD .. '\\rebase-merge\\msgnum', 'wb')
fh:write('1\n'); fh:close()
fh = io.open(REPO_GD .. '\\rebase-merge\\end', 'wb')
fh:write('3\n'); fh:close()
G.action, G.action_step, G.action_total = 'rebase-i', 1, 3
local action_calls = P.calls
tick()
check(plain(H.pf:filter()):find('Ri1/3', 1, true) ~= nil,
    'watcher renders newly started action progress immediately')
tick()
check(P.calls == action_calls + 1, 'new action state triggered status')
tick()
fh = io.open(REPO_GD .. '\\rebase-merge\\msgnum', 'wb')
fh:write('2\n'); fh:close()
G.action_step = 2
action_calls = P.calls
tick()
check(plain(H.pf:filter()):find('Ri2/3', 1, true) ~= nil,
    'watcher detects same-size action progress rewrite')
tick()
check(P.calls == action_calls + 1, 'action progress rewrite triggered status')
tick()

-- T11c push lands while a commit-triggered refresh is still collecting:
-- the in-flight (pre-push) data must be abandoned, not deduped against
P.porcelain = PORC_AHEAD
P.slow = true
fh = io.open(REPO_GD .. '\\index', 'ab')
fh:write('y'); fh:close()
tick()  -- watcher detects the commit, starts slow refresh A
tick()  -- A spawns git (captures pre-push ahead output) and yields mid-read
local c11c = P.calls
fh = io.open(REPO_GD .. '\\refs\\remotes\\origin\\main', 'wb')
fh:write('def456def456\n'); fh:close()
P.porcelain = PORC_STAGED
P.slow = false
tick()  -- watcher detects the push mid-flight: A abandoned, B started
tick()  -- B collects post-push state and applies
check(P.calls == c11c + 1, 'mid-flight repo change started a replacement refresh')
right = H.pf:rightfilter()
pright = plain(right)
check(pright:find('⇡', 1, true) == nil and pright:find('+1', 1, true) ~= nil,
    'abandoned pre-push data not applied, status neutral')

-- T12 snapline-bench consumes the input line
local before_bench = #H.printed
local replaced = endedit('snapline-bench')
check(replaced == '', 'snapline-bench replaced with empty command line')
local bench_out = table.concat(H.printed, '\n', before_bench + 1)
check(bench_out:find('snapline bench', 1, true) ~= nil, 'bench printed results')
check(bench_out:find('collect_status', 1, true) ~= nil, 'bench included snapline alternatives')

-- T13 snapline-legend prints the configured glyphs
local before_legend = #H.printed
replaced = endedit('snapline-legend')
check(replaced == '', 'snapline-legend replaced with empty command line')
local legend_out = table.concat(H.printed, '\n', before_legend + 1)
check(legend_out:find('diverged', 1, true) ~= nil and legend_out:find('⇕⇡A⇣B', 1, true) ~= nil,
    'legend shows composed diverged sample')
check(legend_out:find('untracked', 1, true) ~= nil and legend_out:find('??N', 1, true) ~= nil,
    'legend fills count placeholders')
check(legend_out:find('bisecting', 1, true) ~= nil and legend_out:find('~Nd', 1, true) ~= nil,
    'legend covers actions and fetch age')
check(legend_out:find('RiN/M', 1, true) ~= nil, 'legend explains action progress suffix')

-- A regular .lua prompt must stand down while a selected .clinkprompt is active.
H.active_prompt = 'other-prompt'
local inactive_calls = P.calls
beginedit()
check(H.pf:filter() == nil and H.pf:rightfilter() == nil and H.pf:surround() == nil,
    'snapline filters stand down for an active clinkprompt')
tick()
check(P.calls == inactive_calls, 'inactive snapline starts no status work')
H.active_prompt = nil

-- =====================================================================
print('===== suite 2: transient prompt + no-ahead-behind =====')
load_snapline({ ahead_behind = false })
local pre = H.pf:surround()
check(pre:find('\27[2K', 1, true) ~= nil, 'surround prefix has clear-line')

-- transient prompt
P.errorlevel = 0
check(H.pf:transientfilter() == '> ', 'transient prompt collapses to marker')
P.errorlevel = 2
check(plain(H.pf:transientfilter()):find('✗2', 1, true) ~= nil, 'transient keeps exit code marker')
check(plain(H.pf:transientrightfilter()):match('%d%d:%d%d:%d%d') ~= nil, 'transient right shows time')

-- ahead_behind=false adds --no-ahead-behind
P.errorlevel = 0
G.gitdir, G.branch = REPO_GD, 'main'
P.porcelain = PORC_AB_UNKNOWN
beginedit(); H.pf:filter(); tick(); H.pf:filter()
check(P.lastcmd:find('--no-ahead-behind', 1, true) ~= nil, 'status command has --no-ahead-behind')
check(plain(H.pf:rightfilter()):find('⇡?', 1, true) ~= nil, 'ab_unknown rendered with ahead_behind=false')

-- =====================================================================
print('===== suite 3: safe partial configuration =====')
load_snapline({
    status_format = { ahead = 'UP%d', modified = '%' },
    color = { clean = '\27[32m' },
    untracked_refresh_interval = 'invalid',
    not_a_snapline_option = true,
})
G.gitdir, G.branch = REPO_GD, 'main'
P.porcelain = PORC_DIRTY
check(#H.printed == 0, 'config warnings deferred until a real prompt boundary')
beginedit(); H.pf:filter(); tick(); H.pf:filter()
right = H.pf:rightfilter()
check(plain(right):find('UP1', 1, true) ~= nil, 'partial nested format override merged with defaults')
check(plain(right):find('!1', 1, true) ~= nil, 'invalid nested format retained its safe default')
check(plain(right):find('≡2', 1, true) ~= nil, 'unspecified nested stash format retained')
local warning_text = table.concat(H.printed, '\n')
check(warning_text:find('status_format.modified', 1, true) ~= nil and
      warning_text:find('untracked_refresh_interval', 1, true) ~= nil and
      warning_text:find('not_a_snapline_option', 1, true) ~= nil,
    'invalid and unknown config options reported once without crashing')

-- =====================================================================
print('===== suite 4: fsmonitor hint boolean handling =====')
load_snapline({ fsmonitor_hint_threshold = 0, fsmonitor_hint_count = 1 })
G.gitdir, G.branch = REPO_GD, 'main'
P.porcelain = PORC_STAGED
P.config_value = 'false\n'
beginedit(); H.pf:filter(); tick()
endedit(''); beginedit()
local hint_text = table.concat(H.printed, '\n')
check(hint_text:find('core.fsmonitor true', 1, true) ~= nil,
    'explicit core.fsmonitor=false does not suppress performance hint')

print('')
print(string.format('%d tests, %d failures', tests, fails))
if fails > 0 then error('FAILURES') end
