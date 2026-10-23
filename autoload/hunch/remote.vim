vim9script
# Editor side of the hunch editor protocol, called by bin/hunch-handler
# through `vim --remote-expr`. Every function returns the exit status of
# the operation on the first line and its output after it.

const OK = 0
const ERROR = 1
const UNSAVED = 3

def Result(status: number, output: string): string
  return $"{status}\n{output}"
enddef

# Load the file into a buffer without showing it; Release() undoes that
def Acquire(path: string): dict<any>
  var target = {
    path: path,
    on_disk: filereadable(path),
    existed: bufexists(path),
    buf: bufadd(path),
  }
  target.loaded = bufloaded(target.buf)
  bufload(target.buf)

  if !getbufvar(target.buf, '&modified')
    # Pick up changes made on disk without the W11 prompt
    var autoread = &g:autoread
    &g:autoread = true
    execute $'silent checktime {target.buf}'
    &g:autoread = autoread
  endif

  target.lines = getbufline(target.buf, 1, '$')
  return target
enddef

# A write that failed halfway may leave the file truncated, and Vim may
# fail to restore it from the backup
def Damaged(target: dict<any>): bool
  return target.on_disk && getbufvar(target.buf, '&modified')
    && (!filereadable(target.path) || readfile(target.path) != target.lines)
enddef

# Forced: if saving failed, the change mustn't stay in a hidden buffer.
# Unless the file got damaged: then the buffer holds its only full text.
# Returns an error then, else ''.
def Release(target: dict<any>): string
  if target.loaded
    return ''
  endif
  if Damaged(target)
    setbufvar(target.buf, '&buflisted', true)
    return $'{target.path} may be damaged, its full text is in buffer'
      .. $' {target.buf}'
  endif

  if !target.existed
    execute $'silent! bwipeout! {target.buf}'
  else
    execute $'silent! bunload! {target.buf}'
  endif
  return ''
enddef

# Write the buffer from a window that shows it, else from a hidden popup
def Save(buf: number)
  var wins = win_findbuf(buf)
  if !empty(wins)
    win_execute(wins[0], 'silent write')
    return
  endif

  var popup = popup_create(buf, {hidden: true})
  try
    win_execute(popup, 'silent write')
  finally
    popup_close(popup)
  endtry
enddef

# Top line, bottom line and cursor of every window that shows the buffer
def Views(buf: number): list<dict<any>>
  return win_findbuf(buf)->mapnew((_, id) => ({
    id: id,
    tab: win_id2tabwin(id)[0],
    topline: getwininfo(id)[0].topline,
    botline: getwininfo(id)[0].botline,
    curpos: getcurpos(id),
  }))
enddef

# Keep every window on the same text after lines first..last became count lines
def Restore(views: list<dict<any>>, first: number, last: number, count: number)
  var delta = count - (last - first + 1)
  for v in views
    var topline = v.topline > last ? v.topline + delta : v.topline
    var lnum = v.curpos[1]
    if lnum > last
      lnum += delta
    elseif lnum >= first
      lnum = min([lnum, first + count - 1])
    endif

    var view = {
      topline: max([topline, 1]),
      lnum: max([lnum, 1]),
      col: v.curpos[2] - 1,
    }
    win_execute(v.id, $'call winrestview({view})')
  endfor
enddef

# Is a line of first..last on screen in the current tab
def Visible(views: list<dict<any>>, first: number, last: number): bool
  return views->indexof((_, v) =>
    v.tab == tabpagenr() && v.topline <= last && v.botline >= first) >= 0
enddef

def SetLines(buf: number, first: number, last: number, lines: list<string>)
  var nold = last - first + 1
  if len(lines) >= nold
    setbufline(buf, first, lines[: nold - 1])
    appendbufline(buf, last, lines[nold :])
  else
    setbufline(buf, first, lines)
    deletebufline(buf, first + len(lines), last)
  endif
enddef

def Edit(path: string, buf: number, old_lines: list<string>,
    new_lines: list<string>): string
  if getbufvar(buf, '&modified')
    return Result(UNSAVED, $'{path} has unsaved changes in the editor')
  endif
  if getbufvar(buf, '&readonly')
    return Result(ERROR, $'{path} is read-only in the editor')
  endif
  if !getbufvar(buf, '&modifiable')
    return Result(ERROR, $'{path} is not modifiable in the editor')
  endif

  var text = join(getbufline(buf, 1, '$'), "\n")
  var old = join(old_lines, "\n")
  if old == ''
    return Result(ERROR, 'old text is empty')
  endif
  var idx = stridx(text, old)
  if idx < 0
    return Result(ERROR, $'old text not found in {path}')
  endif
  if stridx(text, old, idx + 1) >= 0
    return Result(ERROR,
      $'old text matches more than once in {path}, add more context')
  endif

  # Replace whole lines: keep the unmatched head of the first line and the
  # tail of the last line
  var before = strpart(text, 0, idx)
  var after = strpart(text, idx + len(old))
  var first = count(before, "\n") + 1
  var last = first + count(old, "\n")
  var head = strpart(before, strridx(before, "\n") + 1)
  var eol = stridx(after, "\n")
  var tail = eol < 0 ? after : strpart(after, 0, eol)
  var lines = split(head .. join(new_lines, "\n") .. tail, "\n", 1)

  var views = Views(buf)
  var visible = Visible(views, first, last)
  SetLines(buf, first, last, lines)
  Restore(views, first, last, len(lines))
  Save(buf)
  redraw

  var where = visible ? 'in place' : 'in the background'
  return Result(OK, $'{path} lines {first}-{last} replaced with '
    .. $'{len(lines)} lines {where}, saved')
enddef

# Active selection, else the last one in the current buffer; its region is
# the arguments of getregion()
def SelectionRange(): dict<any>
  var m = mode()
  var region: list<any>
  var active = false
  if m =~ "^[vV\<C-V>]"
    region = [getpos('v'), getpos('.'), {type: m[0]}]
    active = true
  elseif visualmode() != '' && getpos("'<")[1] > 0
    region = [getpos("'<"), getpos("'>"), {type: visualmode()}]
  else
    return {}
  endif

  var [from, to, opts] = region
  if from[1] > to[1] || from[1] == to[1] && from[2] > to[2]
    region = [to, from, opts]
  endif

  return {region: region, active: active}
enddef

def Mode(): string
  var m = mode()
  if m =~ '^[iRt]'
    return 'insert'
  elseif m =~ "^[vVsS\<C-V>\<C-S>]"
    return 'visual'
  elseif m =~ '^[cr!]'
    return 'prompt'
  endif
  return 'normal'
enddef

# The column of a getpos() position in characters, Vim counts bytes
def CharCol(pos: list<number>): number
  # Marks may hold MAXCOL as the column: linewise, or $ in a block
  var line = getline(pos[1])
  var col = min([pos[2], max([1, len(line)])])
  return charidx(line, col - 1) + 1
enddef

def ContextSelection(): any
  var sel = SelectionRange()
  if empty(sel)
    return null
  endif

  var [from, to, opts] = sel.region
  var type = {v: 'char', V: 'line'}->get(opts.type, 'block')
  var first = 1
  var last = 1
  if type != 'line'
    first = CharCol(from)
    last = CharCol(to)
  endif
  # A block may be selected from its right corner
  if type == 'block' && first > last
    [first, last] = [last, first]
  endif

  # The protocol's end is exclusive; Vim's is too with 'selection' exclusive
  var past = &selection == 'exclusive' ? 0 : 1
  return {
    start: [from[1], first],
    end: [to[1], type == 'line' ? 1 : last + past],
    type: type,
    active: sel.active,
  }
enddef

# The buffer's file, or null for a buffer without one, e.g. fugitive://
def File(buf: number): any
  var name = bufname(buf)
  if name == '' || getbufvar(buf, '&buftype') != ''
    return null
  endif
  return fnamemodify(name, ':p')
enddef

# The buffer's id in the protocol: its file, else its name, e.g.
# fugitive://, else #N for an unnamed buffer
def BufferId(buf: number): string
  var file = File(buf)
  if file != null
    return file
  endif

  var name = bufname(buf)
  return name == '' ? $'#{buf}' : name
enddef

# The number of the loaded buffer with the id, or 0
def LoadedBuffer(id: string): number
  for b in getbufinfo({bufloaded: 1})
    if BufferId(b.bufnr) == id
      return b.bufnr
    endif
  endfor
  return 0
enddef

export def Context(): string
  var buffers = getbufinfo({buflisted: 1})
    ->mapnew((_, b) => ({
      buffer: BufferId(b.bufnr),
      file: File(b.bufnr),
      modified: b.changed == 1,
      visible: !empty(b.windows),
    }))

  return Result(OK, json_encode({
    buffer: BufferId(bufnr('%')),
    file: File(bufnr('%')),
    line: line('.'),
    col: charcol('.'),
    mode: Mode(),
    selection: ContextSelection(),
    buffers: buffers,
  }))
enddef

export def Selection(): string
  var sel = SelectionRange()
  if empty(sel)
    return Result(ERROR, 'no selection')
  endif

  return Result(OK, join(call('getregion', sel.region), "\n"))
enddef

export def Read(buffer: string, first: number, last: number): string
  var lines: list<string>
  var buf = LoadedBuffer(buffer)
  if buf > 0
    lines = getbufline(buf, 1, '$')
  elseif filereadable(buffer)
    lines = readfile(buffer)
  else
    return Result(ERROR, $'{buffer} not found')
  endif

  var stop = last <= 0 ? len(lines) : min([last, len(lines)])
  var out: list<string>
  for i in range(max([first, 1]), stop)
    out->add(printf('%6d	%s', i, lines[i - 1]))
  endfor
  return Result(OK, join(out, "\n"))
enddef

export def Open(path: string, line: number, col: number): string
  var save_shortmess = &shortmess
  # Don't block on the swap file ATTENTION prompt
  set shortmess+=A
  try
    execute 'silent drop ' .. fnameescape(path)
  catch
    return Result(ERROR, $'cannot open {path}: {v:exception}')
  finally
    &shortmess = save_shortmess
  endtry

  if line > 0
    # COL counts characters, cursor() bytes
    setcursorcharpos(line, max([col, 1]))
    normal! zz
  endif
  redraw
  return Result(OK, $'opened {path}')
enddef

def ReviewTab(repo: string): number
  for tab in range(1, tabpagenr('$'))
    if gettabvar(tab, 'hunch_review', '') == repo
      return tab
    endif
  endfor
  return 0
enddef

def Subjects(): list<string>
  return getqflist()->mapnew((_, item) => item.text)
enddef

# The subjects in the review of range and the index of the one the human is
# on, or {}. Amending a commit changes its hash but keeps its subject.
def Reviewed(range: string): dict<any>
  var qf = getqflist({title: 0, idx: 0})
  if qf.title != $':Gclog {range}' || qf.idx == 0
    return {}
  endif
  return {subjects: Subjects(), idx: qf.idx - 1}
enddef

# The index of each old subject among the new ones, or -1. Fixups repeat
# subjects, so they are matched in order: longest common subsequence.
def Align(old: list<string>, new: list<string>): list<number>
  var n = len(old)
  var m = len(new)
  var lcs = range(n + 1)->map((_, _) => repeat([0], m + 1))
  for i in range(n - 1, 0, -1)
    for j in range(m - 1, 0, -1)
      lcs[i][j] = old[i] == new[j]
        ? lcs[i + 1][j + 1] + 1
        : max([lcs[i + 1][j], lcs[i][j + 1]])
    endfor
  endfor

  var match = repeat([-1], n)
  var i = 0
  var j = 0
  while i < n && j < m
    if old[i] == new[j]
      match[i] = j
      i += 1
      j += 1
    elseif lcs[i + 1][j] >= lcs[i][j + 1]
      i += 1
    else
      j += 1
    endif
  endwhile
  return match
enddef

# Where the human goes on in the new list: the same commit, else the next
# one to review. The review goes from the oldest, the log lists the newest
# first.
def NextReviewed(match: list<number>, idx: number): number
  for i in range(idx, 0, -1) + range(idx + 1, len(match) - 1)
    if match[i] >= 0
      return match[i]
    endif
  endfor
  return -1
enddef

# Go to the window with the reviewed commit and return its view, or {}
def CommitView(): dict<any>
  for w in gettabinfo(tabpagenr())[0].windows
    if getwinvar(w, '&filetype') == 'git'
      win_gotoid(w)
      return winsaveview()
    endif
  endfor
  return {}
enddef

def IsRange(repo: string, range: string): bool
  # git would take it as an option
  if range =~ '^-'
    return false
  endif
  system($'git -C {shellescape(repo)} rev-parse {shellescape(range)}')
  return v:shell_error == 0
enddef

export def Review(repo: string, range: string): string
  if !IsRange(repo, range)
    return Result(ERROR, $'not a revision range in {repo}: {range}')
  endif

  var tab = ReviewTab(repo)
  var reviewed = {}
  var subject = ''
  var view = {}
  if tab > 0
    reviewed = Reviewed(range)
    execute $'tabnext {tab}'
    view = CommitView()
    only!
    hide enew
  else
    tabnew
    t:hunch_review = repo
  endif
  execute 'tcd ' .. fnameescape(repo)

  if exists(':Gclog') == 2
    execute 'Gclog ' .. fnameescape(range)
    if !empty(reviewed)
      var match = Align(reviewed.subjects, Subjects())
      var i = NextReviewed(match, reviewed.idx)
      if i >= 0
        execute $'cc {i + 1}'
        subject = Subjects()[i]
      endif
      # Only the same commit keeps the view, the next one starts at the top
      if match[reviewed.idx] >= 0 && !empty(view)
        winrestview(view)
      endif
    endif
  else
    setline(1, systemlist($'git log -p {shellescape(range)}'))
    setlocal buftype=nofile bufhidden=wipe filetype=git nomodified
  endif

  redraw
  if tab == 0
    return Result(OK, $'showing {range} in a new tab')
  endif
  var at = empty(subject) ? '' : $' at "{subject}"'
  return Result(OK, $'showing {range} again{at}')
enddef

export def Reload(): string
  var autoread = &g:autoread
  &g:autoread = true
  var unsaved: list<string>
  # Files only: a terminal with a running job counts as changed
  for b in getbufinfo({bufloaded: 1})->filter((_, b) => File(b.bufnr) != null)
    if b.changed
      unsaved->add(b.name)
    else
      execute $'silent checktime {b.bufnr}'
    endif
  endfor
  &g:autoread = autoread
  redraw

  if !empty(unsaved)
    return Result(UNSAVED,
      $'not reloaded, unsaved changes: {join(unsaved, ", ")}')
  endif
  return Result(OK, 'reloaded')
enddef

export def Replace(path: string, old_file: string, new_file: string): string
  if !filereadable(path)
    return Result(ERROR, $'{path} does not exist, use create')
  endif
  if filewritable(path) != 1
    return Result(ERROR, $'{path} is read-only')
  endif

  var target = Acquire(path)
  var result: string
  try
    result = Edit(path, target.buf, readfile(old_file), readfile(new_file))
  catch
    result = Result(ERROR, $'cannot edit {path}: {v:exception}')
  finally
    var damaged = Release(target)
    if damaged != ''
      result = Result(ERROR, damaged)
    endif
  endtry
  return result
enddef

export def Create(path: string, content_file: string): string
  if filereadable(path) || bufexists(path)
    return Result(ERROR, $'{path} already exists, use replace')
  endif

  mkdir(fnamemodify(path, ':h'), 'p')
  var target = Acquire(path)
  try
    # A BufNewFile autocmd may have filled the buffer from a template
    deletebufline(target.buf, 1, '$')
    setbufline(target.buf, 1, readfile(content_file))
    Save(target.buf)
  catch
    return Result(ERROR, $'cannot create {path}: {v:exception}')
  finally
    # The file wasn't on disk, so it can't be damaged
    Release(target)
  endtry
  return Result(OK, $'created {path} in the background, saved')
enddef
