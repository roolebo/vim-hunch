vim9script
# Editor side of the tribe editor protocol, called by bin/tribe-handler
# through `vim --remote-expr`. Every function returns the exit status of
# the operation on the first line and its output after it.

const OK = 0
const ERROR = 1

def Result(status: number, output: string): string
  return $"{status}\n{output}"
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
