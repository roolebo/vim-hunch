" vim-hunch - AI augmentation that makes sense
" Maintainer:	Roman Bolshakov <roman@subtile.systems>
" License: MIT

vim9script

if exists("g:loaded_hunch")
  finish
endif
g:loaded_hunch = 1

const handler = expand('<sfile>:p:h:h') .. '/bin/hunch-handler'

def Set(name: string, value: string)
  var output = system($'hunch set {name} {shellescape(value)}')
  if v:shell_error != 0
    echohl WarningMsg
    echomsg $'vim-hunch: cannot set {name}: {trim(output)}'
    echohl None
  endif
enddef

def Clear()
  system('hunch clear')
enddef

def Register()
  system('hunch can-join')
  if v:shell_error == 127 && !empty(v:servername)
    echohl WarningMsg
    echomsg 'hunch is not installed'
    echohl None
  endif
  if v:shell_error != 0
    return
  endif
  # The address in hunch is a socket path
  if !has('socketserver')
    echohl ErrorMsg
    echomsg 'vim-hunch: Vim lacks +socketserver'
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

augroup hunch
    autocmd!
    autocmd VimEnter * Register()
    autocmd VimLeave * Clear()
augroup END
