let s:nomodeline = (v:version > 703 || (v:version == 703 && has('patch442'))) ? '<nomodeline>' : ''

" Primary functions {{{

function! gitgutter#all() abort
  for buffer_id in gitgutter#utility#dedup(tabpagebuflist())
    let file = expand('#' . buffer_id . ':p')
    if !empty(file)
      call gitgutter#process_buffer(buffer_id, 0)
    endif
  endfor
endfunction

" bufnr: (integer) the buffer to process.
" realtime: (boolean) when truthy, do a realtime diff; otherwise do a disk-based diff.
function! gitgutter#process_buffer(bufnr, realtime) abort
  call gitgutter#utility#use_known_shell()

  call gitgutter#utility#set_buffer(a:bufnr)
  if gitgutter#utility#is_active()
    if g:gitgutter_sign_column_always
      call gitgutter#sign#add_dummy_sign()
    endif
    try
      if !a:realtime || gitgutter#utility#has_fresh_changes()
        if g:gitgutter_staged
          let diff_head  = gitgutter#diff#run_diff_revision(a:realtime || gitgutter#utility#has_unsaved_changes(), 1, 'HEAD')
          let diff_index = gitgutter#diff#run_diff_revision(a:realtime || gitgutter#utility#has_unsaved_changes(), 1, '')
          let hunks_head  = gitgutter#diff#parse_diff(diff_head)
          let hunks_index = gitgutter#diff#parse_diff(diff_index)
          " Remove the non-staged hunks
          let current_hunks = filter(copy(hunks_head), 'index(hunks_index,v:val) == -1')

          " TODO: Set the correct hunks
          " call gitgutter#hunk#set_hunks()
          let processed_head = gitgutter#diff#process_hunks(hunks_head)
          let processed_index = gitgutter#diff#process_hunks(hunks_index)
          let modified_lines = filter(copy(processed_head), 'index(processed_index,v:val) == -1')
          if &verbose
            echom 'P_H:'.string(processed_head)
            echom 'P_I:'.string(processed_index)
            echom 'RES:'.string(modified_lines)
          endif
          call gitgutter#utility#setbufvar(gitgutter#utility#bufnr(), 'tracked', 1)
          call gitgutter#handle_modifiedlines(modified_lines)
        else
          let diff = gitgutter#diff#run_diff(a:realtime || gitgutter#utility#has_unsaved_changes(), 0)
          if diff != 'async'
            call gitgutter#handle_diff(diff)
          endif
        endif
      endif
    catch /diff failed/
      call gitgutter#debug#log('diff failed')
      call gitgutter#hunk#reset()
    endtry
    execute "silent doautocmd" s:nomodeline "User GitGutter"
  else
    call gitgutter#hunk#reset()
  endif

  call gitgutter#utility#restore_shell()
endfunction


function! gitgutter#handle_diff(diff) abort
  call gitgutter#debug#log(a:diff)

  call gitgutter#utility#setbufvar(gitgutter#utility#bufnr(), 'tracked', 1)

  call gitgutter#hunk#set_hunks(gitgutter#diff#parse_diff(a:diff))
  let modified_lines = gitgutter#diff#process_hunks(gitgutter#hunk#hunks())

  return gitgutter#handle_modifiedlines(modified_lines)
endfunction

function! gitgutter#handle_modifiedlines(modified_lines) abort
  if len(a:modified_lines) > g:gitgutter_max_signs
    call gitgutter#utility#warn_once('exceeded maximum number of signs (configured by g:gitgutter_max_signs).', 'max_signs')
    call gitgutter#sign#clear_signs()
    return
  endif

  if g:gitgutter_signs || g:gitgutter_highlight_lines
    call gitgutter#sign#update_signs(a:modified_lines)
  endif

  call gitgutter#utility#save_last_seen_change()
endfunction

function! gitgutter#disable() abort
  " get list of all buffers (across all tabs)
  let buflist = []
  for i in range(tabpagenr('$'))
    call extend(buflist, tabpagebuflist(i + 1))
  endfor

  for buffer_id in gitgutter#utility#dedup(buflist)
    let file = expand('#' . buffer_id . ':p')
    if !empty(file)
      call gitgutter#utility#set_buffer(buffer_id)
      call gitgutter#sign#clear_signs()
      call gitgutter#sign#remove_dummy_sign(1)
      call gitgutter#hunk#reset()
    endif
  endfor

  let g:gitgutter_enabled = 0
endfunction

function! gitgutter#enable() abort
  let g:gitgutter_enabled = 1
  call gitgutter#all()
endfunction

function! gitgutter#toggle() abort
  if g:gitgutter_enabled
    call gitgutter#disable()
  else
    call gitgutter#enable()
  endif
endfunction

" }}}

" Line highlights {{{

function! gitgutter#line_highlights_disable() abort
  let g:gitgutter_highlight_lines = 0
  call gitgutter#highlight#define_sign_line_highlights()

  if !g:gitgutter_signs
    call gitgutter#sign#clear_signs()
    call gitgutter#sign#remove_dummy_sign(0)
  endif

  redraw!
endfunction

function! gitgutter#line_highlights_enable() abort
  let old_highlight_lines = g:gitgutter_highlight_lines

  let g:gitgutter_highlight_lines = 1
  call gitgutter#highlight#define_sign_line_highlights()

  if !old_highlight_lines && !g:gitgutter_signs
    call gitgutter#all()
  endif

  redraw!
endfunction

function! gitgutter#line_highlights_toggle() abort
  if g:gitgutter_highlight_lines
    call gitgutter#line_highlights_disable()
  else
    call gitgutter#line_highlights_enable()
  endif
endfunction

" }}}

" Signs {{{

function! gitgutter#signs_enable() abort
  let old_signs = g:gitgutter_signs

  let g:gitgutter_signs = 1
  call gitgutter#highlight#define_sign_text_highlights()

  if !old_signs && !g:gitgutter_highlight_lines
    call gitgutter#all()
  endif
endfunction

function! gitgutter#signs_disable() abort
  let g:gitgutter_signs = 0
  call gitgutter#highlight#define_sign_text_highlights()

  if !g:gitgutter_highlight_lines
    call gitgutter#sign#clear_signs()
    call gitgutter#sign#remove_dummy_sign(0)
  endif
endfunction

function! gitgutter#signs_toggle() abort
  if g:gitgutter_signs
    call gitgutter#signs_disable()
  else
    call gitgutter#signs_enable()
  endif
endfunction

" }}}

" Hunks {{{

function! gitgutter#stage_hunk() abort
  if g:gitgutter_staged
    call gitgutter#utility#warn('Unsupported')
    return
  endif
  call gitgutter#utility#use_known_shell()
  if gitgutter#utility#is_active()
    " Ensure the working copy of the file is up to date.
    " It doesn't make sense to stage a hunk otherwise.
    noautocmd silent write
    let diff = gitgutter#diff#run_diff(0, 1)
    call gitgutter#handle_diff(diff)

    if empty(gitgutter#hunk#current_hunk())
      call gitgutter#utility#warn('cursor is not in a hunk')
    else
      let diff_for_hunk = gitgutter#diff#generate_diff_for_hunk(diff, 'stage')
      call gitgutter#utility#system(gitgutter#utility#command_in_directory_of_file(g:gitgutter_git_executable.' apply --cached --unidiff-zero - '), diff_for_hunk)

      " refresh gitgutter's view of buffer
      silent execute "GitGutter"
    endif

    silent! call repeat#set("\<Plug>GitGutterStageHunk", -1)<CR>
  endif
  call gitgutter#utility#restore_shell()
endfunction

function! gitgutter#undo_hunk() abort
  if g:gitgutter_staged
    call gitgutter#utility#warn('Unsupported')
    return
  endif
  call gitgutter#utility#use_known_shell()
  if gitgutter#utility#is_active()
    " Ensure the working copy of the file is up to date.
    " It doesn't make sense to stage a hunk otherwise.
    noautocmd silent write
    let diff = gitgutter#diff#run_diff(0, 1)
    call gitgutter#handle_diff(diff)

    " TODO: Skip the current hunk check for staged mode
    if !g:gitgutter_staged && empty(gitgutter#hunk#current_hunk())
      call gitgutter#utility#warn('cursor is not in a hunk')
    else
      let diff_for_hunk = gitgutter#diff#generate_diff_for_hunk(diff, 'undo')
      " TODO: Workaround for staged mode hunk check
      if diff_for_hunk ==# "\n"
        call gitgutter#utility#warn('cursor is not in a hunk')
        return
      endif

      call gitgutter#utility#system(gitgutter#utility#command_in_directory_of_file(g:gitgutter_git_executable.' apply --reverse --unidiff-zero - '), diff_for_hunk)

      " TODO: Revert on staged mode doesn't change the file, only the working dir
      if g:gitgutter_staged
        " refresh gitgutter's view of buffer
        silent execute "GitGutter"
      else
        " reload file preserving screen line position
        " CTRL-Y and CTRL-E treat negative counts as positive counts.
        let x = line('w0')
        silent edit
        let y = line('w0')
        let z = x - y
        if z > 0
          execute "normal! ".z."\<C-E>"
        else
          execute "normal! ".z."\<C-Y>"
        endif
      endif

      silent! call repeat#set("\<Plug>GitGutterUndoHunk", -1)<CR>
    endif
  endif
  call gitgutter#utility#restore_shell()
endfunction

function! gitgutter#preview_hunk() abort
  if g:gitgutter_staged
    call gitgutter#utility#warn('Unsupported')
    return
  endif
  call gitgutter#utility#use_known_shell()
  if gitgutter#utility#is_active()
    " Ensure the working copy of the file is up to date.
    " It doesn't make sense to stage a hunk otherwise.
    noautocmd silent write
    let diff = gitgutter#diff#run_diff(0, 1)
    call gitgutter#handle_diff(diff)

    " TODO: Skip the current hunk check for staged mode
    if !g:gitgutter_staged && empty(gitgutter#hunk#current_hunk())
      call gitgutter#utility#warn('cursor is not in a hunk')
    else
      let diff_for_hunk = gitgutter#diff#generate_diff_for_hunk(diff, 'preview')

      " TODO: Workaround for staged mode hunk check
      if diff_for_hunk ==# "\n"
        call gitgutter#utility#warn('cursor is not in a hunk')
        return
      endif

      silent! wincmd P
      if !&previewwindow
        noautocmd execute 'bo' &previewheight 'new'
        set previewwindow
      endif

      setlocal noro modifiable filetype=diff buftype=nofile bufhidden=delete noswapfile
      execute "%delete_"
      call append(0, split(diff_for_hunk, "\n"))

      noautocmd wincmd p
    endif
  endif
  call gitgutter#utility#restore_shell()
endfunction

" }}}

" Staged {{{
function! gitgutter#staged_enable()

  let g:gitgutter_staged = 1
  call gitgutter#highlight#define_signs()

  call gitgutter#all()
endfunction

function! gitgutter#staged_disable()

  let g:gitgutter_staged = 0
  call gitgutter#highlight#define_signs()

  call gitgutter#all()
endfunction

function! gitgutter#staged_toggle()
  if g:gitgutter_staged
    call gitgutter#staged_disable()
  else
    call gitgutter#staged_enable()
  endif
endfunction
" }}}
