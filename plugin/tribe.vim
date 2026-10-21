" vim-tribe - AI augmentation that makes sense
" Maintainer:	Roman Bolshakov <roman@subtile.systems>
" License: MIT

vim9script

if exists("g:loaded_tribe")
  finish
endif
g:loaded_tribe = 1

def Set(name: string, value: string)
  var output = system($'tribe set {name} {shellescape(value)}')
  if v:shell_error != 0
    echohl WarningMsg
    echomsg $'vim-tribe: cannot set {name}: {trim(output)}'
    echohl None
  endif
enddef

def Clear()
  var output = system($'tribe clear')
enddef

def Register()
  if empty(v:servername)
    return
  endif
  var output = system($'tribe is-available')
  if v:shell_error != 0
    if v:shell_error == 127
      echohl WarningMsg
      echomsg $'tribe is not installed'
      echohl None
    endif
    return
  endif
  Set('role', 'editor')
  Set('addr', $'vim-server:{v:servername}')
enddef

augroup tribe
    autocmd!
    autocmd VimEnter * Register()
    autocmd VimLeave * Clear()
augroup END
