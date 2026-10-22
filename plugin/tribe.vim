" vim-tribe - AI augmentation that makes sense
" Maintainer:	Roman Bolshakov <roman@subtile.systems>
" License: MIT

vim9script

if exists("g:loaded_tribe")
  finish
endif
g:loaded_tribe = 1

const handler = expand('<sfile>:p:h:h') .. '/bin/tribe-handler'

def Set(name: string, value: string)
  var output = system($'tribe set {name} {shellescape(value)}')
  if v:shell_error != 0
    echohl WarningMsg
    echomsg $'vim-tribe: cannot set {name}: {trim(output)}'
    echohl None
  endif
enddef

def Clear()
  system('tribe clear')
enddef

def Register()
  system('tribe can-join')
  if v:shell_error == 127 && !empty(v:servername)
    echohl WarningMsg
    echomsg 'tribe is not installed'
    echohl None
  endif
  if v:shell_error != 0
    return
  endif
  # The address in tribe is a socket path
  if !has('socketserver')
    echohl ErrorMsg
    echomsg 'vim-tribe: Vim lacks +socketserver'
    echohl None
    return
  endif
  if empty(v:servername)
    return
  endif
  Set('role', 'editor')
  Set('addr', $'vim-server:{v:servername}')
  Set('handler', handler)
enddef

augroup tribe
    autocmd!
    autocmd VimEnter * Register()
    autocmd VimLeave * Clear()
augroup END
